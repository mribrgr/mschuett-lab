# BrickLink-MCP — Shop-Verwaltung aus dem Chat

**Ziel:** mschuett verwaltet **SteinAberFein** über `chat.mauritiusberger.de` und
braucht die BrickLink-Web-UI langfristig nicht mehr; mberger verwaltet **dinoland**
über denselben Weg.
**Stand:** 2026-08-27 gebaut und gegen den echten Store SteinAberFein verifiziert
(986 Bestellungen, 12.714 Lots, Katalog-Export). Credentials liegen in agenix.
Die Verdrahtung in OpenWebUI ist **deklarativ** (kein UI-Schritt).

> **Stand 2026-08-27, deployt.** Multi-Shop und die XML-Exporte laufen auf netcup.
> Im Cluster verifiziert: SteinAberFein vollständig (API + Exporte), Dinoland über die
> Exporte, OpenWebUI sieht 39 Tools.
>
> **Beide Shops vollständig live** (seit 2026-08-30): Dinolands API-Token ist für die
> netcup-IP neu ausgestellt, `TOKEN_IP_MISMATCHED` ist damit erledigt. Im Cluster
> geprüft: `orders_dashboard` 7 Bestellungen, `inventory_stats` 235 Lots / 4.843,50 €,
> `member_ratings` 15× Lob — plus die Exporte über den Web-Pfad.

- Code: `pkgs/bricklink-mcp/` (Python, FastMCP)
- Deployment: `modules/bricklink-mcp.nix` (nix:0-Image + `services.k3s.manifests`)
- Secrets: `secrets/bricklink-{api,web-token,mcp-bearer}.age`

## Zwei Shops, hart getrennt

Der Server bedient mehrere BrickLink-Shops. Es gibt bewusst **keinen „aktuellen
Shop"** und keinen Zustand, der zwischen Aufrufen hängen bleibt.

| Shop | Slug | BL-Konto | userID | agenix-Secret | Default für |
|---|---|---|---|---|---|
| SteinAberFein | `steinaberfein` | `SteinAberFein` | 2795503 | `secrets/bricklink-api-steinaberfein.age` (+ `bricklink-web-token.age`) | mschuett |
| Dinoland | `dinoland` | `dinoliebe` | 3602661 | `secrets/bricklink-api-dinoland.age` | mberger |

⚠️ Bei Dinoland sind Shopname und Verkäuferkonto verschieden: der Shop heißt
**Dinoland**, das Konto **dinoliebe** (`store.bricklink.com/dinoliebe`). Der Slug
folgt dem Shopnamen, weil im Chat davon geredet wird; das Konto steht als `USERNAME`
im Secret und ist der Guard gegen Verwechslung. Aufgelöst wird beides — `dinoland`,
`Dinoland` und `dinoliebe` führen alle zum selben Shop.

Die Shop-Liste steht in `modules/bricklink-mcp.nix` (`stores`) — das ist die einzige
Quelle. Jeder Shop bringt eigenes Consumer-/Token-Paar und eigenen BL-Benutzernamen
mit; BrickLinks Limit von 5000 Requests/Tag hängt am Consumer-Key und wird deshalb
**pro Shop** gezählt.

### Drei Schranken gegen Verwechslung

1. **`store` pro Aufruf.** 27 der 33 Tools nehmen einen `store`-Parameter. Ist er
   nicht gesetzt und lässt sich kein Nutzer-Default ermitteln, wird der Aufruf
   abgelehnt — mit der ausdrücklichen Aufforderung, den Nutzer zu fragen. Kein Raten,
   kein Übernehmen aus einem früheren Thema.
2. **Jede Antwort nennt den Shop.** `store` und `store_label` stehen in jeder
   store-bezogenen Antwort; die Server-Instructions verlangen, den Shop in der
   Chat-Antwort mitzunennen. Eine Verwechslung ist damit sichtbar, nicht stumm.
3. **Verkäufer-Guard auf Datenebene.** Jeder schreibende Aufruf prüft, dass
   `seller_name` der Bestellung zum Benutzernamen des gewählten Shops passt. Greift
   ein Aufruf mit dem falschen Shop, wird **nichts** geschrieben — auch dann nicht,
   wenn Modell und Guardrail-Prompt versagen. Das ist die einzige Schranke, die nicht
   von Formulierungen abhängt.

Zusätzlich verlangen die Instructions, vor jedem schreibenden Aufruf Shop **und**
Bestellnummer bestätigen zu lassen.

### Wie der Shop bestimmt wird

1. ausdrücklich angegebener `store` — Slug, Anzeigename oder BL-Benutzername,
   Groß-/Kleinschreibung egal;
2. Default des anfragenden Nutzers (`userDefaults` im Modul);
3. nur bei reinen **Katalog**-Abfragen (Item, Subsets, Preis-Guide, Farben,
   Element-ID): erster benutzbarer Shop — die Daten gehören BrickLinks Katalog, nicht
   einem Shop, und es zählt nur, wessen Kontingent den Request bezahlt;
4. sonst Fehler mit der Liste der Möglichkeiten.

Schritt 2 braucht die OpenWebUI-Nutzer-Header (`X-OpenWebUI-User-Email`), also
`ENABLE_FORWARD_USER_INFO_HEADERS = "True"` in `modules/openwebui.nix` — steht dort.
Ohne die Header funktioniert alles weiter, nur muss dann bei **jedem** Aufruf ein Shop
mitgegeben werden. Das Tool `stores()` legt Auswahl, Aufrufer und Default offen; es
ist der Einstieg, wenn der Shop unklar ist.

Shop-frei sind: `catalog_search`, `catalog_colors`, `catalog_categories`,
`catalog_status`, `catalog_refresh` (alles Offline-Index) und `stores`.

## Recherche-Ergebnis: wo kommen die Daten her

### 1. Store API v1 — der Hauptweg

`https://api.bricklink.com/api/store/v1`, OAuth 1.0a (HMAC-SHA1), Antwortform
`{"meta": {...}, "data": ...}`.

Die Doku-Seiten (`bricklink.com/v3/api.page?page=…`) sind reines JavaScript; der
komplette Doku-Text steckt in `static2.bricklink.com/_build/js/Api.build.js`.
Daraus extrahiert und gegen den Code hier abgeglichen — die API kann mehr, als
die halbtote Redmine-Doku vermuten lässt:

