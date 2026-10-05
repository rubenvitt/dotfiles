#!/usr/bin/env python3
"""Amtliche Warnungen fuer den aktuellen Standort, fuer sketchybar/items/weather.lua.

Ausgabe sind Zeilen im selben Stil wie helpers/weather_probe.py, damit Lua
ohne JSON-Parser auskommt:

    S|<lage>|<alter-sek>
    A|<quelle>|<stufe>|<kurzname>|<zeitraum>

<lage> ist einer von:

    de          Standort liegt in Deutschland, Daten (auch gealterte) vorhanden
    abroad      Standort liegt ausserhalb Deutschlands -- hier warnt niemand
    unknown     kein Standort bekannt oder noch nie eine Antwort gesehen

Der Unterschied zwischen `abroad` und `unknown` ist der Grund fuer diese Zeile:
beides sieht in der Bar gleich aus (kein Warnitem), ist aber nicht dasselbe.
Wer im Ausland sitzt, soll nicht denken, die Warnungen seien ausgefallen -- und
wer wirklich keinen Empfang hat, soll nicht denken, es gaebe nichts zu warnen.

<stufe> ist die DWD-Warnstufe 1..4 (gelb, orange, rot, violett); 0 steht fuer
Vorabinformationen und fuer Meldungen ohne Stufenangabe.

Zwei Quellen, weil beide etwas koennen, was die andere nicht kann:

  dwd    Wetterwarnungen aus dem WFS unter maps.dwd.de. Der kann einen
         Punktfilter, liefert also gemeindegenau genau die Warnungen, die auf
         diesen Koordinaten liegen -- ohne den Umweg ueber eine Warncell-Liste.
  nina   Bevoelkerungsschutz (MoWaS, KATWARN, BIWAPP, Hochwasser) ueber das
         Dashboard des Bundes. Das gibt es nur kreisweit; eine Meldung fuer den
         Nachbarort im selben Landkreis steht deshalb mit in der Liste. Genau
         so verhaelt sich die NINA-App auch.

Beide Dienste kommen ohne Schluessel aus, was in einem oeffentlichen Repo die
Bedingung ist. NINA-Meldungen mit provider "DWD" werden verworfen: dieselbe
Warnung kommt oben schon gemeindegenau herein, hier waere sie nur kreisgrob.

Caches unter $XDG_CACHE_HOME/sketchybar, wie beim Wetter ausserhalb des Repos:

  warn-area.json    Landkreis und Gemeindeschluessel zum Standort, 7 Tage
  warnings.json     Warnlage, 5 Minuten

Die Fristen gelten nur dafuer, *ob neu geholt wird*. Schlaegt der Abruf fehl,
wird der gespeicherte Stand ausgegeben -- abgelaufene Warnungen fallen dabei
ueber ihr EXPIRES von selbst heraus, eine Warnung von gestern kann also nicht
als aktuell stehenbleiben.
"""

import os
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlencode

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Der Standort kommt aus dem Cache, den weather_probe fuellt -- nie aus einer
# eigenen Ortung. Ein zweiter CoreLocation-Aufruf waere ein zweiter WLAN-Scan
# von ein, zwei Sekunden pro Durchlauf, und sketchybar wartet auf das Ende
# dieses Prozesses. Der Import bringt nebenbei mit, dass
# SKETCHYBAR_WEATHER_LATLON fuer Wetter und Warnungen denselben Ort festnagelt.
import weather_probe as wx  # noqa: E402

AREA_CACHE = os.path.join(wx.CACHE_DIR, "warn-area.json")
WARNINGS_CACHE = os.path.join(wx.CACHE_DIR, "warnings.json")

# Kreisgrenzen aendern sich im Jahrzehnttakt. Die Frist ist hier nur eine
# Bremse gegen einen dauerhaft falschen Eintrag; entwertet wird der Cache in
# der Regel durch den Ortswechsel, denn er merkt sich die Koordinate.
AREA_TTL = 604800
WARNINGS_TTL = 300

