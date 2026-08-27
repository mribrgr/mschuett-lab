{ inputs, self, ... }:
{
  # BrickLink-MCP — Verwaltung von Max' BrickLink-Store aus dem Chat.
  #
  # Ziel (2026-08-27 festgelegt): mschuett verwaltet seinen Shop über
  # chat.mauritiusberger.de und braucht die BrickLink-Web-UI langfristig nicht mehr.
  #
  # ── Warum ein eigener Dienst und nicht BrickStores MCP ────────────────────────
  # BrickStore (2026.7.1) hat selbst einen MCP-Server (src/mcp-server/), der kann
  # aber nur Katalog und offene Dokumente — keine Bestellungen, keine Statuswechsel,
  # und er lebt in einer Desktop-Qt-App. Hier läuft ein eigener Server im Cluster.
  #
  # ── Datenquellen ─────────────────────────────────────────────────────────────
  #   1. Store API v1 (api.bricklink.com, OAuth 1.0a, EIGENER Consumer-Key):
  #      Bestellungen, Positionen, Nachrichten (nur empfangene), Feedback,
  #      Inventar, Katalog-Einzelabfragen, Preis-Guide, Benachrichtigungen sowie
  #      die zwei erlaubten Statuswechsel.
  #      ⚠️ Das Access-Token ist an eine REGISTRIERTE IP gebunden ("BrickLink
  #      resources are accessible only from the registered location") — für dieses
  #      Deployment die netcup-Public-IP aus base/_network.nix. Zieht der Dienst
  #      auf einen anderen Host, MUSS das Token neu registriert werden.
  #      Limit: 5000 Requests/Tag; der Server bucht mit und blockt vorher.
  #   2. Offizieller Katalog-Export (www.bricklink.com/catalogDownload.asp) für
  #      den Offline-Suchindex. Die API hat KEINE Textsuche — ohne Index gibt es
  #      kein „finde die Teilenummer zu 'Brick 2 x 4'".
  #      Dieser Weg braucht eine Web-Session und die gibt es nur über den
  #      BrickStore-Client-Pfad: Header `x-bl-client-id` mit BrickStores UUID
  #      plus ein Token, das Max SELBST auf
  #      bricklink.com/v3/brickstore-access-management.page erzeugt.
  #      ⚠️ Dieses Token läuft nach 30 TAGEN ab und muss von Hand erneuert werden
  #      (inhärent interaktiv, deshalb erlaubte Ausnahme vom Deklarativ-Prinzip).
  #      Läuft es ab, funktioniert alles außer `catalog_refresh` weiter.
  #
  # ── Was hier bewusst NICHT geht ──────────────────────────────────────────────
  # Nachrichten SENDEN, Rechnung senden, Wanted Lists, Store-Statistiken und die
  # Katalog-Suche über die Web-UI: alles nur im Web verfügbar. Phase 2 (Playwright)
  # ist bewusst zurückgestellt — BrickLink hängt eine AWS-WAF-Challenge vor die
  # Seiten, das wird ein eigenes Projekt.
  #
  # ── Zugriff ──────────────────────────────────────────────────────────────────
  # Kein Ingress. OpenWebUI 0.11 spricht natives MCP ausschließlich über
  # Streamable HTTP und verbindet sich CLUSTERINTERN; zusätzlich lässt eine
  # CiliumNetworkPolicy nur den open-webui-Pod herein, und der Server verlangt
  # einen Bearer-Token. In OpenWebUI wird die Verbindung per Access Control auf
  # Max' Gruppe eingeschränkt (Admin → Integrations → External Tool Servers).
  perSystem =
    { pkgs, system, ... }:
    {
      packages.bricklink-mcp = pkgs.python3Packages.buildPythonApplication {
        pname = "bricklink-mcp";
        version = "0.1.0";
        pyproject = true;
        src = ../pkgs/bricklink-mcp;
        build-system = [ pkgs.python3Packages.setuptools ];
        dependencies = with pkgs.python3Packages; [
          fastmcp
          requests
          requests-oauthlib
        ];
        pythonImportsCheck = [ "bricklink_mcp" ];
        # Der Test fährt einen Fake-BrickLink auf 127.0.0.1 und prüft damit die
        # OAuth-1.0a-Signatur, die meta-Auswertung, Cache und Tageskontingent —
        # ohne Netz, also sandbox-tauglich.
        checkPhase = ''
          runHook preCheck
          export BRICKLINK_DATA_DIR="$TMPDIR/bricklink"
          ${pkgs.python3.interpreter} tests/test_bricklink_mcp.py
          runHook postCheck
        '';
      };

      packages.bricklink-mcp-image =
        let
          pkgsBl = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          app = pkgsBl.python3Packages.buildPythonApplication {
            pname = "bricklink-mcp";
            version = "0.1.0";
            pyproject = true;
            src = ../pkgs/bricklink-mcp;
            build-system = [ pkgsBl.python3Packages.setuptools ];
            dependencies = with pkgsBl.python3Packages; [
              fastmcp
              requests
              requests-oauthlib
            ];
            pythonImportsCheck = [ "bricklink_mcp" ];
            checkPhase = ''
              runHook preCheck
              export BRICKLINK_DATA_DIR="$TMPDIR/bricklink"
              ${pkgsBl.python3.interpreter} tests/test_bricklink_mcp.py
              runHook postCheck
            '';
          };
          root = pkgsBl.buildEnv {
            name = "bricklink-mcp-root";
            paths = [
              app
              # sqlite3-CLI: der Katalogindex und der Zustand liegen als SQLite im
              # PVC — ohne CLI ist im Pod keine lesende Diagnose möglich.
              pkgsBl.sqlite
              pkgsBl.coreutils
              pkgsBl.bashInteractive
              pkgsBl.curl
              pkgsBl.jq
              pkgsBl.gnugrep
              pkgsBl.gnused
              pkgsBl.cacert
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgsBl.nix-snapshotter.buildImage {
          name = "bricklink-mcp";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [ "/bin/bricklink-mcp" ];
            env = [
              "PATH=/bin"
              # Ohne CA-Bundle scheitert jeder TLS-Call nach api.bricklink.com mit
              # „certificate verify failed" — gleiche Falle wie bei openwebui/meridian.
              "SSL_CERT_FILE=${pkgsBl.cacert}/etc/ssl/certs/ca-bundle.crt"
              "REQUESTS_CA_BUNDLE=${pkgsBl.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            workingdir = "/data";
          };
        };
    };

  flake.modules.nixos.bricklink-mcp =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.bricklink-mcp-image;
      apiFile = ./../secrets/bricklink-api.age;
      webTokenFile = ./../secrets/bricklink-web-token.age;
      bearerFile = ./../secrets/bricklink-mcp-bearer.age;
      credentialHash = builtins.concatStringsSep "-" (
        map (f: builtins.hashFile "sha256" f) [
          apiFile
          webTokenFile
          bearerFile
        ]
      );
    in
    {
      age.secrets = {
        bricklink-api.file = apiFile;
        bricklink-web-token.file = webTokenFile;
        bricklink-mcp-bearer.file = bearerFile;
      };

      systemd.services.bricklink-mcp-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat/bricklink-mcp-secrets aus agenix rendern";
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
        # Wie bei meridian: ohne restartTriggers liefe der oneshot nach einer
        # Token-Rotation nie wieder (RemainAfterExit + Unit kennt nur Pfade).
        restartTriggers = [ credentialHash ];
        script = ''
          set -euo pipefail
          ready=""
          for _ in $(seq 1 60); do
            if k3s kubectl get ns chat >/dev/null 2>&1; then ready=yes; break; fi
            sleep 2
          done
          if [ -z "$ready" ]; then
            echo "Namespace chat kam in 120s nicht — Unit scheitert absichtlich" >&2
            exit 1
          fi

          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT

          # Ein Verzeichnis, eine Datei pro Secret-Key — `--from-file=<dir>` nimmt jede
          # Datei darin als Schlüssel.
          #
          # ⚠️ NICHT `--from-env-file` für die dotenv-Datei und daneben `--from-file` für
          # die beiden Einzelwerte: kubectl lehnt die Kombination ab
          #   „error: from-env-file cannot be combined with from-file or from-literal"
          # (am 2026-08-27 genau so im Journal gelandet, Unit lief in den Restart-Loop).
          # Deshalb wird die dotenv-Datei hier selbst zerlegt.
          #
          # printf '%s' statt cat: schluckt das abschließende Newline. Mit Newline im Wert
          # wäre die OAuth-Signatur falsch und BrickLink antwortet 401.
          while IFS= read -r line; do
            case "$line" in ""|"#"*) continue ;; esac
            key=''${line%%=*}
            value=''${line#*=}
            # Nur erwartete Schlüssel übernehmen: ein Tippfehler in der age-Datei soll
            # nicht als stiller Extra-Key im k8s-Secret landen.
            case "$key" in
              BRICKLINK_CONSUMER_KEY|BRICKLINK_CONSUMER_SECRET|BRICKLINK_TOKEN_VALUE|BRICKLINK_TOKEN_SECRET|BRICKLINK_STORE_USERNAME) ;;
              *) echo "unbekannter Schlüssel in bricklink-api.age übersprungen: $key" >&2; continue ;;
            esac
            if [ -z "$value" ]; then
              echo "WARNUNG: $key ist leer — der MCP wird das entsprechende Tool ablehnen" >&2
            fi
            printf '%s' "$value" > "$tmp/$key"
          done < ${config.age.secrets.bricklink-api.path}

          printf '%s' "$(cat ${config.age.secrets.bricklink-web-token.path})" \
            > "$tmp/BRICKLINK_WEB_CLIENT_TOKEN"
          printf '%s' "$(cat ${config.age.secrets.bricklink-mcp-bearer.path})" \
            > "$tmp/BRICKLINK_MCP_BEARER"

          out=$(k3s kubectl create secret generic bricklink-mcp-secrets -n chat \
            --from-file="$tmp" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"
          if ! echo "$out" | grep -q 'unchanged'; then
            echo "Credentials geändert → bricklink-mcp neu starten"
            k3s kubectl -n chat rollout restart deploy/bricklink-mcp || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        bricklink-mcp.content = [
          {
            # Katalogindex + Zustand (Kontingentzähler, Cache). 3Gi: der volle
            # BrickLink-Katalog als SQLite mit FTS5 liegt bei ~300 MB, der Neubau
            # braucht kurzzeitig das Doppelte (er schreibt nach catalog.db.new und
            # tauscht erst am Ende atomar).
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "bricklink-mcp-data";
              namespace = "chat";
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "3Gi";
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "bricklink-mcp";
              namespace = "chat";
            };
            spec = {
              replicas = 1;
              # Recreate, nicht RollingUpdate: das PVC ist ReadWriteOnce und der
              # Katalogindex verträgt keine zwei Schreiber.
              strategy.type = "Recreate";
              selector.matchLabels.app = "bricklink-mcp";
              template = {
                metadata = {
                  labels.app = "bricklink-mcp";
                  # envFrom liest das Secret NUR beim Containerstart.
                  annotations."checksum/credentials" = builtins.hashString "sha256" credentialHash;
                };
                spec = {
                  securityContext = {
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                  };
                  volumes = [
                    {
                      name = "data";
                      persistentVolumeClaim.claimName = "bricklink-mcp-data";
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                  ];
                  containers = [
                    {
                      name = "bricklink-mcp";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      workingDir = "/data";
                      ports = [ { containerPort = 8081; } ];
                      envFrom = [ { secretRef.name = "bricklink-mcp-secrets"; } ];
                      env = [
                        {
                          name = "BRICKLINK_DATA_DIR";
                          value = "/data";
                        }
                        {
                          name = "BRICKLINK_MCP_HOST";
                          value = "0.0.0.0";
                        }
                        {
                          name = "BRICKLINK_MCP_PORT";
                          value = "8081";
                        }
                        {
                          name = "BRICKLINK_MCP_PATH";
                          value = "/mcp";
                        }
                        {
                          # 5000/Tag ist BrickLinks hartes Limit. Der Puffer ist
                          # Absicht: ein Preis-Guide-Sweep über ein großes Inventar
                          # wäre sonst das Tageslimit.
                          name = "BRICKLINK_DAILY_BUDGET";
                          value = "4000";
                        }
                        {
                          name = "BRICKLINK_CATALOG_REFRESH_DAYS";
                          value = "7";
                        }
                        {
                          name = "HOME";
                          value = "/data";
                        }
                        {
                          # Ohne das ruft FastMCP beim Start PyPI an und schreibt eine
                          # „Update available"-Box ins Log (am 2026-08-27 im Pod-Log
                          # gesehen). Ein Dienst, der sonst nur mit BrickLink redet, soll
                          # nicht ungefragt nach draußen telefonieren.
                          name = "FASTMCP_CHECK_FOR_UPDATES";
                          value = "off";
                        }
                        {
                          name = "FASTMCP_SHOW_SERVER_BANNER";
                          value = "false";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/data";
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      readinessProbe = {
                        # /health liegt AUSSERHALB der Auth-Middleware von FastMCP
                        # (additional_http_routes werden nicht in RequireAuthMiddleware
                        # gewickelt) — die Probe braucht deshalb keinen Token.
                        httpGet = {
                          path = "/health";
                          port = 8081;
                        };
                        initialDelaySeconds = 5;
                        periodSeconds = 10;
                        failureThreshold = 6;
                      };
                      resources = {
                        requests = {
                          cpu = "25m";
                          memory = "128Mi";
                        };
                        # 768Mi: im Normalbetrieb reichen ~100 MB, der
                        # Katalog-Neubau parst den Part-Export im Stream und hält
                        # zusätzlich SQLite-Puffer.
                        limits.memory = "768Mi";
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
              name = "bricklink-mcp";
              namespace = "chat";
            };
            spec = {
              selector.app = "bricklink-mcp";
              ports = [
                {
                  name = "http";
                  port = 8081;
                  targetPort = 8081;
                }
              ];
            };
          }
          {
            # Wie bei meridian: sobald eine CNP einen Endpoint selektiert, gilt für
            # dessen Ingress Default-Deny. Nur open-webui darf also hinein — ein
            # Wegwerf-Debug-Pod kommt an Max' Store-Credentials nicht heran.
            # EGRESS bleibt offen: der Dienst spricht api.bricklink.com,
            # www.bricklink.com und account.prod.member.bricklink.info, und eine
            # FQDN-Allowlist würde bei jedem Umbau auf BrickLinks Seite lautlos brechen.
            apiVersion = "cilium.io/v2";
            kind = "CiliumNetworkPolicy";
            metadata = {
              name = "bricklink-mcp-only-from-open-webui";
              namespace = "chat";
            };
            spec = {
              endpointSelector.matchLabels.app = "bricklink-mcp";
              ingress = [
                {
                  fromEndpoints = [
                    {
                      matchLabels = {
                        app = "open-webui";
                        "k8s:io.kubernetes.pod.namespace" = "chat";
                      };
                    }
                  ];
                  toPorts = [
                    {
                      ports = [
                        {
                          port = "8081";
                          protocol = "TCP";
                        }
                      ];
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