| Bedarf | Endpoint | Tool |
|---|---|---|
| Verkäufe / Einkäufe | `GET /orders?direction=in\|out&status=…&filed=` | `orders_list`, `orders_dashboard` |
| Bestelldetail **inkl. Lieferadresse** | `GET /orders/{id}` (`shipping.address.*`, `buyer_email`, `cost`, `disp_cost`, `total_weight`, `buyer_order_count`) | `order_get` |
| Positionen | `GET /orders/{id}/items` (Liste von Batches) | `order_items` |
| Nachrichten | `GET /orders/{id}/messages` | `order_messages` |
| Bewertungen | `GET /feedback`, `GET /feedback/{id}`, `POST /feedback`, `POST /feedback/{id}/reply`, `GET /members/{user}/ratings` | `feedback_*`, `member_ratings` |
| Status setzen | `PUT /orders/{id}/status`, Body `{"field":"status","value":"PACKED"}` | `order_mark_packed`, `order_mark_shipped` |
| Sendungsnummer | `PUT /orders/{id}` mit `shipping.tracking_no` / `date_shipped` / `tracking_link` / `method_id` | `order_mark_shipped`, `order_set_tracking` |
| Versandmail | `POST /orders/{id}/drive_thru?mail_me=` | `order_send_drive_thru` |
| Inventar | `GET /inventories`, `GET /inventories/{id}` | `inventory_list`, `inventory_get`, `inventory_stats` |
| Katalog | `GET /items/{type}/{no}`, `/subsets`, `/supersets`, `/colors`, `/item_mapping` | `catalog_item`, `catalog_subsets`, `catalog_supersets`, `known_colors`, `element_id_lookup` |
| Preis-Guide | `GET /items/{type}/{no}/price` (`guide_type=stock\|sold`, `new_or_used`, `country_code`, `region`, `currency_code`, `vat`) | `price_guide` |
| Events | `GET /notifications` | `notifications` |
| Versandarten | `GET /settings/shipping_methods` | `shipping_methods` |

Statusliste (`help.asp?helpID=41`, API-Werte in Großschreibung): PENDING, UPDATED,
PROCESSING, READY, PAID, PACKED, SHIPPED, RECEIVED, COMPLETED, OCR, NPB, NPX, NRS,
NSS, CANCELLED.

Drei Randbedingungen, die man kennen muss:

- **Token pro IP — und das wird durchgesetzt.** „After registering static IP addresses
  of your endpoint client, you can then access tokens… BrickLink resources are
  accessible only from the registered location." Am 2026-08-27 belegt: das Dinoland-
  Token, das auf `152.53.15.24` (netcup) registriert ist, antwortet von einer anderen
  Adresse mit `401 TOKEN_IP_MISMATCHED … BAD_OAUTH_REQUEST`.

  ⚠️ Korrektur einer früheren Notiz in dieser Datei: dort stand, die IP-Bindung werde
  NICHT durchgesetzt, weil SteinAberFein von einer fremden Adresse funktionierte. Das
  war ein Fehlschluss aus einem Einzelfall — bei SteinAberFein ist die Adresse
  offenbar mitregistriert. Die Regel gilt, und das heißt: **Tokens müssen für die
  netcup-IP ausgestellt sein, und Live-Tests gehen nur auf dem Server.**
- **5000 Requests/Tag.** Der Server bucht jeden Aufruf mit (`state.db`) und blockt
  bei 4000, damit ein unbedachter Preis-Sweep nicht das Tagesbudget frisst.
  Katalogantworten werden 30 Tage, Preise 12 Stunden gecacht. `api_quota` zeigt den Stand.
- **Falle:** in *My Orders Settings* gibt es die Option „order payment status from
  order status". Ist sie an, zieht ein Statuswechsel den Zahlungsstatus mit.
  Vor dem ersten Schreibzugriff prüfen.

### 2. Katalog-Export — nur wegen der Suche

Die API hat **keinen Suchendpunkt**: Items sind nur über die exakte Nummer
abfragbar. Deshalb derselbe Weg, den BrickStore geht — einmal den offiziellen
Katalog ziehen und lokal indizieren:

```
POST account.prod.member.bricklink.info/api/v1/actions/verify-and-create-session
     {"clientId": …, "clientToken": …}            → {"sessionToken": …}
GET  www.bricklink.com/catalogDownload.asp?a=a&viewType=…&downloadType=X
     Header: x-bl-tpa-client-id, x-bl-session-token
```

⚠️ Der Client-Header heißt **`x-bl-tpa-client-id`** (tpa = third party application),
nicht `x-bl-client-id`. Mit dem falschen Namen antwortet
`verify-and-create-session` trotzdem mit HTTP 200 **und** einem gültig aussehenden
`sessionToken` — jeder Folge-Request an `www.bricklink.com` landet dann aber auf
`auth/sign-in?…`. Das sieht wie ein abgelaufener 30-Tage-Token aus und ist keiner
(am 2026-08-27 genau in diese Falle gelaufen).

`viewType`: 1 Item-Typen, 2 Kategorien, 3 Farben, 5 Part-Color-Codes,
0 = Items eines Typs (mit `selItemColor=Y&selWeight=Y&selYear=Y`).
Ergebnis landet als SQLite mit FTS5 im PVC; `catalog_search` kostet danach kein
API-Kontingent. Refresh alle 7 Tage in einem Hintergrund-Thread (kein CronJob:
das PVC ist ReadWriteOnce, ein zweiter Pod würde sich um den Mount streiten).

Zwei Dinge, die am 2026-08-27 durchgemessen wurden:

- **Größen:** S 6,1 MB · P 33,9 MB · M 5,9 MB · B 2,5 MB · G 7,8 MB · C 1,5 MB ·
  I 3,7 MB · O 6,1 MB. Deshalb Streaming-Parser (`iterparse` + `root.clear()`) und
  nicht `fromstring` — ein DOM über 34 MB XML sprengt das Memory-Limit des Pods.
- **`U` (Unsorted Lot) antwortet reproduzierbar mit HTTP 500**, auch nach allen
  Retries; für den Typ gibt es keinen Export. Außerdem quittiert BrickLink eine
  Serie großer Downloads gerne mit einem 500, der Minuten anhält. Deshalb: Retry mit
  10/30/90/300 s, 3 s Pause zwischen den Exporten, und ein Typ, der endgültig
  scheitert, blockiert nicht den ganzen Index — er landet in
  `catalog_status().failed_types`. Nur wenn KEIN Typ lädt, bleibt der alte Index stehen.

**Die `x-bl-client-id` ist BrickStores** (`ca629c09-4d8c-45dc-8a6f-bfb2b058f720`,
aus `src/utility/transfer.cpp`). Bewusste Entscheidung, mit offenen Karten:

- Die ID ist kein Credential, sie identifiziert nur die Anwendung. Das Credential
  ist der `clientToken`, und der ist **Max' eigener**, selbst erzeugt auf
  `bricklink.com/v3/brickstore-access-management.page`.
- Die API-ToU lizenzieren den Zugang „limited, **personal, non-sublicenseable,
  non-transferable**" und verbieten „Provide, procure or permit third party access
  to the Website unless expressly so authorized". Eine fremde Client-ID zu
  verwenden ist damit mindestens grenzwertig — deshalb: nur lesende
  Katalog-Downloads, ein Refresh pro Woche, kein Order-Verkehr über diesen Pfad.
- **Nicht** übernommen wurde BrickStores **Affiliate-Key** (in dessen
  Datenbank-Download, für `api.bricklink.com/api/affiliate/v1/price_guide_batch`).
  Den zu benutzen wäre der eigentliche ToU-Bruch, und bei Auffälligkeit rotiert
  BrickLink ihn — dann ist der Preis-Guide für **alle** BrickStore-Nutzer tot.
  Der Preis-Guide läuft hier über den offiziellen Endpunkt (ein Item pro Request,
  dafür mit Cache).
- **Der Token läuft nach 30 Tagen ab** (BrickStore-CHANGELOG 2025.9.1) und ist nur
  im Browser erneuerbar. Läuft er ab, funktioniert alles außer `catalog_refresh`
  weiter; das Tool sagt dann selbst, was zu tun ist.

