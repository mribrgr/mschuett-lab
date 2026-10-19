"""Konfiguration aus der Umgebung.

Alles kommt aus Env-Variablen, die modules/mail-mcp.nix aus einem k8s-Secret bzw.
dem Deployment speist. Kein Config-File und KEINE Anbieter-Defaults im Code: ein
Mail-Server, der ohne Zutun irgendein Postfach anspricht, ist ein Unfall mit Ansage.
Welcher Anbieter (AOL, Gmail, …) gemeint ist, steht ausschließlich im Modul.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _int(name: str, default: int) -> int:
    try:
        return int(_env(name) or default)
    except ValueError:
        return default


def _bool(name: str, default: bool = False) -> bool:
    v = _env(name).lower()
    if not v:
        return default
    return v in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Config:
    # ── Postfach ───────────────────────────────────────────────────────────
    address: str
    password: str
    imap_host: str
    imap_port: int
    smtp_host: str
    smtp_port: int

    # Absendername in der From-Zeile. Ohne ihn steht dort nur die nackte Adresse.
    from_name: str
    # Entwurfsordner. Leer = per SPECIAL-USE (\Drafts) aus LIST ermitteln — die
    # Namen sind je Anbieter und Kontosprache verschieden („Draft", „Drafts",
    # „[Gmail]/Entwürfe").
    drafts_folder: str

    # ── Schranken ──────────────────────────────────────────────────────────
    # Senden ist der EINZIGE Vorgang hier, der nach außen wirkt und sich nicht
    # zurücknehmen lässt. Deshalb ein eigener Schalter, der im Modul sichtbar
    # steht und mit einer Zeile wieder zugeht — nicht im Code versteckt.
    allow_send: bool
    # Obergrenze pro Aufruf. Schützt nicht vor Missbrauch, sondern vor Versehen:
    # ein Modell, das „schick das an alle" wörtlich nimmt, kommt nicht weit.
    max_recipients: int

    # ── Darstellung ────────────────────────────────────────────────────────
    # Menschlicher Name des Postfachs für die Server-Instructions. Einen
    # Tool-Präfix braucht es NICHT: Open WebUI stellt die Tool-Server-ID selbst
    # voran (`aol_search`, utils/middleware.py `f'{server_id}_{name}'`).
    label: str

    # ── Betrieb ────────────────────────────────────────────────────────────
    host: str
    port: int
    path: str
    # Statischer Bearer-Token. Ohne ihn startet der Server nur, wenn
    # MAIL_MCP_ALLOW_NO_AUTH ausdrücklich gesetzt ist (lokale Tests).
    bearer_token: str
    allow_no_auth: bool

    @property
    def usable(self) -> bool:
        return all([self.address, self.password, self.imap_host])

    @classmethod
    def from_env(cls) -> Config:
        return cls(
            address=_env("MAIL_ADDRESS"),
            password=_env("MAIL_PASSWORD"),
            imap_host=_env("MAIL_IMAP_HOST"),
            imap_port=_int("MAIL_IMAP_PORT", 993),
            smtp_host=_env("MAIL_SMTP_HOST"),
            smtp_port=_int("MAIL_SMTP_PORT", 465),
            from_name=_env("MAIL_FROM_NAME"),
            drafts_folder=_env("MAIL_DRAFTS_FOLDER"),
            allow_send=_bool("MAIL_ALLOW_SEND", False),
            max_recipients=_int("MAIL_MAX_RECIPIENTS", 5),
            label=_env("MAIL_LABEL") or _env("MAIL_ADDRESS") or "Postfach",
            host=_env("MAIL_MCP_HOST", "0.0.0.0"),
            port=_int("MAIL_MCP_PORT", 8083),
            path=_env("MAIL_MCP_PATH", "/mcp"),
            bearer_token=_env("MAIL_MCP_BEARER"),
            allow_no_auth=_bool("MAIL_MCP_ALLOW_NO_AUTH", False),
        )
