{
  inputs,
  self,
  ...
}:
{
  # Zwischen-Store für den velero-Mirror auf das NAS.
  # Design: nix-config/docs/superpowers/specs/2026-08-26-velero-nas-mirror-design.md
  #
  # ── Warum überhaupt ein Store IM Cluster ─────────────────────────────────────
  # velero kann nur PUSHEN, und wohin es pusht, dafür braucht es ein Credential.
  # Läge das Ziel auf dem NAS, müsste der Cluster einen NAS-Schlüssel halten und
  # es bräuchte einen eingehenden Pfad ins Heimnetz. Stattdessen schreibt velero
  # in diesen Store hier, und das NAS HOLT ihn ab (`ssh -N -L` + rclone, vom NAS
  # initiiert). Ergebnis:
  #   • der Cluster kennt kein NAS-Credential
  #   • es gibt keinen Inbound-Pfad zum NAS, kein Port-Forward am Speedport
  #   • Azure bleibt völlig unberührt und läuft weiter
  #
  # Der Store ist ZWISCHENLAGER, kein Backup-Ziel: er steht im selben
  # Fehlerbereich wie die Quelle. Deshalb kurze TTL (168h, im Chart-Repo), die
  # Historie hält das NAS über ZFS-Snapshots.
  #
  # ── Warum nix:0 und k3s-Manifest statt ArgoCD ────────────────────────────────
  # Gleiche Begründung wie modules/steinaberfeinde.nix: ein nix:0-Ref IST ein
  # Store-Pfad, den nur nix zur Eval-Zeit kennt. Ein Chart in git kann ihn nicht
  # führen.
  #
  # ⚠️ NICHT hier, sondern im Chart-Repo (mribrgr/not-just-a-developer.com,
  # deploy/chart/values.yaml): das AWS-Plugin von velero, die zweite BSL
  # `staging` und der zweite Schedule. Grund: velero kommt dort als
  # Chart-Abhängigkeit, und `provider: aws` verlangt den initContainer
  # `velero-plugin-for-aws` — am 2026-08-26 lief nur das Azure-Plugin. Ein
  # zweiter Ort für dieselbe Deployment-Definition wäre ein Kampf zweier Besitzer.
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      packages.backup-store-image =
        let
          # Eigene pkgs-Instanz mit dem nix-snapshotter-Overlay — Begründung
          # (aarch64 + Diamond-Vermeidung) steht in modules/steinaberfeinde.nix.
          pkgsSnap = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.nix-snapshotter.overlays.default ];
          };
          nixSnapshotter = pkgsSnap.nix-snapshotter;

          garage = pkgs.garage_2;
          configPath = "/etc/garage/garage.toml";

          # Alle Befehlsformen und Exit-Codes am Binary 2.3.0 verifiziert
          # (2026-08-26, lokaler Durchlauf gegen echte Garage-Instanzen):
          #   `bucket create` auf Bestehendem → Exit 1, `key import` → Exit 1,
          #   `bucket allow` wiederholt → Exit 0.
          #
          # ⚠️ KEINE Pipe von `garage` in einen früh aussteigenden Konsumenten
          # (`grep -q`, `awk … exit`): der schließt die Pipe, garage bekommt
          # SIGPIPE und PANICKT, und mit `pipefail` bricht das Skript ab. In der
          # ersten Fassung des NAS-Pendants passierte das genau zwischen
          # `layout assign` und `layout apply` — der Store blieb dauerhaft auf
          # "Layout not ready". Deshalb: Ausgabe in Variablen, bash-Regex.
          bootstrap = pkgs.writeShellScript "backup-store-bootstrap" ''
            set -euo pipefail
            # Ohne copyToRoot hat das Image kein /bin — der PATH MUSS aus dem
            # Store kommen, sonst findet die Shell weder `seq` noch `sleep`.
            # Nebeneffekt und Absicht: die Referenz zieht coreutils in die Closure.
            export PATH="${pkgs.lib.makeBinPath [ pkgs.coreutils ]}"

            g() { ${garage}/bin/garage -c ${configPath} "$@"; }

            # Der Server braucht nach dem Start einen Moment, bis er RPC annimmt.
            for _ in $(seq 1 60); do
              g status >/dev/null 2>&1 && break
              sleep 1
            done
            g status >/dev/null

            nodeid="$(g node id -q)"
            node="''${nodeid%%@*}"

            status="$(g status)"
            if [[ $status == *"NO ROLE ASSIGNED"* ]]; then
              echo "backup-store: Node $node ohne Rolle — Layout wird zugewiesen"
              g layout assign -z netcup -c 15G "$node"
            fi

            # Getrennt geprüft, nicht als else-Zweig: heilt ein zugewiesenes,
            # aber nie angewendetes Layout. Die Zielversion nennt garage selbst.
            layout="$(g layout show)"
            if [[ $layout == *"STAGED ROLE CHANGES"* ]]; then
              if [[ $layout =~ layout\ apply\ --version\ ([0-9]+) ]]; then
                echo "backup-store: Layout-Version ''${BASH_REMATCH[1]} wird angewendet"
                g layout apply --version "''${BASH_REMATCH[1]}"
              else
                echo "backup-store: staged Änderungen ohne Zielversion in 'layout show'" >&2
                exit 1
              fi
            fi

            # Bis die Partitionen verteilt sind, antwortet jeder Bucket-Aufruf
            # mit "Layout not ready".
            for _ in $(seq 1 60); do
              g bucket list >/dev/null 2>&1 && break
              sleep 1
            done

            buckets="$(g bucket list)"
            if [[ ! $buckets =~ (^|[[:space:]])velero([[:space:]]|$) ]]; then
              echo "backup-store: Bucket velero wird angelegt"
              g bucket create velero
            fi

            keys="$(g key list)"

            # velero schreibt: RW. Der Key steht im k8s-Secret der BSL.
            if [[ ! $keys =~ (^|[[:space:]])"$GARAGE_VELERO_KEY_ID"([[:space:]]|$) ]]; then
              echo "backup-store: velero-Key wird importiert"
              g key import "$GARAGE_VELERO_KEY_ID" "$GARAGE_VELERO_SECRET" --yes -n velero-writer
            fi
            g bucket allow --read --write velero --key "$GARAGE_VELERO_KEY_ID"

            # Das NAS liest nur. Kein --write: ein kompromittiertes NAS darf die
            # Quelle nicht verändern, es soll sie spiegeln.
            if [[ ! $keys =~ (^|[[:space:]])"$GARAGE_NAS_KEY_ID"([[:space:]]|$) ]]; then
              echo "backup-store: NAS-Lesekey wird importiert"
              g key import "$GARAGE_NAS_KEY_ID" "$GARAGE_NAS_SECRET" --yes -n nas-reader
            fi
            g bucket allow --read velero --key "$GARAGE_NAS_KEY_ID"
          '';

          # Bootstrap-Logik gehört in die deklarative Einheit (CLAUDE.md), also in
          # den Image-Entrypoint — nicht in einen Handgriff nach dem Deploy.
          # Der Bootstrap läuft NEBEN dem Server, weil er den laufenden Server
          # braucht; die Schleife wiederholt ihn alle 10 Minuten und korrigiert
          # damit auch Drift (von Hand entzogene Berechtigungen o.Ä.).
          entrypoint = pkgs.writeShellScript "backup-store-entrypoint" ''
            set -euo pipefail
            export PATH="${pkgs.lib.makeBinPath [ pkgs.coreutils ]}"

            # Garage legt metadata_dir/data_dir nicht selbst an; das PVC kommt leer.
            mkdir -p /var/lib/garage/meta /var/lib/garage/data

            (
              while true; do
                if ${bootstrap}; then
                  sleep 600
                else
                  echo "backup-store: Bootstrap fehlgeschlagen, neuer Versuch in 30s" >&2
                  sleep 30
                fi
              done
            ) &

            exec ${garage}/bin/garage -c ${configPath} server
          '';
        in
        nixSnapshotter.buildImage {
          name = "backup-store";
          resolvedByNix = true;
          # ⚠️ KEIN `copyToRoot`. Die erste Fassung hatte hier ein buildEnv mit
          # bash/coreutils/garage — damit startete der Container NIE:
          #   Error: failed to create containerd container:
          #   open /nix/store/…-config-backup-store.json: not a directory
          # (2026-08-27 am laufenden Cluster gesehen, Pod 9 h in
          # CreateContainerError, 2742 Versuche).
          #
          # Ursache: `buildImage` bildet die Closure aus
          # `rootPaths = [ configFile ] ++ copyToRoot` und nix-snapshotter
          # mountet jeden Pfad daraus in den Container. `config-*.json` ist eine
          # DATEI; sobald copyToRoot gesetzt ist, entsteht dafür ein
          # Verzeichnis-Ziel, und `mount(2)` beantwortet Datei-auf-Verzeichnis
          # mit ENOTDIR. Das funktionierende modules/steinaberfeinde.nix setzt
          # copyToRoot ebenfalls nicht.
          #
          # Der Verzicht kostet nichts: die Skripte referenzieren bash (Shebang)
          # und ihre Werkzeuge über absolute Store-Pfade bzw. den PATH oben, und
          # genau dadurch landen sie in der Closure. Was fehlt, ist ein /bin/sh —
          # für `kubectl exec` also den Pfad mitgeben:
          #   kubectl -n backup-store exec deploy/backup-store -- \
          #     ${garage}/bin/garage -c ${configPath} status
          config.entrypoint = [ "${entrypoint}" ];
        };
    };

  flake.modules.nixos.backup-store =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      img = self.packages.${pkgs.stdenv.hostPlatform.system}.backup-store-image;

      ns = "backup-store";
      # Gepinnte ClusterIP. Nicht Kosmetik: der `permitopen`-Zwang im
      # authorized_keys des Tunnel-Users nimmt eine LITERALE Adresse, kein
      # Pattern und keinen Namen — eine wandernde ClusterIP bricht den Tunnel.
      # 10.70.0.30 liegt im service-cidr (10.70.0.0/16) und ist frei: belegt sind
      # dort nur .1 (apiserver) und .10 (kube-dns), am 2026-08-26 geprüft.
      # Niedrige Adresse mit Absicht — dynamische ClusterIPs kommen bevorzugt aus
      # dem oberen Band.
      clusterIp = "10.70.0.30";
      s3Port = 3900;

      # Öffentlicher Teil des Tunnel-Schlüssels. Der private liegt als
      # nix-config/homelab/secrets/nas-pull-ssh-key.age auf dem NAS.
      nasPullKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPh+4SKqGfFVm12R2UnS2thRhr0VVgmFEyslqwDMAzu5 nas-pull@nas";

      envSecret = ../secrets/backup-store-env.age;
      credSecret = ../secrets/velero-staging-credentials.age;

      # Ohne das läuft der Secret-Oneshot nach einem Secret-Wechsel NIE wieder
      # (RemainAfterExit + Unit referenziert nur Pfade). Muster und Begründung:
      # modules/openwebui.nix.
      secretsChecksum = builtins.hashString "sha256" (
        builtins.concatStringsSep ":" (
          map (f: builtins.hashFile "sha256" f) [
            envSecret
            credSecret
          ]
        )
      );

      garageToml = ''
        metadata_dir = "/var/lib/garage/meta"
        data_dir = "/var/lib/garage/data"
        db_engine = "lmdb"

        # Eine Node, eine Kopie. Redundanz ist hier nicht die Aufgabe: dieser
        # Store ist Zwischenlager, die belastbare Kopie liegt auf dem NAS
        # (raidz2 + Snapshots).
        replication_factor = 1

        # RPC redet nur mit sich selbst — Loopback genügt und ist damit von
        # außen nicht erreichbar.
        rpc_bind_addr = "127.0.0.1:3901"
        rpc_public_addr = "127.0.0.1:3901"

        [s3_api]
        # Muss 0.0.0.0 sein: hier kommen velero (aus dem Pod-Netz) und der
        # SSH-Tunnel des NAS (über den Host) an.
        api_bind_addr = "0.0.0.0:${toString s3Port}"
        # Frei wählbar, muss aber auf JEDER Client-Seite identisch stehen
        # (BSL-config.region, rclone, kopia) — die S3-Signatur rechnet sie mit.
        s3_region = "garage"

        [admin]
        # Die CLI läuft im selben Container, also Loopback.
        api_bind_addr = "127.0.0.1:3903"
      '';

      # `velero.io/exclude-from-backup` wirkt laut Velero-Doku NUR auf das Objekt,
      # das es trägt — eine gelabelte Namespace schließt ihren Inhalt NICHT aus.
      # Deshalb an PVC und Pod, denn die sind die fs-backup-Kandidaten. Ohne das
      # sichert velero diesen Store in sich selbst: der bestehende Schedule hat
      # kein `includedNamespaces` und `defaultVolumesToFsBackup: true`, also ist
      # jede neue PVC automatisch drin.
      excludeLabel = {
        "velero.io/exclude-from-backup" = "true";
      };
    in
    {
      age.secrets = {
        backup-store-env.file = envSecret;
        velero-staging-credentials.file = credSecret;
      };

      # Nur-Forwarding-User für den Pull vom NAS.
      #
      # `port-forwarding` MUSS neben `restrict` stehen: `restrict` schaltet laut
      # sshd(8) ALLE Einschränkungen ein, inklusive Port-Forwarding, und
      # `permitopen` allein hebt das nicht wieder auf. Ohne das Schlüsselwort
      # scheitert der Tunnel.
      #
      # Ergebnis: keine Shell, kein PTY, kein Agent-/X11-Forwarding, und als
      # Forward-Ziel ausschließlich diese eine Adresse.
      users.groups.nas-pull = { };
      users.users.nas-pull = {
        isSystemUser = true;
        group = "nas-pull";
        description = "Nur-Forwarding-Zugang des NAS zum backup-store";
        # nologin: für eine Forwarding-Session startet sshd keine Shell. Sollte
        # der Tunnel je mit "This account is currently not available" scheitern,
        # ist pkgs.bash der Ausweg — die Begrenzung macht `restrict`, nicht die
        # Shell.
        shell = "${pkgs.shadow}/bin/nologin";
        openssh.authorizedKeys.keys = [
          ''restrict,port-forwarding,permitopen="${clusterIp}:${toString s3Port}" ${nasPullKey}''
        ];
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        backup-store.content = [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata.name = ns;
          }
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "garage-config";
              namespace = ns;
            };
            # Als Verzeichnis gemountet, nicht per subPath: der Mountpunkt-Ordner
            # muss dann nicht im Image existieren.
            data."garage.toml" = garageToml;
          }
          {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = {
              name = "garage-data";
              namespace = ns;
              labels = excludeLabel;
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              # 20Gi bei gemessenen 257 MB local-path-Belegung des ganzen
              # Clusters (2026-08-26) und TTL 168h. Reichlich Luft, und die
              # Platte hat 445 GB frei. Die 2 TB in Azure sind überwiegend das
              # restic-Repo des Macs, nicht velero.
              resources.requests.storage = "20Gi";
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "backup-store";
              namespace = ns;
            };
            spec = {
              replicas = 1;
              selector.matchLabels.app = "backup-store";
              # Recreate, NICHT RollingUpdate: LMDB verträgt keinen zweiten
              # Schreiber. Beim Rolling Update liefen zwei Pods auf demselben
              # Node gleichzeitig auf dasselbe RWO-Volume — das korrumpiert die
              # Metadaten-DB.
              strategy.type = "Recreate";
              template = {
                metadata.labels = {
                  app = "backup-store";
                }
                // excludeLabel;
                spec = {
                  containers = [
                    {
                      name = "garage";
                      # nix:0 — der nix-snapshotter löst den Ref beim PULL aus dem
                      # Store auf. IfNotPresent, nicht Never: mit Never lehnt der
                      # kubelet vorher ab (ErrImageNeverPull), siehe
                      # modules/steinaberfeinde.nix.
                      image = img.image;
                      imagePullPolicy = "IfNotPresent";
                      envFrom = [ { secretRef.name = "backup-store-env"; } ];
                      ports = [
                        {
                          name = "s3";
                          containerPort = s3Port;
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/var/lib/garage";
                        }
                        {
                          name = "config";
                          mountPath = "/etc/garage";
                        }
                      ];
                      readinessProbe.tcpSocket.port = s3Port;
                      livenessProbe = {
                        tcpSocket.port = s3Port;
                        initialDelaySeconds = 30;
                      };
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "128Mi";
                        };
                        # Kein CPU-Limit: Throttling während eines Backups würde
                        # velero-Uploads verzögern, nicht schützen. Speicher
                        # gedeckelt, weil LMDB-Caches sonst wachsen können und
                        # der Host nur 7,7 GiB hat.
                        limits.memory = "512Mi";
                      };
                    }
                  ];
                  volumes = [
                    {
                      name = "data";
                      persistentVolumeClaim.claimName = "garage-data";
                    }
                    {
                      name = "config";
                      configMap.name = "garage-config";
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
              name = "backup-store";
              namespace = ns;
            };
            spec = {
              type = "ClusterIP";
              clusterIP = clusterIp;
              selector.app = "backup-store";
              ports = [
                {
                  name = "s3";
                  port = s3Port;
                  targetPort = s3Port;
                }
              ];
            };
          }
        ];
      };

      # agenix → k8s-Secret. Zwei Ziele in zwei Namespaces:
      #   backup-store/backup-store-env         RPC-Secret, Admin-Token, beide S3-Keys
      #   default/velero-staging-credentials    AWS-Credential-Datei für die BSL
      systemd.services.backup-store-secrets = {
        description = "k8s-Secrets des backup-store aus agenix rendern";
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
          # Braucht k3s beim Kaltstart länger als die Warteschleife, wäre der
          # Fehlschlag ohne Restart endgültig und das Secret NIE gerendert.
          Restart = "on-failure";
          RestartSec = 15;
        };
        restartTriggers = [ secretsChecksum ];
        script = ''
          set -euo pipefail
          ready=""
          for _ in $(seq 1 60); do
            if k3s kubectl get ns ${ns} >/dev/null 2>&1; then ready=yes; break; fi
            sleep 2
          done
          if [ -z "$ready" ]; then
            echo "Namespace ${ns} kam in 120s nicht — Unit scheitert absichtlich" >&2
            exit 1
          fi

          # --from-env-file: die agenix-Datei ist schon KEY=VALUE pro Zeile.
          out=$(k3s kubectl create secret generic backup-store-env -n ${ns} \
            --from-env-file=${config.age.secrets.backup-store-env.path} \
            --dry-run=client -o yaml | k3s kubectl apply -f -)
          echo "$out"

          # velero erwartet eine AWS-Credential-DATEI unter dem Key, den die BSL
          # in `credential.key` nennt.
          k3s kubectl create secret generic velero-staging-credentials -n default \
            --from-file=cloud=${config.age.secrets.velero-staging-credentials.path} \
            --dry-run=client -o yaml | k3s kubectl apply -f -

          # envFrom wird nur beim Containerstart gelesen. Nur bei echter Änderung
          # rollen, sonst startet jeder Boot den Pod neu (Muster: openwebui.nix).
          if ! echo "$out" | grep -q 'unchanged'; then
            echo "Secret geändert → backup-store wird neu gestartet"
            k3s kubectl -n ${ns} rollout restart deploy/backup-store || true
          fi
        '';
      };
    };
}