### 2b. XML-Exporte — der billige Weg an Massendaten

Die Web-Session kann mehr als den Katalog. Drei Exporte sind angebunden; sie kosten
**kein API-Kontingent** und liefern teils Felder, die die API nicht hat:

| Export | Endpunkt | Was es bringt |
|---|---|---|
| Bestellungen + Positionen | `orderExcelFinal.asp` (`viewType=X`) | EIN Request für einen ganzen Zeitraum inklusive aller Positionen. Über die API wären das 1 + n Requests (einer pro Bestellung). Am 2026-08-27: 30 Tage = 26 Bestellungen, 566 Positionen, 345 KB. |
| Store-Inventar | `invExcelFinal.asp` (`viewType=x`) | Komplettes Inventar (12.714 Lots, 7,5 MB) mit `DATELASTSOLD`, `INVDIMX/Y/Z`, `SUBCONDITION`, `EXTENDED` — die gibt es in der API NICHT. |
| Wanted Lists | `v2/wanted/list.page` + `files/clone/wanted/downloadXML.file` | Die API hat dafür **gar keinen** Endpunkt. |

Formate: Bestellungen und Inventar gibt BrickLink **nur als XML** heraus (`viewType=T`
liefert dort 0 Bytes, geprüft). CSV-artig (TAB-getrennt) gibt es ausschließlich beim
KATALOG-Export (`downloadType=T`) — z.B. alle Minifiguren als 2 MB TSV mit Kopfzeile.

Tools: `orders_export`, `top_selling_items`, `inventory_export`, `wanted_lists`,
`wanted_list_items`, `export_download`, `exports_list`.

⚠️ **Rohe Bestelllisten sprengen den Chat.** Am 2026-08-27 fragte mschuett „welche Lego
teile werden besonders oft gekauft" — das Modell rief `orders_export` auf, bekam 26
Bestellungen mit über 500 Positionen, produzierte laut meridian-Log 30k Output-Token,
wich auf den Code-Interpreter aus und lieferte am Ende eine LEERE Antwort. Der MCP
selbst hatte beide Aufrufe sauber mit HTTP 200 beantwortet; der Fehler lag im
Antwortumfang. Zwei Konsequenzen:

- `orders_export` hat `include_items` jetzt **standardmäßig aus** und kappt Positionen
  bei `max_items` (Default 200, Untergrenze 10). Was wegfiel, steht in
  `items_truncated` bzw. pro Bestellung in `items_omitted` — nicht still.
- Für Auswertungen gibt es `top_selling_items`: aggregiert den Export lokal pro Item
  und Farbe und liefert `limit` Zeilen statt mehrerer Hundert. `by` = `quantity`
  (Default), `orders` oder `revenue`. Das ist die Antwort auf „was geht am meisten weg".

**Filter kommen ins Tool, nicht in die Datei.** `inventory_export` filtert lokal über
den (15 Minuten gecachten) Export — Volltext über Item-Nummer/Beschreibung/Lot-Bemerkung,
Item-Typ, Farbe, Stockroom, Mindestmenge und `not_sold_since_days` für Ladenhüter (das
geht nur hier, weil `DATELASTSOLD` ein Export-Feld ist). Mit `as_csv=true` kommt der
gefilterte Auszug zusätzlich als Semikolon-CSV zurück — direkt in eine Tabelle
kopierbar. Bei `orders_export` ergibt `as_csv` eine Zeile pro POSITION mit
Bestellnummer, Käufer und Lot-Bemerkung: das ist eine fertige Pickliste.

**Download-Link.** `export_download` legt die Rohdatei unter `/data/exports` im PVC ab
und liefert einen signierten, ablaufenden Link mit (Details unten). Die Datei selbst
kommt NICHT in den Chat — ein Inventar-Export sind 7,5 MB. Ohne Link geht es auch:

```sh
kubectl -n chat exec deploy/bricklink-mcp -- cat /data/exports/<datei> > ./<datei>
```

(`kubectl cp` scheitert, weil im nix:0-Image kein `tar` liegt.)

## Öffentlicher Zugriff auf die Export-Dateien

`https://chat.steinaberfein.de/bricklink-exports/<datei>?md5=…&expires=…`

Signierter Link, Standard-Gültigkeit **60 Minuten** (maximal 1440). `export_download`
gibt ihn direkt mit, `export_link` erzeugt für eine schon vorhandene Datei einen neuen.

### Warum genau so

Vier Wege wurden abgewogen:

| Weg | Bewertung |
|---|---|
| Datei in den Chat schreiben | Fällt aus: 7,5 MB Inventar sprengen den Kontext, und OpenWebUI wandelt nur `image`/`audio`-Ergebnisse in Dateien um (`utils/middleware.py`) — für XML/CSV gibt es diesen Pfad nicht. |
| MCP selbst öffentlich machen, Route auf `/mcp` | Abgelehnt. Dann hängt der Prozess mit den Store-Credentials am Internet, und ein Fehler in der Route oder in FastMCPs Auth wäre direkt ein Datenleck. |
| OIDC-Proxy (kanidm) vor die Dateien | Stärkste Identitätsgarantie, aber ein zusätzliches Deployment, ein weiterer kanidm-Client und eine SSO-Anmeldung pro Abruf. Für „Link aufs Handy schicken" zu schwer; bleibt die Option, wenn die Dateien mal wirklich sensibel werden. |
| **nginx-Sidecar mit `secure_link` (gewählt)** | Der Prozess, der ans Internet geht, ist ein nginx, das genau ein Verzeichnis LESEND kennt und ohne gültige Signatur nicht einmal auf die Platte schaut. |

### Was den Zugriff begrenzt

- **Eigener Container, eigener Port.** nginx läuft im selben Pod wie der MCP, mountet
  das PVC **`readOnly: true`** und hört auf 8082. Der MCP-Prozess (8081) ist vom
  Internet weiterhin nicht erreichbar.
- **Die CiliumNetworkPolicy trennt die Ports.** open-webui darf auf 8081, das Gateway
  darf auf 8082 — nichts sonst, in keine Richtung. (Die Gateway-Regel lautet
  `fromEntities: [host]`, weil `cilium-envoy` mit `hostNetwork=true` läuft und sein
  Verkehr für Cilium von der Host-Entity kommt, nicht von einem Pod-Endpoint.)
- **Die Route erlaubt genau ein Pfad-Präfix**, `/bricklink-exports/`, auf den beiden
  bestehenden chat-Hostnamen. Kein neuer Hostname, also kein Chart-Eingriff und kein
  neues Zertifikat. `/mcp` liegt auf einem anderen Port und ist von der Route nicht
  erreichbar.
- **nginx prüft Signatur und Ablauf, bevor es etwas anfasst.** Falsche Signatur → 404
  (nicht 403: ein falscher Link soll nicht bestätigen, dass die Datei existiert),
  abgelaufen → 410. Kein Verzeichnisindex, nur GET/HEAD,
  `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff`,
  `Cache-Control: private, no-store`, `Referrer-Policy: no-referrer`.
- **Das Geheimnis steht in keiner ConfigMap.** Es kommt aus
  `secrets/bricklink-files-secret.age` ins k8s-Secret und wird beim Containerstart in
  die nginx-Config nach `/tmp` eingesetzt (nginx kann keine Env-Variablen in der
  Config auflösen). Rotation: `agenix -e` mit neuem Zufallswert, deployen — alle alten
  Links sind sofort ungültig.

