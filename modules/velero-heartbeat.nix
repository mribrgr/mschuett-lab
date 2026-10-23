{
  # Heartbeat der velero-Schedules an Gatus (modules/gatus.nix, Gruppe backup).
  #
  # velero selbst meldet nichts: ein PartiallyFailed- oder Failed-Backup steht
  # nur als Status am Backup-Objekt, ein ausgesetzter Schedule erzeugt gar
  # nichts. Beides fiel bisher nur auf, wenn jemand `velero backup get`
  # aufrief — im Ernstfall also beim Restore.
  #
  # Die Schedules stehen im Chart des Repos not-just-a-developer.com
  # (deploy/chart/values.yaml), nicht in diesem Flake. Präfix ist der
  # Helm-Release `notjustadevelopercom`. Wer dort einen Schedule umbenennt,
  # muss es hier nachziehen — sonst findet der Pusher keine Backups und
  # meldet rot (gewollt: lieber ein falscher Alarm als stille Lücke).
  #
  # Stündlich statt einmal nach dem Lauf: der Push meldet den ZUSTAND („letztes
  # Backup gut und frisch“), nicht ein Ereignis. Damit ist ein Ausfall des
  # Pushers (3h Stille) von einem kaputten Backup (Push mit success=false)
  # unterscheidbar, und ein Neustart von netcup verliert nichts.
  flake.modules.nixos.velero-heartbeat =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      # Label velero.io/schedule-name → Gatus-Key `<group>_<name>`.
      schedules = {
        "notjustadevelopercom-velero-daily-backup" = "backup_velero-azure";
        "notjustadevelopercom-velero-nas-mirror" = "backup_velero-nas-mirror";
      };
      # Täglicher Schedule plus Puffer für Laufzeit (~8 min) und Verzug.
      maxAgeHours = 26;

      script = pkgs.writeShellApplication {
        name = "velero-heartbeat";
        runtimeInputs = [
          config.services.k3s.package
          pkgs.jq
          pkgs.curl
          pkgs.coreutils
        ];
        text = ''
          token=$(cat ${config.age.secrets.gatus-token-cluster.path})
          now=$(date -u +%s)

          check() {
            local schedule=$1 endpoint=$2 json latest phase finished name age_h ok=false err="" query
            if ! json=$(k3s kubectl -n default get backups.velero.io \
                -l "velero.io/schedule-name=$schedule" -o json); then
              # API weg ist kein Backup-Fehler. Kein Push → Gatus meldet die
              # Stille nach 3h, falls es dabei bleibt.
              echo "$schedule: kubectl fehlgeschlagen, kein Push" >&2
              return 0
            fi
            # Letzter ABGESCHLOSSENER Lauf. Ein Backup, das gerade läuft
            # (02:00–02:10), ist weder gut noch schlecht.
            latest=$(jq -r '
              [.items[] | select(.status.completionTimestamp != null)]
              | sort_by(.metadata.creationTimestamp) | last // empty
              | "\(.status.phase) \(.status.completionTimestamp) \(.metadata.name)"
            ' <<<"$json")
            if [ -z "$latest" ]; then
              err="kein abgeschlossenes Backup für Schedule $schedule"
            else
              read -r phase finished name <<<"$latest"
              age_h=$(( (now - $(date -u -d "$finished" +%s)) / 3600 ))
              if [ "$phase" != Completed ]; then
                err="$name: $phase"
              elif [ "$age_h" -ge ${toString maxAgeHours} ]; then
                err="letztes Backup $name vor $age_h h (Schedule ausgesetzt?)"
              else
                ok=true
              fi
            fi

            query="success=$ok"
            if [ -n "$err" ]; then
              query="$query&error=$(jq -rn --arg e "$err" '$e | @uri')"
            fi
            echo "$endpoint: success=$ok ''${err:+($err)}"
            curl -sS -m 20 --retry 3 --retry-delay 5 --retry-all-errors \
              -X POST \
              -H "Authorization: Bearer $token" \
              -o /dev/null \
              "https://status.mauritiusberger.de/api/v1/endpoints/$endpoint/external?$query" \
              || echo "$endpoint: Heartbeat nicht zugestellt" >&2
          }

          ${lib.concatStrings (lib.mapAttrsToList (s: ep: "check ${s} ${ep}\n") schedules)}
        '';
      };
    in
    {
      systemd.services.velero-heartbeat = lib.mkIf (config.services.k3s.role == "server") {
        description = "velero-Backup-Status an Gatus melden";
        after = [ "k3s.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe script;
        };
      };

      # Stündlich zur Minute 15 — nicht zur vollen Stunde, da starten die
      # Schedules (02:00, 03:00). `Persistent` nicht nötig: der Push meldet
      # einen Zustand, der nächste Lauf holt alles nach.
      systemd.timers.velero-heartbeat = lib.mkIf (config.services.k3s.role == "server") {
        description = "velero-Backup-Status stündlich an Gatus melden";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "10min";
          OnCalendar = "*-*-* *:15:00";
          AccuracySec = "1min";
        };
      };
    };
}
