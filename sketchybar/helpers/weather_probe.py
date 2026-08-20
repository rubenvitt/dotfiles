#!/usr/bin/env python3
"""Wetter fuer den aktuellen Standort, aufbereitet fuer sketchybar/items/weather.lua.

Ausgabe sind Zeilen, die sich in Lua ohne JSON-Parser auswerten lassen:

    W|<wmo-code>|<is_day>|<temp>|<gefuehlt>|<wind-kmh>|<regen-prozent>|<alter-sek>
    O|<ort>
    D|<max>|<min>|<sonnenaufgang>|<sonnenuntergang>
    H|<stunde>|<wmo-code>|<temp>|<regen-prozent>

Das Wetter kommt ohne API-Schluessel von Open-Meteo, weil dieses Repo
oeffentlich ist. Der Nutzer wechselt als Berater staendig den Ort, ein fest
eingetragener Standort waere also nicht nur ein Datenleck, sondern schlicht
falsch.

Den Standort liefern die macOS-Ortungsdienste ueber CoreLocationCLI. Vorher
stand hier eine Geo-IP-Abfrage, und die zeigte verlaesslich den Knoten des
Providers statt den Ort des Rechners -- bei Mobilfunk oder VPN mehrere hundert
Kilometer daneben. CoreLocation trianguliert stattdessen die umliegenden
WLAN-Netze und liegt damit im zweistelligen Meterbereich; den Ortsnamen holt
dieselbe Abfrage aus Apples Reverse-Geocoder statt aus einer IP-Datenbank.

Geo-IP bleibt als Rueckfallebene, denn die Ortungsdienste schweigen, wenn sie
abgeschaltet sind oder das WLAN aus ist (Ethernet, Flugmodus). Ein IP-Ort wird
in der Bar als ungefaehr gekennzeichnet, damit ein grob falscher Ort nicht wie
ein gemessener aussieht.

Einrichtung auf einer frischen Maschine: `brew bundle` bringt das Cask
corelocationcli mit, die Freigabe muss aber von Hand kommen -- einmal

    /Applications/CoreLocationCLI.app/Contents/MacOS/CoreLocationCLI

im Terminal aufrufen und den Dialog bestaetigen, danach steht der Schalter
unter Systemeinstellungen > Datenschutz & Sicherheit > Ortungsdienste. Ohne
Freigabe faellt dieses Skript auf Geo-IP zurueck, die Bar bleibt also nutzbar.

Zwei Caches, beide ausserhalb des Repos unter $XDG_CACHE_HOME/sketchybar:

  weather-location.json   Standort, 30 Minuten
  weather.json            Wetterantwort, 10 Minuten

Die Zeit gilt nur dafuer, *ob neu geholt wird*, nicht dafuer, ob der alte Wert
noch taugt: schlaegt der Abruf fehl -- Hotel-WLAN, Zug, Dienst weg --, wird der
gespeicherte Stand samt Alter ausgegeben. Die Bar zeigt dann weiter Wetter,
nur ergraut und mit Altersangabe, statt leer zu sein. Zehn Minuten liegen
bewusst unter dem 15-Minuten-Takt der Bar, damit jeder Durchlauf tatsaechlich
frische Daten sieht und nicht jedes zweite Mal am Cache haengenbleibt.

Ohne je aufgeloesten Standort wird nichts ausgegeben; die Bar blendet das Item
dann aus. Ein hart hinterlegter Ersatzort waere entweder der Wohnort des
Nutzers (gehoert nicht in ein oeffentliches Repo) oder schlicht gelogen.
"""

import json
import os
import subprocess
import sys
import time

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "sketchybar",
)
LOCATION_CACHE = os.path.join(CACHE_DIR, "weather-location.json")
WEATHER_CACHE = os.path.join(CACHE_DIR, "weather.json")

# Ein Fix kostet einen WLAN-Scan von ein, zwei Sekunden -- billig genug fuer die
# Haelfte des 15-Minuten-Takts der Bar, zu teuer fuer jeden Durchlauf. Den Fall,
# der die kurze Frist eigentlich braeuchte -- Deckel zu in Hamburg, auf in
# Berlin --, deckt nicht die TTL ab, sondern das Argument --relocate, das die
# Bar beim Aufwachen mitgibt.
LOCATION_TTL = 1800
WEATHER_TTL = 600

# CoreLocationCLI aus dem Homebrew-Cask corelocationcli. Der absolute Pfad ist
# Absicht: sketchybar laeuft unter launchd und hat /opt/homebrew/bin nicht im
# PATH -- ein blosser Programmname liefe hier ins Leere.
CORE_LOCATION = "/Applications/CoreLocationCLI.app/Contents/MacOS/CoreLocationCLI"

