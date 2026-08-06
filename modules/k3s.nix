{ inputs, ... }:
{
  # k3s für den netcup-ARM-Node — künftige Control-Plane der Flotte
  # (Fleet-Design §5). Bis zum Merge läuft dieser Cluster GETRENNT vom
  # azure-k3s-Lab (Entscheidung 2026-08-05).
  #
  # Deckungsgleich mit lab/modules/k3s.nix bei allem, was TEUER war zu lernen
  # (Node-Schutz, I/O-Priorität, CNI = Cilium, etcd). Unterschiede sind bewusst:
  #   • KEIN gVisor — hier laufen keine Agenten, nur Max' Dienste. Damit ist auch
  #     socketLB.hostNamespaceOnly unnötig (das war reiner gVisor-Workaround) und
  #     nix:0-Images (nix-snapshotter) sind hier ÜBERALL nutzbar, nicht nur
  #     teilweise wie im lab (nix:0 läuft nicht unter runsc).
  #   • KEIN Apiserver-Audit-Log — keine fremden Agent-ServiceAccounts.
  #   • traefik + servicelb bleiben ZUNÄCHST an: der velero/kopia-Restore soll
  #     like-for-like laufen und die Ingresses (steinaberfein.de,
  #     *.mauritiusberger.de) müssen ab Minute 1 wieder bedient werden. Die
  #     Gateway-API-CRDs + Ciliums GatewayClass kommen im selben Release mit
  #     (modules/gateway.nix), sodass Route für Route migriert werden kann,
  #     OHNE den Cutover an einem Ingress-Rewrite zu koppeln.
  flake.modules.nixos.k3s-netcup =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # Fleet-Adressplan — EINZIGE Quelle der Wahrheit, geteilt mit nix-config.
      # Über den Input, nicht relativ: dieses Repo liegt außerhalb von nix-config.
      net = import (inputs.nix-config + "/base/_network.nix");

      # ⚠️ TEMPORÄRER FALLBACK (2026-08-06). Der GEPINNTE nix-config-Input hat
      # `sites.netcup` noch als String ("10.32.0.0/16"); der Ausbau zum Attrset
      # (fqdn/publicIp/hostName) liegt lokal und ist NICHT gepusht. Genau daran ist
      # der erste Install-Versuch gescheitert — nach dem Wipe, beim Bauen der
      # Closure auf dem Ziel:
      #   error: expected a set but found a string: "10.32.0.0/16"
      # (nixos-anywhere nutzt den dirty Worktree von mschuett-lab, holt nix-config
      # aber aus git.)
      #
      # Sobald base/ gepusht und `nix flake update nix-config` gelaufen ist, greift
      # automatisch wieder der Adressplan und dieser Block kann ersatzlos weg.
      # `cluster.*` unten kommt weiterhin aus _network.nix — das existiert in der
      # gepinnten Revision bereits.
      nc =
        if builtins.isAttrs (net.sites.netcup or null) then
          net.sites.netcup
        else
          {
            fqdn = "v2202505270128345138.powersrv.de";
            publicIp = "152.53.15.24";
            hostName = "netcup";
          };

      isServer = config.services.k3s.role == "server";
    in
    {
      services.k3s = {
        enable = true;
        role = lib.mkDefault "server";

        # Neueste k3s-Release aus nixpkgs-unstable — gleiche Quelle und gleicher
        # Grund wie lab/modules/k3s.nix: 1.36 bringt nativen nix-snapshotter
        # (PR #13676). nixpkgs-26.05 hätte nur 1.35.6, und k3s_1_32 (die Version
        # des abgelösten Clusters) ist dort als EOL entfernt.
        package =
          inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s_1_36;

        # Datastore = embedded etcd statt kine/SQLite. Grund wie im lab: kine/SQLite
        # lief dort 2× in einen WAL/Lock-Stall (Slow-SQL bis 1,5 h, API + sshd tot),
        # obwohl CPU/RAM/IOPS Reserve hatten. Für eine Control-Plane, an der später
        # Agents hängen, ist das keine Option. Nur beim NEUAUFBAU setzbar.
        clusterInit = lib.mkIf isServer true;

        extraFlags =
          [
            "--write-kubeconfig-mode=0600"
            # nix-snapshotter: Voraussetzung für nix:0-Image-Refs (Airgap ohne
            # Registry). Fällt für normale OCI-Refs auf overlayfs durch.
            "--snapshotter=nix"
            # Node-Schutz. eviction-hard hochgesetzt (Default 100Mi → 250Mi): gibt
            # dem kubelet VORLAUF, einen Burstable-Pod zu evicten, BEVOR der
            # kernel-OOM-Killer greift und System/kubelet trifft → Node NotReady.
            # Genau das riss 2026-08-02 den 4-GB-Lab-Worker. Hier besonders
            # relevant: mongod + postgres + paperless auf 7,7 GiB.
            "--kubelet-arg=system-reserved=cpu=100m,memory=512Mi"
            "--kubelet-arg=kube-reserved=cpu=100m,memory=256Mi"
            "--kubelet-arg=eviction-hard=memory.available<250Mi,nodefs.available<10%"
          ]
          ++ lib.optionals isServer [
            # Cilium übernimmt CNI + NetworkPolicy.
            "--flannel-backend=none"
            "--disable-network-policy"
            # KPR: k3s-embedded kube-proxy AUS → Cilium-eBPF. Voraussetzung für die
            # Cilium Gateway API (siehe modules/gateway.nix).
            "--disable-kube-proxy"

            # traefik + servicelb bleiben BEWUSST aktiviert (nicht disabled wie im
            # lab) — Begründung oben im Modulkopf. Beim Umstieg auf Gateway API:
            #   "--disable=traefik" "--disable=servicelb"
            # ergänzen und Ciliums LB-IPAM-Pool setzen.

            # Der Cluster wird über den netcup-FQDN erreicht; ohne SAN schlägt
            # jeder externe kubectl-Zugriff mit Zertifikatsfehler fehl.
            "--tls-san=${nc.fqdn}"
            "--tls-san=${nc.publicIp}"

            # ── Pod-/Service-CIDR: WEG von den k3s-Defaults ────────────────────
            # Verifiziert am 2026-08-05 auf dem laufenden Cluster: er fuhr die
            # k3s-DEFAULTS (Pod 10.42.0.0/16, Service 10.43.0.0/16) — genau der
            # Fall, den Fleet-Design §3.1 als BLOCKIEREND markiert: 10.42.0.0/16
            # kollidiert frontal mit dem Azure-VNet (azure-k3s liegt in
            # 10.42.1.0/24). Beim Merge (§5) würden Pod-IPs auf beiden Seiten
            # verschiedene Maschinen bedeuten → Routing bricht asymmetrisch.
            #
            # Ein CIDR-Wechsel ist ein Cluster-NEUAUFBAU, kein Flag-Flip. Dieser
            # Wiederaufbau ist die EINZIGE günstige Gelegenheit.
            #
            # Restore-sicher: velero verwirft `spec.clusterIP` beim Restore von
            # Services (eingebaute RestoreItemAction, außer headless) → neue IPs im
            # neuen Service-CIDR. In keinem Chart (mschuett-lab,
            # not-just-a-developer.com, bricklink) ist 10.42/10.43 hartcodiert —
            # am 2026-08-05 geprüft.
            "--cluster-cidr=${net.cluster.podCidr}"
            "--service-cidr=${net.cluster.serviceCidr}"
            "--cluster-dns=${net.cluster.clusterDns}"
          ];

        # Cilium als CNI. Version 1.18.12 wie im lab und aus denselben Gründen:
        # behebt den Gateway-API-Bug, bei dem ein HTTP-:80-Listener ohne hostname
        # neben einem HTTPS-Listener mit hostname aus der CiliumEnvoyConfig fällt
        # (→ :80 = 404 → ACME-HTTP-01 scheitert; cilium#36750/#44123, Fix #44492 ab
        # 1.18.8). 1.18.12 ist das neueste 1.18 UND frei vom Opaque-Secret-Regress
        # (#45705, nur 1.19.x).
        #
        # Bewusst NICHT aus dem lab übernommen:
        #   • upgradeCompatibility — dies ist ein FRISCHER Cluster, kein 1.17→1.18.
        #   • socketLB.hostNamespaceOnly — reiner gVisor-Workaround, hier kein gVisor.
        manifests = lib.mkIf isServer {
          cilium.content = [
            {
              apiVersion = "helm.cattle.io/v1";
              kind = "HelmChart";
              metadata = {
                name = "cilium";
                namespace = "kube-system";
              };
              spec = {
                repo = "https://helm.cilium.io/";
                chart = "cilium";
                version = "1.18.12";
                targetNamespace = "kube-system";
                # CNI-Henne-Ei: bootstrap=true lässt den Install-Job früh laufen und
                # alle Taints tolerieren (sonst bleibt der frische Node NotReady).
                bootstrap = true;
                valuesContent = ''
                  operator:
                    replicas: 1
                  ipam:
                    mode: kubernetes
                  # KPR ist Voraussetzung für die Cilium Gateway API. k8sServiceHost
                  # MUSS die direkte API-Adresse sein — ohne kube-proxy routet die
                  # kubernetes-ClusterIP beim Bootstrap noch nicht.
                  # Single-Node ohne privates VNet: Node-IP == öffentliche IP.
                  kubeProxyReplacement: true
                  k8sServiceHost: "${nc.publicIp}"
                  k8sServicePort: "6443"
                  # GatewayClass "cilium" bereitstellen. CRDs kommen aus
                  # modules/gateway.nix — Cilium bringt sie NICHT selbst mit.
                  gatewayAPI:
                    enabled: true
                '';
              };
            }
          ];
        };
      };

      # k3s-containerd braucht nix im Service-PATH (nix-snapshotter).
      # pkgs.gvisor bewusst NICHT — hier läuft kein runsc.
      systemd.services.k3s.path = [ pkgs.nix ];

      # I/O-/CPU-Priorität für etcd + kubelet. Root-Cause 2026-07-25 im lab: ein
      # nix-Build schrieb ~800 MB in 7 min auf DIESELBE Platte wie etcd →
      # fsync-Latenz ~1 s → k3s-Crash → Node NotReady → taint-eviction löschte alle
      # Pods. Hier ist die Co-Location noch enger: EINE vda für /nix UND etcd.
      systemd.services.k3s.serviceConfig = {
        IOWeight = 1000;
        CPUWeight = 1000;
        IODeviceLatencyTargetSec = "/ 20ms";
        OOMScoreAdjust = -900;
      };

      networking.firewall = {
        enable = true;
        allowedTCPPorts = [
          22
          80
          443
          6443
        ];
        # Cilium-VXLAN zwischen Nodes. Heute Single-Node, aber ohne den Port
        # scheitert der Agent-Beitritt beim Merge still.
        allowedUDPPorts = [ 8472 ];
        # Cilium-Datapath-Interfaces vertrauen, sonst verwirft INPUT Pod-Traffic.
        trustedInterfaces = [
          "cilium_host"
          "cilium_net"
          "cilium_vxlan"
          "lxc+"
        ];
      };

      environment.systemPackages = with pkgs; [
        kubectl
        kubernetes-helm
        cilium-cli
        velero
        kubeseal
      ];
    };
}
