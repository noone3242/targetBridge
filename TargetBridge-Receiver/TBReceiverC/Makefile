# TBReceiver pure-C build (macOS target).
#
# Prerequisites on the iMac (Intel) running OCLP macOS 14:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   brew install ffmpeg sdl2 pkgconf
#
# Build:
#   make
#
# Run:
#   ./tbreceiver              # fullscreen
#   ./tbreceiver --windowed   # debug windowed
#
# Linux target (later): identical sources, swap LDFLAGS to pkgconf on
#   libavcodec libavutil sdl2 ; drop -framework lines.

CC       ?= clang
PKG      ?= pkgconf
APP_VERSION ?= 4.0.1
APP_BUILD   ?= dev
APP_COMMIT  ?= unknown

MACOSX_DEPLOYMENT_TARGET ?= 11.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11 -MMD -MP
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil sdl2)
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\" -DTB_RECEIVER_COMMIT=\"$(APP_COMMIT)\"
CFLAGS   += -DTB_LANGUAGE_SOURCE_DIR=\"$(abspath ../../TargetBridge-Shared/Languages)\"

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil sdl2)

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS  += -lcompression -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework Metal -framework QuartzCore
endif

C_SRC = src/main.c src/net.c src/receiver_diagnostics.c src/receiver_heartbeat.c src/receiver_teardown.c src/bc7_frame.c src/bc7_delta.c src/bc7_supercompression.c src/bc7_cursor.c src/nv12_tile_runs.c src/decoder.c src/display.c src/tb_i18n.c
OBJC_SRC = src/tb_gesture_bridge.m
OBJCXX_SRC = src/bc7_renderer.mm
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o) $(OBJCXX_SRC:.mm=.o)
DEP = $(OBJ:.o=.d)
BIN = tbreceiver

all: $(BIN)

$(BIN): $(OBJ)
	$(CXX) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

%.o: %.mm
	$(CXX) $(CFLAGS) -std=c++17 -fobjc-arc -c -o $@ $<

clean:
	rm -f $(OBJ) $(DEP) $(BIN) $(TEST_BIN)

# Unit tests for the packet parser. net.c is pure POSIX, so this needs no
# ffmpeg/SDL/pkgconf — it runs anywhere, including CI, with no hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_BIN = test_net_parser

$(TEST_BIN): tests/test_net_parser.c src/net.c src/net.h src/proto.h src/receiver_diagnostics.h src/receiver_heartbeat.c src/receiver_heartbeat.h src/receiver_teardown.c src/receiver_teardown.h src/bc7_frame.c src/bc7_frame.h src/bc7_delta.c src/bc7_delta.h src/bc7_supercompression.c src/bc7_supercompression.h src/bc7_cursor.c src/bc7_cursor.h src/nv12_tile_runs.c src/nv12_tile_runs.h src/idle_policy.h src/window_policy.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c src/receiver_diagnostics.c src/receiver_heartbeat.c src/receiver_teardown.c src/bc7_frame.c src/bc7_delta.c src/bc7_supercompression.c src/bc7_cursor.c src/nv12_tile_runs.c -lcompression -o $@

test: $(TEST_BIN)
	./$(TEST_BIN)

-include $(DEP)

.PHONY: all clean test
