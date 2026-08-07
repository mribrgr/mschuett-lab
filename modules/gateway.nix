{ inputs, ... }:
{
  # Gateway-API-CRDs + LB-IPAM für Ciliums GatewayClass.
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
  # ⚠️ VERSION MUSS ZUR CILIUM-VERSION PASSEN. Seit 2026-08-07 läuft Cilium 1.20.0,
  # und dessen Doku nennt die getestete Paarung explizit:
  #   „Cilium supports Gateway API v1.6.1 […] all the Core conformance tests are passed"
  # Deshalb v1.6.1, NICHT v1.3.0 (das war die Paarung für Cilium 1.18).
  #
  # Historie, damit niemand zurückspringt: v1.5.0 brach den Cilium-Operator
  # (cilium#45139) — geschlossen und in 1.20 behoben. Wer Cilium wieder auf
  # 1.18/1.19 zurückzieht, muss auch hier zurück.
  #
  # Nur der Standard-Kanal (GatewayClass/Gateway/HTTPRoute/GRPCRoute/
  # ReferenceGrant). TLSRoute wäre `experimental` — für steinaberfein.de und
  # *.mauritiusberger.de nicht nötig (HTTPS terminiert am Gateway).
  flake.modules.nixos.gateway =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      net = import (inputs.nix-config + "/base/_network.nix");
      # Gleicher temporärer Fallback wie in modules/k3s.nix — der gepinnte
      # nix-config-Input hat sites.netcup noch als String. Entfällt mit dem Push.
      nc =
        if builtins.isAttrs (net.sites.netcup or null) then
          net.sites.netcup
        else
          { publicIp = "152.53.15.24"; };
    in
    {
      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        # Rohe YAML via fetchurl gevendort → airgap, kein Runtime-Pull.
        # sha256 via nix-prefetch-url ermittelt (2026-08-07). Weicht bewusst von
        # nix-config/lab/modules/gateway.nix ab — das lab steht noch auf
        # v1.3.0/Cilium 1.18.
        gateway-api-crds.source = pkgs.fetchurl {
          url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml";
          sha256 = "0wrs0v5p9w9gxsqplsvinw7rv86gszm1jhr6fg4l13mx5br33n94";
        };

        # LB-IPAM: seit `--disable=servicelb` (2026-08-07) gibt es kein klipper mehr,
        # das dem Gateway-Service eine Adresse gibt. Cilium vergibt sie stattdessen
        # aus diesem Pool.
        #
        # Anders als im lab/Azure (dort NATet Azure eine Public-IP auf eine
        # Private-IP, weshalb dort die Node-Private-IP im Pool steht) ist die
        # Node-IP hier die ÖFFENTLICHE Adresse selbst — der Pool ist also
        # sites.netcup.publicIp/32.
        #
        # allowFirstLastIPs=Yes ist bei /32 zwingend: sonst gälte die einzige
        # Adresse als Netz-/Broadcast-Adresse und der Pool wäre leer.
        gateway-lbipam.content = [
          {
            apiVersion = "cilium.io/v2alpha1";
            kind = "CiliumLoadBalancerIPPool";
            metadata.name = "netcup-node-pool";
            spec = {
              allowFirstLastIPs = "Yes";
              blocks = [ { cidr = "${nc.publicIp}/32"; } ];
            };
          }
        ];
      };
    };
}
