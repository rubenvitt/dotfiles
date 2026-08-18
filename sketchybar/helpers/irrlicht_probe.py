#!/usr/bin/env python3
"""Aufbereitung der Irrlicht-Sessions fuer sketchybar/items/irrlicht.lua.

Liest die Antwort von http://127.0.0.1:7837/api/v1/sessions auf stdin und
gibt Zeilen aus, die sich in Lua ohne JSON-Parser auswerten lassen:

    <working> <waiting> <gesamt>
    L|<profil>|<fenster-minuten>|<prozent>|<sekunden-bis-reset>
    S|<session-id>|<state>|<projekt>

Die Abo-Limits haengen je Session unter metrics.rate_limit. Zu welchem Abo
eine Session gehoert, steht nicht in den Daten -- es ergibt sich aus dem
CLAUDE_CONFIG_DIR ihres Prozesses, das `ps eww` liefert (siehe r-tools/ccp:
jedes Profil hat ein eigenes Config-Verzeichnis). Je Profil gewinnt der
Eintrag mit dem juengsten sampled_at.

Ein Profil ohne laufende Session taucht nicht auf: die Limits stammen aus
API-Antworten, ohne Session gibt es keine.
"""

import sys, json, time, subprocess

try: d = json.load(sys.stdin)
except Exception: raise SystemExit

rows, pids = [], []
for g in (d.get("groups") or []):
    for a in (g.get("agents") or []):
        rows.append(a)
        if a.get("pid"): pids.append(str(a["pid"]))

# CLAUDE_CONFIG_DIR je PID: ein ps-Aufruf fuer alle Sessions
env_by_pid = {}
if pids:
    try:
        out = subprocess.run(["ps", "eww", "-o", "pid=,command=", "-p", ",".join(pids)],
                             capture_output=True, text=True, timeout=3).stdout
        for line in out.splitlines():
            parts = line.split()
            if not parts: continue
            pid = parts[0]
            for tok in parts:
                if tok.startswith("CLAUDE_CONFIG_DIR="):
                    env_by_pid[pid] = tok.split("=", 1)[1]
    except Exception:
        pass

def profile_of(a):
    path = env_by_pid.get(str(a.get("pid")), "")
    if not path: return None
    name = path.rstrip("/").split("/")[-1].lstrip(".")
    if name == "claude": return "personal"
    return name[len("claude-"):] if name.startswith("claude-") else name

limits = {}
for a in rows:
    prof = profile_of(a)
    rl = (a.get("metrics") or {}).get("rate_limit") or {}
    if not prof or not rl.get("windows"): continue
    cur = limits.get(prof)
    if cur is None or rl.get("sampled_at", 0) > cur[0]:
        limits[prof] = (rl.get("sampled_at", 0), rl["windows"])

order = {"waiting": 0, "working": 1, "ready": 2}
rows.sort(key=lambda a: (order.get(a.get("state") or "", 9), a.get("project_name") or ""))
states = [a.get("state") for a in rows]
print(states.count("working"), states.count("waiting"), len(rows))

now = time.time()
for prof in sorted(limits):
    for minutes in (300, 10080):
        w = next((x for x in limits[prof][1] if x.get("window_minutes") == minutes), None)
        if w:
            print("L|%s|%d|%d|%d" % (prof, minutes, round(w.get("used_percent", 0)),
                                     max(0, w.get("resets_at", 0) - now)))

for a in rows[:10]:
    print("S|%s|%s|%s" % (a.get("session_id") or "", a.get("state") or "",
                          a.get("project_name") or "?"))
