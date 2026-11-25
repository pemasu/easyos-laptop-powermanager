CC      ?= gcc
CFLAGS  ?= -O2 -Wall
PKGS     = gtk+-2.0
PREFIX  ?= /usr/local
SBINDIR  = /usr/sbin
BINNAME  = vpower
DESKTOP  = Easy-laptop-power-manager.desktop

vpower: vpower.c engine.h
	$(CC) $(CFLAGS) -o $@ vpower.c `pkg-config --cflags --libs $(PKGS)`
	strip $@

engine.h: vpower-engine.sh gen-engine.sh
	sh ./gen-engine.sh

install: vpower
	install -d $(SBINDIR) /usr/share/applications
	install -m 755 vpower $(SBINDIR)/$(BINNAME)
	install -m 644 $(DESKTOP) /usr/share/applications/$(DESKTOP)
	-fixmenus 2>/dev/null; jwm -reload 2>/dev/null; true

uninstall:
	rm -f $(SBINDIR)/$(BINNAME)
	rm -f /usr/share/applications/$(DESKTOP)
	-fixmenus 2>/dev/null; jwm -reload 2>/dev/null; true

clean:
	rm -f vpower engine.h

.PHONY: install uninstall clean
