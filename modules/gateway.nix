{ ... }:
{
  # Gateway-API-CRDs für Ciliums GatewayClass.
  #
  # Leaf-Modul nach der Konvention aus nix-config/lab (monitoring, embeddings,
  # gateway): setzt AUSSCHLIESSLICH services.k3s.manifests und importiert das
  # k3s-Basismodul NICHT — sonst entsteht ein Diamond auf
  # services.k3s.package. Genau ein Modul pro Host darf `package` setzen, das ist
  # modules/k3s.nix.
  #
  # Cilium bringt die CRDs NICHT selbst mit; ohne sie startet der Operator mit
  # gatewayAPI.enabled=true nicht.
  #
  # ⚠️ VERSION EXAKT v1.3.0 PINNEN. Cilium 1.18 zielt auf Gateway API v1.3.0;
  # v1.5.x bricht den Cilium-Operator (cilium#45139). Nicht „mal aktualisieren".
  #
  # Nur der Standard-Kanal (GatewayClass/Gateway/HTTPRoute/GRPCRoute/
  # ReferenceGrant). TLSRoute wäre `experimental` — für steinaberfein.de und
  # *.mauritiusberger.de nicht nötig (HTTPS terminiert am Gateway).
  flake.modules.nixos.gateway =
    { pkgs, lib, config, ... }:
    {
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        # Rohe YAML via fetchurl gevendort → airgap, kein Runtime-Pull.
        # sha256 identisch zu nix-config/lab/modules/gateway.nix (gleiche Datei).
        gateway-api-crds.source = pkgs.fetchurl {
          url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml";
          sha256 = "1fc282i3gifmfmw8sl6ph9wq133z2fl2n2f8imfwa3s5a5f6sybq";
        };
      };

      # ── Noch NICHT nötig: LB-IPAM ───────────────────────────────────────────
      # Solange servicelb (klipper) aktiv ist, bekommt der Gateway-Service seine
      # Adresse von dort. Erst wenn in modules/k3s.nix `--disable=servicelb`
      # gesetzt wird, braucht der Gateway-LoadBalancer einen Cilium-Pool:
      #
      #   services.k3s.manifests.gateway-lbipam.content = [{
      #     apiVersion = "cilium.io/v2alpha1";
      #     kind = "CiliumLoadBalancerIPPool";
      #     metadata.name = "netcup-node-pool";
      #     spec = {
      #       allowFirstLastIPs = "Yes";              # einzige /32 nutzbar machen
      #       blocks = [ { cidr = "${nc.publicIp}/32"; } ];
      #     };
      #   }];
      #
      # Anders als in Azure (dort NATet die Public-IP auf eine Private-IP) ist die
      # Node-IP hier die öffentliche Adresse selbst — der Pool ist also direkt
      # sites.netcup.publicIp/32 aus base/_network.nix.
    };
}
