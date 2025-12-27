.PHONY: all build clean dev server client

all: build

build: server client

dev:
	@echo "TODO: run server and client in dev mode"

server:
	cd server && zig build

client:
	cd client && npm run build

clean:
	cd server && zig build --clean || true
	cd client && rm -rf dist
