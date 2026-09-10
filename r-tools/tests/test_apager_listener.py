"""Tests fuer die reinen Hilfsfunktionen von apager-listener.py."""

import http.client
import importlib.util
import io
import pathlib
import re
import socket
import tempfile
import time
import unittest
from datetime import datetime
from http.server import ThreadingHTTPServer

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

# Der Fall, um den es geht: 100.64.0.0/10 ist der CGNAT-Bereich der
# Mobilfunkanbieter. Ein Mac, der ueber einen solchen Carrier tethert, traegt
# eine Adresse daraus auf en0 — und die steht hier vor der Tailscale-Adresse.
IFCONFIG_CGNAT_TETHERING = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 100.92.7.31 netmask 0xfffffc00 broadcast 100.92.7.255
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
\tinet 100.101.102.103 --> 100.101.102.103 netmask 0xff000000
\tinet6 fd7a:115c:a1e0::1234 prefixlen 128
"""

# Getethert, aber Tailscale laeuft nicht. Die CGNAT-Adresse auf en0 ist eine
# gueltige Tailnet-Adresse und trotzdem die falsche: haengte der Listener
# daran, lauschte er am Mobilfunk-Interface.
IFCONFIG_CGNAT_ONLY = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 100.92.7.31 netmask 0xfffffc00 broadcast 100.92.7.255
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

    def test_prefers_utun_over_a_cgnat_address_on_en0(self):
        # Ohne Interface-Pruefung faellt hier die Mobilfunkadresse heraus, und
        # der Listener lauscht am falschen Interface, waehrend "status" alles
        # gruen meldet.
        self.assertEqual(
            listener.tailnet_address(IFCONFIG_CGNAT_TETHERING), "100.101.102.103"
        )

    def test_a_cgnat_address_without_tailscale_is_not_used(self):
        # Lieber gar nicht binden als ans Mobilfunk-Interface: "keine Adresse"
        # ist eine sichtbare Aussage, ein falsches Interface ist keine.
        self.assertIsNone(listener.tailnet_address(IFCONFIG_CGNAT_ONLY))

    def test_parses_interface_and_address_pairs_in_order(self):
        self.assertEqual(
            listener.parse_ifconfig_addresses(IFCONFIG_SAMPLE),
            [
                ("lo0", "127.0.0.1"),
                ("en0", "192.168.178.42"),
                ("utun4", "100.101.102.103"),
            ],
        )

    def test_inet6_lines_are_not_mistaken_for_addresses(self):
        pairs = listener.parse_ifconfig_addresses(IFCONFIG_SAMPLE)
        self.assertNotIn("fd7a:115c:a1e0::1234", [addr for _, addr in pairs])


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

    def test_non_ascii_token_is_rejected_instead_of_raising(self):
        # Vorher: hmac.compare_digest wirft bei einem str mit einem Zeichen ab
        # U+0080 einen TypeError. http.server dekodiert die Requestzeile als
        # latin-1, ein einziges solches Byte im Pfad genuegte also, um die
        # Anfrage spurlos verschwinden zu lassen.
        self.assertFalse(listener.token_matches("/alarm/geheim\xff", "geheim"))
        self.assertFalse(listener.token_matches("/alarm/äöü", "geheim"))


class TestRedactPath(unittest.TestCase):
    """Das listener.log wird jetzt vorgelesen — das Token darf nicht drinstehen."""

    def test_the_token_is_removed(self):
        self.assertEqual(listener.redact_path("/alarm/geheim", "geheim"), "/alarm/<token>")

    def test_the_query_survives(self):
        self.assertEqual(
            listener.redact_path("/alarm/geheim?stichwort=B2", "geheim"),
            "/alarm/<token>?stichwort=B2",
        )

    def test_paths_without_a_token_stay_readable(self):
        # Eine Sonde muss von einem echten aPager-Request unterscheidbar bleiben.
        self.assertEqual(listener.redact_path("/favicon.ico", "geheim"), "/favicon.ico")
        self.assertEqual(listener.redact_path("/", "geheim"), "/")

    def test_extra_path_segments_after_the_token_are_still_redacted(self):
        self.assertEqual(
            listener.redact_path("/alarm/geheim/extra", "geheim"),
            "/alarm/<token>/extra",
        )

    def test_near_miss_prefixes_no_longer_leak_the_token(self):
        # Der urspruengliche Fehler: token_from_path() kannte nur den exakten
        # Praefix "/alarm/" — ein vertippter Pfad liess das echte Token
        # unveraendert durch. Redigiert wird jetzt anhand des Inhalts, nicht
        # der Pfadform, also treffen auch diese Faelle.
        near_misses = [
            "/Alarm/geheim",
            "//alarm/geheim",
            "/alarm2/geheim",
            "/ALARM/geheim",
            "/alarm%2fgeheim",
        ]
        for path in near_misses:
            with self.subTest(path=path):
                self.assertNotIn("geheim", listener.redact_path(path, "geheim"))

    def test_an_empty_token_redacts_nothing(self):
        # str.replace("", ...) wuerde sonst jedes Zeichen ersetzen.
        self.assertEqual(listener.redact_path("/alarm/x", ""), "/alarm/x")

    def test_redacts_the_token_inside_an_arbitrary_message_too(self):
        # log_error() (siehe TestHandler) redigiert nicht nur Pfade, sondern
        # auch freien Text wie eine kaputte Requestzeile.
        self.assertNotIn(
            "geheim",
            listener.redact_path("Bad request syntax ('GET /alarm/geheim X')", "geheim"),
        )


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


class TestDialogLength(unittest.TestCase):
    def test_a_huge_payload_is_shortened_for_the_dialog(self):
        # Ein unbekanntes Format kann ein grosser JSON-Blob sein. Ungekuerzt
        # schoebe der die Adresse aus dem Fenster.
        body = ("{}".format("x" * 50000)).encode("utf-8")
        text = listener.readable_request("POST", "/alarm/geheim", "", body)
        self.assertLess(len(text), listener.DIALOG_MAX_CHARS + 200)
        self.assertIn("gekuerzt", text)

    def test_a_normal_payload_is_untouched(self):
        text = listener.readable_request(
            "POST", "/alarm/geheim", "", b"B2 Wohnungsbrand\nMusterstrasse 12"
        )
        self.assertEqual(text, "B2 Wohnungsbrand\nMusterstrasse 12")

    def test_the_full_body_still_reaches_the_log(self):
        body = b"y" * 50000
        record = listener.raw_request_record(
            "POST", "/alarm/geheim", "", body, datetime(2026, 9, 10, 14, 0, 0)
        )
        self.assertIn(body.decode("ascii"), record)


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

    def test_on_error_can_safely_call_pending_without_deadlock(self):
        # Gegentest zum Deadlock-Verbot: der on_error-Callback darf in derselben
        # AlarmDisplay-Instanz .pending() aufrufen, ohne dass der Thread, der
        # add() aufgerufen hat, auf einen Lock wartet, den der Callback auch
        # benoetigt. Das Test laueft add() in einem Thread und wartet mit Timeout,
        # um den Deadlock sichtbar zu machen, falls er existiert.
        def broken_spawn(text):
            raise OSError("osascript fehlt")

        results = []

        def on_error_that_queries_pending(exc):
            # Dies ist natuerlich in einem echten Callback: auf Fehler den
            # kompletten Alarmkontext ausgeben, um debugging zu erleichtern.
            pending = self.display.pending()
            results.append((exc, pending))

        self.display._on_error = on_error_that_queries_pending
        self.display._spawn = broken_spawn

        # Lauefe add() in einem separaten Thread, damit der Deadlock sichtbar
        # wird (wenn vorhanden).
        thread = threading.Thread(
            target=lambda: self.display.add(self._alarm(0, "TEST")),
            daemon=True
        )
        thread.start()
        thread.join(timeout=3)

        # Wenn der Thread noch laeuft, ist das ein Deadlock.
        self.assertFalse(
            thread.is_alive(),
            "add() did not return within 3 seconds; likely deadlock in on_error",
        )
        self.assertEqual(len(results), 1)
        self.assertIsInstance(results[0][0], OSError)
        self.assertEqual(len(results[0][1]), 1)


class _HandlerFixture:
    """setUp und Hilfsmittel fuer alle Handler-Tests.

    Bewusst kein TestCase: eine Testklasse als Basis einer zweiten liesse
    deren Tests ein zweites Mal laufen.
    """

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

    def _raw_request(self, header_lines, body=b"", path="/alarm/geheim"):
        """Schickt eine Anfrage mit handgesetzten Headern.

        http.client berechnet Content-Length selbst und laesst sich nicht
        dazu bringen, kaputte oder negative Werte zu schicken — genau die
        Faelle, die hier geprueft werden. Der Socket-Timeout sorgt dafuer,
        dass ein Haengenbleiben des Handlers den Test scheitern laesst statt
        die ganze Suite zu blockieren.
        """
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
            request = "POST {} HTTP/1.1\r\nHost: 127.0.0.1\r\n".format(path)
            for line in header_lines:
                request += line + "\r\n"
            request += "\r\n"
            # latin-1, weil http.server die Requestzeile genau so dekodiert:
            # so laesst sich ein einzelnes Byte >= 0x80 im Pfad schicken.
            sock.sendall(request.encode("latin-1") + body)
            return sock.recv(65536)

    @staticmethod
    def _status_of(raw_response):
        match = re.match(rb"^HTTP/1\.[01] (\d+) ", raw_response)
        return int(match.group(1)) if match else None


class TestHandler(_HandlerFixture, unittest.TestCase):
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

    def test_the_event_does_not_carry_the_token(self):
        # "status" und "logs --listener" lesen diese Zeilen vor.
        self._request("POST", "/alarm/geheim-aber-falsch", body="egal")
        joined = "\n".join(self.events)
        self.assertNotIn("geheim-aber-falsch", joined)
        self.assertIn("/alarm/<token>", joined)

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

    def test_malformed_content_length_is_rejected_not_crashed(self):
        # Vorher: int("abc") warf eine unbehandelte ValueError, die aus
        # do_POST herausfiel und einen Traceback nach stderr schrieb.
        response = self._raw_request(["Content-Length: abc"])
        self.assertEqual(self._status_of(response), 400)
        self.assertEqual(self.shown, [])

    def test_negative_content_length_gets_a_response_instead_of_hanging(self):
        # Vorher: min(-1, MAX_BODY_BYTES) == -1, und rfile.read(-1) liest bis
        # zum Verbindungsende statt bis zu einer festen Laenge — der Handler
        # blockierte, bis der Client den Timeout hier ausloeste.
        response = self._raw_request(["Content-Length: -1"])
        self.assertEqual(self._status_of(response), 400)
        self.assertEqual(self.shown, [])

    def test_oversized_content_length_is_clamped_not_rejected(self):
        # Eine zu grosse, aber sonst gueltige Laenge ist kein Framing-Fehler:
        # der Body wird bei MAX_BODY_BYTES gekappt, die Anfrage bleibt gueltig.
        huge_body = b"x" * (listener.MAX_BODY_BYTES + 1000)
        response = self._raw_request(
            ["Content-Length: {}".format(len(huge_body))], body=huge_body
        )
        self.assertEqual(self._status_of(response), 200)
        self.assertEqual(len(self.shown), 1)

    def test_absent_content_length_is_treated_as_empty_body(self):
        response = self._raw_request([])
        self.assertEqual(self._status_of(response), 200)
        self.assertEqual(len(self.shown), 1)
        self.assertIn("(kein Inhalt)", self.shown[0].text)

    def test_non_ascii_in_the_path_gets_an_answer_and_leaves_a_trace(self):
        # Vorher: TypeError aus compare_digest, der Absender bekam nichts, im
        # alarms.log stand nichts, und der Traceback landete in einer Datei,
        # die kein Befehl vorliest.
        response = self._raw_request([], path="/alarm/geheim\xff")
        self.assertEqual(self._status_of(response), 404)
        self.assertEqual(self.shown, [])
        self.assertTrue(any("abgewiesen" in e for e in self.events))

    def test_an_unexpected_exception_still_answers_and_is_logged(self):
        # Der strukturelle Teil: keine Ausnahme aus dem Handler darf mehr
        # spurlos bleiben, ganz gleich woher sie kommt.
        def boom(ip):
            raise RuntimeError("unerwartet")

        handler = listener.make_handler(
            token="geheim",
            display=self.display,
            alarm_log=self.alarm_log,
            allow_source=boom,
            on_event=self.events.append,
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)

        with socket.create_connection(
            ("127.0.0.1", server.server_address[1]), timeout=3
        ) as sock:
            sock.sendall(b"POST /alarm/geheim HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            response = sock.recv(65536)

        self.assertEqual(self._status_of(response), 500)
        self.assertTrue(any("Anfrage fehlgeschlagen" in e for e in self.events))

    def test_an_unsupported_method_gets_501_and_leaves_a_trace(self):
        # PUT/HEAD/OPTIONS haben kein do_*; BaseHTTPRequestHandler beantwortet
        # das selbst per send_error(), an _dispatch/_reject vorbei. Vor der
        # Ueberschreibung von log_error schluckte log_message() (s.o.) das
        # komplett: der Absender bekam die 501, aber weder listener.log noch
        # "apager status" sahen je etwas davon.
        for method in ("PUT", "HEAD", "OPTIONS"):
            with self.subTest(method=method):
                self.events.clear()
                status = self._request(method, "/alarm/geheim")
                self.assertEqual(status, 501)
                self.assertTrue(any("abgewiesen" in e for e in self.events))

    def test_an_unsupported_method_does_not_carry_the_token(self):
        self._request("PUT", "/alarm/geheim")
        joined = "\n".join(self.events)
        self.assertNotIn("geheim", joined)
        self.assertIn("/alarm/<token>", joined)

    def test_a_malformed_request_line_gets_400_and_leaves_a_trace(self):
        # Zu viele Woerter in der Requestzeile scheitern schon in
        # parse_request(), bevor self.command/self.path je gesetzt werden —
        # log_error() muss trotzdem ohne Traceback eine Spur hinterlassen. Das
        # letzte Wort ist bewusst eine gueltige HTTP-Version: nur dann setzt
        # parse_request() self.request_version um, bevor es abbricht, und
        # send_error() schreibt ueberhaupt eine Statuszeile (sonst behandelt
        # http.server die Verbindung als HTTP/0.9 und antwortet ohne eine).
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
            sock.sendall(b"GARBAGE REQUEST LINE HTTP/1.1\r\n\r\n")
            response = sock.recv(65536)
        self.assertEqual(self._status_of(response), 400)
        self.assertTrue(any("abgewiesen" in e for e in self.events))

    def test_a_malformed_request_line_still_redacts_an_embedded_token(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
            sock.sendall(b"GET /alarm/geheim EXTRA JUNK HTTP/1.1\r\n\r\n")
            response = sock.recv(65536)
        self.assertEqual(self._status_of(response), 400)
        joined = "\n".join(self.events)
        self.assertNotIn("geheim", joined)


class TestChunkedBodies(_HandlerFixture, unittest.TestCase):
    """Chunked ist kein Randfall.

    Android-HTTP-Stacks rahmen chunked, sobald die Laenge beim Absenden noch
    nicht feststeht, und das Payload-Format von aPager ist per Definition
    unbekannt. Ohne diesen Zweig lief der Body ins Leere: 200 an das Handy,
    Header ohne Body im alarms.log, ein Dialog mit "(kein Inhalt)" — und
    "status" meldete einen letzten Alarm. Der erste echte Alarm ist genau die
    Vorlage, aus der das Feldmapping entsteht.
    """

    @staticmethod
    def _chunks(*pieces):
        raw = b""
        for piece in pieces:
            raw += "{:x}\r\n".format(len(piece)).encode("ascii") + piece + b"\r\n"
        return raw + b"0\r\n\r\n"

    def test_a_chunked_body_arrives_complete(self):
        body = self._chunks(b"B2 Wohnungsbrand\n", b"Musterstrasse 12")
        response = self._raw_request(["Transfer-Encoding: chunked"], body=body)
        self.assertEqual(self._status_of(response), 200)
        self.assertEqual(len(self.shown), 1)
        self.assertIn("B2 Wohnungsbrand", self.shown[0].text)
        self.assertIn("Musterstrasse 12", self.shown[0].text)
        self.assertIn("Musterstrasse 12", self.alarm_log.read_text(encoding="utf-8"))

    def test_chunk_extensions_are_tolerated(self):
        body = b"10;foo=bar\r\nB2 Wohnungsbrand\r\n0\r\n\r\n"
        response = self._raw_request(["Transfer-Encoding: chunked"], body=body)
        self.assertEqual(self._status_of(response), 200)
        self.assertIn("B2 Wohnungsbrand", self.shown[0].text)

    def test_trailers_after_the_last_chunk_are_ignored(self):
        body = b"5\r\nHALLO\r\n0\r\nX-Spur: egal\r\n\r\n"
        response = self._raw_request(["Transfer-Encoding: chunked"], body=body)
        self.assertEqual(self._status_of(response), 200)
        self.assertIn("HALLO", self.shown[0].text)

    def test_a_malformed_chunk_header_is_rejected_not_hung(self):
        response = self._raw_request(["Transfer-Encoding: chunked"], body=b"zz\r\nmuell")
        self.assertEqual(self._status_of(response), 400)
        self.assertEqual(self.shown, [])

    def test_a_body_that_breaks_midway_keeps_what_arrived(self):
        # Halb ist mehr als nichts: was ankam, ist ein Alarm. Der Vermerk im
        # alarms.log haelt fest, dass er unvollstaendig ist — sonst saehe er
        # dort aus wie ein ganzer.
        body = b"5\r\nHALLO\r\nzz\r\nmuell"
        response = self._raw_request(["Transfer-Encoding: chunked"], body=body)
        self.assertEqual(self._status_of(response), 200)
        self.assertEqual(len(self.shown), 1)
        self.assertIn("HALLO", self.shown[0].text)
        self.assertIn("unvollstaendig", self.alarm_log.read_text(encoding="utf-8"))

    def test_a_chunked_body_is_capped_at_the_limit(self):
        # Der Ueberschuss bleibt klein: wuerde der Handler bei erreichtem
        # Deckel aufhoeren zu lesen, waehrend der Client noch viel zu senden
        # haette, liefe der Test in den Socketpuffer statt in eine Antwort.
        payload = b"x" * (listener.MAX_BODY_BYTES + 200)
        response = self._raw_request(
            ["Transfer-Encoding: chunked"], body=self._chunks(payload)
        )
        self.assertEqual(self._status_of(response), 200)
        self.assertEqual(len(self.shown), 1)
        self.assertIn("gekappt", self.alarm_log.read_text(encoding="utf-8"))

    def test_an_unsupported_transfer_encoding_is_rejected(self):
        response = self._raw_request(["Transfer-Encoding: gzip"], body=b"egal")
        self.assertEqual(self._status_of(response), 400)
        self.assertEqual(self.shown, [])


class TestReadChunked(unittest.TestCase):
    """_read_chunked ohne Socket — die Rahmenlogik allein."""

    @staticmethod
    def _reader(raw):
        return io.BufferedReader(io.BytesIO(raw))

    def test_reads_a_well_formed_body(self):
        body, status = listener._read_chunked(
            self._reader(b"5\r\nHALLO\r\n3\r\n123\r\n0\r\n\r\n"), 1024
        )
        self.assertEqual(body, b"HALLO123")
        self.assertEqual(status, "ok")

    def test_reports_a_truncated_stream_instead_of_raising(self):
        body, status = listener._read_chunked(self._reader(b"5\r\nHAL"), 1024)
        self.assertEqual(status, "kaputt")
        self.assertEqual(body, b"")

    def test_reports_a_negative_size_as_broken(self):
        body, status = listener._read_chunked(self._reader(b"-1\r\nx\r\n"), 1024)
        self.assertEqual(status, "kaputt")

    def test_an_endless_size_line_does_not_grow_without_bound(self):
        body, status = listener._read_chunked(
            self._reader(b"a" * (listener.CHUNK_LINE_MAX + 50)), 1024
        )
        self.assertEqual(status, "kaputt")
        self.assertEqual(body, b"")

    def test_stops_at_the_limit(self):
        body, status = listener._read_chunked(
            self._reader(b"a\r\n0123456789\r\n0\r\n\r\n"), 4
        )
        self.assertEqual(body, b"0123")
        self.assertEqual(status, "gekappt")

    def test_a_missing_crlf_after_a_chunk_is_broken(self):
        body, status = listener._read_chunked(self._reader(b"5\r\nHALLOxx0\r\n\r\n"), 1024)
        self.assertEqual(status, "kaputt")
        self.assertEqual(body, b"HALLO")


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


class TestCleanupBoundFile(unittest.TestCase):
    def test_removes_an_existing_file(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bound_file = pathlib.Path(tmp.name) / "bound"
        bound_file.write_text("100.64.1.2:8787\n", encoding="utf-8")
        listener._cleanup_bound_file(bound_file)
        self.assertFalse(bound_file.exists())

    def test_missing_file_is_not_an_error(self):
        # Kein try/except drumherum noetig: darf auch beim allerersten Start,
        # ohne fruehere bound-Datei, klaglos durchlaufen.
        listener._cleanup_bound_file(pathlib.Path("/nicht/vorhanden/bound"))


class TestServeBindFailure(unittest.TestCase):
    def test_an_occupied_port_is_returned_not_logged_or_raised(self):
        # serve() protokolliert den Bindfehler nicht selbst: nur der Aufrufer
        # sieht ueber die Versuche hinweg, ob sich etwas geaendert hat. Sonst
        # schriebe ein dauerhaft belegter Port alle fuenf Sekunden eine Zeile
        # in ein Protokoll, das niemand rotiert.
        blocker = socket.socket()
        self.addCleanup(blocker.close)
        blocker.bind(("127.0.0.1", 0))
        blocker.listen(1)

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bound_file = pathlib.Path(tmp.name) / "bound"
        events = []

        error = listener.serve(
            address="127.0.0.1",
            port=blocker.getsockname()[1],
            token="geheim",
            display=None,
            alarm_log=pathlib.Path(tmp.name) / "alarms.log",
            bound_file=bound_file,
            on_event=events.append,
        )

        self.assertIsInstance(error, OSError)
        self.assertEqual(events, [])
        # Eine bound-Datei waere hier die schlimmste Luege: "status" laese sie
        # als gebundenen Listener vor.
        self.assertFalse(bound_file.exists())


class TestParsePort(unittest.TestCase):
    def test_accepts_a_valid_port(self):
        self.assertEqual(listener._parse_port("8787"), 8787)

    def test_accepts_the_range_boundaries(self):
        self.assertEqual(listener._parse_port("1"), 1)
        self.assertEqual(listener._parse_port("65535"), 65535)

    def test_rejects_a_port_above_the_valid_range(self):
        with self.assertRaises(ValueError):
            listener._parse_port("99999999")

    def test_rejects_zero(self):
        with self.assertRaises(ValueError):
            listener._parse_port("0")

    def test_rejects_non_numeric_values(self):
        with self.assertRaises(ValueError):
            listener._parse_port("nicht-numerisch")


import signal
import subprocess
import sys


class TestSigtermCleanup(unittest.TestCase):
    """Prueft den SIGTERM-Pfad end-to-end in einem echten Subprozess.

    Signal-Handler sind Prozesseigenschaften, kein Thread-lokaler Zustand —
    "sende SIGTERM an einen Thread in diesem Testprozess" waere kein Test des
    tatsaechlichen Verhaltens. Ein echter Kindprozess ist deshalb kein
    Overkill, sondern der einzige ehrliche Weg. Er ruft serve() direkt mit
    einer festen Adresse auf, nicht main() ueber tailnet_address() — dieser
    Rechner hat kein laufendes Tailscale, und die SIGTERM-Frage ist unabhaengig
    davon, welche Adresse gebunden wurde.
    """

    _HARNESS = """\
