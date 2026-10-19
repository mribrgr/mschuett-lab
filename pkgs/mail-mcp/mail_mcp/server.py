"""MCP-Server für EIN Postfach über IMAP/SMTP — anbieterneutral.

Entstanden aus einer Gmail-IMAP-WIP vom 2026-09-04: Googles offizieller Gmail-MCP
ist für Consumer-Konten gesperrt, und für AOL gibt es gar keinen. IMAP mit
App-Passwort funktioniert bei beiden. Welches Postfach eine Instanz bedient, steht
ausschließlich in modules/mail-mcp.nix — hier gibt es keine Anbieter-Defaults.

Warum kein fertiger Server von der Stange (geprüft 2026-10-13): der reifste
Kandidat, `mcp-email-server`, bringt ~17 Python-Abhängigkeiten mit, hat KEINE
Authentifizierung am HTTP-Endpunkt und veröffentlicht fast täglich. Bei
Vollzugriff auf ein Postfach wiegt jede Zeile fremder Code schwer; der Bedarf hier
(suchen, lesen, Entwurf, optional senden) passt in die Standardbibliothek.

Transport: Streamable HTTP — Open WebUI spricht natives MCP ausschließlich darüber.

Was dieser Server NICHT tut:
  * keine Flags ändern (kein Als-gelesen-Markieren),
  * nichts löschen, nichts verschieben,
  * nicht senden, solange MAIL_ALLOW_SEND nicht gesetzt ist.

Der Bearer-Token ist die zweite Schranke hinter der CiliumNetworkPolicy; beides
steht in modules/mail-mcp.nix.
"""

from __future__ import annotations

import imaplib
import logging
import threading
from collections.abc import Callable
from typing import Any, TypeVar

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_http_headers

from . import compose, mailbox
from .config import Config
from .mailbox import Mailbox, MailboxError

log = logging.getLogger("mail-mcp")

USER_EMAIL_HEADER = "x-openwebui-user-email"

cfg = Config.from_env()
box = Mailbox(host=cfg.imap_host, port=cfg.imap_port, user=cfg.address, password=cfg.password)

auth = None
if not cfg.bearer_token and not cfg.allow_no_auth:
    # Fail closed: ein leer entschlüsseltes Secret darf den Endpunkt nicht still
    # öffnen — dann stünde nur noch die CNP zwischen Netz und Postfach.
    raise SystemExit("MAIL_MCP_BEARER fehlt — ohne Token startet der Server nicht.")
if cfg.bearer_token:
    from fastmcp.server.auth import StaticTokenVerifier

    auth = StaticTokenVerifier(
        {cfg.bearer_token: {"client_id": "open-webui", "scopes": ["mail"]}}
    )

mcp = FastMCP(
    name="mail",
    instructions=(
        f"Zugriff auf das E-Mail-Postfach {cfg.label} ({cfg.address}).\n"
        "\n"
        "Lesen: search liefert Kopfdaten und eine kurze Vorschau, get_message "
        "den Volltext einer Mail anhand ihrer uid. Lesen verändert nichts — auch der "
        "Ungelesen-Status bleibt, wie er ist.\n"
        "Schreiben: create_draft legt einen Entwurf im Postfach ab, der dort von "
        "einem Menschen geprüft und abgeschickt wird. "
        + (
            "send verschickt sofort und endgültig — vorher Empfänger, Betreff und "
            "Text ausdrücklich vom Nutzer bestätigen lassen."
            if cfg.allow_send
            else "Direktes Versenden ist abgeschaltet."
        )
        + "\nLöschen, Verschieben und Markieren gibt es hier nicht."
    ),
    auth=auth,
)

T = TypeVar("T")


