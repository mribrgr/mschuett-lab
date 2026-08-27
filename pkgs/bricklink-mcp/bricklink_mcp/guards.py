"""Schreib-Guards.

Bewusste Einschränkung (Anforderung 2026-08-27): über den MCP sind GENAU zwei
Statusübergänge erlaubt — der Weg „bezahlt/neu" → PACKED und PACKED → SHIPPED.
Alles andere (CANCELLED, NPB, OCR, COMPLETED, Zurückdrehen) bleibt der Web-UI
vorbehalten, damit ein Modell keinen Bestellzustand kaputtmachen kann, den
BrickLink nicht wieder herstellt.

BrickLink prüft zusätzlich selbst und antwortet auf verbotene Übergänge mit
„attempt to update an order status to unavailable value" — dieser Guard ist die
erste, nicht die einzige Schranke.
"""

from __future__ import annotations

# Quellstatus, aus denen wir auf PACKED gehen dürfen. PENDING/UPDATED/PROCESSING/
# READY deckt „frisch bestellt, noch nicht bezahlt" ab, PAID den Normalfall.
PACKED_FROM = {"PENDING", "UPDATED", "PROCESSING", "READY", "PAID"}
SHIPPED_FROM = {"PACKED"}

ALLOWED: dict[str, set[str]] = {"PACKED": PACKED_FROM, "SHIPPED": SHIPPED_FROM}


class NotAllowed(RuntimeError):
    pass


def check_transition(order: dict, target: str, store_username: str) -> None:
    current = (order.get("status") or "").upper()
    seller = order.get("seller_name") or ""
    order_id = order.get("order_id")

    if store_username and seller.casefold() != store_username.casefold():
        raise NotAllowed(
            f"Bestellung {order_id} hat seller_name={seller!r} — das ist keine Bestellung "
            f"aus dem Store {store_username!r}. Schreibzugriffe sind nur auf EIGENE "
            "Verkäufe erlaubt (bei Einkäufen wäre man der Käufer)."
        )

    sources = ALLOWED.get(target)
    if sources is None:
        raise NotAllowed(
            f"Statuswechsel auf {target} ist über diesen MCP nicht vorgesehen. "
            f"Erlaubt sind nur: {', '.join(sorted(ALLOWED))}."
        )
    if current == target:
        raise NotAllowed(f"Bestellung {order_id} steht bereits auf {target}.")
    if current not in sources:
        raise NotAllowed(
            f"Bestellung {order_id} steht auf {current}; {target} ist nur aus "
            f"{', '.join(sorted(sources))} erlaubt. Für alles andere die Web-UI benutzen."
        )
