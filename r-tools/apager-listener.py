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
import logging
import pathlib
import re
import signal
import subprocess
import sys
import threading
import time
from collections import namedtuple
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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
            exc = self._restart_dialog()
        if exc is not None:
            self._on_error(exc)

    def _restart_dialog(self):
        """Nur mit gehaltenem Lock aufrufen. Gibt Exception zurueck (oder None)."""
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
            return exc

        self._proc = proc
        watcher = threading.Thread(
            target=self._wait_for_acknowledgement,
            args=(proc, generation),
            daemon=True,
        )
        watcher.start()
        return None

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


def _parse_content_length(headers):
    """Content-Length robust lesen: 0 wenn er fehlt, None wenn ihm nicht zu
    trauen ist.

    Ein fehlender Header heisst leerer Body — aPager schickt bei GET keinen.
    Ein Wert, der keine nichtnegative Zahl ist, macht den Rahmen der Anfrage
    unbrauchbar: int() wuerde bei Unsinn wie "abc" eine ValueError werfen,
    und ein negativer Wert wuerde als rfile.read(-1) bei einem
    BufferedReader "lies bis Verbindungsende" bedeuten und den Handler-Thread
    blockieren. Beides faengt der Aufrufer ab, statt zu lesen. Ein zu grosser,
    aber sonst gueltiger Wert ist dagegen kein Framing-Fehler und bleibt
    unveraendert — dafuer sorgt weiterhin der MAX_BODY_BYTES-Deckel beim Lesen.
    """
    raw = headers.get("Content-Length")
    if raw is None:
        return 0
    try:
        length = int(raw)
    except ValueError:
        return None
    return length if length >= 0 else None


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

        def _reject(self, reason, status=404):
            notify("abgewiesen: {} ({} {})".format(reason, self.command, self.path))
            self.send_response(status)
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

            length = _parse_content_length(self.headers)
            if length is None:
                # Ein Rahmen, dem man nicht traut, wird verworfen statt zur
                # Haelfte gelesen: 400, nicht 404 — hier ist nicht die
                # Herkunft oder das Token das Problem, sondern die Anfrage
                # selbst.
                self._reject("Content-Length ungueltig", status=400)
                return
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


def serve(address, port, token, display, alarm_log, bound_file, on_event):
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

    # Start liegt in diesem try, nicht davor: schlaegt er fehl, muss dasselbe
    # finally httpd wieder schliessen und die bound-Datei aufraeumen statt die
    # Ausnahme unbehandelt durchzureichen.
    try:
        worker = threading.Thread(target=httpd.serve_forever, daemon=True)
        worker.start()
        while True:
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


def _handle_sigterm(signum, frame):
    """Verwandelt SIGTERM in eine Ausnahme, die serve()s finally durchlaeuft.

    launchd stoppt den Prozess per SIGTERM (bootout, Neuladen, Neustart). Ohne
    Handler beendet die Standardreaktion den Prozess, ohne den Stack
    abzuwickeln — die bound-Datei bliebe stehen und wuerde einen toten Listener
    als lebendig ausweisen. SystemExit laesst das bestehende finally in
    serve() unveraendert die Aufraeumarbeit erledigen.
    """
    raise SystemExit(0)


def _cleanup_bound_file(bound_file):
    """Entfernt eine bound-Datei aus einem frueheren Lauf.

    Ein SIGTERM-Handler hilft nur gegen Signale, die sich fangen lassen —
    gegen SIGKILL, einen Absturz oder einen Stromausfall nicht. Das Loeschen
    beim Start macht "diese Datei existiert" wieder zu einer verlaesslichen
    Aussage ueber den aktuellen Prozess statt einen vergangenen.
    """
    try:
        bound_file.unlink()
    except OSError:
        pass


def _parse_port(value):
    """Parst APAGER_PORT und akzeptiert nur einen gueltigen TCP-Port.

    int(...) allein liesse z. B. "99999999" durch; das crasht erst tief in
    ThreadingHTTPServer(...) mit einem OverflowError, den nichts abfaengt —
    und mit KeepAlive im LaunchAgent eine Absturzschleife statt einer klaren
    Fehlermeldung.
    """
    port = int(value)
    if not 1 <= port <= 65535:
        raise ValueError("Port {} ausserhalb des gueltigen Bereichs".format(port))
    return port


def main():
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    signal.signal(signal.SIGTERM, _handle_sigterm)

    # Bedingungslos, noch vor der Schleife: nur so heisst "die Datei existiert"
    # zuverlaessig "dieser Prozess hat gebunden" statt moeglicherweise "ein
    # frueherer Prozess hat mal gebunden und wurde dann hart beendet".
    _cleanup_bound_file(BOUND_FILE)

    config = read_config(CONFIG_PATH)
    token = config.get("APAGER_TOKEN", "")
    if not token:
        logging.error("kein APAGER_TOKEN in %s — es wird nichts angenommen", CONFIG_PATH)
        return 1
    try:
        port = _parse_port(config.get("APAGER_PORT", DEFAULT_PORT))
    except ValueError:
        logging.error("APAGER_PORT ist keine gueltige Portnummer (1-65535)")
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
        )
        time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
