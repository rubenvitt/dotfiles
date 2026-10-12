# Kalender-Helfer für den Countdown neben der Uhr, siehe next_events.swift.
#
# Bewusst nicht Teil von helpers/makefile: das läuft bei jedem Laden der
# Config, swiftc braucht Sekunden, und jeder Neubau ändert die Signatur —
# macOS fragt dann erneut nach dem Kalenderzugriff. Gebaut wird nur, wenn
# sich die Quelle ändert:
#
#   make -C ~/.config/sketchybar/helpers/calendar install
#
# Beim ersten Start fragt macOS nach dem Kalenderzugriff für
# "next_events" — erlauben. Nachträglich: Systemeinstellungen →
# Datenschutz & Sicherheit → Kalender.

LABEL  := dev.rubeen.mbar-calendar
BIN    := $(CURDIR)/bin/next_events
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG    := $(HOME)/Library/Logs/mbar-calendar.log
DOMAIN := gui/$(shell id -u)

$(BIN): next_events.swift Info.plist | bin
	swiftc -O $< -o $@ \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
	codesign -f -s - -i $(LABEL) $@

bin:
	mkdir bin

install: $(BIN)
	mkdir -p $(dir $(PLIST))
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>Label</key><string>$(LABEL)</string>' \
	  '<key>ProgramArguments</key><array><string>$(BIN)</string></array>' \
	  '<key>RunAtLoad</key><true/>' \
	  '<key>KeepAlive</key><true/>' \
	  '<key>ProcessType</key><string>Background</string>' \
	  '<key>StandardErrorPath</key><string>$(LOG)</string>' \
	  '</dict></plist>' > $(PLIST)
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	launchctl bootstrap $(DOMAIN) $(PLIST)

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	rm -f $(PLIST)

.PHONY: install uninstall
