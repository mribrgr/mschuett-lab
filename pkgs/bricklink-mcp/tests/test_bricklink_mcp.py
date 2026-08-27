import asyncio, json, os, sys, tempfile

os.environ.setdefault("BRICKLINK_DATA_DIR", tempfile.mkdtemp())
from bricklink_mcp.catalog import Catalog
from bricklink_mcp.guards import check_transition, NotAllowed
from bricklink_mcp.state import State, Quota

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

    # Ranking: "Brick 4 x 6" matcht mit (brick, x, 4*) plus item_no 2356 auf "2*" —
    # der NAMENSTREFFER 3001 muss trotzdem vorne stehen (bm25 mit Namensgewicht).
    hits = cat.search(query="brick 2 x 4")
    assert hits[0]["item_no"] == "3001", [h["item_no"] for h in hits]
    # Kurze Tokens werden NICHT als Prefix gesucht, sonst zieht "2" die Nummer 2356
    # herein ("Brick 4 x 6") — und bm25 bewertete die sogar besser.
    assert "2356" not in [h["item_no"] for h in hits], [h["item_no"] for h in hits]
    # Der exakte Name gewinnt gegen Duplo-/Quatro-Varianten, die den Suchstring
    # ebenfalls enthalten (am echten Katalog standen genau die vorn).
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
    # Kategorie kam mit nacktem & durch
    assert any(c["name"] == "Duplo & Explore" for c in cat.categories()), cat.categories()
    # Alt-ID ist suchbar
    assert cat.search(query="3001old")[0]["item_no"] == "3001"
    # Typfilter + Jahresfilter
    assert cat.search(item_type="Set")[0]["item_no"] == "7644-1"
    assert cat.search(query="brick", year_max=1960)[0]["item_no"] == "3001"
    assert cat.search(query="brick", limit=1) and len(cat.search(query="brick")) == 5
    # Kategoriename-Filter
    assert cat.search(category="Brick") and len(cat.search(category="Brick")) == 6
    print("catalog: ok")


def test_guards():
    own = "steinaberfein"
    ok = {"order_id": 1, "status": "PAID", "seller_name": own}
    check_transition(ok, "PACKED", own)
    for order, target, needle in [
        ({"order_id": 2, "status": "SHIPPED", "seller_name": own}, "PACKED", "nur aus"),
        ({"order_id": 3, "status": "PACKED", "seller_name": own}, "PACKED", "bereits"),
        ({"order_id": 4, "status": "PAID", "seller_name": "someoneelse"}, "PACKED", "kein"),
        ({"order_id": 5, "status": "PAID", "seller_name": own}, "SHIPPED", "nur aus"),
        ({"order_id": 6, "status": "PAID", "seller_name": own}, "CANCELLED", "nicht vorgesehen"),
    ]:
        try:
            check_transition(order, target, own)
        except NotAllowed as exc:
            assert needle in str(exc), (target, str(exc))
        else:
            raise AssertionError(f"{target} aus {order['status']} haette scheitern muessen")
    check_transition({"order_id": 7, "status": "PACKED", "seller_name": own}, "SHIPPED", own)
    print("guards: ok")


def test_state():
    st = State(os.path.join(os.environ["BRICKLINK_DATA_DIR"], "state.db"), daily_budget=3)
    st.spend(2)
    assert st.usage()["remaining"] == 1
    try:
        st.spend(2)
    except Quota as exc:
        assert "erschöpft" in str(exc)
    else:
        raise AssertionError("Quota haette greifen muessen")
    st.spend(1)
    assert st.usage()["remaining"] == 0
    st.store("k", {"a": 1})
    assert st.cached("k", 60) == {"a": 1}
    assert st.cached("k", 0) is None
    assert st.cached("nope", 60) is None
    print("state: ok")


async def test_tool_errors():
    from bricklink_mcp import server

    # catalog_search ohne Index -> ToolError mit Klartext
    empty = Catalog(os.path.join(tempfile.mkdtemp(), "catalog.db"))
    from fastmcp.exceptions import ToolError

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

    # Schreib-Tool ohne Credentials -> ToolError, KEIN Traceback
    try:
        server.order_mark_packed(order_id=1)
    except ToolError as exc:
        assert "Credentials" in str(exc), str(exc)
    else:
        raise AssertionError("fehlende Credentials haetten ToolError geben muessen")

    try:
        server.feedback_post(order_id=1, rating="grandios", comment="x")
    except ToolError as exc:
        assert "praise" in str(exc)
    else:
        raise AssertionError("ungueltiges rating haette scheitern muessen")
    print("tool errors: ok")


