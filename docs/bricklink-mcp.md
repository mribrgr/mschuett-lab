# BrickLink-MCP — Shop-Verwaltung aus dem Chat

**Ziel:** mschuett verwaltet seinen BrickLink-Store über `chat.mauritiusberger.de`
und braucht die BrickLink-Web-UI langfristig nicht mehr.
**Stand:** 2026-08-27 gebaut und gegen den echten Store SteinAberFein verifiziert
(986 Bestellungen, 12.714 Lots, Katalog-Export). Credentials liegen in agenix.
Die Verdrahtung in OpenWebUI ist **deklarativ** (kein UI-Schritt).

- Code: `pkgs/bricklink-mcp/` (Python, FastMCP)
- Deployment: `modules/bricklink-mcp.nix` (nix:0-Image + `services.k3s.manifests`)
- Secrets: `secrets/bricklink-{api,web-token,mcp-bearer}.age`

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

- **Token pro IP — laut Doku.** „After registering static IP addresses of your endpoint
  client, you can then access tokens… BrickLink resources are accessible only from the
  registered location." **Empirisch am 2026-08-27 NICHT durchgesetzt:** dasselbe
  Token-Paar lieferte von einer nicht registrierten Adresse (MacBook im Heimnetz)
  anstandslos alle 986 Bestellungen. Verlassen sollte man sich darauf nicht — BrickLink
  kann die Prüfung jederzeit scharf schalten; registriert ist `152.53.15.24` (netcup,
  aus `nix-config/base/_network.nix`).
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

### 3. Was nur im Web geht (Phase 2, bewusst offen)

Nachrichten **senden**/beantworten, Rechnung senden, NPB/OCR anlegen, Wanted Lists,
Warenkörbe, Store-Traffic-Statistiken, Katalogsuche über die Web-UI.
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

### 1. Store-API-Credentials (einmalig, interaktiv)

1. `api.bricklink.com/pages/clone/api/register_consumer.page` → Consumer-Key + Secret.
2. Dort die **IP `152.53.15.24`** registrieren → Access-Token + Token-Secret.
3. Eintragen (dotenv, fünf Zeilen):

```sh
cd secrets && EDITOR=nano nix run github:ryantm/agenix -- -e bricklink-api.age
# BRICKLINK_CONSUMER_KEY=…
# BRICKLINK_CONSUMER_SECRET=…
# BRICKLINK_TOKEN_VALUE=…
# BRICKLINK_TOKEN_SECRET=…
# BRICKLINK_STORE_USERNAME=<BL-Benutzername von Max>
```

4. In *My Orders Settings* prüfen, ob „order payment status from order status" an ist.

### 2. Web-Token für den Katalog (alle 30 Tage)

```sh
# Token holen: https://bricklink.com/v3/brickstore-access-management.page
cd secrets && EDITOR=nano nix run github:ryantm/agenix -- -e bricklink-web-token.age
```

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

`api_quota` → Budget steht. `orders_dashboard` → offene Bestellungen.
`catalog_refresh` (dauert Minuten) → danach `catalog_search` mit „Brick 2 x 4".

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
8. **Suchergebnisse falsch sortiert** — „Brick 4 x 6" vor „Brick 2 x 4", weil
   einstellige Prefix-Terme Item-Nummern treffen und bm25 die falsche Zeile um 0,009
   besser bewertete. Jetzt kein Prefix unter drei Zeichen plus explizite Ränge
   (exakte Nummer → exakter Name → Präfix → Substring → bm25).

### Zwei Dinge, die die Doku anders sagt als die Realität

- **IP-Bindung des API-Tokens wird nicht durchgesetzt.** Dasselbe Token-Paar lieferte
  von einer nicht registrierten Adresse alle 986 Bestellungen. Nicht darauf verlassen.
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
