# apager — aPager-Alarme auf dem Mac anzeigen

Datum: 2026-09-10

## Zweck und Abgrenzung

`apager` nimmt den Webhook entgegen, den aPager PRO auf dem Handy bei einem
Einsatzalarm absetzt, und zeigt den Alarm auf dem Mac an.

Der Mac ist dabei **Anzeigefläche, nicht Alarmierung**. Alarmiert wird über das
Handy. Das Tool macht bewusst keinen Ton, schickt keine Benachrichtigung und
weckt den Rechner nicht. Schläft der Mac oder sitzt niemand davor, geht der
Alarm auf diesem Weg verloren — das ist kein Fehler, sondern die Abgrenzung.
Der Nutzen liegt darin, den Einsatz am Rechner sofort lesen zu können, ohne
zum Handy zu greifen.

Nicht Teil dieses Entwurfs: Quittierung Richtung Leitstelle, Rückmeldung,
Statusabfragen, Alarmhistorie über das Logfile hinaus.

## Ausgangslage

- aPager PRO läuft auf dem Handy und setzt den HTTP-Request selbst ab. Es gibt
  keinen Server, der sendet — deshalb braucht der Mac keine öffentliche
  Erreichbarkeit, kein Zertifikat und keinen Tunnel.
- Handy und Mac hängen im selben Tailnet. Der Request läuft über Tailscale.
- Das Payload-Format ist in aPager **nicht konfigurierbar** und derzeit
  unbekannt. Der Listener muss deshalb formatagnostisch starten.
- macOS, Zielrechner ist der Arbeits-Mac. `/usr/bin/python3` (3.9.6) ist
  vorhanden; die mise-verwalteten Python-Versionen werden bewusst gemieden,
  weil ein LaunchAgent sonst beim nächsten Versionswechsel stillsteht.

## Architektur

Zwei Prozesse mit klarer Trennung:

- **Listener** — langlebig, unter launchd. Nimmt Requests an, prüft Herkunft
  und Token, protokolliert den Rohinhalt und ruft die Anzeige auf. Er enthält
  keine Darstellungslogik.
- **Anzeige** — kurzlebig, via `osascript`. Zeigt die offenen Alarme und wird
  durch Quittieren beendet. Sie enthält keine Netzwerklogik.

Dazwischen liegt ein schmaler Vertrag: Der Listener übergibt der Anzeige einen
fertig formatierten Text und bekommt zurück, ob quittiert wurde. Dadurch lässt
sich die Anzeige ohne Netzwerk testen und der Listener ohne Bildschirm.

## Komponenten

| Datei | Aufgabe |
|---|---|
| `r-tools/apager` | Dispatcher: `install`, `uninstall`, `status`, `test`, `logs`, `url` |
| `r-tools/apager-listener.py` | HTTP-Listener, `/usr/bin/python3`, nur Standardbibliothek |
| `~/Library/LaunchAgents/email.rubeen.apager.plist` | hält den Listener am Leben, startet ihn beim Login |
| `~/.config/apager/config` | Port und Token — außerhalb des Repos |
| `~/.local/state/apager/alarms.log` | Rohprotokoll aller eingegangenen Requests |
| `~/.local/state/apager/listener.log` | Betriebsmeldungen des Listeners |
| `docs/apager.conf.example` | Vorlage für die Config, ohne echte Werte |

`.dotfiles` ist ein öffentliches Repository. Token, Tailnet-Name und Adressen
gehören deshalb ausschließlich in die lokale Config, nie in eine versionierte
Datei.

## Netzwerk und Absicherung

Der Endpunkt ist unverschlüsseltes HTTP. Innerhalb des Tailnets ist der
Transport bereits verschlüsselt; nach außen darf der Port gar nicht erst
sichtbar werden. Drei Maßnahmen, die zusammenwirken:

1. **Bind nur auf die Tailscale-Adresse.** Der Listener bindet nie auf
   `0.0.0.0`. Er ermittelt die Adresse aus dem CGNAT-Bereich `100.64.0.0/10`
   auf den lokalen Interfaces — nicht über das `tailscale`-CLI, das im
   App-Store-Build blockieren kann. Findet er keine, wartet er und versucht es
   erneut, statt auf ein offenes Interface auszuweichen. In einem fremden WLAN
   lauscht so schlicht nichts.
2. **Token im Pfad.** Der Endpunkt lautet `/alarm/<token>`; das Token wird beim
   `install` zufällig erzeugt. aPager erlaubt keine eigenen Header, deshalb der
   Pfad. Der Vergleich läuft zeitkonstant.
