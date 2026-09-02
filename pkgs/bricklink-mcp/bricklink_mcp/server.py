"""MCP-Server für die BrickLink-Stores.

Transport: Streamable HTTP — Open WebUI (ab 0.6.31, hier 0.11.0) spricht
NATIVES MCP ausschließlich darüber. Kein stdio, kein SSE.

── MEHRERE SHOPS, HART GETRENNT ────────────────────────────────────────────────
Der Server bedient mehr als einen BrickLink-Shop. Es gibt bewusst KEINEN
„aktuellen Shop" und keinen globalen Zustand, der zwischen Aufrufen hängen
bleibt: jedes store-bezogene Tool nimmt einen `store`-Parameter. Ist er nicht
angegeben und lässt sich auch kein Nutzer-Default ermitteln, wird der Aufruf
ABGELEHNT — mit der Aufforderung, den Nutzer zu fragen. Raten ist keine Option.

Drei Schranken gegen Verwechslung:
  1. `store` pro Aufruf, kein Zustand;
  2. jede Antwort nennt `store` und `store_username`, mit dem sie gelaufen ist;
  3. schreibende Aufrufe prüfen zusätzlich `seller_name` der Bestellung gegen den
     Benutzernamen des gewählten Shops — ein falscher Shop schreibt nichts.

Aufteilung der Datenquellen:
  * Store API v1 (OAuth 1.0a, ein eigener Consumer-Key PRO SHOP): Bestellungen,
    Nachrichten, Feedback, Inventar, Katalog-Einzelabfragen, Preis-Guide,
    Benachrichtigungen.
  * Offline-Katalogindex (aus dem offiziellen Katalog-Export): Textsuche, die die
    API nicht anbietet. Store-unabhängig — der Katalog gehört BrickLink, nicht
    einem Shop.
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
from fastmcp.server.dependencies import get_http_headers

from . import exports, links, mailbox
from .catalog import Catalog
from .config import USER_EMAIL_HEADER, USER_NAME_HEADER, Config, Store
from .guards import NotAllowed, check_seller, check_transition
from .mailbox import Mailbox, MailboxError
from .state import Quota, State
from .store import BrickLinkError, StoreApi
from .web import WebSession, WebSessionError

log = logging.getLogger("bricklink-mcp")

cfg = Config.from_env()
state = State(os.path.join(cfg.data_dir, "state.db"), cfg.daily_budget)
catalog = Catalog(os.path.join(cfg.data_dir, "catalog.db"))

# Katalog-Session: der Katalog gehört BrickLink, nicht einem Shop — ein beliebiges
# Web-Token reicht.
web = WebSession(cfg, context="Katalog-Export")

# Eine API-Instanz pro Shop. Bewusst vorab angelegt: so scheitert ein Tippfehler im
# Store-Namen sofort und nicht erst beim HTTP-Call.
apis: dict[str, StoreApi] = {s.slug: StoreApi(cfg, state, s) for s in cfg.stores}

# Eine WEB-Session pro Shop. Das Web-Token ist KONTOGEBUNDEN: mit dem Token von Konto
# A liefern die Exporte die Daten von Shop A, unabhängig davon, welcher Store angefragt
# war. Deshalb pro Shop eine eigene Session — und `verify_account` prüft vor der
# Auslieferung, dass der Kontoname zum Shop passt.
webs: dict[str, WebSession] = {
    s.slug: WebSession(
        cfg,
        client_token=s.web_token,
        context=f"Shop {s.label}",
        secret_hint=f"bricklink-api-{s.slug}.age",
    )
    for s in cfg.stores
}

EXPORT_DIR = os.path.join(cfg.data_dir, "exports")
# Arbeitsverzeichnis der Code-Sandbox (jupyter-Container im selben Pod). Der MCP
# schreibt hier nichts, er listet und verlinkt nur — geschrieben wird vom Modell im
# Interpreter.
WORKSPACE_DIR = os.path.join(cfg.data_dir, "workspace")
# Inventar-Export ist 7,5 MB und ändert sich nicht minütlich — 15 Minuten Cache, damit
# mehrere Filterfragen hintereinander nicht jedes Mal neu herunterladen.
INVENTORY_TTL = 900

auth = None
if cfg.bearer_token:
    # Statischer Bearer-Token. Zweite Schranke hinter der CiliumNetworkPolicy,
    # die den Port ohnehin nur für den open-webui-Pod öffnet.
    from fastmcp.server.auth import StaticTokenVerifier

    auth = StaticTokenVerifier(
        {cfg.bearer_token: {"client_id": "open-webui", "scopes": ["bricklink"]}}
    )


def _store_list() -> str:
    return ", ".join(f"{s.slug} ({s.label})" for s in cfg.stores) or "(keiner konfiguriert)"


mcp = FastMCP(
    name="bricklink",
    instructions=(
        "Verwaltung von BrickLink-Shops. Konfiguriert: " + _store_list() + ".\n"
        "\n"
        "WICHTIGSTE REGEL: Jedes Tool, das Shop-Daten liest oder schreibt, braucht den "
        "Parameter `store`. Wenn aus dem Gespräch nicht eindeutig hervorgeht, welcher "
        "Shop gemeint ist, FRAGE ZUERST den Nutzer — niemals raten und niemals einen "
        "Shop aus einem früheren Thema übernehmen. Bei jeder Antwort steht der Shop "
        "dabei; nenne ihn in deiner Antwort mit, damit der Nutzer es sieht. Vor jedem "
        "SCHREIBENDEN Aufruf (gepackt/versendet melden, Feedback, Versandmail) den Shop "
        "und die Bestellnummer noch einmal ausdrücklich bestätigen lassen.\n"
        "\n"
        "Lesen: Bestellungen (erhalten und selbst getätigte), Bestellpositionen, "
        "Nachrichten zu Bestellungen, Feedback, Bewertungsbilanz, Inventar, Katalog und "
        "Preis-Guide. Schreiben: NUR order_mark_packed und order_mark_shipped (optional "
        "mit Sendungsnummer), Feedback abgeben/beantworten und die Versandmail "
        "'Thank You, Drive Thru'. Alle anderen Statuswechsel gibt es hier nicht.\n"
        "\n"
        "Jeder BrickLink-Aufruf zählt gegen ein Tagesbudget PRO SHOP — api_quota zeigt "
        "den Stand. Für Teilesuche nach Namen catalog_search benutzen: der läuft gegen "
        "einen lokalen Index, kostet kein Budget und ist shop-unabhängig."
    ),
    auth=auth,
)


# ── Store-Auflösung ────────────────────────────────────────────────────────


def _caller() -> tuple[str | None, str | None]:
    """(E-Mail, Anzeigename) des anfragenden OpenWebUI-Nutzers, falls mitgeschickt."""
    headers = get_http_headers()
    return headers.get(USER_EMAIL_HEADER), headers.get(USER_NAME_HEADER)


def _resolve(store: str | None, *, for_catalog: bool = False) -> StoreApi:
    """Store-Parameter zu einer API-Instanz auflösen — oder klar scheitern.

    Reihenfolge:
      1. ausdrücklich angegebener Store (Slug, Anzeigename oder BL-Benutzername),
      2. Default des anfragenden Nutzers (nur wenn OpenWebUI die User-Header
         mitschickt),
      3. bei reinen KATALOG-Abfragen: der erste benutzbare Shop, weil die Daten
         shop-unabhängig sind und nur das Kontingent belastet wird,
      4. sonst: Fehler mit der Aufforderung, den Nutzer zu fragen.
    """
    if not cfg.stores:
        raise ToolError(
            "Es ist kein Shop konfiguriert (BRICKLINK_STORES ist leer). "
            "Das ist ein Deployment-Fehler, kein Eingabefehler."
        )

    if store:
        found = cfg.store(store)
        if not found:
            raise ToolError(
                f"Unbekannter Shop {store!r}. Möglich sind: {_store_list()}. "
                "Bitte beim Nutzer nachfragen, welcher gemeint ist."
            )
        return apis[found.slug]

    email, name = _caller()
    default = cfg.default_store_for(email, name)
    if default:
        return apis[default.slug]

    if for_catalog:
        for candidate in cfg.stores:
            if candidate.usable:
                return apis[candidate.slug]

    raise ToolError(
        "Kein Shop angegeben und für diesen Nutzer ist kein Default hinterlegt. "
        f"FRAGE DEN NUTZER, welcher Shop gemeint ist. Möglich: {_store_list()}."
    )


def _web(store: str | None) -> tuple[StoreApi, WebSession]:
    """API- UND Web-Session eines Shops, mit geprüftem Konto.

    Die Kontoprüfung ist die Export-Variante des Verkäufer-Guards: ein Web-Token, das
    zum falschen Konto gehört, würde Daten aus dem falschen Shop liefern. Dann bricht
    der Aufruf ab, statt falsche Zahlen zu liefern.
    """
    api = _resolve(store)
    session = webs[api.store.slug]
    if not session.configured:
        raise ToolError(
            f"Für den Shop {api.store.label!r} ist kein Web-Token hinterlegt. Die "
            "XML-Exporte brauchen eines (30 Tage gültig, mit dem BL-Konto DIESES Shops "
            "auf https://bricklink.com/v3/brickstore-access-management.page erzeugen) — "
            f"als WEB_TOKEN in bricklink-api-{api.store.slug}.age. Die API-Tools "
            "funktionieren ohne."
        )
    _wrap(session.verify_account, api.store.username)
    return api, session


def _stamp(api: StoreApi, payload: dict[str, Any]) -> dict[str, Any]:
    """Store-Herkunft in jede Antwort schreiben — sichtbar gegen Verwechslung."""
    return {"store": api.store.slug, "store_label": api.store.label, **payload}


def _wrap(fn, *args, **kwargs):
    """Fehler aus den Clients in ToolError übersetzen (Modell soll den Text sehen)."""
    try:
        return fn(*args, **kwargs)
    except (BrickLinkError, WebSessionError, NotAllowed, Quota, MailboxError, RuntimeError) as exc:
        raise ToolError(str(exc)) from exc


def _parse_ts(value: str | None) -> datetime:
    if not value:
        return datetime.fromtimestamp(0, tz=timezone.utc)
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return datetime.fromtimestamp(0, tz=timezone.utc)


def _as_float(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


# ── Shops ──────────────────────────────────────────────────────────────────


@mcp.tool
def stores() -> dict[str, Any]:
    """Welche Shops es gibt, wer gerade fragt und welcher Shop dessen Default ist.

    Immer dann aufrufen, wenn unklar ist, für welchen Shop etwas gelten soll —
    und dem Nutzer die Auswahl vorlegen, statt zu raten.
    """
    email, name = _caller()
    default = cfg.default_store_for(email, name)
    return {
        "stores": [
            {
                "store": s.slug,
                "label": s.label,
                "bricklink_username": s.username or None,
                "credentials_present": s.usable,
                "web_token_present": s.has_web,
                "mailbox_present": s.has_mailbox,
                "is_default_for_caller": bool(default and default.slug == s.slug),
            }
            for s in cfg.stores
        ],
        "caller": {"email": email, "name": name, "known": bool(email or name)},
        "default_store": default.slug if default else None,
        "note": (
            "Ohne `store` und ohne Nutzer-Default lehnen die Tools ab. Kennt der Server "
            "den Aufrufer nicht, liegt das an OpenWebUI: dort muss "
            "ENABLE_FORWARD_USER_INFO_HEADERS=True gesetzt sein."
        ),
    }


# ── Bestellungen: lesen ────────────────────────────────────────────────────


@mcp.tool
def orders_list(
    store: str | None = None,
    direction: str = "in",
    status: str | None = None,
    filed: bool | None = None,
    since_days: int | None = None,
    limit: int = 25,
    include_purged: bool = False,
) -> dict[str, Any]:
    """Listet Bestellungen eines Shops, neueste zuerst.

    store: welcher Shop — Pflicht, sofern für den Nutzer kein Default hinterlegt ist.
    direction: "in" = beim Shop eingegangene Verkäufe, "out" = Einkäufe des Shops.
    status: BrickLink-Statusfilter, kommasepariert, "-" schließt aus
        (z.B. "pending,paid" oder "-purged").
    filed: True = nur abgelegte, False = nur nicht abgelegte Bestellungen.
    since_days: filtert nachträglich auf date_ordered der letzten n Tage
        (die API selbst kann nicht nach Datum filtern).
    limit: wie viele Bestellungen zurückkommen (Default 25). `count` nennt immer
        die Gesamtzahl der Treffer, `returned` die Zahl der ausgelieferten.
    include_purged: BrickLink löscht die Details alter Bestellungen und setzt sie auf
        PURGED. Ohne diesen Schalter werden sie ausgeblendet — sonst besteht die
        Antwort fast nur aus leeren Altlasten (im Shop SteinAberFein am 2026-08-27:
        986 Bestellungen insgesamt, davon 876 PURGED).
    """
    api = _resolve(store)
    if status is None and not include_purged:
        status = "-purged"
    orders = _wrap(api.orders, direction=direction, status=status, filed=filed)
    if since_days:
        cutoff = datetime.now(timezone.utc) - timedelta(days=since_days)
        orders = [o for o in orders if _parse_ts(o.get("date_ordered")) >= cutoff]
    orders.sort(key=lambda o: o.get("date_ordered") or "", reverse=True)
    limit = max(1, min(limit, 500))
    return _stamp(
        api,
        {
            "count": len(orders),
            "returned": min(len(orders), limit),
            "status_filter": status,
            "orders": orders[:limit],
        },
    )


@mcp.tool
def order_get(order_id: int, store: str | None = None) -> dict[str, Any]:
    """Volles Bestelldetail inklusive Lieferadresse, Kosten, Zahlungs- und Versandinfos."""
    api = _resolve(store)
    return _stamp(api, {"order": _wrap(api.order, order_id)})


@mcp.tool
def order_items(order_id: int, store: str | None = None) -> dict[str, Any]:
    """Positionen einer Bestellung. BrickLink gruppiert sie in Batches (ein Batch pro Lot-Block)."""
    api = _resolve(store)
    batches = _wrap(api.order_items, order_id)
    flat = [item for batch in batches for item in batch]
    return _stamp(api, {"batches": len(batches), "lots": len(flat), "items": flat})


@mcp.tool
def order_messages(order_id: int, store: str | None = None) -> dict[str, Any]:
    """Nachrichten zu einer Bestellung.

    Achtung, Grenze der API: sie liefert nur Nachrichten, die der Shop als VERKÄUFER
    EMPFANGEN hat. Nachrichten senden geht über die API nicht — dafür (noch) die
    Web-UI.
    """
    api = _resolve(store)
    msgs = _wrap(api.order_messages, order_id)
    return _stamp(api, {"count": len(msgs), "messages": msgs})


@mcp.tool
def order_feedback(order_id: int, store: str | None = None) -> dict[str, Any]:
    """Bewertungen zu EINER Bestellung — beide Richtungen, also auch die, die der Shop
    selbst abgegeben hat. Nützlich vor `feedback_post`, um nicht doppelt zu bewerten.
    """
    api = _resolve(store)
    fb = _wrap(api.order_feedback, order_id)
    return _stamp(api, {"count": len(fb), "feedback": fb})


@mcp.tool
def orders_dashboard(store: str | None = None, direction: str = "in") -> dict[str, Any]:
    """Überblick für einen Shop: offene Bestellungen nach Status, Umsatz der letzten
    30 Tage, Handlungsbedarf.

    Kostet genau einen API-Request. Guter Startpunkt für "was ist zu tun?".
    """
    api = _resolve(store)
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
            revenue_30d += _as_float((o.get("cost") or {}).get("grand_total"))
            currency = (o.get("cost") or {}).get("currency_code") or currency
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
    return _stamp(
        api,
        {
            "direction": direction,
            "orders_total": len(orders),
            "by_status": dict(sorted(by_status.items())),
            "revenue_last_30_days": round(revenue_30d, 2),
            "currency": currency,
            "waiting_to_be_packed": to_pack,
            "packed_waiting_for_shipment": to_ship,
        },
    )


# ── Bestellungen: die zwei erlaubten Statuswechsel ─────────────────────────


@mcp.tool
def order_mark_packed(order_id: int, store: str | None = None) -> dict[str, Any]:
    """Setzt eine Bestellung auf PACKED (gepackt, noch nicht verschickt).

    ⚠️ Schreibend. Vorher Shop UND Bestellnummer beim Nutzer bestätigen lassen.
    Erlaubt nur aus PENDING, UPDATED, PROCESSING, READY oder PAID und nur für
    Verkäufe des gewählten Shops. Andere Statuswechsel sind hier nicht möglich.
    """
    api = _resolve(store)
    order = _wrap(api.order, order_id)
    _wrap(check_transition, order, "PACKED", api.store.username, api.store.label)
    _wrap(api.update_order_status, order_id, "PACKED")
    after = _wrap(api.order, order_id)
    return _stamp(
        api,
        {
            "order_id": order_id,
            "buyer": after.get("buyer_name"),
            "status_before": order.get("status"),
            "status_after": after.get("status"),
            "payment_status": (after.get("payment") or {}).get("status"),
        },
    )


@mcp.tool
def order_mark_shipped(
    order_id: int,
    store: str | None = None,
    tracking_no: str | None = None,
    date_shipped: str | None = None,
    send_drive_thru: bool = False,
) -> dict[str, Any]:
    """Setzt eine Bestellung von PACKED auf SHIPPED.

    ⚠️ Schreibend. Vorher Shop UND Bestellnummer beim Nutzer bestätigen lassen.

    tracking_no: Sendungsnummer, wird vor dem Statuswechsel gesetzt (für den Käufer sichtbar).
    date_shipped: ISO-Zeitstempel; ohne Angabe wird JETZT eingetragen. Dieses Feld ist
        laut BrickLink API-only und auf den Webseiten nicht zu sehen.
    send_drive_thru: True verschickt zusätzlich BrickLinks "Thank You, Drive Thru!"-Mail
        an den Käufer.
    """
    api = _resolve(store)
    order = _wrap(api.order, order_id)
    _wrap(check_transition, order, "SHIPPED", api.store.username, api.store.label)

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
    return _stamp(
        api,
        {
            "order_id": order_id,
            "buyer": after.get("buyer_name"),
            "status_before": order.get("status"),
            "status_after": after.get("status"),
            "tracking_no": (after.get("shipping") or {}).get("tracking_no"),
            "date_shipped": (after.get("shipping") or {}).get("date_shipped"),
            "drive_thru_sent": after.get("drive_thru_sent") if drive_thru is not None else None,
        },
    )


@mcp.tool
def order_set_tracking(order_id: int, tracking_no: str, store: str | None = None) -> dict[str, Any]:
    """Trägt nur die Sendungsnummer nach, ohne den Status anzufassen. ⚠️ Schreibend."""
    api = _resolve(store)
    order = _wrap(api.order, order_id)
    _wrap(check_seller, order, api.store.username, api.store.label)
    _wrap(api.update_order, order_id, {"shipping": {"tracking_no": tracking_no}})
    after = _wrap(api.order, order_id)
    return _stamp(
        api,
        {
            "order_id": order_id,
            "buyer": after.get("buyer_name"),
            "tracking_no": (after.get("shipping") or {}).get("tracking_no"),
        },
    )


@mcp.tool
def order_send_drive_thru(
    order_id: int, store: str | None = None, mail_me: bool = False
) -> dict[str, Any]:
    """Verschickt BrickLinks "Thank You, Drive Thru!"-Versandmail an den Käufer.

    ⚠️ Schreibend (die Mail geht wirklich raus). mail_me: True schickt eine Kopie
    an das eigene Postfach.
    """
    api = _resolve(store)
    order = _wrap(api.order, order_id)
    _wrap(check_seller, order, api.store.username, api.store.label)
    _wrap(api.drive_thru, order_id, mail_me)
    return _stamp(api, {"order_id": order_id, "buyer": order.get("buyer_name"), "drive_thru_sent": True})


# ── Postfach (Benachrichtigungsmails) ─────────────────────────────────────
# Die API kennt nur Nachrichten AN EINER BESTELLUNG. Alles andere („Contact Member",
# Fragen von einer Katalogseite) ist dort unsichtbar, und der Web-Weg ist für unsere
# Session gesperrt. Deshalb dieser Weg über die Benachrichtigungsmails: LESEND,
# ohne Flags zu verändern.


def _mailbox(api: StoreApi) -> Mailbox:
    store = api.store
    if not store.has_mailbox:
        raise ToolError(
            f"Für den Shop {store.label!r} ist kein Postfach hinterlegt. Nötig sind "
            f"MAIL_HOST, MAIL_USER und MAIL_PASSWORD in bricklink-api-{store.slug}.age "
            "(bei Gmail ein App-Passwort). Ohne das zeigt nur `order_messages` "
            "Nachrichten — und die nur zu Bestellungen."
        )
    return Mailbox(
        host=store.mail_host,
        port=store.mail_port,
        user=store.mail_user,
        password=store.mail_password,
        folder=store.mail_folder,
    )


@mcp.tool
def inbox_messages(
    store: str | None = None,
    since_days: int = 14,
    limit: int = 20,
    unread_only: bool = False,
    kind: str | None = "message",
) -> dict[str, Any]:
    """Eingegangene BrickLink-Nachrichten aus den Benachrichtigungsmails.

    Das ist der einzige Weg an Anfragen, die NICHT an einer Bestellung hängen — etwa
    „ich hätte eine Frage zu dieser Figur" über Contact Member. Bestellbezogene
    Nachrichten stehen zusätzlich in `order_messages`.

    since_days: Zeitraum (Default 14). unread_only: nur ungelesene Mails.
    kind: "message" (Default), "feedback", "order" oder null für alles.

    ⚠️ Antworten geht hierüber nicht — BrickLink verschickt die Mails von einer
    No-Reply-Adresse, eine Antwortmail landet nicht im BrickLink-Thread. Zu jeder
    Nachricht kommen deshalb die BrickLink-Links mit; dort geht die Antwort raus.
    Formuliere den Antworttext, gib ihn dem Nutzer und nenne den Link dazu.

    Der Abruf verändert den Ungelesen-Status im Postfach NICHT.
    """
    api = _resolve(store)
    box = _mailbox(api)
    entries = _wrap(mailbox.fetch, box, since_days, limit, unread_only)
    if kind:
        entries = [e for e in entries if e["kind"] == kind]
    return _stamp(
        api,
        {
            "source": f"IMAP {box.host}/{box.folder} (nur lesend)",
            "api_requests_used": 0,
            "period_days": since_days,
            "count": len(entries),
            "messages": [
                {
                    **{k: v for k, v in e.items() if k != "body"},
                    "body": (e["body"][:1500] + " …") if len(e["body"]) > 1500 else e["body"],
                }
                for e in entries
            ],
            "reply_hint": (
                "Antworten in der Web-UI: https://www.bricklink.com/ → Nachrichten. "
                "Die Links pro Nachricht führen direkt hin."
            ),
        },
    )


@mcp.tool
def inbox_message(uid: str, store: str | None = None, since_days: int = 60) -> dict[str, Any]:
    """Eine einzelne Benachrichtigungsmail im Volltext (uid aus `inbox_messages`)."""
    api = _resolve(store)
    box = _mailbox(api)
    entries = _wrap(mailbox.fetch, box, since_days, 100, False)
    for entry in entries:
        if entry["uid"] == str(uid):
            return _stamp(api, {"message": entry})
    raise ToolError(
        f"Keine Mail mit uid {uid!r} in den letzten {since_days} Tagen. "
        "uid kommt aus `inbox_messages` und gilt nur für diesen Postfach-Ordner."
    )


# ── Feedback / Bewertungen ────────────────────────────────────────────────


@mcp.tool
def feedback_list(store: str | None = None, direction: str = "in", limit: int = 25) -> dict[str, Any]:
    """Bewertungen, neueste zuerst. direction "in" = erhaltene, "out" = selbst abgegebene.

    limit begrenzt nur die Ausgabe; `count` bleibt die Gesamtzahl und `summary` zählt
    die Ratings über ALLE Einträge (0 = Lob, 1 = Neutral, 2 = Beschwerde).
    """
    api = _resolve(store)
    fb = _wrap(api.feedback_list, direction)
    summary: dict[str, int] = {}
    for entry in fb:
        key = {0: "praise", 1: "neutral", 2: "complaint"}.get(entry.get("rating"), "unknown")
        summary[key] = summary.get(key, 0) + 1
    fb.sort(key=lambda e: e.get("date_rated") or "", reverse=True)
    limit = max(1, min(limit, 500))
    return _stamp(
        api,
        {
            "count": len(fb),
            "returned": min(len(fb), limit),
            "summary": summary,
            "feedback": fb[:limit],
        },
    )


@mcp.tool
def feedback_get(feedback_id: int, store: str | None = None) -> dict[str, Any]:
    """Eine einzelne Bewertung."""
    api = _resolve(store)
    return _stamp(api, {"feedback": _wrap(api.feedback, feedback_id)})


@mcp.tool
def feedback_post(order_id: int, rating: str, comment: str, store: str | None = None) -> dict[str, Any]:
    """Gibt eine Bewertung zu einer Bestellung ab.

    ⚠️ Schreibend und ENDGÜLTIG: eine abgegebene Bewertung lässt sich über die API
    nicht mehr ändern. Vorher Shop, Bestellnummer und Text bestätigen lassen.

    rating: "praise", "neutral" oder "complaint" (BrickLink-intern 0/1/2).
    """
    mapping = {"praise": 0, "neutral": 1, "complaint": 2}
    key = rating.strip().lower()
    if key not in mapping:
        raise ToolError('rating muss "praise", "neutral" oder "complaint" sein.')
    if not comment.strip():
        raise ToolError("comment darf nicht leer sein.")
    api = _resolve(store)
    order = _wrap(api.order, order_id)
    _wrap(check_seller, order, api.store.username, api.store.label)
    return _stamp(
        api, {"feedback": _wrap(api.post_feedback, order_id, mapping[key], comment.strip())}
    )


@mcp.tool
def feedback_reply(feedback_id: int, reply: str, store: str | None = None) -> dict[str, Any]:
    """Antwortet auf eine erhaltene Bewertung. ⚠️ Schreibend, einmalig, nicht änderbar."""
    if not reply.strip():
        raise ToolError("reply darf nicht leer sein.")
    api = _resolve(store)
    return _stamp(api, {"feedback": _wrap(api.reply_feedback, feedback_id, reply.strip())})


@mcp.tool
def member_ratings(store: str | None = None, username: str | None = None) -> dict[str, Any]:
    """Bewertungsbilanz (Lob/Neutral/Beschwerde, getrennt als Käufer und Verkäufer).

    Ohne username: der eigene Shop. Funktioniert auch für fremde Mitglieder —
    nützlich, um einen Käufer vor dem Versand einzuschätzen.
    """
    api = _resolve(store, for_catalog=username is not None)
    user = username or api.store.username
    if not user:
        raise ToolError(
            f"Für den Shop {api.store.label!r} ist kein BL-Benutzername hinterlegt "
            "und es wurde keiner angegeben."
        )
    return _stamp(api, {"username": user, "ratings": _wrap(api.member_ratings, user)})


# ── Inventar ───────────────────────────────────────────────────────────────


@mcp.tool
def inventory_list(
    store: str | None = None,
    item_type: str | None = None,
    status: str | None = None,
    category_id: int | None = None,
    color_id: int | None = None,
    limit: int = 50,
) -> dict[str, Any]:
    """Lots im Inventar eines Shops.

    status: "Y" verfügbar, "S" im Stockroom, "B"/"C" Stockroom B/C, "N" reserviert,
        "R" reserviert für einen Käufer; "-" schließt aus (z.B. "-R").
    limit: kappt die zurückgegebene Liste (die API liefert immer ALLES — im Shop
        SteinAberFein sind das 12.714 Lots, also rund 5 MB JSON). `count` nennt die
        Gesamtzahl der Treffer; Summen über alles gibt `inventory_stats`.
    """
    api = _resolve(store)
    lots = _wrap(
        api.inventories,
        item_type=item_type,
        status=status,
        category_id=category_id,
        color_id=color_id,
    )
    limit = max(1, min(limit, 500))
    return _stamp(
        api, {"count": len(lots), "returned": min(len(lots), limit), "lots": lots[:limit]}
    )


@mcp.tool
def inventory_get(inventory_id: int, store: str | None = None) -> dict[str, Any]:
    """Ein einzelnes Lot im Inventar."""
    api = _resolve(store)
    return _stamp(api, {"lot": _wrap(api.inventory, inventory_id)})


@mcp.tool
def inventory_stats(store: str | None = None) -> dict[str, Any]:
    """Kennzahlen über das gesamte Inventar eines Shops: Lots, Stückzahl, Listenwert,
    Einkaufswert.

    Ein API-Request. `list_value` ist Menge × eigener Preis (die eigene
    Preisvorstellung, kein Marktwert), `cost_value` die Summe aus `my_cost`, soweit
    hinterlegt. Beträge in der Währung des Shops — die API gibt beim Inventar keine
    Währung mit.

    Aufteilung nach Lager: `for_sale` (im Shop sichtbar), `stockroom_<id>` (Stockroom
    A/B/C, nicht im Shop) und `retain` (Lot bleibt nach Verkauf erhalten).
    """
    api = _resolve(store)
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
    return _stamp(
        api,
        {
            "lots": len(lots),
            "quantity": total_qty,
            "list_value": round(value, 2),
            "cost_value": round(cost, 2),
            "by_item_type": by_type,
            "by_location": by_location,
            "by_condition": by_condition,
        },
    )


# ── Katalog & Recherche (shop-unabhängig) ─────────────────────────────────
# Diese Daten gehören BrickLinks Katalog, nicht einem Shop. `store` ist hier
# optional und entscheidet nur, WESSEN Tageskontingent den Request bezahlt.


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
    """Textsuche im BrickLink-Katalog (offline, kostet KEIN API-Budget, shop-unabhängig).

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
def catalog_item(item_type: str, item_no: str, store: str | None = None) -> dict[str, Any]:
    """Katalogdaten eines Items direkt von BrickLink (exakte Nummer nötig)."""
    api = _resolve(store, for_catalog=True)
    return _wrap(api.item, item_type.upper(), item_no)


