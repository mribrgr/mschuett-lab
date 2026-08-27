"""Offline-Katalogindex (SQLite + FTS5).

Warum überhaupt: die Store API kann Items nur über die EXAKTE Nummer
nachschlagen — es gibt keinen Suchendpunkt. Für „finde mir die Teile-Nummer zu
'Brick 2 x 4'" braucht es also einen eigenen Index. Genau das macht BrickStore
auch: einmal den offiziellen Katalog-Export ziehen, lokal indizieren, danach
offline suchen (kein API-Kontingent, keine Rate-Limits).

Der Index enthält bewusst NUR die Katalog-Stammdaten (Item-Typen, Kategorien,
Farben, Items mit Name/Jahr/Gewicht/Alt-IDs). Preise und Verfügbarkeiten
kommen live aus der API — die dürfen laut API-ToU nicht länger als „reasonable
periods" gecacht werden.
"""

from __future__ import annotations

import io
import json
import logging
import os
import re
import sqlite3
import time
from typing import Any, Iterator
from xml.etree import ElementTree as ET

from .web import WebSession

# BrickLinks Exporte enthalten gelegentlich nackte `&` (z.B. in Item-Namen wie
# "Duplo & Explore"). Das ist kein wohlgeformtes XML; ohne diese Reparatur
# stirbt der Parser mit "not well-formed (invalid token)".
DOWNLOAD_PAUSE_SECONDS = 3

log = logging.getLogger("bricklink-mcp.catalog")

_BARE_AMP = re.compile(rb"&(?!(?:#\d+|#x[0-9a-fA-F]+|amp|lt|gt|quot|apos);)")


def _sanitize(raw: bytes) -> bytes:
    return _BARE_AMP.sub(b"&amp;", raw)


def _match_expression(query: str) -> str:
    """Baut den FTS5-MATCH-Ausdruck für eine Nutzeranfrage.

    Prefix-Stern nur ab drei Zeichen. Grund: mit `"2"*` matcht die Anfrage
    "brick 2 x 4" jede Item-Nummer, die mit 2 beginnt (2356 = "Brick 4 x 6"), weil
    item_no mit im Index steht. Kurze Tokens werden deshalb exakt gesucht — "2"
    trifft dann das Namenstoken "2", aber nicht mehr die Nummer 2356.
    """
    parts = []
    for word in re.findall(r"[\w/-]+", query):
        parts.append(f'"{word}"*' if len(word) >= 3 else f'"{word}"')
    return " ".join(parts)


def _items(raw: bytes) -> Iterator[dict[str, str]]:
    """Streamt <ITEM>-Knoten als {TAG: text}.

    iterparse statt fromstring aus zwei Gründen:
      * Der Part-Export hat >100.000 Items; ein kompletter DOM-Baum sprengt das
        Memory-Limit des Pods auf einem Node mit 7,7 GiB.
      * BrickLink liefert die Exporte MIT `<?xml … encoding="…"?>`. ET auf einem
        `str` mit Encoding-Deklaration wirft „Unicode strings with encoding
        declaration are not supported" — mit Bytes passiert das nicht.
    """
    context = ET.iterparse(io.BytesIO(_sanitize(raw)), events=("start", "end"))
    _event, root = next(context)
    for event, node in context:
        if event != "end" or node.tag != "ITEM":
            continue
        yield {child.tag: (child.text or "").strip() for child in node}
        # Wurzel leeren: sonst hängen alle bereits verarbeiteten ITEMs weiter
        # am Baum und der Speicher wächst trotz iterparse.
        root.clear()


SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE item_types (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE colors (id INTEGER PRIMARY KEY, name TEXT, rgb TEXT, type TEXT);
CREATE TABLE items (
    item_type   TEXT NOT NULL,
    item_no     TEXT NOT NULL,
    name        TEXT NOT NULL,
    category_id INTEGER,
    year        INTEGER,
    weight      REAL,
    alt_ids     TEXT,
    image_color INTEGER,
    PRIMARY KEY (item_type, item_no)
);
CREATE INDEX items_by_category ON items (category_id);
CREATE VIRTUAL TABLE items_fts USING fts5(
    name, item_no, alt_ids, content='items', content_rowid='rowid', tokenize='unicode61'
);
"""


class Catalog:
    def __init__(self, path: str) -> None:
        self._path = path

    # ── Lesen ──────────────────────────────────────────────────────────────
    def _open(self) -> sqlite3.Connection:
        if not os.path.exists(self._path):
            raise RuntimeError(
                "Kein Katalogindex vorhanden. Einmal `catalog_refresh` aufrufen "
                "(braucht ein gültiges BRICKLINK_WEB_CLIENT_TOKEN)."
            )
        db = sqlite3.connect(f"file:{self._path}?mode=ro", uri=True, check_same_thread=False)
        db.row_factory = sqlite3.Row
        return db

    def status(self) -> dict[str, Any]:
        if not os.path.exists(self._path):
            return {"present": False}
        db = self._open()
        try:
            meta = {r["key"]: r["value"] for r in db.execute("SELECT key, value FROM meta")}
            counts = {
                row["item_type"]: row["n"]
                for row in db.execute(
                    "SELECT item_type, COUNT(*) AS n FROM items GROUP BY item_type"
                )
            }
            built = float(meta.get("built_at", "0"))
            failed = {}
            if meta.get("failed_types"):
                try:
                    failed = json.loads(meta["failed_types"])
                except ValueError:
                    failed = {"?": meta["failed_types"]}
            return {
                "present": True,
                "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(built)),
                "failed_types": failed,
                "age_days": round((time.time() - built) / 86400, 1),
                "items_total": sum(counts.values()),
                "items_per_type": counts,
                "colors": db.execute("SELECT COUNT(*) FROM colors").fetchone()[0],
                "categories": db.execute("SELECT COUNT(*) FROM categories").fetchone()[0],
                "size_bytes": os.path.getsize(self._path),
            }
        finally:
            db.close()

    def search(
        self,
        query: str | None = None,
        item_type: str | None = None,
        item_no: str | None = None,
        category: str | None = None,
        year_min: int | None = None,
        year_max: int | None = None,
        limit: int = 25,
    ) -> list[dict[str, Any]]:
        db = self._open()
        try:
            where: list[str] = []
            args: list[Any] = []
            terms = ""
            if query:
                terms = _match_expression(query)

            if terms:
                # ⚠️ Die FTS-Tabelle MUSS in der FROM-Klausel stehen, sonst ist bm25()
                # nicht verfügbar (in einer korrelierten Unterabfrage liefert es keine
                # brauchbare Ordnung). Und sortiert werden MUSS nach bm25, nicht nach
                # Namenslänge: weil item_no mit im Index steht, matcht "brick 2 x 4"
                # auch "Brick 4 x 6" (Nummer 2356 trifft das Prefix "2"), und nach
                # Länge sortiert stand am 2026-08-27 genau dieses falsche Ergebnis vorn.
                # bm25 gewichtet die Spalten in Tabellenreihenfolge (name, item_no,
                # alt_ids); kleinere (negativere) Werte sind besser.
                base = (
                    "FROM items_fts f "
                    "JOIN items i ON i.rowid = f.rowid "
                    "LEFT JOIN categories c ON c.id = i.category_id "
                    "LEFT JOIN item_types t ON t.id = i.item_type "
                )
                where.append("items_fts MATCH ?")
                args.append(terms)
                # Vorstufen vor bm25, weil bm25 allein hier daneben liegt. Zwei am
                # 2026-08-27 gegen den echten Katalog (209.876 Items) gemessene Fälle:
                #   * "brick 2 x 4" bewertet bm25 „Brick 4 x 6" (-0,6714) BESSER als
                #     „Brick 2 x 4" (-0,6627),
                #   * mit reinem Substring-Boost standen die Duplo-/Quatro-Varianten
                #     vorn („Duplo, Brick 2 x 4 x 2 with Bricks Pattern" enthält den
                #     Suchstring ebenfalls).
                # Deshalb explizite Ränge: exakte Nummer, exakter Name, Name beginnt
                # mit der Anfrage, Name enthält sie, dann erst bm25 und Namenslänge.
                order = (
                    "(CASE WHEN lower(i.item_no) = ? THEN 0 ELSE 1 END), "
                    "(CASE WHEN lower(i.name) = ? THEN 0 "
                    "      WHEN instr(lower(i.name), ?) = 1 THEN 1 "
                    "      WHEN instr(lower(i.name), ?) > 0 THEN 2 ELSE 3 END), "
                    "bm25(items_fts, 10.0, 2.0, 1.0), length(i.name)"
                )
                needle = " ".join(query.strip().lower().split())
                order_args: list[Any] = [needle, needle, needle, needle]
            else:
                base = (
                    "FROM items i "
                    "LEFT JOIN categories c ON c.id = i.category_id "
                    "LEFT JOIN item_types t ON t.id = i.item_type "
                )
                order = "length(i.name), i.item_no"
                order_args = []

            if item_type:
                where.append("i.item_type = ?")
                args.append(item_type[:1].upper())
            if item_no:
                where.append("i.item_no LIKE ?")
                args.append(f"%{item_no}%")
            if category:
                where.append("c.name LIKE ?")
                args.append(f"%{category}%")
            if year_min:
                where.append("i.year >= ?")
                args.append(year_min)
            if year_max:
                where.append("i.year <= ?")
                args.append(year_max)

            sql = (
                "SELECT i.item_type, i.item_no, i.name, i.year, i.weight, i.alt_ids, "
                "       i.category_id, c.name AS category_name, t.name AS item_type_name "
                + base
                + ("WHERE " + " AND ".join(where) + " " if where else "")
                + f"ORDER BY {order} LIMIT ?"
            )
            args.extend(order_args)
            args.append(max(1, min(limit, 200)))
            return [dict(row) for row in db.execute(sql, args)]
        finally:
            db.close()

    def colors(self, name: str | None = None) -> list[dict[str, Any]]:
        db = self._open()
        try:
            if name:
                rows = db.execute(
                    "SELECT * FROM colors WHERE name LIKE ? ORDER BY id", (f"%{name}%",)
                )
            else:
                rows = db.execute("SELECT * FROM colors ORDER BY id")
            return [dict(r) for r in rows]
        finally:
            db.close()

    def categories(self, name: str | None = None) -> list[dict[str, Any]]:
        db = self._open()
        try:
            if name:
                rows = db.execute(
                    "SELECT * FROM categories WHERE name LIKE ? ORDER BY name", (f"%{name}%",)
                )
            else:
                rows = db.execute("SELECT * FROM categories ORDER BY name")
            return [dict(r) for r in rows]
        finally:
            db.close()

    # ── Schreiben ──────────────────────────────────────────────────────────
    def refresh(self, web: WebSession) -> dict[str, Any]:
        """Baut den Index komplett neu und tauscht ihn atomar aus.

        Atomar, weil ein halb geschriebener Index schlimmer ist als ein alter:
        gebaut wird in `<pfad>.new`, am Ende `os.replace`.
        """
        tmp = self._path + ".new"
        if os.path.exists(tmp):
            os.remove(tmp)
        os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)

        started = time.time()
        db = sqlite3.connect(tmp)
        try:
            db.executescript(SCHEMA)

            types: list[tuple[str, str]] = []
            for row in _items(web.catalog_view(1)):
                raw = row.get("ITEMTYPE", "")
                name = row.get("ITEMTYPENAME", "")
                if not raw:
                    continue
                # BrickStore leitet die ID aus dem ERSTEN Buchstaben ab
                # (ItemType::idFromFirstCharInString) — der Export liefert je
                # nach Sicht den Buchstaben oder den ausgeschriebenen Namen.
                types.append((raw[:1].upper(), name or raw))
            db.executemany("INSERT OR REPLACE INTO item_types VALUES (?,?)", types)

            db.executemany(
                "INSERT OR REPLACE INTO categories VALUES (?,?)",
                [
                    (int(r["CATEGORY"]), r.get("CATEGORYNAME", ""))
                    for r in _items(web.catalog_view(2))
                    if r.get("CATEGORY", "").isdigit()
                ],
            )
            db.executemany(
                "INSERT OR REPLACE INTO colors VALUES (?,?,?,?)",
                [
                    (
                        int(r["COLOR"]),
                        r.get("COLORNAME", ""),
                        "#" + r.get("COLORRGB", "") if r.get("COLORRGB") else None,
                        r.get("COLORTYPE", ""),
                    )
                    for r in _items(web.catalog_view(3))
                    if r.get("COLOR", "").isdigit()
                ],
            )

            per_type: dict[str, int] = {}
            failed: dict[str, str] = {}
            for type_id, _name in types:
                # Kurze Pause zwischen den Exporten. Der Part-Export ist 27 MB, der
                # Set-Export 6 MB; ohne Pause quittiert BrickLink die Serie gerne mit
                # einem 500 (am 2026-08-27 reproduziert). Der Refresh läuft einmal pro
                # Woche im Hintergrund — die Sekunden sind hier gratis.
                time.sleep(DOWNLOAD_PAUSE_SECONDS)
                # Ein Item-Typ, der dauerhaft 500 liefert, darf nicht den GANZEN Index
                # verhindern: ohne Sets zu suchen ist unangenehm, ohne Index gar nicht
                # zu suchen ist schlimmer. Was gefehlt hat, steht danach in
                # `catalog_status().failed_types` — still ist das nicht.
                #
                # Am 2026-08-27 durchgemessen: S, P, M, B, G, C, I, O liefern zwischen
                # 1,5 MB und 34 MB XML, `U` (Unsorted Lot) antwortet REPRODUZIERBAR mit
                # HTTP 500 — auch nach allen Retries. Der Typ hat auf BrickLink keinen
                # Katalog-Export; er landet erwartungsgemäß in `failed_types`.
                try:
                    raw_items = web.catalog_items(type_id)
                except Exception as exc:  # noqa: BLE001 - bewusst breit, s.o.
                    failed[type_id] = f"{type(exc).__name__}: {exc}"
                    log.warning("Item-Typ %s nicht geladen: %s", type_id, exc)
                    continue
                rows = []
                for r in _items(raw_items):
                    item_no = r.get("ITEMID", "")
                    if not item_no:
                        continue
                    rows.append(
                        (
                            type_id,
                            item_no,
                            " ".join(r.get("ITEMNAME", "").split()),
                            int(r["CATEGORY"]) if r.get("CATEGORY", "").isdigit() else None,
                            int(r["ITEMYEAR"]) if r.get("ITEMYEAR", "").isdigit() else None,
                            float(r["ITEMWEIGHT"]) if r.get("ITEMWEIGHT") else None,
                            r.get("ALTITEMIDS") or None,
                            int(r["IMAGECOLOR"]) if r.get("IMAGECOLOR", "").isdigit() else None,
                        )
                    )
                db.executemany(
                    "INSERT OR REPLACE INTO items "
                    "(item_type, item_no, name, category_id, year, weight, alt_ids, image_color) "
                    "VALUES (?,?,?,?,?,?,?,?)",
                    rows,
                )
                per_type[type_id] = len(rows)
                db.commit()

            if not per_type:
                raise RuntimeError(
                    "Kein einziger Item-Typ konnte geladen werden — Index NICHT ersetzt. "
                    f"Fehler: {failed}"
                )

            db.execute("INSERT INTO items_fts(items_fts) VALUES('rebuild')")
            db.execute(
                "INSERT OR REPLACE INTO meta VALUES ('built_at', ?)", (str(int(started)),)
            )
            db.execute(
                "INSERT OR REPLACE INTO meta VALUES ('failed_types', ?)",
                (json.dumps(failed),),
            )
            db.execute("PRAGMA optimize")
            db.commit()
        except BaseException:
            db.close()
            if os.path.exists(tmp):
                os.remove(tmp)
            raise
        db.close()
        os.replace(tmp, self._path)
        return {
            "ok": not failed,
            "duration_seconds": round(time.time() - started, 1),
            "items_per_type": per_type,
            "items_total": sum(per_type.values()),
            "failed_types": failed,
        }

    def stale(self, max_age_days: int) -> bool:
        st = self.status()
        return not st.get("present") or st.get("age_days", 1e9) > max_age_days
