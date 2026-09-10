# apager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Einen von aPager PRO auf dem Handy abgesetzten Webhook auf dem Mac entgegennehmen und den Einsatzalarm in einem Dialog anzeigen.

**Architecture:** Ein langlebiger Python-Listener unter launchd bindet ausschliesslich an die Tailscale-Adresse, prueft Quell-IP und Pfad-Token, protokolliert den Rohrequest und startet einen kurzlebigen `osascript`-Dialog. Ein Bash-Dispatcher `apager` installiert, prueft und testet das Ganze. Netzwerklogik und Darstellung sind getrennt: der Listener kennt keine Fenster, der Dialog kein Netzwerk.

**Tech Stack:** Bash (`set -euo pipefail`), `/usr/bin/python3` 3.9.6 mit reiner Standardbibliothek, `unittest` aus der stdlib, `osascript`, launchd.

**Spec:** `docs/2026-09-10-apager-design.md`

## Global Constraints

- **Python ist immer `/usr/bin/python3`**, nie `python3` aus dem PATH. Die mise-verwalteten Versionen liegen unter `~/.local/share/mise/` und verschwinden beim naechsten Versionswechsel — ein LaunchAgent stuende dann still.
- **Nur Standardbibliothek.** Keine pip-Installation, kein venv. Zielversion ist 3.9.6, also kein `match`, kein `X | Y` in Annotationen zur Laufzeit, kein `tomllib`.
- **Externe Kommandos absolut adressieren:** `/sbin/ifconfig`, `/usr/bin/osascript`, `/bin/launchctl`. launchd startet Agents mit einem minimalen PATH, der weder `/opt/homebrew/bin` noch `/usr/local/bin` kennt.
- **Skripte transliterieren Umlaute** (`Hoehe`, `grosszuegig`), wie in `sbar` und `backup`. Gemeint sind Umlaute und Eszett, nicht jedes Zeichen jenseits von ASCII: Geviertstriche stehen in `sbar` durchgehend und bleiben erlaubt. Dateien unter `docs/` und der im Dialog angezeigte Text tragen volle Umlaute.
- **Kommentare erklaeren das Warum, nicht das Was.** Vorbild ist der Kopf von `sbar`.
- **`.dotfiles` ist ein oeffentliches Repository.** Token, Tailnet-Namen und IP-Adressen gehoeren nach `~/.config/apager/config`, niemals in eine versionierte Datei. Auch nicht als Beispiel.
- **`apager-listener.py` bekommt Modus 644, nicht 755.** Der Dispatcher `r-tools` listet jede ausfuehrbare Datei im Verzeichnis als eigenes Werkzeug; der Listener ist keines.
- **Kein Ton, keine Benachrichtigung, kein Wecken.** Bewusste Abgrenzung aus der Spec. Wer einen Fallback ueber `terminal-notifier` oder `afplay` einbaut, fuehrt einen abgewaehlten Kanal durch die Hintertuer wieder ein.
- **Tailnet-Bereiche:** IPv4 `100.64.0.0/10`, IPv6 `fd7a:115c:a1e0::/48`.
- **LaunchAgent-Label:** `email.rubeen.apager`.
- **Pfade:** Config `~/.config/apager/config`, Zustand `~/.local/state/apager/` mit `alarms.log`, `listener.log`, `bound`.
- **Tests laufen mit** `/usr/bin/python3 -m unittest discover -s tests -v` aus dem Repository-Wurzelverzeichnis.

---

### Task 1: Reine Hilfsfunktionen des Listeners

Alles, was ohne Netzwerk, Fenster und Uhr auskommt: Adresserkennung, Tokenpruefung, Textaufbereitung. Diese Funktionen tragen die drei Pruefungen, die im Ernstfall still brechen koennen, deshalb bekommen sie als einzige echte Unit-Tests.

**Files:**
- Create: `apager-listener.py` (Modus 644)
- Create: `tests/test_apager_listener.py`

**Interfaces:**
- Consumes: nichts.
- Produces:
  - `TAILNET_V4: ipaddress.IPv4Network`, `TAILNET_V6: ipaddress.IPv6Network`
  - `Alarm` — `collections.namedtuple("Alarm", "received_at text")`, `received_at` ist ein `datetime`, `text` ein `str`
  - `is_tailnet_ip(addr: str) -> bool`
  - `parse_ifconfig_addresses(text: str) -> list` — alle IPv4-Adressen aus einer `ifconfig`-Ausgabe, in Reihenfolge des Auftretens
  - `tailnet_address(ifconfig_output=None) -> str or None` — erste Adresse daraus, die im Tailnet liegt; ohne Argument ruft sie `/sbin/ifconfig -a` selbst auf
  - `token_from_path(path: str) -> str or None` — aus `/alarm/<token>` das Token, sonst `None`
  - `token_matches(path: str, expected: str) -> bool` — zeitkonstanter Vergleich
  - `format_alarms(alarms: list) -> str` — juengster Alarm oben

- [ ] **Step 1: Die Testdatei anlegen**

`apager-listener.py` traegt einen Bindestrich im Namen und laesst sich deshalb nicht normal importieren. Der Loader-Umweg ist noetig; ein Umbenennen waere die schlechtere Loesung, weil die Datei dann aus der Namensfamilie des Werkzeugs fiele.