@mcp.tool
def catalog_subsets(
    item_type: str,
    item_no: str,
    break_minifigs: bool = False,
    instruction: bool = False,
    store: str | None = None,
) -> dict[str, Any]:
    """Was in einem Item enthalten ist — die Teileliste eines Sets (Part-Out-Grundlage).

    break_minifigs: True löst Minifiguren in Einzelteile auf.
    instruction: True nimmt Anleitung und Verpackung mit auf.
    """
    api = _resolve(store, for_catalog=True)
    data = _wrap(api.subsets, item_type.upper(), item_no, break_minifigs, instruction)
    return {"entries": len(data), "subsets": data}


@mcp.tool
def catalog_supersets(
    item_type: str, item_no: str, color_id: int | None = None, store: str | None = None
) -> dict[str, Any]:
    """In welchen Sets ein Teil vorkommt."""
    api = _resolve(store, for_catalog=True)
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
    store: str | None = None,
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
    api = _resolve(store, for_catalog=True)
    return _wrap(
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


@mcp.tool
def known_colors(item_type: str, item_no: str, store: str | None = None) -> dict[str, Any]:
    """In welchen Farben ein Teil laut Katalog existiert (mit Stückzahlen)."""
    api = _resolve(store, for_catalog=True)
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
    store: str | None = None,
) -> dict[str, Any]:
    """Übersetzt zwischen LEGO-Element-ID (Part-Color-Code) und BrickLink-Nummer.

    Entweder element_id angeben (→ BrickLink-Item) oder item_type+item_no
    (→ Element-IDs, optional auf eine Farbe eingeschränkt).
    """
    api = _resolve(store, for_catalog=True)
    if element_id:
        return {"mapping": _wrap(api.item_mapping_from_element, element_id)}
    if item_type and item_no:
        return {"mapping": _wrap(api.item_mapping_from_no, item_type.upper(), item_no, color_id)}
    raise ToolError("Entweder element_id oder item_type + item_no angeben.")


