"""Session gegen die BrickLink-WEBSEITE (nur für Katalog-Downloads).

Die offizielle Store API hat keinen Bulk-Katalog und keine Textsuche. Den
Weg, den es dafür gibt, geht BrickStore (github.com/rgriebl/brickstore,
src/bricklink/core.cpp und src/bricklink/textimport.cpp):

  1. POST account.prod.member.bricklink.info/api/v1/actions/verify-and-create-session
     mit {"clientId": …, "clientToken": …}  →  {"sessionToken": …}
  2. Alle weiteren Requests an www.bricklink.com mit den Headern
     `x-bl-tpa-client-id` und `x-bl-session-token`.
  3. www.bricklink.com/catalogDownload.asp?a=a&viewType=…&downloadType=X
     liefert den Katalog als XML.

⚠️ Der clientToken ist laut BrickStore-CHANGELOG (2025.9.1) nur **30 Tage**
gültig und wird von Hand im Browser erzeugt. Läuft er ab, antwortet BrickLink
mit einem Redirect auf `auth/sign-in?…` — genau das erkennt `_get` und sagt es
mit klarer Ansage, statt eine HTML-Seite als XML zu parsen.
"""

from __future__ import annotations

import json
import logging
import re
import time
from datetime import date
from typing import Any

import requests

from .config import Config

SESSION_URL = "https://account.prod.member.bricklink.info/api/v1/actions/verify-and-create-session"
WWW = "https://www.bricklink.com/"

# ⚠️ Der Header heißt `x-bl-tpa-client-id` (tpa = third party application), NICHT
# `x-bl-client-id`. Quelle: BrickStore src/utility/transfer.cpp:19
#   static const char * const BL_CLIENT_ID_HEADER = "x-bl-tpa-client-id"

# Wartezeiten zwischen den Versuchen; None = kein weiterer Versuch.
# Lang gewählt, weil BrickLinks 500er auf catalogDownload.asp KEIN Schluckauf von
# Sekunden sind: am 2026-08-27 lieferte derselbe Aufruf über 85 Sekunden hinweg
# durchgehend 500 und wenige Minuten später anstandslos 6 MB XML. Das sieht nach
# einer Abkühlphase nach großen Downloads aus (davor waren 46 MB gezogen worden).
RETRY_DELAYS = (10, 30, 90, 300, None)

log = logging.getLogger("bricklink-mcp.web");
# Mit dem falschen Namen legt BrickLink trotzdem eine Session an (der POST auf
# verify-and-create-session antwortet 200 mit sessionToken!), aber jeder Request an
# www.bricklink.com wird auf `auth/sign-in?…` umgeleitet — das sieht wie ein
# abgelaufener Token aus und ist keiner. Am 2026-08-27 genau so debuggt.
CLIENT_ID_HEADER = "x-bl-tpa-client-id"

# Wartezeiten zwischen den Versuchen; None = kein weiterer Versuch.
RETRY_DELAYS = (5, 20, 60, None)

log = logging.getLogger("bricklink-mcp.web")
SESSION_TOKEN_HEADER = "x-bl-session-token"


class WebSessionError(RuntimeError):
    pass


class TokenExpired(WebSessionError):
    pass


