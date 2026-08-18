all:
	(cd event_providers && $(MAKE)) >/dev/null
	(cd menus && $(MAKE)) >/dev/null
# Bei restriktiver umask legt clang die Binaries ohne x-Bit an; sketchybar
# scheitert dann mit "Permission denied" beim Start der Event-Provider.
	chmod +x event_providers/*/bin/* menus/bin/*
