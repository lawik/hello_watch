# Builds priv/vibrator (see c_src/vibrator.c) through elixir_make. Under
# Nerves, CC and CFLAGS come from the target's toolchain.

PREFIX = $(MIX_APP_PATH)/priv

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra

# The program uses Linux's evdev interface; other hosts skip it.
ifeq ($(shell uname -s),Linux)
all: $(PREFIX)/vibrator
else
all:
endif

$(PREFIX)/vibrator: c_src/vibrator.c | $(PREFIX)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(PREFIX):
	mkdir -p $@

clean:
	$(RM) $(PREFIX)/vibrator

.PHONY: all clean