WFS = "https://maps.dwd.de/geoserver/dwd/ows"

# Zwei Fallstricke, die beide *stumm* scheitern -- der Dienst antwortet mit
# HTTP 200 und "numberReturned": 0 statt mit einem Fehler:
#
#   1. WFS 2.0.0 erwartet EPSG:4326 in der Achsenreihenfolge der Norm, also
#      POINT(<breite> <laenge>). Version 1.0.0 will es andersherum, 1.1.0
#      liefert hier ueberhaupt nichts. Gemessen, nicht abgeschrieben.
#   2. Die Geometriespalte heisst je Layer anders: die Warnungs-Layer nennen
#      sie THE_GEOM, die Gebiets-Layer SHAPE. Ein falscher Name ist immerhin
#      der freundlichere Fehler, den quittiert der Dienst mit HTTP 400.
WFS_VERSION = "2.0.0"

# Punktabfrage auf die Kreis-Warngebiete. Das ist die Bruecke zu NINA: die
# WARNCELLID eines Kreises ist eine 1 mit dem achtstelligen Gemeindeschluessel
# dahinter (Kreis Uelzen -> 103360000), die Stellen 2 bis 6 sind der
# Kreisschluessel, den das Dashboard des Bundes braucht. Damit bleibt die
# Standortaufloesung bei DWD und Bund und braucht keinen dritten Dienst.
AREA_LAYER = ("dwd:Warngebiete_Kreise", "SHAPE", "NAME,WARNCELLID")

# "vereinigt" fasst dieselbe Warnung ueber mehrere Gemeinden zu einer Geometrie
# zusammen; ohne das kaeme dieselbe Meldung fuer jede beruehrte Gemeinde einmal
# zurueck. Doppelte bleiben trotzdem moeglich, die faengt dedupe() ab.
WARN_LAYER = ("dwd:Warnungen_Gemeinden_vereinigt", "THE_GEOM",
              "IDENTIFIER,EVENT,SEVERITY,STATUS,MSGTYPE,ONSET,EXPIRES")

# DESCRIPTION und INSTRUCTION stehen bewusst nicht in der Feldliste: sie sind
# mehrere hundert Zeichen lang, in der Bar ist kein Platz dafuer, und bei einer
# bundesweiten Sturmlage haengt die Leiste sonst an einem grossen Payload.
# Die Obergrenze ist derselbe Gedanke -- an einem Punkt gelten selten mehr als
# eine Handvoll Warnungen, 40 ist reichlich und trotzdem endlich.
WARN_LIMIT = 40

DASHBOARD = "https://warnung.bund.de/api31/dashboard/%s0000000.json"

# CAP-Schweregrad auf DWD-Warnstufe. Der DWD fuehrt seine Stufen 1..4 (gelb,
# orange, rot, violett) im CAP-Profil ueber genau dieses Feld; gegengeprueft an
# einer laufenden Lage, in der SEVERITY "Minor" und EC_AREA_COLOR "255 235 59"
# -- das DWD-Gelb der Stufe 1 -- zusammen auftraten. Der Enum ist die
# belastbarere Quelle als der RGB-String, deshalb steht er hier.
LEVEL = {"Minor": 1, "Moderate": 2, "Severe": 3, "Extreme": 4}

# Kleinschreibung nach dem ersten Wort. Der DWD schreibt seine Ereignisnamen
# durchgehend gross ("SCHWERES GEWITTER MIT ORKANBOEEN"); das laesst sich nicht
# blind in Grossschreibung je Wort ueberfuehren, weil deutsche Fuellwoerter
# klein bleiben. Substantive bleiben so oder so gross, die Liste ist deshalb
# kurz und muss es auch bleiben.
LOWERCASE = {"mit", "und", "in", "im", "am", "an", "bei", "vor", "auf", "der",
             "die", "das", "des", "dem", "von", "zu", "zum", "zur", "oder"}


def now():
    return time.time()