# Reihenfolge der Felder in der Antwort von CORE_LOCATION. Ein eigenes Format
# statt --json, weil damit hier feststeht, was zurueckkommt, und nicht das
# Schema einer fremden Version.
CORE_LOCATION_FORMAT = (
    "%latitude|%longitude|%h_accuracy|%locality|%subAdministrativeArea"
)

# Der Scan darf laenger dauern als ein HTTP-Aufruf, aber nicht beliebig: die
# Bar wartet auf das Ende dieses Prozesses.
CORE_LOCATION_TIMEOUT = 8

# Ab welchem Radius ein Fix nicht mehr als gemessen durchgeht. Findet
# CoreLocation kein WLAN, das es kennt -- Ethernet, Flugmodus, Funkloch --,
# antwortet es trotzdem, und zwar mit einer aus der IP geschaetzten Position.
# Das ist wortwoertlich derselbe Fehler, den die Ortungsdienste hier
# ausraeumen sollen, nur ohne den verraeterischen Absender. Erkennbar ist er
# einzig an der Streuung: eine WLAN-Ortung liegt bei einigen zehn Metern, eine
# aus der IP bei Kilometern.
COARSE_ABOVE = 5000

# Wie lange ein gemessener Fix einem frischen IP-Ort vorgezogen wird. Faellt
# das WLAN weg, ist der letzte gemessene Standort fast immer naeher an der
# Wahrheit als der Provider-Knoten -- aber nach einem halben Tag kann ein Flug
# dazwischenliegen, und dann ist auch ein grober IP-Ort besser als ein
# praeziser von gestern.
MEASURED_BEATS_IP = 21600

# Nur noch Rueckfallebene, siehe Modulkopf. Ein IP-Ort ist die Adresse des
# Providers, nicht die des Rechners -- brauchbar, um ueberhaupt etwas zu
# zeigen, nicht als Antwort auf die Frage, wie das Wetter hier ist.
# ipapi.co vor ip-api.com: ip-api.com liefert HTTPS nur gegen Schluessel,
# laeuft also unverschluesselt. Bei hoechstens einem Standort pro halber
# Stunde bleiben beide weit unter ihren Freikontingenten (ipapi.co 1000/Tag,
# ip-api.com 45/Minute).
# Reihenfolge nach Erreichbarkeit, nicht nach Qualitaet: die gaengigen
# Geo-IP-Dienste (ipapi.co, ip-api.com, ipinfo.io, ipwho.is ...) stehen auf
# den ueblichen Tracking-Blocklisten und werden vom DNS hier auf 0.0.0.0
# aufgeloest. ifconfig.co kommt durch und liefert dieselben Felder.
LOCATION_SOURCES = (
    ("https://ifconfig.co/json", ("latitude", "longitude")),
    ("https://ipapi.co/json/", ("latitude", "longitude")),
    ("http://ip-api.com/json/?fields=status,city,lat,lon", ("lat", "lon")),
)

FORECAST = (
    "https://api.open-meteo.com/v1/forecast"
    "?latitude=%.2f&longitude=%.2f"
    "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,"
    "is_day,precipitation_probability"
    "&hourly=temperature_2m,weather_code,precipitation_probability"
    "&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset"
    "&forecast_days=2&timezone=auto"
)


def fetch(url, timeout=5):
    """Harte Zeitgrenze pro Aufruf -- ein haengender Dienst darf die Bar nicht
    aufhalten, und sketchybar wartet auf das Ende dieses Prozesses."""
    try:
        out = subprocess.run(
            ["curl", "-fsS", "--max-time", str(timeout),
             "-H", "Accept: application/json", url],
            capture_output=True, text=True, timeout=timeout + 2,
        )
        return json.loads(out.stdout) if out.returncode == 0 else None
    except Exception:
        return None


