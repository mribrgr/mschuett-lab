{ inputs, self, ... }:
{
  # OpenWebUI mit OIDC-SSO gegen das kanidm aus modules/kanidm.nix.
  #
  # ⚠️ `open-webui` ist in nixpkgs UNFREE („Open WebUI License", Branding-Klausel seit
  # 0.6.6) ⇒ Hydra baut es nicht, es gibt keinen Binary-Cache, der aarch64-Build läuft
  # auf DIESEM Node. Deshalb MUSS die nix-daemon-Drosselung aus hosts/netcup/netcup.nix
  # aktiv sein (Root-Cause 2026-07-25: nix-Build riss etcd mit).
  #
  # Die Unfree-Erlaubnis wird bewusst NICHT am Host gesetzt, sondern auf einer eigenen
  # pkgs-Instanz: so bleibt der Rest der Config unangetastet und es ist an genau einer
  # Stelle sichtbar, welches Paket die Ausnahme braucht.
  perSystem =
    { pkgs, system, ... }:
    {
      packages.open-webui-image =
        let
          pkgsOwui = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
            config.allowUnfreePredicate = p: (pkgs.lib.getName p) == "open-webui";
          };
          root = pkgsOwui.buildEnv {
            name = "open-webui-root";
            paths = [
              pkgsOwui.open-webui
              # sqlite für den velero-Pre-Hook (konsistenter DB-Snapshot),
              # curl/jq für den Modell-Gating-Sidecar (kommt, sobald der API-Key existiert).
              pkgsOwui.sqlite
              pkgsOwui.curl
              pkgsOwui.jq
              pkgsOwui.coreutils
              pkgsOwui.bashInteractive
              pkgsOwui.cacert
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgsOwui.nix-snapshotter.buildImage {
          name = "open-webui";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [
              "/bin/open-webui"
              "serve"
              "--host"
              "0.0.0.0"
              "--port"
              "8080"
            ];
            # Ohne CA-Bundle scheitert jeder TLS-Call nach openrouter.ai/llm.collana.com
            # („certificate signed by unknown authority") — gleiche Falle wie beim
            # llm-proxy in nix-config/lab.
            env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgsOwui.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            workingdir = "/data";
          };
        };
    };

  flake.modules.nixos.openwebui =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.open-webui-image;
      webuiOrigin = "https://chat.mauritiusberger.de";
      idmOrigin = "https://idm.mauritiusberger.de";

      env = {
        # ── Basis ────────────────────────────────────────────────────────────────
        WEBUI_URL = webuiOrigin;
        DATA_DIR = "/data";
        HOME = "/data";
        # torch (über den Import-Pfad von open-webui) ruft getpass.getuser() → pwd.getpwuid(1000).
        # Das nix:0-Image hat keinen passwd-Eintrag für uid 1000, damit stirbt der Start mit
        # `OSError: No username set in the environment` (am 2026-08-26 genau so gesehen).
        # getpass prüft LOGNAME/USER/LNAME/USERNAME VOR dem pwd-Lookup — zwei Env-Vars sind
        # deshalb der saubere Fix, kein gebasteltes /etc/passwd im Image.
        USER = "open-webui";
        LOGNAME = "open-webui";
        # Ohne das steht CORS_ALLOW_ORIGIN auf "*" (open-webui warnt selbst beim Start).
        CORS_ALLOW_ORIGIN = webuiOrigin;
        # `dev` ist der Default und stellt /docs + /openapi.json OHNE Auth öffentlich
        # bereit (main.py: openapi_url nur in dev). Auf einer im Internet erreichbaren
        # Instanz nicht akzeptabel.
        ENV = "prod";
        # STATIC_DIR wird bewusst NICHT gesetzt: open-webui befüllt das Verzeichnis beim
        # Import aus FRONTEND_BUILD_DIR/static neu, und dort fehlen assets/pdf-style.css
        # und swagger-ui/ — die liegen nur im Paket-Default
        # (<site-packages>/open_webui/static). Ein eigenes STATIC_DIR bricht damit den
        # PDF-Export (FileNotFoundError → 500) und /static/swagger-ui/*.
        # HF_HOME bleibt: open-webui selbst liest es nicht, aber huggingface_hub tut es —
        # damit landet ein etwaiger Download in der PVC und nicht im Read-only-Store.
        HF_HOME = "/data/hf";

        # ── Ohne diese zwei ist die ganze Config Fiktion ─────────────────────────
        # OpenWebUI schreibt Admin-Settings beim ersten Start in webui.db und liest die
        # Env-Vars danach NICHT mehr. Mit False gewinnt immer die Config hier.
        ENABLE_PERSISTENT_CONFIG = "False";
        ENABLE_OAUTH_PERSISTENT_CONFIG = "False";

        # ── OIDC gegen kanidm ───────────────────────────────────────────────────
        OPENID_PROVIDER_URL = "${idmOrigin}/oauth2/openid/open-webui/.well-known/openid-configuration";
        OPENID_REDIRECT_URI = "${webuiOrigin}/oauth/oidc/callback";
        OAUTH_CLIENT_ID = "open-webui";
        # kanidm erzwingt PKCE für confidential clients; OpenWebUI kann S256. Damit ist
        # allowInsecureClientDisablePkce auf der kanidm-Seite unnötig.
        OAUTH_CODE_CHALLENGE_METHOD = "S256";
        OAUTH_SCOPES = "openid email profile groups";
        OAUTH_PROVIDER_NAME = "Kanidm";
        ENABLE_OAUTH_SIGNUP = "True";
        ENABLE_SIGNUP = "False";
        # Nur mit verifizierten Mails sicher — hier bewusst aus.
        OAUTH_MERGE_ACCOUNTS_BY_EMAIL = "False";
        # An lassen: Notfallweg in die Instanz, falls kanidm hängt. Es existieren keine
        # lokalen Konten, das Formular ist also faktisch leer.
        ENABLE_LOGIN_FORM = "True";

        # ── Rollen/Gruppen aus dem eigenen Claim ────────────────────────────────
        ENABLE_OAUTH_ROLE_MANAGEMENT = "True";
        OAUTH_ROLES_CLAIM = "owui_roles";
        OAUTH_ADMIN_ROLES = "openwebui-admins";
        OAUTH_ALLOWED_ROLES = "openwebui-admins,openwebui-users";
        ENABLE_OAUTH_GROUP_MANAGEMENT = "True";
        # 0.11 heißt der Key OAUTH_GROUPS_CLAIM (Plural); der Singular funktioniert nur
        # noch über einen Legacy-Fallback in config.py.
        OAUTH_GROUPS_CLAIM = "owui_roles";
        ENABLE_OAUTH_GROUP_CREATION = "True";
        # Explizit pinnen: fehlt oder ist der owui_roles-Claim LEER, überspringt
        # open-webui den Rollen-Match still und nimmt DEFAULT_USER_ROLE. Dessen Default
        # ist zwar schon "pending" (= gesperrt), aber daran soll nicht die
        # Zugriffskontrolle hängen.
        DEFAULT_USER_ROLE = "pending";
        # Nötig für den Modell-Gating-Sidecar: ohne das antwortet jeder Bearer-API-Key
        # mit 403 (auth.enable_api_keys, Default False). Der Plural ist der richtige
        # Name — ENABLE_API_KEY (Singular) existiert nicht.
        ENABLE_API_KEYS = "True";
        # MUSS False bleiben: True gibt jedem Zugriff auf jedes Modell und macht das
        # Modell-Gating wirkungslos.
        BYPASS_MODEL_ACCESS_CONTROL = "False";

        # ── Backends ────────────────────────────────────────────────────────────
        # Reihenfolge MUSS index-gleich zu OPENAI_API_KEYS im Secret sein.
        OPENAI_API_BASE_URLS = "https://openrouter.ai/api/v1;https://llm.collana.com/v1";
        ENABLE_OLLAMA_API = "False";

        # ── RAG aus ─────────────────────────────────────────────────────────────
        # Der Default (leere Engine = lokale SentenceTransformers) lädt beim ersten
        # Einsatz ein Modell von HuggingFace — Laufzeit-Download und ~1 GB RAM neben
        # mongodb/postgres auf 7,7 GiB. "openai" verhindert den lokalen Pfad.
        RAG_EMBEDDING_ENGINE = "openai";
        ENABLE_RAG_HYBRID_SEARCH = "False";
        ENABLE_WEB_SEARCH = "False";
        USER_PERMISSIONS_CHAT_FILE_UPLOAD = "False";

        # ── Telemetrie ──────────────────────────────────────────────────────────
        # open-webui 0.11 liest selbst KEINE dieser Variablen (im Upstream-Dockerfile
        # stehen sie für Drittbibliotheken). DO_NOT_TRACK bleibt als breit respektierte
        # Konvention; SCARF_NO_ANALYTICS (npm-Build-Zeit) und ANONYMIZED_TELEMETRY
        # (chroma setzt es hart auf False) wären hier toter Ballast.
        DO_NOT_TRACK = "True";
      };
    in
    {
      age.secrets.openwebui-oidc-secret.file = ../secrets/openwebui-oidc-secret.age;
      age.secrets.openwebui-secret-key.file = ../secrets/openwebui-secret-key.age;
      # Welt-übergreifend genutzte LLM-Keys: liegen in nix-config/base/secrets/ und kommen
      # über den nix-config-Input. netcup ist dort seit 2026-08-26 Recipient.
      age.secrets.openrouter-develappers.file =
        inputs.nix-config + "/base/secrets/openrouter-develappers.age";
      age.secrets.collana-auth-token.file = inputs.nix-config + "/base/secrets/collana-auth-token.age";

      # agenix → k8s-Secret. Muster: nix-config/lab/modules/llm-proxy.nix (broker-secrets).
      # Über Dateien statt --from-literal, damit kein Secret in argv landet, und mit
      # printf '%s' statt cat, damit kein Zeilenende in einer Env-Var steht (ein \n in
      # OPENAI_API_KEYS bricht die Authorization-Header).
      systemd.services.open-webui-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat/open-webui-secrets aus agenix rendern";
        after = [ "k3s.service" ];
        requires = [ "k3s.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          config.services.k3s.package
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateTmp = true;
        };
        # OHNE das läuft der oneshot nach einem Secret-Wechsel NIE wieder: er ist
        # RemainAfterExit, seine Unit-Definition referenziert nur PFADE, und agenix
        # entschlüsselt beim Switch still an dieselbe Stelle. Ergebnis wäre ein
        # k8s-Secret mit dem ALTEN Wert (am 2026-08-26 genau so passiert).
        # Die .age-Dateien sind Store-Pfade: neuer Inhalt ⇒ neuer Pfad ⇒ Unit-Änderung
        # ⇒ systemd startet den oneshot beim Switch neu.
        restartTriggers = [
          config.age.secrets.openwebui-oidc-secret.file
          config.age.secrets.openwebui-secret-key.file
          config.age.secrets.openrouter-develappers.file
          config.age.secrets.collana-auth-token.file
        ];
        script = ''
          set -euo pipefail
          for _ in $(seq 1 60); do
            k3s kubectl get ns chat >/dev/null 2>&1 && break || sleep 2
          done

          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
          printf '%s;%s' \
            "$(cat ${config.age.secrets.openrouter-develappers.path})" \
            "$(cat ${config.age.secrets.collana-auth-token.path})" > "$tmp/OPENAI_API_KEYS"
          printf '%s' "$(cat ${config.age.secrets.openwebui-secret-key.path})" > "$tmp/WEBUI_SECRET_KEY"
          printf '%s' "$(cat ${config.age.secrets.openwebui-oidc-secret.path})" > "$tmp/OAUTH_CLIENT_SECRET"

          out=$(k3s kubectl create secret generic open-webui-secrets -n chat \
            --from-file="$tmp/OPENAI_API_KEYS" \
            --from-file="$tmp/WEBUI_SECRET_KEY" \
            --from-file="$tmp/OAUTH_CLIENT_SECRET" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"

          # OpenWebUI liest die Werte per envFrom.secretRef, also NUR beim Start. Ändert
          # sich das Secret (Key-Rotation, oder das aus kanidm ausgelesene OAuth2-Secret),
          # muss der Pod neu starten — sonst läuft er still mit dem alten Wert weiter.
          # Nur bei 'configured'/'created', nicht bei 'unchanged': sonst würde jeder Boot
          # den Pod neu starten. Gleiches Muster wie modules/sealed-secrets.nix.
          if ! echo "$out" | grep -q 'unchanged'; then
            echo "Secret geändert → open-webui neu starten"
            k3s kubectl -n chat rollout restart deploy/open-webui || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        openwebui.content = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "open-webui-env";
              namespace = "chat";
            };
            data = env;
          }
          {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "open-webui-data";
              namespace = "chat";
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "5Gi";
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "open-webui";
              namespace = "chat";
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels.app = "open-webui";
              template = {
                metadata = {
                  labels.app = "open-webui";
                  # velero-Hook: konsistente Kopie der sqlite-DB, bevor fs-backup läuft.
                  # Ohne das kopiert kopia eine LAUFENDE sqlite-Datei.
                  annotations = {
                    # `envFrom` liest ConfigMap und Secret NUR beim Containerstart. Ohne
                    # diese zwei Annotationen läuft der Pod nach einer Env- oder
                    # Secret-Änderung mit den alten Werten weiter, und zwar lautlos.
                    # Beides ist zur Eval-Zeit bekannt: der Env-Satz als Hash, die Secrets
                    # über ihre Store-Pfade (neuer Inhalt ⇒ neuer Pfad).
                    "checksum/env" = builtins.hashString "sha256" (builtins.toJSON env);
                    "checksum/secrets" = builtins.hashString "sha256" (
                      builtins.concatStringsSep ":" [
                        "${../secrets/openwebui-oidc-secret.age}"
                        "${../secrets/openwebui-secret-key.age}"
                        "${inputs.nix-config + "/base/secrets/openrouter-develappers.age"}"
                        "${inputs.nix-config + "/base/secrets/collana-auth-token.age"}"
                      ]
                    );
                    "pre.hook.backup.velero.io/container" = "open-webui";
                    "pre.hook.backup.velero.io/command" =
                      ''["/bin/sqlite3","/data/webui.db",".backup /data/webui-backup.db"]'';
                  };
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
                      persistentVolumeClaim.claimName = "open-webui-data";
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                  ];
                  containers = [
                    {
                      name = "open-webui";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      ports = [ { containerPort = 8080; } ];
                      envFrom = [
                        { configMapRef.name = "open-webui-env"; }
                        { secretRef.name = "open-webui-secrets"; }
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
                        # /ready statt /health: /health antwortet sofort, /ready prüft
                        # startup_complete UND die DB-Verbindung.
                        httpGet = {
                          path = "/ready";
                          port = 8080;
                        };
                        initialDelaySeconds = 20;
                        periodSeconds = 10;
                        failureThreshold = 12;
                      };
                      resources = {
                        requests = {
                          cpu = "100m";
                          memory = "512Mi";
                        };
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
              name = "open-webui";
              namespace = "chat";
            };
            spec = {
              selector.app = "open-webui";
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
              name = "chat-mauritiusberger-de";
              namespace = "chat";
            };
            spec = {
              # sectionName: NUR an den HTTPS-Listener. Ohne das hängt die Route auch am
              # hostname-losen `http`-Listener und die Anwendung wäre zusätzlich per
              # Plaintext erreichbar — Session-Cookies gehören nicht auf :80.
              parentRefs = [
                {
                  name = "main";
                  namespace = "default";
                  kind = "Gateway";
                  sectionName = "https-chat";
                }
              ];
              hostnames = [ "chat.mauritiusberger.de" ];
              rules = [
                {
                  backendRefs = [
                    {
                      name = "open-webui";
                      port = 8080;
                    }
                  ];
                }
              ];
            };
          }
          {
            # :80 → 301 auf HTTPS. Kollidiert NICHT mit dem ACME-HTTP-01-Solver: dessen
            # HTTPRoute matcht den exakten Pfad /.well-known/acme-challenge/<token> und
            # gewinnt damit die Gateway-API-Präzedenz gegen dieses Prefix-`/`.
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "chat-mauritiusberger-de-redirect";
              namespace = "chat";
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
              hostnames = [ "chat.mauritiusberger.de" ];
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
