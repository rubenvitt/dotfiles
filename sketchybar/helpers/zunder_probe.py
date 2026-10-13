#!/usr/bin/env python3
"""Fällige Zunder-Aufgaben für sketchybar/items/zunder.lua.

Gibt Zeilen aus, die sich in Lua ohne JSON-Parser auswerten lassen:

    OFF                                  kein brauchbarer Token -> Widget aus
    ERR                                  Netz/HTTP kaputt -> Anzeige unverändert
    C|<heute>|<überfällig>|<heute-schon-vorbei>
    T|<now|today|late>|<fälligkeit>|<url>|<titel>

Getrennt gezählt wird, weil die beiden Zahlen Verschiedenes bedeuten: was
heute fällig ist, kann man heute tun. Der Rückstand ist ein Zustand, keine
Aufgabe für den Nachmittag; stellte er die Zahl in der Leiste, wäre das
Widget nach zwei Tagen Tapete.

Abgefragt wird das MCP-Werkzeug filter_tasks. /mcp ist zustandslos, ein
einzelnes tools/call ohne initialize genügt, und der Server filtert Status,
Fälligkeit und gelöschte Aufgaben selbst.

Der Token (zt_…, in der Web-UI unter „Tokens“ angelegt) steht bewusst
außerhalb dieses Repos in ~/.config/zunder/token -- das Repo ist öffentlich.

OFF und ERR sind getrennt, weil sie verschieden behandelt gehören: ohne
Token gibt es dauerhaft nichts zu zeigen, ein Netzfehler ist vorübergehend.
Bei ERR lässt die Lua-Seite stehen, was zuletzt galt.
"""

import datetime as dt
import json
import os
import re
import subprocess

ENDPOINT = "https://zunder.rubeen.dev/mcp"
TASK_URL = "https://zunder.rubeen.dev/#/aufgabe/"
TOKEN_FILE = os.path.expanduser("~/.config/zunder/token")

MAX_ROWS = 8
TITLE_CHARS = 34
TIMEOUT = 8
PAGE_SIZE = 500  # Obergrenze des Servers.
MAX_PAGES = 4
OPEN_STATES = ["open", "in_progress", "review", "blocked"]

# Die ID landet in einem click_script, also in einer Shell.
SAFE_ID = re.compile(r"^[A-Za-z0-9]+$")
TOKEN_RE = re.compile(r"^zt_[A-Za-z0-9_-]{43}$")


def read_token():
    """Token oder None. Eine leere oder fremdformatige Datei zählt als 'kein
    Token': sonst hinge an einer versehentlich angelegten Datei alle 15
    Minuten ein 401."""
    try:
        with open(TOKEN_FILE) as f:
            token = f.read().strip()
    except Exception:
        return None
    return token if TOKEN_RE.match(token) else None