### Was der Link NICHT kann, und was das bedeutet

- **Ein Link ist ein Passwort.** Wer ihn hat, kommt an die Datei; es gibt keine
  Anmeldung dahinter. Deshalb die kurze Laufzeit, `no-referrer` und der Hinweis in
  jeder Tool-Antwort. In Gruppenchats gehört er nicht.
- **Keine Einmal-Nutzung.** `secure_link` zählt keine Abrufe; innerhalb der Laufzeit
  ist der Link beliebig oft nutzbar. Für Einmal-Links bräuchte es Zustand — dann wäre
  der Dateiserver kein zustandsloses nginx mehr.
- **md5, nicht SHA.** `secure_link` kennt nur md5. Das ist hier eine Keyed-Konstruktion
  mit 64 Zeichen Geheimnis, kein Kollisionsschutz — ohne das Geheimnis lässt sich kein
  gültiger Link bauen. Für stärkere Garantien wäre der OIDC-Proxy der richtige Schritt,
  nicht ein anderer Hash.
- **`fromEntities: [host]`** erlaubt formal alles, was im Host-Netz des Nodes läuft,
  nicht nur Envoy. Auf einem Single-Node-Cluster mit deklarativer Config ist das
  vertretbar; enger geht es erst, wenn Cilium den Gateway-Envoy als eigenen Endpoint
  führt.



⚠️ **Das Web-Token ist KONTOGEBUNDEN, nicht an den Consumer-Key.** Mit dem Token von
Konto A liefern die Exporte die Daten von Shop A — egal, welcher `store` angefragt war.
Deshalb hat jeder Shop sein eigenes Web-Token (`WEB_TOKEN` im Shop-Secret), und vor
jeder Auslieferung prüft `WebSession.verify_account`, dass der Kontoname zum Shop
passt; sonst bricht der Aufruf ab. Der Kontoname steht in der Wanted-List-Seite
(`var username = '…'`) — das ist die einzige gefundene maschinenlesbare Stelle.

### 2c. Postfach über die Benachrichtigungsmails

