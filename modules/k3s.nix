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

            # traefik + servicelb ABGESCHALTET (2026-08-07, Umstieg auf Gateway API).
            # Ingress-Traffic läuft ab jetzt über Ciliums GatewayClass; die Adresse
            # vergibt Ciliums LB-IPAM statt klipper (siehe modules/gateway.nix).
            #
            # ⚠️ REIHENFOLGE beim Umstieg: traefik bringt eigene Gateway-API-CRDs in
            # v1.5.1 mit — genau die Version, die den Cilium-Operator bricht
            # (cilium#45139). Erst traefik weg (nimmt seine CRDs mit), dann die
            # gepinnten v1.6.1-CRDs aus modules/gateway.nix. Andersherum gibt es den
            # Ownership-Konflikt „invalid ownership metadata" vom 2026-08-06.
            "--disable=traefik"
            "--disable=servicelb"

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

        # Cilium als CNI.
        #
        # ── Upgrade-Pfad 1.18.12 → 1.19.6 → 1.20.0 (Stand 2026-08-07) ────────────
        # Ziel ist 1.20.0 (neueste stabile Release, 2026-07-29) zusammen mit
        # Gateway API v1.6.1 — laut Cilium-1.20-Doku genau die getestete Paarung
        # („Cilium supports Gateway API v1.6.1 […] all the Core conformance tests
        # are passed"). Dorthin aber in ZWEI Schritten: Cilium unterstützt nur
        # EINEN Minor-Sprung am Stück, 1.18 → 1.20 direkt ist nicht supported.
        # Schritt 1 (1.19.6) verifiziert 2026-08-07: Cilium Ok, KPR True, Cluster health
        # 1/1, alle Hosts extern erreichbar. Jetzt Schritt 2: 1.20.0.
        #
        # Die zwei Gründe, aus denen das lab bewusst auf 1.18.12 stehen blieb, sind
        # upstream erledigt (beide Issues geschlossen):
        #   • #45705 „Gateway API: Cilium pre-creates TLS secrets as Opaque,
        #     blocking cert-manager" — geschlossen 2026-05-04.
        #   • #45139 „Cilium breaks with gateway-api v1.5.0" — geschlossen.
        # Der ältere Gateway-:80-Listener-Bug (#36750/#44123, Fix #44492 ab 1.18.8)
        # ist in 1.19/1.20 ohnehin enthalten.
        #
        # upgradeCompatibility hält die BPF-Map-Formate über den Sprung
        # abwärtskompatibel und minimiert den Datapath-Churn beim Agent-Neustart
        # (Single-Node = kein Failover, kurzer Netz-Blip). Nach verifiziertem
        # 1.19-Betrieb auf "1.19" hochziehen bzw. beim Schritt auf 1.20 anpassen.
        #
        # Weiterhin NICHT übernommen: socketLB.hostNamespaceOnly — reiner
        # gVisor-Workaround, hier läuft kein gVisor (siehe TODO.md 0e).
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
                version = "1.20.0";
                targetNamespace = "kube-system";
                # CNI-Henne-Ei: bootstrap=true lässt den Install-Job früh laufen und
                # alle Taints tolerieren (sonst bleibt der frische Node NotReady).
                bootstrap = true;
                valuesContent = ''
                  # Hält BPF-Map-Formate über den Minor-Sprung abwärtskompatibel.
                  upgradeCompatibility: "1.19"
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
                  # Gateway API AN (2026-08-07). Stellt die GatewayClass "cilium"
                  # bereit. Setzt kubeProxyReplacement voraus (oben) und die CRDs aus
                  # modules/gateway.nix (v1.6.1 — die von Cilium 1.20 getestete
                  # Paarung). Cilium bringt die CRDs NICHT selbst mit.
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

      # ── Host-Firewall BLEIBT AN ───────────────────────────────────────────────
      # Bewusst anders als nix-config/lab/hosts/azure-k3s (dort `firewall.enable =
      # false`, weil "die NixOS-Host-Firewall bricht Ciliums Datapath"). Das ist
      # richtig beobachtet, aber die Diagnose war unvollständig: es ist NICHT die
      # Filterung in INPUT, sondern AUSSCHLIESSLICH der Reverse-Path-Filter.
      #
      # Analyse am 2026-08-06 auf diesem Host (nach dem Erstinstall lief nichts:
      # coredns/metrics-server/local-path/alle helm-install-Jobs in CrashLoopBackOff,
      # Symptom `read udp 10.60.0.16->46.38.225.230:53: i/o timeout`):
      #
      #   iptables -t mangle -L nixos-fw-rpfilter -n -v
      #     4011K RETURN  rpfilter validmark
      #      137K DROP                          <- 44 Pakete/20s, steigend
      #
      # Mechanik: `checkReversePath` (Default "loose") legt die Chain
      # `nixos-fw-rpfilter` in der MANGLE-Tabelle an, aufgerufen aus mangle
      # PREROUTING, und zwar mit `-m rpfilter --validmark`. `--validmark` lässt den
      # Reverse-Path-Lookup die fwmark des Pakets BERÜCKSICHTIGEN. Cilium arbeitet
      # genau damit:
      #     ip rule:  9: from all fwmark 0x200/0xf00 lookup 2004
      # Der Lookup landet dadurch in Ciliums Tabelle 2004 statt in `main`, der
      # Reverse-Path validiert dort nicht → DROP.
      #
      # Zwei Konsequenzen, die die Fehlersuche so zäh machten:
      #   1. mangle PREROUTING läuft VOR INPUT. `trustedInterfaces` (cilium_host,
      #      lxc+ …) greift also nie — genau das meinte lab mit "egal wie viele
      #      Interfaces getrustet werden". Die lxc+-Accept-Regel stand auf 0 Paketen.
      #      Die INPUT-Filterung war nie das Problem.
      #   2. `logReversePathDrops` ist per Default FALSE → die 137K Drops tauchen in
      #      keinem Log auf. `journalctl -k | grep refused` war leer.
      #
      # Fix: NUR den rpfilter abschalten, die Firewall bleibt vollständig aktiv.
      # Das ist auch die dokumentierte Voraussetzung für Cilium auf NixOS.
      networking.firewall = {
        enable = true;

        # Siehe Analyse oben. Kein Verzicht auf Anti-Spoofing: der Schutz wird
        # unten per Kernel-sysctl auf dem externen Interface wiederhergestellt —
        # dort ohne `--validmark` und damit ohne Cilium-Kollision.
        checkReversePath = false;

        allowedTCPPorts = [
          22
          80
          443
          6443
          # kubelet-API. Heute unkritisch (apiserver und kubelet liegen auf DEMSELBEN
          # Host, der Verkehr läuft über `lo` und damit über trustedInterfaces), aber
          # zwingend, sobald die Control-Plane die Azure-Agents erreichen muss bzw.
          # deren kubelets diese CP. Ohne den Port scheitern später `kubectl logs`,
          # `exec` und metrics-server-Scrapes — mit einem Timeout, der wie ein
          # CNI-Problem aussieht.
          10250
          # cilium-health. Cilium läuft auch ohne, meldet dann aber keine
          # Konnektivitätsinfos zwischen Nodes (Cilium System Requirements). Nur
          # node-to-node relevant, also ebenfalls Vorbereitung auf den Merge.
          4240
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

      # Anti-Spoofing-Ersatz für den abgeschalteten iptables-rpfilter (s. o.).
      # Kernel-rp_filter statt `-m rpfilter --validmark`: der Kernel-Check kennt die
      # fwmark-Regeln NICHT und kollidiert deshalb nicht mit Ciliums Policy-Routing.
      #
      # Nur auf dem EXTERNEN Interface. Cilium schreibt selbst
      # /etc/sysctl.d/99-zzz-override_cilium.conf mit
      #   net.ipv4.conf.all.rp_filter        = 0
      #   net.ipv4.conf.{lxc*,cilium_*}.rp_filter = 0
      # und lässt die physische NIC absichtlich unangetastet — der Kernel bildet
      # max(all, interface), also bleibt hier effektiv 2 (loose) auf enp7s0 und 0 auf
      # allen Cilium-Interfaces. Genau die Aufteilung, die Cilium erwartet.
      #
      # 2 = loose (Quelle muss über IRGENDEIN Interface routbar sein), nicht 1 =
      # strict: strict bricht asymmetrisches Routing und damit ebenfalls Cilium.
      #
      # ⚠️ Interfacename hartcodiert. Diese VM hat stabil `enp7s0` (verifiziert
      # 2026-08-06). Bei Hardware-/Providerwechsel mitziehen, sonst greift der
      # Spoofing-Schutz still nicht mehr.
      boot.kernel.sysctl."net.ipv4.conf.enp7s0.rp_filter" = 2;

      environment.systemPackages = with pkgs; [
        kubectl
        kubernetes-helm
        cilium-cli
        velero
        kubeseal
      ];
    };
}
