{ inputs, ... }:
{
  # ══════════════════════════════════════════════════════════════════════════════
  # VORBEREITUNG — NOCH NICHT AKTIV.
  #
  # Dieses Modul ist bewusst NICHT in hosts/netcup/netcup.nix importiert. Es ist
  # fertig zum Einschalten, aber drei Dinge müssen vorher entschieden/erledigt
  # sein (siehe „BLOCKER" unten). Vorher einzuschalten bringt nichts und kann
  # Volumes kaputtmachen.
  # ══════════════════════════════════════════════════════════════════════════════
  #
  # Warum überhaupt Longhorn: heute liegt JEDE PVC auf `local-path` (RWO,
  # node-lokal). Auf einem Single-Node ist das in Ordnung, aber sobald die
  # Azure-Agents dazukommen (Fleet-Design §5), pinnt local-path jeden Pod
  # dauerhaft auf netcup — kein Rescheduling, keine Replikation. Longhorn löst
  # genau das.
  #
  # ⚠️ Auf einem Single-Node bringt Longhorn KEINEN Replikationsgewinn und kostet
  # nur Overhead. Sinnvoll wird es erst MIT dem Merge.
  #
  # ── BLOCKER 1: NixOS-Pfade (longhorn#2166, seit 2021 OFFEN) ───────────────────
  # Longhorn `nsenter`t in den Host-Namespace und erwartet `iscsiadm`, `mount`
  # usw. an FHS-Pfaden, die es auf NixOS nicht gibt. Es gibt bis heute KEINE
  # native Unterstützung. Der von nixpkgs dokumentierte Weg
  # (pkgs/applications/networking/cluster/k3s/docs/examples/STORAGE.md) ist, allen
  # Longhorn-Pods per Kyverno-ClusterPolicy ein PATH-Env unterzuschieben:
  #
  #   /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\
  #   /run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin
  #
  # Das heißt: Kyverno als zusätzlicher Admission-Controller im Cluster. Vor dem
  # Einschalten entscheiden:
  #   (a) Kyverno installieren (nixpkgs-Weg, am besten dokumentiert), oder
  #   (b) die NixOS-gepatchten Longhorn-Images der Community nutzen (weniger
  #       Infrastruktur, dafür Fremd-Images statt der offiziellen), oder
  #   (c) Longhorn lassen und stattdessen bei local-path bleiben und die
  #       Workloads per nodeSelector pinnen (kein Rescheduling, aber ehrlich
  #       einfach).
  #
  # ── BLOCKER 2: Backup-Target hängt am netbird-Mesh ────────────────────────────
  # Das NAS exportiert /srv/backup/longhorn bereits per NFSv4 — der Export ist in
  # nix-config/homelab/modules/features/nas-backup-target.nix fertig und im
  # nas-Host importiert. Er ist aber auf `mesh.cidr` beschränkt, und der steht in
  # base/_network.nix noch auf PLATZHALTER (`verified = false`). Ohne Mesh keine
  # Route netcup → NAS, also kein Backup-Target.
  #
  # ── BLOCKER 3: Migration der bestehenden Daten ────────────────────────────────
  # Die vorhandenen PVCs (postgres 88M, paperless 85M+48M, n8n 26M, grocy, signal)
  # liegen auf local-path. Ein Wechsel der StorageClass migriert NICHT automatisch
  # — pro Volume braucht es velero-Restore in eine neue PVC oder ein manuelles
  # Kopieren. Reihenfolge: erst Longhorn lauffähig, dann Volume für Volume.
  flake.modules.nixos.longhorn =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      net = import (inputs.nix-config + "/base/_network.nix");
    in
    {
      # ── Host-Voraussetzungen (aus dem nixpkgs-k3s-STORAGE.md) ─────────────────
      # Longhorn braucht iscsid auf JEDEM Node — es hängt Volumes per iSCSI ein.
      services.openiscsi = {
        enable = true;
        # Der Initiator-Name muss clusterweit eindeutig sein; nixpkgs empfiehlt
        # genau dieses Schema.
        name = "${config.networking.hostName}-initiatorhost";
      };

      # NFSv4-Client: für das Backup-Target (NAS) UND für RWX-Volumes, die
      # Longhorn intern über einen NFS-Share bereitstellt.
      environment.systemPackages = [ pkgs.nfs-utils ];

      services.k3s.manifests = lib.mkIf (config.services.k3s.role == "server") {
        longhorn.content = [
          {
            apiVersion = "helm.cattle.io/v1";
            kind = "HelmChart";
            metadata = {
              name = "longhorn";
              namespace = "kube-system";
            };
            spec = {
              repo = "https://charts.longhorn.io";
              chart = "longhorn";
              # 1.12.0 = neueste STABILE Release (2026-06-02). 1.12.1 existiert
              # bisher nur als rc1/rc3, 1.11.3 ist der letzte 1.11-Patch.
              version = "1.12.0";
              targetNamespace = "longhorn-system";
              createNamespace = true;
              valuesContent = ''
                defaultSettings:
                  # Ein Node → nur eine Replica möglich. Beim Merge auf 2–3 hochziehen,
                  # sonst meldet Longhorn "Degraded" für jedes Volume.
                  defaultReplicaCount: 1

                  # Backup-Ziel: NFS-Export des NAS. Longhorn kann NFS direkt, deshalb
                  # dort bewusst kein MinIO/S3 (ein Dienst weniger, keine Credentials).
                  #
                  # ⚠️ PLATZHALTER — die Adresse muss die netbird-Mesh-IP des NAS sein,
                  # nicht die LAN-Adresse ${net.sites.home.hosts.nas}: netcup steht nicht
                  # im Heimnetz. Eintragen, sobald das Mesh existiert und
                  # base/_network.nix mesh.cidr verifiziert ist.
                  # backupTarget: nfs://<nas-mesh-ip>:/srv/backup/longhorn

                  # local-path bleibt vorerst Default-StorageClass; Longhorn wird
                  # explizit angefordert, bis die Migration durch ist.
                  defaultDataLocality: disabled

                persistence:
                  defaultClass: false
                  defaultClassReplicaCount: 1
              '';
            };
          }
        ];
      };
    };
}
