"""Persistenter Zustand: Tages-Kontingent und Antwort-Cache.

Beides liegt in EINER SQLite-Datei im PVC (`state.db`), getrennt vom
Katalogindex (`catalog.db`) — der wird beim Refresh komplett ersetzt und
darf Kontingent/Cache nicht mitnehmen.
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from datetime import date
from typing import Any


class Quota(Exception):
    """Tagesbudget erschöpft. Wird als Tool-Fehler an das Modell gegeben."""


class State:
    def __init__(self, path: str, daily_budget: int) -> None:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        # check_same_thread=False: FastMCP bedient Tools aus einem Threadpool,
        # der Zugriff wird über _lock serialisiert.
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(
            """
            -- Kontingent PRO STORE: BrickLinks 5000/Tag hängen am Consumer-Key,
            -- und den hat jeder Shop einzeln. Ein gemeinsamer Zähler würde den
            -- einen Shop für den anderen ausbremsen.
            CREATE TABLE IF NOT EXISTS quota (
                day   TEXT NOT NULL,
                store TEXT NOT NULL DEFAULT '',
                calls INTEGER NOT NULL,
                PRIMARY KEY (day, store)
            );
            CREATE TABLE IF NOT EXISTS cache (
                key  TEXT PRIMARY KEY,
                ts   INTEGER NOT NULL,
                body TEXT NOT NULL
            );
            """
        )
        self._db.commit()
        self._migrate()
        self._lock = threading.Lock()
        self._budget = daily_budget

    def _migrate(self) -> None:
        """Schema nachziehen, wenn die Datei aus einer älteren Version stammt.

        ⚠️ `CREATE TABLE IF NOT EXISTS` migriert NICHTS: existiert die Tabelle, bleibt
        sie wie sie ist. Und die Datei überlebt jeden Deploy (sie liegt im PVC). Beim
        Multi-Shop-Umbau bekam `quota` die Spalte `store` — auf einer Bestandsdatei
        scheiterte danach JEDER Aufruf, der Kontingent buchen wollte, mit
        „no such column: store" (am 2026-08-27 im laufenden Pod genau so passiert,
        während die Exporte weiterliefen, weil die kein Kontingent buchen).
        Deshalb hier ein ausdrücklicher Schritt statt Hoffnung.
        """
        columns = {row[1] for row in self._db.execute("PRAGMA table_info(quota)")}
        if not columns or "store" in columns:
            return
        # Alte Zeilen kennen den Shop nicht — sie wandern auf den leeren Store-Namen,
        # statt einem Shop fälschlich zugerechnet zu werden. Es sind Tageszähler,
        # spätestens morgen ist die Zuordnung ohnehin bedeutungslos.
        self._db.executescript(
            """
            ALTER TABLE quota RENAME TO quota_legacy;
            CREATE TABLE quota (
                day   TEXT NOT NULL,
                store TEXT NOT NULL DEFAULT '',
                calls INTEGER NOT NULL,
                PRIMARY KEY (day, store)
            );
            INSERT INTO quota (day, store, calls) SELECT day, '', calls FROM quota_legacy;
            DROP TABLE quota_legacy;
            """
        )
        self._db.commit()

    # ── Kontingent ─────────────────────────────────────────────────────────
    def spend(self, store: str, n: int = 1) -> None:
        """Bucht n Requests für einen Store. Wirft Quota VOR dem Überschreiten."""
        today = date.today().isoformat()
        with self._lock:
            row = self._db.execute(
                "SELECT calls FROM quota WHERE day=? AND store=?", (today, store)
            ).fetchone()
            used = row[0] if row else 0
            if used + n > self._budget:
                raise Quota(
                    f"Tagesbudget für Store {store!r} erschöpft ({used}/{self._budget} "
                    f"Requests an {today}). BrickLink erlaubt 5000/Tag pro Consumer-Key; "
                    "der Rest ist bewusster Puffer. Morgen wieder, oder "
                    "BRICKLINK_DAILY_BUDGET anheben."
                )
            self._db.execute(
                "INSERT INTO quota(day, store, calls) VALUES(?, ?, ?) "
                "ON CONFLICT(day, store) DO UPDATE SET calls = calls + ?",
                (today, store, n, n),
            )
            self._db.commit()

    def usage(self, store: str) -> dict[str, Any]:
        today = date.today().isoformat()
        with self._lock:
            row = self._db.execute(
                "SELECT calls FROM quota WHERE day=? AND store=?", (today, store)
            ).fetchone()
            history = self._db.execute(
                "SELECT day, calls FROM quota WHERE store=? ORDER BY day DESC LIMIT 7",
                (store,),
            ).fetchall()
        used = row[0] if row else 0
        return {
            "store": store,
            "day": today,
            "used": used,
            "budget": self._budget,
            "remaining": max(0, self._budget - used),
            "bricklink_hard_limit_per_day": 5000,
            "last_7_days": [{"day": d, "calls": c} for d, c in history],
        }

    # ── Cache ──────────────────────────────────────────────────────────────
    def cached(self, key: str, ttl: int) -> Any | None:
        if ttl <= 0:
            return None
        with self._lock:
            row = self._db.execute("SELECT ts, body FROM cache WHERE key=?", (key,)).fetchone()
        if not row:
            return None
        ts, body = row
        if time.time() - ts > ttl:
            return None
        return json.loads(body)

    def store(self, key: str, value: Any) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO cache(key, ts, body) VALUES(?,?,?) "
                "ON CONFLICT(key) DO UPDATE SET ts=excluded.ts, body=excluded.body",
                (key, int(time.time()), json.dumps(value)),
            )
            self._db.commit()

    def drop_cache(self, prefix: str = "") -> int:
        with self._lock:
            cur = self._db.execute("DELETE FROM cache WHERE key LIKE ?", (prefix + "%",))
            self._db.commit()
            return cur.rowcount
