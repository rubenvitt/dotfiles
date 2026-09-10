#!/usr/bin/python3
# apager-listener - nimmt aPager-Webhooks von Tailscale Serve entgegen und zeigt sie an
"""Listener fuer aPager-Alarme.

Laeuft unter launchd und horcht ausschliesslich auf 127.0.0.1. Vor ihm steht
Tailscale Serve: es terminiert HTTPS mit dem echten *.ts.net-Zertifikat, laesst
nur authentifizierte Tailnet-Gegenstellen herein und leitet nach Loopback
weiter. Der Listener selbst ist damit von keinem Netz aus erreichbar.

Der Mac ist hier Anzeige und keine Alarmierung: kein Ton, keine
Benachrichtigung, kein Wecken. Wer schlaeft, verpasst den Alarm — das ist
Absicht, alarmiert wird ueber das Handy.

Siehe docs/2026-09-10-apager-design.md.
"""

import hmac
import ipaddress
import json
import logging
import os
import pathlib
import re
import signal
import subprocess
import sys
import threading
from collections import namedtuple
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

Alarm = namedtuple("Alarm", "received_at text")


def is_loopback_ip(addr):
    """Kommt die Anfrage von dieser Maschine selbst? Muell ergibt False.

    Die Pruefung hat sich mit der Architektur umgedreht. Frueher band der
    Listener an die Tailscale-Adresse und liess nur Absender aus
    100.64.0.0/10 zu; heute bindet er auf 127.0.0.1, und jede legitime
    Anfrage kommt aus dem lokalen Tailscale-Serve-Proxy. Eine Quelle, die
    nicht Loopback ist, kann es bei diesem Bind gar nicht geben — taucht doch
    eine auf, laeuft etwas anderes als gedacht, und das gehoert abgewiesen
    und protokolliert statt angenommen.

    127.0.0.0/8 gilt vollstaendig: der ganze Bereich verlaesst die Maschine
    nicht. IPv4-mapped (::ffff:127.0.0.1) faellt bewusst durch — bei einem
    Bind auf 127.0.0.1 kann diese Form nicht ankommen.
    """
    try:
        parsed = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return parsed.is_loopback


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
    """Zeitkonstanter Vergleich. Ein leeres erwartetes Token passt auf nichts.

    Verglichen wird ueber Bytes, nicht ueber str: compare_digest wirft bei
    einem str mit einem Zeichen ab U+0080 einen TypeError. http.server
    dekodiert die Requestzeile als latin-1, ein einziges Byte >= 0x80 im Pfad
    erzeugt also genau so einen str — und die Ausnahme fiele aus dem Handler
    heraus, ohne Antwort an den Absender und ohne Spur im alarms.log. latin-1
    bildet exakt zurueck, was http.server dekodiert hat.
    """
    if not expected:
        return False
    got = token_from_path(path)
    if got is None:
        return False
    return hmac.compare_digest(
        got.encode("latin-1", "replace"), expected.encode("utf-8")
    )


def redact_path(text, token):
    """Text fuers listener.log (Pfad oder Fehlermeldung), ohne das Token.

    Im Pfad steht das Geheimnis — aPager laesst keine eigenen Header zu. Das
    listener.log wird von "apager status" und "apager logs --listener"
    vorgelesen und landet damit in Ausgaben, die jemand weiterreicht, wenn er
    fragt, warum nichts ankommt.

    Fruehere Fassung redigierte anhand der Pfadform (Praefix exakt
    "/alarm/"): ein vertippter Pfad ("/Alarm/...", "//alarm/...",
    "/alarm2/...") liess das echte Token unveraendert durch — der Mechanismus
    stimmte, die Grenze war falsch gezogen. Die Regel jetzt kennt keine
    Ausnahmen mehr: jedes Vorkommen des echten Tokens im uebergebenen Text
    verschwindet, ganz gleich wo und in welcher Pfadform es steht.

    Ein leeres erwartetes Token redigiert nichts — sonst wuerde
    str.replace("", ...) jedes Zeichen im Text durch den Platzhalter ersetzen.

    Das alarms.log behaelt den vollstaendigen Pfad: es ist die Vorlage fuer
    das spaetere Feldmapping und liegt nicht in Terminalausgaben.
    """
    if not token:
        return text
    return text.replace(token, "<token>")


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

