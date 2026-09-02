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
  # SearXNG `server.secret_key` — signiert die Such-Sessions. Kein Nutzer-Credential,
  # aber SearXNG startet ohne einen gesetzten Wert nicht.
  "searxng-secret.age".publicKeys = all ++ [ netcup ];
  # Qdrant-API-Key. Der Dienst ist per CiliumNetworkPolicy schon nur für open-webui
  # erreichbar; der Key ist die zweite Schicht, damit ein Fehlgriff in der Policy nicht
  # sofort Lese-/Schreibzugriff auf alle Vektoren bedeutet.
  "qdrant-api-key.age".publicKeys = all ++ [ netcup ];
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
  # EIN SECRET PRO SHOP. Der Dateiname trägt den Slug, den auch der `store`-Parameter
  # der Tools benutzt; modules/bricklink-mcp.nix bildet die Schlüssel auf
  # BRICKLINK_STORE_<SLUG>_* ab. Inhalt jeweils dotenv mit FÜNF Zeilen:
  #   CONSUMER_KEY, CONSUMER_SECRET, TOKEN_VALUE, TOKEN_SECRET, USERNAME
  # (ein führendes BRICKLINK_ bzw. BRICKLINK_STORE_ wird abgeschnitten, die Datei aus
  # der Ein-Shop-Zeit funktioniert also unverändert weiter).
  #
  # USERNAME ist nicht Kosmetik: er ist der Guard, der Schreibzugriffe auf die
  # Bestellungen GENAU DIESES Shops begrenzt. Bei einem falschen `store` passt
  # `seller_name` der Bestellung nicht und es wird nichts geschrieben.
  #
  # ⚠️ Das Token-Paar wird PRO IP ausgestellt und gilt laut Doku nur von dort
  # ("BrickLink resources are accessible only from the registered location") —
  # registriert werden muss die netcup-Public-IP 152.53.15.24 aus
  # nix-config/base/_network.nix. Am 2026-08-27 hat BrickLink das allerdings NICHT
  # durchgesetzt (dasselbe Token lieferte von einer fremden Adresse alle Daten);
  # verlassen sollte man sich darauf nicht.
  #
  # Consumer-Paar anlegen: api.bricklink.com/pages/clone/api/register_consumer.page
  # — pro Shop mit dem BL-Konto DIESES Shops einloggen.
  "bricklink-api-steinaberfein.age".publicKeys = all ++ [ netcup ]; # mschuett
  "bricklink-api-dinoland.age".publicKeys = all ++ [ netcup ]; # mberger

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

  # gmail-mcp-oauth-secret: Client-Secret des Google-OAuth-Clients „Open WebUI
  # chat.steinaberfein.de" (Projekt gmail-mcp-507417). Damit spricht OpenWebUI Googles
  # offiziellen Gmail-MCP (gmailmcp.googleapis.com) über `auth_type = "oauth_2.1_static"`
  # an: die Client-ID steht im Klartext in modules/openwebui.nix — sie ist per OAuth-Design
  # öffentlich und taucht ohnehin in jeder Autorisierungs-URL auf —, nur das Secret liegt hier.
  #
  # Die App steht auf Extern/Test; Zugriff hat nur, wer als Testnutzer eingetragen ist
  # (aktuell steinaberfeinbl@gmail.com). Der Token-Austausch selbst passiert pro OpenWebUI-
  # Nutzer und landet verschlüsselt in dessen DB-Zeile, nicht hier.
  #
  # Rotieren: in der Cloud Console einen neuen Clientschlüssel erzeugen, hier neu
  # verschlüsseln, deployen — open-webui startet dabei neu (secretsChecksum), sonst
  # spricht es Google mit dem alten Secret an und jeder Tool-Aufruf endet in invalid_client.
  "gmail-mcp-oauth-secret.age".publicKeys = all ++ [ netcup ];
}
