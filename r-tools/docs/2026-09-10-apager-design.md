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

- aPager PRO läuft auf dem Handy und setzt den Request selbst ab. Es gibt
  keinen Server, der sendet — deshalb braucht der Mac keine öffentliche
  Erreichbarkeit und keinen Tunnel.
- **HTTPS ist Pflicht, nicht Kür.** iOS App Transport Security verbietet
  Klartext-HTTP: aPager scheitert an einer `http://`-URL mit
  `NSURLErrorDomain Code=-1022`, *bevor* eine Verbindung zustande kommt — kein
  Eintrag im Listener-Log, kein TCP-Connect, nichts. Im `listener.log` standen
  stattdessen acht rohe TLS-Handshakes gegen den Klartext-Port (`Bad request
  version '\x16\x03\x01…'`): die App hatte TLS längst versucht. Ein gültiges
  Zertifikat für den Ziel-Hostnamen ist damit Voraussetzung, nicht Zusatz.
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
| `tailscale serve --https=443` | terminiert HTTPS, lässt nur das Tailnet herein, leitet nach `127.0.0.1` weiter |
| `~/.config/apager/config` | Port und Token — außerhalb des Repos |
| `~/.local/state/apager/alarms.log` | Rohprotokoll aller eingegangenen Requests |
| `~/.local/state/apager/listener.log` | Betriebsmeldungen des Listeners |
| `docs/apager.conf.example` | Vorlage für die Config, ohne echte Werte |

`.dotfiles` ist ein öffentliches Repository. Token, Tailnet-Name und Adressen
gehören deshalb ausschließlich in die lokale Config, nie in eine versionierte
Datei.

## Netzwerk und Absicherung

**Tailscale Serve ist die Haustür, der Listener ist rein lokal.**

```
aPager (iPhone)  --HTTPS-->  Tailscale Serve  --HTTP-->  127.0.0.1:<port>
                  Tailnet     TLS + Auth                  Listener
```

Vier Maßnahmen, die zusammenwirken:

1. **Bind nur auf `127.0.0.1`.** Nie `0.0.0.0`, nie die Tailscale-Adresse, nie
   ein anderes Interface. Der Listener ist damit von *keinem* Netz aus
   erreichbar — auch nicht aus dem Tailnet. Loopback ist immer da, also gibt es
   keine Warteschleife und kein Neubinden mehr: er bindet beim Start und bleibt
   gebunden.
2. **Tailscale Serve terminiert HTTPS.** `tailscale serve --bg --https=443
   http://127.0.0.1:<port>`. Das Zertifikat ist ein echtes Let's-Encrypt-Zertifikat
   für den `*.ts.net`-Namen des Knotens, ausgestellt und erneuert von Tailscale —
   deshalb funktioniert es mit ATS, während ein selbstsigniertes es nicht täte.
   **Serve, nie Funnel.** Funnel stellte denselben Endpunkt ins öffentliche
   Internet; Serve lässt ausschließlich authentifizierte Tailnet-Gegenstellen
   herein. Die Zugangskontrolle liegt damit bei Tailscale, wo sie besser
   aufgehoben ist als in fünfzehn Zeilen Python.
3. **Token im Pfad.** Der Endpunkt lautet `/alarm/<token>`; das Token wird beim
   `install` zufällig erzeugt. aPager erlaubt keine eigenen Header, deshalb der
   Pfad. Der Vergleich läuft zeitkonstant. Das Token ist der zweite Faktor
   *hinter* der Tailnet-Authentifizierung, nicht der einzige.
4. **Quell-IP-Prüfung, umgedreht.** Früher war „aus `100.64.0.0/10`" die
   zulässige Herkunft und Loopback verboten. Heute gilt das Gegenteil: nur
   `127.0.0.1` und `::1` werden angenommen, alles andere verworfen und
   protokolliert. Bei einem Bind auf Loopback *kann* eine andere Quelle nicht
   regulär auftreten — taucht doch eine auf, läuft etwas anderes als gedacht.

### Warum das Backend nicht die eigene Tailnet-Adresse sein darf

Der naheliegende Weg — Serve auf die Adresse zeigen lassen, an der der Listener
schon hing — funktioniert nicht. Auf diesem Rechner gemessen:

| Backend | Ergebnis |
|---|---|
| `http://127.0.0.1:9999` | `HTTP 200` in 0,025 s |
| `http://<eigene-tailnet-adresse>:8787` | **Timeout nach 20 s** |

Weitergeleiteter Verkehr an die eigene Tailnet-Adresse läuft zurück durch den
Tailscale-Stack und blockiert. Das Backend **muss** Loopback sein — und damit
fällt der Grund weg, aus dem der Listener je an die Tailscale-Adresse band.

### Was dadurch entfallen ist

Die Adresssuche über `ifconfig`, die Bevorzugung von `utun`-Interfaces, die
CGNAT-Bereichsprüfung und die Warte- und Neubinde-Schleife sind **ersatzlos
gestrichen**. Sie beantworteten die Frage „welche Tailscale-Adresse gehört mir
gerade", und die stellt sich nicht mehr. Eine ungenutzte Funktion „für alle
Fälle" wäre hier keine Reserve, sondern ein zweiter, unerprobter Bindpfad neben
dem einzigen, der laufen soll.

