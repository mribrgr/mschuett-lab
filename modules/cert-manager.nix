{ ... }:
{
  # cert-manager im BOOTSTRAP, nicht als ArgoCD-Application.
  #
  # Entscheidung 2026-08-05: es wird die netcup-Variante (jetstack 1.18.2 +
  # installCRDs) — NICHT nix-config/lab/modules/cert-manager.nix. Das Lab-Modul ist
  # auf den HTTP-01-gatewayHTTPRoute-Solver am Cilium-Gateway zugeschnitten; hier
  # laufen die Zertifikate (noch) über traefik-Ingress.
  #
  # Warum Bootstrap statt ArgoCD: die Reihenfolge cert-manager → Ingress/Gateway
  # wird damit deterministisch statt sync-wave-abhängig. Angenehmer Nebeneffekt:
  # weil cert-manager MIT dem Cluster hochkommt (vor ArgoCD), existieren die CRDs
  # längst, wenn ArgoCD die ClusterIssuer synct — die
  # sync-wave-Annotationen "0"/"1" in charts/ sind dann nur noch Dokumentation.
  #
  # Die ClusterIssuer (letsencrypt-staging/-prod) bleiben BEWUSST in
  # charts/root-app/templates/letsencrypt-issuers.yaml: sie sind Konfiguration
  # (Kontakt-Mail, ACME-Server, Solver), keine Cluster-Infrastruktur, und ein
  # Wechsel staging↔prod soll ohne nixos-rebuild möglich sein — genau der Fall,
  # wenn beim Cutover das Let's-Encrypt-Prod-Limit (5 identische Zertifikate pro
  # Woche) droht.
  #
  # Leaf-Modul: nur services.k3s.manifests, kein k3s-Basismodul-Import.
  flake.modules.nixos.cert-manager =
    { lib, config, ... }:
    {
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        cert-manager.content = [
          {
            apiVersion = "helm.cattle.io/v1";
            kind = "HelmChart";
            metadata = {
              name = "cert-manager";
              namespace = "kube-system";
            };
            spec = {
              repo = "https://charts.jetstack.io";
              chart = "cert-manager";
              # Gepinnt wie vorher im Chart — cert-manager-Upgrades sind
              # CRD-Migrationen, die nicht nebenbei passieren sollen.
              version = "1.18.2";
              targetNamespace = "cert-manager";
              createNamespace = true;
              valuesContent = ''
                installCRDs: true
              '';
            };
          }
        ];
      };
    };
}