def load_cache(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def save_cache(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        pass


def pinned_location():
    """Standort festnageln, ohne ihn ins Repo zu schreiben.

    Wer bewusst einen anderen Ort sehen will -- oder wessen IP im falschen
    Rechenzentrum landet --, setzt

        launchctl setenv SKETCHYBAR_WEATHER_LATLON "<breite>,<laenge>"

    und startet sketchybar neu. Ein export in .zshrc genuegt nicht: sketchybar
    laeuft unter launchd und sieht die Shell-Umgebung nie. Aus dem Repo kommt
    der Wert so oder so nicht.
    """
    raw = os.environ.get("SKETCHYBAR_WEATHER_LATLON")
    if not raw:
        return None
    try:
        lat, lon = (float(p) for p in raw.split(",", 1))
    except Exception:
        return None
    return {"lat": lat, "lon": lon,
            "city": os.environ.get("SKETCHYBAR_WEATHER_CITY", ""),
            "src": "pin", "at": time.time()}


def clean(field):
    """Leere Felder des Reverse-Geocoders vereinheitlichen.

    Ohne Netz liefert CoreLocation zwar Koordinaten, aber keine Namen; je nach
    Version steht dann ein leerer String, "N/A" oder "<null>" in der Spalte.
    """
    field = (field or "").strip()
    return "" if field in ("", "N/A", "<null>", "(null)", "nil") else field


def system_location():
    """Standort ueber die macOS-Ortungsdienste. None, wenn sie schweigen.

    Schweigen ist hier der Normalfall, nicht die Ausnahme: sind die
    Ortungsdienste aus oder fuer dieses Programm nicht freigegeben, endet der
    Aufruf sofort mit einem Fehler -- gewollt, denn das ist kein Zustand, den
    ein Skript im Hintergrund reparieren darf.
    """
    if not os.path.exists(CORE_LOCATION):
        return None
    try:
        out = subprocess.run(
            [CORE_LOCATION, "--format", CORE_LOCATION_FORMAT],
            capture_output=True, text=True, timeout=CORE_LOCATION_TIMEOUT,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None

    parts = (out.stdout.strip().splitlines() or [""])[-1].split("|")
    if len(parts) < 5:
        return None
    try:
        lat, lon = float(parts[0]), float(parts[1])
    except ValueError:
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None

    # Ein negativer Radius heisst bei CoreLocation "keine Angabe" -- fuer die
    # Frage, ob hier gemessen wurde, zaehlt das wie ein schlechter Wert.
    try:
        accuracy = float(parts[2])
    except ValueError:
        accuracy = -1.0
    measured = 0 <= accuracy <= COARSE_ABOVE

    # Ortsname vor Kreisname: "Winterhude" sagt mehr als "Hamburg", aber auf
    # dem Land gibt es kein locality und dann ist der Kreis alles, was bleibt.
    city = clean(parts[3]) or clean(parts[4])
    # Zwei Nachkommastellen sind rund ein Kilometer genau -- mehr braucht eine
    # Wettervorhersage nicht, und die Cache-Datei wird dadurch nebenbei
    # weniger verraeterisch. Gerundet wird erst hier, nach dem Geocoding: eine
    # gerundete Koordinate landet an der Ortsgrenze schon im Nachbarort.
    return {"lat": round(lat, 2), "lon": round(lon, 2), "city": city[:24],
            "src": "gps" if measured else "ip", "at": time.time()}


def ip_location():
    """Standort per IP. Grob, aber ohne Berechtigung und ohne WLAN."""
    for url, (lat_key, lon_key) in LOCATION_SOURCES:
        data = fetch(url, timeout=4)
        if not isinstance(data, dict):
            continue
        # Beide Dienste antworten im Fehlerfall mit HTTP 200 und einem
        # Fehlerobjekt (ipapi.co: {"error": true, "reason": "RateLimited"}).
        # Belastbar ist nur, ob zwei plausible Zahlen drinstehen.
        try:
            lat, lon = float(data[lat_key]), float(data[lon_key])
        except (KeyError, TypeError, ValueError):
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue
        # Zwei Nachkommastellen sind rund ein Kilometer genau -- mehr braucht
        # eine Wettervorhersage nicht, und die Cache-Datei wird dadurch
        # nebenbei weniger verraeterisch.
        return {"lat": round(lat, 2), "lon": round(lon, 2),
                "city": (data.get("city") or "")[:24],
                "src": "ip", "at": time.time()}

    return None


def resolve_location(relocate=False):
    """Standort, mit Cache. Rueckgabe auch dann, wenn er alt ist.

    relocate verwirft den Cache. Die Bar gibt das Argument beim Aufwachen mit:
    zwischen Zuklappen und Aufklappen liegt der Ortswechsel, den die Frist
    sonst eine halbe Stunde lang verschweigen wuerde.
    """
    pinned = pinned_location()
    if pinned:
        return pinned

    cached = load_cache(LOCATION_CACHE)
    fresh_enough = (
        cached is not None
        and not relocate
        and time.time() - cached.get("at", 0) < LOCATION_TTL
    )
    if fresh_enough:
        return cached

    found = system_location()
    if found:
        # Ohne Netz bleibt der Reverse-Geocoder stumm, die Koordinate stimmt
        # aber. Steht im Cache ein Name fuer praktisch dieselbe Stelle, ist er
        # richtiger als "unbekannt" -- 0.05 Grad sind etwa fuenf Kilometer.
        if not found["city"] and cached and abs(cached.get("lat", 99) - found["lat"]) < 0.05 \
                and abs(cached.get("lon", 999) - found["lon"]) < 0.05:
            found["city"] = cached.get("city") or ""
        save_cache(LOCATION_CACHE, found)
        return found

    # Ein gemessener Standort von vorhin schlaegt einen frischen IP-Ort,
    # solange kein Flug dazwischenpassen kann -- siehe MEASURED_BEATS_IP.
    if cached and cached.get("src") == "gps" \
            and time.time() - cached.get("at", 0) < MEASURED_BEATS_IP:
        return cached

    found = ip_location()
    if found:
        save_cache(LOCATION_CACHE, found)
        return found

    return cached


def resolve_weather(location):
    """Wetter zum Standort, mit Cache. Rueckgabe auch dann, wenn es alt ist."""
    cached = load_cache(WEATHER_CACHE)
    # Ein Ortswechsel entwertet den Cache sofort, sonst zeigt die Bar nach der
    # Landung noch das Wetter des Abflughafens.
    same_place = bool(cached) and (
        cached.get("lat") == location["lat"] and cached.get("lon") == location["lon"]
    )
    if same_place and time.time() - cached.get("at", 0) < WEATHER_TTL:
        return cached

    data = fetch(FORECAST % (location["lat"], location["lon"]), timeout=6)
    if isinstance(data, dict) and data.get("current"):
        fresh = {"lat": location["lat"], "lon": location["lon"],
                 "at": time.time(), "data": data}
        save_cache(WEATHER_CACHE, fresh)
        return fresh
    return cached if same_place else None


def hour_label(iso):
    """'2026-08-19T15:00' -> '15'"""
    return iso[11:13]


def main():
    location = resolve_location(relocate="--relocate" in sys.argv[1:])
    if not location:
        return
    entry = resolve_weather(location)
    if not entry:
        return

    data = entry["data"]
    current = data.get("current") or {}
    if "temperature_2m" not in current:
        return

    age = max(0, int(time.time() - entry.get("at", 0)))
    print("W|%d|%d|%d|%d|%d|%d|%d" % (
        current.get("weather_code", -1),
        current.get("is_day", 1),
        round(current["temperature_2m"]),
        round(current.get("apparent_temperature") or current["temperature_2m"]),
        round(current.get("wind_speed_10m") or 0),
        round(current.get("precipitation_probability") or 0),
        age,
    ))

    # Die Quelle steht mit in der Zeile: ein IP-Ort ist der Provider-Knoten und
    # kann Hunderte Kilometer danebenliegen. Die Bar kennzeichnet ihn deshalb
    # als ungefaehr, statt ihn wie eine Messung aussehen zu lassen.
    city = location.get("city") or ""
    if city:
        print("O|%s|%s" % (location.get("src") or "ip", city))

    # Bezugspunkt fuer Tages- und Stundenzeilen. Bei frischen Daten ist das die
    # Messzeit; ist die Antwort aus dem Cache gealtert, waere eine "Vorschau"
    # aus der Vergangenheit irrefuehrend -- dann zaehlt die Uhr, umgerechnet in
    # die Zeitzone des Standorts.
    local_now = time.strftime("%Y-%m-%dT%H:%M", time.gmtime(
        time.time() + (data.get("utc_offset_seconds") or 0)))
    reference = max(current.get("time") or local_now, local_now)

    daily = data.get("daily") or {}
    days = daily.get("time") or []
    today = next((i for i, d in enumerate(days) if d >= reference[:10]), None)
    if today is not None:
        print("D|%d|%d|%s|%s" % (
            round(daily["temperature_2m_max"][today]),
            round(daily["temperature_2m_min"][today]),
            daily["sunrise"][today][11:16],
            daily["sunset"][today][11:16],
        ))

    # ISO-8601 sortiert lexikografisch, ein Datumsparser eruebrigt sich. Der
    # stuendliche Block beginnt um Mitternacht, nicht jetzt -- ohne diese
    # Suche zeigte die Vorschau die vergangene Nacht.
    hourly = data.get("hourly") or {}
    times = hourly.get("time") or []
    start = next((i for i, t in enumerate(times) if t > reference), len(times))
    for i in range(start, min(start + 3, len(times))):
        print("H|%s|%d|%d|%d" % (
            hour_label(times[i]),
            hourly["weather_code"][i],
            round(hourly["temperature_2m"][i]),
            round(hourly["precipitation_probability"][i] or 0),
        ))


if __name__ == "__main__":
    main()
