# chat-e2e — End-to-End-Tests des Chat-Stacks

`modules/chat-e2e.nix`, läuft auf netcup als systemd-Timer (alle 15 min, plus 10 min nach
dem Boot). Fehlschlag = Unit failed = sichtbar in `systemctl --failed`.

```bash
ssh netcup 'systemctl start chat-e2e; journalctl -u chat-e2e -n 40 --no-pager -o cat'
```

## Warum

Die interessanten Fehler dieses Stacks sind **leise**:

* Ein OAuth-Client, der beim Start nicht registriert wird, kostet eine Logzeile und sonst
  nichts — bis jemand klickt und 400 bekommt (am 2026-09-03 genau so passiert).
* Ein weggerutschter Modell-Grant zeigt sich erst, wenn mschuett vor leerer Auswahl steht.
* `ENABLE_LOGIN_FORM=True` fällt niemandem auf, macht die Instanz aber zu einem offenen
  Admin-Claim.

Keiner davon ist an „läuft der Pod?" zu erkennen.

## Was geprüft wird

| # | Prüfung |
|---|---------|
| 1 | Alle sechs Deployments in `chat` vollständig ready |
| 2 | `GET /health` über die **öffentliche** URL → 200 |
| 3 | `enable_login_form=false`, `enable_signup=false`, `auth=true` |
| 4 | `/openapi.json` ist **kein** OpenAPI-Dokument (`ENV=prod`) |
| 5 | Konto des Nicht-Admins existiert, Rolle ist `user` |
| 6 | `/api/models` liefert **exakt** die freigegebenen Modelle |
| 7 | Beide MCP-Tool-Server sichtbar (`bricklink`, `gmail`) |
| 8 | Gmail-Authorize → 302 zu `accounts.google.com` mit korrekter `client_id`, `redirect_uri` und beiden Scopes |
| 9 | BrickLink-MCP erreichbar **und** ohne Bearer verschlossen (401/403) |

## Entwurfsentscheidungen

**Gegen die öffentliche URL, nicht gegen den ClusterIP.** So liegen Gateway-Listener,
HTTPRoute und TLS mit im Pfad. Hairpin über die eigene öffentliche IP funktioniert auf
netcup (verifiziert 2026-09-03).

**Auth per selbst signiertem HS256-JWT** — dasselbe Verfahren wie im Modell-Gating-Sidecar.
Kein Passwort, kein API-Key, kein zusätzliches Secret; der `WEBUI_SECRET_KEY` liegt ohnehin
als agenix-Secret auf dem Host. Ein Passwort ginge auch gar nicht: kanidm kann
Personen-Credentials nicht provisionieren, die entstehen nur interaktiv.

**Soll-Werte aus `self.chat`, nicht aus Literalen im Test.** Definiert als `chatSpec` in
`modules/openwebui.nix`. Ein Test mit eigener Wahrheit bestätigt irgendwann grün eine
Vergangenheit. Zusätzlich hängt eine `assertion` im Modul: laufen `modelGrants` und
`chatSpec.limitedModelIds` auseinander, bricht schon der **Eval**.

**Kein `set -e`.** Der Lauf soll alle Prüfungen durchziehen und am Ende eine vollständige
Liste zeigen, statt beim ersten Fehler den Rest zu verstecken.

**Signup wird über `/api/config` geprüft, nicht per POST.** Ein echter Signup-POST würde im
Regressionsfall genau das Admin-Konto anlegen, das er aufdecken soll.

**Timer statt `wantedBy = multi-user.target`.** Nach einem Deploy braucht der Pod bis zu
fünf Minuten (`terminationGracePeriodSeconds` 300 bei `Recreate`) — ein Test in der
Aktivierung meldete zuverlässig rot, obwohl alles in Ordnung ist.

## Gegenprobe

Ein Test, der nicht rot werden kann, ist wertlos. Für Schritt 8 nachgewiesen
(2026-09-03): ein nicht registrierter Client (`mcp:doesnotexist`) liefert 404 mit leerem
`redirect_url` — genau der Zweig, den die Prüfung als FAIL wertet.

```
mcp%3Agmail            http=302 redirect=[https://accounts.google.com/o/oauth2/v2/…]
mcp%3Adoesnotexist     http=404 redirect=[]
```