def parse_time(value):
    """CAP-Zeitstempel auf einen Unix-Zeitpunkt. None, wenn nichts brauchbar ist.

    Der DWD schreibt Zulu-Zeit ("...T13:00:00Z"), NINA einen Versatz
    ("...+02:00"). Das Z versteht fromisoformat vor Python 3.11 nicht, der
    Versatz schon -- also wird es vorher ersetzt.
    """
    if not value:
        return None
    try:
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        stamp = datetime.fromisoformat(text)
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=timezone.utc)
        return stamp.timestamp()
    except Exception:
        return None


def wfs(layer, geom_column, fields, lat, lon, limit=1):
    """Punktabfrage auf einen WFS-Layer. Liste der Eigenschaften, nie None."""
    # Zusammengesetzt statt formatiert: der CQL-Ausdruck enthaelt Klammern,
    # Kommas und ein Leerzeichen, und curl weist eine URL mit rohem
    # Leerzeichen rundheraus ab ("Malformed input to a URL function").
    query = urlencode({
        "service": "WFS",
        "version": WFS_VERSION,
        "request": "GetFeature",
        "typeName": layer,
        "outputFormat": "application/json",
        "propertyName": fields,
        "count": limit,
        "CQL_FILTER": "INTERSECTS(%s,POINT(%.4f %.4f))" % (geom_column, lat, lon),
    })
    data = wx.fetch("%s?%s" % (WFS, query), timeout=8)
    if not isinstance(data, dict):
        return None
    return [f.get("properties") or {} for f in data.get("features") or []]


def resolve_area(location):
    """Landkreis und Gemeindeschluessel zum Standort.

    Rueckgabe ist ein Eintrag mit "ags" (leer, wenn der Ort ausserhalb
    Deutschlands liegt) oder None, wenn die Frage unbeantwortet blieb. Die
    Unterscheidung traegt bis in die Bar: ein leerer Schluessel heisst
    "hier warnt niemand", None heisst "wir wissen es nicht".
    """
    cached = wx.load_cache(AREA_CACHE)
    same_place = bool(cached) and (
        cached.get("lat") == location["lat"] and cached.get("lon") == location["lon"]
    )
    if same_place and now() - cached.get("at", 0) < AREA_TTL:
        return cached

    found = wfs(*AREA_LAYER, lat=location["lat"], lon=location["lon"])
    if found is None:
        return cached if same_place else None

    entry = {"lat": location["lat"], "lon": location["lon"],
             "ags": "", "kreis": "", "at": now()}
    if found:
        # Kein Treffer ist hier kein Fehler, sondern die Antwort "ausserhalb
        # Deutschlands" -- der Layer deckt nur das Bundesgebiet ab.
        cell = str(found[0].get("WARNCELLID") or "")
        if len(cell) == 9 and cell.isdigit():
            entry["ags"] = cell[1:6]
            entry["kreis"] = (found[0].get("NAME") or "")[:32]
    wx.save_cache(AREA_CACHE, entry)
    return entry


def event_name(event):
    """DWD-Ereignisnamen aus der Grossschreibung holen: WINDBOEEN -> Windboeen."""
    words = (event or "").split()
    out = []
    for i, word in enumerate(words):
        lower = word.lower()
        out.append(lower if i > 0 and lower in LOWERCASE else lower.capitalize())
    return shorten(" ".join(out))


def dwd_warnings(location):
    """Wetterwarnungen am Punkt. None, wenn der Dienst nicht geantwortet hat."""
    rows = wfs(*WARN_LAYER, lat=location["lat"], lon=location["lon"],
               limit=WARN_LIMIT)
    if rows is None:
        return None

    out = []
    for p in rows:
        # Der DWD schickt Uebungs- und Testwarnungen ueber denselben Kanal wie
        # echte; ohne diesen Filter steht eine Uebung als Warnung in der Bar.
        if p.get("STATUS") != "Actual":
            continue
        if p.get("MSGTYPE") == "Cancel":
            continue
        out.append({
            "id": p.get("IDENTIFIER") or "",
            "src": "dwd",
            "level": LEVEL.get(p.get("SEVERITY"), 0),
            "name": event_name(p.get("EVENT")),
            "onset": parse_time(p.get("ONSET")),
            "expires": parse_time(p.get("EXPIRES")),
        })
    return out