```python
# tests/test_apager_listener.py
"""Tests fuer die reinen Hilfsfunktionen von apager-listener.py."""

import importlib.util
import pathlib
import unittest
from datetime import datetime

# Der Bindestrich im Dateinamen verbietet den normalen Import.
_PATH = pathlib.Path(__file__).resolve().parent.parent / "apager-listener.py"
_SPEC = importlib.util.spec_from_file_location("apager_listener", _PATH)
listener = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(listener)


# Gekuerzte, aber echte ifconfig-Ausgabe: eine Loopback-, eine LAN- und eine
# Tailscale-Adresse. Die Reihenfolge ist Absicht — die LAN-Adresse steht vor
# der Tailscale-Adresse, damit ein Griff nach der "ersten" Adresse auffliegt.
IFCONFIG_SAMPLE = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.178.42 netmask 0xffffff00 broadcast 192.168.178.255
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
\tinet 100.101.102.103 --> 100.101.102.103 netmask 0xff000000
\tinet6 fd7a:115c:a1e0::1234 prefixlen 128
"""

IFCONFIG_NO_TAILSCALE = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.178.42 netmask 0xffffff00 broadcast 192.168.178.255
"""


class TestIsTailnetIp(unittest.TestCase):
    def test_tailscale_v4_is_accepted(self):
        self.assertTrue(listener.is_tailnet_ip("100.101.102.103"))

    def test_tailscale_v6_is_accepted(self):
        self.assertTrue(listener.is_tailnet_ip("fd7a:115c:a1e0::1234"))

    def test_lan_address_is_rejected(self):
        self.assertFalse(listener.is_tailnet_ip("192.168.178.42"))

    def test_loopback_is_rejected(self):
        self.assertFalse(listener.is_tailnet_ip("127.0.0.1"))

    def test_neighbouring_range_is_rejected(self):
        # 100.128.0.0 liegt knapp ausserhalb von 100.64.0.0/10.
        self.assertFalse(listener.is_tailnet_ip("100.128.0.1"))

    def test_garbage_is_rejected_without_raising(self):
        self.assertFalse(listener.is_tailnet_ip("nicht-eine-adresse"))
        self.assertFalse(listener.is_tailnet_ip(""))


class TestTailnetAddress(unittest.TestCase):
    def test_picks_the_tailscale_address_not_the_first_one(self):
        self.assertEqual(
            listener.tailnet_address(IFCONFIG_SAMPLE), "100.101.102.103"
        )

    def test_returns_none_when_tailscale_is_down(self):
        self.assertIsNone(listener.tailnet_address(IFCONFIG_NO_TAILSCALE))

    def test_parses_all_v4_addresses_in_order(self):
        self.assertEqual(
            listener.parse_ifconfig_addresses(IFCONFIG_SAMPLE),
            ["127.0.0.1", "192.168.178.42", "100.101.102.103"],
        )


class TestToken(unittest.TestCase):
    def test_extracts_token_from_alarm_path(self):
        self.assertEqual(listener.token_from_path("/alarm/geheim"), "geheim")

    def test_ignores_query_string(self):
        self.assertEqual(
            listener.token_from_path("/alarm/geheim?stichwort=B2"), "geheim"
        )

    def test_other_paths_yield_none(self):
        self.assertIsNone(listener.token_from_path("/"))
        self.assertIsNone(listener.token_from_path("/alarm"))
        self.assertIsNone(listener.token_from_path("/etwas/geheim"))

    def test_matching_token_is_accepted(self):
        self.assertTrue(listener.token_matches("/alarm/geheim", "geheim"))

    def test_wrong_token_is_rejected(self):
        self.assertFalse(listener.token_matches("/alarm/falsch", "geheim"))

    def test_missing_token_is_rejected(self):
        self.assertFalse(listener.token_matches("/", "geheim"))

    def test_empty_expected_token_never_matches(self):
        # Eine leere Konfiguration darf nicht in einen offenen Endpunkt kippen.
        self.assertFalse(listener.token_matches("/alarm/", ""))


class TestFormatAlarms(unittest.TestCase):
    def test_single_alarm_carries_time_and_text(self):
        alarms = [listener.Alarm(datetime(2026, 9, 10, 14, 3, 9), "B2 Wohnungsbrand")]
        text = listener.format_alarms(alarms)
        self.assertIn("14:03:09", text)
        self.assertIn("B2 Wohnungsbrand", text)

    def test_newest_alarm_comes_first(self):
        alarms = [
            listener.Alarm(datetime(2026, 9, 10, 14, 0, 0), "ERSTER"),
            listener.Alarm(datetime(2026, 9, 10, 14, 5, 0), "ZWEITER"),
        ]
        text = listener.format_alarms(alarms)
        self.assertLess(text.index("ZWEITER"), text.index("ERSTER"))

    def test_empty_list_yields_empty_string(self):
        self.assertEqual(listener.format_alarms([]), "")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Tests laufen lassen und scheitern sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: FAIL — `FileNotFoundError` beziehungsweise `AttributeError`, weil `apager-listener.py` noch nicht existiert.

- [ ] **Step 3: Die Hilfsfunktionen schreiben**

```python
#!/usr/bin/env python3
# apager-listener - nimmt aPager-Webhooks aus dem Tailnet entgegen und zeigt sie an
"""Listener fuer aPager-Alarme.

Laeuft unter launchd. Der Mac ist hier Anzeige und keine Alarmierung: kein Ton,
keine Benachrichtigung, kein Wecken. Wer schlaeft, verpasst den Alarm — das ist
Absicht, alarmiert wird ueber das Handy.

Siehe docs/2026-09-10-apager-design.md.
"""

import hmac
import ipaddress
import re
import subprocess
from collections import namedtuple

# Tailscale vergibt aus dem CGNAT-Bereich; die IPv6-Adressen stammen aus dem
# festen ULA-Praefix des Dienstes.
TAILNET_V4 = ipaddress.ip_network("100.64.0.0/10")
TAILNET_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")

# Absolut, weil launchd einen minimalen PATH setzt.
IFCONFIG = "/sbin/ifconfig"

Alarm = namedtuple("Alarm", "received_at text")

_INET_RE = re.compile(r"^\s*inet (\d+\.\d+\.\d+\.\d+)", re.MULTILINE)


def is_tailnet_ip(addr):
    """Liegt die Adresse im Tailnet? Muell ergibt False statt einer Ausnahme."""
    try:
        parsed = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if parsed.version == 4:
        return parsed in TAILNET_V4
    return parsed in TAILNET_V6


def parse_ifconfig_addresses(text):
    """Alle IPv4-Adressen einer ifconfig-Ausgabe, in Reihenfolge des Auftretens."""
    return _INET_RE.findall(text)


