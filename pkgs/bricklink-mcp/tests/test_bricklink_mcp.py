"""Tests ohne Netz. Läuft im nix-`checkPhase` und lokal:

    BRICKLINK_DATA_DIR=$(mktemp -d) PYTHONPATH=. python tests/test_bricklink_mcp.py
"""

import asyncio
import json
import os
import tempfile

os.environ.setdefault("BRICKLINK_DATA_DIR", tempfile.mkdtemp())
# Zwei Shops, damit die Trennung überhaupt prüfbar ist. MUSS vor dem Import von
# bricklink_mcp.server stehen — die Config wird beim Import gelesen.
os.environ["BRICKLINK_STORES"] = "steinaberfein:SteinAberFein,dinoland:Dinoland"
for slug, user in (("STEINABERFEIN", "SteinAberFein"), ("DINOLAND", "Dinoland")):
    os.environ[f"BRICKLINK_STORE_{slug}_USERNAME"] = user
    for part in ("CONSUMER_KEY", "CONSUMER_SECRET", "TOKEN_VALUE", "TOKEN_SECRET"):
        os.environ[f"BRICKLINK_STORE_{slug}_{part}"] = f"{slug.lower()}-{part.lower()}"
os.environ["BRICKLINK_USER_DEFAULTS"] = "mschuett@example.org=steinaberfein,Max Schütt=steinaberfein"

from bricklink_mcp.catalog import Catalog  # noqa: E402
from bricklink_mcp.config import Config, Store  # noqa: E402
from bricklink_mcp.guards import NotAllowed, check_seller, check_transition  # noqa: E402
from bricklink_mcp.state import Quota, State  # noqa: E402

TYPES = b"""<CATALOG>
<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMTYPENAME>Part</ITEMTYPENAME></ITEM>
<ITEM><ITEMTYPE>S</ITEMTYPE><ITEMTYPENAME>Set</ITEMTYPENAME></ITEM>
</CATALOG>"""
CATS = b"""<CATALOG>
<ITEM><CATEGORY>5</CATEGORY><CATEGORYNAME>Brick</CATEGORYNAME></ITEM>
<ITEM><CATEGORY>7</CATEGORY><CATEGORYNAME>Duplo & Explore</CATEGORYNAME></ITEM>
</CATALOG>"""
COLORS = b"""<?xml version="1.0" encoding="ISO-8859-1"?>
<CATALOG>
<ITEM><COLOR>11</COLOR><COLORNAME>Black</COLORNAME><COLORRGB>212121</COLORRGB><COLORTYPE>Solid</COLORTYPE></ITEM>
<ITEM><COLOR>5</COLOR><COLORNAME>Red</COLORNAME><COLORRGB>C91A09</COLORRGB><COLORTYPE>Solid</COLORTYPE></ITEM>
</CATALOG>"""
ITEMS_P = b"""<?xml version="1.0" encoding="UTF-8"?>
<CATALOG>
<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>3001</ITEMID><ITEMNAME>Brick 2 x 4</ITEMNAME><CATEGORY>5</CATEGORY><ITEMYEAR>1958</ITEMYEAR><ITEMWEIGHT>2.3</ITEMWEIGHT><ALTITEMIDS>3001old</ALTITEMIDS><IMAGECOLOR>11</IMAGECOLOR></ITEM>
<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>3003</ITEMID><ITEMNAME>Brick 2 x 2 & Friends</ITEMNAME><CATEGORY>5</CATEGORY><ITEMYEAR>1963</ITEMYEAR><ITEMWEIGHT>1.2</ITEMWEIGHT></ITEM>
<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>2356</ITEMID><ITEMNAME>Brick 4 x 6</ITEMNAME><CATEGORY>5</CATEGORY></ITEM>
<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>30011</ITEMID><ITEMNAME>Panel 1 x 2 x 3</ITEMNAME><CATEGORY>5</CATEGORY></ITEM>
<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>31111pb010</ITEMID><ITEMNAME>Duplo, Brick 2 x 4 x 2 with Bricks Pattern</ITEMNAME><CATEGORY>5</CATEGORY></ITEM>
<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>48201</ITEMID><ITEMNAME>Quatro Brick 2 x 4</ITEMNAME><CATEGORY>5</CATEGORY></ITEM>
</CATALOG>"""
ITEMS_S = b"""<CATALOG>
<ITEM><ITEMTYPE>S</ITEMTYPE><ITEMID>7644-1</ITEMID><ITEMNAME>MX-81 Hypersonic Operations Aircraft</ITEMNAME><CATEGORY>7</CATEGORY><ITEMYEAR>2007</ITEMYEAR></ITEM>
</CATALOG>"""


class FakeWeb:
    def catalog_view(self, which):
        return {1: TYPES, 2: CATS, 3: COLORS}[which]

    def catalog_items(self, type_id):
        return {"P": ITEMS_P, "S": ITEMS_S}[type_id]


