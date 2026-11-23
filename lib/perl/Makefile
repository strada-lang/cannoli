# Makefile for the Cannoli Perl dispatch library
#
# Builds cannoli_perl.so: the Strada side (cannoli_perl.strada) and the
# embedded-interpreter bridge (perl_bridge.c) in one shared object.
#
#   make                 build
#   make test            build and run t/test_perl.sh against ../../cannoli
#   make PERL=/usr/bin/perl   embed a different perl
#   make clean

# Paths
STRADA_ROOT ?= /usr/local
STRADA_RUNTIME = $(STRADA_ROOT)/lib/strada/runtime
STRADAC = $(STRADA_ROOT)/bin/stradac

# Perl interpreter to embed. Defaults to the bzperl build when it is
# installed (so the library links /opt/bzperl's libperl, matching the
# bizowie runtime), otherwise the perl on PATH.
PERL ?= $(shell test -x /opt/bzperl/bin/perl && echo /opt/bzperl/bin/perl || echo perl)

PERL_CCOPTS := $(shell $(PERL) -MExtUtils::Embed -e ccopts 2>/dev/null)
PERL_LDOPTS := $(shell $(PERL) -MExtUtils::Embed -e ldopts 2>/dev/null)

CC = gcc
CFLAGS = -Wall -Wextra -fPIC -O2
TARGET = cannoli_perl.so

.PHONY: all clean test check-perl check-strada

all: check-perl check-strada $(TARGET)

check-perl:
	@$(PERL) -MExtUtils::Embed -e 'print "Perl: $$^V ($(PERL))\n"' 2>/dev/null || \
		(echo "Error: Perl development headers not found for $(PERL). Install libperl-dev / the matching -dev headers"; exit 1)

check-strada:
	@test -f $(STRADAC) || (echo "Error: Strada compiler not found at $(STRADAC)"; exit 1)

# The interpreter bridge: plain C against the Perl headers only
perl_bridge.o: perl_bridge.c perl_bridge.h
	$(CC) $(CFLAGS) $(PERL_CCOPTS) -c -o $@ perl_bridge.c

# The Strada side: Strada -> C -> object, against the Strada runtime only
cannoli_perl_strada.c: cannoli_perl.strada
	$(STRADAC) $< $@

cannoli_perl_strada.o: cannoli_perl_strada.c perl_bridge.h
	$(CC) -fPIC -O2 -w -I$(STRADA_RUNTIME) -I. -c -o $@ cannoli_perl_strada.c

$(TARGET): cannoli_perl_strada.o perl_bridge.o
	$(CC) -shared -o $@ cannoli_perl_strada.o perl_bridge.o $(PERL_LDOPTS) -ldl -lm
	@echo "Built: $(TARGET)"
	@echo "Usage: cannoli --library $(CURDIR)/$(TARGET):script=app.pl;handler=MyApp::handle"

test: all
	bash ../../t/test_perl.sh

clean:
	rm -f $(TARGET) libperl_bridge.so cannoli_perl_strada.c *.o
