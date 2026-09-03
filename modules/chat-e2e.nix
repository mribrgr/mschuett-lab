{ self, ... }:
{
  # End-to-End-Tests für den Chat-Stack auf chat.steinaberfein.de.
  #
  # Warum überhaupt: die interessanten Fehler dieses Stacks sind allesamt LEISE. Ein
  # OAuth-Client, der beim Start nicht registriert wird, kostet eine Logzeile und sonst
  # nichts — bis jemand klickt (2026-09-03 genau so passiert). Ein weggerutschter
  # Modell-Grant zeigt sich erst, wenn mschuett vor einer leeren Auswahl steht. Ein
  # `ENABLE_LOGIN_FORM=True` fällt niemandem auf, macht die Instanz aber zu einem
  # offenen Admin-Claim. Alle drei prüft ein Blick auf „läuft der Pod?" NICHT.
  #
  # Der Test läuft deshalb gegen die ÖFFENTLICHE URL, nicht gegen den ClusterIP: damit
  # liegen Gateway-Listener, HTTPRoute und TLS mit im Pfad. Hairpin über die eigene
  # öffentliche IP funktioniert auf netcup (2026-09-03 verifiziert, 152.53.15.24).
  #
  # Authentifiziert wird als mschuett mit einem selbst signierten HS256-JWT — dasselbe
  # Verfahren, das der Modell-Gating-Sidecar in modules/openwebui.nix benutzt. Kein
  # Passwort, kein API-Key, kein zusätzliches Secret: der WEBUI_SECRET_KEY liegt ohnehin
  # als agenix-Secret auf diesem Host. Ein Passwort ginge auch gar nicht — kanidm kann
  # Personen-Credentials nicht provisionieren, die entstehen nur interaktiv.
  #
  # Die Soll-Werte kommen aus `self.chat` (definiert in modules/openwebui.nix), nicht aus
  # Literalen hier. Ein Test mit eigener Wahrheit bestätigt irgendwann grün eine
  # Vergangenheit.
  #
  # Fehlschlag = Unit failed = sichtbar in `systemctl --failed`. Bewusst KEIN Alerting
  # hier: das gehört in die Monitoring-Schicht, nicht in den Test.
  #
  # Manuell:  ssh netcup 'systemctl start chat-e2e; journalctl -u chat-e2e -n 60 --no-pager'
  flake.modules.nixos.chat-e2e =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      spec = self.chat;
      gmailClientKey = "mcp:${spec.gmailToolServerId}";
      gmailRedirectUri = "${spec.webuiOrigin}/oauth/clients/${gmailClientKey}/callback";
      expectedTools = [
        "server:mcp:${spec.bricklinkToolServerId}"
        "server:mcp:${spec.gmailToolServerId}"
      ];

      script = pkgs.writeShellApplication {
        name = "chat-e2e";
        runtimeInputs = [
          config.services.k3s.package
          pkgs.curl
          pkgs.jq
          pkgs.openssl
          pkgs.coreutils
          pkgs.gnugrep
        ];
        # set -e wäre hier falsch: der Test soll ALLE Prüfungen laufen lassen und am Ende
        # eine vollständige Liste zeigen, statt beim ersten Fehler abzubrechen und die
        # restlichen Befunde zu verstecken.
        text = ''
          set -uo pipefail

          ORIGIN=${lib.escapeShellArg spec.webuiOrigin}
          fails=0
          pass() { echo "  PASS  $1"; }
          fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

          echo "== chat-e2e gegen $ORIGIN"

          # ── 1. Alle Deployments im Namespace chat sind vollständig ready ──────────
          for d in open-webui kanidm bricklink-mcp qdrant searxng meridian; do
            want=$(k3s kubectl -n chat get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
            have=$(k3s kubectl -n chat get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
            if [ -n "$want" ] && [ "$want" = "''${have:-0}" ]; then
              pass "deployment $d ready ($want/$want)"
            else
              fail "deployment $d nicht ready (''${have:-0}/''${want:-?})"
            fi
          done

          # ── 2. Öffentlicher Pfad: Gateway-Listener, HTTPRoute, TLS ────────────────
          code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ORIGIN/health" || echo 000)
          if [ "$code" = 200 ]; then pass "GET /health 200"; else fail "GET /health $code"; fi

          # ── 3. Kein offener Admin-Claim ───────────────────────────────────────────
          # Mit 0 Nutzern in der DB lässt open-webui den ERSTEN Signup bewusst durch und
          # macht ihn zum Admin; ENABLE_SIGNUP=False greift für genau diesen Fall nicht.
          # Auf einer öffentlichen Instanz ist ein aktives Login-Formular deshalb ein
          # offener Admin-Claim. Bewusst über /api/config statt über einen echten
          # Signup-POST: der würde im Regressionsfall genau das anlegen, was er aufdeckt.
          cfg=$(curl -sf --max-time 20 "$ORIGIN/api/config" || true)
          if [ -z "$cfg" ]; then
            fail "/api/config nicht abrufbar"
          else
            for flag in enable_login_form enable_signup; do
              v=$(printf '%s' "$cfg" | jq -r ".features.$flag")
              if [ "$v" = "false" ]; then pass "$flag=false"; else fail "$flag=$v (erwartet false)"; fi
            done
            v=$(printf '%s' "$cfg" | jq -r '.features.auth')
            if [ "$v" = "true" ]; then pass "auth=true"; else fail "auth=$v (erwartet true)"; fi
          fi

          # ── 4. ENV=prod: keine öffentliche API-Doku ───────────────────────────────
          # Nicht am Statuscode festmachen — der SPA-Catch-All beantwortet JEDE unbekannte
          # URL mit 200 und dem Frontend-Shell. Entscheidend ist, ob unter /openapi.json
          # ein OpenAPI-Dokument liegt.
          body=$(curl -s --max-time 20 "$ORIGIN/openapi.json" || true)
          if printf '%s' "$body" | jq -e '.openapi' >/dev/null 2>&1; then
            fail "/openapi.json liefert ein OpenAPI-Dokument — ENV steht nicht auf prod"
          else
            pass "/openapi.json ist kein OpenAPI-Dokument (ENV=prod)"
          fi

          # ── 5. Der Nicht-Admin existiert und ist kein Admin ───────────────────────
          row=$(k3s kubectl -n chat exec deploy/open-webui -c open-webui -- \
                  sqlite3 /data/webui.db \
                  "select id||'|'||role from user where email='${spec.limitedUserEmail}' limit 1;" 2>/dev/null || true)
          uid=''${row%%|*}
          role=''${row##*|}
          if [ -z "$row" ]; then
            fail "kein Konto für ${spec.limitedUserEmail} — SSO-Erstlogin fehlt noch"
            echo "== $fails Fehler" >&2
            exit 1
          fi
          pass "Konto ${spec.limitedUserEmail} vorhanden"
          if [ "$role" = "user" ]; then
            pass "Rolle=user (kein Admin)"
          else
            fail "Rolle=$role (erwartet user)"
          fi

          # ── JWT wie im Gating-Sidecar: HS256 über den WEBUI_SECRET_KEY ────────────
          b64url() { base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n'; }
          secret=$(cat ${config.age.secrets.openwebui-secret-key.path})
          hdr=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
          pl=$(printf '{"id":"%s"}' "$uid" | b64url)
          sig=$(printf '%s.%s' "$hdr" "$pl" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)
          AUTH="Authorization: Bearer $hdr.$pl.$sig"

          # ── 6. Modellsichtbarkeit: exakt die Grants, nichts darüber hinaus ────────
          got=$(curl -sf --max-time 20 -H "$AUTH" "$ORIGIN/api/models" | jq -r '.data[].id' | sort | tr '\n' ' ' || true)
          want=$(printf '%s\n' ${lib.escapeShellArgs spec.limitedModelIds} | sort | tr '\n' ' ')
          if [ "$got" = "$want" ]; then
            pass "Modelle für den Nicht-Admin: $got"
          else
            fail "Modelle weichen ab — ist: [$got] soll: [$want]"
          fi

          # ── 7. Beide MCP-Tool-Server sichtbar ─────────────────────────────────────
          tools=$(curl -sf --max-time 20 -H "$AUTH" "$ORIGIN/api/v1/tools/" | jq -r '.[].id' | sort | tr '\n' ' ' || true)
          for t in ${lib.escapeShellArgs expectedTools}; do
            case " $tools " in
              *" $t "*) pass "Tool-Server $t sichtbar" ;;
              *) fail "Tool-Server $t fehlt (sichtbar: $tools)" ;;
            esac
          done

          # ── 8. Gmail-OAuth ist tatsächlich anklickbar ─────────────────────────────
          # Der eigentliche Regressionsschutz. Beim Start registriert open-webui den
          # statischen OAuth-Client; scheitert das, kostet es nur eine Logzeile — und der
          # Endpunkt antwortet dann 400 ("authorization endpoint could not be resolved")
          # oder 404. Geprüft wird nicht nur der 302, sondern auch WOHIN: client_id,
          # redirect_uri und Scopes müssen zu dem passen, was im Google-Client hinterlegt
          # ist. Eine falsche redirect_uri fällt sonst erst beim Nutzer auf, als
          # redirect_uri_mismatch.
          loc=$(curl -s --max-time 20 -o /dev/null -w '%{redirect_url}' \
                  -H "$AUTH" "$ORIGIN/oauth/clients/mcp%3A${spec.gmailToolServerId}/authorize" || true)
          if [ -z "$loc" ]; then
            fail "Gmail-Authorize liefert keinen Redirect (Client beim Start nicht registriert?)"
          else
            case "$loc" in
              https://accounts.google.com/*) pass "Gmail-Authorize leitet zu accounts.google.com" ;;
              *) fail "Gmail-Authorize leitet nach $loc" ;;
            esac
            case "$loc" in
              *"client_id=${spec.gmailOauthClientId}"*) pass "client_id korrekt" ;;
              *) fail "client_id fehlt oder falsch im Redirect" ;;
            esac
            enc_redirect=$(printf '%s' ${lib.escapeShellArg gmailRedirectUri} | jq -sRr @uri)
            case "$loc" in
              *"redirect_uri=$enc_redirect"*) pass "redirect_uri korrekt" ;;
              *) fail "redirect_uri weicht ab — erwartet ${gmailRedirectUri}" ;;
            esac
            for sc in ${lib.escapeShellArgs (lib.splitString " " spec.gmailOauthScope)}; do
              enc_scope=$(printf '%s' "$sc" | jq -sRr @uri)
              case "$loc" in
                *"$enc_scope"*) pass "Scope $sc angefragt" ;;
                *) fail "Scope $sc fehlt im Redirect" ;;
              esac
            done
          fi

          # ── 9. BrickLink-MCP ist oben UND verschlossen ────────────────────────────
          # Ohne Bearer muss er ablehnen. Ein 200 hier hiesse, der Token-Schutz ist weg.
          bl=$(k3s kubectl -n chat exec deploy/open-webui -c open-webui -- \
                 curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                 "http://bricklink-mcp.chat.svc.cluster.local:8081/mcp" 2>/dev/null || echo 000)
          case "$bl" in
            401 | 403) pass "BrickLink-MCP erreichbar und verschlossen ($bl)" ;;
            000) fail "BrickLink-MCP nicht erreichbar" ;;
            *) fail "BrickLink-MCP antwortet $bl ohne Bearer (erwartet 401/403)" ;;
          esac

          if [ "$fails" -gt 0 ]; then
            echo "== chat-e2e: $fails Fehler" >&2
            exit 1
          fi
          echo "== chat-e2e: alles grün"
        '';
      };
    in
    {
      systemd.services.chat-e2e = lib.mkIf (config.services.k3s.role == "server") {
        description = "End-to-End-Tests des Chat-Stacks (chat.steinaberfein.de)";
        after = [
          "k3s.service"
          "open-webui-secrets.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe script;
        };
      };

      # Alle 15 Minuten plus einmal nach dem Boot. Bewusst ein Timer und kein
      # `wantedBy = multi-user.target`: nach einem Deploy braucht der Pod bis zu fünf
      # Minuten, bis er wirklich oben ist (terminationGracePeriod 300 bei Recreate) —
      # ein Test direkt in der Aktivierung würde zuverlässig rot melden, obwohl alles in
      # Ordnung ist. `Persistent` bewusst NICHT: ein verpasster Lauf soll nicht
      # nachgeholt werden, der nächste kommt in 15 Minuten von selbst.
      systemd.timers.chat-e2e = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat-e2e regelmäßig laufen lassen";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "10min";
          OnUnitActiveSec = "15min";
          AccuracySec = "1min";
        };
      };
    };
}