# Wie viel vom lesbaren Inhalt im Dialog landet. Der Deckel gilt fuer beides,
# das Feld-pro-Zeile-Layout wie den Rohtext-Rueckfall: ein einzelnes riesiges
# Feld (oder ein grosser Blob im Fallback-Fall) zoege sonst eine Textwand auf
# und schoebe die Adresse aus dem Fenster. Vollstaendig steht alles im
# alarms.log.
DIALOG_MAX_CHARS = 2000

# Eine Chunk-Groessenzeile ist ein paar Bytes lang. Der Deckel verhindert, dass
# ein Absender ohne Zeilenumbruch beliebig viel Speicher belegt.
CHUNK_LINE_MAX = 1024


class BadFraming(Exception):
    """Der Rahmen der Anfrage ist unbrauchbar.

    Sie wird dann ganz verworfen statt zur Haelfte gelesen: hier ist nicht die
    Herkunft oder das Token das Problem, sondern die Anfrage selbst.
    """


def _read_chunked(rfile, limit):
    """Liest einen chunked gerahmten Body und gibt (bytes, status) zurueck.

    status ist "ok", "gekappt" (limit erreicht) oder "kaputt" (Rahmen nicht
    deutbar). Ein kaputter Rahmen fuehrt nie zu einer Ausnahme und nie zu
    einem Weiterlesen — was bis dahin ankam, ist der Rueckgabewert. Der
    Aufrufer entscheidet, ob das noch ein Alarm ist.
    """
    body = bytearray()
    while True:
        line = rfile.readline(CHUNK_LINE_MAX + 1)
        if not line or len(line) > CHUNK_LINE_MAX:
            return bytes(body), "kaputt"
        try:
            # Hinter der Groesse duerfen Chunk-Erweiterungen stehen: "1a;foo=bar".
            size = int(line.split(b";", 1)[0].strip(), 16)
        except ValueError:
            return bytes(body), "kaputt"
        if size < 0:
            return bytes(body), "kaputt"
        if size == 0:
            break
        chunk = rfile.read(size)
        if len(chunk) < size:
            return bytes(body), "kaputt"
        body.extend(chunk[: max(0, limit - len(body))])
        if len(body) >= limit:
            return bytes(body), "gekappt"
        if rfile.readline(CHUNK_LINE_MAX + 1) not in (b"\r\n", b"\n"):
            return bytes(body), "kaputt"
    # Etwaige Trailer bis zur Leerzeile wegwerfen.
    while True:
        line = rfile.readline(CHUNK_LINE_MAX + 1)
        if not line or line in (b"\r\n", b"\n"):
            break
    return bytes(body), "ok"


# Wie weit ein Feldname im Dialog eingerueckt werden darf. Die Felder aus der
# aPager-Konfiguration sind kurz ("keyword", "unit"); ein einzelner
# ungewoehnlich langer Name soll trotzdem nicht jeden Wert aus dem sichtbaren
# Bereich des Dialogs schieben.
FIELD_NAME_PAD_CAP = 20


def _field_value_display(value):
    """Ein Feldwert als Text fuer den Dialog.

    Strings erscheinen ohne die JSON-Anfuehrungszeichen — die sind fuer einen
    Menschen um 3 Uhr nachts nur Rauschen. Alles andere (Zahl, bool, null,
    verschachteltes Objekt/Array) laeuft durch json.dumps: kompakt, garantiert
    einzeilig, ohne Sonderfall pro JSON-Typ.
    """
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _json_object_display(obj):
    """Ein JSON-Objekt als 'Feldname  Wert'-Zeilen, ein Feld pro Zeile.

    Reihenfolge bleibt die des Requests (json.loads erhaelt sie seit 3.7,
    sortiert wird nicht). Ein Objekt ohne Felder liefert hier "" zurueck; der
    Aufrufer faengt das ab, damit daraus kein leerer Dialogtext wird.
    """
    width = min(max((len(name) for name in obj), default=0), FIELD_NAME_PAD_CAP)
    return "\n".join(
        "{:<{width}}  {}".format(name, _field_value_display(value), width=width)
        for name, value in obj.items()
    )


