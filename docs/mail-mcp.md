# Mail-MCP (IMAP/SMTP) in Open WebUI

Eigener, schlanker MCP-Server (`pkgs/mail-mcp`), der genau **ein** Postfach über
IMAP mit App-Passwort bedient. Pro Postfach ein eigener Pod. Heute im Einsatz:

| Tool-Server | Postfach | Pod |
|-------------|----------|-----|
| **AOL-Mail** (`server:mcp:aol`) | `maximilianschuett@aol.com` | `aol-mail-mcp` |
| **Gmail** (`server:mcp:gmail`) | `steinaberfeinbl@gmail.com` | `gmail-mail-mcp` |

Gmail lief bis 2026-10-13 über Googles offiziellen MCP — der ist für Consumer-Konten
gesperrt (Abschnitt „Googles offizieller Gmail-MCP" unten).

Sichtbar für alle angemeldeten Open-WebUI-Nutzer (`access_grants` `*` = mschuett +
mberger) und an beiden mschuett-Modellen automatisch aktiv. Alle Nutzer arbeiten im
**selben** Postfach — das Login liegt beim MCP, nicht pro Nutzer.

## Warum selbst gebaut

Geprüft am 2026-10-13. Der reifste fertige Server, `mcp-email-server` (Wh1isper,
PyPI), kann Streamable HTTP und Env-Konfiguration, bringt aber ~17
Python-Abhängigkeiten mit, hat **keine** Authentifizierung am HTTP-Endpunkt und
veröffentlicht fast täglich. Bei Vollzugriff auf ein Postfach wiegt fremder Code
schwer; der Bedarf hier passt in die Standardbibliothek + fastmcp. Die übrigen
Kandidaten (`@codefuturist/email-mcp`, `imap-mcp-server`, …) waren entweder nur stdio
oder zu jung.

Entstanden aus einer Gmail-IMAP-WIP vom 2026-09-04 (nie committet, inzwischen
gelöscht), anbieterneutral gemacht und um zwei stille Fehler bereinigt: imaplib quotet Suchbegriffe **nicht** (ein Betreff
mit Leerzeichen zerfiel in mehrere Kriterien), und `search`/`fetch` arbeiteten mit
Sequenznummern statt UIDs.

## Was deklarativ im Repo liegt

| Was | Wo |
|-----|-----|
| Postfächer (Adresse, Server, Anzeigename, Senden an/aus) | `modules/mail-mcp.nix` (`mailSpec`) |
| Deployment, Service, CiliumNetworkPolicy, Secret-oneshot | `modules/mail-mcp.nix` |
| Tool-Server-Eintrag + Modell-Bindung | `modules/openwebui.nix` (`mailToolServers`) |
| App-Passwort | `secrets/aol-mail-app-password.age` |
| Bearer Open WebUI → MCP | `secrets/mail-mcp-bearer.age` |
| Laufende Prüfung | `modules/chat-e2e.nix`, Schritt 10 |

## Werkzeuge

Der Server nennt sie `search`, `get_message`, …; Open WebUI stellt die
Tool-Server-ID selbst voran (`utils/middleware.py`: `f'{server_id}_{name}'`), im Chat
heißen sie also `aol_search` usw. — zwei Postfächer kollidieren dadurch nicht.

| Tool (in Open WebUI) | Wirkung |
|------|---------|
| `aol_list_folders` | Ordner mit SPECIAL-USE-Markierung (`\Sent`, `\Drafts`, …) |
| `aol_search` | Kopfdaten + 400 Zeichen Vorschau, neueste zuerst, `total` = Gesamttreffer |
| `aol_get_message` | Volltext (max. 40 000 Zeichen), Anhänge nur als Namen |
| `aol_create_draft` | Entwurf in `Draft` — geht im AOL-Webmailer raus |
| `aol_send` | **nur registriert, wenn `allowSend = true`** |

Lesen verändert nichts (`EXAMINE` + `BODY.PEEK`): ungelesene Mails bleiben
ungelesen. Löschen, Verschieben, Markieren gibt es nicht.

## Inhärent interaktiv: das App-Passwort (dokumentierte Ausnahme)

AOL lässt fremde IMAP-Clients nur mit App-Passwort herein, und das entsteht nur im
Browser mit angemeldetem Konto:

1. `https://login.aol.com/myaccount/security` → *App-Passwort generieren* →
   *Jetzt loslegen* → App-Name `chat.steinaberfein.de` → *Passwort generieren*.
2. Passwort kopieren (wird **nur einmal** angezeigt, 16 Kleinbuchstaben).
3. Aus `secrets/`, ohne dass es im Terminal erscheint:
   ```sh
   pbpaste | tr -d ' \n' | nix run github:ryantm/agenix -- -e aol-mail-app-password.age
   ```
   (oder `age -R <recipients> -o aol-mail-app-password.age`), danach `pbcopy </dev/null`.
4. Deployen. `credentialHash` startet den Pod neu.

Zuletzt erzeugt am 2026-10-13. Ein App-Passwort überlebt eine Änderung des
Kontopassworts; widerrufen wird es auf derselben AOL-Seite.

**Gmail** analog: `https://myaccount.google.com/apppasswords` (Google verlangt vorher
eine Passkey-/Passwort-Bestätigung) → App-Name `chat.steinaberfein.de` → *Erstellen*
→ kopieren → `gmail-app-password.age`. Voraussetzung ist die Bestätigung in zwei
Schritten. ⚠️ Anders als bei AOL **widerruft Google alle App-Passwörter, wenn das
Kontopasswort geändert wird** — dann meldet chat-e2e „Postfach nicht lesbar".

## Senden einschalten

`allowSend = true` im Postfach-Eintrag in `modules/mail-mcp.nix`, deployen. Dann
erscheint `aol_send` (SMTP `smtp.aol.com:465`, dasselbe App-Passwort), mit
Schranke `MAIL_MAX_RECIPIENTS` (5) und strenger Adressprüfung.

## Neues Postfach

Eintrag in `mailSpec.mailboxes` (Schlüssel = Tool-Server-ID, Kleinbuchstaben),
`secrets/<…>.age` + Zeile in `secrets/secrets.nix` (`all ++ [ netcup ]`). Open WebUI,
Modelle und chat-e2e ziehen über `self.mailMcp` automatisch nach. Für Gmail per IMAP
braucht es ein Google-App-Passwort (setzt 2FA voraus).

## AOL-Fakten (live 2026-10-13)

* `imap.aol.com:993` TLS, `smtp.aol.com:465` TLS, Benutzername = volle Adresse.
* Capabilities u. a. `SPECIAL-USE UIDPLUS MOVE LITERAL+` — **kein** `UTF8=ACCEPT`.
  Suchwörter mit Umlauten gehen deshalb als Literal mit `CHARSET UTF-8` raus
  (höchstens eins pro Suche).
* Ordner: `Inbox`, `Draft` (`\Drafts`), `Sent`, `Bulk` (`\Junk`), `Trash`,
  `Archive` plus eigene (`DHL`, `paypal`, …).

## Prüfen

```sh
ssh netcup 'systemctl start chat-e2e; journalctl -u chat-e2e -n 60 --no-pager'
# erwartet u. a.:
#   PASS  deployment aol-mail-mcp ready (1/1)
#   PASS  Tool-Server server:mcp:aol sichtbar
#   PASS  Mail-MCP aol erreichbar und verschlossen (401)
#   PASS  Mail-MCP aol: IMAP-Login ok, 16 Ordner
ssh netcup 'k3s kubectl -n chat logs deploy/aol-mail-mcp --tail=20'
```

`/health` loggt sich bewusst **nicht** bei AOL ein (Probe alle 10 s; AOL sperrt
Konten mit auffällig vielen Logins). Den echten Login prüft chat-e2e alle 15 Minuten.

## Googles offizieller Gmail-MCP (verworfen)

Vom 2026-09-02 bis 2026-10-13 hing Gmail als `gmailmcp.googleapis.com` mit OAuth pro
Nutzer (`auth_type = "oauth_2.1_static"`) in Open WebUI — samt Google-Projekt
`gmail-mcp-507417`, OAuth-Clients und einem open-webui-Patch für upstream #20697.
OAuth-Zustimmung und Tool-Liste funktionierten, jeder echte Aufruf scheiterte aber an
„project not enrolled in the Google Workspace Developer Preview Program". Das Programm
nimmt nur Google-**Workspace**-Konten auf (Stand 2026-10-13 weiterhin Developer
Preview), für `steinaberfeinbl@gmail.com` ist der Weg also zu. Am 2026-10-13 wurde alles
davon entfernt: Modul-Einträge, Secret, Patch, Doku (`docs/gmail-mcp.md`, steht im
git-Log) und das Google-Projekt selbst.

## Gmail drosselt: `[THROTTLED]`

Am 2026-10-13 nach mehreren Volltextsuchen (`TEXT`) über alle ~2500 Mails hängte Gmail
an jede Antwort `[THROTTLED]` und verzögerte **jeden** Befehl nach dem Login um ~10 s —
auch `NOOP`, von netcup wie vom Mac aus gleich. Ein Chat-Aufruf von `gmail_search`
dauerte damit ~40 s statt ~2 s. Kein Fehler im Server; prüfen mit:

```sh
# Passwort nur über stdin, nie in argv
{ sleep 1; printf 'a1 LOGIN steinaberfeinbl@gmail.com %s\r\n' "$PW"; sleep 2; printf 'a2 NOOP\r\na3 LOGOUT\r\n'; sleep 15; } \
  | openssl s_client -connect imap.gmail.com:993 -quiet
```

Steht `[THROTTLED]` hinter `a2 OK`, ist das Konto gedrosselt; das klingt von selbst ab.
Volltextsuchen ohne Zeitgrenze (`since_days=0` mit `text`) daher sparsam einsetzen.

**Stand 2026-10-19: die Drosselung klingt NICHT ab.** Seit dem 13.10. braucht jeder
Befehl nach dem Login ~10–15 s, und daran hat sich nichts geändert. Ein Aufruf von `list_folders` (LOGIN, LIST,
LOGOUT) dauert damit ~20 s, und gut 2 % der chat-e2e-Läufe rissen den damaligen
30-s-Socket-Timeout. Ursache ist nicht dieser Server, sondern **paperless** (`default/paperless`
auf netcup, Chart-Repo): es holt alle 10 min per IMAP aus demselben Konto (Regel
„Bricklink Max.Process attachments", Label `mail_read_by_paperless`), jeder Lauf dauert
95–125 s ohne neues Dokument, und gut die Hälfte endet in
`[OVERQUOTA] Account exceeded command or bandwidth limits` — so seit mindestens
2026-09-29 (weiter reicht das Pod-Log nicht). Solange paperless so pollt, bleibt Gmail
gedrosselt. Gegenmittel liegen bei paperless (Regel enger fassen, Intervall strecken),
nicht hier. Der Timeout steht seitdem auf 60 s pro Operation (`IMAP_TIMEOUT_S`).

```sh
ssh netcup 'k3s kubectl -n default logs deploy/paperless --since=3h | grep -c OVERQUOTA'
```
