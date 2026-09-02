"""Eingehende BrickLink-Nachrichten über die Benachrichtigungs-Mails mitlesen.

Warum dieser Umweg: BrickLinks Store API liefert ausschließlich Nachrichten, die an
einer BESTELLUNG hängen (`GET /orders/{id}/messages`). Anfragen über „Contact Member"
oder von einer Katalogseite haben keine Bestellnummer und sind dort unsichtbar — genau
die Sorte „ich hätte eine Frage zu dieser Figur", an der mschuett am 2026-09-01
hängengeblieben ist.

Der Web-Weg fällt aus: BrickLink gibt der TPA-Session (BrickStore-Client-ID) nur die
Endpunkte frei, die BrickStore selbst benutzt. Am 2026-09-02 gemessen —
`catalogDownload.asp`, `orderDetail.asp`, `v2/wanted/list.page` antworten mit 200,
`orderReceived.asp`, `memberInfo.asp`, `orderSettings.asp`, `v2/mystore/display.page`
mit 302 auf die Anmeldeseite. Das Postfach liegt außerhalb; keine URL ändert das.

Bleibt die Mail: BrickLink schickt jede eingegangene Nachricht an die Kontoadresse.
Dieses Modul liest sie per IMAP, LESEND — es setzt keine Flags (BODY.PEEK) und löscht
nichts. Der Ungelesen-Status im Postfach von Max bleibt also unberührt.

⚠️ Antworten geht hierüber NICHT. BrickLink verschickt die Mails über einen
No-Reply-Absender; eine Antwortmail landet nicht im BrickLink-Thread. Die Tools liefern
deshalb den Deep-Link in die Web-UI mit, wo die Antwort mit zwei Klicks rausgeht.
"""

from __future__ import annotations

import email
import imaplib
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from email.header import decode_header, make_header
from email.message import Message
from typing import Any

# BrickLink-Absender. Kein Filter auf ein einzelnes Konto: die Domain hat sich in der
# Vergangenheit geändert (bricklink.com, mail.bricklink.com, lego.com-Relays).
SENDER_HINTS = ("bricklink", "lego.com")


class MailboxError(RuntimeError):
    pass


@dataclass(frozen=True)
class Mailbox:
    host: str
    port: int
    user: str
    password: str
    folder: str

    @property
    def usable(self) -> bool:
        return all([self.host, self.user, self.password])


def _decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:  # noqa: BLE001 - kaputte Header sind keine Ausnahme, sondern Alltag
        return value


def _body_text(msg: Message) -> str:
    """Klartext einer Mail. HTML wird notdürftig entkleidet, wenn es keinen Text gibt."""
    plain: list[str] = []
    html: list[str] = []
    for part in msg.walk():
        if part.get_content_maintype() != "text":
            continue
        if part.get_filename():
            continue
        try:
            raw = part.get_payload(decode=True) or b""
            charset = part.get_content_charset() or "utf-8"
            text = raw.decode(charset, errors="replace")
        except Exception:  # noqa: BLE001
            continue
        if part.get_content_subtype() == "html":
            html.append(text)
        else:
            plain.append(text)
    if plain:
        return "\n".join(plain).strip()
    if html:
        stripped = re.sub(r"(?is)<(script|style).*?</\1>", " ", "\n".join(html))
        stripped = re.sub(r"(?s)<br\s*/?>|</p>", "\n", stripped)
        stripped = re.sub(r"(?s)<[^>]+>", " ", stripped)
        stripped = re.sub(r"&nbsp;?", " ", stripped)
        stripped = re.sub(r"&amp;", "&", stripped)
        return re.sub(r"[ \t]{2,}", " ", stripped).strip()
    return ""


