#!/usr/bin/env python3
"""Faellige ClickUp-Aufgaben fuer sketchybar/items/clickup.lua.

Gibt Zeilen aus, die sich in Lua ohne JSON-Parser auswerten lassen:

    OFF                                  kein brauchbarer Token -> Widget aus
    ERR                                  Netz/HTTP kaputt -> Anzeige unveraendert
    C|<heute>|<ueberfaellig>|<heute-schon-vorbei>
    T|<now|today|late>|<faelligkeit>|<url>|<titel>

Getrennt gezaehlt wird, weil die beiden Zahlen Verschiedenes bedeuten: was
heute faellig ist, kann man heute tun. Der Rueckstand -- hier dreistellig
angewachsen und teils Monate alt -- ist ein Zustand, keine Aufgabe fuer den
Nachmittag. Wuerde er die Zahl in der Leiste stellen, stuende dort monatelang
dieselbe grosse Zahl, und das Widget waere Tapete.

Der Token steht bewusst ausserhalb dieses Repos in ~/.config/clickup/token --
das Repo ist oeffentlich. Aus demselben Grund werden User- und Workspace-ID
zur Laufzeit ermittelt und nur im Cache abgelegt, nie in einer Datei hier.

OFF und ERR sind getrennt, weil sie verschieden behandelt gehoeren: ohne
Token gibt es dauerhaft nichts zu zeigen, ein Netzfehler ist voruebergehend.
Bei ERR laesst die Lua-Seite stehen, was zuletzt galt, statt bei jedem
Schluckauf fuer eine Viertelstunde zu verschwinden.
"""

import json
import os
import re
import subprocess
import sys
import time

API = "https://api.clickup.com/api/v2"
TOKEN_FILE = os.path.expanduser("~/.config/clickup/token")
CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "sketchybar", "clickup-ids.json",
)

MAX_ROWS = 8
TITLE_CHARS = 34
TIMEOUT = 8
MAX_TEAMS = 4  # Mehrere Workspaces sind moeglich, Dutzende nicht.
PAGE_SIZE = 100  # Von ClickUp vorgegeben.
MAX_PAGES = 5

# Was durch ein click_script laufen darf. Die URL kommt aus der API, landet
# aber in einer Shell -- ohne diese Schranke waere sie eine Einladung.
SAFE_URL = re.compile(r"^https://app\.clickup\.com/[A-Za-z0-9/_.-]+$")
SAFE_ID = re.compile(r"^[A-Za-z0-9_-]+$")


# --------------------------------------------------------------------- Token

def read_token():
    """Token oder None. Jeder Fehlerfall ist ein None, keiner ein Krach.

    Leere oder fremdformatige Datei zaehlt als 'kein Token': sonst haengt
    an einer versehentlich angelegten Datei alle 15 Minuten ein 401.
    """
    try:
        with open(TOKEN_FILE) as f:
            token = f.read().strip()
    except Exception:
        return None
    return token if token.startswith("pk_") and len(token) > 8 else None


def fingerprint(token):
    """Kurzer Hash, damit der ID-Cache beim Tokenwechsel verfaellt.

    Der Token selbst darf nicht in den Cache -- der Hash reicht, um zu
    erkennen, dass die zwischengespeicherten IDs zu jemand anderem gehoeren.
    """
    import hashlib
    return hashlib.sha256(token.encode()).hexdigest()[:16]


# --------------------------------------------------------------------- Netz

def get_json(url, token):
    """(objekt, ok). Der Token geht ueber stdin an curl, nicht ueber argv --
    Kommandozeilen sind fuer jeden Prozess der Sitzung in `ps` lesbar.

    --globoff, weil curl sonst die eckigen Klammern in assignees[] als
    Bereichsangabe deutet.
    """
    try:
        proc = subprocess.run(
            ["curl", "-sS", "--globoff", "--max-time", str(TIMEOUT),
             "-w", "\n%{http_code}", "-K", "-", url],
            input='header = "Authorization: %s"\n' % token,
            capture_output=True, text=True, timeout=TIMEOUT + 4,
        )
    except Exception:
        return None, False
    if proc.returncode != 0:
        return None, False
    body, _, status = proc.stdout.rpartition("\n")
    # 429 ist das Rate-Limit (100/min pro Token). Bei einem Abruf alle 15
    # Minuten praktisch unerreichbar, aber es soll trotzdem nichts loeschen.
    if status.strip() != "200":
        return None, False
    try:
        return json.loads(body), True
    except Exception:
        return None, False


