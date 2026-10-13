# Selbsttest für helpers/zunder_probe.py:  /usr/bin/python3 ~/.config/sketchybar/helpers/zunder_probe_test.py
# Alle Aufgaben sind ausgedacht.

import datetime as dt
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zunder_probe import render  # noqa: E402

now = dt.datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)
today = now.date()


def at(hour, days=0):
    return (now.replace(hour=hour) + dt.timedelta(days=days)).isoformat()


tasks = [
    {"id": "a1", "title": "ohne Uhrzeit heute", "status": "open", "due": today.isoformat()},
    {"id": "a2", "title": "um neun, vorbei", "status": "in_progress", "due": at(9)},
    {"id": "a3", "title": "um fünfzehn", "status": "blocked", "due": at(15)},
    {"id": "a4", "title": "gestern ohne Uhrzeit", "status": "open",
     "due": (today - dt.timedelta(days=1)).isoformat()},
    {"id": "a5", "title": "vor drei Tagen", "status": "review", "due": at(12, -3)},
    {"id": "x1", "title": "erledigt", "status": "done", "due": at(9)},
    {"id": "x2", "title": "morgen", "status": "open", "due": at(9, 1)},
    {"id": "x3", "title": "ohne Fälligkeit", "status": "open", "due": None},
    {"id": "x4", "title": "kaputt", "status": "open", "due": "irgendwann"},
    {"id": "../$(rm)", "title": "böse|ID\nmit Umbruch", "status": "open", "due": at(16)},
]

lines = render(tasks, now)
assert lines[0] == "C|4|2|1", lines[0]
assert lines[1:] == [
    "T|now|09:00|https://zunder.rubeen.dev/#/aufgabe/a2|um neun, vorbei",
    "T|today|15:00|https://zunder.rubeen.dev/#/aufgabe/a3|um fünfzehn",
    "T|today|16:00||böse ID mit Umbruch",
    "T|today|heute|https://zunder.rubeen.dev/#/aufgabe/a1|ohne Uhrzeit heute",
    "T|late|vor 1d|https://zunder.rubeen.dev/#/aufgabe/a4|gestern ohne Uhrzeit",
    "T|late|vor 3d|https://zunder.rubeen.dev/#/aufgabe/a5|vor drei Tagen",
], "\n".join(lines)
assert render([], now) == ["C|0|0|0"]
print("ok")