def call_filter(token, args):
    """structuredContent von filter_tasks oder None.

    Der Token geht über stdin an curl, nicht über argv -- Kommandozeilen sind
    für jeden Prozess der Sitzung in `ps` lesbar. Der Body enthält nichts
    Geheimes und darf in argv stehen.
    """
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": "filter_tasks", "arguments": args}})
    try:
        proc = subprocess.run(
            ["curl", "-sS", "--max-time", str(TIMEOUT), "-w", "\n%{http_code}",
             "-H", "Content-Type: application/json",
             "-H", "Accept: application/json, text/event-stream",
             "--data", body, "-K", "-", ENDPOINT],
            input='header = "Authorization: Bearer %s"\n' % token,
            capture_output=True, text=True, timeout=TIMEOUT + 4,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    out, _, status = proc.stdout.rpartition("\n")
    if status.strip() != "200":
        return None
    try:
        result = json.loads(out)["result"]
    except Exception:
        return None
    if result.get("isError"):
        return None
    return result.get("structuredContent")


def fetch_tasks(token, today):
    """Alle bis heute fälligen offenen Aufgaben, über Seiten hinweg.

    Ohne Nachfassen bliebe die Zahl bei genau PAGE_SIZE stehen. MAX_PAGES
    deckelt das, damit ein aus dem Ruder gelaufener Filter nicht ewig blättert.
    """
    tasks, offset = [], 0
    for _ in range(MAX_PAGES):
        data = call_filter(token, {
            "due_before": today, "status": OPEN_STATES,
            "limit": PAGE_SIZE, "offset": offset,
        })
        if data is None:
            return None
        tasks.extend(data.get("tasks") or [])
        offset = data.get("next_offset")
        if offset is None:
            break
    return tasks


# ------------------------------------------------------------------ Ausgabe

def human_delta(seconds):
    if seconds >= 86400:
        return "%dd" % (seconds // 86400)
    if seconds >= 3600:
        return "%dh" % (seconds // 3600)
    return "%dm" % max(1, seconds // 60)


def clean(text):
    """Steuerzeichen und das Trennzeichen raus, dann kürzen -- Titel dürfen das
    Zeilenformat nicht sprengen."""
    text = re.sub(r"[\x00-\x1f\x7f|]", " ", text or "").strip()
    text = re.sub(r"\s+", " ", text)
    if len(text) > TITLE_CHARS:
        text = text[:TITLE_CHARS - 1].rstrip() + "…"
    return text or "?"


def task_url(task):
    tid = str(task.get("id") or "")
    return TASK_URL + tid if SAFE_ID.match(tid) else ""


def parse_due(value):
    """(lokales Datum, Zeitpunkt oder None) aus 'JJJJ-MM-TT' bzw. RFC 3339.

    Ein reines Datum ist ein Kalendertag ohne Uhrzeit und wird nicht als
    UTC-Mitternacht gelesen -- sonst rutschte es westlich von Greenwich auf
    den Vortag. Python 3.9 liest kein 'Z', daher der Ersatz.
    """
    if not isinstance(value, str):
        return None
    if len(value) == 10:
        try:
            return dt.date.fromisoformat(value), None
        except ValueError:
            return None
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        return None
    local = moment.astimezone()
    return local.date(), local


def render(tasks, now):
    """Ausgabezeilen aus rohen Task-Dicts. Ohne Netz, damit sich der Teil
    gegen Beispieldaten prüfen lässt (zunder_probe_test.py)."""
    now = now.astimezone()
    today_date = now.date()

    # Nach Kalendertag, nicht nach verstrichener Zeit: eine Aufgabe, die heute
    # um neun fällig war, ist mittags schlicht heute dran.
    today, late = [], []
    for task in tasks or []:
        if task.get("status") not in OPEN_STATES:
            continue
        due = parse_due(task.get("due"))
        if not due or due[0] > today_date:
            continue
        date, moment = due
        # Ein reines Datum zählt heute als spätester Termin des Tages, im
        # Rückstand ab Tagesbeginn: gestern ohne Uhrzeit ist „vor 1d“, nicht „vor 9h“.
        if date < today_date:
            key = moment or dt.datetime.combine(date, dt.time.min).astimezone()
            late.append((key, moment, task))
        else:
            key = moment or dt.datetime.combine(date, dt.time.max).astimezone()
            today.append((key, moment, task))

    today.sort(key=lambda item: item[0])              # was als Nächstes ansteht
    late.sort(key=lambda item: item[0], reverse=True)  # die jüngsten zuerst

    urgent, rows = 0, []
    for _, moment, task in today:
        if moment and moment < now:
            urgent += 1
            rows.append(("now", moment.strftime("%H:%M"), task))
        else:
            rows.append(("today", moment.strftime("%H:%M") if moment else "heute", task))
    for key, _, task in late:
        rows.append(("late", "vor " + human_delta(int((now - key).total_seconds())), task))

    lines = ["C|%d|%d|%d" % (len(today), len(late), urgent)]
    for state, label, task in rows[:MAX_ROWS]:
        lines.append("T|%s|%s|%s|%s" % (state, label, task_url(task),
                                        clean(task.get("title"))))
    return lines


def main():
    token = read_token()
    if not token:
        print("OFF")
        return
    now = dt.datetime.now().astimezone()
    tasks = fetch_tasks(token, now.date().isoformat())
    if tasks is None:
        print("ERR")
        return
    print("\n".join(render(tasks, now)))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Nichts darf ins Bar-Log tropfen; ERR heißt 'lass stehen'.
        print("ERR")
