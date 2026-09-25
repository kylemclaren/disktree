# disktree: build, check, and install.
#
# `make install` puts disktree.app in ~/Applications, where Spotlight and
# Finder find it and a folder can be dropped on it, and a `disktree` command
# in ~/.local/bin that runs the same app from a terminal. The default needs
# no root:
#
#   make install                        # ~/Applications/disktree.app
#   make install APPDIR=/Applications   # every user's; admins may write it
#
# `make build ARCHS="arm64 x86_64"` builds the universal app a release ships.

PREFIX ?= $(HOME)
APPDIR ?= $(PREFIX)/Applications
BINDIR ?= $(HOME)/.local/bin

SWIFT ?= swift
# Empty builds for this Mac's architecture only.
ARCHS ?=
BUILDFLAGS = -c release$(foreach arch,$(ARCHS), --arch $(arch))
APP = build/disktree.app
BINARY = $(APP)/Contents/MacOS/disktree
WRAPPER = packaging/disktree.sh
# What swift format owns: the package, and the icon script beside it.
SWIFT_FILES = Package.swift Sources Tests scripts
CORESERVICES = /System/Library/Frameworks/CoreServices.framework/Frameworks
LSREGISTER = $(CORESERVICES)/LaunchServices.framework/Support/lsregister

# The home directory unless told otherwise: `make run ARGS="--disk"`.
ARGS ?= "$(HOME)"

.PHONY: help build run install uninstall lint test ci fmt icon clean

help:
	@echo "disktree"
	@echo
	@echo "  make build       release build, bundled as $(APP)"
	@echo "  make run         build and run, scanning $$HOME (or ARGS=...)"
	@echo "  make install     install to $(APPDIR), and $(BINDIR)/disktree"
	@echo "  make uninstall   remove what install put there"
	@echo "  make lint        swift format --strict, warnings-as-errors build"
	@echo "  make test        core and app tests"
	@echo "  make ci          lint, then test"
	@echo "  make fmt         format in place"
	@echo "  make icon        redraw assets/disktree.icns from the mark"
	@echo "  make clean       swift package clean, and the bundle"

# Always ask swift build: it is incremental and knows every source file, where
# a make file-target would only compare the bundle against the manifest and
# happily install a stale build.
build:
	$(SWIFT) build $(BUILDFLAGS)
	scripts/bundle.sh \
	    "$$($(SWIFT) build $(BUILDFLAGS) --show-bin-path)/disktree" $(APP)

# The binary inside the bundle rather than `open`: this terminal keeps its
# output, and ctrl-c stops it.
run: build
	$(BINARY) $(ARGS)

# lint never fixes anything: a red local run is the same signal CI gives.
#
# swift format cannot rewrap a comment or a string, and lets a long one
# through, so the columns are counted again, in characters: in the package,
# the sources and the scripts. The tests' fixtures quote mount tables as the
# system prints them, and are left out.
lint:
	$(SWIFT) format lint --strict --recursive $(SWIFT_FILES)
	scripts/columns.sh Package.swift $$(find Sources scripts -name '*.swift')
	$(SWIFT) build --build-tests -Xswiftc -warnings-as-errors
	plutil -lint -s packaging/Info.plist packaging/entitlements.plist

# `swift test` can exit 0 with tests unfinished: anything that stops the
# main run loop from inside a test ends the runner's own loop, and it quits
# without its summary. So the summary is what counts, not the exit status.
test:
	@mkdir -p build
	@{ $(SWIFT) test 2>&1; echo $$? > build/test.status; } | tee build/test.log
	@status=$$(cat build/test.status); \
	if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
	if ! grep -Eq 'Test run with [0-9]+ tests? .*passed' build/test.log; then \
	    echo "swift test ended without its summary: not every test ran" >&2; \
	    exit 1; \
	fi

ci: lint test

fmt:
	$(SWIFT) format --in-place --recursive $(SWIFT_FILES)

# The .icns is committed, so a build never needs this; run it when the mark
# changes.
icon:
	$(SWIFT) scripts/make-icon.swift

# Removed before it is copied: ditto merges into what is there, and a file
# left over from an older bundle would break the new one's seal. Registered
# with Launch Services at once, so the Dock takes a dropped folder now rather
# than whenever macOS next looks in APPDIR.
install: build
	install -d "$(APPDIR)" "$(BINDIR)"
	rm -rf "$(APPDIR)/disktree.app"
	ditto $(APP) "$(APPDIR)/disktree.app"
	sed -e 's|@APPDIR@|$(APPDIR)|' $(WRAPPER) > "$(BINDIR)/disktree"
	chmod 755 "$(BINDIR)/disktree"
	@$(LSREGISTER) -f "$(APPDIR)/disktree.app" 2>/dev/null || true
	@echo
	@echo "installed disktree $$(cat VERSION):"
	@echo "  $(APPDIR)/disktree.app"
	@echo "  $(BINDIR)/disktree"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) \
	    echo; echo "note: $(BINDIR) is not on PATH in this shell";; esac

uninstall:
	@if [ -d "$(APPDIR)/disktree.app" ]; then \
	    $(LSREGISTER) -u "$(APPDIR)/disktree.app" 2>/dev/null || true; \
	fi
	rm -rf "$(APPDIR)/disktree.app"
	rm -f "$(BINDIR)/disktree"
	@echo "removed"

clean:
	$(SWIFT) package clean
	rm -rf build