# ── XML-Exporte (kosten KEIN API-Kontingent) ───────────────────────────────
# Die Exporte laufen über die Web-Session, nicht über die Store API. Ein Aufruf
# liefert, wofür die API viele Requests bräuchte — und teils Felder, die die API
# nicht hat. Sie brauchen dafür das kontogebundene 30-Tage-Web-Token des Shops.


@mcp.tool
def orders_export(
    store: str | None = None,
    last_n_days: int = 30,
    direction: str = "in",
    order_id: int | None = None,
    include_items: bool = False,
    limit: int = 25,
    max_items: int = 200,
    as_csv: bool = False,
) -> dict[str, Any]:
    """Bestellungen SAMT allen Positionen in einem Rutsch — ohne API-Kontingent.

    Der Unterschied zu `orders_list` + `order_items`: dort kostet jede Bestellung einen
    eigenen API-Request für ihre Positionen (bei 30 Bestellungen also 31). Hier ist es
    EIN Web-Request für den ganzen Zeitraum, und das Tagesbudget bleibt unberührt.
    Genau das Richtige für Picklisten, Monatsauswertungen und „was steckt in den
    Bestellungen der letzten Woche".

    last_n_days: Zeitraum (Default 30). order_id: nur diese eine Bestellung.
    include_items: Positionen mitliefern. ⚠️ Default AUS: 26 Bestellungen mit allen
        Positionen sind mehrere Hundert Zeilen JSON und sprengen den Chat-Kontext (am
        2026-08-27 genau so passiert — das Modell produzierte 30k Token und gab keine
        Antwort mehr). Für „was steckt in Bestellung X" gezielt `order_id` setzen, für
        Auswertungen `top_selling_items` benutzen.
    max_items: harte Obergrenze für ausgelieferte Positionen, wenn include_items=True.
        Was gekappt wurde, steht in `items_truncated`.
    limit: wie viele Bestellungen ausgegeben werden; `count` nennt die Gesamtzahl.
    as_csv: zusätzlich als CSV — bei include_items=True eine Zeile pro POSITION
        (mit Bestellnummer und Käufer davor), sonst eine Zeile pro Bestellung.

    Enthaltene Felder pro Position: ITEMID, ITEMTYPE, COLOR, QTY, PRICE, CONDITION,
    LOTID, MYCOST, WEIGHT, REMARKS (die Lot-Bemerkung des Verkäufers — dort steht bei
    SteinAberFein der Lagerplatz) und DESCRIPTION.
    """
    api, session = _web(store)
    to_date = datetime.now(timezone.utc).date()
    from_date = to_date - timedelta(days=max(1, last_n_days))
    raw = _wrap(
        session.orders_xml,
        direction=direction,
        from_date=None if order_id else from_date,
        to_date=None if order_id else to_date,
        order_id=str(order_id) if order_id else None,
    )
    orders = exports.parse_orders(raw, include_items=include_items)
    orders.sort(key=lambda o: o.get("order_date") or "", reverse=True)
    limit = max(1, min(limit, 200))
    shown = orders[:limit]
    truncated = 0
    if include_items:
        # Positionen über alle ausgelieferten Bestellungen hinweg kappen — sonst
        # entscheidet die Bestellgröße darüber, ob die Antwort den Kontext sprengt.
        budget = max(10, min(max_items, 2000))
        for order in shown:
            items = order.get("items") or []
            if budget <= 0:
                truncated += len(items)
                order["items"] = []
                order["items_omitted"] = len(items)
            elif len(items) > budget:
                truncated += len(items) - budget
                order["items"] = items[:budget]
                order["items_omitted"] = len(items) - budget
                budget = 0
            else:
                budget -= len(items)
    return _stamp(
        api,
        {
            "source": "orderExcelFinal.asp (XML-Export)",
            "api_requests_used": 0,
            "period": None if order_id else f"{from_date.isoformat()}..{to_date.isoformat()}",
            "count": len(orders),
            "returned": min(len(orders), limit),
            "items_truncated": truncated,
            "orders": shown,
            **({"csv": _orders_csv(shown, include_items)} if as_csv else {}),
        },
    )


