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
