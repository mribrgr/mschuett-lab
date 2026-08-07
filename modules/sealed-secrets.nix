{ ... }:
{
  # sealed-secrets im BOOTSTRAP, nicht als ArgoCD-Application.
  #
  # Grund ist Reihenfolge-Sicherheit, nicht Ästhetik: praktisch jede App im
  # Cluster hängt an einem SealedSecret (`velero-credentials`, `paperlesssecret`,
  # `n8nllmsecret`, `ghostfoliosecret`, `mongodb-secret`, ghcr-Pull-Secret). Als
  # ArgoCD-App war die Kette
  #   k3s → ArgoCD → sync sealed-secrets → Controller da → Keys einspielen
  # und bis dahin scheitert jeder Sync, der ein SealedSecret braucht. Als
  # k3s-Manifest kommt der Controller MIT dem Cluster hoch, unabhängig von ArgoCD.
  #
  # ⚠️ Der frische Controller erzeugt einen NEUEN Key. Die 11 alten Keys müssen
  # eingespielt werden, sonst ist kein SealedSecret aus dem Repo entschlüsselbar:
  #   agenix -d secrets/sealed-secrets-master-keys.age | kubectl apply -f -
  #   kubectl -n kube-system rollout restart deploy/sealed-secrets
  # Nicht fatal, wenn es zu spät passiert: der Controller lädt ALLE Secrets mit
  # Label sealedsecrets.bitnami.com/sealed-secrets-key und nutzt sie zum
  # Entschlüsseln — der neue bleibt nur der aktive Sealing-Key. Siehe TODO.md 0/4.
  #
  # Leaf-Modul: setzt ausschließlich services.k3s.manifests, importiert das
  # k3s-Basismodul NICHT (kein Diamond auf services.k3s.package).
  flake.modules.nixos.sealed-secrets =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    {
      # ── Die 11+1 Controller-Keys DEKLARATIV einspielen ────────────────────────
      # Bis 2026-08-07 war das Handarbeit („agenix -d … | kubectl apply -f -"),
      # also genau die Art Schritt, die beim nächsten Neuaufbau vergessen wird —
      # mit der Folge, dass KEIN SealedSecret im Repo mehr entschlüsselbar ist.
      #
      # Möglich wird das erst, seit der netcup-Host-Key Recipient der age-Datei ist
      # (secrets/secrets.nix): der Server entschlüsselt sie zur Aktivierungszeit
      # selbst, /run/agenix ist tmpfs + root-only.
      #
      # Muster wie `collana-secrets` in nix-config/lab/hosts/azure-k3s.
      age.secrets.sealed-secrets-master-keys.file = ../secrets/sealed-secrets-master-keys.age;

      systemd.services.sealed-secrets-keys = lib.mkIf (config.services.k3s.role == "server") {
        description = "sealed-secrets Controller-Keys aus agenix einspielen";
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
        };
        # Idempotent: `kubectl apply` meldet bei unveränderten Keys "unchanged",
        # dann bleibt der Controller in Ruhe (verifiziert 2026-08-07: 12×
        # unchanged, 0 Restarts). Nur bei einem NEUEN Key wird neu gestartet —
        # sealed-secrets liest seine Keys NUR beim Start ein.
        script = ''
          set -euo pipefail
          for _ in $(seq 1 60); do
            k3s kubectl get ns kube-system >/dev/null 2>&1 && break || sleep 2
          done
          out=$(k3s kubectl apply -f ${config.age.secrets.sealed-secrets-master-keys.path})
          echo "$out"
          # Nur bei 'created' neu starten, NICHT bei 'configured'. Grund: ein
          # Restart bei jedem Boot wäre sinnlos, und genau das passierte beim
          # ersten Lauf (2026-08-07) — die exportierte YAML trug noch
          # resourceVersion/uid/managedFields, wodurch `apply` jedes Mal
          # "configured" meldete. Die age-Datei ist inzwischen um diese Felder
          # bereinigt; 'created' greift dann nur noch auf einem frischen Cluster,
          # und genau dort ist der Restart nötig.
          if echo "$out" | grep -q 'created'; then
            echo "Keys geändert → sealed-secrets neu starten"
            k3s kubectl -n kube-system rollout restart deploy/sealed-secrets || true
          fi
        '';
      };

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        # Version 2.17.7 = exakt die des abgelösten Clusters
        # (charts/root-app/disabled/sealed-secrets.yaml). Bewusst gepinnt: ein
        # Controller-Upgrade darf nicht mitten in der Migration passieren.
        sealed-secrets.content = [
          {
            apiVersion = "helm.cattle.io/v1";
            kind = "HelmChart";
            metadata = {
              name = "sealed-secrets";
              namespace = "kube-system";
            };
            spec = {
              # ⚠️ bitnami, NICHT bitnami-labs. Das Projekt ist am 2026-06-15 von der
              # Org `bitnami-labs` nach `bitnami` umgezogen, und GitHub-Pages-URLs
              # werden NICHT weitergeleitet (nur git/Browser-Links).
              #   https://bitnami-labs.github.io/sealed-secrets/index.yaml -> 404
              #   https://bitnami.github.io/sealed-secrets/index.yaml       -> 200
              # Deshalb lief der ALTE Cluster problemlos (installiert vor 322 Tagen,
              # also vor dem Umzug), während der Neuaufbau am 2026-08-06 mit
              # „404 Not Found" scheiterte. Verifiziert: die neue URL führt 2.17.7.
              repo = "https://bitnami.github.io/sealed-secrets";
              chart = "sealed-secrets";
              version = "2.17.7";
              # kube-system wie vorher — die Key-Secrets, die wir wiederherstellen,
              # liegen genau dort und sind auf diesen Namespace geprägt.
              targetNamespace = "kube-system";
            };
          }
        ];
      };
    };
}
