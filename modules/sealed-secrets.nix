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
    { lib, config, ... }:
    {
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
              repo = "https://bitnami-labs.github.io/sealed-secrets";
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