# Wie viele Zeichen ein Kurzname haben darf. Die Zahl kommt aus der Breite der
# Warnzeile im Popup (146 Punkte abzueglich Dreieck und Abstand, gut fuenf
# Punkte je Zeichen) -- laenger heisst nicht mehr Information, sondern eine
# Zeile, die scrollt.
NAME_CHARS = 22


def shorten(text):
    """Kurznamen auf NAME_CHARS bringen, moeglichst am Wortende.

    Ein Schnitt mitten im Wort ("Bekaempfung d") liest sich wie ein Fehler.
    Bleibt vom Wortschnitt aber zu wenig uebrig -- "Verkeimtes" von "Verkeimtes
    Trinkwasser" --, ist der harte Schnitt der ehrlichere: er zeigt, dass da
    noch etwas kommt, statt einen anderen Begriff vorzutaeuschen.
    """
    if len(text) <= NAME_CHARS:
        return text
    head = text[:NAME_CHARS].rsplit(" ", 1)[0]
    # Ein Name, der auf "mit" oder "von" endet, sieht abgerissen aus statt
    # gekuerzt -- das Fuellwort traegt allein ohnehin nichts.
    while " " in head and head.rsplit(" ", 1)[1].lower() in LOWERCASE:
        head = head.rsplit(" ", 1)[0]
    if len(head) < NAME_CHARS * 0.6:
        head = text[:NAME_CHARS]
    return head.rstrip(" ,;-") + "…"


def nina_title(entry):
    """Kurzname aus einer NINA-Meldung.

    Die Titel sind ganze Saetze mit angehaengtem Gebiet ("2.04 Verkeimtes
    Trinkwasser - Abkochanordnung fuer den Markt Obernzell - Markt Obernzell -
    Landkreis Passau"). Das Gebiet steht in der Bar schon nebenan, und die
    fuehrende Ziffernfolge ist der interne Meldungstyp -- beides faellt weg.
    """
    title = ((entry.get("i18nTitle") or {}).get("de") or "").strip()
    title = title.split(" - ")[0].strip()
    head = title.split(" ", 1)
    if len(head) == 2 and head[0].replace(".", "").isdigit():
        title = head[1].strip()
    return shorten(title)


def nina_warnings(ags):
    """Bevoelkerungsschutz im Landkreis. None, wenn der Dienst schwieg."""
    data = wx.fetch(DASHBOARD % ags, timeout=6)
    if not isinstance(data, list):
        return None

    out = []
    for entry in data:
        payload = ((entry.get("payload") or {}).get("data")) or {}
        # Dieselbe Warnung kommt oben gemeindegenau herein; kreisgrob waere sie
        # hier nur ein zweites, ungenaueres Exemplar.
        if (payload.get("provider") or "").upper() == "DWD":
            continue
        # Entwarnungen sind der haeufigste Eintrag ueberhaupt -- die einzige
        # laufende Hochwassermeldung bei der Entwicklung war eine.
        if (payload.get("msgType") or entry.get("type") or "") == "Cancel":
            continue
        if (payload.get("urgency") or "") == "Past":
            continue
        out.append({
            "id": entry.get("id") or "",
            "src": "nina",
            "level": LEVEL.get(payload.get("severity"), 0),
            "name": nina_title(entry),
            "onset": parse_time(entry.get("sent")),
            "expires": None,
        })
    return out