def test_catalog():
    path = os.path.join(os.environ["BRICKLINK_DATA_DIR"], "catalog.db")
    cat = Catalog(path)
    assert cat.stale(7) is True, "leerer Index muss stale sein"
    res = cat.refresh(FakeWeb())
    assert res["items_total"] == 7, res
    assert res["failed_types"] == {} and res["ok"] is True, res
    st = cat.status()
    assert st["present"] and st["items_per_type"] == {"P": 6, "S": 1}, st
    assert cat.stale(7) is False

    # Ranking: "Brick 4 x 6" könnte über item_no 2356 auf "2*" matchen — darf es nicht,
    # kurze Tokens werden exakt gesucht. Und der exakte NAME gewinnt gegen die
    # Duplo-/Quatro-Varianten, die den Suchstring ebenfalls enthalten.
    hits = cat.search(query="brick 2 x 4")
    assert hits[0]["item_no"] == "3001", [h["item_no"] for h in hits]
    assert "2356" not in [h["item_no"] for h in hits], [h["item_no"] for h in hits]
    assert set([h["item_no"] for h in hits][1:3]) == {"48201", "31111pb010"}, [
        h["item_no"] for h in hits
    ]
    # Exakte Nummer gewinnt gegen den Prefix-Treffer 30011
    exact = cat.search(query="3001")
    assert exact[0]["item_no"] == "3001", [h["item_no"] for h in exact]
    assert "30011" in [h["item_no"] for h in exact]
    # nackte & im Namen dürfen den Parser nicht killen
    amp = cat.search(query="Friends")
    assert amp[0]["name"] == "Brick 2 x 2 & Friends", amp
    assert any(c["name"] == "Duplo & Explore" for c in cat.categories()), cat.categories()
    # Alt-ID ist suchbar
    assert cat.search(query="3001old")[0]["item_no"] == "3001"
    # Typfilter + Jahresfilter + Kategoriefilter
    assert cat.search(item_type="Set")[0]["item_no"] == "7644-1"
    assert cat.search(query="brick", year_max=1960)[0]["item_no"] == "3001"
    assert len(cat.search(query="brick")) == 5
    assert len(cat.search(category="Brick")) == 6
    print("catalog: ok")


def test_stores_config():
    cfg = Config.from_env()
    assert [s.slug for s in cfg.stores] == ["steinaberfein", "dinoland"], cfg.stores
    # Auflösung über Slug, Anzeigename und BL-Benutzernamen, case-insensitiv
    for key in ("steinaberfein", "SteinAberFein", "STEINABERFEIN"):
        assert cfg.store(key).slug == "steinaberfein", key
    assert cfg.store("dinoland").label == "Dinoland"
    assert cfg.store("gibtsnicht") is None
    assert cfg.store("") is None and cfg.store(None) is None
    # Nutzer-Default über E-Mail UND Anzeigename
    assert cfg.default_store_for("mschuett@example.org", None).slug == "steinaberfein"
    assert cfg.default_store_for(None, "max schütt").slug == "steinaberfein"
    assert cfg.default_store_for("fremder@example.org", "Fremd") is None
    assert cfg.default_store_for(None, None) is None
    # Ein Shop ohne Credentials ist konfiguriert, aber nicht benutzbar
    leer = Store("x", "X", "", "", "", "", "")
    assert leer.usable is False and Store("x", "X", "u", "a", "b", "c", "d").usable is True
    print("stores config: ok")


def test_guards():
    own = "SteinAberFein"
    ok = {"order_id": 1, "status": "PAID", "seller_name": own}
    check_transition(ok, "PACKED", own, "SteinAberFein")
    for order, target, needle in [
        ({"order_id": 2, "status": "SHIPPED", "seller_name": own}, "PACKED", "nur aus"),
        ({"order_id": 3, "status": "PACKED", "seller_name": own}, "PACKED", "bereits"),
        ({"order_id": 5, "status": "PAID", "seller_name": own}, "SHIPPED", "nur aus"),
        ({"order_id": 6, "status": "PAID", "seller_name": own}, "CANCELLED", "nicht vorgesehen"),
    ]:
        try:
            check_transition(order, target, own, "SteinAberFein")
        except NotAllowed as exc:
            assert needle in str(exc), (target, str(exc))
        else:
            raise AssertionError(f"{target} aus {order['status']} haette scheitern muessen")
    check_transition({"order_id": 7, "status": "PACKED", "seller_name": own}, "SHIPPED", own, "S")

    # DER Shop-Guard: eine Bestellung des anderen Shops darf nicht angefasst werden
    fremd = {"order_id": 8, "status": "PAID", "seller_name": "Dinoland"}
    for fn, args in (
        (check_transition, (fremd, "PACKED", own, "SteinAberFein")),
        (check_seller, (fremd, own, "SteinAberFein")),
    ):
        try:
            fn(*args)
        except NotAllowed as exc:
            assert "Dinoland" in str(exc) and "NICHTS" in str(exc) or "Schreibzugriffe" in str(exc), str(exc)
        else:
            raise AssertionError("fremder Shop haette scheitern muessen")
    # und umgekehrt genauso
    check_seller({"order_id": 9, "seller_name": "Dinoland"}, "Dinoland", "Dinoland")
    print("guards: ok")


