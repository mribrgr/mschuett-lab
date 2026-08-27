"""MCP-Server für den BrickLink-Store.

Transport: Streamable HTTP — Open WebUI (ab 0.6.31, hier 0.11.0) spricht
NATIVES MCP ausschließlich darüber. Kein stdio, kein SSE.

Aufteilung der Datenquellen:
  * Store API v1 (OAuth 1.0a, eigener Consumer-Key): Bestellungen, Nachrichten,
    Feedback, Inventar, Katalog-Einzelabfragen, Preis-Guide, Benachrichtigungen.
  * Offline-Katalogindex (aus dem offiziellen Katalog-Export): Textsuche, die
    die API nicht anbietet.
  * Web-UI: bleibt für alles, was die API nicht kann (Nachrichten SENDEN,
    Rechnung senden, Wanted Lists, Store-Statistiken) — siehe README.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

from .catalog import Catalog
from .config import Config
from .guards import NotAllowed, check_transition
from .state import Quota, State
from .store import BrickLinkError, StoreApi
from .web import WebSession, WebSessionError

log = logging.getLogger("bricklink-mcp")

cfg = Config.from_env()
state = State(os.path.join(cfg.data_dir, "state.db"), cfg.daily_budget)
api = StoreApi(cfg, state)
catalog = Catalog(os.path.join(cfg.data_dir, "catalog.db"))
web = WebSession(cfg)

auth = None
if cfg.bearer_token:
    # Statischer Bearer-Token. Zweite Schranke hinter der CiliumNetworkPolicy,
    # die den Port ohnehin nur für den open-webui-Pod öffnet.
    from fastmcp.server.auth import StaticTokenVerifier

    auth = StaticTokenVerifier(
        {cfg.bearer_token: {"client_id": "open-webui", "scopes": ["bricklink"]}}
    )

mcp = FastMCP(
    name="bricklink",
    instructions=(
        "Verwaltung des eigenen BrickLink-Stores. Lesen: Bestellungen (erhalten und "
        "selbst getätigt), Bestellpositionen, Nachrichten zu Bestellungen, Feedback, "
        "Bewertungsbilanz, Inventar, Katalog und Preis-Guide. Schreiben: NUR "
        "order_mark_packed und order_mark_shipped (optional mit Sendungsnummer), "
        "Feedback abgeben/beantworten und die Versandmail 'Thank You, Drive Thru'. "
        "Jeder BrickLink-Aufruf zählt gegen ein Tagesbudget — api_quota zeigt den Stand. "
        "Für Teilesuche nach Namen catalog_search benutzen (offline, kostet kein Budget)."
    ),
    auth=auth,
)


def _wrap(fn, *args, **kwargs):
    """Fehler aus den Clients in ToolError übersetzen (Modell soll den Text sehen)."""
    try:
        return fn(*args, **kwargs)
    except (BrickLinkError, WebSessionError, NotAllowed, Quota, RuntimeError) as exc:
        raise ToolError(str(exc)) from exc


# ── Bestellungen: lesen ────────────────────────────────────────────────────


@mcp.tool
def orders_list(
    direction: str = "in",
    status: str | None = None,
    filed: bool | None = None,
    since_days: int | None = None,
    limit: int = 25,
    include_purged: bool = False,
) -> dict[str, Any]:
    """Listet Bestellungen, neueste zuerst.

    direction: "in" = bei mir eingegangene Verkäufe, "out" = meine Einkäufe.
    status: BrickLink-Statusfilter, kommasepariert, "-" schließt aus
        (z.B. "pending,paid" oder "-purged").
    filed: True = nur abgelegte, False = nur nicht abgelegte Bestellungen.
    since_days: filtert nachträglich auf date_ordered der letzten n Tage
        (die API selbst kann nicht nach Datum filtern).
    limit: wie viele Bestellungen zurückkommen (Default 25). `count` nennt immer
        die Gesamtzahl der Treffer, `returned` die Zahl der ausgelieferten.
    include_purged: BrickLink löscht die Details alter Bestellungen und setzt sie auf
        PURGED. Ohne diesen Schalter werden sie ausgeblendet — sonst besteht die
        Antwort fast nur aus leeren Altlasten (im Store SteinAberFein am 2026-08-27:
        986 Bestellungen insgesamt, davon 876 PURGED).
    """
    if status is None and not include_purged:
        status = "-purged"
    orders = _wrap(api.orders, direction=direction, status=status, filed=filed)
    if since_days:
        cutoff = datetime.now(timezone.utc) - timedelta(days=since_days)
        orders = [o for o in orders if _parse_ts(o.get("date_ordered")) >= cutoff]
    orders.sort(key=lambda o: o.get("date_ordered") or "", reverse=True)
    limit = max(1, min(limit, 500))
    return {
        "count": len(orders),
        "returned": min(len(orders), limit),
        "status_filter": status,
        "orders": orders[:limit],
    }


@mcp.tool
def order_get(order_id: int) -> dict[str, Any]:
    """Volles Bestelldetail inklusive Lieferadresse, Kosten, Zahlungs- und Versandinfos."""
    return _wrap(api.order, order_id)


@mcp.tool
def order_items(order_id: int) -> dict[str, Any]:
    """Positionen einer Bestellung. BrickLink gruppiert sie in Batches (ein Batch pro Lot-Block)."""
    batches = _wrap(api.order_items, order_id)
    flat = [item for batch in batches for item in batch]
    return {"batches": len(batches), "lots": len(flat), "items": flat}


@mcp.tool
def order_messages(order_id: int) -> dict[str, Any]:
    """Nachrichten zu einer Bestellung.

    Achtung, Grenze der API: sie liefert nur Nachrichten, die ich als VERKÄUFER
    EMPFANGEN habe. Nachrichten senden geht über die API nicht — dafür (noch) die
    Web-UI.
    """
    msgs = _wrap(api.order_messages, order_id)
    return {"count": len(msgs), "messages": msgs}


@mcp.tool
def order_feedback(order_id: int) -> dict[str, Any]:
    """Bewertungen zu EINER Bestellung — beide Richtungen, also auch die, die ich
    selbst abgegeben habe. Nützlich vor `feedback_post`, um nicht doppelt zu bewerten.
    """
    fb = _wrap(api.order_feedback, order_id)
    return {"count": len(fb), "feedback": fb}


@mcp.tool
def orders_dashboard(direction: str = "in") -> dict[str, Any]:
    """Überblick: offene Bestellungen nach Status, Umsatz der letzten 30 Tage, Handlungsbedarf.

    Kostet genau einen API-Request. Guter Startpunkt für "was ist zu tun?".
    """
    orders = _wrap(api.orders, direction=direction, status="-purged")
    by_status: dict[str, int] = {}
    now = datetime.now(timezone.utc)
    revenue_30d = 0.0
    currency = None
    to_pack: list[dict[str, Any]] = []
    to_ship: list[dict[str, Any]] = []
    for o in orders:
        st = (o.get("status") or "?").upper()
        by_status[st] = by_status.get(st, 0) + 1
        ordered = _parse_ts(o.get("date_ordered"))
        if ordered >= now - timedelta(days=30):
            try:
                revenue_30d += float((o.get("cost") or {}).get("grand_total") or 0)
                currency = (o.get("cost") or {}).get("currency_code") or currency
            except (TypeError, ValueError):
                pass
        entry = {
            "order_id": o.get("order_id"),
            "buyer": o.get("buyer_name"),
            "status": st,
            "date_ordered": o.get("date_ordered"),
            "days_open": round((now - ordered).total_seconds() / 86400, 1),
            "total": (o.get("cost") or {}).get("grand_total"),
            "items": o.get("total_count"),
        }
        if st in {"PAID", "READY", "PROCESSING", "UPDATED", "PENDING"}:
            to_pack.append(entry)
        elif st == "PACKED":
            to_ship.append(entry)
    to_pack.sort(key=lambda e: e["days_open"], reverse=True)
    to_ship.sort(key=lambda e: e["days_open"], reverse=True)
    return {
        "direction": direction,
        "orders_total": len(orders),
        "by_status": dict(sorted(by_status.items())),
        "revenue_last_30_days": round(revenue_30d, 2),
        "currency": currency,
        "waiting_to_be_packed": to_pack,
        "packed_waiting_for_shipment": to_ship,
    }


def _parse_ts(value: str | None) -> datetime:
    if not value:
        return datetime.fromtimestamp(0, tz=timezone.utc)
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return datetime.fromtimestamp(0, tz=timezone.utc)


# ── Bestellungen: die zwei erlaubten Statuswechsel ─────────────────────────


@mcp.tool
def order_mark_packed(order_id: int) -> dict[str, Any]:
    """Setzt eine Bestellung auf PACKED (gepackt, noch nicht verschickt).

    Erlaubt nur aus PENDING, UPDATED, PROCESSING, READY oder PAID und nur für
    eigene Verkäufe. Andere Statuswechsel sind über diesen MCP nicht möglich.
    """
    order = _wrap(api.order, order_id)
    _wrap(check_transition, order, "PACKED", cfg.store_username)
    _wrap(api.update_order_status, order_id, "PACKED")
    after = _wrap(api.order, order_id)
    return {
        "order_id": order_id,
        "status_before": order.get("status"),
        "status_after": after.get("status"),
        "payment_status": (after.get("payment") or {}).get("status"),
    }


@mcp.tool
def order_mark_shipped(
    order_id: int,
    tracking_no: str | None = None,
    date_shipped: str | None = None,
    send_drive_thru: bool = False,
) -> dict[str, Any]:
    """Setzt eine Bestellung von PACKED auf SHIPPED.

    tracking_no: Sendungsnummer, wird vor dem Statuswechsel gesetzt (für den Käufer sichtbar).
    date_shipped: ISO-Zeitstempel; ohne Angabe wird JETZT eingetragen. Dieses Feld ist
        laut BrickLink API-only und auf den Webseiten nicht zu sehen.
    send_drive_thru: True verschickt zusätzlich BrickLinks "Thank You, Drive Thru!"-Mail
        an den Käufer.
    """
    order = _wrap(api.order, order_id)
    _wrap(check_transition, order, "SHIPPED", cfg.store_username)

    shipping: dict[str, Any] = {
        "date_shipped": date_shipped or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    }
    if tracking_no:
        shipping["tracking_no"] = tracking_no
    _wrap(api.update_order, order_id, {"shipping": shipping})
    _wrap(api.update_order_status, order_id, "SHIPPED")

    drive_thru = None
    if send_drive_thru:
        drive_thru = _wrap(api.drive_thru, order_id, False)

    after = _wrap(api.order, order_id)
    return {
        "order_id": order_id,
        "status_before": order.get("status"),
        "status_after": after.get("status"),
        "tracking_no": (after.get("shipping") or {}).get("tracking_no"),
        "date_shipped": (after.get("shipping") or {}).get("date_shipped"),
        "drive_thru_sent": after.get("drive_thru_sent") if drive_thru is not None else None,
    }


@mcp.tool
def order_set_tracking(order_id: int, tracking_no: str) -> dict[str, Any]:
    """Trägt nur die Sendungsnummer nach, ohne den Status anzufassen."""
    order = _wrap(api.order, order_id)
    if cfg.store_username and (order.get("seller_name") or "").casefold() != (
        cfg.store_username.casefold()
    ):
        raise ToolError(
            f"Bestellung {order_id} ist kein eigener Verkauf (seller_name="
            f"{order.get('seller_name')!r})."
        )
    _wrap(api.update_order, order_id, {"shipping": {"tracking_no": tracking_no}})
    after = _wrap(api.order, order_id)
    return {"order_id": order_id, "tracking_no": (after.get("shipping") or {}).get("tracking_no")}


@mcp.tool
def order_send_drive_thru(order_id: int, mail_me: bool = False) -> dict[str, Any]:
    """Verschickt BrickLinks "Thank You, Drive Thru!"-Versandmail an den Käufer.

    mail_me: True schickt eine Kopie an das eigene Postfach.
    """
    _wrap(api.drive_thru, order_id, mail_me)
    return {"order_id": order_id, "drive_thru_sent": True}


# ── Feedback / Bewertungen ────────────────────────────────────────────────


@mcp.tool
def feedback_list(direction: str = "in", limit: int = 25) -> dict[str, Any]:
    """Bewertungen, neueste zuerst. direction "in" = erhaltene, "out" = selbst abgegebene.

    limit begrenzt nur die Ausgabe; `count` bleibt die Gesamtzahl und `summary` zählt
    die Ratings über ALLE Einträge (0 = Lob, 1 = Neutral, 2 = Beschwerde).
    """
    fb = _wrap(api.feedback_list, direction)
    summary: dict[str, int] = {}
    for entry in fb:
        key = {0: "praise", 1: "neutral", 2: "complaint"}.get(entry.get("rating"), "unknown")
        summary[key] = summary.get(key, 0) + 1
    fb.sort(key=lambda e: e.get("date_rated") or "", reverse=True)
    limit = max(1, min(limit, 500))
    return {
        "count": len(fb),
        "returned": min(len(fb), limit),
        "summary": summary,
        "feedback": fb[:limit],
    }


@mcp.tool
def feedback_get(feedback_id: int) -> dict[str, Any]:
    """Eine einzelne Bewertung."""
    return _wrap(api.feedback, feedback_id)


@mcp.tool
def feedback_post(order_id: int, rating: str, comment: str) -> dict[str, Any]:
    """Gibt eine Bewertung zu einer Bestellung ab.

    rating: "praise", "neutral" oder "complaint" (BrickLink-intern 0/1/2).
    Eine abgegebene Bewertung lässt sich über die API NICHT mehr ändern.
    """
    mapping = {"praise": 0, "neutral": 1, "complaint": 2}
    key = rating.strip().lower()
    if key not in mapping:
        raise ToolError('rating muss "praise", "neutral" oder "complaint" sein.')
    if not comment.strip():
        raise ToolError("comment darf nicht leer sein.")
    return _wrap(api.post_feedback, order_id, mapping[key], comment.strip())


@mcp.tool
def feedback_reply(feedback_id: int, reply: str) -> dict[str, Any]:
    """Antwortet auf eine erhaltene Bewertung (einmalig, nicht änderbar)."""
    if not reply.strip():
        raise ToolError("reply darf nicht leer sein.")
    return _wrap(api.reply_feedback, feedback_id, reply.strip())


@mcp.tool
def member_ratings(username: str | None = None) -> dict[str, Any]:
    """Bewertungsbilanz (Lob/Neutral/Beschwerde, getrennt als Käufer und Verkäufer).

    Ohne username: der eigene Store. Funktioniert auch für fremde Mitglieder —
    nützlich, um einen Käufer vor dem Versand einzuschätzen.
    """
    user = username or cfg.store_username
    if not user:
        raise ToolError("Kein username angegeben und BRICKLINK_STORE_USERNAME ist nicht gesetzt.")
    return {"username": user, "ratings": _wrap(api.member_ratings, user)}


# ── Inventar ───────────────────────────────────────────────────────────────


@mcp.tool
def inventory_list(
    item_type: str | None = None,
    status: str | None = None,
    category_id: int | None = None,
    color_id: int | None = None,
    limit: int = 50,
) -> dict[str, Any]:
    """Lots im eigenen Store-Inventar.

    status: "Y" verfügbar, "S" im Stockroom, "B"/"C" Stockroom B/C, "N" reserviert,
        "R" reserviert für einen Käufer; "-" schließt aus (z.B. "-R").
    limit: kappt die zurückgegebene Liste (die API liefert immer ALLES — im Store
        SteinAberFein sind das 12.714 Lots, also rund 5 MB JSON). `count` nennt die
        Gesamtzahl der Treffer; Summen über alles gibt `inventory_stats`.
    """
    lots = _wrap(
        api.inventories,
        item_type=item_type,
        status=status,
        category_id=category_id,
        color_id=color_id,
    )
    limit = max(1, min(limit, 500))
    return {"count": len(lots), "returned": min(len(lots), limit), "lots": lots[:limit]}


@mcp.tool
def inventory_get(inventory_id: int) -> dict[str, Any]:
    """Ein einzelnes Lot im Inventar."""
    return _wrap(api.inventory, inventory_id)


@mcp.tool
def inventory_stats() -> dict[str, Any]:
    """Kennzahlen über das gesamte Inventar: Lots, Stückzahl, Listenwert, Einkaufswert.

    Ein API-Request. `list_value` ist Menge × eigener Preis (die eigene
    Preisvorstellung, kein Marktwert), `cost_value` die Summe aus `my_cost`, soweit
    hinterlegt. Beträge in der Währung des Stores — die API gibt beim Inventar keine
    Währung mit.

    Aufteilung nach Lager: `for_sale` (im Shop sichtbar), `stockroom_<id>` (Stockroom
    A/B/C, nicht im Shop) und `retain` (Lot bleibt nach Verkauf erhalten).
    """
    lots = _wrap(api.inventories)
    total_qty = 0
    value = 0.0
    cost = 0.0
    by_type: dict[str, dict[str, Any]] = {}
    by_location: dict[str, dict[str, Any]] = {}
    by_condition: dict[str, int] = {}
    for lot in lots:
        item = lot.get("item") or {}
        itype = item.get("type") or "?"
        qty = int(lot.get("quantity") or 0)
        price = _as_float(lot.get("unit_price"))
        total_qty += qty
        value += qty * price
        cost += qty * _as_float(lot.get("my_cost"))

        bucket = by_type.setdefault(itype, {"lots": 0, "quantity": 0, "list_value": 0.0})
        bucket["lots"] += 1
        bucket["quantity"] += qty
        bucket["list_value"] = round(bucket["list_value"] + qty * price, 2)

        # Das Inventar-Resource hat KEIN status-Feld (anders als der Filter in
        # inventory_list): es kennt is_stock_room + stock_room_id und is_retain.
        if lot.get("is_stock_room"):
            where = f"stockroom_{lot.get('stock_room_id') or '?'}"
        elif lot.get("is_retain"):
            where = "retain"
        else:
            where = "for_sale"
        loc = by_location.setdefault(where, {"lots": 0, "quantity": 0, "list_value": 0.0})
        loc["lots"] += 1
        loc["quantity"] += qty
        loc["list_value"] = round(loc["list_value"] + qty * price, 2)

        cond = lot.get("new_or_used") or "?"
        by_condition[cond] = by_condition.get(cond, 0) + 1
    return {
        "lots": len(lots),
        "quantity": total_qty,
        "list_value": round(value, 2),
        "cost_value": round(cost, 2),
        "by_item_type": by_type,
        "by_location": by_location,
        "by_condition": by_condition,
    }


def _as_float(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


# ── Katalog & Recherche ───────────────────────────────────────────────────


@mcp.tool
def catalog_search(
    query: str | None = None,
    item_type: str | None = None,
    item_no: str | None = None,
    category: str | None = None,
    year_min: int | None = None,
    year_max: int | None = None,
    limit: int = 25,
) -> dict[str, Any]:
    """Textsuche im BrickLink-Katalog (offline, kostet KEIN API-Budget).

    Der Weg zur Teilenummer: hier nach dem Namen suchen ("Brick 2 x 4"), dann mit
    catalog_item / price_guide weiterarbeiten. Die Store API selbst hat keine Suche.

    item_type: "P" Part, "S" Set, "M" Minifig, "B" Book, "G" Gear, "C" Catalog,
        "I" Instruction, "O" Original Box, "U" Unsorted Lot (voller Name geht auch).
    Farben sind hier NICHT filterbar — der Katalog-Export kennt pro Item nur die
    Standardfarbe. Welche Farben es zu einem Teil gibt: known_colors.
    """
    rows = _wrap(
        catalog.search,
        query=query,
        item_type=item_type,
        item_no=item_no,
        category=category,
        year_min=year_min,
        year_max=year_max,
        limit=limit,
    )
    return {"count": len(rows), "items": rows}


@mcp.tool
def catalog_item(item_type: str, item_no: str) -> dict[str, Any]:
    """Katalogdaten eines Items direkt von BrickLink (exakte Nummer nötig)."""
    return _wrap(api.item, item_type.upper(), item_no)


@mcp.tool
def catalog_subsets(
    item_type: str, item_no: str, break_minifigs: bool = False, instruction: bool = False
) -> dict[str, Any]:
    """Was in einem Item enthalten ist — die Teileliste eines Sets (Part-Out-Grundlage).

    break_minifigs: True löst Minifiguren in Einzelteile auf.
    instruction: True nimmt Anleitung und Verpackung mit auf.
    """
    data = _wrap(api.subsets, item_type.upper(), item_no, break_minifigs, instruction)
    return {"entries": len(data), "subsets": data}


@mcp.tool
def catalog_supersets(item_type: str, item_no: str, color_id: int | None = None) -> dict[str, Any]:
    """In welchen Sets ein Teil vorkommt."""
    data = _wrap(api.supersets, item_type.upper(), item_no, color_id)
    return {"entries": len(data), "supersets": data}


@mcp.tool
def price_guide(
    item_type: str,
    item_no: str,
    color_id: int | None = None,
    guide_type: str = "stock",
    new_or_used: str = "N",
    country_code: str | None = None,
    region: str | None = None,
    currency_code: str | None = None,
) -> dict[str, Any]:
    """Preis-Guide zu einem Item.

    guide_type: "stock" = aktuell zum Verkauf angeboten, "sold" = Verkäufe der
        letzten 6 Monate. new_or_used: "N" oder "U".
    country_code / region: beschränkt auf Läden in einem Land bzw. einer Region
        (asia, africa, north_america, south_america, middle_east, europe, eu, oceania).
        Für deutsche Preisvorstellungen ist country_code="DE" meist aussagekräftiger
        als der Weltdurchschnitt.
    Preise sind laut BrickLink OHNE Mehrwertsteuer. Jeder Aufruf kostet einen
    API-Request; Antworten werden 12 Stunden gecacht.
    """
    data = _wrap(
        api.price_guide,
        item_type.upper(),
        item_no,
        color_id,
        guide_type,
        new_or_used,
        country_code,
        region,
        currency_code,
    )
    return data


@mcp.tool
def known_colors(item_type: str, item_no: str) -> dict[str, Any]:
    """In welchen Farben ein Teil laut Katalog existiert (mit Stückzahlen)."""
    data = _wrap(api.known_colors, item_type.upper(), item_no)
    return {"count": len(data), "colors": data}


@mcp.tool
def catalog_colors(name: str | None = None) -> dict[str, Any]:
    """BrickLink-Farbliste aus dem Offline-Index (Name → color_id). Kostet kein Budget."""
    rows = _wrap(catalog.colors, name)
    return {"count": len(rows), "colors": rows}


@mcp.tool
def catalog_categories(name: str | None = None) -> dict[str, Any]:
    """BrickLink-Kategorienliste aus dem Offline-Index. Kostet kein Budget."""
    rows = _wrap(catalog.categories, name)
    return {"count": len(rows), "categories": rows}


@mcp.tool
def element_id_lookup(
    element_id: str | None = None,
    item_type: str | None = None,
    item_no: str | None = None,
    color_id: int | None = None,
) -> dict[str, Any]:
    """Übersetzt zwischen LEGO-Element-ID (Part-Color-Code) und BrickLink-Nummer.

    Entweder element_id angeben (→ BrickLink-Item) oder item_type+item_no
    (→ Element-IDs, optional auf eine Farbe eingeschränkt).
    """
    if element_id:
        return {"mapping": _wrap(api.item_mapping_from_element, element_id)}
    if item_type and item_no:
        return {"mapping": _wrap(api.item_mapping_from_no, item_type.upper(), item_no, color_id)}
    raise ToolError("Entweder element_id oder item_type + item_no angeben.")


# ── Betrieb ────────────────────────────────────────────────────────────────


@mcp.tool
def notifications(limit: int = 25) -> dict[str, Any]:
    """Ungelesene BrickLink-Push-Benachrichtigungen (neue Bestellung, Statusänderung
    durch den Käufer, geänderte Positionen, neue Nachricht, neues Feedback).

    ⚠️ EINMALIG: BrickLink liefert jede Benachrichtigung nur bei EINEM Abruf. Danach
    ist die Liste leer — am 2026-08-27 verifiziert (erst 159, direkt danach 0). Wer
    also etwas mit dem Ergebnis vorhat, muss es in derselben Antwort verarbeiten;
    ein zweiter Aufruf holt es nicht zurück.

    BrickLink garantiert die Zustellung außerdem ausdrücklich NICHT — für den
    verlässlichen Stand `orders_dashboard` benutzen. `by_event_type` fasst zusammen,
    `limit` begrenzt die Ausgabe.
    """
    data = _wrap(api.notifications)
    by_event: dict[str, int] = {}
    for n in data:
        key = str(n.get("event_type") or "?")
        by_event[key] = by_event.get(key, 0) + 1
    limit = max(1, min(limit, 200))
    return {
        "count": len(data),
        "returned": min(len(data), limit),
        "by_event_type": dict(sorted(by_event.items())),
        "notifications": data[:limit],
    }


@mcp.tool
def shipping_methods() -> dict[str, Any]:
    """Die im Store konfigurierten Versandarten (mit method_id)."""
    data = _wrap(api.shipping_methods)
    return {"count": len(data), "shipping_methods": data}


@mcp.tool
def api_quota() -> dict[str, Any]:
    """Verbrauchte BrickLink-API-Requests heute, Budget und Restkontingent."""
    return state.usage()


@mcp.tool
def catalog_status() -> dict[str, Any]:
    """Zustand des Offline-Katalogindex: Alter, Item-Zahlen, Größe."""
    st = catalog.status()
    st["refresh_interval_days"] = cfg.catalog_refresh_days
    st["web_token_configured"] = cfg.has_web_session
    return st


@mcp.tool
def catalog_refresh() -> dict[str, Any]:
    """Baut den Offline-Katalogindex neu aus dem offiziellen BrickLink-Katalog-Export.

    Dauert einige Minuten und braucht ein gültiges BrickLink-Web-Token
    (30 Tage Laufzeit). Kostet KEIN API-Kontingent, läuft nicht über die Store API.
    """
    return _wrap(catalog.refresh, web)


@mcp.custom_route("/health", methods=["GET"])
async def health(_request):  # noqa: ANN001 - Starlette-Request
    from starlette.responses import JSONResponse

    return JSONResponse({"status": "ok", "catalog": catalog.status().get("present", False)})


def _refresher() -> None:
    """Hintergrund-Thread: hält den Katalogindex frisch.

    Absichtlich im Prozess und nicht als CronJob: der Index liegt auf einem
    ReadWriteOnce-PVC, ein zweiter Pod würde sich um den Mount streiten.
    """
    while True:
        try:
            if cfg.has_web_session and catalog.stale(cfg.catalog_refresh_days):
                log.info("Katalogindex ist veraltet — baue neu")
                result = catalog.refresh(web)
                log.info("Katalogindex neu gebaut: %s", result)
        except Exception as exc:  # noqa: BLE001 - Thread darf nie sterben
            log.warning("Katalog-Refresh fehlgeschlagen: %s", exc)
        time.sleep(6 * 3600)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not cfg.has_store_api:
        log.warning("Store-API-Credentials fehlen — lesende Tools werden fehlschlagen")
    if not cfg.store_username:
        log.warning(
            "BRICKLINK_STORE_USERNAME ist leer: der Verkäufer-Guard für Schreibzugriffe "
            "kann nicht prüfen, ob eine Bestellung ein eigener Verkauf ist"
        )
    threading.Thread(target=_refresher, name="catalog-refresh", daemon=True).start()
    mcp.run(transport="http", host=cfg.host, port=cfg.port, path=cfg.path)


if __name__ == "__main__":
    main()
