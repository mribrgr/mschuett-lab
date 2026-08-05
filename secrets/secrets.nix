# agenix recipients & rules für mschuett-lab.
#
# Bildet jede verschlüsselte *.age-Datei auf die PUBLIC Keys ab, die sie
# entschlüsseln dürfen. Klartext liegt hier nie.
#
# Bearbeiten/Anlegen (aus DIESEM Verzeichnis):
#   EDITOR=nano nix run github:ryantm/agenix -- -e <name>.age
# Nach Key-Wechsel alles neu verschlüsseln:
#   nix run github:ryantm/agenix -- -r
# Ansehen/Ausgeben:
#   nix run github:ryantm/agenix -- -d <name>.age
let
  # Daily-driver SSH key auf dem MacBook (passphrase-los). Identisch mit dem
  # Recipient in nix-config (base/, mac/, homelab/, lab/) — bewusst derselbe,
  # damit ein Key-Wechsel nicht pro Welt vergessen wird.
  macbook = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICxGWKrG3PlTZxWzW071IxUEUbJfr6lXQqHC0m+uDdiK macbook-agenix";

  # Offline-Recovery-Identity. Privater Teil in Apple Passwords UND auf Papier.
  # Identisch mit nix-config. Nach jedem Wechsel: `agenix -r` in JEDER Welt —
  # inklusive dieser hier, die in einem SEPARATEN Repo liegt und daher leicht
  # vergessen wird.
  backup = "age1vu7ce5ggmh93kndr0fwmkcv843tfetkul5nt2h587ss6xw30ue8q34jv2u";

  # ── netcup-Host-Key: EXISTIERT NOCH NICHT ──────────────────────────────────
  # Die Box läuft heute Ubuntu; der NixOS-SSH-Host-Key entsteht erst beim ersten
  # Boot nach dem nixos-anywhere-Install. Solange ist KEIN Host hier Recipient,
  # d. h. der Server kann diese Secrets NICHT zur Aktivierungszeit selbst
  # entschlüsseln — alles hier ist derzeit Recovery-Material für den Menschen.
  #
  # Nach dem ersten Boot:
  #   ssh root@v2202505270128345138.powersrv.de cat /etc/ssh/ssh_host_ed25519_key.pub
  # hier eintragen, `all` erweitern, dann `agenix -r`. Siehe TODO.md Punkt 3.
  # netcup = "ssh-ed25519 AAAA... root@netcup";

  all = [
    macbook
    backup
  ];
in
{
  # ── Kritisch für den Wiederaufbau ─────────────────────────────────────────
  # Alle 11 sealed-secrets-Controller-Keys als v1.List. OHNE diese Datei sind
  # nach einem Cluster-Neuaufbau ALLE SealedSecrets im Repo unentschlüsselbar
  # (der frische Controller generiert einen neuen Key).
  #
  # ⚠️ kubeseal liest aus einer PEM-Datei nur den ERSTEN Key. Deshalb bewusst
  # das v1.List-Format und keine PEM-Konkatenation — verifiziert 2026-08-05:
  # eine Bundle-PEM scheiterte an allen 7 SealedSecrets, das v1.List entschlüsselt
  # 23/23 Keys deckungsgleich mit den Live-Secrets.
  "sealed-secrets-master-keys.age".publicKeys = all;

  # kubeconfig des ALTEN Clusters (cluster-admin). Nach dem Neuaufbau wertlos,
  # bis dahin der einzige Zugang für Restore/Verifikation.
  "kubeconfig-old-cluster.age".publicKeys = all;

  # ── Bootstrap-Credentials ─────────────────────────────────────────────────
  # ghcr.io-Pull-Secret (GitHub PAT) für die privaten Images von
  # bricklink-scraping. Erst wieder relevant, wenn bricklink reaktiviert wird.
  "ghcr-dockerconfig.age".publicKeys = all;

  # ArgoCD repo-creds (SSH-Deploy-Key) für das PRIVATE Repo
  # mribrgr/bricklink-scraping. Ebenfalls erst mit bricklink relevant.
  "bricklink-scraping-deploykey.age".publicKeys = all;

  # Legacy: Deploy-Key, der ArgoCD Zugriff auf mribrgr/hardware gab. Das Repo
  # heißt jetzt mschuett-lab und ist PUBLIC — ArgoCD zieht ohne Credentials.
  # Nur aufbewahrt, bis das Erst-Deployment verifiziert ist (TODO.md Punkt 7).
  "argocd-legacy-repo-key.age".publicKeys = all;
}