`apager status` fragt weiterhin nach der Tailscale-Adresse — dort über
`ifconfig` im Dispatcher, und als *Diagnose*, nicht als Urteil: sie
unterscheidet, ob eine rote HTTPS-Zeile an Tailscale, an Serve oder am Listener
liegt.

### Zugabe: Serve sagt, wer geklopft hat

Serve reicht die Identität der Gegenstelle als Header durch
(`Tailscale-User-Login`, `X-Forwarded-For`, `X-Forwarded-Proto`). Sie landen
über den Rohmitschnitt im `alarms.log`. Das war kein Ziel des Umbaus, ist aber
mehr, als die alte Quell-IP-Prüfung je wusste.

## Datenfluss

1. Alarm auf dem Handy, aPager sendet an `https://<knoten>.<tailnet>.ts.net/alarm/<token>`.
2. Tailscale Serve terminiert TLS, prüft die Tailnet-Zugehörigkeit und leitet
   nach `http://127.0.0.1:<port>` weiter.
3. Listener prüft Quell-IP (nur Loopback) und Token. Bei Fehlschlag: Eintrag ins
   Log, `404`.
4. Der vollständige Request — Methode, Pfad, Header, Body — wird mit Zeitstempel
   nach `alarms.log` geschrieben. Das geschieht **vor** der Anzeige, damit ein
   Fehler in der Darstellung den Alarm nicht verschluckt.
5. Der Listener fügt den Alarm seiner Liste offener Alarme hinzu.
6. Anzeige öffnen oder aktualisieren (siehe unten).
7. Quittieren leert die Liste.

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

- **Serve fehlt oder zeigt aufs falsche Backend** — der Listener läuft, bindet
  und empfängt nie etwas. Von innen ist das nicht zu sehen; `apager status`
  liest deshalb die Serve-Konfiguration und vergleicht das Backend mit dem
  konfigurierten Port.
- **Tailscale unten** — Serve nimmt nichts an, HTTPS läuft ins Leere. Der
  Listener merkt davon nichts und muss es auch nicht: er bindet weiter auf
  Loopback und ist sofort wieder da, wenn Tailscale zurückkommt.
- **Port belegt** — Meldung ins Log, Prozess endet mit Rückgabewert 1.
  `KeepAlive` startet neu. Bewusst kein stilles Weiterversuchen in einer
  Schleife: ein belegter Loopback-Port ist ein anhaltender Zustand, und ein
  Prozess, der endlos wartet, sieht von außen aus wie einer, der läuft. Der
  Preis ist eine wiederkehrende Fehlerzeile im `listener.log` — genau die,
  die `status` als letzte Zeile vorliest.
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
  er wegen fehlender Konfiguration oder eines belegten Ports wiederholt neu,
  steht der Grund in der letzten Zeile des `listener.log`, die `status`
  vorliest.

## Verifikation

Die reinen Funktionen des Listeners — Herkunftsprüfung, Tokenvergleich,
Request-Rahmen, Anzeigelogik — hängen an `tests/test_apager_listener.py`,
ausführbar mit `/usr/bin/python3 -m unittest discover -s tests`. Alles, was
Netzwerk, launchd oder Bildschirm braucht, prüft das Tool selbst.

- `apager test` schickt einen simulierten Alarm **über HTTPS an den eigenen
  `ts.net`-Namen**, also durch Serve — denselben Weg, den aPager nimmt. Zwei
  Stufen, und die Reihenfolge ist der Punkt: erst über Loopback prüfen, ob der
  Listener lebt, dann über HTTPS. Scheitert die zweite Stufe nach einer
  gelungenen ersten, liegt es an Serve oder Tailscale und nicht am Listener.
- `apager status` beantwortet in einem Aufruf: Ist der Agent geladen, ist der
  Listener gebunden, **steht Serve davor und kommt HTTPS wirklich durch**, ist
  Tailscale verbunden, wann kam der letzte Alarm — **und wurde etwas
  abgewiesen**.

  Die HTTPS-Zeile ist die einzige, die die ganze Kette anfasst: eine echte
  Anfrage an `https://<knoten>.<tailnet>.ts.net/healthz`, durch TLS, Serve und
  Weiterleitung bis zum antwortenden Listener. Der Listener beantwortet diesen
  Pfad mit `204` **ohne Token und ohne eine Zeile zu schreiben** — vor dem
  Tokenvergleich. Andernfalls zählte jede Statusabfrage als abgewiesene Anfrage
  und verdärbe genau die Zahl, an der ein veraltetes Token auffliegt: eine
  Anzeige, die ihr eigenes Nachsehen als Störung protokolliert, ist schlimmer
  als gar keine.

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
ein echter Request vom Handy angekommen ist. `apager test` läuft zwar über
HTTPS durch Serve, aber vom Mac aus — dass aPager auf dem Handy die URL richtig
absetzt und in welchem Format, zeigt erst der Ernstfall. Die Kette bis zum
Listener ist damit bewiesen, die App auf dem Handy nicht.

## Offene Punkte

- Das Feldmapping des aPager-Payloads wird nachgezogen, sobald der erste echte
  Alarm im Log steht.
