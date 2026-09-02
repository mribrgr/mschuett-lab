{ inputs, self, ... }:
{
  # BrickLink-MCP — Verwaltung MEHRERER BrickLink-Shops aus dem Chat.
  #
  # Ziel (2026-08-27 festgelegt): mschuett verwaltet SteinAberFein über
  # chat.mauritiusberger.de und braucht die BrickLink-Web-UI langfristig nicht mehr;
  # mberger verwaltet dinoland über denselben Weg.
  #
  # ── SHOP-TRENNUNG IST DIE WICHTIGSTE EIGENSCHAFT ──────────────────────────────
  # Jeder Shop hat sein EIGENES agenix-Secret mit eigenem Consumer-/Token-Paar und
  # eigenem BL-Benutzernamen. Der Server kennt keinen „aktuellen Shop": jedes
  # store-bezogene Tool nimmt einen `store`-Parameter, und ohne eindeutigen Shop
  # lehnt es ab, statt zu raten. Zusätzlich prüft jeder SCHREIBENDE Aufruf, dass
  # `seller_name` der Bestellung zum Benutzernamen des gewählten Shops passt — ein
  # falscher Shop schreibt damit nichts, selbst wenn das Modell sich vertut.
  #
  # `userDefaults` unten bestimmt, welcher Shop gilt, wenn der Nutzer keinen nennt.
  # Das funktioniert NUR, wenn OpenWebUI die Nutzer-Header mitschickt
  # (`ENABLE_FORWARD_USER_INFO_HEADERS = "True"` in modules/openwebui.nix). Ohne sie
  # verlangt der Server bei jedem Aufruf eine ausdrückliche Shop-Angabe — was
  # funktional in Ordnung, aber im Gespräch lästig ist.
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
          # ── Dateiserver-Sidecar ────────────────────────────────────────────────
          # Ausliefern übernimmt nginx, NICHT der MCP-Prozess: der bleibt vom Internet
          # getrennt (die CiliumNetworkPolicy öffnet 8081 nur für open-webui). nginx
          # kennt genau ein Verzeichnis, lesend, ohne Index — und prüft vorher
          # Signatur und Ablaufdatum des Links (ngx_http_secure_link_module).
          #
          # Die Config wird beim Start nach /tmp gerendert, weil das Geheimnis dort
          # eingesetzt wird. In eine ConfigMap gehört es nicht (die ist im Klartext für
          # jeden lesbar, der `get configmap` darf), und nginx kann keine Env-Variablen
          # in der Config auflösen.
          filesServer = pkgsBl.writeShellScriptBin "bricklink-files-server" ''
            set -euo pipefail
            if [ -z "''${BRICKLINK_FILES_SECRET:-}" ]; then
              echo "BRICKLINK_FILES_SECRET fehlt — ohne Geheimnis würde jeder Link gelten. Abbruch." >&2
              exit 1
            fi
            mkdir -p /tmp/nginx/body /tmp/nginx/logs
            cat > /tmp/nginx/nginx.conf.tmpl <<'CONF'
            worker_processes 1;
            daemon off;
            error_log /dev/stderr warn;
            pid /tmp/nginx/nginx.pid;
            events { worker_connections 64; }
            http {
              include ${pkgsBl.nginx}/conf/mime.types;
              default_type application/octet-stream;
              access_log /dev/stdout combined;
              client_body_temp_path /tmp/nginx/body;
              proxy_temp_path /tmp/nginx/proxy;
              fastcgi_temp_path /tmp/nginx/fastcgi;
              uwsgi_temp_path /tmp/nginx/uwsgi;
              scgi_temp_path /tmp/nginx/scgi;
              sendfile on;
              server_tokens off;
              server {
                listen 8082;
                # Probe-Endpunkt ohne Signatur. Verrät nichts: keine Dateinamen, kein Inhalt.
                location = /bricklink-exports/healthz {
                  access_log off;
                  return 200 "ok\n";
                }
                location /bricklink-exports/ {
                  secure_link $arg_md5,$arg_expires;
                  # ⚠️ ''${uri} MUSS geklammert sein. Ohne Klammern klebt das eingesetzte
                  # Geheimnis am Variablennamen und nginx stirbt beim Start mit
                  # „unknown \"uri<geheimnis>\" variable" (am 2026-08-27 genau so
                  # passiert — und das Geheimnis stand dabei im Pod-Log).
                  secure_link_md5 "$secure_link_expires''${uri}@SECRET@";
                  # Leer = Signatur falsch -> 404 (nicht 403: die Existenz einer Datei
                  # soll ein falscher Link nicht bestätigen). "0" = abgelaufen -> 410.
                  if ($secure_link = "") { return 404; }
                  if ($secure_link = "0") { return 410; }
                  limit_except GET HEAD { deny all; }
                  autoindex off;
                  alias /data/exports/;
                  add_header Content-Disposition "attachment" always;
                  add_header X-Content-Type-Options "nosniff" always;
                  add_header Cache-Control "private, no-store" always;
                  add_header Referrer-Policy "no-referrer" always;
                }
                # Ergebnisse der Code-Sandbox. Eigener Präfix, damit `alias` NICHT
                # auf /data zeigt — dort liegen auch state.db und catalog.db, und die
                # haben im Netz nichts zu suchen.
                location /bricklink-workspace/ {
                  secure_link $arg_md5,$arg_expires;
                  secure_link_md5 "$secure_link_expires''${uri}@SECRET@";
                  if ($secure_link = "") { return 404; }
                  if ($secure_link = "0") { return 410; }
                  limit_except GET HEAD { deny all; }
                  autoindex off;
                  alias /data/workspace/;
                  add_header Content-Disposition "attachment" always;
                  add_header X-Content-Type-Options "nosniff" always;
                  add_header Cache-Control "private, no-store" always;
                  add_header Referrer-Policy "no-referrer" always;
                }
                location / { return 404; }
              }
            }
            CONF
            ${pkgsBl.gnused}/bin/sed "s|@SECRET@|$BRICKLINK_FILES_SECRET|" \
              /tmp/nginx/nginx.conf.tmpl > /tmp/nginx/nginx.conf
            rm -f /tmp/nginx/nginx.conf.tmpl
            # -e: nginx öffnet das Standard-Fehlerlog (/var/log/nginx/error.log) BEVOR es
            # die Config liest — im nix:0-Image gibt es das nicht, das ergibt bei jedem
            # Start einen Alert. Mit -e zeigt es von Anfang an auf stderr.
            exec ${pkgsBl.nginx}/bin/nginx -c /tmp/nginx/nginx.conf -p /tmp/nginx -e /dev/stderr
          '';

          root = pkgsBl.buildEnv {
            name = "bricklink-mcp-root";
            paths = [
              app
              filesServer
              pkgsBl.nginx
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

      # ── Code-Sandbox (Jupyter) ────────────────────────────────────────────────
      # OpenWebUIs Code-Interpreter kann zwei Motoren: `pyodide` läuft im BROWSER,
      # `jupyter` gegen einen echten Kernel. Bis 2026-09-02 lief hier pyodide, und das
      # hatte zwei harte Grenzen, an denen mschuett hängengeblieben ist:
      #   * keine PDF-Bibliotheken — „In dieser Umgebung stehen keine PDF-Bibliotheken
      #     zur Verfügung" (sein Chat zur Mieterselbstauskunft), und pyodide verbietet
      #     Nachinstallieren ausdrücklich,
      #   * erzeugte Dateien landen in `/mnt/uploads` — das ist eine IndexedDB IM
      #     BROWSER (src/lib/workers/pyodide.worker.ts), nicht der Server. Deshalb kam
      #     niemand an die Dateien.
      # Ein eigenes Image löst beides: fette Bibliotheksauswahl, echtes Dateisystem.
      #
      # Der Container läuft im SELBEN Pod wie der MCP. Das ist keine Bequemlichkeit,
      # sondern der Grund, warum es überhaupt geht: das Daten-PVC ist ReadWriteOnce,
      # zwei Pods würden sich um den Mount streiten. So teilen MCP, Dateiserver und
      # Sandbox denselben Mount — und die Dateien der Sandbox sind über dieselben
      # signierten Links abrufbar wie die BrickLink-Exporte.
      packages.bricklink-sandbox-image =
        let
          pkgsSb = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          # Was hier NICHT drin ist, kann das Modell auch nicht nachinstallieren: ein
          # nix-Python-Env ist unveränderlich. Deshalb bewusst großzügig — die Liste
          # deckt PDF (lesen, schreiben, Formulare, Rendern), Tabellen, Diagramme,
          # Office-Formate und HTTP ab.
          pyEnv = pkgsSb.python3.withPackages (ps: [
            ps.jupyter-server
            ps.ipykernel
            # PDF
            ps.pypdf
            ps.pikepdf
            ps.pdfplumber
            ps.pymupdf
            ps.reportlab
            # Daten und Darstellung
            ps.pandas
            ps.numpy
            ps.matplotlib
            ps.openpyxl
            ps.tabulate
            # Sonstiges
            ps.python-docx
            ps.pillow
            ps.lxml
            ps.beautifulsoup4
            ps.requests
          ]);
          start = pkgsSb.writeShellScriptBin "bricklink-sandbox" ''
            set -euo pipefail
            if [ -z "''${SANDBOX_TOKEN:-}" ]; then
              echo "SANDBOX_TOKEN fehlt — ein Kernel ohne Token wäre für jeden im Pod-Netz offen. Abbruch." >&2
              exit 1
            fi
            mkdir -p /data/workspace
            cd /data/workspace
            # --ServerApp.disable_check_xsrf: OpenWebUI schickt das Token als
            # QUERY-Parameter (utils/code_interpreter.py: `params={'token': …}`) und
            # keinen XSRF-Header. Ohne das Flag lehnt jupyter-server POST api/kernels ab.
            # Der Dienst ist ausschließlich aus dem open-webui-Pod erreichbar (CNP),
            # deshalb ist das hier vertretbar.
            exec ${pyEnv}/bin/jupyter-server \
              --ServerApp.ip=0.0.0.0 \
              --ServerApp.port=8888 \
              --ServerApp.token="$SANDBOX_TOKEN" \
              --ServerApp.password="" \
              --ServerApp.open_browser=False \
              --ServerApp.allow_remote_access=True \
              --ServerApp.disable_check_xsrf=True \
              --ServerApp.root_dir=/data/workspace \
              --ServerApp.log_level=WARN
          '';
          root = pkgsSb.buildEnv {
            name = "bricklink-sandbox-root";
            paths = [
              start
              pyEnv
              pkgsSb.coreutils
              pkgsSb.bashInteractive
              pkgsSb.gnugrep
              pkgsSb.gnused
              # Schriften: ohne sie zeichnet matplotlib Kästchen statt Buchstaben.
              pkgsSb.dejavu_fonts
              pkgsSb.cacert
            ];
            pathsToLink = [
              "/bin"
              "/etc"
              "/share"
              "/lib"
            ];
          };
        in
        pkgsSb.nix-snapshotter.buildImage {
          name = "bricklink-sandbox";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [ "/bin/bricklink-sandbox" ];
            env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgsSb.cacert}/etc/ssl/certs/ca-bundle.crt"
              "REQUESTS_CA_BUNDLE=${pkgsSb.cacert}/etc/ssl/certs/ca-bundle.crt"
              # HOME muss beschreibbar sein: jupyter legt Runtime-Dateien an, und
              # matplotlib braucht ein Cache-Verzeichnis (sonst Warnung bei jedem Import).
              "HOME=/data/workspace"
              "MPLCONFIGDIR=/data/workspace/.matplotlib"
              "MPLBACKEND=Agg"
              "JUPYTER_RUNTIME_DIR=/tmp/jupyter"
            ];
            workingdir = "/data/workspace";
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
      sandboxImg = self.packages.${pkgs.stdenv.hostPlatform.system}.bricklink-sandbox-image;

      # EINZIGE Quelle dafür, welche Shops es gibt. Reihenfolge = Reihenfolge in
      # Aufzählungen, die der Chat dem Nutzer vorlegt.
      #
      # `slug` ist der stabile Schlüssel (Tool-Parameter, Env-Präfix, Name der
      # age-Datei, Kontingentzähler). `label` ist der Anzeigename. Der
      # BL-BENUTZERNAME steht NICHT hier, sondern im Secret des Shops — er gehört
      # zu den Credentials und wird gegen `seller_name` geprüft.
      stores = [
        {
          slug = "steinaberfein";
          label = "SteinAberFein";
          # Das 30-Tage-Web-Token für die XML-Exporte liegt historisch in einer eigenen
          # Datei — und es GEHÖRT Max' Konto (am 2026-08-27 verifiziert: die Wanted-Seite
          # meldet `username = 'SteinAberFein'`). Deshalb wird es genau diesem Shop
          # zugeordnet. Bei neuen Shops gehört das Token als WEB_TOKEN ins Shop-Secret.
          hasSeparateWebToken = true;
        }
        {
          # ⚠️ Shopname und BL-KONTO sind hier verschieden: der Shop heißt „Dinoland",
          # das Verkäuferkonto `dinoliebe` (https://store.bricklink.com/dinoliebe).
          # Der Slug folgt dem Shopnamen, weil im Chat davon geredet wird; der
          # Kontoname steht als USERNAME im Secret und ist der Guard gegen
          # Shop-Verwechslung. Aufgelöst wird BEIDES — `store="dinoland"` genauso wie
          # `store="dinoliebe"`.
          slug = "dinoland";
          label = "Dinoland";
        }
      ];

      # Welcher Shop gilt, wenn der Nutzer keinen nennt. Schlüssel ist die
      # OpenWebUI-E-Mail (aus kanidm), zusätzlich der Anzeigename als Fallback.
      # Am 2026-08-27 aus der OpenWebUI-DB gelesen.
      userDefaults = {
        "steinaberfeinbl@gmail.com" = "steinaberfein";
        "Max Schütt" = "steinaberfein";
        "mauritius.berger@develappers.de" = "dinoland";
        "Mauritius Berger" = "dinoland";
      };

      storeSecret = store: ./../secrets + "/bricklink-api-${store.slug}.age";
      webTokenFile = ./../secrets/bricklink-web-token.age;
      bearerFile = ./../secrets/bricklink-mcp-bearer.age;
      # Signierschlüssel für die Download-Links. Zufällig erzeugt, kein Wert von
      # BrickLink — Rotation heißt: neu erzeugen, deployen, alte Links sind sofort tot.
      filesSecretFile = ./../secrets/bricklink-files-secret.age;
      # Token des Jupyter-Kernels. Wird von ZWEI Seiten gebraucht: der Sandbox-Container
      # startet damit, und OpenWebUI authentifiziert sich damit (modules/openwebui.nix
      # liest denselben agenix-Pfad).
      sandboxTokenFile = ./../secrets/bricklink-sandbox-token.age;

      # Unter dieser Adresse liefert der nginx-Sidecar aus. Die Listener für beide
      # chat-Hostnamen existieren bereits (charts/root-app/templates/gateway.yaml), es
      # braucht also KEINE Chart-Änderung — nur die HTTPRoute unten. Pfad-Präfix statt
      # eigenem Hostnamen, weil ein neuer Hostname einen neuen Listener UND ein neues
      # Zertifikat gebraucht hätte (und das liegt im gepushten Chart-Repo).
      filesHosts = [
        "chat.steinaberfein.de"
        "chat.mauritiusberger.de"
      ];
      filesPath = "/bricklink-exports/";
      # Zweiter Präfix: Ergebnisse der Code-Sandbox. Getrennt von den Exporten, weil
      # nginx pro Präfix genau ein Verzeichnis freigibt — /data selbst darf nie
      # freigegeben werden, dort liegen state.db und catalog.db.
      filesWorkspacePath = "/bricklink-workspace/";
      filesBaseUrl = "https://${builtins.head filesHosts}";

      credentialHash = builtins.concatStringsSep "-" (
        map (f: builtins.hashFile "sha256" f) (
          (map storeSecret stores)
          ++ [
            webTokenFile
            bearerFile
            filesSecretFile
            sandboxTokenFile
          ]
        )
      );
    in
    {
      age.secrets = {
        bricklink-web-token.file = webTokenFile;
        bricklink-mcp-bearer.file = bearerFile;
        bricklink-files-secret.file = filesSecretFile;
        bricklink-sandbox-token.file = sandboxTokenFile;
      }
      // lib.listToAttrs (
        map (store: {
          name = "bricklink-api-${store.slug}";
          value.file = storeSecret store;
        }) stores
      );

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
                    # ⚠️ NICHT `--from-env-file` für die dotenv-Dateien und daneben `--from-file`
                    # für die Einzelwerte: kubectl lehnt die Kombination ab
                    #   „error: from-env-file cannot be combined with from-file or from-literal"
                    # (am 2026-08-27 genau so im Journal gelandet, Unit lief in den Restart-Loop).
                    # Deshalb werden die dotenv-Dateien hier selbst zerlegt.
                    #
                    # printf '%s' statt cat: schluckt das abschließende Newline. Mit Newline im Wert
                    # wäre die OAuth-Signatur falsch und BrickLink antwortet 401.
                    #
                    # Pro Shop wird jeder Schlüssel auf BRICKLINK_STORE_<SLUG>_<KEY> abgebildet.
                    # Die Secret-Datei selbst kennt den Shop NICHT — sie enthält nur
                    # CONSUMER_KEY/CONSUMER_SECRET/TOKEN_VALUE/TOKEN_SECRET/USERNAME (ein
                    # führendes BRICKLINK_ bzw. BRICKLINK_STORE_ wird abgeschnitten, damit die
                    # Datei aus der Ein-Shop-Zeit unverändert weiterfunktioniert).
                    render_store() {
                      slug_upper=$1
                      file=$2
                      while IFS= read -r line; do
                        case "$line" in ""|"#"*) continue ;; esac
                        key=''${line%%=*}
                        value=''${line#*=}
                        key=''${key#BRICKLINK_}
                        key=''${key#STORE_}
                        case "$key" in
                          CONSUMER_KEY|CONSUMER_SECRET|TOKEN_VALUE|TOKEN_SECRET|USERNAME|WEB_TOKEN) ;;
                          *) echo "unbekannter Schlüssel übersprungen ($slug_upper): $key" >&2; continue ;;
                        esac
                        if [ -z "$value" ]; then
                          echo "WARNUNG: $slug_upper/$key ist leer — Tools für diesen Shop werden ablehnen" >&2
                        fi
                        printf '%s' "$value" > "$tmp/BRICKLINK_STORE_''${slug_upper}_''${key}"
                      done < "$file"
                    }

          ${lib.concatMapStrings (
            store:
            let
              upper = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] store.slug);
            in
            # Reihenfolge: erst das separat abgelegte Web-Token (falls der Shop eines
            # hat), dann das Shop-Secret — ein WEB_TOKEN darin gewinnt also.
            (lib.optionalString (store.hasSeparateWebToken or false) ''
              printf '%s' "$(cat ${config.age.secrets.bricklink-web-token.path})" \
                > "$tmp/BRICKLINK_STORE_${upper}_WEB_TOKEN"
            '')
            + ''
              render_store ${upper} ${config.age.secrets."bricklink-api-${store.slug}".path}
            ''
          ) stores}
                    printf '%s' "$(cat ${config.age.secrets.bricklink-web-token.path})" \
                      > "$tmp/BRICKLINK_WEB_CLIENT_TOKEN"
                    printf '%s' "$(cat ${config.age.secrets.bricklink-mcp-bearer.path})" \
                      > "$tmp/BRICKLINK_MCP_BEARER"
                    printf '%s' "$(cat ${config.age.secrets.bricklink-files-secret.path})" \
                      > "$tmp/BRICKLINK_FILES_SECRET"
                    printf '%s' "$(cat ${config.age.secrets.bricklink-sandbox-token.path})" \
                      > "$tmp/SANDBOX_TOKEN"

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
                    {
                      name = "files-tmp";
                      emptyDir = { };
                    }
                    {
                      name = "sandbox-tmp";
                      emptyDir = { };
                    }
                    {
                      # ⚠️ Das PVC von OpenWebUI, LESEND. Dort liegen die Dateien, die
                      # jemand in den Chat hochlädt (`/data/uploads`), und ohne sie kann
                      # die Sandbox kein hochgeladenes PDF ausfüllen. Beim
                      # jupyter-Motor kopiert OpenWebUI NICHTS in die Sandbox (das
                      # `/mnt/uploads` aus der pyodide-Welt ist reine Browser-IndexedDB)
                      # — also holen wir uns die Dateien direkt.
                      #
                      # Zwei Pods am selben ReadWriteOnce-PVC gehen NUR, weil beide auf
                      # demselben Node laufen (Single-Node-Cluster, local-path). Kommt
                      # je ein zweiter Node dazu, bricht das — dann muss der Weg über
                      # eine API laufen, nicht über den Mount.
                      name = "owui-uploads";
                      persistentVolumeClaim = {
                        claimName = "open-webui-data";
                        readOnly = true;
                      };
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
                          # Welche Shops es gibt, in dieser Reihenfolge. Der Server
                          # liest daraus auch die Env-Präfixe der Credentials.
                          name = "BRICKLINK_STORES";
                          value = lib.concatMapStringsSep "," (s: "${s.slug}:${s.label}") stores;
                        }
                        {
                          # Nutzer → Default-Shop. Greift nur, wenn OpenWebUI die
                          # Nutzer-Header mitschickt; sonst verlangt jedes Tool eine
                          # ausdrückliche Shop-Angabe.
                          name = "BRICKLINK_USER_DEFAULTS";
                          value = lib.concatStringsSep "," (
                            lib.mapAttrsToList (identity: slug: "${identity}=${slug}") userDefaults
                          );
                        }
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
                        {
                          # Basis für die signierten Download-Links. Der MCP signiert
                          # nur — ausgeliefert wird von nginx im Sidecar.
                          name = "BRICKLINK_FILES_BASE_URL";
                          value = filesBaseUrl;
                        }
                        {
                          name = "BRICKLINK_FILES_PATH";
                          value = filesPath;
                        }
                        {
                          name = "BRICKLINK_WORKSPACE_PATH";
                          value = filesWorkspacePath;
                        }
                        {
                          # Eine Stunde. Lang genug, um den Link aufs Handy zu schicken,
                          # kurz genug, dass ein versehentlich geteilter Link nicht
                          # dauerhaft offen steht. Maximal erlaubt sind 1440 Minuten.
                          name = "BRICKLINK_FILES_TTL_MINUTES";
                          value = "60";
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
                    {
                      # ── Dateiserver ────────────────────────────────────────────
                      # Eigener Container, eigener Port, PVC NUR LESEND. Das ist der
                      # einzige Teil dieses Pods, den das Internet erreicht — und er
                      # kann nichts als Dateien aus /data/exports ausliefern, und das
                      # nur mit gültiger Signatur.
                      #
                      # Warum kein zweiter Pod: das PVC ist ReadWriteOnce, zwei Pods
                      # würden sich um den Mount streiten. Im selben Pod ist es
                      # derselbe Mount — einmal schreibend für den MCP, einmal
                      # lesend hier.
                      name = "files";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      command = [ "/bin/bricklink-files-server" ];
                      ports = [ { containerPort = 8082; } ];
                      env = [
                        {
                          name = "BRICKLINK_FILES_SECRET";
                          valueFrom.secretKeyRef = {
                            name = "bricklink-mcp-secrets";
                            key = "BRICKLINK_FILES_SECRET";
                          };
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/data";
                          readOnly = true;
                        }
                        {
                          # nginx braucht Schreibrechte für pid, Temp-Pfade und die
                          # gerenderte Config. Eigener emptyDir, nicht der /tmp des
                          # MCP-Containers.
                          name = "files-tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      readinessProbe = {
                        httpGet = {
                          path = "${filesPath}healthz";
                          port = 8082;
                        };
                        initialDelaySeconds = 3;
                        periodSeconds = 10;
                        failureThreshold = 6;
                      };
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "24Mi";
                        };
                        limits.memory = "96Mi";
                      };
                    }
                    {
                      # ── Code-Sandbox ──────────────────────────────────────────
                      # Jupyter-Kernel für OpenWebUIs Code-Interpreter. Ersetzt
                      # pyodide (Browser): echtes Dateisystem, PDF-Bibliotheken,
                      # matplotlib. Erreichbar NUR aus dem open-webui-Pod (CNP), und
                      # nur mit Token.
                      name = "sandbox";
                      image = sandboxImg.image;
                      imagePullPolicy = "IfNotPresent";
                      ports = [ { containerPort = 8888; } ];
                      env = [
                        {
                          name = "SANDBOX_TOKEN";
                          valueFrom.secretKeyRef = {
                            name = "bricklink-mcp-secrets";
                            key = "SANDBOX_TOKEN";
                          };
                        }
                      ];
                      volumeMounts = [
                        {
                          # Arbeitsverzeichnis: /data/workspace. Liegt im selben PVC wie
                          # die BrickLink-Exporte, deshalb sind die Ergebnisse über
                          # dieselben signierten Links abrufbar.
                          name = "data";
                          mountPath = "/data";
                        }
                        {
                          name = "sandbox-tmp";
                          mountPath = "/tmp";
                        }
                        {
                          # Chat-Uploads, lesend. Der Pfad ist bewusst /mnt/uploads:
                          # so heißt es auch in der pyodide-Welt, und das Modell kennt
                          # den Namen aus dem Prompt.
                          name = "owui-uploads";
                          mountPath = "/mnt/uploads";
                          subPath = "uploads";
                          readOnly = true;
                        }
                      ];
                      readinessProbe = {
                        # TCP, nicht HTTP: jupyter-server verlangt den Token AUCH für
                        # /api/status, und die kubelet-Probe hat keinen — das ergibt
                        # ein dauerhaftes 403 und der Container wird nie ready (am
                        # 2026-09-02 genau so gesehen). Den Token in die Probe zu
                        # schreiben hieße, ihn im Manifest im Klartext zu führen.
                        # Dass der Port hört, ist hier die ehrliche Aussage; die
                        # Token-Prüfung übt OpenWebUI bei jedem Aufruf aus.
                        tcpSocket.port = 8888;
                        initialDelaySeconds = 5;
                        periodSeconds = 10;
                        failureThreshold = 12;
                      };
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "192Mi";
                        };
                        # 1 GiB: pandas/matplotlib/pymupdf brauchen beim Import schon
                        # ~200 MB, ein PDF-Rendering oder ein DataFrame über einen
                        # Export kommt schnell dazu. Der Node hat 7,7 GiB, mehr wäre
                        # gegenüber den anderen Pods unfair.
                        limits.memory = "1Gi";
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
                {
                  # Code-Sandbox. MUSS hier stehen: OpenWebUI verbindet sich auf
                  # bricklink-mcp.chat.svc:8888, und ein Service liefert nur Ports, die
                  # er auch deklariert — fehlt der Port, läuft die Verbindung ins Leere
                  # (am 2026-09-02 als curl-Timeout gesehen, während die
                  # CiliumNetworkPolicy längst 8888 erlaubte und der Kernel lief).
                  name = "sandbox";
                  port = 8888;
                  targetPort = 8888;
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
                        {
                          # Code-Sandbox. Gleiche Quelle, gleiche Begründung: nur
                          # open-webui darf einen Kernel starten.
                          port = "8888";
                          protocol = "TCP";
                        }
                      ];
                    }
                  ];
                }
                {
                  # Der Dateiserver auf 8082 muss vom Gateway und von der
                  # Readiness-Probe erreichbar sein.
                  #
                  # ⚠️ ZWEI Entities, und beide sind nötig:
                  #   * `ingress` — die reservierte Identität des Gateway-API-Envoy.
                  #     `host` allein genügt NICHT: cilium-envoy läuft zwar mit
                  #     hostNetwork, sein weitergeleiteter Verkehr trägt aber die
                  #     Ingress-Identität. Am 2026-08-27 nachgemessen: mit nur `host`
                  #     antwortete das Gateway „503 upstream connect error", während
                  #     ein curl vom Node selbst auf denselben Port 200 lieferte.
                  #   * `host` — die kubelet-Probe kommt vom Node.
                  #
                  # Das ist die einzige Stelle, an der etwas anderes als open-webui
                  # hereindarf — und sie führt ausschließlich auf nginx mit
                  # Signaturprüfung, nicht auf den MCP.
                  fromEntities = [
                    "ingress"
                    "host"
                  ];
                  toPorts = [
                    {
                      ports = [
                        {
                          port = "8082";
                          protocol = "TCP";
                        }
                      ];
                    }
                  ];
                }
              ];
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "bricklink-files";
              namespace = "chat";
            };
            spec = {
              selector.app = "bricklink-mcp";
              ports = [
                {
                  name = "http";
                  port = 8082;
                  targetPort = 8082;
                }
              ];
            };
          }
          {
            # Öffentlicher Weg an die Export-Dateien: NUR dieses Pfad-Präfix, und nur
            # mit signiertem, ablaufendem Link. `/mcp` bleibt unerreichbar — es ist ein
            # anderer Port, und die CNP oben lässt vom Gateway ausschließlich 8082 zu.
            #
            # Pfad-Präfix-Routen haben in der Gateway-API Vorrang vor der `/`-Route von
            # open-webui (längeres Präfix gewinnt), deshalb kollidiert das nicht.
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "bricklink-exports";
              namespace = "chat";
            };
            spec = {
              parentRefs = [
                {
                  name = "main";
                  namespace = "default";
                  sectionName = "https-chat";
                }
                {
                  name = "main";
                  namespace = "default";
                  sectionName = "https-chat-alt";
                }
              ];
              hostnames = filesHosts;
              rules = [
                {
                  matches = [
                    {
                      path = {
                        type = "PathPrefix";
                        value = filesPath;
                      };
                    }
                    {
                      # ⚠️ Der zweite Präfix MUSS hier stehen. Fehlt er, greift die
                      # `/`-Route von open-webui und liefert die SPA mit HTTP 200 —
                      # was wie ein funktionierender Download aussieht, aber HTML ist
                      # (am 2026-09-02 genau so in die Irre gelaufen).
                      path = {
                        type = "PathPrefix";
                        value = filesWorkspacePath;
                      };
                    }
                  ];
                  backendRefs = [
                    {
                      name = "bricklink-files";
                      port = 8082;
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
