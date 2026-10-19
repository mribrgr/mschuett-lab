"""IMAP-Zugriff auf das Postfach.

Bewusst `imaplib` aus der Standardbibliothek statt einer Client-Bibliothek: der
Funktionsumfang, den wir brauchen, ist klein, und bei Vollzugriff auf ein Postfach
ist jede zusätzliche Abhängigkeit ein zusätzliches Risiko.

LESEN VERÄNDERT NICHTS. `select(readonly=True)` plus `BODY.PEEK` — der Abruf setzt
kein \\Seen. Wer sein Postfach mit 12 ungelesenen Mails verlässt, findet danach 12
ungelesene Mails vor. Der einzige schreibende Vorgang in dieser Datei ist
`append_draft`, und der legt eine neue Mail an, statt eine bestehende anzufassen.

Zwei Fallen von imaplib, an denen ein naiver Client still falsche Ergebnisse liefert:

  * Suchbegriffe werden NICHT gequotet. `conn.search(None, "SUBJECT", "Hallo Welt")`
    schickt `SUBJECT Hallo Welt` — der Server sucht dann nach „Hallo" im Betreff und
    hält „Welt" für das nächste Kriterium. Ordnernamen quotet imaplib dagegen selbst
    (`_astring`). Deshalb `_quoted` unten.
  * `search`/`fetch` arbeiten mit SEQUENZNUMMERN, die sich verschieben, sobald im
    Postfach etwas gelöscht wird. Zwischen „suchen" und „Mail 17 holen" kann das
    eine andere Mail sein. Hier deshalb durchgehend `UID SEARCH`/`UID FETCH`.

Die Bausteine `_decode` und `_body_text` stammen aus bricklink_mcp/mailbox.py und
sind dort seit 2026-09 im Einsatz; bewusst kopiert statt importiert, damit dieser
Server nicht am BrickLink-Paket hängt.
"""

from __future__ import annotations

import base64
import email
import email.utils
import imaplib
import re
from dataclasses import dataclass
from datetime import date, timedelta, timezone
from email.header import decode_header, make_header
from email.message import Message
from typing import Any

# Für die Trefferliste reicht der Anfang jeder Mail. Ohne Grenze lädt eine Suche über
# 20 Mails mit je 15 MB Anhang 300 MB, nur um 400 Zeichen Vorschau zu zeigen.
PREVIEW_FETCH_BYTES = 64 * 1024
# Volltext-Grenze für get: ein Newsletter mit 200 kB HTML sprengt sonst das
# Kontextfenster, ohne dass das Modell davon etwas hätte.
BODY_MAX_CHARS = 40_000
# Download-Grenze für get. Eine Mail mit 40 MB Anhang hielte sonst Rohdaten plus
# MIME-Baum im Speicher und sprengte das Pod-Limit (256 Mi). Der Text steht fast
# immer vor den Anhängen; was dahinter abgeschnitten wird, meldet `fetch_truncated`.
GET_FETCH_BYTES = 8 * 1024 * 1024
# Socket-Timeout PRO IMAP-Operation (connect, LOGIN, LIST, …), nicht für den ganzen
# Tool-Aufruf. Gmail braucht für LIST und LOGOUT jeweils ~10 s (gemessen
# 2026-10-19 aus dem Pod; AOL: 0,5 s), und gut 2 % der Läufe rissen die frühere
# Grenze von 30 s. open-webui selbst bricht einen MCP-Aufruf erst nach 300 s Funkstille
# ab (MCP-SDK, httpx read=300) — vier Operationen à 60 s bleiben darunter, und das
# Modell bekommt im Fehlerfall unsere lesbare Meldung statt eines httpx-ReadTimeout.
IMAP_TIMEOUT_S = 60

# IMAP-Datumsformat ist englisch, unabhängig von der Locale des Containers.
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


class MailboxError(RuntimeError):
    pass


@dataclass(frozen=True)
class Mailbox:
    host: str
    port: int
    user: str
    password: str


# ── Modified UTF-7 (RFC 3501 §5.1.3) ─────────────────────────────────────────
# Ordnernamen mit Umlauten stehen im Protokoll als „Entw&APw-rfe". Nach außen
# (Modell, Nutzer) geben wir Klartext, nach innen (SELECT/APPEND) kodieren wir.