def load_cache():
    try:
        with open(CACHE) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_cache(data):
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, CACHE)
    except Exception:
        pass


def identity(token):
    """(user_id, [team_id, ...]) -- aus dem Cache, sonst aus zwei Abrufen.

    Beides sind stabile IDs des Nutzers; sie zu cachen spart bei jedem
    Durchlauf zwei Requests und haelt sie aus dem Repo heraus.
    """
    fp = fingerprint(token)
    cache = load_cache()
    if cache.get("fp") == fp and cache.get("user") and cache.get("teams"):
        return cache["user"], cache["teams"]

    user, ok = get_json(API + "/user", token)
    if not ok:
        return None, None
    user_id = ((user or {}).get("user") or {}).get("id")

    teams, ok = get_json(API + "/team", token)
    if not ok:
        return None, None
    team_ids = [str(t.get("id")) for t in ((teams or {}).get("teams") or [])
                if t.get("id") is not None]

    if not user_id or not team_ids:
        return None, None
    team_ids = team_ids[:MAX_TEAMS]
    save_cache({"fp": fp, "user": user_id, "teams": team_ids})
    return user_id, team_ids


def fetch_tasks(token, user_id, team_ids, until_ms):
    """Alle bis <until_ms> faelligen Aufgaben des Nutzers ueber alle Workspaces.

    ClickUp liefert 100 Aufgaben je Seite. Eine volle Seite heisst, dass es
    weitergeht -- ohne Nachfassen bliebe die Zahl in der Leiste bei genau
    hundert stehen und liesse den Rest verschwinden. MAX_PAGES deckelt das,
    damit ein aus dem Ruder gelaufener Filter nicht minutenlang blaettert.
    """
    tasks = []
    for team_id in team_ids:
        for page in range(MAX_PAGES):
            url = ("%s/team/%s/task?assignees%%5B%%5D=%s&due_date_lt=%d"
                   "&include_closed=false&subtasks=true&order_by=due_date"
                   "&page=%d" % (API, team_id, user_id, until_ms, page))
            data, ok = get_json(url, token)
            if not ok:
                return None
            batch = (data or {}).get("tasks") or []
            tasks.extend(batch)
            # last_page ist die Auskunft der API; die Seitenlaenge ist der
            # Notnagel, falls das Feld einmal fehlt.
            if (data or {}).get("last_page") or len(batch) < PAGE_SIZE:
                break
    return tasks


# ------------------------------------------------------------------ Ausgabe

def day_bounds(now):
    """(Beginn, Ende) des heutigen Tages in Ortszeit als ms seit Epoche.

    Der Tageswechsel wird ueber mktime mit einem ueberlaufenden Monatstag
    berechnet statt ueber '+86400': an den beiden Zeitumstellungen im Jahr
    ist ein Tag 23 oder 25 Stunden lang, und eine feste Sekundenzahl schoebe
    die Grenze dann um eine Stunde.
    """
    t = time.localtime(now)
    start = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))
    end = time.mktime((t.tm_year, t.tm_mon, t.tm_mday + 1, 0, 0, 0, 0, 0, -1))
    return int(start * 1000), int(end * 1000)


def end_of_today(now):
    return day_bounds(now)[1]


