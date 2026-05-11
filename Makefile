.PHONY: all build clean dev prod server client fmt themes theme-db update-themes update-ghostty dist install coverage coverage-server coverage-client

all: build

UNAME_S := $(shell uname -s)
HAS_NIX := $(shell command -v nix-shell >/dev/null 2>&1 && echo 1)
HAS_NIX_DARWIN := $(shell command -v darwin-rebuild >/dev/null 2>&1 && echo 1)
ZIG_0152_HOME := $(firstword $(wildcard $(HOME)/zig-*-0.15.2) $(HOME)/zig-x86_64-linux-0.15.2)
ZIG_0152_BIN := $(ZIG_0152_HOME)/bin
NIX_ZIG_0152_EXPR := 'with import <nixpkgs> {}; mkShell { packages = [ ((callPackage $(CURDIR)/scripts/nix/zig {})."0.15") ]; }'

ifeq ($(UNAME_S),Darwin)
ifneq ($(HAS_NIX),)
ifneq ($(HAS_NIX_DARWIN),)
RUN_ZIG = nix-shell -E $(NIX_ZIG_0152_EXPR) --run 'env NIX_CFLAGS_COMPILE= zig
RUN_ZIG_END = '
endif
endif
endif

ifeq ($(RUN_ZIG),)
ifneq ($(HAS_NIX),)
ifeq ($(UNAME_S),Linux)
RUN_ZIG = nix-shell -p zig_0_15 --run 'env NIX_CFLAGS_COMPILE= zig
RUN_ZIG_END = '
endif
endif
endif

ifeq ($(RUN_ZIG),)
ifneq ($(wildcard $(ZIG_0152_BIN)/zig),)
RUN_ZIG = PATH="$(ZIG_0152_BIN):$(PATH)" zig
else ifneq ($(wildcard $(ZIG_0152_HOME)/zig),)
RUN_ZIG = PATH="$(ZIG_0152_HOME):$(PATH)" zig
else
RUN_ZIG = zig
endif
endif

# =============================================================================
# Debug builds (default)
# =============================================================================

build: server client

server: theme-db
	cd server && $(RUN_ZIG) build$(RUN_ZIG_END)

client: themes
	cd client && bun run build

# =============================================================================
# Distribution build (production, single binary with embedded client)
# =============================================================================

dist: dist-client-assets dist-server-embedded
	@echo ""
	@echo "Distribution build complete!"
	@echo "Single binary with embedded client: dist/dullahan"
	@ls -lh dist/dullahan

# Build client assets for embedding
dist-client-assets: themes
	cd client && bun ci
	cd client && NODE_ENV=production bun run build
	bun scripts/generate-embedded-assets.ts
	@echo "Client assets prepared for embedding"

# Build server with embedded client assets (includes theme-db for OSC color queries)
dist-server-embedded: theme-db
	cd server && $(RUN_ZIG) build -Doptimize=ReleaseFast$(RUN_ZIG_END)
	@mkdir -p dist
	cp server/zig-out/bin/dullahan dist/
	git checkout server/src/embedded_assets.zig 2>/dev/null || true
	@echo "Built dist/dullahan (server with embedded client)"

# Separate client files (if needed for CDN/separate deployment)
dist-client: themes
	@mkdir -p dist/client
	cd client && NODE_ENV=production bun run build
	cp -r client/dist/* dist/client/
	cp client/index.html dist/client/
	cp client/src/palette.css dist/client/
	cp client/src/dullahan.css dist/client/
	cp client/src/themes.css dist/client/
	@echo "Built dist/client/ (standalone web client)"

# Install to ~/bin
install: dist
	@mkdir -p ~/bin
	@if pgrep -x dullahan > /dev/null; then \
		printf "dullahan is running. Kill it? [y/N] "; \
		read ans; \
		case "$$ans" in \
			[yY]*) pkill -9 -x dullahan; echo "Killed dullahan process";; \
			*) echo "Aborted"; exit 1;; \
		esac; \
		sleep 1; \
	fi
	cp dist/dullahan ~/bin/
	@echo "Installed to ~/bin/dullahan"

# =============================================================================
# Utilities
# =============================================================================

themes:
	bun scripts/generate-themes.ts

# Generate server-side theme database (Zig source file)
# This embeds all Ghostty theme colors into the server binary for O(1) lookups
theme-db: themes
	bun scripts/generate-theme-db.ts

update-themes:
	bun scripts/update-themes.ts
	$(MAKE) theme-db

update-ghostty:
	./scripts/update-ghostty.sh

clean:
	cd server && rm -rf zig-out .zig-cache
	cd client && rm -rf dist
	rm -rf dist coverage

fmt:
	$(RUN_ZIG) fmt server/src/$(RUN_ZIG_END)

# =============================================================================
# Test coverage
# =============================================================================

coverage: coverage-server coverage-client
	@echo ""
	@echo "Coverage complete."
	@echo "  Server: Module-level test coverage shown above"
	@echo "  Client: Line-level coverage from bun shown above"

coverage-server:
	@echo "=== Server Test Coverage (Module-level) ==="
	@cd server && $(RUN_ZIG) build test-bin -Doptimize=Debug$(RUN_ZIG_END)
	@server/zig-out/bin/test 2>&1 | awk -F'[. ]' ' \
		/^[0-9]+\/[0-9]+.*\.test\..*\.\.\./ { \
			for (i=1; i<=NF; i++) { \
				if ($$(i) == "test") { module = $$(i-1); break; } \
			} \
			status = ($$NF == "OK" || $$(NF-1) == "OK") ? 1 : 0; \
			if (module != "") { \
				modules[module]++; \
				if (status) passed[module]++; \
			} \
		} \
		END { \
			print ""; \
			printf "%-20s %6s  %6s\n", "Module", "Tests", "Passed"; \
			print "------------------------------------"; \
			for (m in modules) { \
				p = (m in passed) ? passed[m] : 0; \
				printf "%-20s %6d  %6d\n", m, modules[m], p; \
				total_tests += modules[m]; \
				total_passed += p; \
			} \
			print "------------------------------------"; \
			printf "%-20s %6d  %6d\n", "TOTAL", total_tests, total_passed; \
			print ""; \
			if (total_tests > 0) printf "Pass rate: %.1f%%\n", (total_passed/total_tests)*100; \
		}'
	@echo ""
	@echo "Note: Line-level coverage requires kcov, which has limited Zig support."
	@echo "      Install kcov and run: kcov coverage/server server/zig-out/bin/test"

coverage-client:
	@mkdir -p coverage/client
	cd client && bun test --coverage
	cd protocol && bun test --coverage
	@echo "Client coverage printed above (bun built-in)"

# =============================================================================
# Run targets
# =============================================================================

dev: client server
	rm -rf /tmp/dullahan-$(shell id -u)/*.log /tmp/dullahan-$(shell id -u)/*.jsonl
	pkill -9 -x dullahan || true
	DULLAHAN_DEBUG=-all,+pane,+dsr,+clipboard \
								 ./dullahan serve \
								 --tls-cert=$(firstword $(wildcard cert/*.crt)) \
								 --tls-key=$(firstword $(wildcard cert/*.key)) \
								 --pty-log \
								 --port=7682

prod: dist
	rm -rf /tmp/dullahan-$(shell id -u)/*.log
	pkill -9 -x dullahan || true
	./dist/dullahan serve --port=7681
