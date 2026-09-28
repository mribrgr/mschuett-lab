{ inputs, self, ... }:
{
  # Gatus — Status-Seite und Totmann-Schalter für Cluster, NAS und Mac.
  #
  # ── Warum überhaupt ────────────────────────────────────────────────────────
  # Die Wächter, die es vorher gab, liefen alle IM überwachten Fehlerbereich:
  #   • nas-alerts.nix meldete den NAS-Ausfall — vom NAS aus.
  #   • nas-deadman.nix (Mac) prüfte nachts um 09:20 — nur bei offenem Deckel.
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
  # ── Warum nur öffentliche Endpunkte aktiv geprüft werden ───────────────────
  # searxng, qdrant, bricklink-mcp und open-webui liegen hinter je einer
  # CiliumNetworkPolicy, die den Ingress auf genau einen Peer einschränkt. Ein
  # Check aus Namespace `monitoring` hieße, diese Policies aufzuweichen — für
  # ein Monitoring-Nice-to-have. Stattdessen läuft der Check über den
  # öffentlichen Weg durchs Gateway, also über genau die Strecke, die auch ein
  # Nutzer nimmt. Das prüft nebenbei Gateway, TLS und DNS mit.
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
              "GATUS_CONFIG_PATH=/config/config.yaml"
            ];
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

      ns = "monitoring";
      host = "status.mauritiusberger.de";
      idmOrigin = "https://idm.mauritiusberger.de";

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
            default-alert:
              enabled: true
              # 2/2 statt 1/1: ein einzelner verlorener Request um 3 Uhr nachts
              # ist kein Ausfall. Zwei hintereinander schon.
              failure-threshold: 2
              success-threshold: 2
              send-on-resolved: true

        endpoints:
          # CERTIFICATE_EXPIRATION fängt einen Fehler ab, den sonst NICHTS
          # meldet: laut charts/root-app/templates/gateway.yaml ignoriert
          # cert-manager die Gateway-Annotation STILL, wenn `gatewayAPI.enabled`
          # fehlt — kein Fehler, nur nie ein Zertifikat. 240h Vorlauf reicht für
          # zwei Renewal-Versuche von Let's Encrypt.
          - name: open-webui
            group: public
            url: https://chat.steinaberfein.de/health
            interval: 2m
            conditions:
              - "[STATUS] == 200"
              - "[RESPONSE_TIME] < 3000"
              - "[CERTIFICATE_EXPIRATION] > 240h"

          - name: kanidm
            group: public
            url: ${idmOrigin}/status
            interval: 2m
            conditions:
              - "[STATUS] == 200"
              - "[CERTIFICATE_EXPIRATION] > 240h"

          - name: steinaberfein.de
            group: public
            url: https://www.steinaberfein.de/
            interval: 5m
            conditions:
              - "[STATUS] < 400"
              - "[CERTIFICATE_EXPIRATION] > 240h"

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
        external-endpoints:
          # Push alle 15 min aus einem systemd-Timer auf dem NAS.
          - name: nas
            group: home
            token: ''${GATUS_TOKEN_NAS}
            heartbeat:
              interval: 45m

          # Die beiden restic-Ziele des Macs, gepusht vom Wrapper in
          # nix-config/base/modules/restic.nix — success=true nur bei rc=0.
          # Lauf ist täglich um 03:00; 30h lassen einen ausgefallenen Lauf
          # durchgehen, zwei nicht.
          - name: restic-nas
            group: backup
            token: ''${GATUS_TOKEN_MAC}
            heartbeat:
              interval: 30h

          - name: restic-azure
            group: backup
            token: ''${GATUS_TOKEN_MAC}
            heartbeat:
              interval: 30h

          # chat-e2e läuft per systemd-Timer auf netcup alle 15 min
          # (modules/chat-e2e.nix). Der Heartbeat macht aus dem Test einen
          # Wächter: bisher fiel ein DAUERHAFT roter Testlauf nur auf, wenn
          # jemand ins Journal sah.
          - name: chat-e2e
            group: cluster
            token: ''${GATUS_TOKEN_CLUSTER}
            heartbeat:
              interval: 45m

          # velero fehlt hier bewusst: sein Schedule steht im Chart-Repo, nicht
          # in diesem Flake. Erst den Takt festnageln, dann den Heartbeat — ein
          # geratenes Intervall produziert nur Fehlalarme.
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
                  annotations."checksum/config" = builtins.hashString "sha256" configYaml;
                };
                spec = {
                  enableServiceLinks = false;
                  securityContext = {
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                  };
                  volumes = [
                    {
                      name = "config";
                      configMap.name = "gatus-config";
                    }
                    {
                      name = "data";
                      persistentVolumeClaim.claimName = "gatus-data";
                    }
                  ];
                  containers = [
                    {
                      name = "gatus";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      ports = [ { containerPort = 8080; } ];
                      envFrom = [ { secretRef.name = "gatus-secrets"; } ];
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/config";
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
