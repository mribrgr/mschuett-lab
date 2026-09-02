"""Parser für BrickLinks XML-Exporte.

Warum überhaupt: die Exporte liefern in EINEM Web-Request, was über die Store API
viele Requests kostet — und teils Felder, die die API nicht hat. Sie belasten das
Tageskontingent der API NICHT (sie laufen über die Web-Session).

Am 2026-08-27 gegen den echten Shop verifizierte Strukturen:

  orderExcelFinal.asp  <ORDERS><ORDER>  Kopfdaten + geschachtelte <ITEM>-Knoten
                       Kopf: ORDERID, ORDERDATE, ORDERSTATUSCHANGED, BUYER,
                             ORDERSHIPPING, ORDERINSURANCE, ORDERADDCHRG1/2,
                             ORDERCREDIT, ORDERCREDITCOUPON, ORDERTOTAL,
                             ORDERSALESTAX, ORDERVAT, BASECURRENCYCODE,
                             BASEGRANDTOTAL, PAYCURRENCYCODE, ORDERLOTS, ORDERITEMS,
                             ORDERCOST, ORDERSTATUS, PAYMENTTYPE, ORDERREMARKS,
                             ORDERTRACKNO, LOCATION, VATCHARGES
                       Position: ORDERITEMID, ORDERBATCH, CATEGORY, COLOR, PRICE, QTY,
                             BULK, IMAGE, DESCRIPTION, CONDITION, ITEMTYPE, ITEMID,
                             REMARKS, WEIGHT, LOTID, MYCOST
  invExcelFinal.asp    <INVENTORY><ITEM>  LOTID, DATEADDED, DATELASTSOLD, CATEGORY,
                             COLOR, PRICE, QTY, BULK, DESCRIPTION, REMARKS, CONDITION,
                             SUBCONDITION, ITEMTYPE, ITEMID, ITEMWEIGHT, MYCOST, SALE,
                             RETAIN, STOCKROOM, STOCKROOMID, EXTENDED, INVDIMX/Y/Z
  downloadXML.file     <INVENTORY><ITEM>  ITEMTYPE, ITEMID, COLOR, MAXPRICE, MINQTY,
                             CONDITION, NOTIFY (Wanted List)

DATELASTSOLD und die INVDIM*-Maße gibt es NUR im Export, nicht in der API.
"""

from __future__ import annotations

import csv
import io
import re
from datetime import date, datetime
from typing import Any, Iterator
from xml.etree import ElementTree as ET

# Gleiche Reparatur wie im Katalog-Parser: BrickLink liefert gelegentlich nackte `&`.
_BARE_AMP = re.compile(rb"&(?!(?:#\d+|#x[0-9a-fA-F]+|amp|lt|gt|quot|apos);)")


def _sanitize(raw: bytes) -> bytes:
    return _BARE_AMP.sub(b"&amp;", raw)


def _scalars(node: ET.Element, skip: set[str] = frozenset()) -> dict[str, str]:
    out: dict[str, str] = {}
    for child in node:
        if child.tag in skip or len(child):
            continue
        text = (child.text or "").strip()
        if text:
            out[child.tag.lower()] = text
    return out


def _nodes(raw: bytes, tag: str) -> Iterator[ET.Element]:
    """Streamt Knoten eines Tags. iterparse, weil das Inventar 7,5 MB groß ist."""
    if not raw.strip():
        return
    context = ET.iterparse(io.BytesIO(_sanitize(raw)), events=("start", "end"))
    _event, root = next(context)
    for event, node in context:
        if event != "end" or node.tag != tag:
            continue
        yield node
        root.clear()


def us_date(value: str | None) -> str | None:
    """BrickLinks MM/DD/YYYY in ISO. Ungültiges bleibt unverändert."""
    if not value:
        return None
    for fmt in ("%m/%d/%Y", "%m/%d/%y"):
        try:
            return datetime.strptime(value.strip(), fmt).date().isoformat()
        except ValueError:
            continue
    return value


def _num(value: str | None) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def parse_orders(raw: bytes, include_items: bool = True) -> list[dict[str, Any]]:
    orders: list[dict[str, Any]] = []
    for node in _nodes(raw, "ORDER"):
        order = _scalars(node, skip={"ITEM"})
        order["order_date"] = us_date(order.get("orderdate"))
        order["status_changed"] = us_date(order.get("orderstatuschanged"))
        items = [_scalars(item) for item in node.findall("ITEM")]
        order["lots"] = len(items)
        order["items_total"] = sum(int(_num(i.get("qty"))) for i in items)
        if include_items:
            order["items"] = items
        orders.append(order)
    return orders


def parse_inventory(raw: bytes) -> list[dict[str, Any]]:
    lots: list[dict[str, Any]] = []
    for node in _nodes(raw, "ITEM"):
        lot = _scalars(node)
        lot["date_added"] = us_date(lot.get("dateadded"))
        lot["date_last_sold"] = us_date(lot.get("datelastsold"))
        lots.append(lot)
    return lots


def parse_wanted(raw: bytes) -> list[dict[str, Any]]:
    return [_scalars(node) for node in _nodes(raw, "ITEM")]