def dedupe(warnings):
    """Gleiche Meldung nur einmal.

    Der vereinigte Layer liefert dieselbe Warnung mehrfach, wenn sie in
    mehreren Teilflaechen liegt; verglichen wird deshalb nicht die Zeile,
    sondern die Meldung.
    """
    seen, out = set(), []
    for w in warnings:
        key = (w["src"], w["id"], w["name"], w["onset"])
        if key in seen:
            continue
        seen.add(key)
        out.append(w)
    return out


def resolve_warnings(location, ags):
    """Warnlage zum Standort, mit Cache. Rueckgabe auch dann, wenn sie alt ist."""
    cached = wx.load_cache(WARNINGS_CACHE)
    same_place = bool(cached) and (
        cached.get("lat") == location["lat"] and cached.get("lon") == location["lon"]
    )
    if same_place and now() - cached.get("at", 0) < WARNINGS_TTL:
        return cached

    weather, civil = dwd_warnings(location), nina_warnings(ags)
    # Nur eine der beiden Quellen zu uebernehmen hiesse, die andere fuer
    # entwarnt zu erklaeren. Faellt eine aus, bleibt der gemeinsame alte Stand
    # stehen -- abgelaufene Warnungen raeumt emit() ohnehin weg.
    if weather is None or civil is None:
        return cached if same_place else None

    fresh = {"lat": location["lat"], "lon": location["lon"], "at": now(),
             "warnings": dedupe(weather + civil)}
    wx.save_cache(WARNINGS_CACHE, fresh)
    return fresh


def clock(stamp):
    """Unix-Zeitpunkt auf die volle Stunde in Ortszeit: 1787...  -> '13'."""
    return time.strftime("%H", time.localtime(stamp))


def period(warning):
    """Kurzer Zeitraum fuer die Popup-Zeile.

    Vier Faelle, weil der DWD EXPIRES weglassen darf und NINA es nie mitgibt:
    laufend und befristet, laufend und offen, kuenftig und befristet, kuenftig
    und offen.
    """
    onset, expires = warning.get("onset"), warning.get("expires")
    ahead = onset is not None and onset > now() + 60
    if ahead and expires:
        # Ohne Spatien um den Strich: die Wertspalte ist knapp, und "13–18 Uhr"
        # ist genauso eindeutig wie "13 – 18 Uhr".
        return "%s–%s Uhr" % (clock(onset), clock(expires))
    if ahead:
        return "ab %s Uhr" % clock(onset)
    if expires:
        return "bis %s Uhr" % clock(expires)
    if onset:
        return "seit %s" % time.strftime("%d.%m.", time.localtime(onset))
    return ""


def clean(text):
    """Der Trenner darf im Text nicht vorkommen, sonst zerfaellt die Zeile."""
    return (text or "").replace("|", "/").replace("\n", " ").strip()


def main():
    location = wx.pinned_location() or wx.load_cache(wx.LOCATION_CACHE)
    if not location or "lat" not in location:
        print("S|unknown|0")
        return

    area = resolve_area(location)
    if area is None:
        print("S|unknown|0")
        return
    if not area.get("ags"):
        print("S|abroad|0")
        return

    entry = resolve_warnings(location, area["ags"])
    if not entry:
        print("S|unknown|0")
        return

    print("S|de|%d" % max(0, int(now() - entry.get("at", 0))))

    # Abgelaufenes faellt hier heraus, nicht beim Holen: so kann ein Stand aus
    # dem Cache eine Warnung nicht ueber ihr Ende hinaus am Leben halten.
    current = [w for w in entry.get("warnings") or []
               if not w.get("expires") or w["expires"] > now()]
    # Schaerfstes zuerst, bei gleicher Stufe das, was zuerst anfaengt: die Bar
    # zeigt nur die erste Zeile, und das soll die wichtigste sein.
    current.sort(key=lambda w: (-w.get("level", 0), w.get("onset") or 0))

    for w in current[:5]:
        print("A|%s|%d|%s|%s" % (
            w.get("src") or "dwd",
            w.get("level") or 0,
            clean(w.get("name")) or "Warnung",
            clean(period(w)),
        ))


if __name__ == "__main__":
    main()
