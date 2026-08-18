#!/usr/bin/env python3
"""Aufbereitung der Irrlicht-Sessions fuer sketchybar/items/irrlicht.lua.

Liest die Antwort von http://127.0.0.1:7837/api/v1/sessions auf stdin und
gibt Zeilen aus, die sich in Lua ohne JSON-Parser auswerten lassen:

    <working> <waiting> <gesamt>
    L|<profil>|<fenster-minuten>|<prozent>|<sekunden-bis-reset>|<alter-sekunden>
    S|<session-id>|<state>|<projekt>

Die Abo-Limits haengen je Session unter metrics.rate_limit. Zu welchem Abo
eine Session gehoert, steht nicht in den Daten. Fuer Claude Code ergibt es
sich aus dem CLAUDE_CONFIG_DIR ihres Prozesses, das `ps eww` liefert (siehe
r-tools/ccp: jedes Profil hat ein eigenes Config-Verzeichnis). Andere
Adapter -- Codex etwa -- haben kein solches Verzeichnis und teils gar keine
PID; sie werden unter ihrem Adapternamen gefuehrt. Eine Claude-Code-Session
ohne aufloesbare PID bleibt aussen vor, sonst entstuende neben dem Profil
ein zweiter Eintrag mit denselben Zahlen. Je Abo gewinnt der
Eintrag mit dem juengsten sampled_at.

Welche Zeitfenster ein Anbieter meldet, ist nicht vorgegeben: Claude Code
liefert 300 und 10080 Minuten, Codex nur 10080. Ausgegeben wird, was da
ist.

Limits gibt es nur aus API-Antworten, ein Profil ohne laufende Session
liefert also keine. Damit die anderen Abos trotzdem sichtbar bleiben, wird
der letzte bekannte Stand je Profil zwischengespeichert und mit seinem Alter
ausgegeben. Ist der Reset-Zeitpunkt eines Fensters verstrichen, hat sich das
Fenster geleert und der gespeicherte Prozentwert ist wertlos -- eine solche
Zeile faellt weg statt zu luegen.
"""

import json
import os
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


def account_of(agent, dirs):
    """Abo, unter dem die Session laeuft.

    Claude-Code-Sessions unterscheiden sich nach ccp-Profil, alles andere
    laeuft unter seinem Adapternamen. Ohne PID -- Codex meldet keine -- bleibt
    nur der Adapter.
    """
    adapter = agent.get("adapter") or "?"
    path = dirs.get(str(agent.get("pid")))
    if adapter == "claude-code":
        # Ohne aufloesbare PID -- beendete Session, ps ohne Treffer -- bliebe
        # nur der Adaptername, und der stuende als eigenes "Abo" neben dem
        # Profil, zu dem dieselben Zahlen gehoeren. Lieber auslassen: eine
        # laufende Session desselben Profils liefert sie ohnehin.
        return profile_name(path) if path else None
    return adapter


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    agents = [a for g in (data.get("groups") or []) for a in (g.get("agents") or [])]
    dirs = config_dirs([str(a["pid"]) for a in agents if a.get("pid")])

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
    if changed:
        save_cache(cache)

    order = {"waiting": 0, "working": 1, "ready": 2}
    agents.sort(key=lambda a: (order.get(a.get("state") or "", 9),
                               a.get("project_name") or ""))
    states = [a.get("state") for a in agents]
    print(states.count("working"), states.count("waiting"), len(agents))

    now = time.time()
    for account in sorted(cache):
        entry = cache[account] or {}
        age = max(0, now - entry.get("sampled_at", 0))
        windows = sorted((entry.get("windows") or []),
                         key=lambda w: w.get("window_minutes", 0))
        for window in windows:
            minutes = window.get("window_minutes")
            if not minutes:
                continue
            remaining = window.get("resets_at", 0) - now
            if remaining <= 0:
                # Fenster ist seit der Messung durchgelaufen.
                continue
            print("L|%s|%d|%d|%d|%d" % (account, minutes,
                                        round(window.get("used_percent", 0)),
                                        remaining, age))

    for agent in agents[:10]:
        print("S|%s|%s|%s" % (agent.get("session_id") or "",
                              agent.get("state") or "",
                              agent.get("project_name") or "?"))


if __name__ == "__main__":
    main()
