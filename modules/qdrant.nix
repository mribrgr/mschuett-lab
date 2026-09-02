{ inputs, self, ... }:
{
  # Qdrant — Vektorspeicher für OpenWebUIs RAG UND für das Memory-System.
  #
  # Warum überhaupt statt des eingebauten chroma: chroma liegt in derselben PVC wie
  # open-webui und wird bei jedem Pod-Start mit dem Prozess geteilt. Qdrant ist ein eigener
  # Dienst mit eigener PVC, hält den HNSW-Index auf der Platte statt im RAM
  # (`QDRANT_ON_DISK`) und übersteht ein Zurücksetzen von open-webui. Für Memories, die
  # über Monate wachsen sollen, ist das der Unterschied zwischen „Beiwerk" und „Speicher".
  #
  # ⚠️ Der Wechsel des VECTOR_DB ist NICHT migrierend: bereits in chroma eingebettete
  # Dokumente und Memories sind in Qdrant nicht vorhanden und müssen neu indexiert werden
  # (Dokument erneut hochladen bzw. Memory erneut speichern). Am 2026-08-27 war das
  # unkritisch — es gab noch keine Wissensbasis.
  #
  # Nur intern: keine HTTPRoute, CiliumNetworkPolicy nur für open-webui, dazu ein API-Key
  # aus agenix als zweite Schicht.
  perSystem =
    { pkgs, system, ... }:
    {
      packages.qdrant-image =
        let
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          root = pkgs.buildEnv {
            name = "qdrant-root";
            paths = [
              pkgs.qdrant
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
          name = "qdrant";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [ "/bin/qdrant" ];
            env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgsSnap.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          };
        };
    };

  flake.modules.nixos.qdrant =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.qdrant-image;
      secretFile = ../secrets/qdrant-api-key.age;
    in
    {
      age.secrets.qdrant-api-key.file = secretFile;

      # Ein Secret, zwei Konsumenten: qdrant prüft den Key, open-webui schickt ihn.
      # modules/openwebui.nix liest dieselbe age-Datei für QDRANT_API_KEY.
      systemd.services.qdrant-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat/qdrant-secrets aus agenix rendern";
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
          printf '%s' "$(cat ${config.age.secrets.qdrant-api-key.path})" > "$tmp/QDRANT_API_KEY"
          out=$(k3s kubectl create secret generic qdrant-secrets -n chat \
            --from-file="$tmp/QDRANT_API_KEY" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"
          if ! echo "$out" | grep -q 'unchanged'; then
            # Reihenfolge: erst qdrant (prüft den Key), dann open-webui (schickt ihn).
            echo "Secret geändert → qdrant, dann open-webui neu starten"
            k3s kubectl -n chat rollout restart deploy/qdrant || true
            k3s kubectl -n chat rollout status deploy/qdrant --timeout=180s || \
              echo "WARNUNG: qdrant-Rollout nicht bestätigt" >&2
            k3s kubectl -n chat rollout restart deploy/open-webui || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        qdrant.content = [
          {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "qdrant-data";
              namespace = "chat";
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "8Gi";
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "qdrant";
              namespace = "chat";
            };
            spec = {
              replicas = 1;
              # Recreate: eine RWO-PVC, und zwei Qdrant-Prozesse auf demselben Storage
              # wären Datenkorruption.
              strategy.type = "Recreate";
              selector.matchLabels.app = "qdrant";
              template = {
                metadata = {
                  labels.app = "qdrant";
                  annotations."checksum/secret" = builtins.hashFile "sha256" secretFile;
                };
                spec = {
                  # Gleiche Vorsichtsmaßnahme wie bei searxng: die Docker-Link-Variablen
                  # (QDRANT_PORT=tcp://…) kollidieren hier heute nicht, weil Qdrant seine
                  # Einstellungen mit doppeltem Unterstrich liest — aber niemand braucht sie.
                  enableServiceLinks = false;
                  securityContext = {
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                  };
                  volumes = [
                    {
                      name = "data";
                      persistentVolumeClaim.claimName = "qdrant-data";
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                  ];
                  containers = [
                    {
                      name = "qdrant";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      workingDir = "/data";
                      ports = [
                        { containerPort = 6333; }
                        { containerPort = 6334; }
                      ];
                      # Qdrant nimmt jede Einstellung als QDRANT__<SEKTION>__<KEY> — damit
                      # braucht es keine config.yaml und der Zustand bleibt in der Env.
                      env = [
                        {
                          name = "QDRANT__SERVICE__HOST";
                          value = "0.0.0.0";
                        }
                        {
                          name = "QDRANT__STORAGE__STORAGE_PATH";
                          value = "/data/storage";
                        }
                        {
                          name = "QDRANT__STORAGE__SNAPSHOTS_PATH";
                          value = "/data/snapshots";
                        }
                        {
                          name = "QDRANT__TELEMETRY_DISABLED";
                          value = "true";
                        }
                        {
                          name = "QDRANT__SERVICE__API_KEY";
                          valueFrom.secretKeyRef = {
                            name = "qdrant-secrets";
                            key = "QDRANT_API_KEY";
                          };
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
                        # /readyz ist ohne API-Key erreichbar; /collections wäre es nicht.
                        httpGet = {
                          path = "/readyz";
                          port = 6333;
                        };
                        initialDelaySeconds = 5;
                        periodSeconds = 10;
                        failureThreshold = 12;
                      };
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "256Mi";
                        };
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
              name = "qdrant";
              namespace = "chat";
            };
            spec = {
              selector.app = "qdrant";
              ports = [
                {
                  name = "http";
                  port = 6333;
                  targetPort = 6333;
                }
                {
                  name = "grpc";
                  port = 6334;
                  targetPort = 6334;
                }
              ];
            };
          }
          {
            apiVersion = "cilium.io/v2";
            kind = "CiliumNetworkPolicy";
            metadata = {
              name = "qdrant-only-from-open-webui";
              namespace = "chat";
            };
            spec = {
              endpointSelector.matchLabels.app = "qdrant";
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
                          port = "6333";
                          protocol = "TCP";
                        }
                        {
                          port = "6334";
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
