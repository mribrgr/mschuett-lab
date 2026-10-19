# GitHub-MCP in Open WebUI (nur mberger)

GitHubs **offizieller**, remote gehosteter MCP-Server (`https://api.githubcopilot.com/mcp/`)
als Tool-Server **GitHub** (`server:mcp:github`) auf `chat.steinaberfein.de`. Kein eigenes
Image, kein Pod — nur ein Eintrag in `TOOL_SERVER_CONNECTIONS` (`modules/openwebui.nix`).

## Wer ihn sieht

**Nur Admins, also mberger.** `config.access_grants = [ ]` bedeutet in Open WebUI 0.11
„privat, nur Admin" (`utils/access_control.has_connection_access`). Das gilt für die
Tool-Liste UND für den Aufruf: `middleware.py` prüft vor jedem MCP-Connect erneut.
mschuett sieht ihn nicht — chat-e2e Schritt 7b prüft das bei jedem Lauf.

GitHub hängt an keinem Modell aus `modelGrants` (die gelten für mschuetts Gruppe). Im
Chat über das Tool-Menü (Schraubenschlüssel-Symbol) zuschalten.

## Anmelden

Beim ersten Aufruf bzw. über *Einstellungen → Integrationen* fragt Open WebUI nach der
GitHub-Anmeldung: GitHub-Zustimmungsseite, „Authorize", zurück in den Chat. Das Token
liegt verschlüsselt (`WEBUI_SECRET_KEY`) in der DB-Zeile des Nutzers; GitHub-OAuth-App-
Tokens laufen nicht ab. Widerrufen: github.com → Settings → Applications → Authorized
OAuth Apps → „Open WebUI chat.steinaberfein.de" → Revoke.

### ⚠️ Vorher prüfen, als wer man im Chat angemeldet ist

Der Endpunkt `/oauth/clients/mcp:github/authorize` prüft die Admin-Beschränkung des
Tool-Servers **nicht** (Open WebUI 0.11) — jeder angemeldete Nutzer kann den Ablauf
starten, und das Token landet bei **dem** Open-WebUI-Konto, das gerade angemeldet ist.
Am 2026-10-16 passiert: der Ablauf lief in einem Browser, der als mschuett angemeldet
war, und mbergers GitHub-Token (mribrgr) landete in mschuetts DB-Zeile. Über die Tools
nutzbar war es nicht (Aufruf prüft `has_connection_access`), es wurde trotzdem sofort
bei GitHub widerrufen (`DELETE /applications/{client_id}/token` → 204) und die Session
gelöscht. Über die UI passiert das nicht — mschuett sieht den Server gar nicht; nur der
direkte Aufruf der Authorize-URL umgeht das.

Prüfen, wer welche Session hat:

```sh
ssh netcup "k3s kubectl -n chat exec deploy/open-webui -c open-webui -- sqlite3 /data/webui.db \
  \"select s.provider, u.email from oauth_session s join user u on u.id = s.user_id where s.provider like 'mcp:%';\""
```

## Warum keine dynamische Registrierung

Gewünscht war „Anmelden über dynamic provisioning" (`auth_type = "oauth_2.1"`, RFC 7591).
Gemessen am 2026-10-16:

```
GET https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp/
  → authorization_servers: ["https://github.com/login/oauth"]
GET https://github.com/.well-known/oauth-authorization-server/login/oauth
  → registration_endpoint: null, client_id_metadata_document_supported: null
```

GitHub bietet weder DCR noch Client-ID-Metadata-Documents. Open WebUI kann sich dort
also nicht selbst registrieren. Deshalb einmalig eine **GitHub-OAuth-App** als
statischer Client (`oauth_2.1_static`); das Anmelden pro Nutzer bleibt der gleiche
Klick. Bietet GitHub künftig `registration_endpoint`, genügt: `auth_type` auf
`oauth_2.1`, `oauth_client_id`/`oauth_client_secret` raus, OAuth-App + Secret löschen.

`oauth_2.1_static` braucht den open-webui-Patch für upstream **#20697** (statischer
Client lässt sich mit `ENABLE_PERSISTENT_CONFIG=False` beim Start nicht registrieren —
Begründung im Kommentar an `postPatch` in `modules/openwebui.nix`).

## Was NICHT im Repo liegt (GitHub-Seite, manuell)

OAuth-App im Konto **mribrgr** (github.com → Settings → Developer settings → OAuth Apps,
App-ID 3937303, Client-ID `Ov23li6ZXD0UZK3k3eOV`),
angelegt am 2026-10-16:

| Feld | Wert |
|------|------|
| Application name | `Open WebUI chat.steinaberfein.de` |
| Homepage URL | `https://chat.steinaberfein.de` |
| Authorization callback URL | `https://chat.steinaberfein.de/oauth/clients/mcp:github/callback` |
| Device Flow | aus |
| Expire user access tokens | an (8 h + Refresh-Token; Open WebUI erneuert 5 min vor Ablauf selbst) |

Client-ID im Klartext in `modules/openwebui.nix` (`chatSpec.githubOauthClientId`),
Client-Secret in `secrets/github-mcp-oauth-secret.age`. Die Callback-URL hängt an der
Tool-Server-ID `github` — ändert sich die ID, MUSS sie in der OAuth-App nachgezogen
werden, sonst „redirect_uri mismatch".

## Scopes

`repo read:org read:user user:email notifications gist` — explizit gesetzt, sonst fragt
Open WebUI alle Scopes aus der Protected-Resource-Metadata an (inkl. `write:packages`,
`project`). `repo` erlaubt Lesen UND Schreiben in allen Repos des Kontos; der MCP bietet
entsprechend auch schreibende Tools (Issues/PRs anlegen, Dateien ändern, mergen).
Nur-Lesen ginge über die URL `https://api.githubcopilot.com/mcp/readonly`.

## Secret rotieren

1. OAuth-App → „Generate a new client secret", kopieren.
2. `cd secrets && pbpaste | tr -d ' \n' | nix run github:ryantm/agenix -- -e github-mcp-oauth-secret.age`
3. Deployen — `secretsChecksum` startet open-webui neu.
4. Altes Secret in der OAuth-App löschen.
