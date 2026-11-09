# Build against the Hyprland that pkg-config finds (Omarchy: /usr).
# --no-gnu-unique is required so the plugin can actually unload.
#
# BUILD is where objects and the .so go (bin/strata-setup builds outside the
# plugin folder: any write inside it makes the Omarchy shell reload plugins).

PLUGIN  := hypr-strata
MAKEFLAGS += -j$(shell nproc)
BUILD   ?= build
PREFIX  ?= $(or $(XDG_DATA_HOME),$(HOME)/.local/share)/strata

CXX      ?= g++
PKG      := hyprland pixman-1 libdrm lua
CXXFLAGS ?= -O2 -g
override CXXFLAGS += -std=gnu++26 -fPIC -fno-gnu-unique -Wall
override CXXFLAGS += $(shell pkg-config --cflags $(PKG))
override LDFLAGS  += -shared
LIBS     := $(shell pkg-config --libs hyprland pixman-1 libdrm)

SRC := $(wildcard src/*.cpp)
OBJ := $(patsubst src/%.cpp,$(BUILD)/obj/%.o,$(SRC))
SO  := $(BUILD)/$(PLUGIN).so

.PHONY: all install clean flags

all: $(SO)

$(BUILD)/obj/%.o: src/%.cpp src/*.hpp
	@mkdir -p "$(BUILD)/obj"
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(SO): $(OBJ)
	$(CXX) $(LDFLAGS) -o $@ $^ $(LIBS)

# Install under a fresh inode so a loaded copy is never overwritten in place.
install: $(SO)
	@mkdir -p "$(PREFIX)"
	install -m 755 $(SO) "$(PREFIX)/$(PLUGIN).so.new"
	mv -f "$(PREFIX)/$(PLUGIN).so.new" "$(PREFIX)/$(PLUGIN).so"

clean:
	rm -rf "$(BUILD)"

# Include paths and flags for clangd (editor diagnostics).
flags: compile_flags.txt
compile_flags.txt: Makefile
	@printf '%s\n' -std=gnu++26 -xc++ $(shell pkg-config --cflags $(PKG)) > $@
