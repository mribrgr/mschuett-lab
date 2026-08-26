{ inputs, self, ... }:
{
  # Kanidm als IdP für das OpenWebUI-SSO. Ein Pod, drei Container aus EINEM nix:0-Image:
  #
  #   kanidmd    127.0.0.1:8443, TLS-pflichtig (kanidm hat keinen Plaintext-Modus)
  #   nginx      :8080 → https://127.0.0.1:8443, proxy_ssl_verify off (nur Loopback)
  #   provision  einmalig recover-account + kanidm-provision, danach sleep infinity
  #
  # ── Warum der nginx-Sidecar ────────────────────────────────────────────────────
  # Envoy (Cilium Gateway) spricht Plaintext zum Backend, kanidm kann kein Plaintext.
  # Die Alternativen wurden geprüft und verworfen:
  #   • BackendTLSPolicy (CRD ist da, Cilium 1.20 unterstützt es): bräuchte ein echtes
  #     LE-Zertifikat IM Pod, und kanidm liest Zertifikate nur bei Start oder SIGHUP neu
  #     → alle 60 Tage ein Watcher-Sidecar, der SIGHUP schickt.
  #   • TLSRoute-Passthrough: gleiches Renewal-Problem.
  # Ein 10-Jahre-Self-Signed auf Loopback hat das Problem nicht; das ÖFFENTLICHE
  # Zertifikat bleibt beim cert-manager am Gateway, wie bei allen anderen Hosts.
  #
  # ⚠️ `domain`/`origin` sind nach dem ersten Start praktisch nicht mehr änderbar — sie
  # hängen an allen ausgestellten Credentials. Einmal richtig: idm.mauritiusberger.de.
  #
  # ⚠️ NICHT auf `kanidm_1_8` zurückgehen: upstream EOL, in nixpkgs mit
  # knownVulnerabilities markiert. Ab 1.9 heißt das Unterkommando
  # `kanidmd scripting recover-account`.
  perSystem =
    { pkgs, system, ... }:
    {
      packages.kanidm-image =
        let
          # Eigene pkgs-Instanz für den Overlay — Begründung wie in
          # modules/steinaberfeinde.nix: das nix-snapshotter-Flake publiziert Pakete NUR
          # für x86_64-linux, der Overlay baut es dagegen aus dem Source und liefert
          # `buildImage` auch auf aarch64. Lokal begrenzt, damit kein Diamond auf
          # services.k3s.package entsteht.
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          # Alles in EINEM Image: die drei Container unterscheiden sich nur im `command`.
          # Ein zweites Image wäre ein zweiter Build ohne Gegenwert.
          root = pkgs.buildEnv {
            name = "kanidm-root";
            paths = [
              # .withSecretProvisioning: trägt die zwei Patches von oddlama, ohne die
              # kanidm-provision das OAuth2-Basic-Secret NICHT setzen kann (nur auslesen).
              # Kostet einen Rust-Build ohne Binary-Cache — der läuft off-host in der
              # aarch64-linux-VM des Macs (nix-config/mac/modules/linux-builder.nix), nie
              # auf diesem Node.
              pkgs.kanidm_1_11.withSecretProvisioning # liefert kanidmd UND kanidm
              pkgs.kanidm-provision
              pkgs.nginx
              pkgs.openssl
              pkgs.curl
              pkgs.jq
              pkgs.coreutils
              pkgs.bashInteractive
              pkgs.cacert
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgsSnap.nix-snapshotter.buildImage {
          name = "kanidm";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            # Kleinschreibung: nix2container unmarshalt in ocispec.ImageConfig, und Go
            # matcht JSON-Felder case-insensitive. Konvention dieses Repos, siehe
            # modules/steinaberfeinde.nix.
            entrypoint = [ "/bin/kanidmd" ];
            env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          };
        };
    };

  flake.modules.nixos.kanidm =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.kanidm-image;

      domain = "idm.mauritiusberger.de";
      chatOrigin = "https://chat.mauritiusberger.de";

      serverToml = ''
        version = "2"
        bindaddress = "127.0.0.1:8443"
        domain = "${domain}"
        origin = "https://${domain}"
        db_path = "/data/kanidm.db"
        tls_chain = "/tls/chain.pem"
        tls_key = "/tls/key.pem"
        role = "WriteReplica"
        # `kanidmd scripting recover-account` redet NICHT mit der DB, sondern über diesen
        # Unix-Socket mit dem laufenden Server. Der eingebaute Default ist
        # /run/kanidmd/sock — den legt unter NixOS `RuntimeDirectory=kanidmd` an, im
        # Container existiert das Verzeichnis nicht und `UnixListener::bind` scheitert mit
        # ENOENT, womit kanidmd GAR NICHT startet. /tmp ist das geteilte emptyDir, das
        # kanidmd UND der provision-Container mounten — deshalb hier hin.
        # Der Socket akzeptiert nur Peers mit uid 0 oder der uid von kanidmd; beide
        # Container laufen als 1000, das passt.
        adminbindpath = "/tmp/kanidmd.sock"

        # Client-IP aus dem X-Forwarded-For des nginx-Sidecars übernehmen, sonst steht in
        # jedem Audit-Log und Rate-Limit nur 127.0.0.1.
        # ⚠️ NICHT `trust_x_forward_for = true` — das ist der LEGACY-Key. `version = "2"`
        # deserialisiert in ServerConfigV2 mit `deny_unknown_fields`, kanidmd bricht damit
        # beim Start ab („unknown field").
        [http_client_address_info]
        x-forward-for = [ "127.0.0.1" ]

        [online_backup]
        # Konsistente Dumps für velero: die LAUFENDE sqlite-DB per fs-backup zu kopieren
        # kann eine zerrissene Datei liefern, diese JSON-Dumps nicht.
        path = "/data/backups"
        schedule = "00 03 * * *"
        versions = 7
      '';

      nginxConf = ''
        worker_processes 1;
        error_log /dev/stderr info;
        pid /tmp/nginx.pid;
        events { worker_connections 256; }
        http {
          access_log off;
          # Das Image-Root hat nur /bin und /etc; alle Schreibpfade müssen in das
          # emptyDir unter /tmp zeigen, sonst startet nginx nicht.
          client_body_temp_path /tmp/nginx-body;
          proxy_temp_path /tmp/nginx-proxy;
          fastcgi_temp_path /tmp/nginx-fastcgi;
          uwsgi_temp_path /tmp/nginx-uwsgi;
          scgi_temp_path /tmp/nginx-scgi;
          server {
            listen 8080;
            client_max_body_size 16m;
            location / {
              proxy_pass https://127.0.0.1:8443;
              # Loopback zum Self-Signed im GLEICHEN Pod — hier ist nichts zu verifizieren.
              proxy_ssl_verify off;
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto https;
              proxy_read_timeout 120s;
            }
          }
        }
      '';

      # Schema von kanidm-provision (github.com/oddlama/kanidm-provision#json-schema).
      # Schlüssel MÜSSEN kleingeschrieben sein. `members` wird hier explizit geführt —
      # das NixOS-Modul leitet es aus persons.*.groups ab, hier gibt es kein Modul.
      # EINZIGE Quelle für die Zuordnung Person → Gruppen. `groups.*.members` wird daraus
      # berechnet, weil kanidm-provision 1.3.0 ein `groups`-Feld an einer Person STILL
      # IGNORIERT (Person-Struct hat es nicht, kein deny_unknown_fields) — beides
      # getrennt zu pflegen wäre eine Drift-Falle ohne Fehlermeldung. Das NixOS-Modul
      # macht es genauso (`config.members` aus `cfg.provision.persons`).
      personGroups = {
        mberger = [ "openwebui-admins" ];
        mschuett = [
          "openwebui-users"
          "openwebui-deepseek"
        ];
      };

      groupNames = [
        "openwebui-admins"
        "openwebui-users"
        "openwebui-deepseek"
      ];

      membersOf = group: lib.attrNames (lib.filterAttrs (_: groups: lib.elem group groups) personGroups);

      provisionState = {
        groups = lib.genAttrs groupNames (g: {
          members = membersOf g;
        });
        persons = {
          mberger = {
            displayName = "Mauritius Berger";
            mailAddresses = [ "mauritius.berger@develappers.de" ];
          };
          mschuett = {
            displayName = "Max Schütt";
            mailAddresses = [ "steinaberfeinbl@gmail.com" ];
          };
        };
        systems.oauth2.open-webui = {
          displayName = "Open WebUI";
          originUrl = "${chatOrigin}/oauth/oidc/callback";
          originLanding = "${chatOrigin}/";
          # `name` statt `spn` im preferred_username-Claim → die OpenWebUI-Konten heißen
          # "mberger", nicht "mberger@idm.mauritiusberger.de".
          preferShortUsername = true;
          # Das Secret kommt aus agenix (openwebui-oidc-secret.age) und wird von
          # kanidm-provision in kanidm GESETZT — dieselbe Datei speist über
          # modules/openwebui.nix auch OAUTH_CLIENT_SECRET. Eine Quelle, zwei Konsumenten,
          # kein Auslese-Schritt und kein Drift bei einem kanidm-Neuaufbau.
          basicSecretFile = "/secrets/oidc-client-secret";
          scopeMaps = {
            openwebui-admins = [
              "openid"
              "profile"
              "email"
              "groups"
            ];
            openwebui-users = [
              "openid"
              "profile"
              "email"
              "groups"
            ];
          };
          # Eigener Claim statt des eingebauten `groups`-Claims: der liefert volle SPNs
          # (openwebui-admins@idm.mauritiusberger.de), OAUTH_ADMIN_ROLES müsste dann auf
          # Domain-Suffixe matchen.
          claimMaps.owui_roles = {
            joinType = "array";
            valuesByGroup = {
              openwebui-admins = [ "openwebui-admins" ];
              openwebui-users = [ "openwebui-users" ];
              openwebui-deepseek = [ "openwebui-deepseek" ];
            };
          };
        };
      };

      # Portiert aus nixos/modules/services/security/kanidm.nix (`postStartScript`).
      # Läuft bei JEDEM Pod-Start und ist damit idempotent; kanidm-provision räumt aus
      # der Config entfernte Entities über seine Tracking-Gruppe selbst weg.
      provisionScript = ''
        set -euo pipefail
        for i in $(seq 1 60); do
          if curl -sS --insecure --max-time 2 https://127.0.0.1:8443 >/dev/null 2>&1; then break; fi
          if [ "$i" = 60 ]; then echo "kanidm kam in 120s nicht hoch" >&2; exit 1; fi
          sleep 2
        done

        # Frisches idm_admin-Passwort pro Lauf, nur transient benutzt. Ein GEWÄHLTES
        # Passwort (--from-environment) gäbe es nur mit dem Secret-Provisioning-Patch.
        recover_out=$(kanidmd scripting recover-account -c /config/server.toml idm_admin)
        pw=$(printf '%s' "$recover_out" | jq -r .output)
        if [ -z "$pw" ] || [ "$pw" = "null" ]; then
          echo "idm_admin-Passwort nicht parsebar: $recover_out" >&2
          exit 1
        fi

        KANIDM_PROVISION_IDM_ADMIN_TOKEN="$pw" kanidm-provision \
          --accept-invalid-certs \
          --url https://127.0.0.1:8443 \
          --state /config/provision-state.json

        echo "provisioning ok"
        exec sleep infinity
      '';
    in
    {
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        kanidm.content = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "kanidm-config";
              namespace = "chat";
            };
            data = {
              "server.toml" = serverToml;
              "nginx.conf" = nginxConf;
              "provision-state.json" = builtins.toJSON provisionState;
            };
          }
          {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "kanidm-data";
              namespace = "chat";
            };
            # local-path ist Default-StorageClass → kein storageClassName nötig.
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "2Gi";
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "kanidm";
              namespace = "chat";
            };
            spec = {
              replicas = 1;
              # Recreate, nicht RollingUpdate: EINE RWO-PVC. Ein zweiter Writer würde die
              # sqlite-DB gefährden und der Rollout deadlockte am Volume.
              strategy.type = "Recreate";
              selector.matchLabels.app = "kanidm";
              template = {
                metadata = {
                  labels.app = "kanidm";
                  # kanidm-provision setzt das OAuth2-Basic-Secret beim POD-START. Ändert
                  # sich die age-Datei, muss der Pod rollen, sonst behält kanidm den alten
                  # Wert, während open-webui schon den neuen benutzt — SSO wäre kaputt und
                  # nichts würde es melden. Der Store-Pfad der age-Datei ist der Trigger.
                  annotations."checksum/oidc-secret" = builtins.hashString "sha256" "${
                    ../secrets/openwebui-oidc-secret.age
                  }";
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
                      persistentVolumeClaim.claimName = "kanidm-data";
                    }
                    {
                      name = "tls";
                      emptyDir = { };
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                    {
                      name = "config";
                      configMap.name = "kanidm-config";
                    }
                    {
                      # Nur der eine Key aus dem von modules/openwebui.nix gerenderten
                      # Secret — kanidm hat keinen Grund, die LLM-Keys zu sehen.
                      name = "oidc-secret";
                      secret = {
                        secretName = "open-webui-secrets";
                        items = [
                          {
                            key = "OAUTH_CLIENT_SECRET";
                            path = "oidc-client-secret";
                          }
                        ];
                      };
                    }
                  ];
                  initContainers = [
                    {
                      name = "tls-init";
                      image = img.image;
                      # IfNotPresent, NICHT Never: der nix-snapshotter klinkt sich in den
                      # PULL ein und löst den nix:0-Ref dabei aus dem Store auf. Mit
                      # "Never" lehnt der kubelet vorher ab (ErrImageNeverPull).
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "/bin/bash"
                        "-ec"
                        ''
                          openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
                            -subj "/CN=${domain}" \
                            -addext "subjectAltName=DNS:${domain},DNS:localhost,IP:127.0.0.1" \
                            -keyout /tls/key.pem -out /tls/chain.pem
                          chmod 0400 /tls/key.pem
                        ''
                      ];
                      volumeMounts = [
                        {
                          name = "tls";
                          mountPath = "/tls";
                        }
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "kanidmd";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "/bin/kanidmd"
                        "server"
                        "-c"
                        "/config/server.toml"
                      ];
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/data";
                        }
                        {
                          name = "tls";
                          mountPath = "/tls";
                          readOnly = true;
                        }
                        {
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "192Mi";
                        };
                        limits.memory = "512Mi";
                      };
                    }
                    {
                      name = "nginx";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "/bin/nginx"
                        "-c"
                        "/config/nginx.conf"
                        # -e vor dem Config-Parsing: sonst versucht nginx zuerst seinen
                        # einkompilierten Default /var/log/nginx/error.log und meldet
                        # „could not open error log file" (harmlos, aber Rauschen).
                        "-e"
                        "/dev/stderr"
                        "-g"
                        "daemon off;"
                      ];
                      ports = [ { containerPort = 8080; } ];
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits.memory = "128Mi";
                      };
                    }
                    {
                      name = "provision";
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "/bin/bash"
                        "-ec"
                        provisionScript
                      ];
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/data";
                        }
                        {
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          name = "oidc-secret";
                          mountPath = "/secrets";
                          readOnly = true;
                        }
                        # /tls read-only: für interaktive kanidm-CLI-Aufrufe im Pod
                        # (Credential-Reset-Token). Achtung: das Self-Signed ist sein eigener
                        # Issuer, rustls lehnt es als `-C`-CA mit „CaUsedAsEndEntity" ab →
                        # stattdessen `--accept-invalid-certs`.
                        {
                          name = "tls";
                          mountPath = "/tls";
                          readOnly = true;
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                      resources = {
                        requests = {
                          cpu = "10m";
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
              name = "kanidm";
              namespace = "chat";
            };
            spec = {
              selector.app = "kanidm";
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
              name = "idm-mauritiusberger-de";
              namespace = "chat";
            };
            spec = {
              # Cross-Namespace-parentRef ist erlaubt, weil der Listener
              # allowedRoutes.namespaces.from: All führt. Ein ReferenceGrant wäre nur für
              # cross-namespace BACKENDrefs nötig — das Backend liegt hier daneben.
              # sectionName: NUR an den HTTPS-Listener. Ohne das hängt die Route auch am
              # hostname-losen `http`-Listener und der IdP wäre zusätzlich per Plaintext
              # erreichbar — für einen Identity Provider inakzeptabel.
              parentRefs = [
                {
                  name = "main";
                  namespace = "default";
                  kind = "Gateway";
                  sectionName = "https-idm";
                }
              ];
              hostnames = [ domain ];
              rules = [
                {
                  backendRefs = [
                    {
                      name = "kanidm";
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
              name = "idm-mauritiusberger-de-redirect";
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
              hostnames = [ domain ];
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
