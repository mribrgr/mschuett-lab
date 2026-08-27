{ inputs, self, ... }:
{
  # Meridian — bridged das Claude-Max-Abo als OpenAI-kompatiblen Endpoint für OpenWebUI.
  #
  # Meridian spricht beide Protokolle (`/v1/messages` anthropic-kompatibel und
  # `/v1/chat/completions` + `/v1/models` OpenAI-kompatibel) und authentifiziert über das
  # Claude Code SDK statt über einen API-Key. Für OpenWebUI ist die OpenAI-Seite relevant:
  # es kennt nur OpenAI- und Ollama-Connections.
  #
  # ── ⚠️ Der Port IST das Abo-Credential ───────────────────────────────────────
  # Wer diesen Endpoint erreicht, nutzt das Claude-Max-Konto — ohne Rate-Limit-Schranke,
  # ohne Abrechnungstrennung. Deshalb drei Schichten:
  #   1. KEINE HTTPRoute. Der Dienst ist nicht am Gateway und damit nicht aus dem Internet
  #      erreichbar.
  #   2. CiliumNetworkPolicy: nur der open-webui-Pod darf Port 3456 überhaupt öffnen.
  #      Sobald eine Policy einen Endpoint selektiert, ist alles andere in dieser Richtung
  #      verboten — ein anderer Pod im Cluster (paperless, n8n, ein Wegwerf-Debug-Pod)
  #      kommt nicht mehr dran.
  #   3. In OpenWebUI bleiben die Claude-Modelle OHNE Grant und sind damit automatisch nur
  #      für Admins sichtbar (`get_filtered_models`: Modelle ohne DB-Eintrag sieht nur ein
  #      Admin). Wer sie einem Nicht-Admin geben will, muss das explizit tun.
  #
  # ── ⚠️ Warum hier ein Registry-Image und KEIN nix:0-Image ────────────────────
  # Ein selbstgebautes nix:0-Image lief NICHT, und zwar aus einem Grund, der nicht auf
  # unserer Seite liegt: Meridian startet die Claude-CLI über das Claude Code SDK mit
  # `options.executable = "node"` und `pathToClaudeCodeExecutable = <aufgelöster Pfad>`,
  # führt also effektiv `node <pfad>` aus. nixpkgs paketiert `claude-code` aber als
  # KOMPILIERTES Binary (nur `bin/claude` + `bin/.claude-wrapped`, kein `cli.js`) — `node`
  # bekommt damit eine ELF-Datei zum Parsen und der Kindprozess stirbt mit Code 127.
  # Am 2026-08-27 bis in das Meridian-Bundle hinein nachverfolgt; die CLI selbst lief im
  # Container einwandfrei, auch mit leerem Environment.
  #
  # Upstreams Image bringt die npm-Struktur mit (ihr Dockerfile ruft install.cjs und legt
  # ein `claude`-Shim), ist also der vom Autor unterstützte Laufzeitpfad. Gepinnt wird der
  # arm64-MANIFEST-Digest, nicht ein Tag: damit ist der Deploy reproduzierbar, auch wenn
  # jemand `1.63.0` überschreibt. Update = neuen Digest per
  # `skopeo inspect --raw docker://ghcr.io/rynfar/meridian:<tag>` holen und hier eintragen.
  #
  # EGRESS ist bewusst NICHT eingeschränkt: das Claude Code SDK spricht mit mehreren
  # Anthropic-Endpunkten (API, Telemetrie, Statsig) und ein FQDN-Allowlist würde bei jedem
  # Upstream-Wechsel lautlos brechen. Die Gegenrichtung ist hier auch nicht das Risiko —
  # das Risiko ist, wer HEREIN darf.
  flake.modules.nixos.meridian =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      # 1.63.0, linux/arm64. Bewusst der Manifest-Digest der Architektur, nicht der Index.
      image = "ghcr.io/rynfar/meridian@sha256:9233b3b8e087bfead5d96922f5999c6b8c9968e15685282e80ee0573ced35421";
      tokenFile = inputs.nix-config + "/base/secrets/claude-code-oauth-token.age";
    in
    {
      # Welt-übergreifend: dasselbe Token treibt features.meridian auf dem Mac.
      age.secrets.claude-code-oauth-token.file = tokenFile;

      systemd.services.meridian-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat/meridian-secrets aus agenix rendern";
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
        # Ohne restartTriggers liefe der oneshot nach einer Token-Rotation nie wieder:
        # RemainAfterExit, und die Unit-Definition kennt nur Pfade. Der Hash des
        # DATEIINHALTS ändert sich mit dem Token und damit die Unit.
        restartTriggers = [ (builtins.hashFile "sha256" tokenFile) ];
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
          printf '%s' "$(cat ${config.age.secrets.claude-code-oauth-token.path})" \
            > "$tmp/CLAUDE_CODE_OAUTH_TOKEN"

          out=$(k3s kubectl create secret generic meridian-secrets -n chat \
            --from-file="$tmp/CLAUDE_CODE_OAUTH_TOKEN" \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"
          if ! echo "$out" | grep -q 'unchanged'; then
            echo "Token geändert → meridian neu starten"
            k3s kubectl -n chat rollout restart deploy/meridian || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        meridian.content = [
          {
            # ⚠️ Ohne /etc/machine-id scheitert JEDE Anfrage mit HTTP 500 und der Meldung
            # „cannot capture lock owner process incarnation". Meridians Session-Store
            # identifiziert den Lock-Besitzer über
            #   hashIdentity("linux:<machine-id>:<pid-namespace>") + boot_id
            # (`linuxLocalBootIdentity()` in dist/cli-*.js). Fehlt die Datei oder ist der
            # Wert kein 32-stelliger Hex-String, gibt die Funktion `undefined` zurück und
            # der Lock kann nie erworben werden. Ein nix:0-Image aus `buildEnv` bringt
            # /etc/machine-id NICHT mit — am 2026-08-27 im Bundle nachgelesen, nachdem der
            # Fehler zuerst wie ein libsql-Locking-Problem aussah.
            #
            # Der Wert selbst ist beliebig und kein Geheimnis: er identifiziert hier nur
            # „diese Instanz" gegenüber ihrem eigenen Lockfile. Fest statt zufällig, damit
            # er über Pod-Neustarts stabil bleibt (die pid-Namespace-Komponente wechselt
            # ohnehin und macht alte Locks korrekt als tot erkennbar).
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "meridian-machine-id";
              namespace = "chat";
            };
            data."machine-id" = "a3f1c47b90e24d6f8b5e2c7d19a04f63";
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "meridian";
              namespace = "chat";
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels.app = "meridian";
              template = {
                metadata = {
                  labels.app = "meridian";
                  # env kommt aus dem Secret und wird nur beim Containerstart gelesen.
                  annotations."checksum/token" = builtins.hashFile "sha256" tokenFile;
                };
                spec = {
                  securityContext = {
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                  };
                  volumes = [
                    {
                      # Das SDK schreibt ~/.claude (Session-State, Cache). Ephemer ist
                      # richtig: die Identität kommt aus dem Token, nicht aus dem Verzeichnis.
                      name = "home";
                      emptyDir = { };
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                    {
                      name = "machine-id";
                      configMap.name = "meridian-machine-id";
                    }
                  ];
                  containers = [
                    {
                      name = "meridian";
                      inherit image;
                      # Digest-gepinnt ⇒ IfNotPresent ist ausreichend und vermeidet einen
                      # Registry-Roundtrip bei jedem Pod-Start.
                      imagePullPolicy = "IfNotPresent";
                      ports = [ { containerPort = 3456; } ];
                      env = [
                        {
                          # 0.0.0.0, nicht der 127.0.0.1-Default: sonst wäre der Port aus
                          # dem Pod-Netz nicht erreichbar. Die Zugriffsbeschränkung macht
                          # die NetworkPolicy unten, nicht die Bind-Adresse.
                          name = "MERIDIAN_HOST";
                          value = "0.0.0.0";
                        }
                        {
                          name = "MERIDIAN_PORT";
                          value = "3456";
                        }
                        {
                          # Upstream-Image legt den User `claude` mit diesem HOME an; das SDK
                          # sucht dort ~/.claude.
                          name = "HOME";
                          value = "/home/claude";
                        }
                        {
                          name = "CLAUDE_CODE_OAUTH_TOKEN";
                          valueFrom.secretKeyRef = {
                            name = "meridian-secrets";
                            key = "CLAUDE_CODE_OAUTH_TOKEN";
                          };
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "home";
                          mountPath = "/home/claude";
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                        {
                          # subPath: legt GENAU diese Datei an, ohne das /etc des Images
                          # zu verdecken (dort liegen u.a. die CA-Zertifikate).
                          name = "machine-id";
                          mountPath = "/etc/machine-id";
                          subPath = "machine-id";
                          readOnly = true;
                        }
                      ];
                      readinessProbe = {
                        httpGet = {
                          path = "/v1/models";
                          port = 3456;
                        };
                        initialDelaySeconds = 10;
                        periodSeconds = 10;
                        failureThreshold = 12;
                      };
                      # Node-Limits liegen schon bei ~102% von 6,72 GiB allocatable
                      # (Overcommit ist normal, entscheidend ist die echte Nutzung).
                      # Deshalb knapp: ein Node-Prozess plus die claude-CLI.
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "192Mi";
                        };
                        limits.memory = "640Mi";
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
              name = "meridian";
              namespace = "chat";
            };
            spec = {
              selector.app = "meridian";
              ports = [
                {
                  name = "http";
                  port = 3456;
                  targetPort = 3456;
                }
              ];
            };
          }
          {
            # Least access: NUR open-webui darf zu meridian. Sobald eine CNP einen Endpoint
            # selektiert, ist jeder andere Ingress auf ihn verboten — Default-Deny gilt
            # dann für diese Richtung, nicht nur für die aufgezählten Ports.
            apiVersion = "cilium.io/v2";
            kind = "CiliumNetworkPolicy";
            metadata = {
              name = "meridian-only-from-open-webui";
              namespace = "chat";
            };
            spec = {
              endpointSelector.matchLabels.app = "meridian";
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
                          port = "3456";
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
