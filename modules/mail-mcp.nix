{ inputs, self, ... }:
let
  # ── Postfächer ────────────────────────────────────────────────────────────────
  # EINZIGE Quelle dafür, welche Postfächer als MCP-Tool-Server in Open WebUI hängen.
  # Pro Eintrag entsteht ein eigener Pod mit genau EINEM Satz Zugangsdaten — ein
  # kompromittierter Server sieht also nie mehr als sein eigenes Postfach.
  #
  # Der Schlüssel (`aol`) ist gleichzeitig:
  #   * Tool-Server-ID in Open WebUI (`server:mcp:aol`). Open WebUI stellt sie den
  #     Tool-Namen selbst voran (`aol_search`), zwei Postfächer kollidieren also nicht.
  #     Ändert sich der Schlüssel, zeigen die
  #     Modell-Zuordnungen (modules/openwebui.nix, modelGrants) ins Leere,
  #   * Name von Deployment/Service/Secret (`aol-mail-mcp`).
  #
  # Neues Postfach: Eintrag hier, App-Passwort als secrets/<…>.age, fertig —
  # openwebui.nix und chat-e2e.nix lesen diese Liste über `self.mailMcp`.
  mailSpec = {
    port = 8083;
    mailboxes = {
      aol = {
        address = "maximilianschuett@aol.com";
        name = "AOL-Mail";
        label = "AOL-Postfach von Max Schütt";
        fromName = "Max Schütt";
        description = "Max' AOL-Postfach (maximilianschuett@aol.com): Mails suchen und lesen, Entwürfe anlegen. Kein Senden, Löschen oder Verschieben — Entwürfe gehen im AOL-Webmailer raus.";
        imapHost = "imap.aol.com";
        imapPort = 993;
        smtpHost = "smtp.aol.com";
        smtpPort = 465;
        # App-Passwort, NICHT das Kontopasswort: AOL lässt fremde IMAP-Clients nur
        # damit herein. Erzeugt unter login.aol.com → Kontosicherheit → „App-Passwort
        # generieren" (docs/mail-mcp.md). Überlebt eine Änderung des Kontopassworts.
        passwordFile = ../secrets/aol-mail-app-password.age;
        # Senden ist der einzige Vorgang, der nach außen wirkt und sich nicht
        # zurücknehmen lässt. Aus, bis es jemand ausdrücklich will — dann hier `true`.
        allowSend = false;
      };
      # Ersetzt seit 2026-10-13 Googles offiziellen Gmail-MCP (nur Developer Preview, nur
      # Workspace-Konten — siehe docs/mail-mcp.md). Schlüssel bleibt `gmail`, damit die
      # Tool-Server-ID `server:mcp:gmail` gleich bleibt.
      gmail = {
        address = "steinaberfeinbl@gmail.com";
        name = "Gmail";
        label = "Gmail-Postfach von SteinAberFein (Max Schütt)";
        fromName = "SteinAberFein";
        description = "Max' Gmail-Postfach (steinaberfeinbl@gmail.com, SteinAberFein): Mails suchen und lesen, Entwürfe anlegen. Kein Senden, Löschen oder Verschieben — Entwürfe gehen in Gmail raus.";
        imapHost = "imap.gmail.com";
        imapPort = 993;
        smtpHost = "smtp.gmail.com";
        smtpPort = 465;
        # Google-App-Passwort (16 Zeichen), NICHT das Kontopasswort. Gibt es nur bei
        # aktiver Bestätigung in zwei Schritten: myaccount.google.com/apppasswords.
        # Wird beim Ändern des Kontopassworts von Google WIDERRUFEN.
        passwordFile = ../secrets/gmail-app-password.age;
        allowSend = false;
      };
    };
  };
