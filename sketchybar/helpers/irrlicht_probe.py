#!/usr/bin/env python3
"""Aufbereitung der Irrlicht-Sessions fuer sketchybar/items/irrlicht.lua.

Liest die Antwort von http://127.0.0.1:7837/api/v1/sessions auf stdin und
gibt Zeilen aus, die sich in Lua ohne JSON-Parser auswerten lassen:

    <working> <waiting> <gesamt>
    L|<profil>|<fenster-minuten>|<prozent>|<sekunden-bis-reset>|<alter-sekunden>
    S|<session-id>|<state>|<projekt>

Die Abo-Limits haengen je Session unter metrics.rate_limit. Zu welchem Abo
eine Session gehoert, steht nicht in den Daten. Fuer Claude Code ergibt es
sich aus dem CLAUDE_CONFIG_DIR (siehe r-tools/ccp: jedes Profil hat ein
eigenes Config-Verzeichnis), und das steht im transcript_path -- alles vor
"/projects/". Genau die Sessions, die Limits melden, haben einen: die
Prozess-Treffer ohne Transkript melden nie welche. `ps eww` ueber die PID
bleibt als Rueckfalltuer, greift aber nicht immer, denn ein Teil der
Sessions kommt ohne pid und ohne adapter aus der API. Andere Adapter --
Codex etwa -- haben kein Config-Verzeichnis und werden unter ihrem
Adapternamen gefuehrt. Laesst sich kein Abo aufloesen, faellt die Session
weg statt unter einem Sammelnamen ein Phantom-Abo zu bilden. Je Abo gewinnt
der Eintrag mit dem juengsten sampled_at.

Welche Zeitfenster ein Anbieter meldet, ist nicht vorgegeben: Claude Code
liefert 300 und 10080 Minuten, Codex nur 10080. Ausgegeben wird, was da
ist.

Limits gibt es nur aus API-Antworten, ein Profil ohne laufende Session
liefert also keine. Damit die anderen Abos trotzdem sichtbar bleiben, wird
der letzte bekannte Stand je Profil zwischengespeichert und mit seinem Alter
ausgegeben. Ist der Reset-Zeitpunkt eines Fensters verstrichen, hat sich das
Fenster geleert und der gespeicherte Prozentwert ist wertlos -- eine solche
Zeile faellt weg statt zu luegen; ein Eintrag, dessen Fenster allesamt
durchgelaufen sind, wird aus dem Cache entfernt.
"""

import json
import os
import re
import subprocess
import sys
import time

CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "sketchybar", "irrlicht-limits.json",
)


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


def config_dirs(pids):
    """CLAUDE_CONFIG_DIR je PID, in einem einzigen ps-Aufruf."""
    result = {}
    if not pids:
        return result
    try:
        out = subprocess.run(
            ["ps", "eww", "-o", "pid=,command=", "-p", ",".join(pids)],
            capture_output=True, text=True, timeout=3,
        ).stdout
    except Exception:
        return result
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        for token in parts:
            if token.startswith("CLAUDE_CONFIG_DIR="):
                result[parts[0]] = token.split("=", 1)[1]
                break
    return result


def profile_name(path):
    """~/.claude -> personal, ~/.claude-work -> work."""
    name = path.rstrip("/").split("/")[-1].lstrip(".")
    if name == "claude":
        return "personal"
    return name[len("claude-"):] if name.startswith("claude-") else name


def config_dir_of(agent, dirs):
    """CLAUDE_CONFIG_DIR der Session, bevorzugt aus dem transcript_path.

    Der Pfad ist <config-dir>/projects/<slug>/<session>.jsonl und liegt jeder
    Session bei, die ueberhaupt Limits meldet. Die PID ist die schwaechere
    Quelle: sie fehlt bei einem Teil der Sessions ganz.
    """
    path = agent.get("transcript_path") or ""
    head, sep, _ = path.partition("/projects/")
    if sep and head:
        return head
    return dirs.get(str(agent.get("pid")))


