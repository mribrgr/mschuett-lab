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
            CREATE TABLE IF NOT EXISTS quota (day TEXT PRIMARY KEY, calls INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS cache (
                key  TEXT PRIMARY KEY,
                ts   INTEGER NOT NULL,
                body TEXT NOT NULL
            );
            """
        )
        self._db.commit()
        self._lock = threading.Lock()
        self._budget = daily_budget

    # ── Kontingent ─────────────────────────────────────────────────────────
    def spend(self, n: int = 1) -> None:
        """Bucht n Requests. Wirft Quota, BEVOR das Limit überschritten wird."""
        today = date.today().isoformat()
        with self._lock:
            row = self._db.execute("SELECT calls FROM quota WHERE day=?", (today,)).fetchone()
            used = row[0] if row else 0
            if used + n > self._budget:
                raise Quota(
                    f"Tagesbudget erschöpft ({used}/{self._budget} Requests an {today}). "
                    "BrickLink erlaubt 5000/Tag; der Rest ist bewusster Puffer. "
                    "Morgen wieder, oder BRICKLINK_DAILY_BUDGET anheben."
                )
            self._db.execute(
                "INSERT INTO quota(day, calls) VALUES(?, ?) "
                "ON CONFLICT(day) DO UPDATE SET calls = calls + ?",
                (today, n, n),
            )
            self._db.commit()

    def usage(self) -> dict[str, Any]:
        today = date.today().isoformat()
        with self._lock:
            row = self._db.execute("SELECT calls FROM quota WHERE day=?", (today,)).fetchone()
            history = self._db.execute(
                "SELECT day, calls FROM quota ORDER BY day DESC LIMIT 7"
            ).fetchall()
        used = row[0] if row else 0
        return {
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
