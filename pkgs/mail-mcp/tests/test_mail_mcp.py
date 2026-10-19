"""Tests ohne Netz.

Geprüft wird das, was still falsch sein kann: das Zerlegen echter Mails und
IMAP-Antworten, das Bauen der Suchbefehle und die Empfänger-Schranke. Der
IMAP-/SMTP-Verkehr selbst ist Standardbibliothek und wird nicht nachgebaut — ein
Mock von imaplib würde nur bestätigen, dass der Mock tut, was der Mock tut. Dafür
gibt es die Prüfung gegen das echte Postfach (docs/mail-mcp.md).
"""

from __future__ import annotations

from datetime import date

import pytest

from mail_mcp import compose, mailbox

PLAIN = b"""From: Max Schuett <max@example.com>
To: maximilianschuett@aol.com
Subject: =?utf-8?q?Gru=C3=9F_aus_M=C3=BCnchen?=
Date: Wed, 3 Sep 2026 10:11:12 +0200
Message-ID: <abc@example.com>
Content-Type: text/plain; charset="utf-8"

Hallo,
zwei Zeilen Text.
"""

HTML_ONLY = b"""From: shop@example.com
Subject: Rechnung
Date: Wed, 3 Sep 2026 10:11:12 +0200
Content-Type: text/html; charset="utf-8"

<html><head><style>p{color:red}</style></head><body>
<p>Betrag: 12,50&nbsp;&amp;nbsp</p><script>alert(1)</script><p>Danke</p></body></html>
"""


# ── Mails zerlegen ──────────────────────────────────────────────────────────


def test_summarise_decodes_header_and_keeps_body_out_of_preview():
    entry = mailbox.summarise(PLAIN, uid="7", folder="INBOX", with_body=False, unread=True)
    assert entry["subject"] == "Gruß aus München"
    assert entry["from"] == "Max Schuett <max@example.com>"
    assert entry["sent_at"] == "2026-09-03T08:11:12Z"
    assert entry["message_id"] == "<abc@example.com>"
    assert entry["unread"] is True
    # Vorschau, nicht Volltext: die Trefferliste darf das Kontextfenster nicht sprengen.
    assert "body" not in entry
    assert entry["preview"] == "Hallo, zwei Zeilen Text."


def test_summarise_with_body_returns_full_text():
    entry = mailbox.summarise(PLAIN, uid="7", folder="INBOX", with_body=True)
    assert entry["body"] == "Hallo,\nzwei Zeilen Text."
    assert "preview" not in entry
    assert "unread" not in entry


def test_long_body_is_truncated_and_flagged():
    raw = b"Subject: x\nContent-Type: text/plain\n\n" + b"a" * (mailbox.BODY_MAX_CHARS + 10)
    entry = mailbox.summarise(raw, uid="1", folder="INBOX", with_body=True)
    assert len(entry["body"]) == mailbox.BODY_MAX_CHARS
    assert entry["body_truncated"] is True


def test_html_only_mail_is_stripped_including_script_and_style():
    entry = mailbox.summarise(HTML_ONLY, uid="1", folder="INBOX", with_body=True)
    body = entry["body"]
    assert "alert(1)" not in body
    assert "color:red" not in body
    assert "Betrag: 12,50" in body
    assert "Danke" in body


def test_truncated_preview_fetch_still_parses():
    # Die Trefferliste holt nur die ersten 64 KiB — eine abgeschnittene Mail darf
    # die Kopfdaten nicht verlieren.
    entry = mailbox.summarise(PLAIN[:-10], uid="7", folder="INBOX", with_body=False)
    assert entry["subject"] == "Gruß aus München"


# ── Modified UTF-7 ──────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("plain", "wire"),
    [
        ("INBOX", "INBOX"),
        ("Entwürfe", "Entw&APw-rfe"),
        ("[Gmail]/Gelöschte Elemente", "[Gmail]/Gel&APY-schte Elemente"),
        ("A&B", "A&-B"),
        ("日本語", "&ZeVnLIqe-"),
    ],
)
def test_utf7_roundtrip(plain, wire):
    assert mailbox.utf7_encode(plain) == wire
    assert mailbox.utf7_decode(wire) == plain


# ── Suche bauen ─────────────────────────────────────────────────────────────


def test_search_terms_are_quoted_so_spaces_stay_one_criterion():
    args, literal = mailbox.build_search(
        since_days=0, subject='Hallo "Welt"', sender="a\\b"
    )
    assert args == ["FROM", '"a\\\\b"', "SUBJECT", '"Hallo \\"Welt\\""']
    assert literal is None


