"""Mails bauen und verschicken.

Getrennt von mailbox.py, weil hier der einzige Vorgang liegt, der nach außen wirkt
und sich nicht zurücknehmen lässt. Eine verschickte Mail holt niemand zurück.
"""

from __future__ import annotations

import re
import smtplib
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid

# Absichtlich streng: genau eine Adresse pro Eintrag, kein Display-Name, kein
# Komma. Wer "Max <a@b.de>, alle@firma.de" in ein einzelnes Feld schreibt, meint
# meistens etwas anderes als was passiert — lieber ablehnen und nachfragen lassen.
ADDRESS = re.compile(r"^[^@\s,<>]+@[^@\s,<>]+\.[A-Za-z]{2,}$")


class SendError(RuntimeError):
    pass


def check_recipients(values: list[str], limit: int) -> list[str]:
    out: list[str] = []
    for v in values:
        v = (v or "").strip()
        if not v:
            continue
        if not ADDRESS.match(v):
            raise SendError(
                f"{v!r} ist keine einzelne, einfache E-Mail-Adresse. Jede Adresse gehört "
                "als eigener Listeneintrag, ohne Anzeigename und ohne Komma."
            )
        if v.lower() not in [o.lower() for o in out]:
            out.append(v)
    if not out:
        raise SendError("Keine Empfängeradresse angegeben.")
    if len(out) > limit:
        raise SendError(
            f"{len(out)} Empfänger, erlaubt sind {limit}. Das ist eine Schranke gegen "
            "Versehen — für einen echten Verteiler bitte den Menschen fragen."
        )
    return out


def build(
    sender: str,
    sender_name: str,
    to: list[str],
    subject: str,
    body: str,
    cc: list[str] | None = None,
    reply_to_message_id: str = "",
) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = formataddr((sender_name, sender)) if sender_name else sender
    msg["To"] = ", ".join(to)
    if cc:
        msg["Cc"] = ", ".join(cc)
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    # Domain der Absenderadresse statt des Pod-Hostnamens: sonst steht in jeder
    # Message-ID der k8s-Podname — ein unnötiges Detail nach außen.
    msg["Message-ID"] = make_msgid(domain=sender.rsplit("@", 1)[-1] or None)
    if reply_to_message_id:
        # Ohne diese beiden Header hängt die Antwort im Thread des Empfängers nicht
        # an der ursprünglichen Mail, sondern startet einen neuen.
        msg["In-Reply-To"] = reply_to_message_id
        msg["References"] = reply_to_message_id
    msg.set_content(body)
    return msg


def send(
    host: str,
    port: int,
    user: str,
    password: str,
    msg: EmailMessage,
    recipients: list[str],
) -> None:
    try:
        with smtplib.SMTP_SSL(host, port, timeout=30) as smtp:
            smtp.login(user, password)
            smtp.send_message(msg, from_addr=user, to_addrs=recipients)
    except smtplib.SMTPAuthenticationError as exc:
        raise SendError(
            f"SMTP-Anmeldung als {user} abgelehnt: {exc}. Es braucht dasselbe "
            "App-Passwort wie für IMAP."
        ) from exc
    except Exception as exc:  # noqa: BLE001
        raise SendError(f"Versand über {host}:{port} gescheitert: {exc}") from exc