import importlib.util, pathlib, signal
spec = importlib.util.spec_from_file_location("apager_listener", {listener_path!r})
listener = importlib.util.module_from_spec(spec)
spec.loader.exec_module(listener)
signal.signal(signal.SIGTERM, listener._handle_sigterm)
bound_file = pathlib.Path({bound_file!r})
listener.serve(
    address="127.0.0.1",
    port=0,
    token="geheim",
    display=None,
    alarm_log=bound_file.parent / "alarms.log",
    bound_file=bound_file,
    on_event=lambda msg: None,
)
"""

    def test_sigterm_removes_the_bound_file(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bound_file = pathlib.Path(tmp.name) / "bound"
        script = pathlib.Path(tmp.name) / "harness.py"
        script.write_text(
            self._HARNESS.format(listener_path=str(_PATH), bound_file=str(bound_file)),
            encoding="utf-8",
        )

        # Als Kontextmanager: schliesst stdout/stderr zuverlaessig, auch wenn
        # eine Assertion unten fehlschlaegt — sonst ResourceWarning je Lauf.
        with subprocess.Popen(
            [sys.executable, str(script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as proc:
            self.addCleanup(lambda: proc.poll() is None and proc.kill())

            deadline = time.time() + 5
            while not bound_file.exists() and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(bound_file.exists(), "bound-Datei wurde nicht geschrieben")

            proc.send_signal(signal.SIGTERM)
            try:
                returncode = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                self.fail("Prozess hat auf SIGTERM nicht beendet")

        self.assertEqual(returncode, 0)
        self.assertFalse(bound_file.exists(), "bound-Datei nach SIGTERM noch vorhanden")


if __name__ == "__main__":
    unittest.main()