def parse_notification(raw: bytes, uid: str = "") -> dict[str, Any]:
    """Eine BrickLink-Benachrichtigungsmail in ein auswertbares Dict."""
    msg = email.message_from_bytes(raw)
    subject = _decode(msg.get("Subject"))
    sender = _decode(msg.get("From"))
    body = _body_text(msg)

    sent_at = None
    if msg.get("Date"):
        try:
            sent_at = email.utils.parsedate_to_datetime(msg["Date"]).astimezone(
                timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
        except (TypeError, ValueError):
            sent_at = msg.get("Date")

    # Absendendes Mitglied: BrickLink schreibt es in den Betreff („Message from X",
    # „New message from X") oder in den Fließtext („from member X").
    member = None
    for pattern in (
        r"(?:message|nachricht)\s+(?:from|von)\s+([A-Za-z0-9_.\-]{2,30})",
        r"(?:from|von)\s+member\s+([A-Za-z0-9_.\-]{2,30})",
    ):
        m = re.search(pattern, subject + "\n" + body, re.I)
        if m:
            member = m.group(1)
            break

    order_id = None
    m = re.search(r"order\s*#?\s*(\d{6,})", subject + "\n" + body, re.I)
    if m:
        order_id = m.group(1)

    links = []
    for m in re.finditer(r"https?://[^\s\"'<>)]+bricklink\.com[^\s\"'<>)]*", body):
        url = m.group(0).rstrip(".,;")
        if url not in links:
            links.append(url)

    kind = "other"
    low = (subject + " " + body[:400]).lower()
    if "message" in low or "nachricht" in low:
        kind = "message"
    elif "feedback" in low or "bewertung" in low:
        kind = "feedback"
    elif "order" in low or "bestellung" in low:
        kind = "order"

    return {
        "uid": uid,
        "kind": kind,
        "subject": subject,
        "from_header": sender,
        "member": member,
        "order_id": order_id,
        "sent_at": sent_at,
        "body": body,
        "bricklink_links": links[:5],
    }


def fetch(box: Mailbox, since_days: int = 14, limit: int = 20, unread_only: bool = False) -> list[dict[str, Any]]:
    """Benachrichtigungsmails holen — ohne Flags zu verändern.

    `BODY.PEEK` statt `BODY`: sonst markiert der Abruf die Mails als gelesen und
    Max' Postfach sieht danach anders aus, als er es verlassen hat.
    """
    if not box.usable:
        raise MailboxError(
            "Für diesen Shop ist kein Postfach hinterlegt (MAIL_HOST/MAIL_USER/"
            "MAIL_PASSWORD im Shop-Secret). Ohne die Zugangsdaten gibt es nur die "
            "bestellbezogenen Nachrichten aus der API."
        )
    since = (date.today() - timedelta(days=max(1, since_days))).strftime("%d-%b-%Y")
    criteria = ["SINCE", since]
    if unread_only:
        criteria.insert(0, "UNSEEN")

    try:
        conn = imaplib.IMAP4_SSL(box.host, box.port)
    except Exception as exc:  # noqa: BLE001
        raise MailboxError(f"IMAP-Verbindung zu {box.host}:{box.port} gescheitert: {exc}") from exc
    try:
        try:
            conn.login(box.user, box.password)
        except imaplib.IMAP4.error as exc:
            raise MailboxError(
                f"IMAP-Anmeldung als {box.user} abgelehnt: {exc}. Bei Gmail braucht es "
                "ein App-Passwort, das normale Kontopasswort funktioniert nicht."
            ) from exc
        conn.select(box.folder, readonly=True)
        typ, data = conn.search(None, *criteria)
        if typ != "OK":
            raise MailboxError(f"IMAP-Suche fehlgeschlagen: {typ}")
        ids = (data[0] or b"").split()
        out: list[dict[str, Any]] = []
        for mail_id in reversed(ids):
            if len(out) >= max(1, min(limit, 100)):
                break
            typ, payload = conn.fetch(mail_id, "(BODY.PEEK[])")
            if typ != "OK" or not payload or not isinstance(payload[0], tuple):
                continue
            entry = parse_notification(payload[0][1], uid=mail_id.decode())
            if not any(h in entry["from_header"].lower() for h in SENDER_HINTS):
                continue
            out.append(entry)
        return out
    finally:
        try:
            conn.logout()
        except Exception:  # noqa: BLE001
            pass