def tailnet_address(ifconfig_output=None):
    """Die eigene Tailscale-Adresse, oder None wenn Tailscale gerade nicht laeuft.

    Bewusst ueber ifconfig statt ueber das tailscale-CLI: der App-Store-Build
    blockiert dessen Aufrufe gelegentlich minutenlang, und ein blockierender
    Aufruf in der Bind-Schleife waere von "kein Tailscale" nicht zu unterscheiden.
    """
    if ifconfig_output is None:
        try:
            ifconfig_output = subprocess.run(
                [IFCONFIG, "-a"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            return None
    for addr in parse_ifconfig_addresses(ifconfig_output):
        if is_tailnet_ip(addr):
            return addr
    return None


def token_from_path(path):
    """Das Token aus /alarm/<token>, sonst None.

    aPager laesst keine eigenen Header zu, deshalb steht das Geheimnis im Pfad.
    """
    path = path.split("?", 1)[0]
    prefix = "/alarm/"
    if not path.startswith(prefix):
        return None
    token = path[len(prefix):]
    return token or None


def token_matches(path, expected):
    """Zeitkonstanter Vergleich. Ein leeres erwartetes Token passt auf nichts."""
    if not expected:
        return False
    got = token_from_path(path)
    if got is None:
        return False
    return hmac.compare_digest(got, expected)


def format_alarms(alarms):
    """Der Text fuer den Dialog: juengster Alarm oben, durch Linien getrennt."""
    blocks = []
    for alarm in reversed(alarms):
        stamp = alarm.received_at.strftime("%H:%M:%S")
        blocks.append("{}\n{}".format(stamp, alarm.text.strip()))
    return "\n\n--------------------\n\n".join(blocks)
```

- [ ] **Step 4: Tests laufen lassen und gruen sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: PASS, 19 Tests.

- [ ] **Step 5: Modus pruefen und committen**

Der Modus ist kein Detail: bei 755 taucht der Listener in `r-tools -l` als eigenes Werkzeug auf.

```bash
chmod 644 apager-listener.py
ls -l apager-listener.py
git add apager-listener.py tests/test_apager_listener.py
git commit -m "apager: Adresserkennung, Tokenpruefung und Textaufbereitung"
```

---

### Task 2: Alarmspeicher und Dialoganzeige

Die Liste offener Alarme und der Dialog, der sie zeigt. Der knifflige Teil ist der Zweitalarm: der laufende Dialog wird beendet und durch einen neuen mit allen offenen Alarmen ersetzt. Ohne Generationszaehler wuerde der Watcher-Thread des beendeten Dialogs die Liste leeren, die der neue gerade anzeigt.

**Files:**
- Modify: `apager-listener.py` — anfuegen
- Modify: `tests/test_apager_listener.py` — anfuegen

**Interfaces:**
- Consumes: `Alarm`, `format_alarms` aus Task 1.
- Produces:
  - `DIALOG_SCRIPT: str` — das AppleScript
  - `spawn_dialog(text: str) -> subprocess.Popen`
  - `class AlarmDisplay` mit `__init__(self, spawn=spawn_dialog, on_error=None)`, `add(self, alarm) -> None`, `pending(self) -> list` (Kopie der offenen Alarme, aeltester zuerst)

- [ ] **Step 1: Die Tests schreiben**

Der Dialog wird nie wirklich gestartet: `spawn` ist eine Attrappe. Damit laeuft der Test ohne Fenster und ohne Wartezeit.

```python
# an tests/test_apager_listener.py anfuegen

import threading


class FakeProc:
    """Ein Dialogprozess, den der Test von Hand beenden kann."""

    def __init__(self, text):
        self.text = text
        self.terminated = False
        self._done = threading.Event()

    def wait(self):
        self._done.wait(timeout=5)
        return 0

    def terminate(self):
        self.terminated = True
        self._done.set()

    def finish(self):
        """Der Benutzer hat quittiert."""
        self._done.set()


class TestAlarmDisplay(unittest.TestCase):
    def setUp(self):
        self.spawned = []

        def fake_spawn(text):
            proc = FakeProc(text)
            self.spawned.append(proc)
            return proc

        self.display = listener.AlarmDisplay(spawn=fake_spawn)

    def _alarm(self, minute, text):
        return listener.Alarm(datetime(2026, 9, 10, 14, minute, 0), text)

    def test_first_alarm_opens_one_dialog(self):
        self.display.add(self._alarm(0, "ERSTER"))
        self.assertEqual(len(self.spawned), 1)
        self.assertIn("ERSTER", self.spawned[0].text)

    def test_second_alarm_replaces_the_dialog_and_shows_both(self):
        self.display.add(self._alarm(0, "ERSTER"))
        self.display.add(self._alarm(5, "ZWEITER"))

        self.assertEqual(len(self.spawned), 2)
        self.assertTrue(self.spawned[0].terminated)
        self.assertIn("ERSTER", self.spawned[1].text)
        self.assertIn("ZWEITER", self.spawned[1].text)
        self.assertEqual(len(self.display.pending()), 2)

    def test_acknowledging_clears_the_list(self):
        self.display.add(self._alarm(0, "ERSTER"))
        self.spawned[0].finish()

        deadline = time.time() + 5
        while self.display.pending() and time.time() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.display.pending(), [])

    def test_replaced_dialog_does_not_clear_the_new_list(self):
        # Der Kern der Sache: der Watcher des ersten Dialogs endet, weil wir
        # ihn ersetzt haben — nicht, weil jemand quittiert hat. Er darf die
        # Liste des zweiten Dialogs nicht anruehren.
        self.display.add(self._alarm(0, "ERSTER"))
        self.display.add(self._alarm(5, "ZWEITER"))

        time.sleep(0.2)
        self.assertEqual(len(self.display.pending()), 2)

    def test_a_failing_spawn_keeps_the_alarm_in_the_list(self):
        def broken_spawn(text):
            raise OSError("osascript fehlt")

        errors = []
        display = listener.AlarmDisplay(spawn=broken_spawn, on_error=errors.append)
        display.add(self._alarm(0, "ERSTER"))

        self.assertEqual(len(errors), 1)
        self.assertEqual(len(display.pending()), 1)
```

Ergaenze oben in der Datei den Import: `import time`.

- [ ] **Step 2: Tests laufen lassen und scheitern sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: FAIL — `AttributeError: module 'apager_listener' has no attribute 'AlarmDisplay'`.

- [ ] **Step 3: AlarmDisplay schreiben**

```python
# an apager-listener.py anfuegen; oben ergaenzen:
#   import threading

OSASCRIPT = "/usr/bin/osascript"

# Der Text kommt als Argument, nicht in den Skripttext hineingeschrieben:
# Einsatzdaten enthalten Anfuehrungszeichen und Zeilenumbrueche, und jedes
# Escaping waere eine Fehlerquelle an genau der Stelle, an der es zaehlt.
# "System Events" holt den Dialog nach vorn; osascript allein oeffnet ihn
# hinter dem, was gerade offen ist.
DIALOG_SCRIPT = """on run argv
\ttell application "System Events"
\t\tactivate
\t\tdisplay dialog (item 1 of argv) with title "Einsatzalarm" buttons {"Quittieren"} default button 1 with icon caution
\tend tell
end run"""


def spawn_dialog(text):
    """Startet den Dialog und kehrt sofort zurueck."""
    return subprocess.Popen(
        [OSASCRIPT, "-e", DIALOG_SCRIPT, text],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class AlarmDisplay:
    """Haelt die offenen Alarme und genau einen Dialog, der sie alle zeigt.

    Trifft ein zweiter Alarm ein, waehrend der erste noch offen ist, wird der
    laufende Dialog beendet und durch einen neuen mit beiden Alarmen ersetzt.
    Jeder Start bekommt dafuer eine Generationsnummer: der Watcher-Thread eines
    ersetzten Dialogs sieht beim Aufwachen, dass seine Generation veraltet ist,
    und laesst die Liste in Ruhe. Ohne das wuerde er die Alarme wegraeumen, die
    der neue Dialog gerade anzeigt.
    """

    def __init__(self, spawn=spawn_dialog, on_error=None):
        self._spawn = spawn
        self._on_error = on_error or (lambda exc: None)
        self._lock = threading.Lock()
        self._alarms = []
        self._proc = None
        self._generation = 0

    def pending(self):
        with self._lock:
            return list(self._alarms)

    def add(self, alarm):
        with self._lock:
            self._alarms.append(alarm)
            self._restart_dialog()

    def _restart_dialog(self):
        """Nur mit gehaltenem Lock aufrufen."""
        if self._proc is not None:
            try:
                self._proc.terminate()
            except OSError:
                pass
            self._proc = None

        self._generation += 1
        generation = self._generation
        text = format_alarms(self._alarms)

        try:
            proc = self._spawn(text)
        except Exception as exc:  # osascript fehlt, TCC verweigert, ...
            # Der Alarm bleibt in der Liste und steht ohnehin im alarms.log.
            # Kein Ausweichen auf Ton oder Benachrichtigung: beide Kanaele sind
            # bewusst abgewaehlt, siehe Spec.
            self._proc = None
            self._on_error(exc)
            return

        self._proc = proc
        watcher = threading.Thread(
            target=self._wait_for_acknowledgement,
            args=(proc, generation),
            daemon=True,
        )
        watcher.start()

    def _wait_for_acknowledgement(self, proc, generation):
        try:
            proc.wait()
        except Exception:
            return
        with self._lock:
            if generation != self._generation:
                return  # ersetzt, nicht quittiert
            self._alarms = []
            self._proc = None
```

- [ ] **Step 4: Tests laufen lassen und gruen sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: PASS, 24 Tests.

- [ ] **Step 5: Den Dialog einmal von Hand ansehen**

Die Attrappe beweist die Logik, nicht das Aussehen. Ein Blick auf das echte Fenster gehoert dazu — und der erste Aufruf loest womoeglich eine Nachfrage nach der Automatisierungsberechtigung fuer "System Events" aus, die bestaetigt werden muss.

```bash
/usr/bin/python3 -c '
import importlib.util, pathlib, datetime, time
p = pathlib.Path("apager-listener.py").resolve()
s = importlib.util.spec_from_file_location("l", p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
d = m.AlarmDisplay()
d.add(m.Alarm(datetime.datetime.now(), "B2 Wohnungsbrand\nMusterstrasse 12\nAlarmiert: FF Musterstadt"))
time.sleep(3)
d.add(m.Alarm(datetime.datetime.now(), "H1 Tuer oeffnen\nBahnhofsplatz 3"))
time.sleep(30)
'
```

Expected: Nach drei Sekunden ersetzt ein Dialog mit beiden Alarmen den ersten, juengster oben. Ein Klick auf "Quittieren" schliesst ihn.

- [ ] **Step 6: Commit**

```bash
git add apager-listener.py tests/test_apager_listener.py
git commit -m "apager: Alarmspeicher und Dialog, Zweitalarm ersetzt das Fenster"
```

---

### Task 3: HTTP-Handler und Protokollierung

Der Handler prueft Quell-IP und Token, schreibt den Rohrequest ins Protokoll und uebergibt an die Anzeige. Wichtig ist die Reihenfolge: erst protokollieren, dann anzeigen. Ein Fehler in der Darstellung darf keinen Einsatz verschlucken.

**Files:**
- Modify: `apager-listener.py` — anfuegen
- Modify: `tests/test_apager_listener.py` — anfuegen

**Interfaces:**
- Consumes: `is_tailnet_ip`, `token_matches`, `Alarm`, `AlarmDisplay` aus Task 1 und 2.
- Produces:
  - `MAX_BODY_BYTES: int` = `64 * 1024`
  - `make_handler(token, display, alarm_log, allow_source=is_tailnet_ip, on_event=None)` — liefert eine `BaseHTTPRequestHandler`-Unterklasse. `alarm_log` ist ein `pathlib.Path`, `on_event` bekommt Betriebsmeldungen als `str`.
  - `readable_request(method, path, headers_text, body_bytes) -> str` — der Text fuer den Dialog
  - `raw_request_record(method, path, headers_text, body_bytes, received_at) -> str` — der Eintrag fuer `alarms.log`

- [ ] **Step 1: Die Tests schreiben**

```python
# an tests/test_apager_listener.py anfuegen

import http.client
import tempfile
from http.server import ThreadingHTTPServer


class TestHandler(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.alarm_log = pathlib.Path(self.tmp.name) / "alarms.log"
        self.shown = []

        class RecordingDisplay:
            def __init__(inner):
                inner.alarms = []

            def add(inner, alarm):
                inner.alarms.append(alarm)
                self.shown.append(alarm)

        self.display = RecordingDisplay()
        self.events = []

        # allow_source ist im Test immer wahr: der Testserver haengt an
        # 127.0.0.1, und die echte Herkunftspruefung hat eigene Tests.
        handler = listener.make_handler(
            token="geheim",
            display=self.display,
            alarm_log=self.alarm_log,
            allow_source=lambda ip: True,
            on_event=self.events.append,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.addCleanup(self.server.server_close)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_address[1]

    def _request(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body)
        response = conn.getresponse()
        response.read()
        conn.close()
        return response.status

    def test_post_with_correct_token_is_accepted(self):
        status = self._request("POST", "/alarm/geheim", body="B2 Wohnungsbrand")
        self.assertEqual(status, 200)
        self.assertEqual(len(self.shown), 1)
        self.assertIn("B2 Wohnungsbrand", self.shown[0].text)

    def test_get_with_correct_token_is_accepted(self):
        # Ob aPager GET oder POST schickt, ist unbekannt — beides muss gehen.
        status = self._request("GET", "/alarm/geheim?stichwort=B2")
        self.assertEqual(status, 200)
        self.assertEqual(len(self.shown), 1)
        self.assertIn("stichwort=B2", self.shown[0].text)

    def test_wrong_token_is_rejected_and_shows_nothing(self):
        status = self._request("POST", "/alarm/falsch", body="egal")
        self.assertEqual(status, 404)
        self.assertEqual(self.shown, [])

    def test_other_paths_are_rejected(self):
        self.assertEqual(self._request("GET", "/"), 404)
        self.assertEqual(self.shown, [])

    def test_alarm_is_logged_before_it_is_shown(self):
        self._request("POST", "/alarm/geheim", body="B2 Wohnungsbrand")
        written = self.alarm_log.read_text(encoding="utf-8")
        self.assertIn("B2 Wohnungsbrand", written)
        self.assertIn("POST /alarm/geheim", written)

    def test_rejected_request_is_noted_as_an_event(self):
        self._request("POST", "/alarm/falsch", body="egal")
        self.assertTrue(any("abgewiesen" in e for e in self.events))

    def test_a_failing_display_still_logs_the_alarm(self):
        class BrokenDisplay:
            def add(inner, alarm):
                raise RuntimeError("kaputt")

        handler = listener.make_handler(
            token="geheim",
            display=BrokenDisplay(),
            alarm_log=self.alarm_log,
            allow_source=lambda ip: True,
            on_event=self.events.append,
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)

        conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
        conn.request("POST", "/alarm/geheim", body="B2 Wohnungsbrand")
        response = conn.getresponse()
        response.read()
        conn.close()

        self.assertIn("B2 Wohnungsbrand", self.alarm_log.read_text(encoding="utf-8"))

    def test_undecodable_body_does_not_crash(self):
        status = self._request("POST", "/alarm/geheim", body=b"\xff\xfe kaputt")
        self.assertEqual(status, 200)
        self.assertEqual(len(self.shown), 1)


class TestSourceCheck(unittest.TestCase):
    def test_handler_rejects_sources_outside_the_tailnet(self):
        # Der Vorgabewert von allow_source ist is_tailnet_ip; ein Testserver
        # auf 127.0.0.1 muss damit abgewiesen werden.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        events = []
        handler = listener.make_handler(
            token="geheim",
            display=None,
            alarm_log=pathlib.Path(tmp.name) / "alarms.log",
            on_event=events.append,
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)

        conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
        conn.request("POST", "/alarm/geheim", body="egal")
        response = conn.getresponse()
        response.read()
        conn.close()
        self.assertEqual(response.status, 404)
```

- [ ] **Step 2: Tests laufen lassen und scheitern sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: FAIL — `AttributeError: module 'apager_listener' has no attribute 'make_handler'`.

- [ ] **Step 3: Handler schreiben**

```python
# an apager-listener.py anfuegen; oben ergaenzen:
#   from datetime import datetime
#   from http.server import BaseHTTPRequestHandler

MAX_BODY_BYTES = 64 * 1024


def readable_request(method, path, headers_text, body_bytes):
    """Was im Dialog steht, solange das Feldmapping noch nicht existiert.

    Das Payload-Format von aPager ist nicht konfigurierbar und derzeit
    unbekannt. Bis der erste echte Alarm im Protokoll steht, zeigen wir alles
    Lesbare — lieber zu viel als das falsche Feld.

    method und headers_text werden noch nicht ausgewertet, stehen aber bewusst
    schon in der Signatur: sobald das Feldmapping kommt, entscheidet der
    Content-Type darueber, ob der Body als JSON, als Formulardaten oder als
    Klartext zu lesen ist.
    """
    body = body_bytes.decode("utf-8", errors="replace").strip()
    parts = []
    if body:
        parts.append(body)
    query = path.split("?", 1)[1] if "?" in path else ""
    if query:
        parts.append(query)
    if not parts:
        parts.append("(kein Inhalt)")
    return "\n".join(parts)


def raw_request_record(method, path, headers_text, body_bytes, received_at):
    """Der vollstaendige Eintrag fuer alarms.log."""
    body = body_bytes.decode("utf-8", errors="replace")
    return (
        "===== {} =====\n{} {}\n{}\n{}\n".format(
            received_at.isoformat(timespec="seconds"),
            method,
            path,
            headers_text.rstrip(),
            body,
        )
    )


def make_handler(token, display, alarm_log, allow_source=is_tailnet_ip, on_event=None):
    """Baut die Handler-Klasse. Alles Veraenderliche kommt ueber Closures herein,
    damit der Handler ohne globalen Zustand testbar bleibt."""
    notify = on_event or (lambda message: None)

    class AlarmHandler(BaseHTTPRequestHandler):
        server_version = "apager"
        sys_version = ""

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

        def log_message(self, fmt, *args):
            # Der eingebaute Zugriffslog schreibt nach stderr und damit in die
            # listener.log; wir protokollieren selbst, was zaehlt.
            pass

        def _reject(self, reason):
            notify("abgewiesen: {} ({} {})".format(reason, self.command, self.path))
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _handle(self, method):
            source = self.client_address[0]
            if not allow_source(source):
                self._reject("Quelle ausserhalb des Tailnets")
                return
            if not token_matches(self.path, token):
                self._reject("Token stimmt nicht")
                return

            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(min(length, MAX_BODY_BYTES)) if length else b""

            received_at = datetime.now()
            headers_text = str(self.headers)

            # Erst protokollieren, dann anzeigen: ein Fehler in der Darstellung
            # darf keinen Einsatz verschlucken.
            try:
                alarm_log.parent.mkdir(parents=True, exist_ok=True)
                with alarm_log.open("a", encoding="utf-8") as handle:
                    handle.write(
                        raw_request_record(method, self.path, headers_text, body, received_at)
                    )
            except OSError as exc:
                notify("alarms.log nicht schreibbar: {}".format(exc))

            self.send_response(200)
            self.send_header("Content-Length", "3")
            self.end_headers()
            self.wfile.write(b"ok\n")

            try:
                display.add(Alarm(received_at, readable_request(method, self.path, headers_text, body)))
            except Exception as exc:
                notify("Anzeige fehlgeschlagen: {}".format(exc))

    return AlarmHandler
```

- [ ] **Step 4: Tests laufen lassen und gruen sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: PASS, 33 Tests.

- [ ] **Step 5: Commit**

```bash
git add apager-listener.py tests/test_apager_listener.py
git commit -m "apager: HTTP-Handler mit Herkunftspruefung, Protokoll vor Anzeige"
```

---

### Task 4: Bind-Schleife, Konfiguration und Einstiegspunkt

Der Listener bindet nur an die Tailscale-Adresse. Fehlt sie, wartet er — er weicht nie auf ein anderes Interface aus, sonst stuende der Endpunkt im fremden WLAN offen. Die tatsaechlich gebundene Adresse landet in `~/.local/state/apager/bound`; daraus liest der Dispatcher spaeter seinen Status.

**Files:**
- Modify: `apager-listener.py` — anfuegen
- Modify: `tests/test_apager_listener.py` — anfuegen

**Interfaces:**
- Consumes: alles Bisherige.
- Produces:
  - `STATE_DIR`, `CONFIG_PATH`, `ALARM_LOG`, `BOUND_FILE` als `pathlib.Path`
  - `read_config(path) -> dict` — liest `KEY="wert"`-Zeilen, ignoriert Kommentare und Leerzeilen
  - `serve(address, port, token, display, alarm_log, bound_file, on_event, should_continue) -> None` — bindet, bedient, schreibt `bound_file`, kehrt zurueck sobald `should_continue()` falsch wird oder die Adresse verschwindet
  - `main() -> int`

- [ ] **Step 1: Die Tests fuer die Konfiguration schreiben**

Die Bind-Schleife selbst wird nicht automatisiert getestet — sie braucht eine echte Tailscale-Adresse. Was sich testen laesst, ist das Einlesen der Konfiguration, und dort steckt der Fall, der am teuersten waere: ein fehlendes Token, das stillschweigend zu einem offenen Endpunkt fuehrt.

```python
# an tests/test_apager_listener.py anfuegen

class TestReadConfig(unittest.TestCase):
    def _write(self, text):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = pathlib.Path(tmp.name) / "config"
        path.write_text(text, encoding="utf-8")
        return path

    def test_reads_quoted_values(self):
        path = self._write('APAGER_PORT="8787"\nAPAGER_TOKEN="geheim"\n')
        config = listener.read_config(path)
        self.assertEqual(config["APAGER_PORT"], "8787")
        self.assertEqual(config["APAGER_TOKEN"], "geheim")

    def test_ignores_comments_and_blank_lines(self):
        path = self._write('# ein Kommentar\n\nAPAGER_TOKEN="geheim"\n')
        self.assertEqual(listener.read_config(path), {"APAGER_TOKEN": "geheim"})

    def test_reads_unquoted_values(self):
        path = self._write("APAGER_PORT=8787\n")
        self.assertEqual(listener.read_config(path)["APAGER_PORT"], "8787")

    def test_missing_file_yields_empty_dict(self):
        self.assertEqual(listener.read_config(pathlib.Path("/nicht/vorhanden")), {})
```

- [ ] **Step 2: Tests laufen lassen und scheitern sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: FAIL — `AttributeError: module 'apager_listener' has no attribute 'read_config'`.

- [ ] **Step 3: Konfiguration, Bind-Schleife und main schreiben**

```python
# an apager-listener.py anfuegen; oben ergaenzen:
#   import logging, pathlib, sys, time
#   from http.server import ThreadingHTTPServer

CONFIG_PATH = pathlib.Path.home() / ".config" / "apager" / "config"
STATE_DIR = pathlib.Path.home() / ".local" / "state" / "apager"
ALARM_LOG = STATE_DIR / "alarms.log"
BOUND_FILE = STATE_DIR / "bound"

DEFAULT_PORT = 8787

# Wie lange zwischen zwei Versuchen gewartet wird, wenn Tailscale nicht laeuft
# oder der Port belegt ist. Kurz genug, dass ein Wiederanlauf nicht auffaellt.
RETRY_SECONDS = 5

# Wie oft die gebundene Adresse geprueft wird. Ein Wechsel ist selten; haeufiger
# nachzusehen kostet nur Strom.
ADDRESS_CHECK_SECONDS = 15

_CONFIG_RE = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"?([^"]*)"?\s*$')


def read_config(path):
    """Liest KEY="wert"-Zeilen. Fehlt die Datei, ist die Konfiguration leer."""
    config = {}
    try:
        text = pathlib.Path(path).read_text(encoding="utf-8")
    except OSError:
        return config
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = _CONFIG_RE.match(line)
        if match:
            config[match.group(1)] = match.group(2)
    return config


def serve(address, port, token, display, alarm_log, bound_file, on_event, should_continue):
    """Bedient Requests auf genau einer Adresse, bis sie verschwindet.

    Kehrt zurueck, wenn die Adresse wegfaellt oder sich aendert; die aufrufende
    Schleife sucht dann eine neue. Ein Ausweichen auf 0.0.0.0 findet nie statt.
    """
    handler = make_handler(token, display, alarm_log, on_event=on_event)
    try:
        httpd = ThreadingHTTPServer((address, port), handler)
    except OSError as exc:
        on_event("Bind auf {}:{} fehlgeschlagen: {}".format(address, port, exc))
        return

    on_event("gebunden an {}:{}".format(address, port))
    try:
        bound_file.parent.mkdir(parents=True, exist_ok=True)
        bound_file.write_text("{}:{}\n".format(address, port), encoding="utf-8")
    except OSError as exc:
        on_event("bound-Datei nicht schreibbar: {}".format(exc))

    worker = threading.Thread(target=httpd.serve_forever, daemon=True)
    worker.start()
    try:
        while should_continue():
            time.sleep(ADDRESS_CHECK_SECONDS)
            if tailnet_address() != address:
                on_event("Tailscale-Adresse hat sich geaendert oder ist weg")
                return
    finally:
        httpd.shutdown()
        httpd.server_close()
        try:
            bound_file.unlink()
        except OSError:
            pass


def main():
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    config = read_config(CONFIG_PATH)
    token = config.get("APAGER_TOKEN", "")
    if not token:
        logging.error("kein APAGER_TOKEN in %s — es wird nichts angenommen", CONFIG_PATH)
        return 1
    try:
        port = int(config.get("APAGER_PORT", DEFAULT_PORT))
    except ValueError:
        logging.error("APAGER_PORT ist keine Zahl")
        return 1

    display = AlarmDisplay(on_error=lambda exc: logging.error("Anzeige: %s", exc))

    # Nur bei Zustandswechsel protokollieren. Alle fuenf Sekunden "kein
    # Tailscale" zu schreiben, macht die Datei gross und die Meldung wertlos.
    last_state = None
    while True:
        address = tailnet_address()
        if address is None:
            if last_state != "down":
                logging.info("keine Tailscale-Adresse — warte")
                last_state = "down"
            time.sleep(RETRY_SECONDS)
            continue
        last_state = "up"
        serve(
            address=address,
            port=port,
            token=token,
            display=display,
            alarm_log=ALARM_LOG,
            bound_file=BOUND_FILE,
            on_event=logging.info,
            should_continue=lambda: True,
        )
        time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Tests laufen lassen und gruen sehen**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: PASS, 37 Tests.

- [ ] **Step 5: Den Listener von Hand starten**

```bash
mkdir -p ~/.config/apager
printf 'APAGER_PORT="8787"\nAPAGER_TOKEN="testtoken"\n' > ~/.config/apager/config
chmod 600 ~/.config/apager/config
/usr/bin/python3 apager-listener.py
```

Expected: Laeuft Tailscale nicht, erscheint genau einmal `keine Tailscale-Adresse — warte` und der Prozess bleibt am Leben. Laeuft Tailscale, erscheint `gebunden an 100.x.x.x:8787` und `~/.local/state/apager/bound` enthaelt diese Adresse. Mit Strg-C beenden.

- [ ] **Step 6: Commit**

```bash
git add apager-listener.py tests/test_apager_listener.py
git commit -m "apager: bindet nur an die Tailscale-Adresse, wartet sonst"
```

---

### Task 5: Der Dispatcher `apager`

Das Werkzeug, das der Benutzer anfasst: installieren, Status ansehen, testen, Protokoll lesen, die URL fuer aPager ausgeben. Dazu die Config-Vorlage und der Eintrag in `CLAUDE.md`.

**Files:**
- Create: `apager` (Modus 755)
- Create: `docs/apager.conf.example`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `apager-listener.py`; die Datei `~/.local/state/apager/bound` im Format `<adresse>:<port>`; die Konfigurationsschluessel `APAGER_PORT` und `APAGER_TOKEN`.
- Produces: `~/Library/LaunchAgents/email.rubeen.apager.plist`.

- [ ] **Step 1: Die Config-Vorlage schreiben**

```bash
cat > docs/apager.conf.example <<'EOF'
# apager.conf - Endpunkt fuer die aPager-Alarme.
#
# Wird von `apager install` angelegt; diese Datei ist nur die Vorlage.
# Ziel: ~/.config/apager/config, Modus 0600.
#
# Die echte Datei gehoert bewusst NICHT in dieses Repository: es ist
# oeffentlich, und ein Token, mit dem sich Alarme einspeisen lassen, hat darin
# nichts zu suchen.

# Port, auf dem der Listener horcht. Nur auf der Tailscale-Adresse erreichbar.
APAGER_PORT="8787"

# Zufaelliges Geheimnis im URL-Pfad: /alarm/<token>. aPager laesst keine
# eigenen Header zu, deshalb steht es im Pfad und nicht in einem Header.
# `apager install` erzeugt es; von Hand ginge es so:
#   openssl rand -hex 16
APAGER_TOKEN="hier-ein-zufallswert"
EOF
```

- [ ] **Step 2: Den Dispatcher schreiben**

```bash
#!/usr/bin/env bash
# apager - aPager-Alarme aus dem Tailnet auf dem Mac anzeigen
set -euo pipefail

# Warum es dieses Skript gibt: aPager PRO setzt den Webhook vom Handy ab, nicht
# von einem Server. Der Mac braucht deshalb keine oeffentliche Erreichbarkeit —
# ein Listener, der ausschliesslich an die Tailscale-Adresse bindet, genuegt.
#
# Der Mac ist Anzeige, nicht Alarmierung: kein Ton, keine Benachrichtigung,
# kein Wecken. Schlaeft er, verpasst er den Alarm. Alarmiert wird ueber das
# Handy. Siehe docs/2026-09-10-apager-design.md.

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
LISTENER="$TOOLS_DIR/apager-listener.py"

LABEL="email.rubeen.apager"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="gui/$(id -u)/$LABEL"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/apager"
CONFIG="$CONFIG_DIR/config"
STATE_DIR="$HOME/.local/state/apager"
ALARM_LOG="$STATE_DIR/alarms.log"
LISTENER_LOG="$STATE_DIR/listener.log"
BOUND="$STATE_DIR/bound"

# Absolut, weil launchd einen minimalen PATH setzt und dieses Skript die plist
# schreibt, die davon abhaengt.
PYTHON="/usr/bin/python3"

usage() {
  cat <<'EOF'
apager - aPager-Alarme aus dem Tailnet auf dem Mac anzeigen

  apager install      Config und LaunchAgent anlegen, Listener starten
  apager uninstall    LaunchAgent entfernen (Config und Protokolle bleiben)
  apager status       Laeuft der Agent, woran haengt er, wann kam der letzte Alarm
  apager url          Die URL, die in aPager einzutragen ist
  apager test         Einen Testalarm ueber das Tailnet schicken
  apager logs         Die letzten Alarme anzeigen
  apager logs -f      Dem Protokoll folgen
  apager -h | --help  Diese Hilfe

Der Mac ist Anzeige, nicht Alarmierung: kein Ton, keine Benachrichtigung, kein
Wecken. Schlaeft der Rechner, verpasst er den Alarm — alarmiert wird ueber das
Handy.
EOF
}

die() { printf 'apager: %s\n' "$1" >&2; exit 1; }

config_value() {
  [[ -f "$CONFIG" ]] || return 1
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$CONFIG" | head -1
}

# Die tatsaechlich gebundene Adresse, nicht die konfigurierte. Genau darin liegt
# der Unterschied zwischen "sollte laufen" und "laeuft".
bound_address() { [[ -f "$BOUND" ]] && cat "$BOUND" || true; }

do_install() {
  [[ -f "$LISTENER" ]] || die "apager-listener.py fehlt neben $0"

  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  if [[ -f "$CONFIG" ]]; then
    printf 'Config bleibt: %s\n' "$CONFIG"
  else
    local token
    token="$(openssl rand -hex 16)"
    umask 077
    cat > "$CONFIG" <<CONF
# Von \`apager install\` erzeugt. Siehe docs/apager.conf.example.
APAGER_PORT="8787"
APAGER_TOKEN="$token"
CONF
    chmod 600 "$CONFIG"
    printf 'Config angelegt: %s\n' "$CONFIG"
  fi

  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$PYTHON</string>
		<string>$LISTENER</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$LISTENER_LOG</string>
	<key>StandardErrorPath</key>
	<string>$LISTENER_LOG</string>
</dict>
</plist>
PLIST_EOF

  # bootout vor bootstrap: eine bereits geladene Fassung wuerde die neue
  # sonst mit "service already loaded" abweisen.
  launchctl bootout "$SERVICE" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  printf 'LaunchAgent geladen: %s\n\n' "$LABEL"

  do_url
}

do_uninstall() {
  launchctl bootout "$SERVICE" 2>/dev/null || true
  rm -f "$PLIST"
  printf 'LaunchAgent entfernt. Config und Protokolle bleiben:\n  %s\n  %s\n' \
    "$CONFIG" "$ALARM_LOG"
}

do_url() {
  local token port bound
  token="$(config_value APAGER_TOKEN)" || die "keine Config — erst 'apager install'"
  port="$(config_value APAGER_PORT)"
  bound="$(bound_address)"

  if [[ -n "$bound" ]]; then
    printf 'In aPager als Ziel eintragen:\n\n  http://%s/alarm/%s\n\n' "$bound" "$token"
  else
    printf 'Der Listener haengt gerade an keiner Adresse (Tailscale aus?).\n'
    printf 'Sobald er gebunden ist, lautet die URL:\n\n  http://<tailscale-adresse>:%s/alarm/%s\n\n' \
      "$port" "$token"
  fi
  printf 'Das Token ist ein Geheimnis: Wer die URL hat, kann Alarme einspeisen.\n'
}

do_status() {
  local bound
  bound="$(bound_address)"

  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    printf 'LaunchAgent   geladen (%s)\n' "$LABEL"
  else
    printf 'LaunchAgent   NICHT geladen — "apager install" fehlt\n'
  fi

  if [[ -n "$bound" ]]; then
    printf 'Listener      gebunden an %s\n' "$bound"
  else
    printf 'Listener      an keine Adresse gebunden\n'
  fi

  # Ueber ifconfig statt ueber das tailscale-CLI: der App-Store-Build blockiert
  # dessen Aufrufe gelegentlich minutenlang.
  local ts
  ts="$(/sbin/ifconfig -a 2>/dev/null | awk '/inet 100\./ {print $2}' | head -1)"
  if [[ -n "$ts" ]]; then
    printf 'Tailscale     verbunden (%s)\n' "$ts"
  else
    printf 'Tailscale     keine Adresse — es kommt nichts an\n'
  fi

  if [[ -s "$ALARM_LOG" ]]; then
    local last
    last="$(grep -a '^===== ' "$ALARM_LOG" | tail -1 | tr -d '= ')"
    printf 'Letzter Alarm %s\n' "$last"
  else
    printf 'Letzter Alarm noch keiner\n'
  fi
}

do_test() {
  local bound token
  bound="$(bound_address)"
  [[ -n "$bound" ]] || die "der Listener haengt an keiner Adresse — 'apager status' zeigt warum"
  token="$(config_value APAGER_TOKEN)" || die "keine Config — erst 'apager install'"

  # Bewusst an die gebundene Tailscale-Adresse und nicht an 127.0.0.1: nur so
  # laufen Bind, Herkunftspruefung und Tokenvergleich wirklich mit. Ueber
  # Loopback waere der Test gruen, waehrend genau diese drei kaputt sind.
  local body
  body="TESTALARM $(date '+%H:%M:%S')
Musterstrasse 12, Musterstadt
Ausgeloest von: apager test"

  printf 'Sende an http://%s/alarm/...\n' "$bound"
  curl -fsS --max-time 5 -X POST --data-binary "$body" \
    "http://$bound/alarm/$token" >/dev/null \
    || die "der Listener hat nicht angenommen — 'apager logs' und $LISTENER_LOG ansehen"
  printf 'Angenommen. Der Dialog sollte jetzt offen sein.\n'
}

do_logs() {
  [[ -f "$ALARM_LOG" ]] || die "noch kein Protokoll: $ALARM_LOG"
  if [[ "${1:-}" == "-f" ]]; then
    tail -f "$ALARM_LOG"
  else
    tail -40 "$ALARM_LOG"
  fi
}

case "${1:-}" in
  -h|--help|help) usage ;;
  install)        do_install ;;
  uninstall)      do_uninstall ;;
  status)         do_status ;;
  url)            do_url ;;
  test)           do_test ;;
  logs)           shift; do_logs "${1:-}" ;;
  "")             do_status ;;
  *)              die "unbekannter Befehl: $1 (siehe --help)" ;;
esac
```

- [ ] **Step 3: Ausfuehrbar machen und mit shellcheck pruefen**

```bash
chmod 755 apager
shellcheck apager
```

Expected: keine Warnungen. Meldet `shellcheck` etwas an, beheben — nicht mit `# shellcheck disable` zudecken, solange die Warnung berechtigt ist.

- [ ] **Step 4: Hilfe und Auffindbarkeit pruefen**

```bash
./apager --help
./r-tools -l | grep apager
```

Expected: Die Hilfe erscheint, und `r-tools -l` listet `apager` mit der Beschreibung aus der Kommentarzeile — aber **nicht** `apager-listener.py`. Taucht der Listener auf, hat er faelschlich Modus 755.

- [ ] **Step 5: Installieren und Status ansehen**

```bash
./apager install
./apager status
```

Expected: Config wird angelegt (oder bleibt), der LaunchAgent laedt, und `status` beantwortet alle vier Zeilen. Ist Tailscale aus, muss `status` das benennen und darf nicht so tun, als liefe alles.

- [ ] **Step 6: `CLAUDE.md` ergaenzen**

Zwei Stellen. In der Werkzeugliste nach dem `sbar`-Absatz einfuegen:

```markdown
- **apager** — Nimmt den Webhook entgegen, den aPager PRO bei einem Einsatzalarm vom Handy absetzt, und zeigt ihn in einem Dialog. Der Listener (`apager-listener.py`, unter launchd) bindet ausschliesslich an die Tailscale-Adresse — nie an `0.0.0.0` —, prüft Quell-IP gegen `100.64.0.0/10` und ein Zufallstoken im Pfad, protokolliert den Rohrequest und startet erst dann die Anzeige. Ein Zweitalarm ersetzt den offenen Dialog durch einen, der beide zeigt. Bewusste Abgrenzung: kein Ton, keine Benachrichtigung, kein Wecken — der Mac ist Anzeige, alarmiert wird über das Handy. Design: `docs/2026-09-10-apager-design.md`.
```

Und den Abschnitt „No Build/Test/Lint" ersetzen, weil er nicht mehr stimmt:

```markdown
## Tests

Die Shell-Skripte haben kein Testframework und werden mit `shellcheck` geprüft.
Einzige Ausnahme ist `apager-listener.py`: dessen reine Funktionen — Adress-
erkennung, Tokenvergleich, Alarmspeicher, HTTP-Handler — tragen die Prüfungen,
die im Ernstfall still brechen, und haben deshalb Unit-Tests:

    /usr/bin/python3 -m unittest discover -s tests -v

`unittest` und `/usr/bin/python3` sind bewusst gewählt: keine Installation, kein
venv, keine mise-Abhängigkeit, die einen LaunchAgent lahmlegen könnte.
```

- [ ] **Step 7: Commit**

```bash
git add apager docs/apager.conf.example CLAUDE.md
git commit -m "apager: Dispatcher zum Installieren, Pruefen und Testen"
```

---

## Nach dem Plan: was noch offen bleibt

Zwei Dinge lassen sich erst mit dem Handy in der Hand erledigen und gehoeren
nicht in diesen Plan:

1. **Die URL in aPager eintragen.** `apager url` gibt sie aus. Danach einen
   Testalarm aus der App ausloesen.
2. **Das Feldmapping ergaenzen.** Sobald der erste echte Alarm in
   `~/.local/state/apager/alarms.log` steht, ist das Format bekannt. Dann wird
   `readable_request()` von der Rohanzeige auf Stichwort, Adresse und Meldung
   umgestellt — eine Aenderung in einer Funktion, mit einem Test, der den echten
   Payload als Beispiel nimmt. Dispatcher, LaunchAgent und Anzeigepfad bleiben
   unberuehrt.

Als verifiziert gilt die Installation erst nach Schritt 1. `apager test` schickt
zwar ueber die echte Tailscale-Adresse und prueft damit Bind, Herkunft und Token
mit — aber nicht, ob aPager die URL akzeptiert und in einem Format sendet, das
der Listener lesbar darstellt.
