{ inputs, self, ... }:
{
  # Gatus — Status-Seite und Totmann-Schalter für Cluster, NAS und Mac.
  #
  # ── Warum überhaupt ────────────────────────────────────────────────────────
  # Die Wächter, die es vorher gab, liefen alle IM überwachten Fehlerbereich:
  #   • nas-alerts.nix meldete den NAS-Ausfall — vom NAS aus.
  #   • nas-deadman.nix (Mac) prüfte nachts um 09:20 — nur bei offenem Deckel.
  #     Am 2026-09-29 entfernt, nachdem der erste Gatus-Alarm per ntfy ankam.
  # Beim NAS-Ausfall ab dem 05.09.2026 merkte es deshalb neun Tage lang niemand.
  #
  # Gatus steht außerhalb von beidem. Entscheidend ist dabei nicht die hübsche
  # Seite, sondern `external-endpoints` mit `heartbeat`: die Clients PUSHEN, und
  # das Ausbleiben eines Push ist der Alarm. Damit ist Stille nicht mehr
  # „vermutlich alles gut", sondern „meldepflichtig" — genau die Umkehrung, an
  # der die alten Wächter gescheitert sind.
  #
  # ── Warum keine aktiven Checks ins Heimnetz ────────────────────────────────
  # Erwogen und verworfen (Entscheidung 2026-09-28): netcup ins netbird-Mesh
  # holen, um den NAS direkt anzupingen. Dafür hätte es einen Setup-Key von
  # Lukas, ein weiteres Modul und die Masquerade-Frage Pod → `wt0` gebraucht —
  # für eine Aussage, die ein Heartbeat aus dem Heimnetz heraus genauso gut
  # liefert. Longhorn, der zweite Grund für das Mesh, ist mit derselben
  # Entscheidung gestrichen: Backups werden gezogen, kurze Downtime ist okay.
  #
  # ── Warum die Chat-Backends nicht direkt geprüft werden ────────────────────
  # searxng, qdrant, meridian, bricklink-mcp und mail-mcp liegen hinter je
  # einer CiliumNetworkPolicy, die den Ingress auf open-webui einschränkt. Ein
  # Check aus Namespace `monitoring` hieße, diese Policies aufzuweichen — für
  # ein Monitoring-Nice-to-have. chat-e2e prüft sie ohnehin mit (Schritt 1:
  # jedes Deployment in `chat` ready). Öffentliche Dienste laufen über den
  # öffentlichen Weg durchs Gateway, also über genau die Strecke, die auch ein
  # Nutzer nimmt. Das prüft nebenbei Gateway, TLS und DNS mit. Direkt im
  # Cluster geprüft wird nur, was KEINE Policy hat (Namespace default,
  # backup-store) und keinen öffentlichen Weg.
  #
  # ── Öffentliche Dienste kommen aus dem Gateway, nicht aus dieser Datei ─────
  # Jeder HTTPS-Listener am Gateway default/main wird automatisch ein Check
  # (Sidecar `discovery`, Wunsch 2026-10-19: „neue Apps gleich drin“). Die
  # Listener stammen aus ZWEI Quellen — charts/root-app/templates/gateway.yaml
  # (ArgoCD) und den nix-Modulen hier —, eine Liste in diesem Modul würde also
  # zwangsläufig hinterherlaufen. Gatus liest /config als Verzeichnis
  # (deepmerge, `endpoints` werden aneinandergehängt) und lädt bei geänderter
  # mtime binnen 30 s neu; der Sidecar schreibt deshalb nur bei echter
  # Änderung. Was hier noch steht, ist nur die Abweichung vom Standard-Check
  # (`discovery.overrides`: anderer Pfad, strengere Bedingung, Name).
  # Ein entfernter Listener verschwindet damit still von der Seite — gewollt:
  # wer den Listener löscht, schaltet die App ab.
  perSystem =
    { pkgs, system, ... }:
    {
      packages.gatus-image =
        let
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          root = pkgs.buildEnv {
            name = "gatus-root";
            paths = [
              pkgs.gatus
              pkgs.cacert
              pkgs.coreutils
              pkgs.bashInteractive
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgsSnap.nix-snapshotter.buildImage {
          name = "gatus";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [ "/bin/gatus" ];
            env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # Verzeichnis, nicht Datei: statische Config (ConfigMap unter
              # /config/static) + discovered.yaml vom Sidecar.
              "GATUS_CONFIG_PATH=/config"
            ];
          };
        };

      # Liest die HTTPS-Listener von Gateway default/main über die k8s-API und
      # schreibt daraus /out/discovered.yaml (JSON ist gültiges YAML). Läuft
      # einmal als initContainer (`--once`, damit Gatus gleich mit allen
      # Checks startet) und danach als Sidecar-Schleife.
      packages.gatus-discovery-image =
        let
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          program = pkgs.writeText "gatus-discovery.jq" ''
            ($cfg[0]) as $c
            | [ .spec.listeners[]
                | select(.protocol == "HTTPS")
                | .hostname // empty
                | select(startswith("*") | not) ]
            | unique
            | map(select(. as $h | $c.exclude | any(. == $h) | not))
            | map(. as $h | ($c.overrides[$h] // {}) as $o | ($o.name // $h) as $n | {
                name: $n,
                group: ($o.group // $c.group),
                url: ("https://" + $h + ($o.path // "/")),
                interval: ($o.interval // $c.interval),
                conditions: (($o.conditions // $c.conditions) + $c.extraConditions)
              }
              + (if $o.alert == false then {} else
                  { alerts: [ { type: "ntfy", description: ($n + " (https://" + $h + ") antwortet nicht") } ] } end)
              + (if $o.client then { client: $o.client } else {} end))
            | { endpoints: . }
          '';
          discovery = pkgs.writeShellApplication {
            name = "gatus-discovery";
            runtimeInputs = [
              pkgs.curl
              pkgs.jq
              pkgs.coreutils
            ];
            text = ''
              sa=/var/run/secrets/kubernetes.io/serviceaccount
              url="https://kubernetes.default.svc/apis/gateway.networking.k8s.io/v1/namespaces/$GATEWAY_NAMESPACE/gateways/$GATEWAY_NAME"
              out="$OUT_DIR/discovered.yaml"

              render() {
                local gw new
                gw=$(curl -sf --max-time 10 --cacert "$sa/ca.crt" \
                  -H "Authorization: Bearer $(cat "$sa/token")" "$url") \
                  || { echo "gatus-discovery: Gateway $GATEWAY_NAMESPACE/$GATEWAY_NAME nicht lesbar" >&2; return 1; }
                new=$(jq -S --slurpfile cfg "$DISCOVERY_CONFIG" -f ${program} <<<"$gw") || return 1
                # Eine leere Liste schreibt NICHT: ein Gateway mitten im
                # ArgoCD-Sync ohne Listener würde sonst alle öffentlichen Checks
                # still von der Seite nehmen. Lieber der letzte gute Stand.
                if [ "$(jq '.endpoints | length' <<<"$new")" -eq 0 ]; then
                  echo "gatus-discovery: keine HTTPS-Listener gefunden, behalte alten Stand" >&2
                  return 1
                fi
                # Nur bei echter Änderung schreiben: jede neue mtime lässt Gatus
                # alle Checks neu starten.
                if [ -f "$out" ] && [ "$(cat "$out")" = "$new" ]; then
                  return 0
                fi
                # .tmp hat keine yaml-Endung, Gatus ignoriert sie; mv ist atomar.
                printf '%s\n' "$new" > "$out.tmp"
                mv "$out.tmp" "$out"
                echo "gatus-discovery: $(jq -r '[.endpoints[].url] | join(" ")' <<<"$new")"
              }

              if [ "''${1:-}" = "--once" ]; then
                # Darf den Pod-Start nie blockieren: ohne Datei läuft Gatus mit
                # der statischen Config, der Sidecar holt den Rest nach.
                render || true
                exit 0
              fi
              while :; do
                render || true
                sleep "$INTERVAL"
              done
            '';
          };
          root = pkgs.buildEnv {
            name = "gatus-discovery-root";
            paths = [
              discovery
              pkgs.bashInteractive
              pkgs.coreutils
            ];
            pathsToLink = [ "/bin" ];
          };
        in
        pkgsSnap.nix-snapshotter.buildImage {
          name = "gatus-discovery";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [ "/bin/gatus-discovery" ];
            env = [ "PATH=/bin" ];
          };
        };
    };

  flake.modules.nixos.gatus =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.gatus-image;
      discoveryImg = self.packages.${pkgs.stdenv.hostPlatform.system}.gatus-discovery-image;

      ns = "monitoring";
      host = "status.mauritiusberger.de";
      idmOrigin = "https://idm.mauritiusberger.de";

      gateway = {
        namespace = "default";
        name = "main";
      };

      # Standard-Check für jeden HTTPS-Listener und die Abweichungen davon.
      # Name ist der Hostname, außer er sagt nicht, was dahinter läuft.
      # `[STATUS] < 400` als Standard, weil Apps mit Login (grocy, paperless)
      # auf / mit 302 antworten — das IST ihr gesunder Zustand.
      discoveryConfig = {
        group = "public";
        interval = "5m";
        conditions = [ "[STATUS] < 400" ];
        # Hängt an JEDEN Check, auch an Overrides. CERTIFICATE_EXPIRATION fängt
        # einen Fehler ab, den sonst NICHTS meldet: laut
        # charts/root-app/templates/gateway.yaml ignoriert cert-manager die
        # Gateway-Annotation STILL, wenn `gatewayAPI.enabled` fehlt — kein
        # Fehler, nur nie ein Zertifikat. 240h Vorlauf reicht für zwei
        # Renewal-Versuche von Let's Encrypt.
        extraConditions = [ "[CERTIFICATE_EXPIRATION] > 240h" ];
        # Gatus kann sein eigenes Fehlen nicht melden.
        exclude = [ host ];
        overrides = {
          # Namen und Schlüssel public_open-webui / public_kanidm wie vor der
          # Discovery — sonst wäre der Verlauf weg.
          "chat.steinaberfein.de" = {
            name = "open-webui";
            path = "/health";
            interval = "2m";
            conditions = [
              "[STATUS] == 200"
              "[RESPONSE_TIME] < 3000"
            ];
          };
          "idm.mauritiusberger.de" = {
            name = "kanidm";
            path = "/status";
            interval = "2m";
            conditions = [ "[STATUS] == 200" ];
          };
          "n8n.mauritiusberger.de" = {
            path = "/healthz";
            conditions = [ "[STATUS] == 200" ];
          };
          # Dieselbe Route wie die readinessProbe im Chart
          # (not-just-a-developer.com, deploy/chart/templates/deployment.yaml).
          # Stand 2026-10-19 steht ghostfolio auf replicas 0 → bewusst rot,
          # solange es aus ist (auf Wunsch trotzdem aufgenommen). `alert =
          # false`: sichtbar, aber kein ntfy (Wunsch 2026-10-20) — für einen
          # absichtlich abgeschalteten Dienst ist jeder Alarm Rauschen. Wird
          # ghostfolio wieder hochgefahren, diese Zeile entfernen.
          "ghostfolio.mauritiusberger.de" = {
            path = "/api/v1/health";
            conditions = [ "[STATUS] == 200" ];
            alert = false;
          };
        }
        # Kurz-Adressen auf Lukas' Dienste (charts/root-app/templates/redirects.yaml):
        # hier läuft kein Backend, nur ein 302 am Gateway. Geprüft wird GENAU
        # das — Redirect + Zertifikat —, nicht das Ziel: Lukas' Server ist
        # nicht unserer, und dass er fehlt, ist kein Alarm für diese Seite.
        # Dass sich der Check lohnt, zeigte der erste Tag: die HTTPS-Route
        # antwortete wegen `scheme: https` mit 404 (Commit c94db01).
        # Neue Kurz-Adressen hier eintragen, sonst folgt der Standard-Check
        # dem Redirect und prüft Lukas' Dienst mit.
        //
          lib.genAttrs
            [
              "jellyfin.mauritiusberger.de"
              "seerr.mauritiusberger.de"
              "netbird.mauritiusberger.de"
            ]
            (_: {
              group = "kurz-adressen";
              client.ignore-redirect = true;
              conditions = [ "[STATUS] == 302" ];
            });
      };
      discoveryJson = builtins.toJSON discoveryConfig;

      # Einmal als initContainer (`--once`), einmal als Sidecar — gleiche Mounts.
      discoveryContainer =
        extra:
        {
          name = "discovery";
          image = discoveryImg.image;
          imagePullPolicy = "IfNotPresent";
          env = [
            {
              name = "GATEWAY_NAMESPACE";
              value = gateway.namespace;
            }
            {
              name = "GATEWAY_NAME";
              value = gateway.name;
            }
            {
              name = "DISCOVERY_CONFIG";
              value = "/discovery/discovery.json";
            }
            {
              name = "OUT_DIR";
              value = "/out";
            }
            {
              # Ein neuer Listener ist nach spätestens 60 s + 30 s (Gatus'
              # mtime-Poll) auf der Seite.
              name = "INTERVAL";
              value = "60";
            }
          ];
          volumeMounts = [
            {
              name = "config";
              mountPath = "/out";
            }
            {
              name = "discovery";
              mountPath = "/discovery";
              readOnly = true;
            }
            {
              name = "kube-api";
              mountPath = "/var/run/secrets/kubernetes.io/serviceaccount";
              readOnly = true;
            }
          ];
          resources = {
            requests = {
              cpu = "5m";
              memory = "16Mi";
            };
            limits.memory = "64Mi";
          };
        }
        // extra;

      oidcSecretFile = ../secrets/gatus-oidc-secret.age;
      ntfyTopicFile = ../secrets/gatus-ntfy-topic.age;
      tokenNasFile = ../secrets/gatus-token-nas.age;
      tokenMacFile = ../secrets/gatus-token-mac.age;
      tokenClusterFile = ../secrets/gatus-token-cluster.age;

      # ⚠️ `''${VAR}` ist Gatus' eigene Env-Substitution, KEINE nix-Interpolation.
      # Deshalb hier escaped — im gerenderten YAML steht `${VAR}`, und Gatus
      # ersetzt es beim Start aus der Pod-Umgebung (envFrom, Secret).
      configYaml = ''
        # Verlauf überlebt einen Pod-Neustart; ohne das stünde nach jedem Deploy
        # eine leere Historie da und man könnte "war das schon gestern rot?"
        # nicht beantworten.
        storage:
          type: sqlite
          path: /data/data.db

        # Die Seite listet jeden überwachten Dienst und jeden Ausfall. Das ist
        # nichts fürs offene Netz, deshalb Kanidm davor. Wer hinein darf,
        # entscheidet die scopeMap in modules/kanidm.nix (Gruppe gatus-users) —
        # NICHT `allowed-subjects` hier: eine zweite Namensliste im YAML wäre
        # eine zweite Wahrheit, die beim nächsten Nutzer vergessen wird.
        security:
          oidc:
            issuer-url: ${idmOrigin}/oauth2/openid/gatus
            redirect-url: https://${host}/authorization-code/callback
            client-id: gatus
            client-secret: ''${GATUS_OIDC_CLIENT_SECRET}
            scopes:
              - openid

        # Derselbe ntfy-Kanal, über den der NAS seinen Tagesbericht schickt.
        # Bewusst kein eigener Topic: ein zweiter Kanal wird nie geprüft und
        # verrottet still.
        alerting:
          ntfy:
            topic: ''${GATUS_NTFY_TOPIC}
            url: https://ntfy.sh
            priority: 4
            # ⚠️ default-alert liefert NUR Voreinstellungen für Alerts, die am
            # Endpoint deklariert sind (config/config.go: Merge über ep.Alerts).
            # Ohne `alerts:` am Endpoint alarmiert Gatus NIE — so lief es vom
            # 28. auf den 29.09.: sechs rote NAS-Heartbeats, keine Meldung.
            default-alert:
              enabled: true
              # 2/2 statt 1/1: ein einzelner verlorener Request um 3 Uhr nachts
              # ist kein Ausfall. Zwei hintereinander schon.
              failure-threshold: 2
              success-threshold: 2
              send-on-resolved: true

        # Schreibt der Sidecar eine kaputte discovered.yaml (z.B. doppelter
        # Endpoint-Key), läuft Gatus mit der alten Config weiter, statt beim
        # Neuladen zu panicen.
        skip-invalid-config-update: true

        # Die Checks je HTTPS-Listener am Gateway (chat, idm, grocy, n8n, …)
        # stehen NICHT hier, sondern kommen aus /config/discovered.yaml — siehe
        # Modulkopf und `discoveryConfig`. Hier nur, was die Discovery nicht
        # sehen kann.
        endpoints:
          # Kein eigener Listener, sondern ein Pfad an chat.steinaberfein.de.
          # Der Datei-Sidecar läuft im bricklink-mcp-Pod und /healthz liegt vor
          # der Signatur-Prüfung (modules/bricklink-mcp.nix) — 200 heißt also:
          # Pod lebt, Route steht. Der MCP selbst ist per Policy nur für
          # open-webui offen; den deckt chat-e2e ab.
          - name: bricklink-mcp
            group: public
            url: https://chat.steinaberfein.de/bricklink-exports/healthz
            interval: 5m
            conditions:
              - "[STATUS] == 200"
            alerts:
              - type: ntfy
                description: "bricklink-mcp: Export-Download (chat.steinaberfein.de/bricklink-exports) antwortet nicht"

          # ── Azure-Lab (nix-config/lab, eigener Cluster, eigenes Gateway) ───
          # Für die Discovery unsichtbar. /ping beantwortet oauth2-proxy selbst,
          # ohne Login — der Check sagt also: VM an, Gateway und Zertifikat
          # gut, Login-Proxy lebt. Ob Hermes dahinter antwortet, sagt er NICHT;
          # dafür bräuchte es eine skip_auth_route in lab/modules/user-web.nix.
          - name: hermes-dashboard
            group: lab
            url: https://hermes.mberger.lab.mauritiusberger.de/ping
            interval: 5m
            conditions:
              - "[STATUS] == 200"
              - "[CERTIFICATE_EXPIRATION] > 240h"
            alerts:
              - type: ntfy
                description: "Azure-Lab: hermes.mberger.lab.mauritiusberger.de nicht erreichbar (VM, Gateway oder oauth2-proxy)"

          # ── Im Cluster, ohne öffentlichen Weg ──────────────────────────────
          # Alles hier hat KEINE NetworkPolicy, der Check weicht also nichts
          # auf (Stand 2026-10-19 verifiziert). Die Namen sagen, wer betroffen
          # ist, wenn's rot wird — postgres und redis allein sagen das nicht.
          - name: argocd
            group: cluster
            url: http://argo-cd-argocd-server.default.svc/healthz
            interval: 2m
            conditions:
              - "[STATUS] == 200"
            alerts:
              - type: ntfy
                description: "ArgoCD-Server antwortet nicht — Deploys aus charts/root-app (grocy, n8n, paperless, Website) hängen"

          - name: signal-api (n8n)
            group: cluster
            url: http://signal-api.default.svc:8080/v1/health
            interval: 2m
            conditions:
              - "[STATUS] == 204"
            alerts:
              - type: ntfy
                description: "signal-api antwortet nicht — n8n kann keine Signal-Nachrichten senden"

          # n8n hängt NICHT daran (kein DB_TYPE gesetzt → SQLite).
          - name: postgres (paperless, ghostfolio)
            group: cluster
            url: tcp://postgres.default.svc:5432
            interval: 2m
            conditions:
              - "[CONNECTED] == true"
            alerts:
              - type: ntfy
                description: "postgres in default nicht erreichbar — paperless und ghostfolio ohne Datenbank"

          - name: redis (paperless, ghostfolio)
            group: cluster
            url: tcp://redis.default.svc:6379
            interval: 2m
            conditions:
              - "[CONNECTED] == true"
            alerts:
              - type: ntfy
                description: "redis in default nicht erreichbar — paperless-Verarbeitung und ghostfolio stehen"

          # Garage-S3 als Zwischenablage velero → NAS (modules/backup-store.nix).
          # Ohne Credentials antwortet ein gesundes Garage mit 403 + S3-XML —
          # das beweist mehr als ein offener Port.
          - name: backup-store (velero-nas-mirror)
            group: cluster
            url: http://backup-store.backup-store.svc:3900/
            interval: 5m
            conditions:
              - "[STATUS] == 403"
            alerts:
              - type: ntfy
                description: "backup-store (Garage S3) antwortet nicht — velero nas-mirror und der NAS-Pull scheitern"

          # ── NetBird (Lukas' Server, netbird.lukashirsch.de) ─────────────────
          # Pull, weil der Server öffentlich ist. Über dieses Mesh läuft der
          # Mac↔NAS-Weg von unterwegs (DEPLOY_VIA=mesh) — fällt es aus, soll das
          # nicht erst beim nächsten Deploy auffallen. restic zum NAS nutzt das
          # Mesh NICHT: der ssh-Alias `nas` zeigt fest auf die LAN-IP, Backups
          # zum NAS laufen bewusst nur zu Hause (Entscheidung 2026-09-30).
          # Die Wurzel `/` ist nur das statische Dashboard (200 auch ohne
          # Backend), deshalb die zwei Dienste, die Peers wirklich brauchen:
          #   • management: `/api/users` ohne Token → 401 mit NetBird-JSON
          #     ({"message":…,"code":401}). Der JSON-Code beweist, dass der
          #     Management-Server selbst antwortet, nicht ein Proxy-Fehler.
          #   • relay: `/relay` ohne WebSocket-Upgrade → 426.
          # Signal fehlt bewusst: reines gRPC, dafür hat Gatus keinen Check,
          # der ohne NetBirds Protokoll auskommt.
          # Stand 2026-09-29 so beobachtet. 5m statt 2m: fremder Server,
          # sparsam pollen.
          - name: management
            group: netbird
            url: https://netbird.lukashirsch.de/api/users
            interval: 5m
            conditions:
              - "[STATUS] == 401"
              - "[BODY].code == 401"
              - "[CERTIFICATE_EXPIRATION] > 240h"
            alerts:
              - type: ntfy
                description: "NetBird-Management (netbird.lukashirsch.de) antwortet nicht"

          - name: relay
            group: netbird
            url: https://netbird.lukashirsch.de/relay
            interval: 5m
            conditions:
              - "[STATUS] == 426"
              - "[BODY] == pat(*WebSocket*)"
            alerts:
              - type: ntfy
                description: "NetBird-Relay (netbird.lukashirsch.de) antwortet nicht"

        # ── Totmann-Schalter ──────────────────────────────────────────────────
        # Kein Poller kommt hier heran: der NAS steht hinter einem Speedport
        # ohne Port-Forwarding, der Mac ist mal auf, mal zu. Also pushen sie, und
        # Gatus alarmiert, wenn der Push ausbleibt.
        #
        # POST /api/v1/endpoints/<group>_<name>/external?success=true
        # Header: Authorization: Bearer <token>
        #
        # Intervall = Push-Takt plus großzügiger Puffer. Zu knapp gewählt heißt
        # Fehlalarm bei jedem verpassten Lauf, und ein Wächter, dem man nicht
        # glaubt, ist keiner.
        #
        # failure-threshold 1 bei reinen Heartbeats, aus zwei Gründen:
        #   • Ein Fehler heißt hier schon „ein ganzes Intervall kein Push“ —
        #     beim NAS vier verpasste Pushes. Das Argument „ein verlorener
        #     Request ist kein Ausfall“ ist im Intervall bereits eingepreist.
        #   • Gatus schreibt nur JEDES ZWEITE Intervall einen Fehler: beim
        #     nächsten Tick zählt sein eigenes Fehlerergebnis als „Ergebnis
        #     innerhalb des Intervalls“ (watchdog/external_endpoint.go,
        #     HasEndpointStatusNewerThan). Mit Schwelle 2 bräuchte der
        #     NAS-Alarm drei Intervalle, der restic-Alarm bis zu 90 h.
        # Effektiv alarmiert Gatus damit nach 1–2 Intervallen Stille.
        external-endpoints:
          # Push alle 30 s aus einem Dauerdienst auf dem NAS
          # (homelab/modules/features/nas-heartbeat.nix, intervalSec). 2m =
          # vier verpasste Pushes; Alarm 2–4 min nach dem Ausfall, auch kurze
          # Ausfälle ab ~4 min fallen sicher auf (vorher 15 min/45m: nur lange).
          # Beim Ändern beide Seiten, NAS zuerst deployen.
          - name: nas
            group: home
            token: ''${GATUS_TOKEN_NAS}
            heartbeat:
              interval: 2m
            alerts:
              - type: ntfy
                failure-threshold: 1
                description: "NAS meldet sich nicht (Push alle 30 s)"

          # Die beiden restic-Ziele des Macs, gepusht vom Wrapper in
          # nix-config/base/modules/restic.nix — success=true nur bei rc=0.
          # Lauf ist täglich um 03:00.
          #
          # Nur melden, worum man sich kümmern kann (Entscheidung 2026-10-03,
          # ersetzt die vom 2026-09-30 „unterwegs → ein Alarm“): Ist das Ziel
          # nicht erreichbar (unterwegs bzw. offline), überspringt der Wrapper
          # den Lauf und pusht GAR NICHTS (`probe` in restic.nix). Ein Push mit
          # success=false heißt also: Ziel war da, Backup trotzdem kaputt, und
          # alarmiert sofort. Stille alarmiert erst nach 168h; weil Gatus nur
          # jedes zweite Intervall einen Fehler schreibt (s. oben), effektiv
          # nach 7–14 Tagen. Ein Wochenende mit zugeklapptem Mac oder eine
          # kurze Reise bleiben damit still, eine Woche Funkstille nicht.
          #
          # success-threshold 1: bei einem Lauf pro Tag hieße der Default 2,
          # dass die Entwarnung erst nach ZWEI guten Tagen käme.
          - name: restic-nas
            group: backup
            token: ''${GATUS_TOKEN_MAC}
            heartbeat:
              interval: 168h
            alerts:
              - type: ntfy
                failure-threshold: 1
                success-threshold: 1
                description: "restic-Backup Mac → NAS fehlgeschlagen (Ziel erreichbar) oder seit 7+ Tagen still"

          # chat-e2e läuft per systemd-Timer auf netcup alle 15 min
          # (modules/chat-e2e.nix). Der Heartbeat macht aus dem Test einen
          # Wächter: bisher fiel ein DAUERHAFT roter Testlauf nur auf, wenn
          # jemand ins Journal sah.
          - name: chat-e2e
            group: cluster
            token: ''${GATUS_TOKEN_CLUSTER}
            heartbeat:
              interval: 45m
            # Schwelle bleibt beim Default 2: hier kommen auch gepushte ROTE
            # Testläufe an (success=false alle 15 min), und ein einzelner
            # wackliger Lauf soll nicht aufs Handy.
            alerts:
              - type: ntfy
                description: "chat-e2e rot oder ausgeblieben"

          # ── velero (Schedules im Chart: not-just-a-developer.com,
          # deploy/chart/values.yaml) ──────────────────────────────────────
          #   daily-backup 02:00 → Azure Blob, nas-mirror 03:00 → backup-store.
          # Gepusht STÜNDLICH von modules/velero-heartbeat.nix: success=true
          # nur, wenn der letzte abgeschlossene Lauf `Completed` und jünger als
          # 26 h ist. Ein Push meldet damit beides, kaputtes Backup und
          # ausgesetzten Schedule; 3h ohne Push heißt: der Pusher (oder netcup)
          # selbst ist weg. Ein Fehlschlag ist hier kein wackliger Request,
          # sondern Zustand → Schwelle 1 in beide Richtungen.
          - name: velero-azure
            group: backup
            token: ''${GATUS_TOKEN_CLUSTER}
            heartbeat:
              interval: 3h
            alerts:
              - type: ntfy
                failure-threshold: 1
                success-threshold: 1
                description: "velero daily-backup → Azure: letzter Lauf nicht Completed, älter als 26 h, oder Pusher still"

          - name: velero-nas-mirror
            group: backup
            token: ''${GATUS_TOKEN_CLUSTER}
            heartbeat:
              interval: 3h
            alerts:
              - type: ntfy
                failure-threshold: 1
                success-threshold: 1
                description: "velero nas-mirror → backup-store: letzter Lauf nicht Completed, älter als 26 h, oder Pusher still"

          # Dritter Schritt der Kette: der NAS zieht backup-store täglich um
          # 05:00 in seine Garage (homelab/modules/features/nas-velero-mirror.nix,
          # ExecStopPost). Holt verpasste Läufe nach (Persistent), daher 30h —
          # wie maxAgeHours des Tagesberichts. Effektiv Alarm nach 30–60 h Stille.
          - name: nas-velero-pull
            group: backup
            token: ''${GATUS_TOKEN_NAS}
            heartbeat:
              interval: 30h
            alerts:
              - type: ntfy
                failure-threshold: 1
                success-threshold: 1
                description: "NAS-Pull der velero-Backups fehlgeschlagen oder seit 30+ h still"
      '';
    in
    {
      age.secrets = {
        gatus-oidc-secret.file = oidcSecretFile;
        gatus-ntfy-topic.file = ntfyTopicFile;
        gatus-token-nas.file = tokenNasFile;
        gatus-token-mac.file = tokenMacFile;
        gatus-token-cluster.file = tokenClusterFile;
      };

      # agenix → k8s-Secret, gleiches Muster wie modules/searxng.nix. Die Werte
      # landen als Umgebung im Pod (envFrom) und werden von Gatus' eigener
      # Env-Substitution in die Config eingesetzt — kein Secret im nix-Store,
      # keins in der ConfigMap.
      systemd.services.gatus-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "monitoring/gatus-secrets aus agenix rendern";
        after = [ "k3s.service" ];
        requires = [ "k3s.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          config.services.k3s.package
          pkgs.coreutils
          pkgs.gnugrep
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateTmp = true;
          Restart = "on-failure";
          RestartSec = 15;
        };
        restartTriggers = [
          (builtins.hashFile "sha256" oidcSecretFile)
          (builtins.hashFile "sha256" ntfyTopicFile)
          (builtins.hashFile "sha256" tokenNasFile)
          (builtins.hashFile "sha256" tokenMacFile)
          (builtins.hashFile "sha256" tokenClusterFile)
        ];
        script = ''
          set -euo pipefail
          ready=""
          for _ in $(seq 1 60); do
            if k3s kubectl get ns ${ns} >/dev/null 2>&1; then ready=yes; break; fi
            sleep 2
          done
          [ -n "$ready" ] || { echo "Namespace ${ns} kam in 120s nicht" >&2; exit 1; }
          k3s kubectl get ns chat >/dev/null 2>&1 || { echo "Namespace chat fehlt" >&2; exit 1; }

          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
          printf '%s' "$(cat ${config.age.secrets.gatus-oidc-secret.path})" > "$tmp/GATUS_OIDC_CLIENT_SECRET"
          printf '%s' "$(cat ${config.age.secrets.gatus-ntfy-topic.path})" > "$tmp/GATUS_NTFY_TOPIC"
          printf '%s' "$(cat ${config.age.secrets.gatus-token-nas.path})" > "$tmp/GATUS_TOKEN_NAS"
          printf '%s' "$(cat ${config.age.secrets.gatus-token-mac.path})" > "$tmp/GATUS_TOKEN_MAC"
          printf '%s' "$(cat ${config.age.secrets.gatus-token-cluster.path})" > "$tmp/GATUS_TOKEN_CLUSTER"

          out=$(k3s kubectl create secret generic gatus-secrets -n ${ns} \
            --from-file="$tmp/GATUS_OIDC_CLIENT_SECRET" \
            --from-file="$tmp/GATUS_NTFY_TOPIC" \
            --from-file="$tmp/GATUS_TOKEN_NAS" \
            --from-file="$tmp/GATUS_TOKEN_MAC" \
            --from-file="$tmp/GATUS_TOKEN_CLUSTER" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"
          if ! echo "$out" | grep -q 'unchanged'; then
            echo "Secret geändert → gatus neu starten"
            k3s kubectl -n ${ns} rollout restart deploy/gatus || true
          fi

          # Zweite Kopie NUR des Client-Secrets in Namespace `chat`: k8s-Secrets
          # sind namespace-gebunden, kanidm läuft in `chat` und muss dasselbe
          # Secret setzen, das Gatus vorzeigt (basicSecretFile in
          # modules/kanidm.nix). Eine agenix-Quelle, zwei Konsumenten — kein
          # Auslesen aus kanidm, kein Drift bei einem Neuaufbau.
          printf '%s' "$(cat ${config.age.secrets.gatus-oidc-secret.path})" > "$tmp/oidc-client-secret"
          outk=$(k3s kubectl create secret generic gatus-oidc -n chat \
            --from-file="$tmp/oidc-client-secret" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$outk"
          if ! echo "$outk" | grep -q 'unchanged'; then
            echo "Client-Secret geändert → kanidm neu starten"
            k3s kubectl -n chat rollout restart deploy/kanidm || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        gatus.content = [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata.name = ns;
          }
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "gatus-config";
              namespace = ns;
            };
            data."config.yaml" = configYaml;
          }
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "gatus-discovery";
              namespace = ns;
            };
            data."discovery.json" = discoveryJson;
          }
          # Leserecht auf GENAU ein Objekt: das Gateway. Kein list/watch, keine
          # Secrets, kein anderer Namespace. Das Token bekommt nur der
          # discovery-Container (projected volume unten), nicht Gatus selbst.
          {
            apiVersion = "v1";
            kind = "ServiceAccount";
            metadata = {
              name = "gatus";
              namespace = ns;
            };
            automountServiceAccountToken = false;
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "Role";
            metadata = {
              name = "gatus-discovery";
              namespace = gateway.namespace;
            };
            rules = [
              {
                apiGroups = [ "gateway.networking.k8s.io" ];
                resources = [ "gateways" ];
                resourceNames = [ gateway.name ];
                verbs = [ "get" ];
              }
            ];
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            metadata = {
              name = "gatus-discovery";
              namespace = gateway.namespace;
            };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "Role";
              name = "gatus-discovery";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = "gatus";
                namespace = ns;
              }
            ];
          }
          {
            # local-path, nicht Longhorn — das ist am 2026-09-28 gestrichen
            # worden. Ein Verlust dieses Volumes kostet die Historie, sonst
            # nichts: Konfiguration kommt aus dem Flake, der Zustand aus den
            # nächsten Checks.
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "gatus-data";
              namespace = ns;
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "1Gi";
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "gatus";
              namespace = ns;
            };
            spec = {
              replicas = 1;
              # Recreate, nicht RollingUpdate: das PVC ist RWO, zwei Pods
              # bekämen es nie gleichzeitig gemountet.
              strategy.type = "Recreate";
              selector.matchLabels.app = "gatus";
              template = {
                metadata = {
                  labels.app = "gatus";
                  annotations."checksum/config" = builtins.hashString "sha256" (configYaml + discoveryJson);
                };
                spec = {
                  enableServiceLinks = false;
                  serviceAccountName = "gatus";
                  # Token nur per projected volume an den discovery-Container.
                  automountServiceAccountToken = false;
                  securityContext = {
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                  };
                  volumes = [
                    {
                      # /config: Gatus liest das Verzeichnis. Darin
                      # discovered.yaml (Sidecar) und static/ (ConfigMap).
                      name = "config";
                      emptyDir = { };
                    }
                    {
                      name = "config-static";
                      configMap.name = "gatus-config";
                    }
                    {
                      name = "discovery";
                      configMap.name = "gatus-discovery";
                    }
                    {
                      name = "kube-api";
                      projected.sources = [
                        {
                          serviceAccountToken = {
                            path = "token";
                            expirationSeconds = 3607;
                          };
                        }
                        {
                          configMap = {
                            name = "kube-root-ca.crt";
                            items = [
                              {
                                key = "ca.crt";
                                path = "ca.crt";
                              }
                            ];
                          };
                        }
                      ];
                    }
                    {
                      name = "data";
                      persistentVolumeClaim.claimName = "gatus-data";
                    }
                  ];
                  initContainers = [
                    (discoveryContainer {
                      name = "discovery-init";
                      args = [ "--once" ];
                    })
                  ];
                  containers = [
                    (discoveryContainer { })
                    {
                      name = "gatus";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      ports = [ { containerPort = 8080; } ];
                      envFrom = [ { secretRef.name = "gatus-secrets"; } ];
                      volumeMounts = [
                        {
                          # NICHT readOnly: runc legt den Mountpoint für
                          # /config/static IN diesem Volume an, und auf einem
                          # ro-Bind scheitert das ("make mountpoint …: read-only
                          # file system", 2026-10-19). Gatus schreibt hier nichts.
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          # Unterverzeichnis im emptyDir; Gatus' walkConfigDir
                          # überspringt die `..data`-Symlinks der ConfigMap.
                          name = "config-static";
                          mountPath = "/config/static";
                          readOnly = true;
                        }
                        {
                          name = "data";
                          mountPath = "/data";
                        }
                      ];
                      # /health ist Gatus' eigener, ungeschützter Endpunkt — er
                      # liegt VOR der OIDC-Middleware, sonst würde kubelet hier
                      # auf einen Login-Redirect laufen.
                      readinessProbe = {
                        httpGet = {
                          path = "/health";
                          port = 8080;
                        };
                        initialDelaySeconds = 5;
                        periodSeconds = 10;
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "/health";
                          port = 8080;
                        };
                        initialDelaySeconds = 30;
                        periodSeconds = 30;
                      };
                      resources = {
                        requests = {
                          cpu = "25m";
                          memory = "64Mi";
                        };
                        limits.memory = "256Mi";
                      };
                    }
                  ];
                };
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "gatus";
              namespace = ns;
            };
            spec = {
              selector.app = "gatus";
              ports = [
                {
                  name = "http";
                  port = 8080;
                  targetPort = 8080;
                }
              ];
            };
          }
          {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "status-mauritiusberger-de";
              namespace = ns;
            };
            spec = {
              # sectionName: nur an den HTTPS-Listener. Der Listener selbst kommt
              # aus charts/root-app/templates/gateway.yaml und damit über ArgoCD
              # — andere Quelle, anderer Zeitpunkt. Erst der Listener, dann das
              # hier, sonst hängt die Route ins Leere.
              parentRefs = [
                {
                  name = "main";
                  namespace = "default";
                  kind = "Gateway";
                  sectionName = "https-status";
                }
              ];
              hostnames = [ host ];
              rules = [
                {
                  backendRefs = [
                    {
                      name = "gatus";
                      port = 8080;
                    }
                  ];
                }
              ];
            };
          }
          {
            # :80 → 301. Gleiche Begründung wie bei chat.steinaberfein.de: der
            # ACME-Solver matcht den exakten Challenge-Pfad und gewinnt die
            # Gateway-API-Präzedenz gegen dieses Prefix-`/`.
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "status-mauritiusberger-de-redirect";
              namespace = ns;
            };
            spec = {
              parentRefs = [
                {
                  name = "main";
                  namespace = "default";
                  kind = "Gateway";
                  sectionName = "http";
                }
              ];
              hostnames = [ host ];
              rules = [
                {
                  filters = [
                    {
                      type = "RequestRedirect";
                      requestRedirect = {
                        scheme = "https";
                        statusCode = 301;
                      };
                    }
                  ];
                }
              ];
            };
          }
        ];
      };
    };
}
