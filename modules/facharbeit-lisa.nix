{
  inputs,
  lib,
  self,
  ...
}:
let
  # facharbeit.lisa.mauritiusberger.de: private Lernseite für Lisas Facharbeit
  # (Aufgabenpakete, Varianten, Quellen, PDF/Word-Downloads), fürs iPad gebaut.
  #
  # ⚠️ Der Inhalt liegt NICHT im Repo: web/facharbeit-lisa/ steht in .gitignore,
  # weil dieses Repo öffentlich ist und die Seite Lisas Namen, einen Plagiatsbefund
  # und Textbausteine für ihre Abgabe enthält. Der dokumentierte Bauweg (README
  # „Bauen: NICHT auf diesem Node": rsync des Flake-Verzeichnisses + `path:`-Build
  # in der Builder-VM) nimmt den Ordner trotzdem mit. Fehlt er (frischer Clone,
  # `git+file:`-Eval), erzeugt dieses Modul gar nichts — Eval bleibt grün.
  #
  # Schutz: Basic-Auth im nginx (htpasswd aus agenix, Benutzer `lisa`) plus
  # noindex/robots-Sperre, damit weder Suchmaschinen noch Plagiats-Crawler den
  # Text sehen. Icons, Manifest und robots.txt sind ohne Login abrufbar, weil
  # iPadOS sie für „Zum Home-Bildschirm" ohne Zugangsdaten lädt.
  siteDir = self + "/web/facharbeit-lisa";
  hasSite = builtins.pathExists siteDir;
  secretFile = ../secrets/facharbeit-lisa-htpasswd.age;
in
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    let
      # Gleiches Snapshotter-Overlay wie in alibaba.nix (aarch64-netcup).
      pkgsSnap = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.nix-snapshotter.overlays.default ];
      };
      site = lib.cleanSource siteDir;

      # Als Verzeichnis (destination), nicht als Datei: nix-snapshotter bindet
      # Store-Pfade als Verzeichnisse ein (vgl. alibaba.nix, 2026-10-29).
      nginxConf = pkgs.writeTextFile {
        name = "facharbeit-lisa-nginx";
        destination = "/nginx.conf";
        text = ''
          worker_processes 1;
          pid /tmp/nginx.pid;
          error_log /dev/stderr warn;
          events { worker_connections 256; }
          http {
            include ${pkgs.nginx}/conf/mime.types;
            types { application/manifest+json webmanifest; }
            default_type application/octet-stream;
            access_log /dev/stdout;
            client_body_temp_path /tmp/client_body;
            proxy_temp_path /tmp/proxy;
            fastcgi_temp_path /tmp/fastcgi;
            uwsgi_temp_path /tmp/uwsgi;
            scgi_temp_path /tmp/scgi;
            server_tokens off;
            sendfile on;
            gzip on;
            gzip_types text/css text/javascript application/javascript application/json application/manifest+json text/plain;
            server {
              listen 8080;
              root ${site};
              # Store-Dateien haben mtime 1970 → ohne das bekäme das iPad veraltete Seiten.
              etag off;
              if_modified_since off;
              add_header Cache-Control "no-cache" always;
              add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
              add_header Referrer-Policy "no-referrer" always;
              add_header X-Content-Type-Options "nosniff" always;
              auth_basic "Facharbeit Lisa";
              auth_basic_user_file /auth/htpasswd;
              location ~ /\. { deny all; }
              location = /healthz { auth_basic off; access_log off; default_type text/plain; return 200 "ok\n"; }
              location ~ ^/(robots\.txt|manifest\.webmanifest|apple-touch-icon\.png|icon-192\.png|icon-512\.png)$ { auth_basic off; }
              location / { try_files $uri $uri/ =404; }
            }
          }
        '';
      };
    in
    lib.optionalAttrs hasSite {
      packages.facharbeit-lisa-image = pkgsSnap.nix-snapshotter.buildImage {
        name = "facharbeit-lisa";
        resolvedByNix = true;
        config.entrypoint = [
          "${pkgs.nginx}/bin/nginx"
          "-c"
          "${nginxConf}/nginx.conf"
          "-e"
          "/dev/stderr"
          "-g"
          "daemon off;"
        ];
      };
    };

  flake.modules.nixos.facharbeit-lisa =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      name = "facharbeit-lisa";
      host = "facharbeit.lisa.mauritiusberger.de";
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
      # allen *.mauritiusberger.de-Hosts; die Route hängt bis dahin kurz ins Leere.
      services.k3s.manifests.${name}.content = [
        {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            inherit name;
            namespace = "default";
          };
          spec = {
            replicas = 1;
            selector.matchLabels.app = name;
            template = {
              metadata.labels.app = name;
              spec = {
                enableServiceLinks = false;
                securityContext = {
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  runAsNonRoot = true;
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
                ];
                containers = [
                  {
                    inherit name;
                    # nix:0 — vom nix-snapshotter aufgelöst; IfNotPresent wie in alibaba.nix.
                    image = self.packages.${pkgs.stdenv.hostPlatform.system}.facharbeit-lisa-image.image;
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
