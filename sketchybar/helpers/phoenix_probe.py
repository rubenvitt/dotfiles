#!/usr/bin/python3
"""Aktuelle Position in der Phönix-Progression, gelesen aus dem Obsidian-Vault.

Die Progression ist ein 12-Wochen-System (Ära → Zyklus → Feuersturm →
1-Wochen-Feuer). Wo man gerade steht, weiss nur der Vault: der aktive
Feuersturm traegt Start und Ende im Frontmatter, seine Wochen-Tabelle die
Wochenstatus, sein Wochen-Tracker die Execution-Scores. Nichts davon liegt in
ClickUp oder einem Kalender in verwertbarer Form -- das MOC im Vault ist die
Wahrheit, und dieser Helfer liest sie so, wie sie geschrieben steht.

Gelesen wird nur, nie geschrieben. Es gibt keinen Cache: die Dateien liegen
lokal, das Parsen kostet Millisekunden.

Ausgabe, eine Zeile je Ebene, Felder mit "|" getrennt:

  S|<zustand>|<woche>|<wochen>|<tage_rest>|<letzte_woche>|<letzter_score>|<avg>|<n>
      zustand: feuer | urlaub | asche | none
      woche/wochen: aktuelle Woche und Wochenanzahl des Feuersturms
      tage_rest: Tage bis zum Ende des Feuersturms
      letzte_woche/letzter_score: juengste Woche mit eingetragenem Score
      avg/n: Durchschnitt und Anzahl der gewerteten Wochen ("" wenn keine)
  A|<aera-name>
  Z|<zyklus-name>|<zeitraum>
  F|<feuersturm-name>|<zeitraum>|<nummer im zyklus>|<anzahl im zyklus>
  E|<woche>|<alignment des aktiven Feuers>
  W|<n>|<status>|<zeitraum>     -- eine Zeile je Woche der Wochen-Tabelle

Bei "none" folgen nur die Zeilen, die es gibt (typisch: A und Z).
"""

import datetime as dt
import os
import re
import sys

VAULT = os.environ.get("PHOENIX_VAULT",
                       os.path.expanduser("~/rnotes/20-lebensbereiche/Phönix-Progression"))

# Zwischen zwei Feuerstuermen liegt eine Aschezeit; welche Woche das ist,
# steht in der Phasen-Tabelle des Zyklus und nirgends sonst.
ASCHE_MARK = "Aschezeit"
URLAUB_MARK = "🏖️"


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        k, sep, v = line.partition(":")
        if sep and not line.startswith(" "):
            out[k.strip()] = v.strip().strip("'\"")
    return out


def parse_date(s):
    """'2026-06-29' oder '29.06.2026' -> date, sonst None."""
    for fmt in ("%Y-%m-%d", "%d.%m.%Y"):
        try:
            return dt.datetime.strptime(s.strip(), fmt).date()
        except ValueError:
            pass
    return None


def active_note(folder, key="status", value="aktiv"):
    """Erste Notiz im Ordner mit status: aktiv, samt Frontmatter."""
    d = os.path.join(VAULT, folder)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None, None, {}
    for name in names:
        if not name.endswith(".md"):
            continue
        text = read(os.path.join(d, name))
        fm = frontmatter(text)
        if fm.get(key) == value:
            return name[:-3], text, fm
    return None, None, {}


def table_rows(text, heading):
    """Zeilen der ersten Markdown-Tabelle unter der Ueberschrift, als Zellenlisten."""
    m = re.search(r"^#+ .*" + re.escape(heading) + r".*?$", text, re.M)
    if not m:
        return []
    rows = []
    started = False
    for line in text[m.end():].splitlines():
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if re.match(r"^[-: ]+$", "".join(cells)):
                continue
            rows.append(cells)
            started = True
        elif started:
            break
    return rows[1:] if rows else []  # Kopfzeile weg


def week_status(cells):
    """Status einer Wochenzeile: die letzte Zelle, auf ihr erstes Symbol gekuerzt."""
    status = cells[-1] if cells else ""
    status = status.replace("**", "").strip()
    return status.split()[0] if status else ""