def _orders_csv(orders: list[dict[str, Any]], include_items: bool) -> str:
    if not include_items:
        return exports.to_csv(
            orders,
            columns=[
                "orderid",
                "order_date",
                "orderstatus",
                "buyer",
                "lots",
                "items_total",
                "basegrandtotal",
                "basecurrencycode",
                "ordertrackno",
            ],
        )
    # Eine Zeile pro Position — das ist die Form, die man für eine Pickliste braucht.
    rows: list[dict[str, Any]] = []
    for order in orders:
        for item in order.get("items") or []:
            rows.append(
                {
                    "orderid": order.get("orderid"),
                    "order_date": order.get("order_date"),
                    "orderstatus": order.get("orderstatus"),
                    "buyer": order.get("buyer"),
                    **item,
                }
            )
    return exports.to_csv(
        rows,
        columns=[
            "orderid",
            "order_date",
            "orderstatus",
            "buyer",
            "itemtype",
            "itemid",
            "color",
            "condition",
            "qty",
            "price",
            "remarks",
            "description",
            "lotid",
            "weight",
        ],
    )


@mcp.tool
def top_selling_items(
    store: str | None = None,
    last_n_days: int = 180,
    limit: int = 20,
    by: str = "quantity",
    item_type: str | None = None,
) -> dict[str, Any]:
    """Welche Teile gehen am meisten weg — Ranking über die echten Bestellungen.

    Läuft über den Bestell-Export (EIN Web-Request, KEIN API-Kontingent) und aggregiert
    lokal pro Item und Farbe. Genau dafür ist die Rohliste der Bestellungen zu groß:
    hier kommen `limit` Zeilen zurück statt mehrerer Hundert.

    last_n_days: Betrachtungszeitraum (Default 180 Tage).
    by: "quantity" (verkaufte Stückzahl, Default), "orders" (in wie vielen Bestellungen
        das Teil vorkam) oder "revenue" (Menge × Positionspreis, ohne Versand).
    item_type: auf einen Typ einschränken, z.B. "P" für Teile oder "S" für Sets.
    """
    api, session = _web(store)
    to_date = datetime.now(timezone.utc).date()
    from_date = to_date - timedelta(days=max(1, last_n_days))
    raw = _wrap(session.orders_xml, from_date=from_date, to_date=to_date)
    orders = exports.parse_orders(raw, include_items=True)
    ranking = exports.top_selling(
        orders, limit=max(1, min(limit, 100)), by=by, item_type=item_type
    )
    return _stamp(
        api,
        {
            "source": "orderExcelFinal.asp (XML-Export)",
            "api_requests_used": 0,
            "period": f"{from_date.isoformat()}..{to_date.isoformat()}",
            **ranking,
        },
    )


