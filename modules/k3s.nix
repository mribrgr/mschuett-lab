{ inputs, ... }:
{
  # k3s für den netcup-ARM-Single-Node.
  #
  # ABSICHTLICH NICHT das lab/modules/k3s.nix: dort läuft Cilium (CNI+KPR),
  # gVisor, embedded etcd und traefik/servicelb sind ABGESCHALTET. Dieser
  # Cluster fährt seit 430 Tagen den k3s-Standard-Stack, und der Wiederaufbau
  # soll ihn 1:1 reproduzieren, damit die velero-/kopia-Restores unverändert
  # greifen:
  #   • flannel (VXLAN)      → Pod-Netz 10.42.0.0/16 (kein Konflikt, netcup ist kein VNet)
  #   • traefik              → alle Ingresses (steinaberfein.de, *.mauritiusberger.de)
  #   • servicelb (klipper)  → traefik bekommt darüber die öffentliche IP
  #   • local-path           → JEDE PVC dieses Clusters (mongodb 7,5 GB, postgres, paperless …)
  # Wird einer dieser Defaults abgeschaltet, sind die Restores unbrauchbar.
  flake.modules.nixos.k3s-netcup =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      services.k3s = {
        enable = true;
        role = lib.mkDefault "server";

        # Neueste k3s-Release aus nixpkgs-unstable — gleiche Quelle/Muster wie
        # lab/modules/k3s.nix (dort k3s_1_36). Der Cluster wird KOMPLETT neu
        # aufgebaut, es gibt also keinen In-Place-Upgrade-Pfad, der einen kleinen
        # Versionssprung erzwingen würde. Der abgelöste Cluster fuhr 1.32.5+k3s1
        # (in nixpkgs 26.05 als EOL entfernt) — die velero-Backups daraus sind
        # Ressourcen-Manifeste, kein etcd-Dump, und werden von 1.36 gelesen.
        #
        # nixpkgs-26.05 hätte nur 1.35.6; unstable liefert 1.36.2+k3s1.
        package =
          inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s_1_36;

        # kubeconfig für den Betrieb lesbar machen (Single-Node, root-only Box).
        extraFlags = [
          "--write-kubeconfig-mode=0600"
          # Der Cluster wird über den netcup-FQDN erreicht; ohne SAN schlägt
          # jeder kubectl-Zugriff von außen mit Zertifikatsfehler fehl.
          "--tls-san=v2202505270128345138.powersrv.de"
          "--tls-san=152.53.15.24"
          # Node-Schutz: kubelet reserviert sich CPU/RAM, damit ein Pod-Spike
          # (mongod auf 7,7-GB-Box) nicht kubelet/k3s selbst mitreißt.
          "--kubelet-arg=system-reserved=cpu=100m,memory=512Mi"
          "--kubelet-arg=kube-reserved=cpu=100m,memory=256Mi"
          "--kubelet-arg=eviction-hard=memory.available<250Mi,nodefs.available<10%"
        ];
      };

      # etcd/kubelet-Priorität wie im lab: ein nix-Build darf die einzige vda
      # nicht sättigen, sonst reißt die Datastore-fsync-Latenz → k3s-Crash.
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
        # flannel-VXLAN zwischen Nodes (heute Single-Node, aber ohne den Port
        # scheitert jede spätere Agent-Erweiterung still).
        allowedUDPPorts = [ 8472 ];
        # k3s-Datapath-Interfaces vertrauen, sonst verwirft INPUT Pod-Traffic.
        trustedInterfaces = [
          "cni0"
          "flannel.1"
        ];
      };

      environment.systemPackages = with pkgs; [
        kubectl
        kubernetes-helm
        velero
        kubeseal
      ];
    };
}
