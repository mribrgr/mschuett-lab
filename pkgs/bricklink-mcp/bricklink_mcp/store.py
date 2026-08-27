"""Client für die offizielle BrickLink Store API v1.

Basis: https://api.bricklink.com/api/store/v1, OAuth 1.0a (HMAC-SHA1).
Jede Antwort ist `{"meta": {"code", "message", "description"}, "data": …}`;
`code != 200` wird zur Exception mit BrickLinks eigenem Text.

Alle Endpunkte sind aus der offiziellen Doku verifiziert (der Doku-Text steckt
im React-Bundle static2.bricklink.com/_build/js/Api.build.js, die HTML-Seite
selbst ist leer).
"""

from __future__ import annotations

import os
import urllib.parse
from typing import Any

import requests
from requests_oauthlib import OAuth1

from .config import Config
from .state import State

# Überschreibbar ausschließlich für Tests (tests/test_bricklink_mcp.py fährt einen
# Fake-BrickLink auf localhost). Im Betrieb nie setzen.
BASE = os.environ.get("BRICKLINK_API_BASE", "https://api.bricklink.com/api/store/v1")

# TTLs in Sekunden. Katalogdaten sind praktisch statisch, Preise volatil,
# Bestell-/Nachrichtendaten überhaupt nicht cachebar.
TTL_CATALOG = 30 * 24 * 3600
TTL_PRICE = 12 * 3600
TTL_NONE = 0


class BrickLinkError(RuntimeError):
    pass


