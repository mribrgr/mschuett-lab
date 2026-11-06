# Speicher für facharbeit.lisa.mauritiusberger.de: Lisas Auswahl, Notizen und Haken,
# damit iPad und Handy denselben Stand sehen. Läuft im selben Pod hinter nginx
# (Basic-Auth) und lauscht nur auf 127.0.0.1 — von außen nicht direkt erreichbar.
#
#   GET  /api/state  → {"sel":{}, "notes":{}, "checks":{}, "rev":n, "at":…, "device":…}
#   POST /api/patch  → dieselbe Form (nur geänderte Schlüssel), Antwort = neuer Stand
#   GET  /health     → für die Readiness-Probe (über nginx /healthz-api)
#
# Pro Schlüssel gilt der letzte Schreiber: zwei Geräte, die verschiedene Pakete
# ändern, überschreiben sich nicht. Jede Änderung landet zusätzlich in
# changes.jsonl — damit lässt sich ein versehentlich überschriebener Stand
# rekonstruieren.
import json
import os
import re
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("DATA_DIR", "/data")
STATE = os.path.join(DATA, "state.json")
LOG = os.path.join(DATA, "changes.jsonl")
LOCK = threading.Lock()
KEY = re.compile(r"^[a-z0-9-]{1,40}$")
KINDS = ("sel", "notes", "checks")


def empty():
    return {"sel": {}, "notes": {}, "checks": {}, "rev": 0, "at": None, "device": None}


def load():
    try:
        with open(STATE, encoding="utf-8") as f:
            st = json.load(f)
    except FileNotFoundError:
        return empty()
    for k in KINDS:
        st.setdefault(k, {})
    return st


def save(st):
    fd, tmp = tempfile.mkstemp(dir=DATA, prefix=".state-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


def validate(body):
    if not isinstance(body, dict):
        raise ValueError("body")
    patch = {}
    for kind in KINDS:
        if kind not in body:
            continue
        items = body[kind]
        if not isinstance(items, dict) or len(items) > 60:
            raise ValueError(kind)
        for key, value in items.items():
            if not KEY.match(key):
                raise ValueError(key)
            if kind == "sel" and value not in (None, "A", "B", "C"):
                raise ValueError("sel")
            if kind == "notes" and not (isinstance(value, str) and len(value) <= 4000):
                raise ValueError("notes")
            if kind == "checks" and not isinstance(value, bool):
                raise ValueError("checks")
        patch[kind] = items
    device = body.get("device")
    if device is not None and not (isinstance(device, str) and len(device) <= 30):
        raise ValueError("device")
    return patch, device


class Handler(BaseHTTPRequestHandler):
    server_version = "facharbeit-api"

    def reply(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            return self.reply(200, {"ok": True})
        if path == "/api/state":
            with LOCK:
                return self.reply(200, load())
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/api/patch":
            return self.reply(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 65536:
            return self.reply(413, {"error": "too large"})
        try:
            patch, device = validate(json.loads(self.rfile.read(length)))
        except (ValueError, json.JSONDecodeError):
            return self.reply(400, {"error": "bad request"})
        with LOCK:
            st = load()
            for kind, items in patch.items():
                for key, value in items.items():
                    if kind == "sel" and value is None:
                        st[kind].pop(key, None)
                    else:
                        st[kind][key] = value
            st["rev"] = int(st.get("rev") or 0) + 1
            st["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            st["device"] = device
            save(st)
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps({"at": st["at"], "device": device, "patch": patch}, ensure_ascii=False) + "\n")
            return self.reply(200, st)

    def log_message(self, fmt, *args):
        pass  # nginx protokolliert die Zugriffe schon


if __name__ == "__main__":
    os.makedirs(DATA, exist_ok=True)
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("PORT", "3000"))), Handler).serve_forever()