class WebSession:
    """Eine Web-Session = EIN BrickLink-Konto.

    `client_token` entscheidet, wessen Daten die Exporte liefern. Für den Katalog ist
    das egal, für Bestellungen/Inventar/Wanted-Lists NICHT — deshalb bekommt jeder
    Shop seine eigene Session, und `verify_account` prüft vor der Auslieferung, dass
    das Konto zum Shop passt.
    """

    def __init__(
        self,
        cfg: Config,
        client_token: str | None = None,
        context: str = "Katalog",
        secret_hint: str = "bricklink-web-token.age",
    ) -> None:
        self._cfg = cfg
        self._client_token = client_token if client_token is not None else cfg.catalog_web_token
        self._context = context
        self._secret_hint = secret_hint
        self._session = requests.Session()
        self._session.headers.update(
            {
                "User-Agent": cfg.user_agent,
                CLIENT_ID_HEADER: cfg.web_client_id,
            }
        )
        self._token: str | None = None
        self._account: tuple[str, str] | None = None

    @property
    def configured(self) -> bool:
        return bool(self._cfg.web_client_id and self._client_token)

    def login(self, force: bool = False) -> str:
        if self._token and not force:
            return self._token
        if not self.configured:
            raise WebSessionError(
                f"Kein Web-Token für {self._context} hinterlegt. Token auf "
                "https://bricklink.com/v3/brickstore-access-management.page erzeugen "
                f"(30 Tage gültig, mit dem BL-Konto DIESES Shops) und in {self._secret_hint} "
                "als WEB_TOKEN eintragen."
            )
        resp = self._session.post(
            SESSION_URL,
            json={
                "clientId": self._cfg.web_client_id,
                "clientToken": self._client_token,
            },
            timeout=60,
            allow_redirects=False,
        )
        if resp.status_code != 200:
            raise WebSessionError(
                f"Session-Erzeugung scheiterte: HTTP {resp.status_code} {resp.text[:200]}"
            )
        token = (resp.json() or {}).get("sessionToken")
        if not token:
            raise WebSessionError("Antwort enthielt keinen sessionToken")
        self._token = token
        return token

    def get(self, page: str, params: dict[str, str] | None = None, retry: bool = True) -> bytes:
        token = self.login()
        resp = None
        # ⚠️ Serverfehler sind bei den Katalog-Downloads NORMAL, nicht die Ausnahme:
        # am 2026-08-27 antwortete `catalogDownload.asp?viewType=0&itemType=S` mit
        # HTTP 500, und derselbe Aufruf eine Minute später mit 3,8 MB XML. Ohne diesen
        # Retry stirbt der wöchentliche Refresh an einem Schluckauf und der Index
        # veraltet still.
        for attempt, delay in enumerate(RETRY_DELAYS, start=1):
            resp = self._session.get(
                WWW + page,
                params=params or {},
                headers={SESSION_TOKEN_HEADER: token},
                timeout=600,
                allow_redirects=False,
            )
            if resp.status_code < 500:
                break
            if delay is None:
                break
            log.warning(
                "GET %s → HTTP %s (Versuch %s), neuer Versuch in %ss",
                page,
                resp.status_code,
                attempt,
                delay,
            )
            time.sleep(delay)

        if resp.status_code in (301, 302, 303, 307, 308):
            target = resp.headers.get("Location", "")
            if "auth/sign-in" in target:
                if retry:
                    # Erst einmal neu einloggen — die Session kann einfach
                    # abgelaufen sein, ohne dass der clientToken tot ist.
                    self.login(force=True)
                    return self.get(page, params, retry=False)
                raise TokenExpired(
                    f"BrickLink schickt uns auf die Anmeldeseite: der 30-Tage-clientToken "
                    f"für {self._context} ist abgelaufen. Neu erzeugen auf "
                    "https://bricklink.com/v3/brickstore-access-management.page und "
                    f"{self._secret_hint} aktualisieren."
                )
            raise WebSessionError(f"Unerwarteter Redirect auf {target}")
        if resp.status_code != 200:
            raise WebSessionError(f"GET {page} → HTTP {resp.status_code}")
        return resp.content

    def post(self, page: str, data: dict[str, Any] | None = None, retry: bool = True) -> bytes:
        """POST auf www.bricklink.com — die Store-Exporte sind alle POST-Formulare."""
        token = self.login()
        resp = None
        for attempt, delay in enumerate(RETRY_DELAYS, start=1):
            resp = self._session.post(
                WWW + page,
                data=data or {},
                headers={SESSION_TOKEN_HEADER: token},
                timeout=600,
                allow_redirects=False,
            )
            if resp.status_code < 500:
                break
            if delay is None:
                break
            log.warning(
                "POST %s → HTTP %s (Versuch %s), neuer Versuch in %ss",
                page,
                resp.status_code,
                attempt,
                delay,
            )
            time.sleep(delay)

        if resp.status_code in (301, 302, 303, 307, 308):
            target = resp.headers.get("Location", "")
            # BrickLink leitet eine LEERE Ergebnisliste auf "…error=EOF" um. Das ist
            # kein Fehler, sondern „keine Treffer" (so behandelt es BrickStore auch).
            if "error=EOF" in target:
                return b""
            if "auth/sign-in" in target:
                if retry:
                    self.login(force=True)
                    return self.post(page, data, retry=False)
                raise TokenExpired(
                    f"BrickLink schickt uns auf die Anmeldeseite: der 30-Tage-clientToken "
                    f"für {self._context} ist abgelaufen. Neu erzeugen auf "
                    "https://bricklink.com/v3/brickstore-access-management.page und "
                    f"{self._secret_hint} aktualisieren."
                )
            raise WebSessionError(f"Unerwarteter Redirect auf {target}")
        if resp.status_code != 200:
            raise WebSessionError(f"POST {page} → HTTP {resp.status_code}")
        return resp.content

    # ── Kontoprüfung ───────────────────────────────────────────────────────

    def account(self) -> tuple[str, str]:
        """(BL-Benutzername, userID) des Kontos, dem dieses Token gehört.

        Quelle ist die Wanted-List-Seite: sie enthält `var username = '…'` und
        `var userID = '…'`. Das ist die einzige gefundene Stelle, an der eine
        Web-Seite das Konto maschinenlesbar nennt — und der Anker dafür, dass ein
        Export nicht aus dem falschen Shop kommt.
        """
        if self._account:
            return self._account
        body = self.post("v2/wanted/list.page").decode("utf-8", errors="replace")
        name = re.search(r"var\s+username\s*=\s*'([^']*)'", body)
        uid = re.search(r"var\s+userID\s*=\s*'([^']*)'", body)
        if not name:
            raise WebSessionError(
                "Konto konnte nicht bestimmt werden — BrickLink hat das Seitenformat "
                "geändert. Store-Exporte werden deshalb NICHT ausgeliefert."
            )
        self._account = (name.group(1), uid.group(1) if uid else "")
        self._wanted_page = body
        return self._account

    def verify_account(self, expected_username: str) -> None:
        """Schranke gegen Shop-Verwechslung auf Export-Ebene.

        Ein Web-Token gehört zu einem KONTO. Passt der Kontoname nicht zum
        Benutzernamen des angefragten Shops, kämen die Daten aus dem falschen Shop —
        dann lieber abbrechen als falsche Zahlen ausliefern.
        """
        if not expected_username:
            return
        actual, _uid = self.account()
        if actual.casefold() != expected_username.casefold():
            raise WebSessionError(
                f"Das Web-Token für {self._context} gehört dem BrickLink-Konto "
                f"{actual!r}, erwartet war {expected_username!r}. Der Export käme aus "
                "dem FALSCHEN Shop — abgebrochen. Bitte das Token dieses Shops in "
                f"{self._secret_hint} korrigieren."
            )

    # ── Store-Exporte (kosten KEIN API-Kontingent) ─────────────────────────

    def orders_xml(
        self,
        direction: str = "received",
        from_date: date | None = None,
        to_date: date | None = None,
        order_id: str | None = None,
    ) -> bytes:
        """Bestellungen samt Positionen als XML (`orderExcelFinal.asp`).

        Ein Aufruf liefert ALLE Bestellungen des Zeitraums MIT allen Positionen — über
        die API wären das 1 + n Requests (einer pro Bestellung). Parameter wie in
        BrickStore (`order.cpp`), `viewType=X` ist das XML-Format; TAB-getrennt gibt es
        hier nicht (viewType=T liefert 0 Bytes, am 2026-08-27 geprüft).
        """
        query: dict[str, Any] = {
            "action": "save",
            "orderType": "received" if direction in ("in", "received") else "placed",
            "viewType": "X",
            "getStatusSel": "I",
            "getFiled": "Y",
            "getDetail": "y",
            "getDateFormat": "0",  # MM/DD/YY
            "includeMyCost": "Y",
        }
        if order_id:
            query["orderID"] = order_id
        elif from_date and to_date:
            query.update(
                {
                    "getOrders": "date",
                    "fMM": from_date.month,
                    "fDD": from_date.day,
                    "fYY": from_date.year,
                    "tMM": to_date.month,
                    "tDD": to_date.day,
                    "tYY": to_date.year,
                }
            )
        return self.post("orderExcelFinal.asp", query)

    def inventory_xml(self) -> bytes:
        """Komplettes Store-Inventar als XML (`invExcelFinal.asp`).

        Enthält Felder, die die API NICHT hat: DATELASTSOLD, INVDIMX/Y/Z, SUBCONDITION,
        EXTENDED. Nur XML — viewType=t/T liefert ebenfalls XML (2026-08-27 geprüft).
        """
        return self.post(
            "invExcelFinal.asp",
            {
                "itemType": "",
                "catID": "",
                "colorID": "",
                "invNew": "",
                "itemYear": "",
                "viewType": "x",
                "invStock": "Y",
                "invStockOnly": "",
                "invQty": "",
                "invQtyMin": "0",
                "invQtyMax": "0",
                "invBrikTrak": "",
                "invDesc": "",
            },
        )

    def wanted_lists(self) -> list[dict[str, Any]]:
        """Wanted Lists mit Füllstand. Die Store API hat dafür GAR KEINEN Endpunkt.

        Die Seite ist HTML mit einem eingebetteten `var wlJson = {…};`.
        """
        self.account()  # füllt _wanted_page
        body = getattr(self, "_wanted_page", "")
        m = re.search(r"var\s+wlJson\s*=\s*(\{.*?\});", body, re.S)
        if not m:
            raise WebSessionError(
                "Wanted-Lists nicht gefunden — BrickLink hat das Seitenformat geändert."
            )
        try:
            data = json.loads(m.group(1))
        except ValueError as exc:
            raise WebSessionError(f"Wanted-List-JSON nicht lesbar: {exc}") from exc
        return data.get("wantedLists") or []

    def wanted_xml(self, wanted_list_id: int) -> bytes:
        """Eine Wanted List als XML (`files/clone/wanted/downloadXML.file`)."""
        return self.post(
            "files/clone/wanted/downloadXML.file", {"wantedMoreID": str(wanted_list_id)}
        )

    # ── Katalog-Downloads ──────────────────────────────────────────────────
    # viewType laut BrickStore (textimport.cpp): 1 = Item-Typen,
    # 2 = Kategorien, 3 = Farben, 5 = Part-Color-Codes, 0 = Items eines Typs.
    def catalog_view(self, view_type: int) -> bytes:
        return self.get(
            "catalogDownload.asp",
            {"a": "a", "viewType": str(view_type), "downloadType": "X"},
        )

    def catalog_items(self, item_type_id: str, download_type: str = "X") -> bytes:
        """Items eines Typs. download_type "X" = XML, "T" = TAB-getrennt (CSV-artig)."""
        return self.get(
            "catalogDownload.asp",
            {
                "a": "a",
                "viewType": "0",
                "itemType": item_type_id,
                "downloadType": download_type,
                # Diese drei Flags schaltet BrickLink für BrickStore frei
                # ("special BrickStore flag to get default color - thanks Dan",
                # textimport.cpp): Standardfarbe, Gewicht und Jahr im Export.
                "selItemColor": "Y",
                "selWeight": "Y",
                "selYear": "Y",
            },
        )
