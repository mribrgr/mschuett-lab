"""Konfiguration — ausschließlich aus der Umgebung, keine Datei im Image.

Der Server bedient MEHRERE BrickLink-Stores (heute SteinAberFein von mschuett und
dinoland von mberger). Jeder Store hat sein eigenes OAuth-1.0a-Quadrupel
(Consumer-Paar + Token-Paar) und seinen eigenen BL-Benutzernamen; das Tageslimit von
5000 Requests gilt PRO Consumer-Key, wird also ebenfalls pro Store gezählt.

⚠️ Die Store-Trennung ist die wichtigste Eigenschaft dieses Servers. Es darf NIE
passieren, dass eine Bestellung im falschen Shop angefasst wird. Deshalb:
  * kein globaler „aktueller Store" — jeder Aufruf entscheidet selbst,
  * ohne bekannten Store wird der Aufruf abgelehnt, statt zu raten,
  * jede Antwort nennt den Store, gegen den sie gelaufen ist,
  * schreibende Aufrufe prüfen zusätzlich, dass `seller_name` der Bestellung zum
    Benutzernamen des gewählten Stores passt.

Der Katalog-Teil (Offline-Index, Textsuche) ist store-UNABHÄNGIG: er beschreibt
BrickLinks Katalog, nicht einen Shop. Dafür gibt es genau ein Web-Token.
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

# Header, unter denen OpenWebUI den anfragenden Nutzer mitschickt — aber NUR wenn
# dort `ENABLE_FORWARD_USER_INFO_HEADERS=True` gesetzt ist
# (open_webui/utils/headers.py). Ohne die Header kennt dieser Server den Aufrufer
# nicht und verlangt bei jedem store-bezogenen Tool eine explizite Store-Angabe.
USER_EMAIL_HEADER = "x-openwebui-user-email"
USER_NAME_HEADER = "x-openwebui-user-name"


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _int_env(name: str, default: int) -> int:
    raw = _env(name)
    return int(raw) if raw else default


@dataclass(frozen=True)
class Store:
    """Ein BrickLink-Shop mit eigenem API-Zugang."""

    slug: str  # stabiler Schlüssel, z.B. "steinaberfein"
    label: str  # Anzeigename, z.B. "SteinAberFein"
    username: str  # BL-Benutzername — Guard für Schreibzugriffe
    consumer_key: str
    consumer_secret: str
    token_value: str
    token_secret: str
    # Web-Token für die XML-Exporte (Bestellungen, Inventar, Wanted Lists). Der ist
    # KONTOGEBUNDEN, nicht an den Consumer-Key: mit dem Token von Konto A bekommt man
    # die Exporte von Shop A, egal welcher Store angefragt war. Deshalb pro Shop ein
    # eigenes Token — und vor der Auslieferung prüft `WebSession.verify_account`, dass
    # der Kontoname zum Shop passt.
    web_token: str = ""
    # Postfach für die BrickLink-Benachrichtigungsmails. Nur damit sind Anfragen
    # sichtbar, die an KEINER Bestellung hängen („Contact Member") — die API zeigt
    # die nicht, und der Web-Weg ist für die TPA-Session gesperrt.
    mail_host: str = ""
    mail_port: int = 993
    mail_user: str = ""
    mail_password: str = ""
    mail_folder: str = "INBOX"

    @property
    def usable(self) -> bool:
        return all(
            [self.consumer_key, self.consumer_secret, self.token_value, self.token_secret]
        )

    @property
    def has_web(self) -> bool:
        return bool(self.web_token)

    @property
    def has_mailbox(self) -> bool:
        return all([self.mail_host, self.mail_user, self.mail_password])

    @property
    def aliases(self) -> set[str]:
        """Alles, worüber dieser Store angesprochen werden darf (kleingeschrieben)."""
        return {v.strip().lower() for v in (self.slug, self.label, self.username) if v.strip()}


@dataclass(frozen=True)
class Config:
    stores: tuple[Store, ...]
    # E-Mail oder Anzeigename (kleingeschrieben) → Store-Slug. Greift nur, wenn
    # OpenWebUI die User-Header mitschickt.
    user_defaults: dict[str, str]

    # ── Web-Pfad (nur Katalog-Downloads, store-unabhängig) ─────────────────
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

    # ── Öffentliche Download-Links für die Export-Dateien ──────────────────
    # Ausgeliefert wird von einem nginx-Sidecar, nicht vom MCP selbst. Fehlt das
    # Geheimnis oder die Basis-URL, gibt es einfach keine Links — die Dateien liegen
    # dann nur im PVC.
    files_base_url: str
    files_path: str
    # Zweiter Präfix für die Ergebnisse der Code-Sandbox. Getrennt gehalten, weil
    # nginx pro Präfix ein Verzeichnis freigibt — /data selbst darf NIE freigegeben
    # werden, dort liegen auch state.db und catalog.db.
    files_workspace_path: str
    files_secret: str
    files_ttl_minutes: int

    @property
    def has_public_links(self) -> bool:
        return bool(self.files_base_url and self.files_secret)

    @property
    def has_web_session(self) -> bool:
        """Gibt es irgendein Web-Token? Für den Katalog reicht ein beliebiges."""
        return bool(self.web_client_id) and bool(self.catalog_web_token)

    @property
    def catalog_web_token(self) -> str:
        """Token für den KATALOG-Export.

        Der Katalog gehört BrickLink, nicht einem Shop — jedes Konto darf ihn ziehen.
        Deshalb: erst ein ausdrücklich gesetztes globales Token, sonst das erste
        Shop-Token. So funktioniert der Index auch, wenn nur ein Shop ein Web-Token hat.
        """
        if self.web_client_token:
            return self.web_client_token
        for store in self.stores:
            if store.web_token:
                return store.web_token
        return ""

    def store(self, key: str) -> Store | None:
        """Store über Slug, Anzeigename oder BL-Benutzernamen finden."""
        needle = (key or "").strip().lower()
        if not needle:
            return None
        for store in self.stores:
            if needle in store.aliases:
                return store
        return None

    def default_store_for(self, *identities: str | None) -> Store | None:
        """Store-Default für den anfragenden Nutzer (E-Mail oder Anzeigename)."""
        for identity in identities:
            if not identity:
                continue
            slug = self.user_defaults.get(identity.strip().lower())
            if slug:
                return self.store(slug)
        return None

    @classmethod
    def from_env(cls) -> "Config":
        # BRICKLINK_STORES ist die EINZIGE Quelle dafür, welche Shops es gibt, und
        # bestimmt auch die Reihenfolge in Aufzählungen. Format: "slug:Label,slug:Label".
        stores: list[Store] = []
        for entry in _env("BRICKLINK_STORES").split(","):
            entry = entry.strip()
            if not entry:
                continue
            slug, _, label = entry.partition(":")
            slug = slug.strip().lower()
            if not slug:
                continue
            prefix = f"BRICKLINK_STORE_{slug.upper().replace('-', '_')}_"
            stores.append(
                Store(
                    slug=slug,
                    label=(label.strip() or slug),
                    username=_env(prefix + "USERNAME"),
                    consumer_key=_env(prefix + "CONSUMER_KEY"),
                    consumer_secret=_env(prefix + "CONSUMER_SECRET"),
                    token_value=_env(prefix + "TOKEN_VALUE"),
                    token_secret=_env(prefix + "TOKEN_SECRET"),
                    web_token=_env(prefix + "WEB_TOKEN"),
                    mail_host=_env(prefix + "MAIL_HOST"),
                    mail_port=_int_env(prefix + "MAIL_PORT", 993),
                    mail_user=_env(prefix + "MAIL_USER"),
                    mail_password=_env(prefix + "MAIL_PASSWORD"),
                    mail_folder=_env(prefix + "MAIL_FOLDER", "INBOX"),
                )
            )

        defaults: dict[str, str] = {}
        for entry in _env("BRICKLINK_USER_DEFAULTS").split(","):
            identity, _, slug = entry.partition("=")
            identity = identity.strip().lower()
            slug = slug.strip().lower()
            if identity and slug:
                defaults[identity] = slug

        return cls(
            stores=tuple(stores),
            user_defaults=defaults,
            web_client_id=_env("BRICKLINK_WEB_CLIENT_ID", BRICKSTORE_CLIENT_ID),
            web_client_token=_env("BRICKLINK_WEB_CLIENT_TOKEN"),
            data_dir=_env("BRICKLINK_DATA_DIR", "/data"),
            # 5000 Requests/Tag sind das dokumentierte Limit PRO Consumer-Key, also
            # pro Store. Der Puffer bleibt bewusst groß: ein einziger unbedachter
            # Preis-Guide-Sweep über ein Inventar mit 12.000 Lots wäre sonst das
            # Tageslimit.
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
            files_base_url=_env("BRICKLINK_FILES_BASE_URL"),
            files_path=_env("BRICKLINK_FILES_PATH", "/bricklink-exports/"),
            files_workspace_path=_env("BRICKLINK_WORKSPACE_PATH", "/bricklink-workspace/"),
            files_secret=_env("BRICKLINK_FILES_SECRET"),
            # Eine Stunde: lang genug, um den Link aufs Handy zu schicken, kurz genug,
            # dass ein versehentlich geteilter Link nicht dauerhaft offen steht.
            files_ttl_minutes=_int_env("BRICKLINK_FILES_TTL_MINUTES", 60),
        )