def test_search_date_is_english_and_independent_of_locale():
    args, _ = mailbox.build_search(since_days=3, today=date(2026, 3, 4))
    assert args == ["SINCE", "01-Mar-2026"]


def test_search_without_filters_is_all():
    assert mailbox.build_search(since_days=0) == (["ALL"], None)


def test_non_ascii_term_goes_out_as_utf8_literal_last():
    args, literal = mailbox.build_search(
        since_days=0, unread_only=True, subject="Grüße", sender="max@example.com"
    )
    assert args == ["CHARSET", "UTF-8", "UNSEEN", "FROM", '"max@example.com"', "SUBJECT"]
    assert literal == "Grüße".encode()


def test_two_non_ascii_terms_are_rejected_instead_of_silently_dropped():
    with pytest.raises(mailbox.MailboxError):
        mailbox.build_search(subject="Grüße", text="Bärbel")


def test_search_strips_line_breaks_from_quoted_terms():
    args, _ = mailbox.build_search(since_days=0, text="a\r\nb")
    assert args == ["TEXT", '"a b"']


# ── IMAP-Antworten zerlegen ─────────────────────────────────────────────────


def test_parse_fetch_uid_before_and_after_literal():
    data = [
        (b"1 (UID 41 FLAGS (\\Seen) BODY[]<0> {5}", b"AAAAA"),
        b")",
        (b"2 (BODY[]<0> {5}", b"BBBBB"),
        b" UID 42 FLAGS ())",
        (b"3 (UID 43 BODY[]<0> {5}", b"CCCCC"),
        b")",
    ]
    out = mailbox.parse_fetch(data)
    assert out["41"] == (b"AAAAA", False)
    assert out["42"] == (b"BBBBB", True)
    # Ohne FLAGS in der Antwort: unbekannt, nicht „gelesen".
    assert out["43"] == (b"CCCCC", None)


@pytest.mark.parametrize(
    ("line", "name", "flag"),
    [
        (b'(\\HasNoChildren) "/" "Inbox"', "Inbox", "\\HasNoChildren"),
        (b'(\\HasNoChildren \\Drafts) "/" "Draft"', "Draft", "\\Drafts"),
        (b'(\\HasNoChildren) "/" Bulk', "Bulk", "\\HasNoChildren"),
        (b'(\\Drafts) "/" "[Gmail]/Entw&APw-rfe"', "[Gmail]/Entwürfe", "\\Drafts"),
        (b'(\\Noselect) NIL ""', "", "\\Noselect"),
    ],
)
def test_parse_list_line(line, name, flag):
    parsed = mailbox.parse_list_line(line)
    assert parsed is not None
    assert parsed["name"] == name
    assert flag in parsed["flags"]


def test_special_folder_prefers_flag_then_name():
    folders = [
        {"name": "Drafts", "flags": []},
        {"name": "Entwurf", "flags": ["\\Drafts"]},
    ]
    assert mailbox.special_folder(folders, "\\Drafts", ("Drafts",)) == "Entwurf"
    assert mailbox.special_folder(folders[:1], "\\Drafts", ("drafts",)) == "Drafts"
    assert mailbox.special_folder([], "\\Drafts", ("Drafts",)) is None


# ── Empfänger ───────────────────────────────────────────────────────────────


def test_check_recipients_deduplicates_case_insensitively():
    assert compose.check_recipients(["A@b.de", "a@B.de", " "], limit=5) == ["A@b.de"]


@pytest.mark.parametrize(
    "value",
    [
        "Max <max@example.com>",  # Anzeigename gehört nicht ins Adressfeld
        "a@b.de, c@d.de",  # zwei Adressen in einem Eintrag
        "keine-adresse",
        "a@b",  # keine TLD
    ],
)
def test_check_recipients_rejects_ambiguous_input(value):
    with pytest.raises(compose.SendError):
        compose.check_recipients([value], limit=5)


def test_check_recipients_enforces_limit():
    with pytest.raises(compose.SendError):
        compose.check_recipients([f"a{i}@b.de" for i in range(6)], limit=5)


def test_build_sets_threading_headers_and_sender_domain_message_id():
    msg = compose.build(
        "maximilianschuett@aol.com", "Max Schütt", ["a@b.de"], "Re: x", "Text",
        reply_to_message_id="<orig@example.com>",
    )
    assert msg["In-Reply-To"] == "<orig@example.com>"
    assert msg["References"] == "<orig@example.com>"
    assert msg["Message-ID"].endswith("@aol.com>")
    assert "Max" in msg["From"] and "maximilianschuett@aol.com" in msg["From"]
