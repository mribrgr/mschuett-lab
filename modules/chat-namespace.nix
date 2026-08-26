{ ... }:
{
  # Namespace für die persönlichen Dienste (OpenWebUI + Kanidm-SSO), getrennt von
  # Max' `default`-Welt.
  #
  # Eigenes Modul, weil sowohl modules/kanidm.nix als auch modules/openwebui.nix
  # hineinlegen — und genau EINE Manifest-Datei darf die Namespace anlegen, sonst
  # streiten sich zwei k3s-Addons um dasselbe Objekt.
  #
  # Backup kommt ohne Zutun: der velero-Schedule `notjustadevelopercom-velero-daily-backup`
  # hat KEIN includedNamespaces und `defaultVolumesToFsBackup: true` (am 2026-08-26 am
  # laufenden Cluster geprüft), sichert also alle Namespaces inklusive Volumes.
  #
  # Leaf-Modul: setzt ausschließlich services.k3s.manifests, importiert das
  # k3s-Basismodul NICHT (kein Diamond auf services.k3s.package).
  flake.modules.nixos.chat-namespace =
    { lib, config, ... }:
    {
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        chat-namespace.content = [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata.name = "chat";
          }
        ];
      };
    };
}
