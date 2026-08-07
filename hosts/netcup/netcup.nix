{ self, inputs, ... }:
{
  # netcup VPS 1000 ARM G11 SE — Single-Node k3s.
  #
  # Hardware (per SSH am 2026-08-05 am laufenden System erhoben, siehe
  # ~/mschuett-lab-migration/hardware-inventory.json):
  #   netcup KVM Server "VPS 1000 ARM G11 SE"
  #   ARM Neoverse-N1, 6 Kerne, aarch64
  #   7,7 GiB RAM, kein Swap
  #   vda 512 GB (virtio-blk), UEFI mit vorhandenen efivars
  #   6 virtio-Geräte, Netz über eth0
  #
  # ⚠️ Es gibt hier ABSICHTLICH kein facter.json. Das alte facter.json im
  # Repo-Root stammte vom VORGÄNGER-Server (v2202504270128336125.luckysrv.de,
  # erzeugt 2025-05-02) und hätte beim Install falsche Hardware beschrieben —
  # das Flake `throw`t nur bei FEHLENDEM, nicht bei veraltetem Report. Ein
  # korrektes facter.json kann nur im kexec-Installer entstehen:
  #   nixos-anywhere --generate-hardware-config nixos-facter ./facter.json
  # Bis dahin beschreibt dieses Modul die Hardware explizit.
  configurations.nixos.netcup.module =
    { lib, ... }:
    {
      imports = [
        self.outputs.modules.nixos.disko
        self.outputs.modules.nixos.netcup-disk-config
        self.outputs.modules.nixos.ssh
        self.outputs.modules.nixos.user-root
        # agenix. Setzt age.identityPaths auf /etc/ssh/ssh_host_ed25519_key —
        # genau der Key, der seit 2026-08-07 Recipient von
        # secrets/sealed-secrets-master-keys.age ist. Damit kann der Host seine
        # Secrets zur Aktivierungszeit selbst entschlüsseln (verifiziert: der
        # Host-Key liest alle 12 Keys) statt sie von Hand einzuspielen.
        self.outputs.modules.nixos.secrets
        self.outputs.modules.nixos.k3s-netcup
        # Leaf-Module: setzen NUR services.k3s.manifests, kein k3s-Base-Import →
        # kein Diamond auf services.k3s.package.
        #
        # Reihenfolge der Zeilen ist irrelevant (Nix-Module sind kommutativ); die
        # LAUFZEIT-Reihenfolge ergibt sich daraus, dass all das k3s-Bootstrap ist
        # und damit VOR ArgoCD existiert. Genau das ist der Zweck:
        #   sealed-secrets  da, bevor irgendein SealedSecret gesynct wird
        #   cert-manager    CRDs da, bevor ArgoCD die ClusterIssuer anlegt
        #   gateway         Gateway-API-CRDs da, bevor Cilium die GatewayClass baut
        self.outputs.modules.nixos.sealed-secrets
        self.outputs.modules.nixos.cert-manager
        self.outputs.modules.nixos.argocd

        # Gateway-API-CRDs (v1.6.1) + LB-IPAM. Aktiviert 2026-08-07 zusammen mit
        # `--disable=traefik/--disable=servicelb` und cilium gatewayAPI=true.
        # Die Reihenfolge ist wichtig: traefik muss WEG sein (es bringt eigene
        # Gateway-CRDs in v1.5.1 mit, die den Cilium-Operator brechen), bevor diese
        # v1.6.1-CRDs greifen.
        self.outputs.modules.nixos.gateway
      ];

      nixpkgs.hostPlatform = "aarch64-linux";
      # Literal, nicht aus _network.nix: die gepinnte nix-config-Revision hat
      # `sites.netcup` noch als String — siehe den Fallback-Block in
      # modules/k3s.nix. Nach dem Push von base/ kann das wieder auf
      # `net.sites.netcup.hostName` zeigen.
      networking.hostName = "netcup";
      networking.domain = "powersrv.de";

      # systemd-boot statt des alten GRUB-mit-efiInstallAsRemovable: efivars sind
      # auf dieser Box vorhanden (/sys/firmware/efi/efivars), damit ist der
      # Removable-Fallback nicht nötig.
      # FALLBACK, falls netcup NVRAM doch nicht persistiert und die Box nach dem
      # Install nicht bootet: systemd-boot aus, dafür
      #   boot.loader.grub = { enable = true; efiSupport = true;
      #                        efiInstallAsRemovable = true; devices = [ "nodev" ]; };
      # (schreibt \EFI\BOOT\BOOTAA64.EFI, bootet ohne NVRAM-Eintrag).
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # virtio-Treiber ins initrd: ohne virtio_pci + virtio_blk findet der Kernel
      # die Root-Disk nicht und paniced vor dem Switch-Root.
      boot.initrd.availableKernelModules = [
        "virtio_pci"
        "virtio_blk"
        "virtio_scsi"
        "virtio_net"
        "sd_mod"
      ];
      # LVM-root: ohne dm_mod/lvm findet initrd das Logical Volume nicht.
      boot.initrd.kernelModules = [ "dm_mod" ];

      # netcup ARM: serielle Konsole liegt auf ttyAMA0 (VNC zeigt tty0).
      boot.kernelParams = [
        "console=tty0"
        "console=ttyAMA0,115200"
      ];

      # 7,7 GiB ohne Swap ist für mongod + postgres + paperless knapp. zram
      # kostet keinen Plattenplatz und federt Spitzen ab, statt den OOM-Killer
      # den Node zu treffen (vgl. eviction-hard in modules/k3s.nix).
      zramSwap = {
        enable = true;
        memoryPercent = 25;
      };

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Erstinstallation dieser Generation. NICHT nachträglich hochziehen.
      system.stateVersion = "25.11";
    };
}
