.PHONY: all build clean dev prod server client fmt themes dist coverage coverage-server coverage-client

all: build

# =============================================================================
# Debug builds (default)
# =============================================================================

build: server client

server:
	cd server && zig build

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
	cd client && NODE_ENV=production bun run build
	bun scripts/generate-embedded-assets.ts
	@echo "Client assets prepared for embedding"

# Build server with embedded client assets
dist-server-embedded:
	cd server && zig build -Doptimize=ReleaseFast
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
	rm -rf dist coverage

fmt:
	zig fmt server/src/

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
	@cd server && zig build test-bin -Doptimize=Debug
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
	rm -rf /tmp/dullahan-$(shell id -u)/*.log
	pkill -9 -x dullahan || true
	# ./server/zig-out/bin/dullahan serve --port=7682 --pty-log
	# ./server/zig-out/bin/dullahan serve --port=7682 --no-delta
	./server/zig-out/bin/dullahan serve --port=7682

prod: dist
	rm -rf /tmp/dullahan-$(shell id -u)/*.log
	pkill -9 -x dullahan || true
	./dist/dullahan serve --port=7681
