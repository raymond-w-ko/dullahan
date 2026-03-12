# Dependency Update Process

## Ghostty

Update Ghostty with:

```bash
make update-ghostty
```

What it does:
- runs `scripts/update-ghostty.sh`
- updates `server/build.zig.zon` to latest `ghostty-org/ghostty` `main`
- refreshes reference checkout at `deps/ghostty/`

After update:

```bash
cd server && zig build test
cd ../client && bun run typecheck
cd .. && make build
```

Notes:
- do not edit `server/build.zig.zon` by hand for normal Ghostty bumps
- `deps/ghostty/` is reference/source checkout only; real dependency pin is `server/build.zig.zon`

## Themes

Refresh pinned Ghostty/iTerm theme bundle with:

```bash
make update-themes
```

What it does:
- queries latest `mbadolato/iTerm2-Color-Schemes` release
- pins release metadata in `scripts/theme-release.json`
- downloads `ghostty-themes.tgz`
- verifies sha256
- extracts into release-scoped cache under `deps/themes/releases/<release-tag>/ghostty`
- regenerates:
  - `client/src/themes.css`
  - `client/src/themes.ts`
  - `server/src/theme_db.zig`

Normal rebuild path:

```bash
make build
```

`make build` always regenerates from the pinned release in `scripts/theme-release.json`. It does not depend on the old mutable `deps/themes/ghostty` directory, so stale files from prior theme releases do not persist into output.

Notes:
- iTerm themes come through the same upstream theme release; no separate iTerm fetch step
- theme source/cache logic lives in `scripts/theme-source.ts`
- if theme defaults/fallback colors change, also update the fallback locations called out in `AGENTS.md`
