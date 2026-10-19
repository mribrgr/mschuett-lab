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
      mailSlugs = lib.attrNames self.mailMcp.mailboxes;
      mailUrl = slug: "http://${slug}-mail-mcp.chat.svc.cluster.local:${toString self.mailMcp.port}/mcp";
      githubRedirectUri = "${spec.webuiOrigin}/oauth/clients/mcp:${spec.githubToolServerId}/callback";
      expectedTools = [
        "server:mcp:${spec.bricklinkToolServerId}"
      ]
      ++ map (s: "server:mcp:${s}") mailSlugs;

      # Echter MCP-Aufruf gegen einen Mail-MCP, ausgeführt IM open-webui-Pod (nur der
      # darf laut CNP hinein). Kommt per stdin in den Pod, samt Bearer in der ersten
      # Zeile — so steht der Token weder in argv auf dem Host noch im Pod.
      # Ruft list_folders, also ein echtes IMAP-LOGIN: fällt auf, wenn das
      # App-Passwort widerrufen wurde. 96 Logins am Tag sind weniger als jedes
      # Mailprogramm mit Abruf alle 5 Minuten.
      #
      # Timeouts wie open-webui 0.11 beim echten Chat, damit der Test genau dann rot wird,
      # wenn auch der Nutzer einen Fehler sähe — nicht früher, nicht später:
      #   * initialize: MCP_INITIALIZE_TIMEOUT, Default 10 s (bei uns nicht gesetzt)
      #   * tools/call: das MCP-SDK baut httpx.Timeout(30, read=300); ein Gesamtlimit für
      #     Tool-Aufrufe hat open-webui nicht (middleware.py, `result = await function(…)`).
      #     Bricht der MCP vorher selbst ab, landet seine Meldung als Tool-Ergebnis beim
      #     Modell — genau das, was diese Probe dann auch meldet.
      mailProbe = pkgs.writeText "mail-mcp-probe.sh" ''
        set -u
        URL=$1
        TOOL=$2
        H=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json'
           -H 'Accept: application/json, text/event-stream')
        # Streamable HTTP antwortet je nach Server als JSON oder als SSE (`data: {…}`).
        body() { sed -n 's/^data: //p; /^{/p' | tail -1; }
        hdr=$(mktemp)
        curl -s -D "$hdr" -o /dev/null --max-time 10 "''${H[@]}" \
          -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"chat-e2e","version":"1"}}}' \
          "$URL"
        sid=$(grep -i '^mcp-session-id:' "$hdr" | cut -d' ' -f2 | tr -d '\r')
        if [ -z "$sid" ]; then echo "initialize ohne Mcp-Session-Id"; exit 0; fi
        curl -s -o /dev/null --max-time 10 "''${H[@]}" -H "Mcp-Session-Id: $sid" \
          -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$URL"
        curl -s --connect-timeout 30 --max-time 300 "''${H[@]}" -H "Mcp-Session-Id: $sid" \
          -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":{}}}" \
          "$URL" | body | jq -r '
            if .result.isError then "Tool-Fehler: " + (.result.content[0].text // "?")
            elif .error then "JSON-RPC-Fehler: " + (.error.message // "?")
            else ((.result.structuredContent // (.result.content[0].text | fromjson)).folders | length | tostring)
            end' 2>/dev/null || echo "unlesbare Antwort"
      '';

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
          for d in open-webui kanidm bricklink-mcp qdrant searxng meridian ${
            lib.concatMapStringsSep " " (s: "${s}-mail-mcp") mailSlugs
          }; do
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

          # ── 7. Alle MCP-Tool-Server sichtbar ──────────────────────────────────────
          tools=$(curl -sf --max-time 20 -H "$AUTH" "$ORIGIN/api/v1/tools/" | jq -r '.[].id' | sort | tr '\n' ' ' || true)
          for t in ${lib.escapeShellArgs expectedTools}; do
            case " $tools " in
              *" $t "*) pass "Tool-Server $t sichtbar" ;;
              *) fail "Tool-Server $t fehlt (sichtbar: $tools)" ;;
            esac
          done

          # ── 7b. GitHub ist NUR für Admins: der Nicht-Admin darf ihn NICHT sehen ──
          # access_grants = [ ] heißt „privat, nur Admin". Taucht er hier auf, ist die
          # Beschränkung weg — und mschuett käme an mbergers GitHub-Anbindung.
          case " $tools " in
            *" server:mcp:${spec.githubToolServerId} "*) fail "GitHub-MCP für den Nicht-Admin sichtbar (soll: nur Admin)" ;;
            *) pass "GitHub-MCP für den Nicht-Admin unsichtbar" ;;
          esac

          # ── 7c. GitHub-OAuth als Admin anklickbar ─────────────────────────────────
          # Gleiches Muster wie früher bei Gmail: der statische Client wird beim Start
          # registriert (open-webui-Patch für #20697); scheitert das, kostet es nur eine
          # Logzeile und der Authorize-Endpunkt antwortet 400/404.
          arow=$(k3s kubectl -n chat exec deploy/open-webui -c open-webui -- \
                   sqlite3 /data/webui.db \
                   "select id from user where email='${spec.adminUserEmail}' and role='admin' limit 1;" 2>/dev/null || true)
          if [ -z "$arow" ]; then
            fail "kein Admin-Konto ${spec.adminUserEmail}"
          else
            apl=$(printf '{"id":"%s"}' "$arow" | b64url)
            asig=$(printf '%s.%s' "$hdr" "$apl" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)
            loc=$(curl -s --max-time 20 -o /dev/null -w '%{redirect_url}' \
                    -H "Authorization: Bearer $hdr.$apl.$asig" \
                    "$ORIGIN/oauth/clients/mcp%3A${spec.githubToolServerId}/authorize" || true)
            case "$loc" in
              https://github.com/login/oauth/authorize*) pass "GitHub-Authorize leitet zu github.com" ;;
              "") fail "GitHub-Authorize liefert keinen Redirect (Client beim Start nicht registriert?)" ;;
              *) fail "GitHub-Authorize leitet nach $loc" ;;
            esac
            case "$loc" in
              *"client_id=${spec.githubOauthClientId}"*) pass "GitHub client_id korrekt" ;;
              *) fail "GitHub client_id fehlt oder falsch im Redirect" ;;
            esac
            enc_redirect=$(printf '%s' ${lib.escapeShellArg githubRedirectUri} | jq -sRr @uri)
            case "$loc" in
              *"redirect_uri=$enc_redirect"*) pass "GitHub redirect_uri korrekt" ;;
              *) fail "GitHub redirect_uri weicht ab — erwartet ${githubRedirectUri}" ;;
            esac
          fi

          # ── 8. BrickLink-MCP ist oben UND verschlossen ────────────────────────────
          # Ohne Bearer muss er ablehnen. Ein 200 hier hiesse, der Token-Schutz ist weg.
          bl=$(k3s kubectl -n chat exec deploy/open-webui -c open-webui -- \
                 curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                 "http://bricklink-mcp.chat.svc.cluster.local:8081/mcp" 2>/dev/null || echo 000)
          case "$bl" in
            401 | 403) pass "BrickLink-MCP erreichbar und verschlossen ($bl)" ;;
            000) fail "BrickLink-MCP nicht erreichbar" ;;
            *) fail "BrickLink-MCP antwortet $bl ohne Bearer (erwartet 401/403)" ;;
          esac

          # ── 9. Mail-MCPs: verschlossen ohne Bearer, Postfach-Login mit Bearer ─────
          ${lib.concatMapStrings (slug: ''
            code=$(k3s kubectl -n chat exec deploy/open-webui -c open-webui -- \
                     curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                     ${lib.escapeShellArg (mailUrl slug)} 2>/dev/null || true)
            # curl schreibt bei Verbindungsfehler selbst „000" — ein `|| echo 000`
            # ergäbe „000000" und träfe den Zweig unten nie.
            code=''${code:-000}
            case "$code" in
              401 | 403) pass "Mail-MCP ${slug} erreichbar und verschlossen ($code)" ;;
              000) fail "Mail-MCP ${slug} nicht erreichbar" ;;
              *) fail "Mail-MCP ${slug} antwortet $code ohne Bearer (erwartet 401/403)" ;;
            esac
            # Dauer mit ausgeben: das ist die Wartezeit, die ein Nutzer im Chat für
            # einen Postfach-Aufruf mindestens hat (Gmail ~20 s, AOL ~2 s).
            t0=$SECONDS
            res=$({ printf 'TOKEN=%q\n' "$(cat ${config.age.secrets.mail-mcp-bearer.path})"; cat ${mailProbe}; } \
                    | k3s kubectl -n chat exec -i deploy/open-webui -c open-webui -- \
                        bash -s -- ${lib.escapeShellArg (mailUrl slug)} list_folders 2>&1 | tail -1)
            dt=$((SECONDS - t0))
            case "$res" in
              [1-9]*) pass "Mail-MCP ${slug}: IMAP-Login ok, $res Ordner in $dt s" ;;
              *) fail "Mail-MCP ${slug}: Postfach nicht lesbar nach $dt s — $res" ;;
            esac
          '') mailSlugs}

          if [ "$fails" -gt 0 ]; then
            echo "== chat-e2e: $fails Fehler" >&2
            exit 1
          fi
          echo "== chat-e2e: alles grün"
        '';
      };

      heartbeat = pkgs.writeShellScript "chat-e2e-heartbeat" ''
        set -u
        # $EXIT_STATUS ist bei Type=oneshot der Rückgabewert von ExecStart:
        # "0" heißt grün, alles andere rot. Bei einem Signal steht hier der
        # Signalname — der ist ebenfalls nicht "0" und damit korrekt rot.
        success=false
        [ "''${EXIT_STATUS:-1}" = "0" ] && success=true

        # `|| true` fehlt hier absichtlich NICHT im Ergebnis: ExecStopPost darf
        # den Unit-Status nicht kippen, sonst meldet der Timer einen Fehler,
        # obwohl der Test selbst grün war.
        ${pkgs.curl}/bin/curl -sS -m 20           --retry 3 --retry-delay 5 --retry-all-errors           -X POST           -H "Authorization: Bearer $(cat ${config.age.secrets.gatus-token-cluster.path})"           -o /dev/null           "https://status.mauritiusberger.de/api/v1/endpoints/cluster_chat-e2e/external?success=$success"           || echo "chat-e2e: Heartbeat nicht zugestellt" >&2
        exit 0
      '';
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
          # Heartbeat an Gatus, egal wie der Lauf ausging. ExecStopPost statt
          # eines Anhängsels im Skript: systemd setzt hier $EXIT_STATUS, und der
          # Push passiert damit auch dann, wenn der Test mitten im Lauf stirbt.
          #
          # Warum das den Test aufwertet: bisher fiel ein DAUERHAFT roter
          # chat-e2e nur auf, wenn jemand ins Journal sah. Jetzt ist sowohl das
          # rote Ergebnis als auch das AUSBLEIBEN des Laufs eine Meldung.
          ExecStopPost = "${heartbeat}";
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