in
{
  flake.mailMcp = mailSpec;

  # MCP-Server für E-Mail-Postfächer über IMAP/SMTP (pkgs/mail-mcp).
  #
  # ── Zugriff ──────────────────────────────────────────────────────────────────
  # Wie bricklink-mcp: kein Ingress, Open WebUI verbindet sich clusterintern über
  # Streamable HTTP. Zwei Schranken: die CiliumNetworkPolicy lässt nur den
  # open-webui-Pod herein, und der Server verlangt einen Bearer-Token
  # (secrets/mail-mcp-bearer.age, gemeinsam für alle Postfächer — er schützt den
  # Port, nicht das Postfach; das App-Passwort ist pro Postfach getrennt).
  #
  # EGRESS bleibt offen, wie bei bricklink-mcp: eine FQDN-Allowlist auf
  # imap.aol.com bräche lautlos, sobald AOL die Hostnamen umbaut.
  perSystem =
    { pkgs, system, ... }:
    let
      mkApp =
        p:
        p.python3Packages.buildPythonApplication {
          pname = "mail-mcp";
          version = "0.1.0";
          pyproject = true;
          src = ../pkgs/mail-mcp;
          build-system = [ p.python3Packages.setuptools ];
          dependencies = [ p.python3Packages.fastmcp ];
          nativeCheckInputs = [ p.python3Packages.pytestCheckHook ];
          pythonImportsCheck = [ "mail_mcp.mailbox" ];
        };
    in
    {
      packages.mail-mcp = mkApp pkgs;

      packages.mail-mcp-image =
        let
          pkgsMail = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          root = pkgsMail.buildEnv {
            name = "mail-mcp-root";
            paths = [
              (mkApp pkgsMail)
              pkgsMail.coreutils
              pkgsMail.bashInteractive
              pkgsMail.curl
              pkgsMail.cacert
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgsMail.nix-snapshotter.buildImage {
          name = "mail-mcp";
          resolvedByNix = true;
          copyToRoot = [ root ];
          config = {
            entrypoint = [ "/bin/mail-mcp" ];
            env = [
              "PATH=/bin"
              # Ohne CA-Bundle scheitert der TLS-Handshake zu imap.aol.com mit
              # „certificate verify failed" — gleiche Falle wie bei openwebui/meridian.
              "SSL_CERT_FILE=${pkgsMail.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            workingdir = "/tmp";
          };
        };
    };

  flake.modules.nixos.mail-mcp =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.mail-mcp-image;
      inherit (mailSpec) port mailboxes;
      bearerFile = ../secrets/mail-mcp-bearer.age;
      appName = slug: "${slug}-mail-mcp";
      secretName = slug: "${slug}-mail-app-password";

      # Hash über den INHALT der .age-Dateien (siehe openwebui.nix secretsChecksum):
      # neue Credentials ⇒ neue Pod-Annotation ⇒ Neustart, weil envFrom das Secret nur
      # beim Containerstart liest.
      credentialHash = builtins.hashString "sha256" (
        builtins.concatStringsSep ":" (
          map (f: builtins.hashFile "sha256" f) (
            [ bearerFile ] ++ lib.mapAttrsToList (_: m: m.passwordFile) mailboxes
          )
        )
      );

      objectsFor = slug: m: [
        {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = appName slug;
            namespace = "chat";
          };
          spec = {
            replicas = 1;
            selector.matchLabels.app = appName slug;
            template = {
              metadata = {
                labels.app = appName slug;
                annotations."checksum/credentials" = credentialHash;
              };
              spec = {
                securityContext = {
                  runAsUser = 1000;
                  runAsGroup = 1000;
                  runAsNonRoot = true;
                };
                # Kein ServiceAccount-Token im Pod: der Server redet nur mit dem
                # Mailserver, nie mit der k8s-API.
                automountServiceAccountToken = false;
                volumes = [
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                ];
                containers = [
                  {
                    name = "mail-mcp";
                    image = img.image;
                    imagePullPolicy = "IfNotPresent";
                    ports = [ { containerPort = port; } ];
                    envFrom = [ { secretRef.name = appName slug; } ];
                    env = lib.mapAttrsToList (name: value: { inherit name value; }) {
                      MAIL_ADDRESS = m.address;
                      MAIL_IMAP_HOST = m.imapHost;
                      MAIL_IMAP_PORT = toString m.imapPort;
                      MAIL_SMTP_HOST = m.smtpHost;
                      MAIL_SMTP_PORT = toString m.smtpPort;
                      MAIL_FROM_NAME = m.fromName;
                      MAIL_LABEL = m.label;
                      MAIL_ALLOW_SEND = lib.boolToString m.allowSend;
                      MAIL_MCP_HOST = "0.0.0.0";
                      MAIL_MCP_PORT = toString port;
                      MAIL_MCP_PATH = "/mcp";
                      HOME = "/tmp";
                      # Ohne das ruft FastMCP beim Start PyPI an (siehe bricklink-mcp).
                      FASTMCP_CHECK_FOR_UPDATES = "off";
                      FASTMCP_SHOW_SERVER_BANNER = "false";
                    };
                    volumeMounts = [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                    ];
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      readOnlyRootFilesystem = true;
                      capabilities.drop = [ "ALL" ];
                    };
                    readinessProbe = {
                      # /health liegt außerhalb der Bearer-Auth und loggt sich NICHT
                      # bei AOL ein (Konten mit auffällig vielen Logins sperrt AOL).
                      httpGet = {
                        path = "/health";
                        inherit port;
                      };
                      initialDelaySeconds = 3;
                      periodSeconds = 10;
                      failureThreshold = 6;
                    };
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
            name = appName slug;
            namespace = "chat";
          };
          spec = {
            selector.app = appName slug;
            ports = [
              {
                name = "http";
                inherit port;
                targetPort = port;
              }
            ];
          };
        }
        {
          # Sobald eine CNP einen Endpoint selektiert, gilt für dessen Ingress
          # Default-Deny. Nur open-webui darf hinein — ein Wegwerf-Debug-Pod kommt an
          # das Postfach nicht heran. Die kubelet-Probe vom Node lässt Cilium ohnehin zu.
          apiVersion = "cilium.io/v2";
          kind = "CiliumNetworkPolicy";
          metadata = {
            name = "${appName slug}-only-from-open-webui";
            namespace = "chat";
          };
          spec = {
            endpointSelector.matchLabels.app = appName slug;
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
                        port = toString port;
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
    in
    {
      age.secrets = {
        mail-mcp-bearer.file = bearerFile;
      }
      // lib.mapAttrs' (
        slug: m: lib.nameValuePair (secretName slug) { file = m.passwordFile; }
      ) mailboxes;

      systemd.services.mail-mcp-secrets = lib.mkIf (config.services.k3s.role == "server") {
        description = "chat/<postfach>-mail-mcp-Secrets aus agenix rendern";
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
        # Ohne restartTriggers liefe der oneshot nach einer Rotation nie wieder
        # (RemainAfterExit + Unit kennt nur Pfade) — siehe openwebui.nix.
        restartTriggers = [ credentialHash ];
        # printf '%s' statt cat: kein Zeilenende im Wert — ein \n am App-Passwort
        # endet als „LOGIN failed".
        #
        # Zusätzlich zur Pod-Annotation checksum/credentials ein `rollout restart`,
        # wenn sich das Secret geändert hat: k3s kann das Manifest (neue Annotation,
        # Pod-Neustart) VOR diesem oneshot anwenden — dann startete der Pod noch mit
        # dem alten Wert.
        script = ''
          set -euo pipefail
          for _ in $(seq 1 60); do
            k3s kubectl get ns chat >/dev/null 2>&1 && break
            sleep 2
          done
          k3s kubectl get ns chat >/dev/null
          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
        ''
        + lib.concatStrings (
          lib.mapAttrsToList (slug: _: ''
            # Leer entschlüsselt = Unit scheitert laut, statt einen Pod ohne Passwort
            # bzw. ohne Bearer zu starten (der Server verweigert dann ohnehin den Start).
            for f in ${
              config.age.secrets.${secretName slug}.path
            } ${config.age.secrets.mail-mcp-bearer.path}; do
              [ -s "$f" ] || { echo "$f ist leer — Abbruch" >&2; exit 1; }
            done
            mkdir "$tmp/${slug}"
            printf '%s' "$(cat ${config.age.secrets.${secretName slug}.path})" > "$tmp/${slug}/MAIL_PASSWORD"
            printf '%s' "$(cat ${config.age.secrets.mail-mcp-bearer.path})" > "$tmp/${slug}/MAIL_MCP_BEARER"
            out=$(k3s kubectl create secret generic ${appName slug} -n chat --from-file="$tmp/${slug}" \
              --dry-run=client -o yaml | k3s kubectl apply -f -)
            echo "$out"
            if ! echo "$out" | grep -q unchanged; then
              k3s kubectl -n chat rollout restart deploy/${appName slug} || true
            fi
          '') mailboxes
        );
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        mail-mcp.content = lib.concatLists (lib.mapAttrsToList objectsFor mailboxes);
      };
    };
}