def sanitize(s):
    # Die Werte landen in sketchybar-Labels; "|" ist unser Trennzeichen.
    return s.replace("|", "/").replace("\n", " ").strip()


def main():
    today = dt.date.today()
    out = []

    aera_name = None
    for name in sorted(os.listdir(VAULT)) if os.path.isdir(VAULT) else []:
        if name.startswith("Ära") and name.endswith(".md"):
            aera_name = name[:-3]
    zyklus_name, zyklus_text, zyklus_fm = active_note("zyklen")
    fs_name, fs_text, fs_fm = active_note("feuerstürme")

    start = parse_date(fs_fm.get("start", ""))
    ende = parse_date(fs_fm.get("ende", ""))

    weeks = table_rows(fs_text or "", "1-Wochen-Feuer")
    total = len(weeks) or 12

    state, week, days_left = "none", 0, 0
    if start and ende and start <= today <= ende:
        week = min(total, (today - start).days // 7 + 1)
        days_left = (ende - today).days
        # Die laufende Woche traegt als Status 🔥; ob sie Urlaub ist, steht in
        # ihrer Fokus-Spalte. Abgeschlossene oder kuenftige Urlaubswochen
        # tragen die Insel auch im Status.
        row = weeks[week - 1] if week <= len(weeks) else []
        state = "urlaub" if any(URLAUB_MARK[0] in c for c in row) else "feuer"
    elif zyklus_text:
        # Kein laufender Feuersturm: liegt heute in einer Aschezeit des Zyklus?
        for cells in table_rows(zyklus_text, "Phasen"):
            if len(cells) >= 3 and ASCHE_MARK in cells[0]:
                a, b = parse_date(cells[1]), parse_date(cells[2])
                if a and b and a <= today <= b:
                    state = "asche"
                    days_left = (b - today).days

    # Scores: letzte Woche mit Wert und Durchschnitt.
    scores = []
    for cells in table_rows(fs_text or "", "Wochen-Tracker"):
        m_week = re.match(r"W(\d+)", cells[0]) if cells else None
        m_score = next((re.search(r"(\d+)/100", c) for c in cells if re.search(r"\d+/100", c)), None)
        if m_week and m_score:
            scores.append((int(m_week.group(1)), int(m_score.group(1))))
    last_week, last_score, avg = "", "", ""
    if scores:
        last_week, last_score = scores[-1]
        avg = "%.1f" % (sum(s for _, s in scores) / len(scores))

    out.append("S|%s|%d|%d|%d|%s|%s|%s|%d"
               % (state, week, total, days_left, last_week, last_score, avg, len(scores)))
    if aera_name:
        out.append("A|" + sanitize(aera_name))
    if zyklus_name:
        z_start, z_end = zyklus_fm.get("start", ""), zyklus_fm.get("ende", "")
        zs, ze = parse_date(z_start), parse_date(z_end)
        span = "%s – %s" % (zs.strftime("%d.%m.%Y"), ze.strftime("%d.%m.%Y")) if zs and ze else ""
        out.append("Z|%s|%s" % (sanitize(zyklus_name), span))
    if fs_name:
        # "Feuersturm 1 von 2" steht als Fliesstext in der Notiz.
        m = re.search(r"Feuersturm\s+(\d+)\s+von\s+(\d+)", fs_text)
        idx, cnt = (m.group(1), m.group(2)) if m else ("", "")
        out.append("F|%s|%s|%s|%s" % (sanitize(fs_name), sanitize(fs_fm.get("zeitraum", "")), idx, cnt))
        feuer_name, _, feuer_fm = active_note("feuer")
        if feuer_name:
            out.append("E|%s|%s" % (sanitize(feuer_fm.get("woche", "")),
                                    sanitize(feuer_fm.get("alignment", ""))))
        for cells in weeks:
            if len(cells) >= 2:
                out.append("W|%s|%s|%s" % (sanitize(cells[0].lstrip("W")),
                                           sanitize(week_status(cells)), sanitize(cells[1])))

    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