@mcp.tool
def inventory_export(
    store: str | None = None,
    query: str | None = None,
    item_type: str | None = None,
    color_id: int | None = None,
    stockroom: str | None = None,
    not_sold_since_days: int | None = None,
    min_qty: int | None = None,
    limit: int = 50,
    refresh: bool = False,
    as_csv: bool = False,
) -> dict[str, Any]:
    """Komplettes Inventar aus dem XML-Export, lokal gefiltert — ohne API-Kontingent.

    Kann Dinge, die die API nicht kann, weil sie die Felder nicht hat:
      * `not_sold_since_days` — Ladenhüter finden (Feld DATELASTSOLD, API-fremd),
      * `stockroom` — "A"/"B"/"C" für ein bestimmtes Stockroom, "N" für nur die im Shop
        sichtbaren Lots,
      * Volltext über Item-Nummer, Beschreibung und Lot-Bemerkung (`query`).

    Der Export (bei SteinAberFein 7,5 MB / 12.714 Lots) wird 15 Minuten
    zwischengespeichert; `refresh=True` erzwingt einen neuen Download.
    `stats` bezieht sich immer auf das GANZE Inventar, `matches` auf den Filter.

    as_csv: liefert die Treffer zusätzlich als CSV-Text (Semikolon-getrennt) — direkt
    kopierbar in eine Tabelle. Sinnvoll für gefilterte Auszüge; für das komplette
    Inventar `export_download` benutzen.
    """
    api, session = _web(store)
    key = f"export:inventory:{api.store.slug}"
    lots = None if refresh else state.cached(key, INVENTORY_TTL)
    if lots is None:
        raw = _wrap(session.inventory_xml)
        lots = exports.parse_inventory(raw)
        state.store(key, lots)
        cached = False
    else:
        cached = True
    matches = exports.filter_inventory(
        lots,
        query=query,
        item_type=item_type,
        color_id=color_id,
        stockroom=stockroom,
        not_sold_since_days=not_sold_since_days,
        min_qty=min_qty,
    )
    limit = max(1, min(limit, 300))
    return _stamp(
        api,
        {
            "source": "invExcelFinal.asp (XML-Export)",
            "api_requests_used": 0,
            "from_cache": cached,
            "stats": exports.inventory_stats(lots),
            "matches": len(matches),
            "returned": min(len(matches), limit),
            "lots": matches[:limit],
            **(
                {
                    "csv": exports.to_csv(
                        matches[:limit],
                        columns=[
                            "itemtype",
                            "itemid",
                            "color",
                            "condition",
                            "qty",
                            "price",
                            "mycost",
                            "remarks",
                            "description",
                            "stockroom",
                            "stockroomid",
                            "date_added",
                            "date_last_sold",
                            "lotid",
                        ],
                    )
                }
                if as_csv
                else {}
            ),
        },
    )


