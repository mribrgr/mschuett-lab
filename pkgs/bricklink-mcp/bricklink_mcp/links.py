"""Signierte, ablaufende Download-Links für die Export-Dateien.

Warum so und nicht anders: die Dateien liegen im PVC des Dienstes, und der MCP selbst
ist absichtlich NICHT aus dem Internet erreichbar (CiliumNetworkPolicy: nur der
open-webui-Pod darf auf Port 8081). Ausgeliefert werden die Dateien deshalb von einem
nginx-Sidecar im selben Pod auf einem EIGENEN Port, der nur ein Verzeichnis lesend
kennt — der MCP-Prozess bleibt vom Internet getrennt, selbst wenn an der Route etwas
falsch konfiguriert wäre.

Die Signatur ist nginx' `secure_link`-Format (ngx_http_secure_link_module):

    secure_link       $arg_md5,$arg_expires;
    secure_link_md5   "$secure_link_expires$uri<GEHEIMNIS>";

Der Hash ist also md5 über „<expires><uri><geheimnis>", base64url ohne Padding. md5 ist
hier kein Integritätsschutz gegen Kollisionen, sondern eine Keyed-Konstruktion mit
einem 64-Zeichen-Geheimnis: ohne das Geheimnis lässt sich kein gültiger Link bauen.
nginx prüft die Signatur UND das Ablaufdatum selbst; scheitert eines, kommt 404 bzw.
410 — ohne dass jemals ein Dateisystemzugriff passiert.
"""

from __future__ import annotations

import base64
import hashlib
import time

# nginx' Grenze, nicht unsere: über einen Tag alte Links sind kein Feature, sondern ein
# Leck. Wer länger braucht, holt sich einen neuen.
MAX_TTL_MINUTES = 1440


def sign(
    base_url: str, path_prefix: str, filename: str, secret: str, ttl_minutes: int
) -> tuple[str, int]:
    """(URL, Ablaufzeitpunkt als Unix-Zeit) für eine Datei im Export-Verzeichnis."""
    ttl = max(1, min(int(ttl_minutes), MAX_TTL_MINUTES))
    expires = int(time.time()) + ttl * 60
    uri = path_prefix.rstrip("/") + "/" + filename.lstrip("/")
    digest = hashlib.md5(f"{expires}{uri}{secret}".encode("utf-8")).digest()
    token = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return f"{base_url.rstrip('/')}{uri}?md5={token}&expires={expires}", expires
