#!/usr/bin/env python3
"""Wetter fuer den aktuellen Standort, aufbereitet fuer sketchybar/items/weather.lua.

Ausgabe sind Zeilen, die sich in Lua ohne JSON-Parser auswerten lassen:

    W|<wmo-code>|<is_day>|<temp>|<gefuehlt>|<wind-kmh>|<regen-prozent>|<alter-sek>
    O|<ort>
    D|<max>|<min>|<sonnenaufgang>|<sonnenuntergang>
    H|<stunde>|<wmo-code>|<temp>|<regen-prozent>

Beides ohne API-Schluessel, weil dieses Repo oeffentlich ist: Open-Meteo fuer
das Wetter, ein IP-Dienst fuer den Standort. Der Nutzer wechselt als Berater
staendig den Ort, ein fest eingetragener Standort waere also nicht nur ein
Datenleck, sondern schlicht falsch.

Zwei Caches, beide ausserhalb des Repos unter $XDG_CACHE_HOME/sketchybar:

  weather-location.json   Standort, 1 Stunde
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
import time

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "sketchybar",
)
LOCATION_CACHE = os.path.join(CACHE_DIR, "weather-location.json")
WEATHER_CACHE = os.path.join(CACHE_DIR, "weather.json")

LOCATION_TTL = 3600
WEATHER_TTL = 600

# ipapi.co zuerst: ip-api.com liefert HTTPS nur gegen Schluessel, laeuft also
# unverschluesselt und taugt hoechstens als Rueckfallebene. Bei einem
# Standort pro Stunde bleiben beide weit unter ihren Freikontingenten
# (ipapi.co 1000/Tag, ip-api.com 45/Minute).
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
            "at": time.time()}


def resolve_location():
    """Standort per IP, mit Cache. Rueckgabe auch dann, wenn er alt ist."""
    pinned = pinned_location()
    if pinned:
        return pinned

    cached = load_cache(LOCATION_CACHE)
    if cached and time.time() - cached.get("at", 0) < LOCATION_TTL:
        return cached

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
        fresh = {"lat": round(lat, 2), "lon": round(lon, 2),
                 "city": (data.get("city") or "")[:18], "at": time.time()}
        save_cache(LOCATION_CACHE, fresh)
        return fresh

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
    location = resolve_location()
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

    city = location.get("city") or ""
    if city:
        print("O|%s" % city)

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