def account_of(agent, dirs):
    """Abo, unter dem die Session laeuft, oder None.

    Claude-Code-Sessions unterscheiden sich nach ccp-Profil, alles andere
    laeuft unter seinem Adapternamen. Ein Config-Verzeichnis weist die Session
    als Claude Code aus, auch wenn die API kein adapter-Feld mitschickt.
    """
    config_dir = config_dir_of(agent, dirs)
    if config_dir:
        return safe_name(profile_name(config_dir))
    adapter = agent.get("adapter")
    if adapter == "claude-code":
        # Ohne Config-Verzeichnis stuende der Adaptername als eigenes "Abo"
        # neben dem Profil, zu dem dieselben Zahlen gehoeren. Lieber
        # auslassen: eine aufloesbare Session desselben Abos liefert sie
        # ohnehin.
        return None
    return safe_name(adapter) if adapter else None


def safe_name(name):
    """Abo-Namen auf das beschraenken, was die Bar unfallfrei anzeigt.

    Der Name landet in einem `sketchybar --set`-Aufruf; alles ausserhalb von
    Buchstaben, Ziffern, Strich und Unterstrich hat dort nichts zu suchen.
    Die Laenge ist gedeckelt, weil die Beschriftungsspalte im Popup fest ist
    und laengerer Text den Nachbarn ueberzeichnet statt abzubrechen.
    """
    clean = re.sub(r"[^A-Za-z0-9_-]", "", name or "")
    return clean[:10] or None


def live_windows(entry, now):
    """Fenster eines Cache-Eintrags, deren Reset noch aussteht."""
    return [w for w in ((entry or {}).get("windows") or [])
            if w.get("window_minutes") and w.get("resets_at", 0) > now]


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    agents = [a for g in (data.get("groups") or []) for a in (g.get("agents") or [])]
    # `ps` nur fuer die Sessions, denen der transcript_path nichts verraet --
    # meist bleibt die Liste leer und der Aufruf entfaellt ganz.
    dirs = config_dirs([str(a["pid"]) for a in agents
                        if a.get("pid") and not config_dir_of(a, {})])

    # Frische Limits je Profil einsammeln und im Cache festhalten.
    cache = load_cache()
    changed = False
    for agent in agents:
        limit = (agent.get("metrics") or {}).get("rate_limit") or {}
        if not limit.get("windows"):
            continue
        account = account_of(agent, dirs)
        if not account:
            continue
        sampled = limit.get("sampled_at", 0)
        if sampled > (cache.get(account) or {}).get("sampled_at", -1):
            cache[account] = {"sampled_at": sampled, "windows": limit["windows"]}
            changed = True
    # Ein Eintrag, dessen Fenster alle durchgelaufen sind, sagt nichts mehr und
    # wird auch nie wieder ausgegeben -- er bliebe sonst fuer immer im Cache.
    now = time.time()
    for account in [a for a in cache if not live_windows(cache[a], now)]:
        del cache[account]
        changed = True
    if changed:
        save_cache(cache)

    order = {"waiting": 0, "working": 1, "ready": 2}
    agents.sort(key=lambda a: (order.get(a.get("state") or "", 9),
                               a.get("project_name") or ""))
    states = [a.get("state") for a in agents]
    print(states.count("working"), states.count("waiting"), len(agents))

    for account in sorted(cache):
        entry = cache[account] or {}
        age = max(0, now - entry.get("sampled_at", 0))
        windows = sorted(live_windows(entry, now),
                         key=lambda w: w.get("window_minutes", 0))
        for window in windows:
            minutes = window["window_minutes"]
            remaining = window["resets_at"] - now
            print("L|%s|%d|%d|%d|%d" % (account, minutes,
                                        round(window.get("used_percent", 0)),
                                        remaining, age))

    for agent in agents[:10]:
        print("S|%s|%s|%s" % (agent.get("session_id") or "",
                              agent.get("state") or "",
                              agent.get("project_name") or "?"))


if __name__ == "__main__":
    main()
