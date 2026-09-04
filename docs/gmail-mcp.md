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

## ⚠️ Testnutzer: der Eintrag, der gern verschwindet

Ohne Eintrag in *Zielgruppe → Testnutzer* endet die Zustimmung in

```
Fehler 403: access_denied
„steinaberfein.de" hat die Überprüfung durch Google nicht abgeschlossen.
Die App wird gerade getestet und nur die vom Entwickler genehmigten Tester haben Zugriff.
```

Die Falle: im Panel „Nutzer hinzufügen" reicht **ein** Klick auf *Speichern* nicht. Solange
das Chip-Eingabefeld den Fokus hat, schluckt es den ersten Klick — das Panel bleibt offen,
die Liste bleibt leer, und es erscheint **keine** Fehlermeldung. Am 2026-09-02 genau so
passiert und erst am 2026-09-03 beim ersten echten Anmeldeversuch aufgefallen.

**Immer gegenprüfen:** Seite neu laden und schauen, ob unter *OAuth-Nutzerobergrenze*
tatsächlich „1 Nutzer (1 Testnutzer, 0 andere)" steht und die Mail in der Tabelle auftaucht.

Das kann `chat-e2e` **nicht** abdecken: die Testnutzerliste ist Google-Konto-Zustand, und
Google bietet dafür keine API. Der e2e-Test prüft nur, dass open-webui korrekt zu Google
weiterleitet — was hinter dem Redirect passiert, sieht er nicht.

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

## Der open-webui-Patch (upstream #20697)

Open WebUI 0.11.0 kann einen per `TOOL_SERVER_CONNECTIONS` deklarierten MCP-Server mit
`oauth_2.1_static` **nicht** beim Start registrieren. `initialize_runtime_config`
(`main.py:586`) ruft `resolve_oauth_client_info`, und das entschlüsselt bedingungslos
`info.oauth_client_info` — einen Blob, den ausschließlich `register_client` in die DB
schreibt. Mit `ENABLE_PERSISTENT_CONFIG=False` liest `Config.get` nur die Env, der Blob kann
also per Definition nie existieren. `decrypt_data("")` wirft dann `InvalidToken`, deren
`str()` leer ist — daher die nichtssagende Logzeile:

```
ERROR | open_webui.main:initialize_runtime_config:596 - Error adding OAuth client for MCP tool server gmail:
```

Der statische Overlay aus `oauth_client_id`/`oauth_client_secret` steht zwei Zeilen darunter
und wird nie erreicht. Folge: der Client fehlt im Manager, und
`/oauth/clients/mcp:gmail/authorize` antwortet **404** — die Zustimmung ist nicht anklickbar.

`modules/openwebui.nix` patcht deshalb zwei Einzeiler in `backend/open_webui/utils/oauth.py`:

1. `resolve_oauth_client_info`: entschlüsselt nur noch, wenn ein Blob da ist.
2. `recover_static_oauth_client_metadata`: ergänzt `redirect_uris`, das im gepinnten
   MCP-SDK Pflicht ist (im SDK-`main` inzwischen optional — nicht verwechseln). Ohne das
   Feld scheitert der Konstruktor mit
   `1 validation error for OAuthClientInformationFull: redirect_uris Field required`.

Danach fehlt dem Objekt nur noch `server_metadata`; damit scheitert
`_preflight_authorization_url`, und der Authorize-Endpunkt ruft upstreams **eigenen**
Reparaturpfad `register_client` → `get_oauth_client_info_with_static_credentials` mit voller
Discovery. Der Patch liefert also nur den Anker, den upstream danach selbst korrekt aufbaut.

Beide Ersetzungen sind bewusst einzeilig: Python ist whitespace-sensitiv, und eine
mehrzeilige Ersetzung in einem nix-`''`-String verlöre durch das Abziehen der gemeinsamen
Einrückung ihre Indentation. `--replace-fail` bricht beim nächsten open-webui-Bump laut —
dann prüfen, ob #20697 zu ist, und den Patch ersatzlos entfernen.

Der Patch hängt an `overridePythonAttrs`, betrifft also **nur** das Python-Paket. Die
Frontend-Derivation (`open-webui-frontend`, `buildNpmPackage`) hängt am unveränderten `src`
und wird nicht neu gebaut — der 3,9-GB-Vite-Build bleibt aus, der Deploy geht nativ auf
netcup (verifiziert 2026-09-02: 37 Derivations, keine davon `open-webui-frontend`,
`npm-deps` oder `pyodide`).

### Nicht erschrecken: „Initialized 0 tool server(s)"

`get_tool_servers_data` verarbeitet nur `type == "openapi"` (`utils/tools.py:1460`).
MCP-Server laufen zur Request-Zeit über `connect_mcp_server`. Die Null stand also auch schon
da, als BrickLink allein und funktionierend eingetragen war.

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