@mcp.tool
def wanted_lists(store: str | None = None) -> dict[str, Any]:
    """Wanted Lists des Shops mit Füllstand.

    Die Store API hat dafür GAR KEINEN Endpunkt — das geht nur über den Web-Weg.
    `filled_pct` ist der Anteil, der schon beschafft ist.
    """
    api, session = _web(store)
    lists = _wrap(session.wanted_lists)
    return _stamp(
        api,
        {
            "source": "v2/wanted/list.page",
            "api_requests_used": 0,
            "count": len(lists),
            "wanted_lists": [
                {
                    "wanted_list_id": entry.get("id"),
                    "name": entry.get("name"),
                    "description": entry.get("desc"),
                    "lots": entry.get("num"),
                    "items_total": entry.get("totalNum"),
                    "items_left": entry.get("totalLeft"),
                    "filled_pct": round((entry.get("filledPct") or 0) * 100, 1),
                }
                for entry in lists
            ],
        },
    )


@mcp.tool
def wanted_list_items(
    wanted_list_id: int, store: str | None = None, limit: int = 50
) -> dict[str, Any]:
    """Positionen einer Wanted List (XML-Export). Ohne API-Kontingent.

    Felder: ITEMTYPE, ITEMID, COLOR, MINQTY, MAXPRICE, CONDITION, NOTIFY.
    `wanted_list_id` kommt aus `wanted_lists`; 0 ist die Default-Liste.
    """
    api, session = _web(store)
    raw = _wrap(session.wanted_xml, wanted_list_id)
    items = exports.parse_wanted(raw)
    limit = max(1, min(limit, 300))
    return _stamp(
        api,
        {
            "source": "files/clone/wanted/downloadXML.file",
            "api_requests_used": 0,
            "wanted_list_id": wanted_list_id,
            "count": len(items),
            "returned": min(len(items), limit),
            "items": items[:limit],
        },
    )


EXPORT_KINDS = {
    "orders": "XML: Bestellungen samt Positionen (Zeitraum über last_n_days)",
    "inventory": "XML: komplettes Store-Inventar",
    "wanted": "XML: eine Wanted List (wanted_list_id nötig)",
    "catalog_items": "XML oder TSV: alle Katalog-Items eines Typs (item_type nötig)",
    "catalog_colors": "XML: BrickLink-Farbliste",
    "catalog_categories": "XML: BrickLink-Kategorien",
    "catalog_itemtypes": "XML: BrickLink-Item-Typen",
}


