{ inputs, self, ... }:
{
  # SearXNG — Meta-Suchmaschine als Websuche-Backend für OpenWebUI.
  #
  # OpenWebUI ruft `/search?q=<query>&format=json` auf; deshalb MUSS `json` in
  # `search.formats` stehen — mit dem Default (nur html) antwortet SearXNG mit 403 und die
  # Websuche bleibt stumm.
  #
  # Nur intern erreichbar: keine HTTPRoute, dazu eine CiliumNetworkPolicy, die Port 8080
  # ausschließlich für den open-webui-Pod öffnet. Eine offene SearXNG-Instanz im Netz wird
  # binnen Tagen für Scraping missbraucht und fliegt bei den Upstream-Suchmaschinen raus.
  #
  # EGRESS bleibt offen — SearXNG muss ja genau nach draußen zu den Suchmaschinen.
  perSystem =
    { pkgs, system, ... }:
    {
      packages.searxng-image =
        let
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          root = pkgs.buildEnv {
            name = "searxng-root";
            paths = [
              pkgs.searxng
              pkgs.coreutils
              pkgs.bashInteractive
              pkgs.curl
              pkgs.gnugrep
              pkgs.cacert
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgsSnap.nix-snapshotter.buildImage {
          name = "searxng";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            # mainProgram des nixpkgs-Pakets; startet die App standalone, ohne uwsgi.
            entrypoint = [ "/bin/searxng-run" ];
            env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          };
        };
    };

  flake.modules.nixos.searxng =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.searxng-image;
      secretFile = ../secrets/searxng-secret.age;

      settingsYaml = ''
        # Auf den Defaults des Pakets aufsetzen, statt die komplette Engine-Liste zu pflegen.
        use_default_settings: true

        # Breit einschalten statt kuratieren. SearXNG merged, was antwortet, und sperrt
        # eine Engine nach einem Fehler von selbst für `suspended_time` (429 → 180 s,
        # Captcha → bis zu 3600 s). Damit entscheidet der Dienst pro Anfrage, wer gerade
        # liefert — es gibt hier bewusst KEINE Liste, die nach Tagesform nachgepflegt wird.
        #
        # Hintergrund: das Default-Profil kennt für `general` nur duckduckgo und google.
        # Beide waren am 2026-08-30 von der netcup-IP tot (Captcha bzw. still 0 Treffer),
        # und die Websuche kam mit LEERER Trefferliste zurück. Deshalb steht hier die
        # Breite — nicht die jeweils gerade funktionierende Auswahl.
        #
        # ⚠️ Einzige Wartung, die bleibt: verschwindet einer dieser Namen upstream, deutet
        # SearXNG den Eintrag als NEUE Engine ohne `engine:`-Feld und der Pod startet nicht
        # mehr. Das scheitert laut (CrashLoopBackOff), nicht still.
        engines:
          - name: bing
            disabled: false
          - name: brave
            disabled: false
          - name: duckduckgo
            disabled: false
          - name: google
            disabled: false
          - name: startpage
            disabled: false
          - name: qwant
            disabled: false
          - name: mojeek
            disabled: false
          - name: yandex
            disabled: false
          - name: seznam
            disabled: false
          - name: yahoo
            disabled: false
          - name: presearch
            disabled: false
          - name: mwmbl
            disabled: false
          - name: wiby
            disabled: false
          - name: encyclosearch
            disabled: false
          - name: wolframalpha
            disabled: false

        general:
          instance_name: "chat"
          debug: false
          # Kein Kontakt-Link: die Instanz ist nicht öffentlich.
          contact_url: false

        server:
          bind_address: "0.0.0.0"
          port: 8080
          # Kein Limiter: der bräuchte valkey/redis, und der einzige Aufrufer ist ein
          # Pod, den die NetworkPolicy schon einschränkt.
          limiter: false
          public_instance: false
          image_proxy: false
          # secret_key kommt über die Env-Var SEARXNG_SECRET aus agenix.

        search:
          # `json` ist für OpenWebUI PFLICHT — ohne das 403 auf jede Suchanfrage.
          formats:
            - html
            - json
          safe_search: 0
          autocomplete: ""
          default_lang: "de"

        ui:
          default_locale: "de"

        outgoing:
          # 4 s statt der 6 s Default: bei breit eingeschalteten Engines bestimmt der
          # LANGSAMSTE Teilnehmer die Antwortzeit, und die toten laufen immer ins Timeout.
          # bing/brave/yandex antworten in unter 2 s — gemessen 2026-08-30: 6 s Timeout
          # ergab 5,2–6,0 s pro Suche, mit 4 s bleibt die Trefferzahl gleich.
          request_timeout: 4.0
          max_request_timeout: 12.0
          pool_connections: 20
      '';
    in
    {
      age.secrets.searxng-secret.file = secretFile;

      systemd.services.searxng-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat/searxng-secrets aus agenix rendern";
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
        restartTriggers = [ (builtins.hashFile "sha256" secretFile) ];
        script = ''
          set -euo pipefail
          ready=""
          for _ in $(seq 1 60); do
            if k3s kubectl get ns chat >/dev/null 2>&1; then ready=yes; break; fi
            sleep 2
          done
          [ -n "$ready" ] || { echo "Namespace chat kam in 120s nicht" >&2; exit 1; }

          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
          printf '%s' "$(cat ${config.age.secrets.searxng-secret.path})" > "$tmp/SEARXNG_SECRET"
          out=$(k3s kubectl create secret generic searxng-secrets -n chat \
            --from-file="$tmp/SEARXNG_SECRET" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"
          if ! echo "$out" | grep -q 'unchanged'; then
            echo "Secret geändert → searxng neu starten"
            k3s kubectl -n chat rollout restart deploy/searxng || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        searxng.content = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "searxng-config";
              namespace = "chat";
            };
            data."settings.yml" = settingsYaml;
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "searxng";
              namespace = "chat";
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels.app = "searxng";
              template = {
                metadata = {
                  labels.app = "searxng";
                  annotations = {
                    "checksum/config" = builtins.hashString "sha256" settingsYaml;
                    "checksum/secret" = builtins.hashFile "sha256" secretFile;
                  };
                };
                spec = {
                  # PFLICHT hier: k8s injiziert für jeden Service im Namespace die alten
                  # Docker-Link-Variablen, darunter SEARXNG_PORT=tcp://10.70.x.y:8080.
                  # SearXNG liest jede SEARXNG_*-Variable als eigene Einstellung und stirbt
                  # daran mit `invalid literal for int(): 'tcp://…'`. Die Links braucht
                  # niemand — im Cluster wird über DNS aufgelöst.
                  enableServiceLinks = false;
                  securityContext = {
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                  };
                  volumes = [
                    {
                      name = "config";
                      configMap.name = "searxng-config";
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                  ];
                  containers = [
                    {
                      name = "searxng";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      # Das Image-Root hat nur /bin und /etc; alles Schreibende nach /tmp.
                      workingDir = "/tmp";
                      ports = [ { containerPort = 8080; } ];
                      env = [
                        {
                          name = "SEARXNG_SETTINGS_PATH";
                          value = "/config/settings.yml";
                        }
                        {
                          # SearXNG liest den Schlüssel aus der Env und überschreibt damit
                          # server.secret_key — so bleibt er aus der ConfigMap heraus.
                          name = "SEARXNG_SECRET";
                          valueFrom.secretKeyRef = {
                            name = "searxng-secrets";
                            key = "SEARXNG_SECRET";
                          };
                        }
                        {
                          name = "HOME";
                          value = "/tmp";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/config";
                          readOnly = true;
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      readinessProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = 8080;
                        };
                        initialDelaySeconds = 10;
                        periodSeconds = 10;
                        failureThreshold = 12;
                      };
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "192Mi";
                        };
                        limits.memory = "512Mi";
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
              name = "searxng";
              namespace = "chat";
            };
            spec = {
              selector.app = "searxng";
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
            apiVersion = "cilium.io/v2";
            kind = "CiliumNetworkPolicy";
            metadata = {
              name = "searxng-only-from-open-webui";
              namespace = "chat";
            };
            spec = {
              endpointSelector.matchLabels.app = "searxng";
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
                          port = "8080";
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
