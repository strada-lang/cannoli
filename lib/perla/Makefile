# Build cannoli_perla.so — bridge .so for dispatching Cannoli requests
# to a Perla-compiled handler.
#
# Usage:
#   make              Build cannoli_perla.so
#   make demo         Also (re)compile Demo.pm to Demo.pm.so for the demo
#   make run          Launch cannoli wired to the Demo handler (port 8080)
#   make clean        Remove build artifacts

STRADA_DIR   ?= /home/mflickin/p/strada
STRADA_SRC    = $(STRADA_DIR)/runtime
PERLA_SRC     = $(STRADA_DIR)/perla/runtime
PERLA_RT_A    = $(PERLA_SRC)/perla_runtime.a
STRADAC       = $(STRADA_DIR)/stradac
PERLA_BIN     = $(STRADA_DIR)/perla/perla
CANNOLI_BIN   = /home/mflickin/p/cannoli/cannoli
# pcre2 is already in the cannoli binary — dlopen'd handlers resolve
# pcre2_* symbols against cannoli's global namespace. Don't pull it in
# here (libpcre2-8.a isn't -fPIC so can't link into a .so anyway).
PCRE2_FLAGS   = -DHAVE_PCRE2 -DPCRE2_STATIC -I$(STRADA_DIR)/vendor/pcre2/src

CC      = gcc
CFLAGS  = -Wall -fPIC -O0 -I$(STRADA_SRC) -I$(PERLA_SRC) $(PCRE2_FLAGS)
LDFLAGS = -shared -ldl -lm -rdynamic -lpthread

TARGET  = cannoli_perla.so

all: $(TARGET)

# Strada → C (stradac emits just C, no linking). Then gcc → .so, linked
# with the Strada runtime source AND perla_runtime.a so that dlopen'd
# Perla-compiled handlers can resolve perla_* and strada_* symbols
# against this .so. Requires the .so to be loaded RTLD_GLOBAL by
# cannoli (which it does by default).
cannoli_perla.c: cannoli_perla.strada
	$(STRADAC) cannoli_perla.strada cannoli_perla.c

# We compile the perla runtime sources directly (not the .a) because the
# prebuilt .a isn't -fPIC. Compiling from source with -fPIC here works
# and also gives the Perla DBI bridge a normal symbol surface in the .so.
$(TARGET): cannoli_perla.c perla_globals_stub.c
	$(CC) $(CFLAGS) -o $@ cannoli_perla.c perla_globals_stub.c \
	  $(STRADA_SRC)/strada_runtime.c \
	  $(PERLA_SRC)/perla_stash.c \
	  $(PERLA_SRC)/perla_dbi.c \
	  $(LDFLAGS) -lmysqlclient -Wl,--allow-multiple-definition

demo: Demo.pm
	PERLA_BUILD_PM_SO=1 $(PERLA_BIN) -M Demo.pm

run: all demo
	$(CANNOLI_BIN) \
	  --library "$(PWD)/$(TARGET):so=$(PWD)/Demo.pm.so;init=perla_mod_init_Demo;handler=perla_sub_Demo_hello" \
	  --dev --debug -p 8080

clean:
	rm -f $(TARGET) cannoli_perla.c Demo.pm.o Demo.pm.so Demo.pm.c Demo.pm.deps