def human_delta(seconds):
    if seconds >= 86400:
        return "%dd" % (seconds // 86400)
    if seconds >= 3600:
        return "%dh" % (seconds // 3600)
    return "%dm" % max(1, seconds // 60)


def clean(text):
    """Steuerzeichen und das Trennzeichen raus, dann kuerzen.

    Aufgabentitel sind Kundendaten und Fremdtext zugleich: sie duerfen das
    Zeilenformat nicht sprengen und keine Zeilenumbrueche einschleusen.
    """
    text = re.sub(r"[\x00-\x1f\x7f|]", " ", text or "").strip()
    text = re.sub(r"\s+", " ", text)
    if len(text) > TITLE_CHARS:
        text = text[:TITLE_CHARS - 1].rstrip() + "…"
    return text or "?"


def task_url(task):
    url = task.get("url") or ""
    if SAFE_URL.match(url):
        return url
    # Fallback aus der ID -- dieselbe Adresse, nur selbst gebaut.
    tid = str(task.get("id") or "")
    return "https://app.clickup.com/t/" + tid if SAFE_ID.match(tid) else ""


def is_open(task):
    """Erledigtes aussortieren.

    include_closed=false filtert serverseitig nur den Statustyp 'closed' --
    nachgemessen: von 93 gelieferten Aufgaben waren 20 vom Typ 'done' und
    kamen trotz des Parameters mit. Ohne diesen Filter stuenden sie als
    faellig in der Leiste.

    Geprueft wird der Typ, nicht der Name: die Statusnamen sind pro Workspace
    frei vergeben und hier deutsch ('anstehend', 'review', 'idee'). Typ
    'custom' zaehlt als offen.
    """
    if task.get("date_done"):
        return False
    status = (task.get("status") or {}).get("type")
    return status not in ("closed", "done")


def render(tasks, now):
    """Ausgabezeilen aus rohen Task-Dicts. Bewusst ohne Netz, damit sich der
    Teil gegen Beispieldaten pruefen laesst."""
    start_ms, end_ms = day_bounds(now)
    now_ms = int(now * 1000)

    # Einsortiert wird nach Kalendertag, nicht nach verstrichener Zeit. Eine
    # Aufgabe, die heute um neun faellig war, ist um zwoelf nicht "seit drei
    # Stunden ueberfaellig", sondern schlicht heute dran -- und damit etwas
    # anderes als die Aufgabe vom Juni.
    today, late = [], []
    for task in tasks or []:
        if not is_open(task):
            continue
        try:
            ms = int(task.get("due_date"))
        except (TypeError, ValueError):
            continue  # Aufgabe ohne Faelligkeit
        if ms >= end_ms:
            continue
        (late if ms < start_ms else today).append((ms, task))

    today.sort(key=lambda item: item[0])              # was als naechstes ansteht
    late.sort(key=lambda item: item[0], reverse=True)  # die juengsten zuerst

    urgent, rows = 0, []
    for ms, task in today:
        # Ein Datum ohne Uhrzeit legt ClickUp trotzdem auf eine Uhrzeit, frueh
        # am Tag. Nur eine echte Uhrzeit darf deshalb "schon vorbei" bedeuten.
        timed = bool(task.get("due_date_time"))
        clock = time.strftime("%H:%M", time.localtime(ms / 1000.0))
        if timed and ms < now_ms:
            urgent += 1
            rows.append(("now", clock, task))
        else:
            rows.append(("today", clock if timed else "heute", task))
    for ms, task in late:
        rows.append(("late", "vor " + human_delta((now_ms - ms) // 1000), task))

    lines = ["C|%d|%d|%d" % (len(today), len(late), urgent)]
    for state, label, task in rows[:MAX_ROWS]:
        lines.append("T|%s|%s|%s|%s" % (state, label, task_url(task),
                                        clean(task.get("name"))))
    return lines


def main():
    token = read_token()
    if not token:
        print("OFF")
        return
    user_id, team_ids = identity(token)
    if not user_id:
        print("ERR")
        return
    now = time.time()
    tasks = fetch_tasks(token, user_id, team_ids, end_of_today(now))
    if tasks is None:
        print("ERR")
        return
    print("\n".join(render(tasks, now)))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Nichts darf ins sketchybar-Log tropfen; ERR heisst 'lass stehen'.
        print("ERR")