def _wrap(fn: Callable[..., T], *args: Any, **kwargs: Any) -> T:
    """Fachliche Fehler als ToolError ans Modell, statt als Stacktrace ins Leere."""
    if not cfg.usable:
        raise ToolError(
            "Für dieses Postfach sind keine Zugangsdaten hinterlegt "
            "(MAIL_ADDRESS/MAIL_PASSWORD/MAIL_IMAP_HOST). Ohne sie geht kein Zugriff."
        )
    try:
        return fn(*args, **kwargs)
    except (MailboxError, compose.SendError) as exc:
        raise ToolError(str(exc)) from exc
    except ValueError as exc:
        # z.B. Zeilenumbruch im Betreff: EmailMessage lehnt Header-Injection ab.
        raise ToolError(f"Ungültige Eingabe: {exc}") from exc
    except imaplib.IMAP4.error as exc:
        raise ToolError(f"IMAP-Server lehnt ab: {exc}") from exc
    except OSError as exc:
        raise ToolError(f"Netzwerkfehler zu {cfg.imap_host}: {exc}") from exc


def _caller() -> str:
    try:
        return get_http_headers().get(USER_EMAIL_HEADER) or "unbekannt"
    except Exception:  # noqa: BLE001 - außerhalb eines HTTP-Requests (Tests)
        return "unbekannt"


# Entwurfsordner einmal ermitteln. Ändert sich der Name im Konto (selten), hilft
# ein Pod-Neustart oder MAIL_DRAFTS_FOLDER.
_drafts_lock = threading.Lock()
_drafts: str | None = cfg.drafts_folder or None


def _drafts_folder() -> str:
    global _drafts
    with _drafts_lock:
        if _drafts is None:
            found = mailbox.special_folder(
                mailbox.list_folders(box),
                "\\Drafts",
                ("Drafts", "Draft", "Entwürfe", "[Gmail]/Drafts", "[Gmail]/Entwürfe"),
            )
            if not found:
                raise MailboxError(
                    "Kein Entwurfsordner gefunden (weder per \\Drafts-Markierung noch unter "
                    "einem üblichen Namen). MAIL_DRAFTS_FOLDER im Modul setzen."
                )
            _drafts = found
        return _drafts


@mcp.tool(name="list_folders")
def list_folders() -> dict:
    """Alle Ordner des Postfachs auflisten, mit IMAP-Markierungen wie \\Sent oder \\Drafts.

    Nützlich, bevor in einem anderen Ordner als dem Posteingang gesucht wird — die
    Namen sind je Anbieter verschieden („Sent" vs. „Gesendet").
    """
    folders = _wrap(mailbox.list_folders, box)
    return {"address": cfg.address, "folders": folders}


@mcp.tool(name="search")
def search(
    folder: str = "INBOX",
    since_days: int = 14,
    limit: int = 20,
    unread_only: bool = False,
    sender: str = "",
    subject: str = "",
    text: str = "",
) -> dict:
    """Mails suchen, neueste zuerst. Liefert Kopfdaten, ungelesen-Status und eine kurze
    Vorschau — nicht den Volltext.

    Alle Filter sind UND-verknüpft; `sender`, `subject` und `text` sind Teilstrings.
    `since_days=0` hebt die Zeitgrenze auf (bei großen Ordnern langsam). `limit` max. 50.
    `total` nennt die Gesamtzahl der Treffer, auch wenn nur `limit` geliefert werden.
    Den Volltext holt die get_message-Funktion mit der `uid` aus dieser Liste.
    """
    total, found = _wrap(
        mailbox.search,
        box,
        folder=folder,
        since_days=since_days,
        limit=limit,
        unread_only=unread_only,
        sender=sender,
        subject=subject,
        text=text,
    )
    return {
        "address": cfg.address,
        "folder": folder,
        "total": total,
        "count": len(found),
        "messages": found,
    }


@mcp.tool(name="get_message")
def get_message(uid: str, folder: str = "INBOX") -> dict:
    """Eine einzelne Mail im Volltext holen. `uid` und `folder` stammen aus der Suche.

    Sehr lange Mails werden gekürzt (`body_truncated`). Anhänge werden nur mit Namen
    genannt, nicht ausgeliefert.
    """
    return _wrap(mailbox.get, box, uid=uid, folder=folder)