test_catalog()
test_guards()
test_state()
asyncio.run(test_tool_errors())


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
    from bricklink_mcp.config import Config

    cfg = Config.from_env()
    cfg = type(cfg)(**{**cfg.__dict__, "consumer_key": "ck", "consumer_secret": "cs",
                       "token_value": "tv", "token_secret": "ts",
                       "store_username": "seller"})
    st = State(os.path.join(tempfile.mkdtemp(), "state.db"), daily_budget=50)
    api = store_mod.StoreApi(cfg, st)

    order = api.order(7)
    assert order["status"] == "PAID", order
    method, path, auth = calls[0]
    assert path == "/orders/7", path
    for needle in ("OAuth", 'oauth_consumer_key="ck"', "oauth_signature", "HMAC-SHA1"):
        assert needle in auth, (needle, auth)
    assert st.usage()["used"] == 1

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
    used_before = st.usage()["used"]
    api.item("PART", "3001")
    api.item("PART", "3001")
    assert len(calls) == before + 1, calls[before:]
    assert st.usage()["used"] == used_before + 1

    # Schreibpfade schicken das dokumentierte Patch-Format
    api.update_order_status(7, "PACKED")
    assert json.loads(calls[-1][2]) == {"field": "status", "value": "PACKED"}
    api.update_order(7, {"shipping": {"tracking_no": "DE123"}})
    assert json.loads(calls[-1][2]) == {"shipping": {"tracking_no": "DE123"}}

    srv.shutdown()
    del os.environ["BRICKLINK_API_BASE"]
    print("http layer: ok")


test_http_layer()


# ── Aggregationen (reine Logik, mit gefälschten API-Antworten) ─────────────


def test_aggregations():
    from bricklink_mcp import server

    lots = [
        {"item": {"type": "PART"}, "quantity": 10, "unit_price": "1.50", "my_cost": "0.50",
         "new_or_used": "N", "is_stock_room": False, "is_retain": False},
        {"item": {"type": "PART"}, "quantity": 2, "unit_price": "3.00",
         "new_or_used": "U", "is_stock_room": True, "stock_room_id": "B"},
        {"item": {"type": "SET"}, "quantity": 1, "unit_price": "99.99", "my_cost": "60",
         "new_or_used": "N", "is_stock_room": False, "is_retain": True},
    ]
    server.api.inventories = lambda **_kw: lots
    stats = server.inventory_stats()
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
    server.api.orders = lambda **_kw: orders
    dash = server.orders_dashboard()
    assert dash["orders_total"] == 3
    assert dash["by_status"] == {"COMPLETED": 1, "PACKED": 1, "PAID": 1}
    # nur die letzten 30 Tage zählen in den Umsatz
    assert dash["revenue_last_30_days"] == 25.0, dash
    assert [e["order_id"] for e in dash["waiting_to_be_packed"]] == [1]
    assert [e["order_id"] for e in dash["packed_waiting_for_shipment"]] == [2]
    assert dash["currency"] == "EUR"

    # orders_list: since_days-Filter, Sortierung, Limit und der PURGED-Default
    seen_kwargs = {}

    def fake_orders(**kw):
        seen_kwargs.clear()
        seen_kwargs.update(kw)
        return list(orders)

    server.api.orders = fake_orders
    assert server.orders_list(since_days=30)["count"] == 2
    listed = server.orders_list()
    assert listed["count"] == 3 and listed["returned"] == 3
    # Default blendet PURGED aus, sonst besteht die Antwort aus Altlasten
    assert seen_kwargs["status"] == "-purged", seen_kwargs
    assert server.orders_list(include_purged=True)["status_filter"] is None
    assert seen_kwargs["status"] is None
    # explizit gesetzter Status gewinnt
    server.orders_list(status="paid")
    assert seen_kwargs["status"] == "paid"
    # neueste zuerst, Limit kappt die Ausgabe aber nicht die Zählung
    capped = server.orders_list(limit=1)
    assert capped["count"] == 3 and capped["returned"] == 1
    assert capped["orders"][0]["order_id"] in (1, 2), capped["orders"][0]
    assert capped["orders"][0]["date_ordered"] == recent

    # feedback_list zählt über ALLE Einträge, gibt aber nur `limit` aus
    fb = [
        {"feedback_id": 1, "rating": 0, "date_rated": recent},
        {"feedback_id": 2, "rating": 0, "date_rated": old},
        {"feedback_id": 3, "rating": 2, "date_rated": old},
    ]
    server.api.feedback_list = lambda direction="in": list(fb)
    out = server.feedback_list(limit=1)
    assert out["count"] == 3 and out["returned"] == 1
    assert out["summary"] == {"praise": 2, "complaint": 1}, out["summary"]
    assert out["feedback"][0]["feedback_id"] == 1

    print("aggregations: ok")


test_aggregations()
print("ALLE TESTS OK (inkl. HTTP + Aggregationen)")