3. **Quell-IP-Prüfung.** Requests, deren Absender nicht aus `100.64.0.0/10`
   stammt, werden verworfen und protokolliert.

Fällt Tailscale aus, bindet der Listener nicht neu auf ein anderes Interface,
sondern wartet. Ändert sich die Tailscale-Adresse, bindet er auf die neue.

## Datenfluss

1. Alarm auf dem Handy, aPager sendet an `http://<tailscale-adresse>:<port>/alarm/<token>`.
2. Listener prüft Quell-IP und Token. Bei Fehlschlag: Eintrag ins Log, `404`.
3. Der vollständige Request — Methode, Pfad, Header, Body — wird mit Zeitstempel
   nach `alarms.log` geschrieben. Das geschieht **vor** der Anzeige, damit ein
   Fehler in der Darstellung den Alarm nicht verschluckt.
4. Der Listener fügt den Alarm seiner Liste offener Alarme hinzu.
5. Anzeige öffnen oder aktualisieren (siehe unten).
6. Quittieren leert die Liste.

## Anzeigeverhalten

Solange kein Alarm offen ist, läuft keine Anzeige. Beim ersten Alarm startet
der Listener `osascript` als Unterprozess und merkt sich dessen PID.

Trifft ein weiterer Alarm ein, während die Anzeige offen ist, beendet der
Listener den laufenden Dialog und öffnet einen neuen, der **alle** offenen
Alarme untereinander zeigt, der jüngste oben. Ein Dialog pro Zeitpunkt, kein
Fensterstapel. Quittieren gilt für alle gezeigten Alarme gemeinsam.

Weil das Format unbekannt ist, zeigt die erste Ausbaustufe den gesamten
lesbaren Inhalt des Requests, lediglich um Zeitstempel ergänzt. Sobald der
erste echte Alarm im Log steht, wird daraus ein Feldmapping — Stichwort,
Adresse, Meldung. Diese Erweiterung betrifft ausschließlich
`apager-listener.py`; Dispatcher, LaunchAgent und Anzeigepfad bleiben unberührt.

## Fehlerbehandlung

Das Fehlerbild, auf das es hier ankommt, ist der stille Ausfall: ein Alarm, der
nicht ankommt, ohne dass es jemandem auffällt.

- **Keine Tailscale-Adresse** — der Listener wartet in einer Schleife und
  protokolliert jeden Zustandswechsel genau einmal, nicht bei jedem Versuch. Er
  beendet sich nicht.
- **Port belegt** — Meldung ins Log, erneuter Versuch nach Wartezeit.
- **Anzeige schlägt fehl** — Meldung ins Log. Der Alarm steht bereits in
  `alarms.log` und ist über `apager logs` nachlesbar. Ein Ausweichen auf
  Benachrichtigung oder Ton findet nicht statt: Beide Kanäle wurden bewusst
  abgewählt, und sie hier durch die Hintertür einzuführen wäre irreführend.
- **Unbekanntes oder unlesbares Payload-Format** — Rohbytes werden
  fehlertolerant dekodiert und angezeigt, statt eine Ausnahme auszulösen.
- **Listener stürzt ab** — `KeepAlive` im LaunchAgent startet ihn neu.

## Verifikation

Das Repository hat kein Testframework; die Prüfung läuft wie bei den übrigen
Werkzeugen über das Tool selbst.

- `apager test` schickt einen simulierten Alarm über die Loopback-Schnittstelle
  und zeigt den Dialog wie im Ernstfall. Damit sind Formatierung, Anzeige und
  Quittierung geprüft.
- `apager status` beantwortet in einem Aufruf: Ist der Agent geladen, an welche
  Adresse ist der Listener tatsächlich gebunden, ist Tailscale verbunden, wann
  kam der letzte Alarm.
- `shellcheck` über `apager`.

**Wichtige Einschränkung:** `apager test` läuft über Loopback und prüft damit
gerade jene drei Dinge *nicht*, die am ehesten unbemerkt brechen — Bind auf die
Tailnet-Adresse, Quell-IP-Prüfung und Tokenvergleich. Als verifiziert gilt die
Installation erst, wenn ein echter Request vom Handy angekommen ist. `status`
muss dafür die tatsächlich gebundene Adresse ausgeben, nicht die konfigurierte.

## Offene Punkte

- Das Feldmapping des aPager-Payloads wird nachgezogen, sobald der erste echte
  Alarm im Log steht.
