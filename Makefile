.PHONY: all build clean dev server client fmt themes dist

all: build

# =============================================================================
# Debug builds (default)
# =============================================================================

build: server client

dev:
	@echo "TODO: run server and client in dev mode"

server:
	cd server && zig build

client: themes
	cd client && bun run build

# =============================================================================
# Distribution build (production)
# =============================================================================

dist: dist-server dist-client
	@echo "Distribution build complete: dist/"
	@ls -lh dist/

dist-server: themes
	@mkdir -p dist
	cd server && zig build -Doptimize=ReleaseFast
	cp server/zig-out/bin/dullahan dist/
	@echo "Built dist/dullahan (server)"

dist-client: themes
	@mkdir -p dist/client
	cd client && NODE_ENV=production bun run build
	cp -r client/dist/* dist/client/
	cp client/index.html dist/client/
	@echo "Built dist/client/ (web client)"

# =============================================================================
# Utilities
# =============================================================================

themes:
	@if [ ! -d deps/themes/ghostty ]; then \
		echo "Downloading Ghostty themes..."; \
		mkdir -p deps/themes; \
		curl -sL "https://deps.files.ghostty.org/ghostty-themes-release-20251222-150520-0add1e1.tgz" | tar xz -C deps/themes; \
	fi
	bun scripts/generate-themes.ts

clean:
	cd server && rm -rf zig-out .zig-cache
	cd client && rm -rf dist
	rm -rf dist

fmt:
	zig fmt server/src/