def inventory_stats(lots: list[dict[str, Any]]) -> dict[str, Any]:
    """Kennzahlen über einen geparsten Inventar-Export."""
    qty = 0
    value = 0.0
    cost = 0.0
    by_location: dict[str, int] = {}
    never_sold = 0
    for lot in lots:
        q = int(_num(lot.get("qty")))
        qty += q
        value += q * _num(lot.get("price"))
        cost += q * _num(lot.get("mycost"))
        if (lot.get("stockroom") or "N").upper() == "Y":
            where = f"stockroom_{lot.get('stockroomid') or '?'}"
        elif (lot.get("retain") or "N").upper() == "Y":
            where = "retain"
        else:
            where = "for_sale"
        by_location[where] = by_location.get(where, 0) + 1
        if not lot.get("date_last_sold"):
            never_sold += 1
    return {
        "lots": len(lots),
        "quantity": qty,
        "list_value": round(value, 2),
        "cost_value": round(cost, 2),
        "by_location": dict(sorted(by_location.items())),
        "never_sold_lots": never_sold,
    }


def filter_inventory(
    lots: list[dict[str, Any]],
    query: str | None = None,
    item_type: str | None = None,
    color_id: int | None = None,
    stockroom: str | None = None,
    not_sold_since_days: int | None = None,
    min_qty: int | None = None,
) -> list[dict[str, Any]]:
    """Lokale Filter über den Export — kostet keinen weiteren Request."""
    needle = (query or "").strip().lower()
    out = []
    today = date.today()
    for lot in lots:
        if needle:
            haystack = " ".join(
                str(lot.get(k, "")) for k in ("itemid", "description", "remarks")
            ).lower()
            if needle not in haystack:
                continue
        if item_type and (lot.get("itemtype") or "").upper() != item_type[:1].upper():
            continue
        if color_id is not None and str(lot.get("color") or "") != str(color_id):
            continue
        if stockroom:
            want = stockroom.strip().upper()
            if want in ("N", "NO", "FALSE"):
                if (lot.get("stockroom") or "N").upper() == "Y":
                    continue
            elif (lot.get("stockroom") or "N").upper() != "Y" or (
                lot.get("stockroomid") or ""
            ).upper() != want:
                continue
        if not_sold_since_days is not None:
            sold = lot.get("date_last_sold")
            if sold:
                try:
                    age = (today - date.fromisoformat(sold)).days
                except ValueError:
                    age = 0
                if age < not_sold_since_days:
                    continue
        if min_qty is not None and int(_num(lot.get("qty"))) < min_qty:
            continue
        out.append(lot)
    return out


def to_csv(rows: list[dict[str, Any]], columns: list[str] | None = None) -> str:
    """Gefilterte Zeilen als CSV (Semikolon, wie Excel es im deutschen Locale erwartet).

    Für den Chat gedacht: ein gefilterter Auszug ist klein genug, um ihn direkt
    auszugeben und in eine Tabelle zu kopieren. Der VOLLE Export gehört nicht in den
    Chat (7,5 MB) — dafür `export_download`.
    """
    if not rows:
        return ""
    if columns is None:
        seen: list[str] = []
        for row in rows:
            for key in row:
                if key not in seen and not isinstance(row[key], (list, dict)):
                    seen.append(key)
        columns = seen
    out = io.StringIO()
    writer = csv.DictWriter(
        out, fieldnames=columns, delimiter=";", extrasaction="ignore", lineterminator="\n"
    )
    writer.writeheader()
    for row in rows:
        writer.writerow({k: row.get(k, "") for k in columns})
    return out.getvalue()


def top_selling(
    orders: list[dict[str, Any]],
    limit: int = 20,
    by: str = "quantity",
    item_type: str | None = None,
) -> dict[str, Any]:
    """Verkaufsranking über einen geparsten Bestell-Export.

    Beantwortet „welche Teile gehen bei mir am meisten weg" — die Frage, für die man
    sonst jede Bestellung einzeln durch die API ziehen müsste. Aggregiert wird pro
    (Item-Typ, Item-Nummer, Farbe); der Umsatz ist Menge × Positionspreis, also ohne
    Versand und Rabatte.
    """
    buckets: dict[tuple[str, str, str], dict[str, Any]] = {}
    counted_orders = 0
    for order in orders:
        items = order.get("items") or []
        if items:
            counted_orders += 1
        for item in items:
            itype = (item.get("itemtype") or "?").upper()
            if item_type and itype != item_type[:1].upper():
                continue
            key = (itype, item.get("itemid") or "?", item.get("color") or "")
            bucket = buckets.setdefault(
                key,
                {
                    "item_type": key[0],
                    "item_no": key[1],
                    "color": key[2],
                    "quantity": 0,
                    "orders": 0,
                    "revenue": 0.0,
                    "description": item.get("description") or "",
                    "condition": item.get("condition") or "",
                },
            )
            qty = int(_num(item.get("qty")))
            bucket["quantity"] += qty
            bucket["orders"] += 1
            bucket["revenue"] = round(bucket["revenue"] + qty * _num(item.get("price")), 2)

    key_fn = {
        "quantity": lambda b: (b["quantity"], b["revenue"]),
        "orders": lambda b: (b["orders"], b["quantity"]),
        "revenue": lambda b: (b["revenue"], b["quantity"]),
    }.get(by, lambda b: (b["quantity"], b["revenue"]))
    ranked = sorted(buckets.values(), key=key_fn, reverse=True)
    return {
        "orders_considered": counted_orders,
        "distinct_items": len(buckets),
        "sorted_by": by if by in ("quantity", "orders", "revenue") else "quantity",
        "top": ranked[:limit],
    }
