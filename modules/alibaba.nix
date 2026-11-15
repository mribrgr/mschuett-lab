{
  inputs,
  lib,
  self,
  ...
}:
{
  # Ali Baba Dresden auf netcup, als nix:0-Images (nix-snapshotter).
  #
  #   alibaba-rot.mauritiusberger.de  → web/alibaba-rot/index.html
  #     Design-Vorschau (Claude-Design-Export, „Bundled Page“), darkhttpd.
  #   alibaba-blau.mauritiusberger.de → web/alibaba-staging/
  #     Testumgebung der echten Website, so nah wie möglich am Ziel-Hosting bei KCS
  #     (Plesk: nginx vorne, statische Dateien aus public_html, alles andere an die
  #     Node-App via Passenger). Hier: nginx + Node-App im selben Pod, Mailpit als
  #     SMTP-Senke statt echtem Postausgang. Inhalt = Build-Ausgabe aus
  #     ~/projects/alibaba/website (`STAGING=1 … npm run build`, dann nach
  #     web/alibaba-staging/ kopieren – siehe dortiges docs/staging.md).
  #
  # Gleiche Begründung wie bei steinaberfein.de (siehe modules/steinaberfeinde.nix):
  # ein nix:0-Ref IST ein Store-Pfad und ändert sich mit jedem Inhalt, den ein
  # Helm-Chart in git nicht kennen kann. Deshalb hier als `services.k3s.manifests`
  # statt als ArgoCD-Application. Content liegt IN diesem Repo unter web/, die
  # Version ist also der Git-Commit — kein zweites Repo, kein flake-Input.
  #
  # ⚠️ Bauen in der Builder-VM (README „Bauen: NICHT auf diesem Node“): eine
  # Inhaltsänderung baut das Image neu, und nix-snapshotter fehlt im Store des Nodes –
  # der native Weg „Kleine Änderungen“ hat am 2026-10-28 k3s per Last umgeworfen.
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    let
      # ⚠️ buildImage über eine EIGENE pkgs-Instanz mit dem nix-snapshotter-Overlay,
      # nicht über `inputs.nix-snapshotter.packages.<system>`: das Flake liefert die
      # Pakete nur für x86_64-linux, auf aarch64-netcup gibt es dort nichts. Der
      # Overlay baut nix-snapshotter aus dem Source (Go, portabel) → läuft auf aarch64
      # (gleicher Hinweis wie steinaberfeinde.nix).
      pkgsSnap = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.nix-snapshotter.overlays.default ];
      };
      image =
        name: entrypoint:
        pkgsSnap.nix-snapshotter.buildImage {
          inherit name;
          resolvedByNix = true;
          config.entrypoint = entrypoint;
        };

      # cleanSource, nicht getSrc: getSrc wirft ohne .git-Checkout — und der
      # dokumentierte Netcup-Bauweg rsynct das Flake EXKLUSIV `--exclude .git`
      # (README "Kleine Änderungen"). cleanSource filtert nur, braucht kein Git.
      #
      # darkhttpd statt nginx: rein statisch, ein Binary, keine Config-Datei, kein
      # Worker-User-Drop, keine temp-Verzeichnisse → kleine Closure, wenig was bricht.
      makeSite =
        name:
        image name [
          "${pkgs.darkhttpd}/bin/darkhttpd"
          "${lib.cleanSource (self + "/web/${name}")}"
          "--port"
          "80"
          # Kein Directory-Listing für Verzeichnisse ohne index.html.
          "--no-listing"
        ];

      # Testumgebung: public_html/ + alibaba-app/ wie im KCS-Webspace
      staging = lib.cleanSource (self + "/web/alibaba-staging");

      # nginx bildet nach, was Plesk/Passenger bei KCS tut: vorhandene Dateien aus dem
      # Docroot liefert der Webserver selbst, alles andere (API, alte URLs, 404) geht an
      # die Node-App. Läuft ohne root (Port 8080), alles Schreibende nach /tmp.
      # Als Verzeichnis (destination), nicht als einzelne Datei: nix-snapshotter bindet
      # Store-Pfade als Verzeichnisse ein; ein Datei-Store-Pfad scheitert mit
      # „config-….json: not a directory“ (CreateContainerError, 2026-10-29).
      nginxConf = pkgs.writeTextFile {
        name = "alibaba-staging-nginx";
        destination = "/nginx.conf";
        text = ''
        worker_processes 1;
        pid /tmp/nginx.pid;
        error_log /dev/stderr warn;
        events { worker_connections 256; }
        http {
          include ${pkgs.nginx}/conf/mime.types;
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
          gzip_types text/css text/javascript application/javascript application/json application/xml image/svg+xml text/plain;
          server {
            listen 8080;
            root ${staging}/public_html;
            # Store-Dateien haben alle mtime 1970 → ETag/Last-Modified wären bei gleicher
            # Größe gleich und Browser bekämen veraltete Seiten. Assets tragen Hashes im Namen.
            etag off;
            if_modified_since off;
            add_header Cache-Control "no-cache";
            location ~ /\.(?!well-known) { deny all; }
            location / { try_files $uri $uri/index.html @app; }
            location /api/ { proxy_pass http://127.0.0.1:3000; proxy_set_header Host $http_host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; }
            location @app { proxy_pass http://127.0.0.1:3000; proxy_set_header Host $http_host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; }
          }
        }
        '';
      };
    in
    {
      packages.alibaba-rot-image = makeSite "alibaba-rot";
      packages.alibaba-staging-web-image = image "alibaba-staging-web" [
        "${pkgs.nginx}/bin/nginx"
        "-c"
        "${nginxConf}/nginx.conf"
        "-e"
        "/dev/stderr"
        "-g"
        "daemon off;"
      ];
      # Node 22 statt der bei KCS vorausgewählten 16.20.2 (EOL, nicht mehr in nixpkgs).
      # app.js ist auf Node 16 gebaut und dort lokal getestet; Ziel bei KCS: 22 oder neuer.
      packages.alibaba-staging-app-image = image "alibaba-staging-app" [
        "${pkgs.nodejs_22}/bin/node"
        "${staging}/alibaba-app/app.js"
      ];
      packages.alibaba-mailpit-image = image "alibaba-mailpit" [
        "${pkgs.mailpit}/bin/mailpit"
        "--smtp"
        "0.0.0.0:1025"
        "--listen"
        "0.0.0.0:8025"
        "--smtp-auth-accept-any"
        "--smtp-auth-allow-insecure"
        "--database"
        "/tmp/mailpit.db"
        "--max"
        "1000"
      ];
    };

  # ── Auslieferung per k3s-Manifest (NICHT ArgoCD) ─────────────────────────────
  # Begründung oben: der nix:0-Ref ist ein Store-Pfad, den nur nix kennt. Durch die
  # String-Interpolation des Image-Derivats landet der Image-Tar automatisch in der
  # System-Closure des Nodes — kein extraDependencies nötig.
  #
  # Der TLS-Listener pro Host steht NICHT hier, sondern in
  # charts/root-app/templates/gateway.yaml (ArgoCD-Quelle) — wie bei allen übrigen
  # *.mauritiusberger.de-Hosts. Beide Seiten (Listener + Route) liegen im selben
  # Repo, gehen aber über zwei Quellen live (Flake → k3s, Chart → ArgoCD). Für einen
  # NEUEN Host ohne Bestand gibt es kein Reihenfolge-Problem: die HTTPRoute hängt
  # kurz ins Leere, bis der Listener da ist — die Seite ist dann erst erreichbar,
  # wenn beides steht.
  flake.modules.nixos.alibaba =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      imgs = self.packages.${pkgs.stdenv.hostPlatform.system};

      # HTTPRoute für einen Host auf den gleichnamigen Service (Port 80). group/kind/weight
      # explizit (wie in der NJD-HTTPRoute), damit der Diff gegen das Live-Objekt sauber
      # bleibt und ServerSideApply keine Defaults als Drift meldet.
      route = name: host: {
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
      };

      service = name: selector: ports: {
        apiVersion = "v1";
        kind = "Service";
        metadata = {
          inherit name;
          namespace = "default";
        };
        spec = {
          selector.app = selector;
          inherit ports;
        };
      };

      deployment = name: podSpec: {
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
            spec = podSpec;
          };
        };
      };

      # nix:0 — vom nix-snapshotter aufgelöst, kein Registry-Pull.
      # IfNotPresent, NICHT Never (ErrImageNeverPull, vgl. steinaberfeinde.nix).
      container = img: attrs: {
        image = img.image;
        imagePullPolicy = "IfNotPresent";
      } // attrs;

      tmpVolume = name: {
        inherit name;
        emptyDir = { };
      };
      nonRoot = {
        runAsUser = 65534;
        runAsGroup = 65534;
        runAsNonRoot = true;
      };

      rot = [
        (deployment "alibaba-rot" {
          containers = [
            (container imgs.alibaba-rot-image {
              name = "alibaba-rot";
              ports = [ { containerPort = 80; } ];
            })
          ];
        })
        (service "alibaba-rot" "alibaba-rot" [
          {
            protocol = "TCP";
            port = 80;
            targetPort = 80;
          }
        ])
        (route "alibaba-rot" "alibaba-rot.mauritiusberger.de")
      ];

      blau = [
        (deployment "alibaba-blau" {
          enableServiceLinks = false;
          securityContext = nonRoot;
          volumes = [
            (tmpVolume "tmp-web")
            (tmpVolume "tmp-app")
          ];
          containers = [
            (container imgs.alibaba-staging-web-image {
              name = "web";
              ports = [ { containerPort = 8080; } ];
              volumeMounts = [
                {
                  name = "tmp-web";
                  mountPath = "/tmp";
                }
              ];
              readinessProbe = {
                httpGet = {
                  path = "/";
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
            })
            (container imgs.alibaba-staging-app-image {
              name = "app";
              ports = [ { containerPort = 3000; } ];
              env = lib.mapAttrsToList (name: value: { inherit name value; }) {
                PORT = "3000";
                HOME = "/tmp";
                SMTP_HOST = "alibaba-mailpit";
                SMTP_PORT = "1025";
                SMTP_IGNORE_TLS = "true";
                SUBJECT_PREFIX = "[STAGING] ";
              };
              volumeMounts = [
                {
                  name = "tmp-app";
                  mountPath = "/tmp";
                }
              ];
              readinessProbe = {
                httpGet = {
                  path = "/api/health";
                  port = 3000;
                };
                periodSeconds = 10;
              };
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "48Mi";
                };
                limits.memory = "192Mi";
              };
            })
          ];
        })
        (service "alibaba-blau" "alibaba-blau" [
          {
            protocol = "TCP";
            port = 80;
            targetPort = 8080;
          }
        ])
        (route "alibaba-blau" "alibaba-blau.mauritiusberger.de")

        # Mailpit: fängt alle Mails der Testumgebung ab. Oberfläche nur per
        #   kubectl -n default port-forward svc/alibaba-mailpit 8025:8025
        (deployment "alibaba-mailpit" {
          enableServiceLinks = false;
          securityContext = nonRoot;
          volumes = [ (tmpVolume "tmp") ];
          containers = [
            (container imgs.alibaba-mailpit-image {
              name = "mailpit";
              ports = [
                { containerPort = 1025; }
                { containerPort = 8025; }
              ];
              volumeMounts = [
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "24Mi";
                };
                limits.memory = "128Mi";
              };
            })
          ];
        })
        (service "alibaba-mailpit" "alibaba-mailpit" [
          {
            name = "smtp";
            protocol = "TCP";
            port = 1025;
            targetPort = 1025;
          }
          {
            name = "ui";
            protocol = "TCP";
            port = 8025;
            targetPort = 8025;
          }
        ])
      ];
    in
    {
      # `services.k3s.manifests` ist `lazyAttrsOf (submoduleOf …)`: jeder Key ein
      # Modul mit `.content = [ Doku; … ]` — genau wie steinaberfeinde/gatus.
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        alibaba-rot.content = rot;
        alibaba-blau.content = blau;
      };
    };
}
