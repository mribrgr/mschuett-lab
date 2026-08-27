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

  # netcup-Host-Key. Damit entschlüsselt der Server seine Secrets zur
  # AKTIVIERUNGSZEIT selbst (agenix nutzt /etc/ssh/ssh_host_ed25519_key als
  # Identity, siehe base/modules/secrets-nixos.nix).
  #
  # Es ist derselbe Key wie vor dem Umbau: nixos-anywhere lief mit
  # `--copy-host-keys`, der Ubuntu-Host-Key hat den Neuaufbau also überlebt
  # (verifiziert 2026-08-07, Fingerprint identisch vor/nach Install). Nebeneffekt:
  # known_hosts blieb gültig, kein Host-Key-Warning.
  netcup = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfT7O/yvdtGLwe0+p1Vwft7Y/ED1w4YYT6OAyKjsZLG root@v2202505270128345138";

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
  # `netcup` als Recipient, die anderen Secrets NICHT: nur diese Datei wird auf
  # dem Host selbst gebraucht (damit das Einspielen der Keys nach einem Neuaufbau
  # deklarativ statt manuell passieren kann). Alles andere ist reines
  # Recovery-Material für den Menschen und hat auf dem Server nichts zu suchen.
  #
  # ⚠️ Enthält seit 2026-08-07 ZWÖLF Keys, nicht mehr elf: der frisch installierte
  # Controller hat beim ersten Start einen eigenen erzeugt (`…key52k57`), und der
  # ist inzwischen der AKTIVE Sealing-Key. Alles neu Verschlüsselte hängt an ihm —
  # fehlt er im Backup, ist es nach dem nächsten Neuaufbau nicht mehr lesbar.
  "sealed-secrets-master-keys.age".publicKeys = all ++ [ netcup ];

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

  # ── chat.mauritiusberger.de: OpenWebUI + Kanidm (Namespace `chat`) ────────────
  # Alle drei werden auf dem Host entschlüsselt und von modules/openwebui.nix in das
  # k8s-Secret `chat/open-webui-secrets` gerendert (Muster: broker-secrets in
  # nix-config/lab/modules/llm-proxy.nix). Die LLM-Keys selbst liegen in
  # nix-config/base/secrets/ — netcup ist dort seit 2026-08-26 Recipient.
  #
  # openwebui-oidc-secret: WIR setzen es. kanidm-provision schreibt den Wert per
  # `basicSecretFile` in kanidm (dafür läuft kanidm als `withSecretProvisioning`-Variante,
  # off-host gebaut), und dieselbe Datei speist OAUTH_CLIENT_SECRET in open-webui.
  # Rotation = age-Datei neu verschlüsseln + Deploy; kein Auslese-Schritt, und ein
  # kanidm-Neuaufbau übernimmt den Wert von selbst.
  "openwebui-oidc-secret.age".publicKeys = all ++ [ netcup ];
  # Session-Signing-Key von OpenWebUI. Rotation invalidiert alle Sessions.
  "openwebui-secret-key.age".publicKeys = all ++ [ netcup ];
  # (Ein API-Key für den Modell-Gating-Sidecar wurde bewusst NICHT eingeführt: der Sidecar
  # signiert sich mit dem WEBUI_SECRET_KEY selbst ein kurzlebiges Admin-JWT. Ein Key hätte
  # einen manuellen UI-Schritt und ein weiteres exportierbares Secret bedeutet.)

  # ── backup-store: Zwischenlager des velero-Mirrors aufs NAS ──────────────────
  # Design: nix-config/docs/superpowers/specs/2026-08-26-velero-nas-mirror-design.md
  # Beide werden von modules/backup-store.nix in k8s-Secrets gerendert.

  # KEY=VALUE-Zeilen: GARAGE_RPC_SECRET, GARAGE_ADMIN_TOKEN und ZWEI S3-Keys —
  # `GARAGE_VELERO_*` (schreibend, für die BSL) und `GARAGE_NAS_*` (nur lesend,
  # für den Pull vom NAS). Der Bootstrap im Image importiert beide; erzeugen darf
  # sie Garage nicht, sonst wäre der Schlüssel Laufzeit-State ohne Quelle.
  #
  # ⚠️ `GARAGE_NAS_*` MUSS denselben Wert haben wie
  # nix-config/homelab/secrets/netcup-staging-s3.age (dort in rclone-Schreibweise).
  # Bei Rotation also BEIDE Dateien anfassen — sonst spiegelt das NAS still nicht
  # mehr, und das fällt erst im Frischecheck des Tagesberichts auf.
  "backup-store-env.age".publicKeys = all ++ [ netcup ];

  # AWS-Credential-DATEI ([default] + aws_access_key_id/aws_secret_access_key) für
  # die velero-BSL `staging`. Enthält den GARAGE_VELERO_*-Key in der Form, die das
  # AWS-Plugin erwartet — velero liest hier eine Datei, keine Env-Variablen.
  "velero-staging-credentials.age".publicKeys = all ++ [ netcup ];

  # ── bricklink-mcp: Max' BrickLink-Store aus dem Chat verwalten ───────────────
  # Alle drei werden von modules/bricklink-mcp.nix in das k8s-Secret
  # `chat/bricklink-mcp-secrets` gerendert.
  #
  # bricklink-api: dotenv mit FÜNF Zeilen — BRICKLINK_CONSUMER_KEY/_SECRET,
  # BRICKLINK_TOKEN_VALUE/_SECRET und BRICKLINK_STORE_USERNAME (eigener
  # BL-Benutzername; er ist der Guard, der Schreibzugriffe auf EIGENE Verkäufe
  # begrenzt). Consumer-Paar auf
  # api.bricklink.com/pages/clone/api/register_consumer.page anlegen.
  #
  # ⚠️ Das Token-Paar wird PRO IP ausgestellt und gilt nur von dort
  # ("BrickLink resources are accessible only from the registered location").
  # Registriert werden muss die netcup-Public-IP 152.53.15.24 aus
  # nix-config/base/_network.nix. Wandert der Dienst auf einen anderen Host,
  # ist das Token dort wertlos, bis es neu ausgestellt ist.
  "bricklink-api.age".publicKeys = all ++ [ netcup ];

  # bricklink-web-token: der clientToken für den BrickStore-Client-Pfad, mit dem
  # der Katalog-Export geholt wird (die Store API hat keine Textsuche, ohne Index
  # gibt es keine Teilesuche nach Namen). Erzeugen auf
  # https://bricklink.com/v3/brickstore-access-management.page.
  #
  # ⚠️ Nur 30 TAGE gültig und nur im Browser erneuerbar — inhärent interaktiv,
  # also eine erlaubte Ausnahme vom Deklarativ-Prinzip. Läuft er ab, funktioniert
  # alles außer `catalog_refresh` weiter; das Tool sagt dann selbst, was zu tun ist.
  "bricklink-web-token.age".publicKeys = all ++ [ netcup ];

  # bricklink-mcp-bearer: Bearer-Token, mit dem sich OpenWebUI beim MCP anmeldet.
  # Zweite Schranke hinter der CiliumNetworkPolicy (nur der open-webui-Pod kommt
  # überhaupt an den Port). Erzeugen: `openssl rand -base64 32`.
  # Derselbe Wert muss in OpenWebUI unter Admin → Integrations → External Tool
  # Servers eingetragen werden — das ist UI-State, kein Repo-State.
  "bricklink-mcp-bearer.age".publicKeys = all ++ [ netcup ];
}