@mcp.tool(name="create_draft")
def create_draft(
    to: list[str],
    subject: str,
    body: str,
    cc: list[str] | None = None,
    reply_to_message_id: str = "",
) -> dict:
    """Einen Entwurf im Postfach ablegen — OHNE ihn zu verschicken.

    Der sichere Weg für alles, was ein Mensch noch ansehen soll: der Entwurf erscheint
    im Webmailer unter „Entwürfe" und geht dort mit einem Klick raus. Bei einer
    Antwort `reply_to_message_id` (die message_id der Originalmail) mitgeben, damit
    sie im richtigen Gesprächsverlauf landet. Jede Adresse als eigener Listeneintrag.
    """

    def run() -> dict:
        rcpt = compose.check_recipients(list(to), cfg.max_recipients)
        cc_list = compose.check_recipients(list(cc), cfg.max_recipients) if cc else []
        msg = compose.build(
            cfg.address, cfg.from_name, rcpt, subject, body, cc_list, reply_to_message_id
        )
        folder = _drafts_folder()
        mailbox.append_draft(box, folder, msg.as_bytes())
        log.info("Entwurf in %s abgelegt (an %s, Betreff %r) für %s", folder, rcpt, subject, _caller())
        return {"status": "draft_saved", "folder": folder, "to": rcpt, "cc": cc_list, "subject": subject}

    return _wrap(run)


def send(
    to: list[str],
    subject: str,
    body: str,
    cc: list[str] | None = None,
    reply_to_message_id: str = "",
) -> dict:
    """Eine Mail verschicken. Endgültig — eine verschickte Mail holt niemand zurück.

    Nur nach ausdrücklicher Bestätigung von Empfängern, Betreff und Text durch den
    Nutzer. Im Zweifel stattdessen einen Entwurf anlegen.
    """
    if not cfg.allow_send or not cfg.smtp_host:
        raise ToolError(
            "Versand ist für dieses Postfach abgeschaltet (MAIL_ALLOW_SEND). "
            "create_draft legt stattdessen einen Entwurf an."
        )

    def run() -> dict:
        rcpt = compose.check_recipients(list(to), cfg.max_recipients)
        cc_list = compose.check_recipients(list(cc), cfg.max_recipients) if cc else []
        msg = compose.build(
            cfg.address, cfg.from_name, rcpt, subject, body, cc_list, reply_to_message_id
        )
        compose.send(cfg.smtp_host, cfg.smtp_port, cfg.address, cfg.password, msg, rcpt + cc_list)
        log.info("Mail an %s verschickt (Betreff %r) für %s", rcpt + cc_list, subject, _caller())
        return {"status": "sent", "to": rcpt, "cc": cc_list, "subject": subject}

    return _wrap(run)


# Nur registrieren, wenn Versand erlaubt ist: ein Tool, das immer ablehnt, verleitet
# das Modell zu Fehlversuchen und verspricht dem Nutzer etwas, das es nicht gibt.
if cfg.allow_send and cfg.smtp_host:
    mcp.tool(name="send")(send)


@mcp.custom_route("/health", methods=["GET"])
async def health(_request):  # noqa: ANN001 - Starlette-Request
    # Bewusst OHNE IMAP-Login: die Probe läuft alle 10 s, und AOL sperrt Konten mit
    # auffällig vielen Anmeldungen. Ob das Postfach erreichbar ist, prüft chat-e2e.
    from starlette.responses import JSONResponse

    return JSONResponse({"status": "ok", "configured": cfg.usable, "send": cfg.allow_send})


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    if not cfg.usable:
        # Nicht abbrechen: der Pod soll laufen und beim Tool-Aufruf verständlich
        # meckern, statt in CrashLoopBackOff zu gehen und den Grund zu verstecken.
        log.warning("Keine Postfach-Zugangsdaten gesetzt — alle Tools werden ablehnen")
    else:
        log.info(
            "Postfach %s über %s:%s, Versand %s, Auth %s",
            cfg.address,
            cfg.imap_host,
            cfg.imap_port,
            "erlaubt" if cfg.allow_send else "gesperrt",
            "Bearer" if auth else "KEINE",
        )
    mcp.run(transport="http", host=cfg.host, port=cfg.port, path=cfg.path)


if __name__ == "__main__":
    main()