**Das Problem:** Die Store API liefert ausschließlich Nachrichten, die an einer
BESTELLUNG hängen. Eine Anfrage über „Contact Member" oder von einer Katalogseite hat
keine Bestellnummer und ist dort unsichtbar — genau daran ist mschuett am 2026-09-01
zweimal hängengeblieben („die letzte eingegangene nachricht ist eine anfrage zu einer
figur").

**Warum nicht über den Web-Weg:** BrickLink gibt der TPA-Session nur die Endpunkte
frei, die BrickStore selbst benutzt. Am 2026-09-02 gemessen:

| Endpunkt | von BrickStore benutzt | Antwort |
|---|---|---|
| `catalogDownload.asp`, `orderDetail.asp`, `v2/wanted/list.page` | ja | **200** |
| `orderReceived.asp`, `memberInfo.asp`, `orderSettings.asp`, `v2/mystore/display.page` | nein | **302 → Anmeldeseite** |

Das Postfach liegt außerhalb der Freigabe; keine URL ändert das. (`messageList.asp`
und `messageThread.asp` sind übrigens das Diskussionsforum, nicht das Postfach.)

**Der gewählte Weg:** BrickLink schickt jede eingegangene Nachricht an die
Kontoadresse. `inbox_messages` liest dieses Postfach per IMAP — **nur lesend**, mit
`BODY.PEEK`, damit der Ungelesen-Status unberührt bleibt. Der Parser holt aus der Mail
Absender-Mitglied, Betreff, Klartext (HTML wird entkleidet), Bestellbezug und die
BrickLink-Links heraus.

⚠️ **Antworten geht darüber NICHT.** BrickLink verschickt von einer No-Reply-Adresse;
eine Antwortmail landet nicht im BrickLink-Thread. Die Tools liefern deshalb den Link
in die Web-UI mit — das Modell formuliert den Text, abgeschickt wird dort mit zwei
Klicks. Das war die ausdrückliche Entscheidung (2026-09-01), weil die Alternative
(Playwright mit Max' echtem Login) sein Passwort im Cluster und eine
AWS-WAF-Abhängigkeit bedeutet hätte.

Konfiguration pro Shop, im jeweiligen Shop-Secret:

```
MAIL_HOST=imap.gmail.com
MAIL_PORT=993
MAIL_USER=steinaberfeinbl@gmail.com
MAIL_PASSWORD=<App-Passwort, NICHT das Kontopasswort>
MAIL_FOLDER=INBOX
```

Bei Gmail braucht es zwingend ein App-Passwort. Fehlen die Werte, sagen genau diese
zwei Tools ab; alles andere läuft weiter.

## Code-Sandbox: PDFs, Diagramme, abrufbare Dateien

**Vorher:** OpenWebUIs Code-Interpreter lief als `pyodide` — Python im BROWSER. Zwei
harte Grenzen, beide aus mschuetts Chats:

- *„In dieser Umgebung stehen keine PDF-Bibliotheken zur Verfügung"* — pyodide bringt
  keine mit, und OpenWebUIs eigener pyodide-Prompt verbietet dem Modell das
  Nachinstallieren ausdrücklich.
- *„im Dateibrowser abrufbar"* — die Dateien lagen in `/mnt/uploads`, und das ist eine
  **IndexedDB im Browser** (`src/lib/workers/pyodide.worker.ts`), nicht der Server.
  Deshalb kam niemand an sie heran.
- Dazu: *„Bilder kann ich hier nicht rendern"* — kein matplotlib.

**Jetzt:** ein Jupyter-Kernel als Container `sandbox` im bricklink-mcp-Pod.

| | |
|---|---|
| Bibliotheken | pypdf, pikepdf, pdfplumber, pymupdf, reportlab, pandas, numpy, matplotlib, openpyxl, python-docx, Pillow, lxml, bs4, requests |
| Hochgeladene Dateien | `/mnt/uploads` — das PVC von open-webui, **lesend** gemountet |
| Ergebnisse | `/data/workspace` — dasselbe PVC wie die BrickLink-Exporte |
| Download | `workspace_list` + `workspace_link` → signierter Link unter `/bricklink-workspace/` |
| Erreichbar | nur aus dem open-webui-Pod (CNP, Port 8888) und nur mit Token |

Zwei Dinge, die dabei zu wissen sind:

- **OpenWebUI injiziert beim jupyter-Motor keine Dateien.** Das `/mnt/uploads` aus der
  pyodide-Welt existiert serverseitig nicht. Deshalb der Mount des open-webui-PVC.
  Zwei Pods am selben ReadWriteOnce-PVC gehen nur, weil beide auf **demselben Node**
  laufen (Single-Node, local-path). Mit einem zweiten Node bricht das und der Weg muss
  über eine API laufen.
- **Nachinstallieren ist nicht möglich** — ein nix-Python-Environment ist
  unveränderlich. Der Prompt sagt dem Modell das, statt es raten zu lassen. Fehlt eine
  Bibliothek dauerhaft, gehört sie ins Image.

Der Standardprompt von OpenWebUI wurde ersetzt: er beschreibt eine Browser-Umgebung,
was jetzt falsch wäre. Der eigene Prompt nennt beide Verzeichnisse, den Weg zum
Download-Link und die Bibliotheksliste.

### 3. Was nur im Web geht (Phase 2, bewusst offen)

Nachrichten **senden**/beantworten, Rechnung senden, NPB/OCR anlegen, Warenkörbe,
Store-Traffic-Statistiken, Katalogsuche über die Web-UI. (Wanted Lists sind seit dem
Export-Umbau drin, eingehende Nachrichten seit dem Postfach-Umbau — siehe oben.)
Für Phase 2 ist Playwright vorgesehen — mit der Warnung, dass BrickLink eine
**AWS-WAF-Challenge** (`awswaf.com/…/challenge.js`) vor die Seiten hängt.

### Was BrickStore selbst macht (zur Einordnung)

BrickStore nutzt die Store API **überhaupt nicht**, sondern die Web-Endpunkte mit
Session-Token: `invExcelFinal.asp` (Inventar-XML), `orderExcelFinal.asp`
(Orders + Items), `orderDetail.asp` (Adresse per Regex), `catalogDownload.asp`,
`btinvlist.asp`, `btchglog.asp`, Wanted-List-XML, `getStoreCart.ajax`.
Adress-Scraping brauchen wir nicht — die API liefert `shipping.address` mit.
BrickStore 2026.7.1 hat außerdem einen **eigenen MCP-Server** (`src/mcp-server/`),
der aber nur Katalog und offene Dokumente kann, keine Bestellungen, und in einer
Desktop-Qt-App lebt.

## Schreibrechte: absichtlich zwei Übergänge

`guards.py` erlaubt genau:

- `PENDING|UPDATED|PROCESSING|READY|PAID → PACKED`
- `PACKED → SHIPPED` (optional mit Sendungsnummer und Drive-Thru-Mail)

Zusätzlich: Feedback abgeben/beantworten und die Versandmail. Alles andere
(CANCELLED, NPB, OCR, COMPLETED, Zurückdrehen) ist nicht implementiert.
Jeder Schreibzugriff prüft außerdem `seller_name == BRICKLINK_STORE_USERNAME` —
eine Bestellung, in der wir Käufer sind, lässt sich nicht anfassen.

## Betrieb

```
open-webui (Pod) ──MCP/Streamable-HTTP──► Svc bricklink-mcp:8081 ──► Pod
                     Bearer-Token          CNP: nur open-webui        │
                                                                      ├ /data (PVC 3Gi): catalog.db + state.db
                                                                      └ egress: api.bricklink.com, www.bricklink.com,
                                                                        account.prod.member.bricklink.info
```

Kein Ingress. Drei Schranken wie bei meridian: keine HTTPRoute,
CiliumNetworkPolicy (nur der `open-webui`-Pod darf auf 8081), Bearer-Token.
In OpenWebUI wird die Verbindung per **Access Control** auf Max' Gruppe begrenzt.

## Runbook

### 1. Store-API-Credentials — PRO SHOP (einmalig, interaktiv)

Für jeden Shop mit dem BL-Konto **dieses** Shops einloggen, dann:

1. `api.bricklink.com/pages/clone/api/register_consumer.page` → Consumer-Key + Secret.
2. Dort die **IP `152.53.15.24`** registrieren → Access-Token + Token-Secret.
3. Eintragen (dotenv, fünf Zeilen, ohne Shop-Präfix — den setzt das Modul):

```sh
cd secrets
EDITOR=nano nix run github:ryantm/agenix -- -e bricklink-api-dinoland.age
# CONSUMER_KEY=…
# CONSUMER_SECRET=…
# TOKEN_VALUE=…
# TOKEN_SECRET=…
# USERNAME=<BL-Benutzername des Shops>      # Guard gegen Shop-Verwechslung
```

`USERNAME` ist keine Kosmetik: er ist die Datenschranke, die Schreibzugriffe auf die
Bestellungen genau dieses Shops begrenzt.

4. In *My Orders Settings* jedes Shops prüfen, ob „order payment status from order
   status" an ist.

Einen weiteren Shop aufnehmen: Eintrag in `stores` (Modul), Secret
`bricklink-api-<slug>.age` anlegen, Zeile in `secrets/secrets.nix`, optional
`userDefaults` ergänzen. Kein Code-Eingriff.

### 2. Web-Token — pro Shop, alle 30 Tage

Das Web-Token treibt den Katalog-Index UND die XML-Exporte. Es gehört zu einem
BrickLink-KONTO, also braucht jeder Shop sein eigenes, erzeugt im Browser **mit dem
Konto dieses Shops**:

```sh
# Token holen: https://bricklink.com/v3/brickstore-access-management.page
# SteinAberFein (historisch eigene Datei, vom Modul diesem Shop zugeordnet):
cd secrets && EDITOR=nano nix run github:ryantm/agenix -- -e bricklink-web-token.age
# Jeder weitere Shop: als WEB_TOKEN=… in sein Shop-Secret
cd secrets && EDITOR=nano nix run github:ryantm/agenix -- -e bricklink-api-dinoland.age
```

Fehlt das Token eines Shops, sagen genau die Export-Tools dieses Shops ab; API-Tools
und der (gemeinsame) Katalogindex laufen weiter.

Danach Deploy; der oneshot `bricklink-mcp-secrets` startet den Pod neu, wenn sich
der Inhalt geändert hat. Prüfen: Tool `catalog_status` (Feld `age_days`).

### 3. Bearer-Token

```sh
openssl rand -base64 32
cd secrets && EDITOR=nano nix run github:ryantm/agenix -- -e bricklink-mcp-bearer.age
```

### 4. Deploy

Das Image ist ein aarch64-linux-Build → **nicht** auf dem Mac, sondern über die
Builder-VM (Weg und Fallstricke: README, Abschnitt „Bauen: NICHT auf diesem Node").

### 5. OpenWebUI verdrahten — passiert von selbst

**Kein UI-Schritt.** `modules/openwebui.nix` rendert die Verbindung als
`TOOL_SERVER_CONNECTIONS` (JSON) in das Secret `chat/open-webui-secrets`:

```json
[{ "url": "http://bricklink-mcp.chat.svc.cluster.local:8081/mcp", "path": "",
   "type": "mcp", "auth_type": "bearer", "key": "<Bearer aus agenix>",
   "config": { "enable": true,
               "access_grants": [{"principal_type":"user","principal_id":"*","permission":"read"}] },
   "info": { "id": "bricklink", "name": "BrickLink", "description": "…" } }]
```

Warum das die EINZIGE Quelle ist: bei `ENABLE_PERSISTENT_CONFIG=False` liefert
`Config.get('tool_server.connections')` den Env-Wert und schaut die DB überhaupt
nicht an (`models/config.py`). Ein Eintrag über Admin → Integrations landet in der
DB und wäre wirkungslos — genau so gewollt.

Zusätzlich trägt der Gating-Sidecar den Server bei Max' drei Modellen in
`meta.toolIds` (`server:mcp:bricklink`) ein. Die Web-UI aktiviert Tool-Server aus
`toolIds` beim Modellwechsel selbst (`Chat.svelte`: „Set Default Tools") — Max muss
also nichts anhaken.

⚠️ `principal_id: "*"` (alle angemeldeten Nutzer) statt eines Gruppen-Grants: ein
Gruppen-Grant braucht die OpenWebUI-**Gruppen-UUID**, und die entsteht erst zur
Laufzeit — im Repo nicht hinschreibbar. „Alle" sind hier mberger (Admin, sieht
ohnehin alles) und mschuett; weitere Konten entstehen nur über kanidm-SSO und landen
mit `DEFAULT_USER_ROLE=pending`. Der Schutz liegt ohnehin in der
CiliumNetworkPolicy und im Bearer-Token, nicht in diesem Grant.

### 6. Erster Rauchtest

`stores` → beide Shops, `credentials_present` je Shop. `api_quota` → Budget pro Shop.
`orders_dashboard` (mit `store`) → offene Bestellungen. `catalog_refresh` (dauert
Minuten, gilt für alle Shops) → danach `catalog_search` mit „Brick 2 x 4".

## Verifikationsstand (2026-08-27, deployt auf netcup)

Alles unten ist am laufenden System gemessen, nicht abgeleitet.

### Gegen den echten Store (SteinAberFein)

| Prüfung | Ergebnis |
|---|---|
| `orders_dashboard` | 110 nicht-purged Bestellungen: 89 COMPLETED, 13 SHIPPED, 4 RECEIVED, 2 CANCELLED, 1 PAID, 1 PENDING; Umsatz 30 Tage 919,74 € |
| `orders_list` | 986 Bestellungen insgesamt, 876 davon PURGED → Default filtert sie aus; 25 Treffer = 16 KB Antwort (unlimitiert waren es 697 KB) |
| `order_get` | Lieferadresse vollständig (`address1/2`, `city`, `postal_code`, `state`, `country_code`, `phone_number`, normalisierter Name) |
| `order_items` | 17 Lots in einem Batch |
| `order_messages` | echte Nachrichten gefunden (2 bzw. 1 in zwei der letzten fünf Bestellungen) |
| `feedback_list` | 616 erhaltene Bewertungen, Summary 615 Lob / 1 neutral |
| `member_ratings` | PRAISE 615, NEUTRAL 1, COMPLAINT 0 |
| `inventory_stats` | 12.714 Lots, 240.996 Teile, Listenwert 39.639,74 €; Aufteilung for_sale / stockroom_A / retain |
| `price_guide` | PART 3001 schwarz, verkauft, DE: Ø 0,1176 € über 982 Verkäufe |
| `catalog_item` / `subsets` / `known_colors` / `element_id_lookup` | „Brick 2 x 4", 214 Teile in Set 7644-1, 60 Farben, Element-ID 300126 |
| `shipping_methods` | 18 Versandarten |
| `catalog_refresh` (im Pod, automatisch beim ersten Start) | 209.876 Items in 8 Typen, 215 Farben, 1.206 Kategorien, 42 MB Index in ~2 Minuten; `U` in `failed_types` |
| `catalog_search` | „brick 2 x 4" → 3001 zuerst; „millennium falcon" + Typ Set → 7190-1/7965-1/75030-1; Torso-Suche trifft `973pb…` |
| Tages-Kontingent | zählt korrekt mit (25 Requests im Test, 3.975 von 4.000 übrig) |

### Schranken

| Prüfung | Ergebnis |
|---|---|
| Guard `→ PACKED` gegen echte Bestellungen | erlaubt aus PENDING und PAID; blockiert aus COMPLETED, RECEIVED, SHIPPED |
| Guard `→ SHIPPED` | blockiert aus allem außer PACKED, inkl. „steht bereits auf SHIPPED" |
| Verkäufer-Guard | greift, wenn `seller_name` nicht `BRICKLINK_STORE_USERNAME` ist |
| MCP ohne Bearer-Token | 401 |
| Fremder Pod (`mongodb-operator`, ns `bricklink-sync`) → MCP | Timeout nach 8 s; derselbe Pod erreicht kanidm mit HTTP 303 — es ist die CiliumNetworkPolicy, kein Netzproblem |
| `cilium-dbg endpoint list` | Endpoint `app=bricklink-mcp`: Ingress-Enforcement **Enabled**, Egress Disabled (so gewollt) |

### OpenWebUI-Integration

| Prüfung | Ergebnis |
|---|---|
| `TOOL_SERVER_CONNECTIONS` im Pod | vorhanden, Typ `mcp`, Bearer aus agenix |
| `POST /api/v1/configs/tool_servers/verify` | `status: true`, **32 Tool-Specs**, alle 6 Schreib-Tools dabei |
| `GET /api/v1/tools/` als mberger (admin) | `server:mcp:bricklink` sichtbar |
| `GET /api/v1/tools/` als mschuett (user) | `server:mcp:bricklink` sichtbar — der `*`-Grant greift |
| `model.meta.toolIds` in der DB | bei allen drei Modellen `["server:mcp:bricklink"]` |
| Gating-Sidecar-Log | `gating ok: … tools=["server:mcp:bricklink"]` für alle drei Modelle |
| Erreichbarkeit aus open-webui | `/health` 200, MCP-Handshake mit Session-ID |

### Shop-Trennung (Multi-Store-Umbau, 2026-08-27)

| Prüfung | Ergebnis |
|---|---|
| Aufruf ohne `store`, Aufrufer unbekannt | abgelehnt: „FRAGE DEN NUTZER, welcher Shop gemeint ist" + Liste |
| Aufruf ohne `store`, Header von Max | läuft gegen `steinaberfein`, 110 Bestellungen |
| Aufruf ohne `store`, Header von Mauritius | läuft gegen `dinoland` → klarer Credential-Fehler mit Dateinamen |
| ausdrücklicher `store` gegen Nutzer-Default | ausdrücklicher gewinnt |
| Alias-Auflösung | Slug, Anzeigename und BL-Benutzername, case-insensitiv |
| unbekannter Shop | abgelehnt, nennt die möglichen Shops |
| Katalog-Tools ohne `store` | erlaubt (shop-unabhängige Daten), Fallback auf ersten benutzbaren Shop |
| Kontingent | pro Shop getrennt gezählt (steinaberfein 5 Requests, dinoland 0) |
| Schreibaufruf mit falschem Shop (Unit-Test) | ToolError, und `update_order*` wurde **nicht** aufgerufen |
| OAuth-Signatur pro Shop (Unit-Test) | jeder Shop signiert mit seinem eigenen `oauth_consumer_key` |
| Tool-Abdeckung | 39 Tools, 32 mit `store`, 7 bewusst ohne (Offline-Katalog, `exports_list`, `stores`) |
| Dinoland-API von einer fremden IP | `401 TOKEN_IP_MISMATCHED` — die IP-Bindung greift, das Token gilt nur auf netcup |

### XML-Exporte (2026-08-27, e2e gegen SteinAberFein)

| Prüfung | Ergebnis |
|---|---|
| Antwortgrößen nach dem Umbau (gemessen im Pod) | `orders_export` Default **13,9 KB** (vorher 139 KB mit Positionen), mit Positionen und `max_items=50` 25,6 KB bei `items_truncated=514`, `top_selling_items` **1,2 KB** |
| `top_selling_items` steinaberfein, 180 Tage | 5 Sekunden, 107 Bestellungen, 2.129 verschiedene Teile, 0 API-Requests. Spitze: P 3023 schwarz 355 Stk / P 4265c 198 / P 3004 195 |
| dasselbe nach Umsatz | 60198-1 (110 €), 5264 (65,60 €), 91405 (52,26 €) |
| `top_selling_items` Dinoland, 365 Tage | 6 Bestellungen, 17 Teile; Spitze nach Umsatz 21323-1 mit 250 € |
| `orders_export` 30 Tage | 26 Bestellungen mit Positionen, `api_requests_used=0`, Kontingent unverändert |
| Positionsdaten | Lot-Bemerkung kommt mit (`X Hanna3 02-08` = Lagerplatz), plus LOTID, MYCOST, WEIGHT, CONDITION |
| `export_download` orders | 344.855 Bytes XML, 566 ITEM-Knoten, Datei auf Platte, `fetch_hint` für kubectl |
| `as_csv` Pickliste | 32 Positionszeilen, Semikolon-CSV mit Kopfzeile |
| `export_download catalog_items fmt=tsv` | 2.031.732 Bytes, 19.166 Zeilen, echte TSV-Kopfzeile |
| `exports_list` | listet beide erzeugten Dateien mit Größe und Zeitstempel |
| Export ohne Web-Token (Dinoland) | klare Absage samt Datei- und Token-Hinweis |
| Kontoprüfung (Unit-Test) | falsches Konto → Abbruch, keine Auslieferung |
| Parser (Unit-Test) | Orders/Inventar/Wanted, US-Datumsformat, nackte `&`, leere Antwort, Ladenhüter-Filter, CSV |

### Beide Shops über die Exporte (2026-08-27, nachdem beide Web-Tokens vorlagen)

| Prüfung | Ergebnis |
|---|---|
| **Nach dem Deploy im Cluster** | SteinAberFein `orders_dashboard` 110 Bestellungen, `inventory_stats` 12.714 Lots / 39.639,74 €; beide Shops `orders_export` (26 bzw. 1 Bestellung, 0 API-Requests); Dinoland Ladenhüter-CSV und 5 Wanted Lists; Kontingent getrennt (2 bzw. 3 Requests) |
| Dinoland-API vom Server, Token für die netcup-IP (2026-08-30) | 7 Bestellungen, 235 Lots / 4.843,50 €, 15× Lob — die IP-Bindung ist damit sauber bedient |
| OpenWebUI nach dem Deploy | `tool_servers/verify` → 39 Specs, `status: true` |
| CiliumNetworkPolicy nach dem Deploy | Endpoint `app=bricklink-mcp`: Ingress-Enforcement Enabled |
| Kontoprüfung SteinAberFein | Token gehört Konto `SteinAberFein` (userID 2795503) — passt |
| Kontoprüfung Dinoland | Token gehört Konto `dinoliebe` (userID 3602661) — passt |
| **Fremdes Token**: SteinAberFein-Token für Dinoland benutzen | abgebrochen: „Der Export käme aus dem FALSCHEN Shop" — nichts ausgeliefert |
| `orders_export` Dinoland, 30 Tage | 1 Bestellung (188,69 €), `api_requests_used=0` |
| `inventory_export` Dinoland | 235 Lots / 350 Teile / 5.043,50 Listenwert, 228 nie verkauft |
| Ladenhüter-Filter Dinoland | 228 Lots seit >2 Jahren nicht verkauft, CSV mit Lot-Bemerkung |
| Zweiter Aufruf | `from_cache=true` — der 15-Minuten-Cache greift |
| `wanted_lists` Dinoland | 5 Listen, eine bei 97,3 % gefüllt |
| Trennung | SteinAberFein 12.714 Lots / 240.996 Teile gegen Dinoland 235 / 350 — komplett verschiedene Datensätze |
| API-Kontingent nach allen Exporten | 0 Requests bei beiden Shops verbraucht |

### Öffentliche Download-Links (2026-08-27, von außerhalb des Clusters geprüft)

| Prüfung | Ergebnis |
|---|---|
| gültiger Link | HTTP 200, 3.380 Bytes, `content-disposition: attachment`, `x-content-type-options: nosniff`, `cache-control: private, no-store`, `referrer-policy: no-referrer` |
| Link ohne Signatur | **404** |
| Signatur um ein Zeichen verändert | **404** |
| Link mit 1 Minute Laufzeit | sofort 200, nach 66 s **410 Gone** |
| Verzeichnisindex `/bricklink-exports/` | **404** |
| `POST /mcp` auf demselben Hostnamen | 405 von OpenWebUI — der MCP ist NICHT erreichbar (anderer Port, CNP lässt vom Gateway nur 8082 zu) |
| `export_link` mit Pfad statt Name | abgelehnt: „name muss ein reiner Dateiname sein" |
| `export_link` für unbekannte Datei | abgelehnt, listet die vorhandenen |
| Signaturformat | Unit-Test rechnet md5 unabhängig nach und vergleicht mit dem, was nginx prüft |

### Code-Sandbox und Workspace-Links (2026-09-02)

Im Cluster geprüft:

| Prüfung | Ergebnis |
|---|---|
| Kernel mit Token | HTTP 200; **ohne** Token 403 — der Kernel hängt nicht offen im Pod-Netz |
| Bibliotheken | `pypdf, pikepdf, pdfplumber, fitz, reportlab, pandas, numpy, matplotlib, docx, openpyxl, PIL` importieren alle |
| `/mnt/uploads` | lesbar, 9 echte Chat-Uploads sichtbar |
| `/data/workspace` | beschreibbar |
| PDF e2e | Formularfeld geschrieben und wieder gelesen (`1.591 EUR *`), Seite gerendert (6.416 B PNG), Text extrahiert (`Testformular`), matplotlib-Diagramm (4.548 B) |
| `workspace_list` | die 4 erzeugten Dateien mit Größe |
| `inbox_messages` ohne Zugangsdaten | sagt ab und nennt die Datei, in die `MAIL_*` gehört |

Von außerhalb des Clusters geprüft (die Links kommen aus `workspace_link`):

| Prüfung | Ergebnis |
|---|---|
| gültiger Workspace-Link | HTTP 200, `application/pdf`, 3.295 B, beginnt mit `%PDF-`, `content-disposition: attachment` |
| ohne Signatur | **404** (nginx, 146 B — nicht die SPA) |
| Signatur um ein Zeichen verändert | **404** |
| Verzeichnisindex `/bricklink-workspace/` | **404** |
| `..%2Fexports%2Forders.csv` | **404** |
| `..%2Fstate.db` | **404** — die SQLite-Dateien bleiben unerreichbar |
| Link mit 1 Minute Laufzeit | 200, nach Ablauf **410 Gone** |
| Export-Präfix (Regression) | 200, `text/xml`, 3.380 B, beginnt mit `<?xml` |

Wichtig für künftige Tests: **nicht nur den Statuscode prüfen.** Fehlt ein Präfix in
der HTTPRoute, liefert open-webui HTTP 200 mit seiner SPA — Fehler 15 unten.

### Betrieb

| Prüfung | Ergebnis |
|---|---|
| Pod-Neustart | Katalogindex bleibt (gleiche `built_at`, kein neuer Download), Suche sofort wieder da |
| agenix → k8s-Secret | 7 Schlüssel im Secret, Unit `active`, Pod-Rollout nur bei geändertem Inhalt |
| FastMCP-Telemetrie | `FASTMCP_CHECK_FOR_UPDATES=off` — kein PyPI-Aufruf, kein Banner im Log |
| Unit-Tests im nix-`checkPhase` | OAuth-1.0a-Signatur, `meta`-Auswertung, 401-Fallback, Cache, Kontingent, XML-Parsing, Guards, Aggregationen, Ranking |

### Beim Verifizieren gefundene und behobene Fehler

1. **Client-Header falsch benannt** — `x-bl-client-id` statt `x-bl-tpa-client-id`.
   Die Session wurde trotzdem erstellt, aber jeder Katalog-Download landete auf der
   Anmeldeseite. Sah wie ein abgelaufener Token aus.
2. **`--from-env-file` + `--from-file`** — kubectl lehnt die Kombination ab, die
   Secret-Unit lief in einen Restart-Loop. Jetzt zerlegt der oneshot die dotenv-Datei
   selbst und übergibt ein Verzeichnis.
3. **`order_feedback` war nur im Client implementiert**, nicht als Tool exponiert.
4. **`orders_list` ohne Limit** — 697 KB JSON pro Aufruf, und 876 der 986 Bestellungen
   sind PURGED-Leichen. Jetzt Default-Limit 25, neueste zuerst, PURGED ausgefiltert.
   Dasselbe für `inventory_list` (12.714 Lots ≈ 5 MB), `feedback_list`, `notifications`.
5. **`inventory_stats` griff auf `status` und `currency_code`** zu — die es im
   Inventar-Resource nicht gibt. Jetzt `is_stock_room`/`stock_room_id`/`is_retain`.
6. **Katalog-Refresh scheiterte komplett an einem einzelnen 500er.** Jetzt Retry mit
   10/30/90/300 s, 3 s Pause zwischen den Exporten, und ein Typ, der endgültig
   scheitert, blockiert den Index nicht mehr.
7. **XML-Parser** las den kompletten Baum ein und wäre am 34-MB-Part-Export
   gestorben; außerdem hätte `ET.fromstring` auf einem `str` mit
   Encoding-Deklaration geworfen. Jetzt `iterparse` über Bytes.
8. **Quota-Tabelle wanderte nicht mit** (beim Deploy des Multi-Shop-Stands
   aufgefallen): `quota` bekam die Spalte `store`, aber `CREATE TABLE IF NOT EXISTS`
   migriert eine bestehende Tabelle nicht — und die SQLite-Datei liegt im PVC, also
   überlebt sie jeden Deploy. Ergebnis im laufenden Pod: **jeder** Aufruf, der
   Kontingent buchte, scheiterte mit „no such column: store", während die Exporte
   weiterliefen (die buchen keins). Jetzt migriert `State._migrate` ausdrücklich,
   Altzeilen landen ohne Shop-Zuordnung. Mit Test gegen eine Datei im alten Schema.
9. **nginx-Config: `$uri` ohne Klammern** (beim Dateiserver aufgefallen). In
   `secure_link_md5 "$secure_link_expires$uri<geheimnis>"` klebt das eingesetzte
   Geheimnis am Variablennamen — nginx startet nicht und schreibt
   `unknown "uri<geheimnis>" variable` ins Log. Zwei Konsequenzen: `''${uri}` geklammert,
   **und das Geheimnis war damit im Pod-Log** und wurde deshalb rotiert.
10. **CiliumNetworkPolicy: falsche Entity für das Gateway.** `fromEntities: [host]`
    genügt nicht — der weitergeleitete Verkehr von `cilium-envoy` trägt die reservierte
    Identität `ingress`, obwohl der Pod mit `hostNetwork` läuft. Symptom: Gateway
    antwortete `503 upstream connect error`, während ein curl vom Node selbst auf
    denselben Port 200 lieferte. Jetzt `[ "ingress" "host" ]` (host bleibt für die
    kubelet-Probe).
11. **Suchergebnisse falsch sortiert** — „Brick 4 x 6" vor „Brick 2 x 4", weil
   einstellige Prefix-Terme Item-Nummern treffen und bm25 die falsche Zeile um 0,009
   besser bewertete. Jetzt kein Prefix unter drei Zeichen plus explizite Ränge
   (exakte Nummer → exakter Name → Präfix → Substring → bm25).

12. **Readiness-Probe des Kernels auf `/api/status`** — der Jupyter-Server antwortet
    dort **403**, wenn kein Token mitkommt, und eine Probe schickt keins. Der
    Container galt damit dauerhaft als nicht bereit. Jetzt `tcpSocket` auf 8888.
13. **Die Sandbox-Tokens landeten nicht im OpenWebUI-Secret.** Die Secret-Unit legte
    die zwei Dateien korrekt an, führte sie aber nicht in den `--from-file`-Flags auf.
    OpenWebUI startete ohne Token, der Kernel wies jede Anfrage mit 403 ab. Symptom
    im Chat: „Code-Ausführung fehlgeschlagen", ohne Hinweis auf den Grund.
14. **Der Service `bricklink-mcp` kannte Port 8888 nicht.** Die
    CiliumNetworkPolicy erlaubte den Weg, aber ohne Port im Service gibt es keinen
    Endpoint — OpenWebUI lief in einen Verbindungs-Timeout. Ein Netzwerkfehler, der
    aussieht wie ein hängender Kernel.
15. **Die HTTPRoute traf nur `/bricklink-exports/`.** Die Links aus
    `workspace_link` zeigen aber auf `/bricklink-workspace/`, und dafür griff die
    `/`-Route von open-webui: der Abruf beantwortete **HTTP 200 mit der SPA**.
    Das ist die gemeinste Variante des Fehlers — ein Test, der nur den Statuscode
    prüft, meldet Erfolg, während die Datei nie ausgeliefert wurde. Jetzt hat die
    Route beide Präfixe, und der Test prüft zusätzlich `content-type` und die
    ersten Bytes.

### Was die Doku anders sagt als die Realität

- **`GET /notifications` ist einmalig.** Der Abruf leert die Liste (erst 159 ungelesene,
  direkt danach 0). Wer sie braucht, muss sie in derselben Antwort verarbeiten.

### Nicht geprüft

- **Der schreibende Pfad gegen eine echte Bestellung** (`PUT /orders/{id}/status`,
  `PUT /orders/{id}` mit Sendungsnummer, `POST /feedback`, `drive_thru`). Die Guards,
  die Request-Bodies und die Fehlerbehandlung sind gegen einen Fake-BrickLink
  getestet, der echte Schreibvorgang würde eine Kundenbestellung verändern und wartet
  auf eine ausdrückliche Freigabe.
- Verhalten nach Ablauf des 30-Tage-Web-Tokens (der Code erkennt den Redirect auf
  `auth/sign-in`, ausprobiert wurde das nicht mit einem echt abgelaufenen Token).
- **dinoland gegen die echte API** — dort fehlen noch die Credentials. Geprüft ist
  nur, dass der Shop konfiguriert ist, sauber als „keine Credentials" gemeldet wird
  und ein eigenes Kontingent führt.
- **Der schreibende Pfad** bleibt der einzige ungeprüfte Teil (siehe oben) — bei
  beiden Shops.