def test_state_migration():
    """Bestandsdatei mit ALTEM Quota-Schema muss weiterlaufen, nicht crashen."""
    import sqlite3

    path = os.path.join(tempfile.mkdtemp(), "state.db")
    legacy = sqlite3.connect(path)
    legacy.executescript(
        """
        CREATE TABLE quota (day TEXT PRIMARY KEY, calls INTEGER NOT NULL);
        CREATE TABLE cache (key TEXT PRIMARY KEY, ts INTEGER NOT NULL, body TEXT NOT NULL);
        INSERT INTO quota (day, calls) VALUES ('2026-08-01', 42);
        """
    )
    legacy.commit()
    legacy.close()

    st = State(path, daily_budget=100)
    # Migration hat die Spalte ergänzt und die Altzeile behalten (ohne Shop-Zuordnung)
    st.spend("steinaberfein", 3)
    assert st.usage("steinaberfein")["used"] == 3
    assert st.usage("dinoland")["used"] == 0
    rows = dict(
        (row[0], row[1])
        for row in sqlite3.connect(path).execute("SELECT store, calls FROM quota ORDER BY store")
    )
    assert rows.get("") == 42, rows
    assert rows.get("steinaberfein") == 3, rows
    print("state migration: ok")


def test_state():
    st = State(os.path.join(os.environ["BRICKLINK_DATA_DIR"], "state.db"), daily_budget=3)
    st.spend("shopA", 2)
    assert st.usage("shopA")["remaining"] == 1
    # Kontingent ist PRO SHOP: shopB ist davon unberührt
    assert st.usage("shopB")["remaining"] == 3, st.usage("shopB")
    st.spend("shopB", 3)
    assert st.usage("shopB")["remaining"] == 0
    try:
        st.spend("shopA", 2)
    except Quota as exc:
        assert "shopA" in str(exc) and "erschöpft" in str(exc)
    else:
        raise AssertionError("Quota haette greifen muessen")
    st.spend("shopA", 1)
    assert st.usage("shopA")["remaining"] == 0
    st.store("k", {"a": 1})
    assert st.cached("k", 60) == {"a": 1}
    assert st.cached("k", 0) is None
    assert st.cached("nope", 60) is None
    print("state: ok")


def test_store_resolution():
    from fastmcp.exceptions import ToolError

    from bricklink_mcp import server

    # ausdrücklich angegeben
    assert server._resolve("dinoland").store.slug == "dinoland"
    assert server._resolve("SteinAberFein").store.slug == "steinaberfein"
    # unbekannter Shop -> Fehler, der die Auswahl nennt
    try:
        server._resolve("legoland")
    except ToolError as exc:
        assert "legoland" in str(exc) and "dinoland" in str(exc) and "nachfragen" in str(exc)
    else:
        raise AssertionError("unbekannter Shop haette scheitern muessen")

    # ohne Shop und ohne bekannten Aufrufer -> ABLEHNEN, nicht raten
    server._caller = lambda: (None, None)
    try:
        server._resolve(None)
    except ToolError as exc:
        assert "FRAGE DEN NUTZER" in str(exc), str(exc)
    else:
        raise AssertionError("ohne Shop haette es scheitern muessen")
    # ... bei Katalogabfragen ist der Shop egal, da darf gefallbackt werden
    assert server._resolve(None, for_catalog=True).store.slug == "steinaberfein"

    # mit bekanntem Aufrufer greift dessen Default
    server._caller = lambda: ("mschuett@example.org", "Max Schütt")
    assert server._resolve(None).store.slug == "steinaberfein"
    # ein ausdrücklich genannter Shop schlägt den Default
    assert server._resolve("dinoland").store.slug == "dinoland"

    # stores() legt die Auswahl offen
    out = server.stores()
    assert [s["store"] for s in out["stores"]] == ["steinaberfein", "dinoland"]
    assert out["default_store"] == "steinaberfein"
    assert out["stores"][0]["is_default_for_caller"] is True
    assert out["stores"][1]["is_default_for_caller"] is False
    assert out["caller"]["known"] is True
    print("store resolution: ok")


async def test_tool_errors():
    from fastmcp.exceptions import ToolError

    from bricklink_mcp import server

    # catalog_search ohne Index -> ToolError mit Klartext
    empty = Catalog(os.path.join(tempfile.mkdtemp(), "catalog.db"))
    saved = server.catalog
    server.catalog = empty
    try:
        server.catalog_search(query="brick")
    except ToolError as exc:
        assert "catalog_refresh" in str(exc), str(exc)
    else:
        raise AssertionError("fehlender Index haette ToolError geben muessen")
    finally:
        server.catalog = saved

    # Shop ohne Credentials -> sprechender Fehler MIT Shop-Namen
    server.apis["dinoland"]._store = Store("dinoland", "Dinoland", "Dinoland", "", "", "", "")
    try:
        server.order_mark_packed(order_id=1, store="dinoland")
    except ToolError as exc:
        assert "Dinoland" in str(exc) and "bricklink-api-dinoland.age" in str(exc), str(exc)
    else:
        raise AssertionError("fehlende Credentials haetten ToolError geben muessen")

    try:
        server.feedback_post(order_id=1, rating="quatsch", comment="x", store="steinaberfein")
    except ToolError as exc:
        assert "praise" in str(exc)
    else:
        raise AssertionError("ungueltiges rating haette scheitern muessen")
    print("tool errors: ok")


# ── HTTP-Schicht gegen einen Fake-BrickLink ────────────────────────────────
# Prüft, was ohne echten Server sonst niemand prüft: OAuth-1.0a-Signatur im
# Authorization-Header, meta-Auswertung, der 401-Fallback auf Query-Signatur,
# Cache-Treffer und Kontingentbuchung.


