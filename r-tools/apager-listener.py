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
