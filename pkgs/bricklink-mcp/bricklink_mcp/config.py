"""Konfiguration — ausschließlich aus der Umgebung, keine Datei im Image.

Die Store-API-Credentials sind ein OAuth-1.0a-Vierer (Consumer-Paar +
Token-Paar). Das Token ist bei BrickLink an eine REGISTRIERTE IP gebunden
("BrickLink resources are accessible only from the registered location",
api.page?page=general) — für dieses Deployment also an die netcup-Public-IP.
Läuft der Server woanders, antwortet die API mit einem Auth-Fehler; das ist
kein Bug in diesem Code.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

# Client-ID von BrickStore (github.com/rgriebl/brickstore,
# src/utility/transfer.cpp: BL_CLIENT_ID_VALUE). Sie ist KEIN Geheimnis und
# kein Credential: sie identifiziert nur die Anwendung gegenüber
# account.prod.member.bricklink.info. Das eigentliche Credential ist der
# clientToken, den der Nutzer SELBST auf
# bricklink.com/v3/brickstore-access-management.page erzeugt.
#
# ⚠️ Bewusste Entscheidung (2026-08-27): wir treten für die Web-Endpunkte
# (Katalog-Downloads) als BrickStore auf, weil BrickLink für Dritt-Clients
# keinen eigenen Weg anbietet, an einen Session-Token zu kommen. Die API-ToU
# lizenzieren den Zugang "personal, non-sublicenseable, non-transferable" —
# der Token gehört uns, die Client-ID nicht. Deshalb gilt hier:
#   * NUR lesende Katalog-Downloads über diesen Pfad (kein Order-/Store-Zugriff,
#     das läuft über die offizielle API mit eigenem Consumer-Key),
#   * ein Refresh pro Woche, kein Dauerfeuer,
#   * überschreibbar per BRICKLINK_WEB_CLIENT_ID, falls BrickLink uns eine
#     eigene ID gibt.
BRICKSTORE_CLIENT_ID = "ca629c09-4d8c-45dc-8a6f-bfb2b058f720"


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _int_env(name: str, default: int) -> int:
    raw = _env(name)
    return int(raw) if raw else default


@dataclass(frozen=True)
class Config:
    # ── Store API v1 (offiziell, eigener Consumer-Key) ──────────────────────
    consumer_key: str
    consumer_secret: str
    token_value: str
    token_secret: str
    # Eigener BL-Benutzername. Guard für JEDEN Schreibzugriff: eine Bestellung
    # darf nur verändert werden, wenn wir dort der VERKÄUFER sind.
    store_username: str

    # ── Web-Pfad (nur Katalog-Downloads) ───────────────────────────────────
    web_client_id: str
    web_client_token: str

    # ── Betrieb ────────────────────────────────────────────────────────────
    data_dir: str
    daily_budget: int
    catalog_refresh_days: int
    host: str
    port: int
    path: str
    bearer_token: str
    user_agent: str

    @property
    def has_store_api(self) -> bool:
        return all(
            [self.consumer_key, self.consumer_secret, self.token_value, self.token_secret]
        )

    @property
    def has_web_session(self) -> bool:
        return bool(self.web_client_id and self.web_client_token)

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            consumer_key=_env("BRICKLINK_CONSUMER_KEY"),
            consumer_secret=_env("BRICKLINK_CONSUMER_SECRET"),
            token_value=_env("BRICKLINK_TOKEN_VALUE"),
            token_secret=_env("BRICKLINK_TOKEN_SECRET"),
            store_username=_env("BRICKLINK_STORE_USERNAME"),
            web_client_id=_env("BRICKLINK_WEB_CLIENT_ID", BRICKSTORE_CLIENT_ID),
            web_client_token=_env("BRICKLINK_WEB_CLIENT_TOKEN"),
            data_dir=_env("BRICKLINK_DATA_DIR", "/data"),
            # 5000 Requests/Tag sind das dokumentierte Limit. Der Puffer bleibt
            # bewusst groß: ein einziger unbedachter Preis-Guide-Sweep über ein
            # Inventar mit 3000 Lots wäre sonst das Tageslimit.
            daily_budget=_int_env("BRICKLINK_DAILY_BUDGET", 4000),
            catalog_refresh_days=_int_env("BRICKLINK_CATALOG_REFRESH_DAYS", 7),
            host=_env("BRICKLINK_MCP_HOST", "0.0.0.0"),
            port=_int_env("BRICKLINK_MCP_PORT", 8081),
            path=_env("BRICKLINK_MCP_PATH", "/mcp"),
            bearer_token=_env("BRICKLINK_MCP_BEARER"),
            user_agent=_env(
                "BRICKLINK_USER_AGENT",
                "BrickStore/2026.8.1 (bricklink-mcp; mschuett-lab)",
            ),
        )
