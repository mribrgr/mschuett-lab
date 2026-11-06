{
  inputs,
  lib,
  self,
  ...
}:
let
  # facharbeit.lisa.mauritiusberger.de — Images (nix:0) für Web und Speicher.
  # Überblick und Begründungen: cluster.nix.
  siteDir = self + "/web/facharbeit-lisa";
  hasSite = builtins.pathExists siteDir;
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
      image =
        name: entrypoint:
        pkgsSnap.nix-snapshotter.buildImage {
          inherit name;
          resolvedByNix = true;
          config.entrypoint = entrypoint;
        };
      site = lib.cleanSource siteDir;

      # Als Verzeichnisse (destination), nicht als Einzeldateien: nix-snapshotter
      # bindet Store-Pfade als Verzeichnisse ein (vgl. alibaba.nix, 2026-10-29).
      api = pkgs.writeTextFile {
        name = "facharbeit-lisa-api";
        destination = "/api.py";
        text = builtins.readFile ./_api.py;
      };
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
            # Bremse gegen Dauerfeuer auf den Speicher (alle Clients kommen über Envoy).
            limit_req_zone $binary_remote_addr zone=api:1m rate=10r/s;
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
              location = /healthz-api { auth_basic off; access_log off; proxy_pass http://127.0.0.1:3000/health; }
              location ~ ^/(robots\.txt|manifest\.webmanifest|apple-touch-icon\.png|icon-192\.png|icon-512\.png)$ { auth_basic off; }
              # Speicher (Auswahl, Notizen, Haken) — gleicher Login wie die Seite.
              location /api/ {
                limit_req zone=api burst=40 nodelay;
                client_max_body_size 64k;
                proxy_pass http://127.0.0.1:3000;
                proxy_set_header Host $host;
                proxy_read_timeout 10s;
              }
              location / { try_files $uri $uri/ =404; }
            }
          }
        '';
      };
    in
    lib.optionalAttrs hasSite {
      packages.facharbeit-lisa-image = image "facharbeit-lisa" [
        "${pkgs.nginx}/bin/nginx"
        "-c"
        "${nginxConf}/nginx.conf"
        "-e"
        "/dev/stderr"
        "-g"
        "daemon off;"
      ];
      # Nur Python-Standardbibliothek, keine Pakete.
      packages.facharbeit-lisa-api-image = image "facharbeit-lisa-api" [
        "${pkgs.python3}/bin/python3"
        "-I"
        "${api}/api.py"
      ];
    };
}
