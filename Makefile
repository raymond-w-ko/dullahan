.PHONY: all build clean dev server client fmt themes

all: build

build: server client

dev:
	@echo "TODO: run server and client in dev mode"

server:
	cd server && zig build

client: themes
	cd client && bun run build

themes:
	@if [ ! -d deps/themes/ghostty ]; then \
		echo "Downloading Ghostty themes..."; \
		mkdir -p deps/themes; \
		curl -sL "https://deps.files.ghostty.org/ghostty-themes-release-20251222-150520-0add1e1.tgz" | tar xz -C deps/themes; \
	fi
	bun scripts/generate-themes.ts

clean:
	cd server && zig build --clean || true
	cd client && rm -rf dist

fmt:
	zig fmt server/src/