@mcp.tool
def export_download(
    kind: str,
    store: str | None = None,
    fmt: str = "xml",
    last_n_days: int = 30,
    order_id: int | None = None,
    wanted_list_id: int | None = None,
    item_type: str | None = None,
) -> dict[str, Any]:
    """Holt einen Export als DATEI und legt ihn im Volume des Dienstes ab.

    Für „gib mir die Rohdaten": die Datei landet unter /data/exports im PVC. Sie kommt
    NICHT in den Chat — ein Inventar-Export sind 7,5 MB. Zurück kommen Pfad, Größe,
    Zeilen-/Knotenzahl und die ersten Zeilen als Kostprobe. Abholen auf dem Host:

        kubectl -n chat exec deploy/bricklink-mcp -- cat /data/exports/<datei> > <ziel>

    (`kubectl cp` scheitert, weil im nix:0-Image kein `tar` liegt.)

    kind: einer von orders, inventory, wanted, catalog_items, catalog_colors,
        catalog_categories, catalog_itemtypes.
    fmt: nur bei `catalog_items` wirksam — "xml" oder "tsv" (TAB-getrennt, das ist die
        CSV-artige Variante). Bestellungen und Inventar gibt BrickLink ausschließlich
        als XML heraus (viewType=T liefert dort 0 Bytes, am 2026-08-27 geprüft).
    """
    if kind not in EXPORT_KINDS:
        raise ToolError(
            "Unbekannte Export-Art "
            + repr(kind)
            + ". Möglich: "
            + ", ".join(f"{k} ({v})" for k, v in EXPORT_KINDS.items())
        )

    suffix = "xml"
    if kind.startswith("catalog"):
        # Katalog: shop-unabhängig, jedes Web-Token darf ihn ziehen.
        api = _resolve(store, for_catalog=True)
        session = web if web.configured else webs[api.store.slug]
        if kind == "catalog_items":
            if not item_type:
                raise ToolError("catalog_items braucht item_type (z.B. 'P', 'S', 'M').")
            tsv = fmt.strip().lower() in ("tsv", "csv", "tab", "t")
            raw = _wrap(session.catalog_items, item_type[:1].upper(), "T" if tsv else "X")
            suffix = "tsv" if tsv else "xml"
            name = f"catalog_items_{item_type[:1].upper()}"
        else:
            view = {"catalog_colors": 3, "catalog_categories": 2, "catalog_itemtypes": 1}[kind]
            raw = _wrap(session.catalog_view, view)
            name = kind
    else:
        api, session = _web(store)
        if kind == "orders":
            to_date = datetime.now(timezone.utc).date()
            from_date = to_date - timedelta(days=max(1, last_n_days))
            raw = _wrap(
                session.orders_xml,
                from_date=None if order_id else from_date,
                to_date=None if order_id else to_date,
                order_id=str(order_id) if order_id else None,
            )
            name = f"orders_{api.store.slug}" + (f"_{order_id}" if order_id else "")
        elif kind == "inventory":
            raw = _wrap(session.inventory_xml)
            name = f"inventory_{api.store.slug}"
        else:
            if wanted_list_id is None:
                raise ToolError("wanted braucht wanted_list_id (siehe wanted_lists).")
            raw = _wrap(session.wanted_xml, wanted_list_id)
            name = f"wanted_{api.store.slug}_{wanted_list_id}"

    os.makedirs(EXPORT_DIR, exist_ok=True)
    # Zeitstempel im Namen: Exporte sind Momentaufnahmen, ein Überschreiben würde die
    # Nachvollziehbarkeit kosten. Aufräumen macht niemand automatisch — das PVC hat 3Gi.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(EXPORT_DIR, f"{name}_{stamp}.{suffix}")
    with open(path, "wb") as fh:
        fh.write(raw)
    preview = raw[:600].decode("utf-8", errors="replace")
    link = _link_for(os.path.basename(path))
    return {
        "path": path,
        **link,
        "kind": kind,
        "format": suffix,
        "bytes": len(raw),
        "lines": raw.count(b"\n") + 1,
        "item_nodes": raw.count(b"<ITEM>"),
        "order_nodes": raw.count(b"<ORDER>"),
        "api_requests_used": 0,
        "store": None if kind.startswith("catalog") else api.store.slug,
        "fetch_hint": (
            f"kubectl -n chat exec deploy/bricklink-mcp -- cat {path} > ./{os.path.basename(path)}"
        ),
        "preview": preview,
    }


