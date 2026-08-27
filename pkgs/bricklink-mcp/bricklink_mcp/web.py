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

import logging
import time

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
    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._session = requests.Session()
        self._session.headers.update(
            {
                "User-Agent": cfg.user_agent,
                CLIENT_ID_HEADER: cfg.web_client_id,
            }
        )
        self._token: str | None = None

    def login(self, force: bool = False) -> str:
        if self._token and not force:
            return self._token
        if not self._cfg.has_web_session:
            raise WebSessionError(
                "Kein BRICKLINK_WEB_CLIENT_TOKEN gesetzt. Token auf "
                "https://bricklink.com/v3/brickstore-access-management.page erzeugen "
                "(30 Tage gültig) und als agenix-Secret hinterlegen."
            )
        resp = self._session.post(
            SESSION_URL,
            json={
                "clientId": self._cfg.web_client_id,
                "clientToken": self._cfg.web_client_token,
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
                    "BrickLink schickt uns auf die Anmeldeseite: der 30-Tage-clientToken "
                    "ist abgelaufen. Neu erzeugen auf "
                    "https://bricklink.com/v3/brickstore-access-management.page und das "
                    "agenix-Secret bricklink-web-token.age aktualisieren."
                )
            raise WebSessionError(f"Unerwarteter Redirect auf {target}")
        if resp.status_code != 200:
            raise WebSessionError(f"GET {page} → HTTP {resp.status_code}")
        return resp.content

    # ── Katalog-Downloads ──────────────────────────────────────────────────
    # viewType laut BrickStore (textimport.cpp): 1 = Item-Typen,
    # 2 = Kategorien, 3 = Farben, 5 = Part-Color-Codes, 0 = Items eines Typs.
    def catalog_view(self, view_type: int) -> bytes:
        return self.get(
            "catalogDownload.asp",
            {"a": "a", "viewType": str(view_type), "downloadType": "X"},
        )

    def catalog_items(self, item_type_id: str) -> bytes:
        return self.get(
            "catalogDownload.asp",
            {
                "a": "a",
                "viewType": "0",
                "itemType": item_type_id,
                "downloadType": "X",
                # Diese drei Flags schaltet BrickLink für BrickStore frei
                # ("special BrickStore flag to get default color - thanks Dan",
                # textimport.cpp): Standardfarbe, Gewicht und Jahr im Export.
                "selItemColor": "Y",
                "selWeight": "Y",
                "selYear": "Y",
            },
        )