class StoreApi:
    def __init__(self, cfg: Config, state: State) -> None:
        self._cfg = cfg
        self._state = state
        self._session = requests.Session()
        self._session.headers["User-Agent"] = cfg.user_agent
        self._signature_type = "AUTH_HEADER"

    # ── Transport ──────────────────────────────────────────────────────────
    def _auth(self) -> OAuth1:
        return OAuth1(
            self._cfg.consumer_key,
            client_secret=self._cfg.consumer_secret,
            resource_owner_key=self._cfg.token_value,
            resource_owner_secret=self._cfg.token_secret,
            signature_type=self._signature_type,
        )

    def _call(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        json_body: Any | None = None,
    ) -> Any:
        if not self._cfg.has_store_api:
            raise BrickLinkError(
                "Keine Store-API-Credentials gesetzt (BRICKLINK_CONSUMER_KEY/…). "
                "Consumer-Key auf api.bricklink.com/pages/clone/api/register_consumer.page "
                "anlegen und das Token für die Server-IP registrieren."
            )
        params = {k: v for k, v in (params or {}).items() if v is not None}
        url = BASE + path
        self._state.spend()
        resp = self._session.request(
            method, url, params=params, json=json_body, auth=self._auth(), timeout=60
        )
        # BrickLink antwortet auf falsch platzierte OAuth-Parameter mit 401.
        # Einige Deployments akzeptieren nur die Signatur in der Query — dann
        # einmalig umschalten statt am Auth-Header zu verzweifeln.
        if resp.status_code == 401 and self._signature_type == "AUTH_HEADER":
            self._signature_type = "QUERY"
            self._state.spend()
            resp = self._session.request(
                method, url, params=params, json=json_body, auth=self._auth(), timeout=60
            )

        try:
            payload = resp.json()
        except ValueError as exc:
            raise BrickLinkError(
                f"{method} {path} → HTTP {resp.status_code}, keine JSON-Antwort: "
                f"{resp.text[:300]}"
            ) from exc

        meta = payload.get("meta") or {}
        code = meta.get("code")
        if code != 200:
            raise BrickLinkError(
                f"{method} {path} → BrickLink {code} {meta.get('description')}: "
                f"{meta.get('message')}"
            )
        return payload.get("data")

    def _get(self, path: str, params: dict[str, Any] | None = None, ttl: int = TTL_NONE) -> Any:
        key = ""
        if ttl > 0:
            query = urllib.parse.urlencode(sorted((params or {}).items()))
            key = f"GET {path}?{query}"
            hit = self._state.cached(key, ttl)
            if hit is not None:
                return hit
        data = self._call("GET", path, params=params)
        if ttl > 0:
            self._state.store(key, data)
        return data

    # ── Bestellungen ───────────────────────────────────────────────────────
    def orders(
        self,
        direction: str = "in",
        status: str | None = None,
        filed: bool | None = None,
    ) -> list[dict]:
        params: dict[str, Any] = {"direction": direction}
        if status:
            params["status"] = status
        if filed is not None:
            params["filed"] = "true" if filed else "false"
        return self._get("/orders", params) or []

    def order(self, order_id: int) -> dict:
        return self._get(f"/orders/{order_id}")

    def order_items(self, order_id: int) -> list[list[dict]]:
        # BrickLink liefert eine Liste von Batches (ein Batch = ein Lot-Block).
        return self._get(f"/orders/{order_id}/items") or []

    def order_messages(self, order_id: int) -> list[dict]:
        return self._get(f"/orders/{order_id}/messages") or []

    def order_feedback(self, order_id: int) -> list[dict]:
        return self._get(f"/orders/{order_id}/feedback") or []

    def update_order(self, order_id: int, body: dict) -> dict:
        return self._call("PUT", f"/orders/{order_id}", json_body=body)

    def update_order_status(self, order_id: int, value: str) -> Any:
        return self._call(
            "PUT", f"/orders/{order_id}/status", json_body={"field": "status", "value": value}
        )

    def drive_thru(self, order_id: int, mail_me: bool = False) -> Any:
        return self._call(
            "POST",
            f"/orders/{order_id}/drive_thru",
            params={"mail_me": "true" if mail_me else "false"},
        )

    # ── Feedback / Bewertungen ─────────────────────────────────────────────
    def feedback_list(self, direction: str = "in") -> list[dict]:
        return self._get("/feedback", {"direction": direction}) or []

    def feedback(self, feedback_id: int) -> dict:
        return self._get(f"/feedback/{feedback_id}")

    def post_feedback(self, order_id: int, rating: int, comment: str) -> dict:
        return self._call(
            "POST",
            "/feedback",
            json_body={"order_id": order_id, "rating": rating, "comment": comment},
        )

    def reply_feedback(self, feedback_id: int, reply: str) -> dict:
        return self._call("POST", f"/feedback/{feedback_id}/reply", json_body={"reply": reply})

    def member_ratings(self, username: str) -> dict:
        return self._get(f"/members/{urllib.parse.quote(username)}/ratings", ttl=3600)

    # ── Inventar ───────────────────────────────────────────────────────────
    def inventories(
        self,
        item_type: str | None = None,
        status: str | None = None,
        category_id: int | None = None,
        color_id: int | None = None,
    ) -> list[dict]:
        return (
            self._get(
                "/inventories",
                {
                    "item_type": item_type,
                    "status": status,
                    "category_id": category_id,
                    "color_id": color_id,
                },
            )
            or []
        )

    def inventory(self, inventory_id: int) -> dict:
        return self._get(f"/inventories/{inventory_id}")

    # ── Katalog ────────────────────────────────────────────────────────────
    def item(self, item_type: str, item_no: str) -> dict:
        return self._get(f"/items/{item_type}/{urllib.parse.quote(item_no)}", ttl=TTL_CATALOG)

    def subsets(
        self, item_type: str, item_no: str, break_minifigs: bool = False, instruction: bool = False
    ) -> list[dict]:
        return (
            self._get(
                f"/items/{item_type}/{urllib.parse.quote(item_no)}/subsets",
                {
                    "break_minifigs": "true" if break_minifigs else "false",
                    "instruction": "true" if instruction else "false",
                },
                ttl=TTL_CATALOG,
            )
            or []
        )

    def supersets(self, item_type: str, item_no: str, color_id: int | None = None) -> list[dict]:
        return (
            self._get(
                f"/items/{item_type}/{urllib.parse.quote(item_no)}/supersets",
                {"color_id": color_id},
                ttl=TTL_CATALOG,
            )
            or []
        )

    def price_guide(
        self,
        item_type: str,
        item_no: str,
        color_id: int | None = None,
        guide_type: str = "stock",
        new_or_used: str = "N",
        country_code: str | None = None,
        region: str | None = None,
        currency_code: str | None = None,
        vat: str | None = None,
    ) -> dict:
        return self._get(
            f"/items/{item_type}/{urllib.parse.quote(item_no)}/price",
            {
                "color_id": color_id,
                "guide_type": guide_type,
                "new_or_used": new_or_used,
                "country_code": country_code,
                "region": region,
                "currency_code": currency_code,
                "vat": vat,
            },
            ttl=TTL_PRICE,
        )

    def known_colors(self, item_type: str, item_no: str) -> list[dict]:
        return (
            self._get(
                f"/items/{item_type}/{urllib.parse.quote(item_no)}/colors", ttl=TTL_CATALOG
            )
            or []
        )

    def item_mapping_from_no(
        self, item_type: str, item_no: str, color_id: int | None = None
    ) -> list[dict]:
        return (
            self._get(
                f"/item_mapping/{item_type}/{urllib.parse.quote(item_no)}",
                {"color_id": color_id},
                ttl=TTL_CATALOG,
            )
            or []
        )

    def item_mapping_from_element(self, element_id: str) -> list[dict]:
        return self._get(f"/item_mapping/{urllib.parse.quote(element_id)}", ttl=TTL_CATALOG) or []

    # ── Sonstiges ──────────────────────────────────────────────────────────
    def notifications(self) -> list[dict]:
        return self._get("/notifications") or []

    def shipping_methods(self) -> list[dict]:
        return self._get("/settings/shipping_methods", ttl=3600) or []
