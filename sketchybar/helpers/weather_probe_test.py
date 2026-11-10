"""Prüft die Abbildung der Witterung-Antwort auf die Zeilen der Bar.

    /usr/bin/python3 helpers/weather_probe_test.py
"""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import weather_probe as wx  # noqa: E402

TODAY = time.strftime("%Y-%m-%d")
HOUR = int(time.time()) // 3600 * 3600


def at(offset):
    """RFC-3339-Zeitpunkt `offset` Stunden nach Beginn der laufenden Stunde."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(HOUR + offset * 3600))


def hour(at, cond, temp, prob):
    return {"at": at, "consensus": {"temp_c": temp, "condition": cond,
                                    "precip_prob_pct": prob}}


class WitterungLines(unittest.TestCase):
    def sample(self, observed, shift=0):
        return {
            "now": {
                "observed": observed,
                "forecast": {"temp_c": 4.4, "feels_like_c": None, "wind_kmh": 10,
                             "condition": "rain", "precip_prob_pct": None,
                             "is_day": True},
            },
            "hourly": [
                dict(hour(at(shift), "rain", 4.4, None),
                     spread={"precip_agreement_pct": 67}),
                hour(at(shift + 1), "thunderstorm", 5.6, 40),
                hour(at(shift + 2), "wind", 5.0, None),
                hour(at(shift + 3), "unbekannt", 4.0, 10),
                hour(at(shift + 4), "clear", 3.0, 0),
            ],
            "daily": [{"date": TODAY, "consensus": {
                "temp_min_c": 1.2, "temp_max_c": 7.6,
                "sunrise": "2026-11-10T06:32:00Z", "sunset": "2026-11-10T15:30:00Z"}}],
        }

    def test_observed_beats_forecast(self):
        current, day, hours = wx.witterung_lines(self.sample(
            {"temp_c": 7.5, "wind_kmh": 20, "condition": "fog"}))
        # fog=45, Tag, gemessene 7.5 -> 8, gefühlt fehlt -> Temperatur,
        # Regen fehlt -> Übereinstimmung der Quellen.
        self.assertEqual(current, (45, 1, 8, 8, 20, 67))
        self.assertEqual(day[:2], (8, 1))
        # Die laufende Stunde fehlt in der Vorschau; Unbekanntes fällt auf bedeckt.
        self.assertEqual([h[1:] for h in hours],
                         [(95, 6, 40), (3, 5, 0), (3, 4, 10)])
        self.assertEqual(hours[0][0], time.strftime(
            "%H", time.localtime(HOUR + 3600)))

    def test_aged_cache_skips_past_hours(self):
        # Antwort von vor zwei Stunden: nur ihre Stunden 4 und 5 liegen noch vorn.
        _, _, hours = wx.witterung_lines(self.sample(None, shift=-2))
        self.assertEqual([h[1:] for h in hours], [(3, 4, 10), (0, 3, 0)])

    def test_forecast_without_station(self):
        current, _, _ = wx.witterung_lines(self.sample(None))
        self.assertEqual(current[:3], (63, 1, 4))

    def test_no_temperature_means_nothing(self):
        self.assertIsNone(wx.witterung_lines({"now": {}, "hourly": []}))


if __name__ == "__main__":
    unittest.main()