def _render_body(body_text):
    """Der Body fuers Dialog: ein Feld pro Zeile, wenn er ein JSON-Objekt ist.

    Alles andere — kein JSON, kaputtes JSON, ein JSON-Array oder -Skalar, ein
    leeres Objekt — faellt zurueck auf die Rohanzeige. Dieses Projekt hat sich
    an einer Formatannahme schon zweimal verschluckt (siehe is_loopback_ip,
    redact_path); der Rueckfall hier ist deshalb keine Nebensaeche, sondern
    das eigentliche Verhalten. Keine Ausnahme darf aus dieser Funktion
    heraus: ein Alarm darf nie an einer Anzeige-Annahme scheitern.
    """
    try:
        parsed = json.loads(body_text)
        if not isinstance(parsed, dict) or not parsed:
            return body_text
        rendered = _json_object_display(parsed)
        return rendered if rendered else body_text
    except Exception:
        return body_text


def readable_request(method, path, headers_text, body_bytes):
    """Was im Dialog steht.

    Ein JSON-Objekt im Body wird Feld fuer Feld angezeigt (siehe
    _render_body); alles andere unveraendert als Rohtext, wie schon vor dem
    Feldmapping.

    method und headers_text werden noch nicht ausgewertet, stehen aber bewusst
    schon in der Signatur: eine kuenftige Erweiterung koennte den Content-Type
    heranziehen, statt den Body blind als JSON zu versuchen.
    """
    body = body_bytes.decode("utf-8", errors="replace").strip()
    parts = []
    if body:
        parts.append(_render_body(body))
    query = path.split("?", 1)[1] if "?" in path else ""
    if query:
        parts.append(query)
    if not parts:
        parts.append("(kein Inhalt)")
    text = "\n".join(parts)
    if len(text) > DIALOG_MAX_CHARS:
        text = text[:DIALOG_MAX_CHARS].rstrip() + "\n\n[... gekuerzt, vollstaendig im alarms.log]"
    return text