def test_http_layer():
    import http.server
    import threading as _th

    calls: list[tuple[str, str, str]] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def _reply(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            auth = self.headers.get("Authorization", "")
            calls.append(("GET", self.path, auth))
            if self.path.startswith("/orders/401"):
                # erster Versuch scheitert -> Client muss auf QUERY umschalten
                if "oauth_signature" not in self.path:
                    self._reply(401, {"meta": {"code": 401, "description": "UNAUTHORIZED"}})
                    return
                self._reply(200, {"meta": {"code": 200}, "data": {"order_id": 401}})
                return
            if self.path.startswith("/orders/boom"):
                self._reply(
                    200,
                    {"meta": {"code": 400, "description": "BAD_REQUEST", "message": "nope"}},
                )
                return
            self._reply(200, {"meta": {"code": 200}, "data": {"order_id": 7, "status": "PAID"}})

        def do_PUT(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode()
            calls.append(("PUT", self.path, body))
            self._reply(200, {"meta": {"code": 200}, "data": {"ok": True}})

    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    _th.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    os.environ["BRICKLINK_API_BASE"] = base

    import importlib

    from bricklink_mcp import store as store_mod

    importlib.reload(store_mod)

    cfg = Config.from_env()
    st = State(os.path.join(tempfile.mkdtemp(), "state.db"), daily_budget=50)
    shop = cfg.store("steinaberfein")
    other = cfg.store("dinoland")
    api = store_mod.StoreApi(cfg, st, shop)

    order = api.order(7)
    assert order["status"] == "PAID", order
    _method, path, auth = calls[0]
    assert path == "/orders/7", path
    for needle in ("OAuth", 'oauth_consumer_key="steinaberfein-consumer_key"', "oauth_signature", "HMAC-SHA1"):
        assert needle in auth, (needle, auth)
    assert st.usage("steinaberfein")["used"] == 1

    # Der zweite Shop signiert mit SEINEM Schlüssel und bezahlt sein eigenes Budget
    api2 = store_mod.StoreApi(cfg, st, other)
    api2.order(7)
    assert 'oauth_consumer_key="dinoland-consumer_key"' in calls[-1][2], calls[-1][2]
    assert st.usage("dinoland")["used"] == 1 and st.usage("steinaberfein")["used"] == 1

    # Fehler-meta wird zur sprechenden Exception
    try:
        api.order("boom")
    except store_mod.BrickLinkError as exc:
        assert "BAD_REQUEST" in str(exc) and "nope" in str(exc), str(exc)
    else:
        raise AssertionError("meta.code != 200 haette werfen muessen")

    # 401 -> Umschalten auf Signatur in der Query, zweiter Versuch klappt
    assert api.order("401")["order_id"] == 401
    assert api._signature_type == "QUERY"
    assert "oauth_signature=" in calls[-1][1]

    # Katalog-Antworten werden gecacht -> kein zweiter HTTP-Call, kein Budget
    before = len(calls)
    used_before = st.usage("steinaberfein")["used"]
    api.item("PART", "3001")
    api.item("PART", "3001")
    assert len(calls) == before + 1, calls[before:]
    assert st.usage("steinaberfein")["used"] == used_before + 1

    # Schreibpfade schicken das dokumentierte Patch-Format
    api.update_order_status(7, "PACKED")
    assert json.loads(calls[-1][2]) == {"field": "status", "value": "PACKED"}
    api.update_order(7, {"shipping": {"tracking_no": "DE123"}})
    assert json.loads(calls[-1][2]) == {"shipping": {"tracking_no": "DE123"}}

    srv.shutdown()
    del os.environ["BRICKLINK_API_BASE"]
    print("http layer: ok")


# ── Aggregationen (reine Logik, mit gefälschten API-Antworten) ─────────────


def test_aggregations():
    from bricklink_mcp import server

    server._caller = lambda: (None, None)
    api = server.apis["steinaberfein"]

    lots = [
        {"item": {"type": "PART"}, "quantity": 10, "unit_price": "1.50", "my_cost": "0.50",
         "new_or_used": "N", "is_stock_room": False, "is_retain": False},
        {"item": {"type": "PART"}, "quantity": 2, "unit_price": "3.00",
         "new_or_used": "U", "is_stock_room": True, "stock_room_id": "B"},
        {"item": {"type": "SET"}, "quantity": 1, "unit_price": "99.99", "my_cost": "60",
         "new_or_used": "N", "is_stock_room": False, "is_retain": True},
    ]
    api.inventories = lambda **_kw: lots
    stats = server.inventory_stats(store="steinaberfein")
    assert stats["store"] == "steinaberfein" and stats["store_label"] == "SteinAberFein", stats
    assert stats["lots"] == 3 and stats["quantity"] == 13, stats
    assert stats["list_value"] == round(10 * 1.5 + 2 * 3.0 + 99.99, 2), stats
    assert stats["cost_value"] == round(10 * 0.5 + 60, 2), stats
    assert stats["by_location"]["for_sale"]["lots"] == 1
    assert stats["by_location"]["stockroom_B"]["quantity"] == 2
    assert stats["by_location"]["retain"]["list_value"] == 99.99
    assert stats["by_condition"] == {"N": 2, "U": 1}
    assert stats["by_item_type"]["PART"]["lots"] == 2

    from datetime import datetime, timedelta, timezone

    now = datetime.now(timezone.utc)
    recent = (now - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
    old = (now - timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ")
    orders = [
        {"order_id": 1, "status": "PAID", "buyer_name": "a", "date_ordered": recent,
         "cost": {"grand_total": "20.00", "currency_code": "EUR"}, "total_count": 5},
        {"order_id": 2, "status": "PACKED", "buyer_name": "b", "date_ordered": recent,
         "cost": {"grand_total": "5.00", "currency_code": "EUR"}, "total_count": 1},
        {"order_id": 3, "status": "COMPLETED", "buyer_name": "c", "date_ordered": old,
         "cost": {"grand_total": "999.00", "currency_code": "EUR"}, "total_count": 9},
    ]
    seen_kwargs = {}

    def fake_orders(**kw):
        seen_kwargs.clear()
        seen_kwargs.update(kw)
        return list(orders)

    api.orders = fake_orders
    dash = server.orders_dashboard(store="steinaberfein")
    assert dash["store"] == "steinaberfein"
    assert dash["orders_total"] == 3
    assert dash["by_status"] == {"COMPLETED": 1, "PACKED": 1, "PAID": 1}
    # nur die letzten 30 Tage zählen in den Umsatz
    assert dash["revenue_last_30_days"] == 25.0, dash
    assert [e["order_id"] for e in dash["waiting_to_be_packed"]] == [1]
    assert [e["order_id"] for e in dash["packed_waiting_for_shipment"]] == [2]
    assert dash["currency"] == "EUR"

    # orders_list: since_days-Filter, Sortierung, Limit und der PURGED-Default
    assert server.orders_list(store="steinaberfein", since_days=30)["count"] == 2
    listed = server.orders_list(store="steinaberfein")
    assert listed["count"] == 3 and listed["returned"] == 3
    assert seen_kwargs["status"] == "-purged", seen_kwargs
    assert server.orders_list(store="steinaberfein", include_purged=True)["status_filter"] is None
    assert seen_kwargs["status"] is None
    server.orders_list(store="steinaberfein", status="paid")
    assert seen_kwargs["status"] == "paid"
    capped = server.orders_list(store="steinaberfein", limit=1)
    assert capped["count"] == 3 and capped["returned"] == 1
    assert capped["orders"][0]["date_ordered"] == recent

    # feedback_list zählt über ALLE Einträge, gibt aber nur `limit` aus
    fb = [
        {"feedback_id": 1, "rating": 0, "date_rated": recent},
        {"feedback_id": 2, "rating": 0, "date_rated": old},
        {"feedback_id": 3, "rating": 2, "date_rated": old},
    ]
    api.feedback_list = lambda direction="in": list(fb)
    out = server.feedback_list(store="steinaberfein", limit=1)
    assert out["count"] == 3 and out["returned"] == 1
    assert out["summary"] == {"praise": 2, "complaint": 1}, out["summary"]
    assert out["feedback"][0]["feedback_id"] == 1

    # api_quota ohne Shop nennt ALLE Shops
    quota = server.api_quota()
    assert [q["store"] for q in quota["stores"]] == ["steinaberfein", "dinoland"], quota
    print("aggregations: ok")


def test_write_guard_against_wrong_store():
    """Der wichtigste Test: schreibender Aufruf mit dem FALSCHEN Shop schreibt nichts."""
    from fastmcp.exceptions import ToolError

    from bricklink_mcp import server

    api = server.apis["steinaberfein"]
    written: list[tuple] = []
    # Bestellung gehört Dinoland, aufgerufen wird mit steinaberfein
    api.order = lambda oid: {"order_id": oid, "status": "PAID", "seller_name": "Dinoland"}
    api.update_order_status = lambda *a: written.append(a)
    api.update_order = lambda *a: written.append(a)
    for call in (
        lambda: server.order_mark_packed(order_id=42, store="steinaberfein"),
        lambda: server.order_set_tracking(order_id=42, tracking_no="X", store="steinaberfein"),
    ):
        try:
            call()
        except ToolError as exc:
            assert "Dinoland" in str(exc) and "NICHTS geändert" in str(exc), str(exc)
        else:
            raise AssertionError("falscher Shop haette scheitern muessen")
    assert written == [], f"es wurde geschrieben, obwohl der Shop nicht passt: {written}"
    print("write guard: ok")




# ── Export-Parser (echte Strukturen aus dem Shop, gekürzt) ─────────────────

ORDERS_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<ORDERS>
   <ORDER>
      <ORDERID>32422524</ORDERID>
      <ORDERDATE>8/26/2026</ORDERDATE>
      <BUYER>M.Stadler</BUYER>
      <ORDERSTATUS>Paid</ORDERSTATUS>
      <BASEGRANDTOTAL>20.29</BASEGRANDTOTAL>
      <BASECURRENCYCODE>EUR</BASECURRENCYCODE>
      <ORDERTRACKNO></ORDERTRACKNO>
      <ITEM>
         <ITEMID>46303</ITEMID><ITEMTYPE>P</ITEMTYPE><COLOR>86</COLOR>
         <QTY>2</QTY><PRICE>0.15</PRICE><CONDITION>U</CONDITION>
         <REMARKS>X Hanna3 02-08</REMARKS><LOTID>315550119</LOTID>
      </ITEM>
      <ITEM>
         <ITEMID>3001</ITEMID><ITEMTYPE>P</ITEMTYPE><COLOR>11</COLOR>
         <QTY>5</QTY><PRICE>0.10</PRICE><CONDITION>N</CONDITION>
         <REMARKS>Kiste &amp; Deckel</REMARKS><LOTID>1</LOTID>
      </ITEM>
   </ORDER>
   <ORDER>
      <ORDERID>32414403</ORDERID>
      <ORDERDATE>8/25/2026</ORDERDATE>
      <BUYER>misja_robotyka</BUYER>
      <ORDERSTATUS>Shipped</ORDERSTATUS>
      <ITEM><ITEMID>2456</ITEMID><ITEMTYPE>P</ITEMTYPE><QTY>1</QTY><PRICE>0.30</PRICE></ITEM>
   </ORDER>
</ORDERS>"""

INVENTORY_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<INVENTORY>
   <ITEM>
      <LOTID>1</LOTID><DATEADDED>10/25/2022</DATEADDED><DATELASTSOLD>1/2/2026</DATELASTSOLD>
      <ITEMTYPE>P</ITEMTYPE><ITEMID>3001</ITEMID><COLOR>11</COLOR>
      <QTY>10</QTY><PRICE>0.15</PRICE><MYCOST>0.05</MYCOST><CONDITION>N</CONDITION>
      <REMARKS>Regal A1</REMARKS><STOCKROOM>N</STOCKROOM>
   </ITEM>
   <ITEM>
      <LOTID>2</LOTID><DATEADDED>1/1/2020</DATEADDED>
      <ITEMTYPE>P</ITEMTYPE><ITEMID>2456</ITEMID><COLOR>5</COLOR>
      <QTY>3</QTY><PRICE>1.00</PRICE><CONDITION>U</CONDITION>
      <REMARKS>Ladenhueter</REMARKS><STOCKROOM>Y</STOCKROOM><STOCKROOMID>B</STOCKROOMID>
   </ITEM>
   <ITEM>
      <LOTID>3</LOTID><DATELASTSOLD>8/1/2026</DATELASTSOLD>
      <ITEMTYPE>S</ITEMTYPE><ITEMID>7644-1</ITEMID>
      <QTY>1</QTY><PRICE>99.99</PRICE><CONDITION>U</CONDITION><RETAIN>Y</RETAIN>
   </ITEM>
</INVENTORY>"""

WANTED_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<INVENTORY>
   <ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>15573</ITEMID><COLOR>88</COLOR>
      <MAXPRICE>-1.0000</MAXPRICE><MINQTY>1</MINQTY><CONDITION>X</CONDITION><NOTIFY>N</NOTIFY></ITEM>
</INVENTORY>"""


def test_export_parsers():
    from bricklink_mcp import exports

    orders = exports.parse_orders(ORDERS_XML)
    assert [o["orderid"] for o in orders] == ["32422524", "32414403"], orders
    first = orders[0]
    assert first["order_date"] == "2026-08-26", first["order_date"]
    assert first["buyer"] == "M.Stadler" and first["orderstatus"] == "Paid"
    assert first["lots"] == 2 and first["items_total"] == 7, first
    # nackte & auch hier repariert, Lot-Bemerkung (= Lagerplatz) kommt mit
    assert first["items"][0]["remarks"] == "X Hanna3 02-08"
    assert first["items"][1]["remarks"] == "Kiste & Deckel"
    # ohne Positionen bleibt die Zählung erhalten, die Liste fehlt
    lean = exports.parse_orders(ORDERS_XML, include_items=False)
    assert lean[0]["lots"] == 2 and "items" not in lean[0]
    # leere Antwort (BrickLink liefert bei "keine Treffer" 0 Bytes)
    assert exports.parse_orders(b"") == []

    lots = exports.parse_inventory(INVENTORY_XML)
    assert len(lots) == 3
    assert lots[0]["date_added"] == "2022-10-25" and lots[0]["date_last_sold"] == "2026-01-02"
    assert lots[1]["date_last_sold"] is None, "nie verkauft -> None"

    stats = exports.inventory_stats(lots)
    assert stats["lots"] == 3 and stats["quantity"] == 14
    assert stats["list_value"] == round(10 * 0.15 + 3 * 1.0 + 99.99, 2), stats
    assert stats["cost_value"] == 0.5, stats
    assert stats["never_sold_lots"] == 1
    assert stats["by_location"]["for_sale"] == 1 and stats["by_location"]["retain"] == 1

    # Filter: Ladenhüter, Typ, Volltext, Stockroom, Mindestmenge
    assert [l["lotid"] for l in exports.filter_inventory(lots, not_sold_since_days=3650)] == ["2"]
    assert [l["lotid"] for l in exports.filter_inventory(lots, item_type="Set")] == ["3"]
    assert [l["lotid"] for l in exports.filter_inventory(lots, query="regal")] == ["1"]
    assert [l["lotid"] for l in exports.filter_inventory(lots, query="3001")] == ["1"]
    assert [l["lotid"] for l in exports.filter_inventory(lots, min_qty=5)] == ["1"]
    assert [l["lotid"] for l in exports.filter_inventory(lots, color_id=5)] == ["2"]
    assert len(exports.filter_inventory(lots, stockroom="N")) == 2

    wanted = exports.parse_wanted(WANTED_XML)
    assert wanted == [
        {
            "itemtype": "P",
            "itemid": "15573",
            "color": "88",
            "maxprice": "-1.0000",
            "minqty": "1",
            "condition": "X",
            "notify": "N",
        }
    ], wanted

    csv_text = exports.to_csv(lots, columns=["itemid", "qty", "price"])
    assert csv_text.splitlines()[0] == "itemid;qty;price"
    assert csv_text.splitlines()[1] == "3001;10;0.15"
    assert exports.to_csv([]) == ""
    print("export parsers: ok")


def test_top_selling_and_caps():
    """Ranking-Aggregation und die Kontext-Bremse von orders_export."""
    from bricklink_mcp import exports, server

    orders = exports.parse_orders(ORDERS_XML)
    top = exports.top_selling(orders, limit=5)
    assert top["orders_considered"] == 2 and top["distinct_items"] == 3, top
    # 3001 wurde 5x verkauft, 46303 2x, 2456 1x -> Reihenfolge nach Stückzahl
    assert [(t["item_no"], t["quantity"]) for t in top["top"]] == [
        ("3001", 5),
        ("46303", 2),
        ("2456", 1),
    ], top["top"]
    assert top["top"][0]["revenue"] == 0.5, top["top"][0]
    # nach Umsatz: 46303 (2 x 0.15 = 0.30) vs 3001 (5 x 0.10 = 0.50) vs 2456 (0.30)
    by_rev = exports.top_selling(orders, by="revenue")["top"]
    assert by_rev[0]["item_no"] == "3001", by_rev
    # Typfilter
    only_p = exports.top_selling(orders, item_type="P")["top"]
    assert all(t["item_type"] == "P" for t in only_p) and len(only_p) == 3
    # Farbe wird mit aggregiert: gleiches Item in zwei Farben bleibt getrennt
    keys = {(t["item_no"], t["color"]) for t in top["top"]}
    assert ("3001", "11") in keys and ("46303", "86") in keys, keys

    # orders_export: Positionen sind standardmäßig AUS
    server._caller = lambda: (None, None)
    api = server.apis["steinaberfein"]
    sess = server.webs["steinaberfein"]
    sess.verify_account = lambda *_a, **_k: None
    sess._client_token = "x"  # configured -> True
    sess.orders_xml = lambda **_kw: ORDERS_XML
    lean = server.orders_export(store="steinaberfein")
    assert "items" not in lean["orders"][0], lean["orders"][0].keys()
    assert lean["items_truncated"] == 0
    # mit Positionen und genug Budget: nichts gekappt (die Untergrenze ist 10)
    full = server.orders_export(store="steinaberfein", include_items=True)
    assert sum(len(o.get("items") or []) for o in full["orders"]) == 3
    assert full["items_truncated"] == 0

    # Kappen: eine Bestellung mit 15 Positionen, Budget 10
    many = (
        b'<?xml version="1.0" encoding="UTF-8"?><ORDERS><ORDER><ORDERID>99</ORDERID>'
        b"<ORDERDATE>8/20/2026</ORDERDATE><BUYER>x</BUYER><ORDERSTATUS>Paid</ORDERSTATUS>"
        + b"".join(
            b"<ITEM><ITEMID>p%d</ITEMID><ITEMTYPE>P</ITEMTYPE><QTY>1</QTY><PRICE>1.00</PRICE></ITEM>"
            % i
            for i in range(15)
        )
        + b"</ORDER></ORDERS>"
    )
    sess.orders_xml = lambda **_kw: many
    capped = server.orders_export(store="steinaberfein", include_items=True, max_items=10)
    total = sum(len(o.get("items") or []) for o in capped["orders"])
    assert total == 10 and capped["items_truncated"] == 5, (total, capped["items_truncated"])
    assert capped["orders"][0].get("items_omitted") == 5
    # das Ranking sieht dagegen ALLE Positionen (es aggregiert vor dem Kappen)
    ranked = exports.top_selling(exports.parse_orders(many), limit=100)
    assert ranked["distinct_items"] == 15 and ranked["top"][0]["quantity"] == 1
    print("top selling + caps: ok")


def test_export_tools_without_web_token():
    """Ohne Web-Token muss der Export sagen WAS fehlt und WO es hingehört."""
    from fastmcp.exceptions import ToolError

    from bricklink_mcp import server

    server._caller = lambda: (None, None)
    try:
        server.orders_export(store="dinoland")
    except ToolError as exc:
        assert "kein Web-Token" in str(exc) and "bricklink-api-dinoland.age" in str(exc), str(exc)
    else:
        raise AssertionError("ohne Web-Token haette es scheitern muessen")

    # Kontoprüfung: ein Token, das zum falschen Konto gehört, darf NICHTS ausliefern
    from bricklink_mcp.web import WebSession, WebSessionError

    session = WebSession(server.cfg, client_token="egal", context="Test")
    session._account = ("dinoliebe", "42")
    try:
        session.verify_account("SteinAberFein")
    except WebSessionError as exc:
        assert "FALSCHEN Shop" in str(exc) and "dinoliebe" in str(exc), str(exc)
    else:
        raise AssertionError("falsches Konto haette scheitern muessen")
    session.verify_account("dinoliebe")  # passt -> kein Fehler
    print("export guards: ok")


test_catalog()
test_stores_config()
test_export_parsers()
test_guards()
test_state()
test_state_migration()
test_store_resolution()
asyncio.run(test_tool_errors())
test_http_layer()
test_aggregations()
test_write_guard_against_wrong_store()
test_top_selling_and_caps()
test_export_tools_without_web_token()
print("ALLE TESTS OK")


def test_signed_links():
    """Signatur muss BIT FÜR BIT dem entsprechen, was nginx' secure_link prüft."""
    import base64
    import hashlib
    import urllib.parse

    from bricklink_mcp import links

    secret = "geheim-und-lang-genug-fuer-einen-test"
    url, expires = links.sign(
        "https://chat.example.org/", "/bricklink-exports/", "orders_x.xml", secret, 60
    )
    parsed = urllib.parse.urlparse(url)
    args = dict(urllib.parse.parse_qsl(parsed.query))
    assert parsed.scheme == "https" and parsed.netloc == "chat.example.org"
    assert parsed.path == "/bricklink-exports/orders_x.xml", parsed.path
    assert int(args["expires"]) == expires

    # nginx rechnet: md5("$secure_link_expires$uri<secret>"), base64url ohne Padding
    want = (
        base64.urlsafe_b64encode(
            hashlib.md5(f"{expires}{parsed.path}{secret}".encode()).digest()
        )
        .decode()
        .rstrip("=")
    )
    assert args["md5"] == want, (args["md5"], want)
    assert "=" not in args["md5"], "Padding muss weg, sonst passt es nicht zu nginx"

    # TTL wird gedeckelt (ein Tag) und nach unten begrenzt
    _u, long_exp = links.sign("https://x", "/p/", "f", secret, 99999)
    assert long_exp - int(__import__("time").time()) <= links.MAX_TTL_MINUTES * 60 + 2
    _u, short_exp = links.sign("https://x", "/p/", "f", secret, 0)
    assert short_exp > int(__import__("time").time())

    # doppelte Slashes im Pfad dürfen nicht entstehen (sonst stimmt der Hash nicht)
    url2, _e = links.sign("https://x/", "/p/", "/f", secret, 5)
    assert url2.count("//") == 1 and "/p/f?" in url2, url2
    print("signed links: ok")


test_signed_links()
print("ALLE TESTS OK (inkl. Links)")


def test_mail_parser():
    """Benachrichtigungsmail zerlegen — Absender, Mitglied, Bestellbezug, Links."""
    from bricklink_mcp import mailbox

    raw = (
        b"From: BrickLink <no-reply@bricklink.com>\r\n"
        b"To: shop@example.org\r\n"
        b"Subject: =?UTF-8?Q?New_message_from_Ronny9_=E2=80=93_Frage_zur_Figur?=\r\n"
        b"Date: Tue, 01 Sep 2026 18:22:10 +0200\r\n"
        b"MIME-Version: 1.0\r\n"
        b"Content-Type: multipart/alternative; boundary=BOUND\r\n"
        b"\r\n"
        b"--BOUND\r\n"
        b"Content-Type: text/plain; charset=utf-8\r\n\r\n"
        b"Hallo, ist die Figur sw0973 komplett? Gruss Ronny9\r\n"
        b"Antworten: https://www.bricklink.com/messageThread.asp?ID=999\r\n"
        b"--BOUND\r\n"
        b"Content-Type: text/html; charset=utf-8\r\n\r\n"
        b"<p>ignoriert, weil Klartext vorhanden</p>\r\n"
        b"--BOUND--\r\n"
    )
    got = mailbox.parse_notification(raw, uid="42")
    assert got["uid"] == "42" and got["kind"] == "message", got
    # Betreff wird dekodiert (Quoted-Printable + UTF-8)
    assert "Frage zur Figur" in got["subject"], got["subject"]
    assert got["member"] == "Ronny9", got["member"]
    assert "sw0973" in got["body"] and "ignoriert" not in got["body"], got["body"]
    assert got["bricklink_links"] == ["https://www.bricklink.com/messageThread.asp?ID=999"]
    assert got["sent_at"] == "2026-09-01T16:22:10Z", got["sent_at"]
    assert got["order_id"] is None

    # Bestellbezug und Feedback-Art
    raw2 = (
        b"From: BrickLink <no-reply@bricklink.com>\r\n"
        b"Subject: Feedback received for Order #32458351\r\n"
        b"Content-Type: text/plain; charset=utf-8\r\n\r\n"
        b"You received feedback.\r\n"
    )
    got2 = mailbox.parse_notification(raw2)
    assert got2["kind"] == "feedback" and got2["order_id"] == "32458351", got2

    # Nur-HTML-Mail: Tags raus, Text bleibt
    raw3 = (
        b"From: BrickLink <noreply@mail.bricklink.com>\r\n"
        b"Subject: Message from bricker99\r\n"
        b"Content-Type: text/html; charset=utf-8\r\n\r\n"
        b"<html><style>p{color:red}</style><body><p>Frage:</p>"
        b"<p>Haben Sie 3001 in rot?</p></body></html>\r\n"
    )
    got3 = mailbox.parse_notification(raw3)
    assert "Haben Sie 3001 in rot?" in got3["body"], got3["body"]
    assert "color:red" not in got3["body"], "CSS muss raus"
    assert got3["member"] == "bricker99"

    # Ohne Zugangsdaten sagt fetch, was fehlt — statt zu crashen
    try:
        mailbox.fetch(mailbox.Mailbox("", 993, "", "", "INBOX"))
    except mailbox.MailboxError as exc:
        assert "MAIL_HOST" in str(exc)
    else:
        raise AssertionError("ohne Zugangsdaten haette es scheitern muessen")
    print("mail parser: ok")


test_mail_parser()
print("ALLE TESTS OK (inkl. Mail)")
