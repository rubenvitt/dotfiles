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
   `0.0.0.0`. Er ermittelt die Adresse aus dem Bereich `100.64.0.0/10`
   **auf einem `utun`-Interface** — nicht über das `tailscale`-CLI, das im
   App-Store-Build blockieren kann. Findet er keine, wartet er und versucht es
   erneut, statt auf ein offenes Interface auszuweichen. In einem fremden WLAN
   lauscht so schlicht nichts.

   Das Interface ist Teil der Bedingung, nicht Beiwerk: `100.64.0.0/10` ist der
   CGNAT-Bereich der Mobilfunkanbieter. Tethert der Mac über einen Carrier mit
   CGNAT, trägt `en0` eine Adresse aus genau diesem Bereich — und steht in der
   `ifconfig`-Ausgabe vor `utun`. Eine Adressprüfung ohne Interface bände den
   Listener dann ans Mobilfunk-Interface: der Alarm vom Handy liefe ins Leere,
   während `status` gebunden und verbunden meldete. Eine Adresse aus dem
   Bereich auf einem anderen Interface wird deshalb **nicht** ersatzweise
   genommen — lieber gar nicht binden als falsch.
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

Weil das Format unbekannt ist, zeigt die erste Ausbaustufe **Body und
Query-String** des Requests, um einen Zeitstempel ergänzt. Die Header gehören
bewusst nicht dazu: sie sagen über den Einsatz nichts und schöben die Adresse
aus dem Fenster. Vollständig — Methode, Pfad, Header, Body — steht der Request
im `alarms.log`.

Der Dialogtext ist zusätzlich bei rund 2 KB gekappt, mit sichtbarem Vermerk.
Ein unbekanntes Format kann ein großer JSON-Blob sein, und eine Textwand ist
bei einem Einsatzalarm schlechter als ein Ausschnitt. Das `alarms.log` bleibt
ungekürzt.

Sobald der erste echte Alarm im Log steht, wird daraus ein Feldmapping —
Stichwort, Adresse, Meldung. Diese Erweiterung betrifft ausschließlich
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
- **Unbekannter Request-Rahmen** — `Content-Length` und `Transfer-Encoding:
  chunked` werden beide gelesen. Android-Stacks rahmen chunked, sobald die
  Länge beim Absenden noch nicht feststeht; ohne diesen Zweig käme ein leerer
  Alarm an, der Erfolg meldet. Ein unbrauchbarer Rahmen wird mit `400`
  verworfen, statt halb gelesen zu werden; ein Body, der mittendrin abreißt
  oder am Größendeckel endet, gilt als Alarm und bekommt einen Vermerk im
  `alarms.log` — ein halber Alarm darf dort nicht wie ein ganzer aussehen.
- **Unerwartete Ausnahme im Handler** — wird gefangen, protokolliert, und der
  Absender bekommt `500`. Eine Ausnahme, die bis `socketserver` durchfällt,
  hinterlässt einen Traceback in einer Datei, die niemand liest, und lässt den
  Alarm spurlos verschwinden. Diese Fehlerklasse ist deshalb strukturell
  geschlossen, nicht Fall für Fall.
- **Listener stürzt ab** — `KeepAlive` im LaunchAgent startet ihn neu. Startet
  er wegen fehlender Konfiguration wiederholt neu, unterscheidet `status` das
  über die letzte Zeile des `listener.log` von „wartet auf Tailscale“ — beide
  Zustände sahen von außen identisch aus.

## Verifikation

Die reinen Funktionen des Listeners — Adresserkennung, Tokenvergleich,
Request-Rahmen, Anzeigelogik — hängen an `tests/test_apager_listener.py`,
ausführbar mit `/usr/bin/python3 -m unittest discover -s tests`. Alles, was
Netzwerk, launchd oder Bildschirm braucht, prüft das Tool selbst.

- `apager test` schickt einen simulierten Alarm **an die tatsächlich gebundene
  Tailscale-Adresse** und zeigt den Dialog wie im Ernstfall. Damit laufen Bind,
  Quell-IP-Prüfung und Tokenvergleich wirklich mit — über Loopback wäre der
  Test grün, während genau diese drei kaputt sind.
- `apager status` beantwortet in einem Aufruf: Ist der Agent geladen, an welche
  Adresse ist der Listener tatsächlich gebunden, ist Tailscale verbunden, wann
  kam der letzte Alarm — **und wurde etwas abgewiesen**.

  Die letzte Frage ist keine Zugabe. Ein veraltetes Token (Neuinstallation,
  vertippte URL, verlorenes Zeichen beim Kopieren) lässt jeden echten Alarm mit
  `404` abprallen, während die ersten vier Zeilen grün bleiben. Eine Anzeige,
  die Gesundheit behauptet, wo keine ist, ist schlimmer als gar keine. Gezählt
  wird ab dem letzten Bind, damit die Zeile beantwortet, ob gerade etwas
  abprallt — und nicht, ob je etwas abgeprallt ist.
- `apager logs --listener` macht die Betriebsmeldungen erreichbar. Abgewiesene
  Anfragen und der Grund, warum nicht gebunden wird, stehen nur dort.
- `shellcheck` über `apager`.

**Wichtige Einschränkung:** Als verifiziert gilt die Installation erst, wenn
ein echter Request vom Handy angekommen ist. `apager test` läuft zwar über das
Tailnet, aber vom Mac aus — dass aPager auf dem Handy die URL richtig absetzt
und in welchem Format, zeigt erst der Ernstfall. `status` gibt dafür die
tatsächlich gebundene Adresse aus, nicht die konfigurierte.

## Offene Punkte

- Das Feldmapping des aPager-Payloads wird nachgezogen, sobald der erste echte
  Alarm im Log steht.