def raw_request_record(method, path, headers_text, body_bytes, received_at, note=""):
    """Der vollstaendige Eintrag fuer alarms.log.

    note vermerkt einen unvollstaendigen Body direkt unter der Requestzeile.
    Ohne den Vermerk saehe ein gekappter oder abgerissener Body im Protokoll
    aus wie ein vollstaendiger — und genau dieses Protokoll ist die Grundlage
    fuer das spaetere Feldmapping.
    """
    body = body_bytes.decode("utf-8", errors="replace")
    return (
        "===== {} =====\n{} {}\n{}{}\n{}\n".format(
            received_at.isoformat(timespec="seconds"),
            method,
            path,
            "[{}]\n".format(note) if note else "",
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


def make_handler(token, display, alarm_log, allow_source=is_loopback_ip, on_event=None):
    """Baut die Handler-Klasse. Alles Veraenderliche kommt ueber Closures herein,
    damit der Handler ohne globalen Zustand testbar bleibt."""
    notify = on_event or (lambda message: None)

    class AlarmHandler(BaseHTTPRequestHandler):
        server_version = "apager"
        sys_version = ""

        # Ein Absender, der die Verbindung offen haelt und nichts mehr schickt,
        # wuerde einen Handler-Thread sonst dauerhaft binden.
        timeout = 10

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

        def log_message(self, fmt, *args):
            # Der eingebaute Zugriffslog schreibt nach stderr und damit in die
            # listener.log; wir protokollieren selbst, was zaehlt.
            pass

        def log_error(self, fmt, *args):
            """Faengt, was BaseHTTPRequestHandler an _dispatch vorbei selbst
            beantwortet: unbekannte Methoden (PUT, HEAD, OPTIONS -> 501, weil
            kein do_* existiert) und kaputte Requestzeilen (400), beide ueber
            sein eigenes send_error(). log_message() oben schluckte das bisher
            komplett — der Absender bekam die Fehlerzeile, aber weder
            listener.log noch "apager status" sahen sie je. Harmlos, solange
            "status" nichts behauptete; seit die Abgewiesen-Zeile Gesundheit
            signalisiert, ist genau das die Fluchtstelle desselben
            Fehlerbilds: eine Anfrage prallt spurlos ab.

            self.command/self.path existieren hier nicht immer — eine kaputte
            Requestzeile faellt schon in parse_request() aus der
            Wortzahl-Pruefung, bevor beide gesetzt werden. self.requestline
            ist in dem Fall trotzdem da und dient als Ersatz.
            """
            command = getattr(self, "command", None) or "?"
            where = getattr(self, "path", None) or getattr(self, "requestline", "") or "?"
            notify(
                "abgewiesen: {} ({} {})".format(
                    redact_path(fmt % args, token), command, redact_path(where, token)
                )
            )

        def _health(self):
            """Antwortet "apager status", ohne eine Spur zu hinterlassen.

            Der Pfad braucht kein Token: er transportiert keine Alarmdaten und
            verraet nichts, was ein Tailnet-Mitglied nicht ohnehin sieht. Er
            braucht aber zwingend seine eigene Antwort *vor* dem
            Tokenvergleich — sonst zaehlte jede Statusabfrage als abgewiesene
            Anfrage, und genau diese Zahl ist das Signal, an dem ein veraltetes
            Token auffliegt. Eine Anzeige, die ihr eigenes Nachsehen als
            Stoerung protokolliert, ist schlimmer als gar keine.

            204 statt 200 mit Inhalt: hier ist nichts zu lesen, nur zu
            beantworten.
            """
            self._responded = True
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _reject(self, reason, status=404):
            notify("abgewiesen: {} ({} {})".format(reason, self.command, redact_path(self.path, token)))
            self._responded = True
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _handle(self, method):
            """Faengt alles, was aus _dispatch herausfaellt.

            Das eigentliche Fehlerbild dieses Werkzeugs ist nicht der Absturz,
            sondern der Alarm, der spurlos verschwindet. Eine Ausnahme aus dem
            Handler landet in socketserver.handle_error, deren Traceback in
            einer Datei steht, die kein Befehl vorliest — der Absender bekommt
            nichts, das alarms.log bleibt leer, und niemand erfaehrt davon.
            Dieser Block schliesst diese Fehlerklasse strukturell: was hier
            hereinfaellt, wird protokolliert, und der Absender bekommt eine
            Antwort.
            """
            self._responded = False
            try:
                self._dispatch(method)
            except Exception as exc:
                notify("Anfrage fehlgeschlagen: {!r} ({} {})".format(exc, method, redact_path(self.path, token)))
                self._answer_with_failure()

        def _answer_with_failure(self):
            # Nur wenn noch nichts hinausging: sonst haenge man eine zweite
            # Statuszeile an eine bereits gesendete Antwort.
            if self._responded:
                return
            try:
                self._responded = True
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()
            except OSError:
                pass  # Verbindung schon weg — mehr ist hier nicht zu tun.

        def _read_body(self):
            """(bytes, Vermerk) — Vermerk ist leer, wenn der Body vollstaendig ist."""
            encoding = self.headers.get("Transfer-Encoding", "").strip().lower()
            if encoding:
                if "chunked" not in encoding:
                    raise BadFraming("Transfer-Encoding nicht unterstuetzt")
                body, status = _read_chunked(self.rfile, MAX_BODY_BYTES)
                if status == "kaputt":
                    # Der Rest des Streams ist nicht mehr zu deuten; die
                    # Verbindung darf nicht wiederverwendet werden.
                    self.close_connection = True
                    if not body:
                        raise BadFraming("chunked-Body unlesbar")
                    return body, "chunked-Body unvollstaendig — Rahmen kaputt"
                if status == "gekappt":
                    self.close_connection = True
                    return body, "Body bei {} Bytes gekappt".format(MAX_BODY_BYTES)
                return body, ""

            length = _parse_content_length(self.headers)
            if length is None:
                raise BadFraming("Content-Length ungueltig")
            if length > MAX_BODY_BYTES:
                self.close_connection = True
                return self.rfile.read(MAX_BODY_BYTES), "Body bei {} Bytes gekappt".format(
                    MAX_BODY_BYTES
                )
            return (self.rfile.read(length) if length else b""), ""

        def _dispatch(self, method):
            source = self.client_address[0]
            if not allow_source(source):
                self._reject("Quelle nicht lokal")
                return
            if method == "GET" and self.path.split("?", 1)[0] == HEALTH_PATH:
                self._health()
                return
            if not token_matches(self.path, token):
                self._reject("Token stimmt nicht")
                return

            try:
                body, note = self._read_body()
            except BadFraming as exc:
                self._reject(str(exc), status=400)
                return
            if note:
                notify("{} ({} {})".format(note, method, redact_path(self.path, token)))

            received_at = datetime.now()
            headers_text = str(self.headers)

            # Erst protokollieren, dann anzeigen: ein Fehler in der Darstellung
            # darf keinen Einsatz verschlucken.
            try:
                alarm_log.parent.mkdir(parents=True, exist_ok=True)
                with alarm_log.open("a", encoding="utf-8") as handle:
                    handle.write(
                        raw_request_record(
                            method, self.path, headers_text, body, received_at, note
                        )
                    )
            except OSError as exc:
                notify("alarms.log nicht schreibbar: {}".format(exc))

            self._responded = True
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

# Die einzige Adresse, auf die dieser Listener je bindet. Nicht 0.0.0.0, nicht
# die Tailscale-Adresse, kein anderes Interface: davor steht Tailscale Serve,
# und dessen Backend darf nicht die eigene Tailnet-Adresse des Knotens sein —
# der weitergeleitete Verkehr liefe dann zurueck durch den Tailscale-Stack und
# blockierte (gemessen: Loopback 200 in 25 ms, eigene Tailnet-Adresse Timeout
# nach 20 s). Siehe docs/2026-09-10-apager-design.md.
BIND_ADDRESS = "127.0.0.1"

# Der Pfad, ueber den "apager status" die ganze Kette prueft: TLS, Serve,
# Weiterleitung, antwortender Listener. Siehe _health() im Handler.
HEALTH_PATH = "/healthz"

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
    """Bindet und bedient Requests, bis der Prozess beendet wird.

    Kehrt nur ueber SIGTERM zurueck (als SystemExit durch das finally) oder
    sofort mit dem OSError vom Bind. Fruehere Fassungen ueberwachten hier die
    gebundene Adresse und banden bei einem Wechsel neu — das war die Antwort
    darauf, dass die Tailscale-Adresse kommt und geht. Loopback tut das nicht,
    also gibt es nichts zu ueberwachen; eine Schleife, die auf eine Bedingung
    wartet, die immer erfuellt ist, ist kein Sicherheitsnetz, sondern
    Irrefuehrung.

    Das Protokollieren des Bindfehlers gehoert bewusst dem Aufrufer: nur er
    weiss, ob daraufhin noch etwas versucht wird oder der Prozess endet.
    """
    handler = make_handler(token, display, alarm_log, on_event=on_event)
    try:
        httpd = ThreadingHTTPServer((address, port), handler)
    except OSError as exc:
        return exc

    # Der tatsaechlich gebundene Port, nicht der erbetene: bei Port 0 waere
    # sonst ":0" die Auskunft, und "status" laese eine Adresse vor, an der nie
    # jemand horchte.
    bound_port = httpd.server_address[1]
    on_event("gebunden an {}:{}".format(address, bound_port))
    try:
        bound_file.parent.mkdir(parents=True, exist_ok=True)
        bound_file.write_text("{}:{}\n".format(address, bound_port), encoding="utf-8")
    except OSError as exc:
        on_event("bound-Datei nicht schreibbar: {}".format(exc))

    # serve_forever() laeuft im Hauptthread, damit SIGTERM ihn erreicht: der
    # Handler wirft SystemExit, die aus dem select() herausfaellt und das
    # finally unten durchlaeuft. In einem Nebenthread bliebe die bound-Datei
    # stehen und wiese einen toten Listener als lebendig aus.
    try:
        httpd.serve_forever()
    finally:
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

    # Das alarms.log enthaelt Einsatzadressen und mitunter Namen. Unter launchd
    # entstuende es sonst mit dessen umask als 644.
    os.umask(0o077)

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

    bind_error = serve(
        address=BIND_ADDRESS,
        port=port,
        token=token,
        display=display,
        alarm_log=ALARM_LOG,
        bound_file=BOUND_FILE,
        on_event=logging.info,
    )
    if bind_error is None:
        return 0
    # Ein belegter Loopback-Port ist ein anhaltender Zustand, kein
    # Wackelkontakt: hier zu warten und stumm weiterzuversuchen hiesse, einen
    # nicht laufenden Listener zu verbergen. KeepAlive im LaunchAgent startet
    # neu, jeder Versuch schreibt diese Zeile, und "apager status" liest sie
    # als letzte Zeile des listener.log vor.
    logging.error("Bind auf %s:%s fehlgeschlagen: %s", BIND_ADDRESS, port, bind_error)
    return 1


if __name__ == "__main__":
    sys.exit(main())
