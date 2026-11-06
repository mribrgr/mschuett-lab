{
  lib,
  self,
  ...
}:
let
  # facharbeit.lisa.mauritiusberger.de: private Lernseite für Lisas Facharbeit
  # (Aufgabenpakete, Varianten, Quellen, PDF/Word-Downloads), fürs iPad und Handy.
  #
  # ⚠️ Der Inhalt liegt NICHT im Repo: web/facharbeit-lisa/ steht in .gitignore,
  # weil dieses Repo öffentlich ist und die Seite Lisas Namen, einen Plagiatsbefund
  # und Textbausteine für ihre Abgabe enthält. Der dokumentierte Bauweg (README
  # „Bauen: NICHT auf diesem Node": rsync des Flake-Verzeichnisses + `path:`-Build
  # in der Builder-VM) nimmt den Ordner trotzdem mit. Fehlt er (frischer Clone,
  # `git+file:`-Eval), erzeugt dieses Modul gar nichts — Eval bleibt grün.
  #
  # Ein Pod, zwei Container:
  #   web — nginx: Basic-Auth (htpasswd aus agenix, Benutzer `lisa`), noindex,
  #         statische Seite, /api/ → 127.0.0.1:3000
  #   api — _api.py: Lisas Auswahl/Notizen/Haken als JSON auf der PVC, damit iPad
  #         und Handy denselben Stand sehen; changes.jsonl protokolliert jede Änderung.
  # Icons, Manifest und robots.txt sind ohne Login abrufbar, weil iPadOS sie für
  # „Zum Home-Bildschirm" ohne Zugangsdaten lädt.
  siteDir = self + "/web/facharbeit-lisa";
  hasSite = builtins.pathExists siteDir;
  secretFile = ../../secrets/facharbeit-lisa-htpasswd.age;
  name = "facharbeit-lisa";
  host = "facharbeit.lisa.mauritiusberger.de";
in
{
  flake.modules.nixos.facharbeit-lisa =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      imgs = self.packages.${pkgs.stdenv.hostPlatform.system};
      isServer = config.services.k3s.role == "server";
    in
    lib.mkIf (hasSite && isServer) {
      age.secrets.facharbeit-lisa-htpasswd.file = secretFile;

      # agenix → k8s-Secret, gleiches Muster wie modules/searxng.nix.
      systemd.services.facharbeit-lisa-auth = {
        description = "default/facharbeit-lisa-auth aus agenix rendern";
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
            if k3s kubectl get ns default >/dev/null 2>&1; then ready=yes; break; fi
            sleep 2
          done
          [ -n "$ready" ] || { echo "k3s-API kam in 120s nicht" >&2; exit 1; }

          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
          cp ${config.age.secrets.facharbeit-lisa-htpasswd.path} "$tmp/htpasswd"
          out=$(k3s kubectl create secret generic facharbeit-lisa-auth -n default \
            --from-file=htpasswd="$tmp/htpasswd" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"
          if ! echo "$out" | grep -q 'unchanged'; then
            k3s kubectl -n default rollout restart deploy/${name} || true
          fi
        '';
      };

      # Listener steht in charts/root-app/templates/gateway.yaml (ArgoCD) — wie bei
      # allen *.mauritiusberger.de-Hosts.
      services.k3s.manifests.${name}.content = [
        {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          metadata = {
            name = "${name}-data";
            namespace = "default";
          };
          # local-path ist Default-StorageClass → kein storageClassName nötig.
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = "100Mi";
          };
        }
        {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            inherit name;
            namespace = "default";
          };
          spec = {
            replicas = 1;
            # RWO-Volume + eine Datei als Speicher: nie zwei Pods gleichzeitig.
            # rollingUpdate = null entfernt das Feld aus dem bisher laufenden Objekt —
            # sonst lehnt die API „Recreate" neben alten rollingUpdate-Werten ab.
            strategy = {
              type = "Recreate";
              rollingUpdate = null;
            };
            selector.matchLabels.app = name;
            template = {
              metadata.labels.app = name;
              spec = {
                enableServiceLinks = false;
                securityContext = {
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  runAsNonRoot = true;
                  fsGroup = 65534;
                };
                volumes = [
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                  {
                    name = "auth";
                    secret.secretName = "facharbeit-lisa-auth";
                  }
                  {
                    name = "data";
                    persistentVolumeClaim.claimName = "${name}-data";
                  }
                ];
                containers = [
                  {
                    name = "web";
                    # nix:0 — vom nix-snapshotter aufgelöst; IfNotPresent wie in alibaba.nix.
                    image = imgs.facharbeit-lisa-image.image;
                    imagePullPolicy = "IfNotPresent";
                    ports = [ { containerPort = 8080; } ];
                    volumeMounts = [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                      {
                        name = "auth";
                        mountPath = "/auth";
                        readOnly = true;
                      }
                    ];
                    readinessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = 8080;
                      };
                      periodSeconds = 10;
                    };
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "16Mi";
                      };
                      limits.memory = "64Mi";
                    };
                  }
                  {
                    name = "api";
                    image = imgs.facharbeit-lisa-api-image.image;
                    imagePullPolicy = "IfNotPresent";
                    env = [
                      {
                        name = "DATA_DIR";
                        value = "/data";
                      }
                      {
                        name = "PORT";
                        value = "3000";
                      }
                    ];
                    volumeMounts = [
                      {
                        name = "data";
                        mountPath = "/data";
                      }
                    ];
                    # lauscht nur auf 127.0.0.1 → Probe läuft über den nginx im selben Pod
                    readinessProbe = {
                      httpGet = {
                        path = "/healthz-api";
                        port = 8080;
                      };
                      periodSeconds = 10;
                    };
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "24Mi";
                      };
                      limits.memory = "96Mi";
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
            inherit name;
            namespace = "default";
          };
          spec = {
            selector.app = name;
            ports = [
              {
                protocol = "TCP";
                port = 80;
                targetPort = 8080;
              }
            ];
          };
        }
        {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            inherit name;
            namespace = "default";
          };
          spec = {
            parentRefs = [
              {
                group = "gateway.networking.k8s.io";
                kind = "Gateway";
                name = "main";
                namespace = "default";
              }
            ];
            hostnames = [ host ];
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = "/";
                    };
                  }
                ];
                backendRefs = [
                  {
                    group = "";
                    kind = "Service";
                    inherit name;
                    port = 80;
                    weight = 1;
                  }
                ];
              }
            ];
          };
        }
      ];
    };
}