def utf7_decode(name: str) -> str:
    def repl(m: re.Match[str]) -> str:
        chunk = m.group(1)
        if not chunk:
            return "&"
        b64 = chunk.replace(",", "/")
        b64 += "=" * (-len(b64) % 4)
        try:
            return base64.b64decode(b64).decode("utf-16-be")
        except Exception:  # noqa: BLE001 - kaputte Namen lieber roh zeigen als crashen
            return m.group(0)

    return re.sub(r"&([A-Za-z0-9+,]*)-", repl, name)


def utf7_encode(name: str) -> str:
    out: list[str] = []
    run: list[str] = []

    def flush() -> None:
        if run:
            raw = "".join(run).encode("utf-16-be")
            out.append("&" + base64.b64encode(raw).decode().rstrip("=").replace("/", ",") + "-")
            run.clear()

    for ch in name:
        if 0x20 <= ord(ch) <= 0x7E:
            flush()
            out.append("&-" if ch == "&" else ch)
        else:
            run.append(ch)
    flush()
    return "".join(out)


# ── Mails zerlegen ──────────────────────────────────────────────────────────


def _decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:  # noqa: BLE001 - kaputte Header sind Alltag, keine Ausnahme
        return value


def _body_text(msg: Message) -> str:
    """Klartext einer Mail. HTML wird notdürftig entkleidet, wenn es keinen Text gibt."""
    plain: list[str] = []
    html: list[str] = []
    for part in msg.walk():
        if part.get_content_maintype() != "text" or part.get_filename():
            continue
        try:
            raw = part.get_payload(decode=True) or b""
            text = raw.decode(part.get_content_charset() or "utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            continue
        (html if part.get_content_subtype() == "html" else plain).append(text)
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


def _attachments(msg: Message) -> list[str]:
    out: list[str] = []
    for part in msg.walk():
        name = part.get_filename()
        if name:
            out.append(_decode(name))
    return out[:20]


def summarise(
    raw: bytes, uid: str, folder: str, with_body: bool, unread: bool | None = None
) -> dict[str, Any]:
    msg = email.message_from_bytes(raw)
    sent_at = None
    if msg.get("Date"):
        try:
            sent_at = (
                email.utils.parsedate_to_datetime(msg["Date"])
                .astimezone(timezone.utc)
                .strftime("%Y-%m-%dT%H:%M:%SZ")
            )
        except (TypeError, ValueError):
            sent_at = msg.get("Date")

    body = _body_text(msg)
    entry: dict[str, Any] = {
        "uid": uid,
        "folder": folder,
        "subject": _decode(msg.get("Subject")),
        "from": _decode(msg.get("From")),
        "to": _decode(msg.get("To")),
        "cc": _decode(msg.get("Cc")),
        "sent_at": sent_at,
        "message_id": (msg.get("Message-ID") or "").strip(),
        "attachments": _attachments(msg),
    }
    if unread is not None:
        entry["unread"] = unread
    if with_body:
        entry["body"] = body[:BODY_MAX_CHARS]
        if len(body) > BODY_MAX_CHARS:
            entry["body_truncated"] = True
    else:
        # Vorschau statt Volltext: eine Trefferliste mit zwanzig kompletten Mails
        # sprengt jedes Kontextfenster, und für „welche ist gemeint?" reicht der
        # Anfang. Den Rest holt get_message.
        entry["preview"] = re.sub(r"\s+", " ", body)[:400]
    return entry


# ── Suche bauen ─────────────────────────────────────────────────────────────


def _quoted(value: str) -> str:
    """IMAP-quoted-string. Nur für ASCII — CR/LF sind darin gar nicht erlaubt."""
    value = re.sub(r"[\r\n]+", " ", value)
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def imap_date(d: date) -> str:
    return f"{d.day:02d}-{_MONTHS[d.month - 1]}-{d.year}"


def build_search(
    since_days: int = 14,
    unread_only: bool = False,
    sender: str = "",
    subject: str = "",
    text: str = "",
    today: date | None = None,
) -> tuple[list[str], bytes | None]:
    """Kriterien für UID SEARCH → (Argumente, Literal).

    Ein Suchwort mit Nicht-ASCII-Zeichen („Grüße") passt in keinen quoted-string und
    muss als Literal mit `CHARSET UTF-8` raus. imaplib kann genau EIN Literal pro
    Befehl, und das hängt es ans Ende — deshalb steht der Schlüssel dafür zuletzt.
    """
    args: list[str] = []
    if unread_only:
        args.append("UNSEEN")
    if since_days > 0:
        args += ["SINCE", imap_date((today or date.today()) - timedelta(days=since_days))]

    literal: tuple[str, bytes] | None = None
    for key, value in (("FROM", sender), ("SUBJECT", subject), ("TEXT", text)):
        value = (value or "").strip()
        if not value:
            continue
        if value.isascii():
            args += [key, _quoted(value)]
        elif literal is None:
            literal = (key, value.encode("utf-8"))
        else:
            raise MailboxError(
                "Höchstens EIN Suchfeld darf Umlaute oder andere Nicht-ASCII-Zeichen "
                "enthalten — bitte die übrigen Felder ohne Umlaute formulieren oder "
                "nacheinander suchen."
            )

    if literal is not None:
        return ["CHARSET", "UTF-8", *args, literal[0]], literal[1]
    return args or ["ALL"], None


# ── Verbindung ──────────────────────────────────────────────────────────────


def _connect(box: Mailbox) -> imaplib.IMAP4_SSL:
    try:
        conn = imaplib.IMAP4_SSL(box.host, box.port, timeout=IMAP_TIMEOUT_S)
    except Exception as exc:  # noqa: BLE001
        raise MailboxError(f"IMAP-Verbindung zu {box.host}:{box.port} gescheitert: {exc}") from exc
    try:
        conn.login(box.user, box.password)
    except imaplib.IMAP4.error as exc:
        raise MailboxError(
            f"IMAP-Anmeldung als {box.user} abgelehnt: {exc}. Fremde Mailprogramme "
            "brauchen bei AOL, Yahoo und Gmail ein App-Passwort — das normale "
            "Kontopasswort funktioniert nicht."
        ) from exc
    return conn


def _logout(conn: imaplib.IMAP4_SSL) -> None:
    try:
        conn.logout()
    except Exception:  # noqa: BLE001
        pass


def _select(conn: imaplib.IMAP4_SSL, folder: str) -> None:
    typ, _ = conn.select(utf7_encode(folder), readonly=True)
    if typ != "OK":
        raise MailboxError(
            f"Ordner {folder!r} nicht auswählbar. list_folders zeigt die vorhandenen."
        )


# ── Ordner ──────────────────────────────────────────────────────────────────

_LIST_LINE = re.compile(r'^\((?P<flags>[^)]*)\)\s+(?P<delim>"[^"]*"|NIL)\s+(?P<name>.+)$')


def parse_list_line(line: bytes | str) -> dict[str, Any] | None:
    """Eine LIST-Antwortzeile → {name, flags}. Name dekodiert, ohne Anführungszeichen."""
    text = line.decode("utf-8", "replace") if isinstance(line, bytes) else line
    m = _LIST_LINE.match(text.strip())
    if not m:
        return None
    name = m.group("name").strip()
    if len(name) >= 2 and name[0] == name[-1] == '"':
        name = name[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return {"name": utf7_decode(name), "flags": m.group("flags").split()}


def list_folders(box: Mailbox) -> list[dict[str, Any]]:
    conn = _connect(box)
    try:
        typ, data = conn.list()
        if typ != "OK":
            raise MailboxError(f"IMAP LIST fehlgeschlagen: {typ}")
        out: list[dict[str, Any]] = []
        for line in data or []:
            # Namen mit Sonderzeichen kommen als Literal: (b'(\\HasNoChildren) "/" {7}', b'Ordner')
            if isinstance(line, tuple):
                line = line[0].rsplit(b"{", 1)[0] + b'"' + line[1] + b'"'
            if not isinstance(line, bytes):
                continue
            parsed = parse_list_line(line)
            if parsed and "\\Noselect" not in parsed["flags"]:
                out.append(parsed)
        return out
    finally:
        _logout(conn)


def special_folder(folders: list[dict[str, Any]], flag: str, fallbacks: tuple[str, ...]) -> str | None:
    for f in folders:
        if flag in f["flags"]:
            return f["name"]
    names = {f["name"].lower(): f["name"] for f in folders}
    for fb in fallbacks:
        if fb.lower() in names:
            return names[fb.lower()]
    return None


# ── Suchen und Lesen ────────────────────────────────────────────────────────

_UID = re.compile(rb"\bUID (\d+)")
_FLAGS = re.compile(rb"\bFLAGS \(([^)]*)\)")


def parse_fetch(data: list[Any]) -> dict[str, tuple[bytes, bool | None]]:
    """FETCH-Antwort → {uid: (rohdaten, ungelesen)}.

    UID und FLAGS dürfen VOR oder NACH dem Literal stehen (`* 3 FETCH (UID 7 BODY[]
    {n}` … `)` genauso wie `* 3 FETCH (BODY[] {n}` … ` UID 7 FLAGS (\\Seen))`) —
    deshalb wird der Text vor UND nach jedem Literal betrachtet.
    """
    out: dict[str, tuple[bytes, bool | None]] = {}
    for i, item in enumerate(data or []):
        if not isinstance(item, tuple):
            continue
        meta = item[0] if isinstance(item[0], bytes) else b""
        nxt = data[i + 1] if i + 1 < len(data) and isinstance(data[i + 1], bytes) else b""
        context = meta + b" " + nxt
        m = _UID.search(context)
        if not m:
            continue
        flags = _FLAGS.search(context)
        unread = None if flags is None else (b"\\Seen" not in flags.group(1))
        out[m.group(1).decode()] = (item[1], unread)
    return out


def search(
    box: Mailbox,
    folder: str = "INBOX",
    since_days: int = 14,
    limit: int = 20,
    unread_only: bool = False,
    sender: str = "",
    subject: str = "",
    text: str = "",
) -> tuple[int, list[dict[str, Any]]]:
    """Suchen und Kopfdaten holen — ohne Flags zu verändern. → (Trefferzahl, neueste zuerst)."""
    args, literal = build_search(since_days, unread_only, sender, subject, text)
    limit = max(1, min(limit, 50))

    conn = _connect(box)
    try:
        _select(conn, folder)
        if literal is not None:
            conn.literal = literal
        typ, data = conn.uid("SEARCH", *args)
        if typ != "OK":
            raise MailboxError(f"IMAP-Suche fehlgeschlagen: {typ} {data}")
        uids = (data[0] or b"").split() if data else []
        # UIDs steigen mit dem Eingang — die letzten sind die neuesten.
        wanted = [u.decode() for u in uids[-limit:]][::-1]
        if not wanted:
            return len(uids), []
        typ, payload = conn.uid(
            "FETCH", ",".join(wanted), f"(UID FLAGS BODY.PEEK[]<0.{PREVIEW_FETCH_BYTES}>)"
        )
        if typ != "OK":
            raise MailboxError(f"IMAP FETCH fehlgeschlagen: {typ}")
        fetched = parse_fetch(payload)
        out = [
            summarise(fetched[u][0], u, folder, with_body=False, unread=fetched[u][1])
            for u in wanted
            if u in fetched
        ]
        return len(uids), out
    finally:
        _logout(conn)


def get(box: Mailbox, uid: str, folder: str = "INBOX") -> dict[str, Any]:
    uid = str(uid).strip()
    if not uid.isdigit():
        raise MailboxError(f"{uid!r} ist keine UID — sie stammt aus der Trefferliste von search.")
    conn = _connect(box)
    try:
        _select(conn, folder)
        typ, payload = conn.uid("FETCH", uid, f"(UID FLAGS BODY.PEEK[]<0.{GET_FETCH_BYTES}>)")
        fetched = parse_fetch(payload) if typ == "OK" else {}
        if uid not in fetched:
            raise MailboxError(f"Mail mit UID {uid} in {folder!r} nicht gefunden.")
        raw, unread = fetched[uid]
        entry = summarise(raw, uid, folder, with_body=True, unread=unread)
        if len(raw) >= GET_FETCH_BYTES:
            # Weitere Anhänge können fehlen — die Liste ist dann unvollständig.
            entry["fetch_truncated"] = True
        return entry
    finally:
        _logout(conn)


def append_draft(box: Mailbox, folder: str, raw: bytes) -> str:
    """Entwurf ins Postfach legen.

    Kein SMTP, kein Versand — die Mail landet im Entwurfsordner und wartet dort auf
    einen Menschen. `\\Draft` wird gesetzt, damit der Webmailer sie als Entwurf
    behandelt und nicht als eingegangene Nachricht anzeigt.
    """
    conn = _connect(box)
    try:
        typ, data = conn.append(utf7_encode(folder), "(\\Draft \\Seen)", None, raw)
        if typ != "OK":
            raise MailboxError(f"Entwurf konnte nicht in {folder!r} abgelegt werden: {typ} {data}")
        return folder
    finally:
        _logout(conn)