def _link_for(
    name: str, ttl_minutes: int | None = None, path: str | None = None
) -> dict[str, Any]:
    """Signierten Download-Link bauen, wenn dafür alles konfiguriert ist."""
    if not cfg.has_public_links:
        return {
            "url": None,
            "url_note": (
                "Keine öffentlichen Links konfiguriert (BRICKLINK_FILES_BASE_URL / "
                "BRICKLINK_FILES_SECRET fehlen). Datei liegt nur im Volume."
            ),
        }
    ttl = ttl_minutes if ttl_minutes is not None else cfg.files_ttl_minutes
    url, expires = links.sign(
        cfg.files_base_url, path or cfg.files_path, name, cfg.files_secret, ttl
    )
    return {
        "url": url,
        "url_expires_at": datetime.fromtimestamp(expires, tz=timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "url_valid_minutes": max(1, min(int(ttl), links.MAX_TTL_MINUTES)),
        "url_note": (
            "Der Link ist signiert und läuft ab. Wer ihn hat, kommt an die Datei — also "
            "wie ein Passwort behandeln und nicht in Gruppenchats posten."
        ),
    }


@mcp.tool
def export_link(name: str, ttl_minutes: int = 60) -> dict[str, Any]:
    """Neuen Download-Link für eine bereits erzeugte Export-Datei.

    name: Dateiname aus `exports_list` (nicht der ganze Pfad).
    ttl_minutes: Gültigkeit, Default 60, maximal 1440 (ein Tag).

    Der Link enthält eine Signatur und ein Ablaufdatum; nginx prüft beides, bevor es
    überhaupt auf die Platte schaut. Abgelaufen = HTTP 410, falsch signiert = 404.
    """
    base = os.path.basename(name.strip())
    if not base or base != name.strip():
        raise ToolError("name muss ein reiner Dateiname sein, kein Pfad.")
    full = os.path.join(EXPORT_DIR, base)
    if not os.path.isfile(full):
        available = sorted(os.listdir(EXPORT_DIR)) if os.path.isdir(EXPORT_DIR) else []
        raise ToolError(
            f"Datei {base!r} liegt nicht im Export-Verzeichnis. Vorhanden: "
            + (", ".join(available[:20]) or "(keine)")
        )
    if not cfg.has_public_links:
        raise ToolError(
            "Öffentliche Links sind nicht konfiguriert (BRICKLINK_FILES_BASE_URL / "
            "BRICKLINK_FILES_SECRET). Die Datei liegt unter " + full
        )
    return {
        "name": base,
        "bytes": os.path.getsize(full),
        **_link_for(base, ttl_minutes),
    }


@mcp.tool
def workspace_list(limit: int = 50) -> dict[str, Any]:
    """Was im Arbeitsverzeichnis der Code-Sandbox liegt (`/data/workspace`).

    Dort schreibt der Code-Interpreter seine Ergebnisse — ausgefüllte PDFs,
    Diagramme, Tabellen. Von hier führt `workspace_link` zu einem Download-Link.
    Neueste zuerst.
    """
    if not os.path.isdir(WORKSPACE_DIR):
        return {"count": 0, "dir": WORKSPACE_DIR, "files": [], "note": "noch nichts erzeugt"}
    entries = []
    for name in os.listdir(WORKSPACE_DIR):
        full = os.path.join(WORKSPACE_DIR, name)
        if not os.path.isfile(full) or name.startswith("."):
            continue
        entries.append(
            {
                "name": name,
                "bytes": os.path.getsize(full),
                "modified": datetime.fromtimestamp(
                    os.path.getmtime(full), tz=timezone.utc
                ).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        )
    entries.sort(key=lambda e: e["modified"], reverse=True)
    limit = max(1, min(limit, 200))
    return {
        "count": len(entries),
        "returned": min(len(entries), limit),
        "dir": WORKSPACE_DIR,
        "files": entries[:limit],
    }


@mcp.tool
def workspace_link(name: str, ttl_minutes: int = 60) -> dict[str, Any]:
    """Download-Link für eine Datei aus dem Arbeitsverzeichnis der Sandbox.

    Genau das, was in der pyodide-Welt gefehlt hat: die Datei liegt auf dem Server,
    nicht im Browser, und der Link ist von jedem Gerät abrufbar.

    name: Dateiname aus `workspace_list` (kein Pfad).
    ttl_minutes: Gültigkeit, Default 60, maximal 1440.
    """
    base = os.path.basename(name.strip())
    if not base or base != name.strip():
        raise ToolError("name muss ein reiner Dateiname sein, kein Pfad.")
    full = os.path.join(WORKSPACE_DIR, base)
    if not os.path.isfile(full):
        available = (
            sorted(n for n in os.listdir(WORKSPACE_DIR) if not n.startswith("."))
            if os.path.isdir(WORKSPACE_DIR)
            else []
        )
        raise ToolError(
            f"Datei {base!r} liegt nicht im Arbeitsverzeichnis. Vorhanden: "
            + (", ".join(available[:20]) or "(keine)")
        )
    if not cfg.has_public_links:
        raise ToolError(
            "Öffentliche Links sind nicht konfiguriert. Die Datei liegt unter " + full
        )
    return {
        "name": base,
        "bytes": os.path.getsize(full),
        **_link_for(base, ttl_minutes, path=cfg.files_workspace_path),
    }


@mcp.tool
def exports_list() -> dict[str, Any]:
    """Welche Export-Dateien liegen im Volume (aus früheren `export_download`-Aufrufen).

    Links werden hier bewusst NICHT mitgeliefert — sonst entstünde für jede Datei ein
    gültiger Link, nur weil jemand die Liste sehen wollte. Einen Link gibt es gezielt
    über `export_link`.
    """
    if not os.path.isdir(EXPORT_DIR):
        return {"count": 0, "files": [], "dir": EXPORT_DIR}
    files = []
    for entry in sorted(os.listdir(EXPORT_DIR), reverse=True):
        full = os.path.join(EXPORT_DIR, entry)
        if os.path.isfile(full):
            files.append(
                {
                    "name": entry,
                    "bytes": os.path.getsize(full),
                    "modified": datetime.fromtimestamp(
                        os.path.getmtime(full), tz=timezone.utc
                    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }
            )
    return {"count": len(files), "dir": EXPORT_DIR, "files": files[:50]}


# ── Betrieb ────────────────────────────────────────────────────────────────


@mcp.tool
def notifications(store: str | None = None, limit: int = 25) -> dict[str, Any]:
    """Ungelesene BrickLink-Push-Benachrichtigungen eines Shops (neue Bestellung,
    Statusänderung durch den Käufer, geänderte Positionen, neue Nachricht, neues
    Feedback).

    ⚠️ EINMALIG: BrickLink liefert jede Benachrichtigung nur bei EINEM Abruf. Danach
    ist die Liste leer — am 2026-08-27 verifiziert (erst 159, direkt danach 0). Wer
    also etwas mit dem Ergebnis vorhat, muss es in derselben Antwort verarbeiten;
    ein zweiter Aufruf holt es nicht zurück.

    BrickLink garantiert die Zustellung außerdem ausdrücklich NICHT — für den
    verlässlichen Stand `orders_dashboard` benutzen. `by_event_type` fasst zusammen,
    `limit` begrenzt die Ausgabe.
    """
    api = _resolve(store)
    data = _wrap(api.notifications)
    by_event: dict[str, int] = {}
    for n in data:
        key = str(n.get("event_type") or "?")
        by_event[key] = by_event.get(key, 0) + 1
    limit = max(1, min(limit, 200))
    return _stamp(
        api,
        {
            "count": len(data),
            "returned": min(len(data), limit),
            "by_event_type": dict(sorted(by_event.items())),
            "notifications": data[:limit],
        },
    )


@mcp.tool
def shipping_methods(store: str | None = None) -> dict[str, Any]:
    """Die im Shop konfigurierten Versandarten (mit method_id)."""
    api = _resolve(store)
    data = _wrap(api.shipping_methods)
    return _stamp(api, {"count": len(data), "shipping_methods": data})


@mcp.tool
def api_quota(store: str | None = None) -> dict[str, Any]:
    """Verbrauchte BrickLink-API-Requests heute, Budget und Restkontingent.

    Das Limit gilt pro Shop (es hängt am Consumer-Key). Ohne `store` kommt der
    Stand ALLER Shops.
    """
    if store:
        api = _resolve(store)
        return state.usage(api.store.slug)
    return {"stores": [state.usage(s.slug) for s in cfg.stores]}


@mcp.tool
def catalog_status() -> dict[str, Any]:
    """Zustand des Offline-Katalogindex: Alter, Item-Zahlen, Größe. Shop-unabhängig."""
    st = catalog.status()
    st["refresh_interval_days"] = cfg.catalog_refresh_days
    st["web_token_configured"] = cfg.has_web_session
    return st


@mcp.tool
def catalog_refresh() -> dict[str, Any]:
    """Baut den Offline-Katalogindex neu aus dem offiziellen BrickLink-Katalog-Export.

    Dauert einige Minuten und braucht ein gültiges BrickLink-Web-Token
    (30 Tage Laufzeit). Kostet KEIN API-Kontingent und gilt für alle Shops
    gemeinsam — der Katalog ist shop-unabhängig.
    """
    return _wrap(catalog.refresh, web)


@mcp.custom_route("/health", methods=["GET"])
async def health(_request):  # noqa: ANN001 - Starlette-Request
    from starlette.responses import JSONResponse

    return JSONResponse(
        {
            "status": "ok",
            "catalog": catalog.status().get("present", False),
            "stores": [s.slug for s in cfg.stores],
        }
    )


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
    if not cfg.stores:
        log.error("BRICKLINK_STORES ist leer — es gibt keinen Shop, alle Tools werden ablehnen")
    for s in cfg.stores:
        if not s.usable:
            log.warning("Shop %s (%s): keine API-Credentials hinterlegt", s.slug, s.label)
        elif not s.username:
            log.warning(
                "Shop %s: kein BL-Benutzername — der Verkäufer-Guard kann nicht prüfen, "
                "ob eine Bestellung zu diesem Shop gehört",
                s.slug,
            )
        else:
            log.info("Shop %s (%s) als %s bereit", s.slug, s.label, s.username)
    if cfg.user_defaults:
        log.info("Nutzer-Defaults: %s", cfg.user_defaults)
    else:
        log.warning(
            "Keine Nutzer-Defaults gesetzt — jeder store-bezogene Aufruf braucht "
            "eine ausdrückliche Shop-Angabe"
        )
    # Verzeichnisse anlegen, bevor jemand sie braucht: nginx `alias` auf ein
    # fehlendes Verzeichnis endet in 404, und die Sandbox startet mit cd dorthin.
    for path in (EXPORT_DIR, WORKSPACE_DIR):
        try:
            os.makedirs(path, exist_ok=True)
        except OSError as exc:
            log.warning("Verzeichnis %s nicht anlegbar: %s", path, exc)
    threading.Thread(target=_refresher, name="catalog-refresh", daemon=True).start()
    mcp.run(transport="http", host=cfg.host, port=cfg.port, path=cfg.path)


if __name__ == "__main__":
    main()
