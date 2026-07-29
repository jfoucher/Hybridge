# Watch faces bundled with the companion app (see README.md).
#
# The whole toolchain is vendored under vendor/ as git submodules:
# JerryScript 2.1.0 (the engine the watch runs — newer versions produce
# snapshots the firmware rejects) and the Fossil-HR-SDK (image_compress
# and pack).  `make deps` fetches and builds both; everything else
# assumes they are there.

VENDOR ?= vendor
JERRY_DIR ?= $(VENDOR)/jerryscript
SDK_DIR ?= $(VENDOR)/Fossil-HR-SDK

PACK := $(SDK_DIR)/tools/pack.py
# stock build: error messages off, as on the watch — this is the one
# that compiles app.js into a snapshot
JERRY_STOCK := $(JERRY_DIR)/build/bin/jerry-snapshot
# error-message build: test.py and simulate.py *run* app.js under this
# one, because a stock ReferenceError prints an empty message
JERRY_ERRMSG := $(JERRY_DIR)/build-errmsg/bin/jerry

JERRY_BUILD_FLAGS := --snapshot-exec=on --jerry-cmdline-snapshot=on \
	--profile=es5.1 --line-info=on --logging=on \
	--compile-flag=-w

# 2.1.0 is from 2020 and trips diagnostics clang has added since — e.g.
# -Wenum-enum-conversion on ecma-builtins.c. Nothing here is our code to
# fix and the version is pinned, so silence its warnings. `-w`, not
# `-Wno-error`: the build also sets `-Werror=all`/`-Werror=extra`, which a
# bare `-Wno-error` does not undo. `--compile-flag` lands last in
# CMAKE_C_FLAGS (CMakeLists.txt appends EXTERNAL_COMPILE_FLAGS at the end),
# so it wins.

# JerryScript 2.1.0 asks for `cmake_minimum_required(VERSION 2.8.12)`, and
# CMake 4 removed compatibility with anything below 3.5 — configuring dies
# before it compiles a line. Raising the floor in the submodule's twelve
# CMakeLists.txt is the entire fix; nothing else about the build changes.
JERRY_CMAKE_MIN := 3.5

.PHONY: all test build gallery clean deps check-deps patch-jerry

all: test build gallery

build: check-deps
	python3 build.py

gallery: check-deps
	python3 simulate.py --sheet=gallery.png
	cp gallery.png ..

test: check-deps
	python3 test.py

check-deps:
	@test -x $(JERRY_STOCK) && test -x $(JERRY_ERRMSG) && test -f $(PACK) \
		|| { echo "toolchain missing — run 'make deps' first"; exit 1; }

clean:
	rm -rf */build *.wapp

# --------------------------------------------------------------- deps

deps: $(PACK) $(JERRY_STOCK) $(JERRY_ERRMSG)
	python3 -m pip install crc32c pillow

$(PACK):
	git submodule update --init --recursive

# Idempotent (it only ever matches a 2.8.x floor), so re-running deps or
# re-checking out the submodule costs nothing. It does leave the submodule
# with a dirty worktree — that is expected, don't commit it upstream.
patch-jerry: | $(PACK)
	@find $(JERRY_DIR) -name CMakeLists.txt -exec perl -pi -e \
		's/cmake_minimum_required\s*\(\s*VERSION\s+2\.8[\d.]*\s*\)/cmake_minimum_required (VERSION $(JERRY_CMAKE_MIN))/' {} +

$(JERRY_STOCK): | $(PACK) patch-jerry
	cd $(JERRY_DIR) && python3 tools/build.py $(JERRY_BUILD_FLAGS) \
		--error-messages=off

$(JERRY_ERRMSG): | $(PACK) patch-jerry
	cd $(JERRY_DIR) && python3 tools/build.py $(JERRY_BUILD_FLAGS) \
		--error-messages=on \
		--builddir=$(CURDIR)/$(JERRY_DIR)/build-errmsg
