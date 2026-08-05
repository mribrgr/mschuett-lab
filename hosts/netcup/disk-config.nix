{ ... }:
{
  # disko-Layout für die netcup-ARM-VPS (vda, 512 GB).
  #
  # Übernommen aus dem alten disk-config.nix im Repo-Root. Bewusst BEIBEHALTEN
  # (ESP + LVM-PV + ext4-root), obwohl die laufende Ubuntu-Installation ein
  # anderes Layout hat (vda1 256M /boot/efi, vda2 512M /boot, vda3 511G /) —
  # disko partitioniert beim Install ohnehin neu, und LVM lässt später
  # Volume-Erweiterung/Snapshots zu, ohne die Partitionstabelle anzufassen.
  #
  # ESP liegt auf /boot (nicht /boot/efi): systemd-boot erwartet genau das.
  flake.modules.nixos.netcup-disk-config =
    { lib, ... }:
    {
      disko.devices = {
        disk.disk1 = {
          device = lib.mkDefault "/dev/vda";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              esp = {
                name = "ESP";
                size = "512M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };
              root = {
                name = "root";
                size = "100%";
                content = {
                  type = "lvm_pv";
                  vg = "pool";
                };
              };
            };
          };
        };

        lvm_vg.pool = {
          type = "lvm_vg";
          lvs.root = {
            size = "100%FREE";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
}
