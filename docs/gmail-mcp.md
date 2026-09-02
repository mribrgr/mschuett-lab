# Gmail-MCP in Open WebUI

Googles **offizieller**, remote gehosteter MCP-Server (`gmailmcp.googleapis.com`) als
Tool-Server in Open WebUI auf `chat.steinaberfein.de`.

Kein selbst gebauter Server wie `bricklink-mcp` — Google betreibt ihn, wir konfigurieren
nur den OAuth-Client. Entsprechend gibt es hier weder ein Image noch ein Deployment,
sondern nur einen Eintrag in `TOOL_SERVER_CONNECTIONS` (`modules/openwebui.nix`).

## Was deklarativ im Repo liegt

| Was | Wo |
|-----|-----|
| Server-URL, Tool-Server-ID, Anzeigename, Beschreibung | `modules/openwebui.nix` (`gmailToolServerUrl` etc.) |
| OAuth-Client-ID | `modules/openwebui.nix` (`gmailOauthClientId`) — per OAuth-Design öffentlich |
| OAuth-Client-Secret | `secrets/gmail-mcp-oauth-secret.age` (agenix) |
| Sichtbarkeit + Modell-Bindung | `modules/openwebui.nix` (`access_grants`, `modelGrants`) |

Wie bei BrickLink gilt `ENABLE_PERSISTENT_CONFIG=False`: `TOOL_SERVER_CONNECTIONS` aus der
Env ist die EINZIGE Quelle. Ein Eintrag über Admin → Integrations landet in der DB und
bliebe wirkungslos.

## Was NICHT im Repo liegt (Google-Seite, manuell)

Angelegt am 2026-09-02 im Google-Konto `steinaberfeinbl@gmail.com`:

* **Projekt** `gmail-mcp-507417` (Anzeigename `gmail-mcp`), kein Billing nötig.
* **Aktivierte APIs**: `gmail.googleapis.com` + `gmailmcp.googleapis.com`.
* **Zustimmungsbildschirm**: Nutzertyp **Extern**, Status **Test**.
  Zugriff hat nur, wer unter *Zielgruppe → Testnutzer* steht — aktuell nur
  `steinaberfeinbl@gmail.com`. Wer sich sonst anmeldet, bekommt `access_denied`.
* **Scopes**: `gmail.readonly` + `gmail.compose`.
* **OAuth-Clients** (Typ Webanwendung):
  * `Open WebUI chat.steinaberfein.de` → Client-ID `825099451418-3q800m171d09dj9fgflp654smo9vm2mo…`,
    Redirect-URI `https://chat.steinaberfein.de/oauth/clients/mcp:gmail/callback`
  * `Claude Code CLI` → für die Claude-Code-Anbindung auf dem Mac, Redirect-URIs
    `http://localhost:51234/callback` und `http://127.0.0.1:51234/callback`

Das ist eine bewusst dokumentierte Ausnahme vom Deklarativ-Prinzip: die Google-Cloud-Seite
ist von hier aus nicht deklarativ erreichbar.

## Die Redirect-URI mit dem Doppelpunkt

Open WebUI baut sie als `{WEBUI_URL}/oauth/clients/mcp:{id}/callback` (`utils/oauth.py`,
`expected_client_id = f'mcp:{server_id}'`). Der Doppelpunkt im Pfad ist RFC-3986-konform
(`pchar` erlaubt `:` außerhalb des ersten Segments einer relativen Referenz) und wurde von
der Google Cloud Console akzeptiert — verifiziert 2026-09-02.

**Folge:** ändert sich `gmailToolServerId`, ändert sich die Redirect-URI. Dann MUSS sie im
OAuth-Client nachgezogen werden, sonst endet die Zustimmung in `redirect_uri_mismatch`.

## Warum `oauth_2.1_static` und nicht `oauth_2.1`

Open WebUI 0.11 kennt beide (`utils/tools.py`:
`elif auth_type in ('oauth_2.1', 'oauth_2.1_static')`). Die dynamische Variante registriert
den Client beim Autorisierungsserver selbst (RFC 7591) — **Google unterstützt das nicht**.
Also die statische mit vorab angelegter Client-ID; `resolve_oauth_client_info` überschreibt
damit den gespeicherten Blob aus `info.oauth_client_id` / `info.oauth_client_secret`.

Discovery läuft über
`https://gmailmcp.googleapis.com/.well-known/oauth-protected-resource/mcp/v1`;
sie nennt `https://accounts.google.com/` als Autorisierungsserver.

## Pro-Nutzer-Zustimmung

Der Bearer-Token ist hier **nicht** geteilt: jeder Open WebUI-Nutzer autorisiert einmal im
Browser mit seinem eigenen Google-Konto, das Token landet verschlüsselt in seiner DB-Zeile.
Verschlüsselt wird mit `WEBUI_SECRET_KEY` — der kommt aus agenix und ist über Neustarts
stabil. Wäre er flüchtig, wäre nach jedem Pod-Restart jede Gmail-Verbindung tot.

Bis die Zustimmung erteilt ist, ist der Server zwar sichtbar, liefert aber 401.

## Werkzeuge

Lesen und Suchen (`search_threads`, `get_thread`, `get_message`), Labels
(`list_labels`, `create_label`, `label_message`/`label_thread` und die `unlabel_*`-Gegenstücke)
sowie Entwürfe (`create_draft`, `list_drafts`).

**Kein Senden.** Der Scope `gmail.compose` erlaubt es zwar, der MCP bietet aber kein
Send-Tool an. Wer senden will, braucht einen anderen Server.

## Secret rotieren

1. Cloud Console → Clients → `Open WebUI chat.steinaberfein.de` → neuen Clientschlüssel erzeugen
2. `cd secrets && EDITOR=nano nix run github:ryantm/agenix -- -e gmail-mcp-oauth-secret.age`
3. Deployen — `secretsChecksum` startet open-webui neu

Ohne den Neustart spricht Open WebUI Google mit dem alten Secret an und jeder Tool-Aufruf
endet in `invalid_client`.
