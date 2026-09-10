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
import threading
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
