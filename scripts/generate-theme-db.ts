#!/usr/bin/env bun
/**
 * Generate Zig theme database from Ghostty themes
 *
 * Parses Ghostty theme files and generates a Zig source file with a
 * StaticStringMap for O(1) theme lookups at runtime.
 *
 * Usage: bun scripts/generate-theme-db.ts
 * Output: server/src/theme_db.zig
 */

import { readdir, readFile, writeFile } from "fs/promises";
import { join } from "path";

const THEMES_DIR = "deps/themes/ghostty";
const OUTPUT_FILE = "server/src/theme_db.zig";

interface ThemeColors {
  name: string;
  fg: [number, number, number];
  bg: [number, number, number];
  cursorFg?: [number, number, number];
  cursorBg?: [number, number, number];
  selectionFg?: [number, number, number];
  selectionBg?: [number, number, number];
  palette: ([number, number, number] | null)[];
}

/** Parse hex color "#rrggbb" to [r, g, b] array */
function parseHexColor(color: string): [number, number, number] | null {
  const match = color.match(/^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/);
  if (!match) return null;
  return [
    parseInt(match[1]!, 16),
    parseInt(match[2]!, 16),
    parseInt(match[3]!, 16),
  ];
}

/** Convert theme name to CSS selector (same as generate-themes.ts) */
function themeToCssSelector(name: string): string {
  return name
    .toLowerCase()
    .replace(/\+/g, "-plus")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

/** Parse a Ghostty theme file */
function parseTheme(name: string, content: string): ThemeColors | null {
  const palette: ([number, number, number] | null)[] = new Array(16).fill(null);
  let fg: [number, number, number] | null = null;
  let bg: [number, number, number] | null = null;
  let cursorFg: [number, number, number] | undefined;
  let cursorBg: [number, number, number] | undefined;
  let selectionFg: [number, number, number] | undefined;
  let selectionBg: [number, number, number] | undefined;

  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const match = trimmed.match(/^([a-z-]+)\s*=\s*(.+)$/i);
    if (!match) continue;

    const [, key, value] = match;
    const color = value!.trim();

    switch (key) {
      case "foreground": {
        const parsed = parseHexColor(color);
        if (parsed) fg = parsed;
        break;
      }
      case "background": {
        const parsed = parseHexColor(color);
        if (parsed) bg = parsed;
        break;
      }
      case "cursor-text": {
        const parsed = parseHexColor(color);
        if (parsed) cursorFg = parsed;
        break;
      }
      case "cursor-color": {
        const parsed = parseHexColor(color);
        if (parsed) cursorBg = parsed;
        break;
      }
      case "selection-foreground": {
        const parsed = parseHexColor(color);
        if (parsed) selectionFg = parsed;
        break;
      }
      case "selection-background": {
        const parsed = parseHexColor(color);
        if (parsed) selectionBg = parsed;
        break;
      }
      case "palette": {
        // Parse "N=COLOR" format
        const paletteMatch = color.match(/^(\d+)=(.+)$/);
        if (paletteMatch) {
          const index = parseInt(paletteMatch[1]!, 10);
          if (index >= 0 && index <= 15) {
            const parsed = parseHexColor(paletteMatch[2]!);
            if (parsed) palette[index] = parsed;
          }
        }
        break;
      }
    }
  }

  // Require at least fg and bg
  if (!fg || !bg) {
    console.warn(`Theme "${name}" missing fg or bg, skipping`);
    return null;
  }

  return {
    name: themeToCssSelector(name),
    fg,
    bg,
    cursorFg,
    cursorBg,
    selectionFg,
    selectionBg,
    palette,
  };
}

/** Format RGB array as Zig array literal */
function formatRgb(rgb: [number, number, number]): string {
  return `.{ 0x${rgb[0].toString(16).padStart(2, "0")}, 0x${rgb[1].toString(16).padStart(2, "0")}, 0x${rgb[2].toString(16).padStart(2, "0")} }`;
}

/** Format optional RGB as Zig optional */
function formatOptionalRgb(rgb: [number, number, number] | undefined | null): string {
  return rgb ? formatRgb(rgb) : "null";
}

/** Format palette array as Zig array literal */
function formatPalette(palette: ([number, number, number] | null)[]): string {
  const entries = palette.map((c) => (c ? formatRgb(c) : ".{ 0, 0, 0 }"));
  return `.{ ${entries.join(", ")} }`;
}

/** Generate Zig source file */
function generateZigSource(themes: ThemeColors[]): string {
  const lines: string[] = [];

  lines.push("//! Auto-generated theme database from Ghostty themes");
  lines.push("//! Do not edit manually. Run: bun scripts/generate-theme-db.ts");
  lines.push("//!");
  lines.push(`//! Theme count: ${themes.length}`);
  lines.push("");
  lines.push("const std = @import(\"std\");");
  lines.push("");
  lines.push("/// Theme colors for OSC 10/11/4 queries");
  lines.push("pub const ThemeColors = struct {");
  lines.push("    fg: [3]u8,");
  lines.push("    bg: [3]u8,");
  lines.push("    cursor_fg: ?[3]u8,");
  lines.push("    cursor_bg: ?[3]u8,");
  lines.push("    selection_fg: ?[3]u8,");
  lines.push("    selection_bg: ?[3]u8,");
  lines.push("    palette: [16][3]u8,");
  lines.push("");
  lines.push("    /// Create theme colors with only fg/bg (for custom themes)");
  lines.push("    pub fn fromFallback(fg: ?[3]u8, bg: ?[3]u8) ThemeColors {");
  lines.push("        return .{");
  lines.push("            .fg = fg orelse default_fg,");
  lines.push("            .bg = bg orelse default_bg,");
  lines.push("            .cursor_fg = null,");
  lines.push("            .cursor_bg = null,");
  lines.push("            .selection_fg = null,");
  lines.push("            .selection_bg = null,");
  lines.push("            .palette = default_palette,");
  lines.push("        };");
  lines.push("    }");
  lines.push("};");
  lines.push("");
  lines.push("/// Default foreground color (Atom One Dark fg)");
  lines.push("pub const default_fg: [3]u8 = .{ 0xab, 0xb2, 0xbf };");
  lines.push("");
  lines.push("/// Default background color (Atom One Dark bg)");
  lines.push("pub const default_bg: [3]u8 = .{ 0x21, 0x25, 0x2b };");
  lines.push("");
  lines.push("/// Default ANSI palette (xterm colors)");
  lines.push("pub const default_palette: [16][3]u8 = .{");
  lines.push("    .{ 0x00, 0x00, 0x00 }, // 0 black");
  lines.push("    .{ 0xcd, 0x00, 0x00 }, // 1 red");
  lines.push("    .{ 0x00, 0xcd, 0x00 }, // 2 green");
  lines.push("    .{ 0xcd, 0xcd, 0x00 }, // 3 yellow");
  lines.push("    .{ 0x00, 0x00, 0xee }, // 4 blue");
  lines.push("    .{ 0xcd, 0x00, 0xcd }, // 5 magenta");
  lines.push("    .{ 0x00, 0xcd, 0xcd }, // 6 cyan");
  lines.push("    .{ 0xe5, 0xe5, 0xe5 }, // 7 white");
  lines.push("    .{ 0x7f, 0x7f, 0x7f }, // 8 bright black");
  lines.push("    .{ 0xff, 0x00, 0x00 }, // 9 bright red");
  lines.push("    .{ 0x00, 0xff, 0x00 }, // 10 bright green");
  lines.push("    .{ 0xff, 0xff, 0x00 }, // 11 bright yellow");
  lines.push("    .{ 0x5c, 0x5c, 0xff }, // 12 bright blue");
  lines.push("    .{ 0xff, 0x00, 0xff }, // 13 bright magenta");
  lines.push("    .{ 0x00, 0xff, 0xff }, // 14 bright cyan");
  lines.push("    .{ 0xff, 0xff, 0xff }, // 15 bright white");
  lines.push("};");
  lines.push("");
  lines.push("/// Theme lookup table (compile-time hash map)");
  lines.push("pub const themes = std.StaticStringMap(ThemeColors).initComptime(.{");

  for (const theme of themes) {
    const cursorFg = formatOptionalRgb(theme.cursorFg);
    const cursorBg = formatOptionalRgb(theme.cursorBg);
    const selectionFg = formatOptionalRgb(theme.selectionFg);
    const selectionBg = formatOptionalRgb(theme.selectionBg);
    const palette = formatPalette(theme.palette.map((c) => c ?? [0, 0, 0]) as [number, number, number][]);

    // Use explicit ThemeColors{...} to help Zig's type inference
    lines.push(`    .{ "${theme.name}", ThemeColors{`);
    lines.push(`        .fg = ${formatRgb(theme.fg)},`);
    lines.push(`        .bg = ${formatRgb(theme.bg)},`);
    lines.push(`        .cursor_fg = ${cursorFg},`);
    lines.push(`        .cursor_bg = ${cursorBg},`);
    lines.push(`        .selection_fg = ${selectionFg},`);
    lines.push(`        .selection_bg = ${selectionBg},`);
    lines.push(`        .palette = ${palette},`);
    lines.push("    } },");
  }

  lines.push("});");
  lines.push("");
  lines.push("/// Look up theme colors by name");
  lines.push("pub fn get(name: []const u8) ?ThemeColors {");
  lines.push("    return themes.get(name);");
  lines.push("}");
  lines.push("");
  lines.push("test \"theme lookup\" {");
  lines.push('    // Test a known theme');
  lines.push('    const dracula = get("dracula");');
  lines.push("    try std.testing.expect(dracula != null);");
  lines.push("    try std.testing.expectEqual(@as(u8, 0xf8), dracula.?.fg[0]);");
  lines.push("");
  lines.push('    // Test unknown theme');
  lines.push('    const unknown = get("not-a-real-theme");');
  lines.push("    try std.testing.expect(unknown == null);");
  lines.push("}");
  lines.push("");

  return lines.join("\n");
}

async function main() {
  console.log(`Reading themes from ${THEMES_DIR}...`);

  const files = await readdir(THEMES_DIR);
  console.log(`Found ${files.length} theme files`);

  const themes: ThemeColors[] = [];

  for (const file of files.sort()) {
    try {
      const content = await readFile(join(THEMES_DIR, file), "utf-8");
      const theme = parseTheme(file, content);
      if (theme) {
        themes.push(theme);
      }
    } catch (e) {
      console.error(`Error parsing ${file}:`, e);
    }
  }

  console.log(`Parsed ${themes.length} themes successfully`);

  const zigSource = generateZigSource(themes);
  await writeFile(OUTPUT_FILE, zigSource);

  console.log(`Written ${OUTPUT_FILE}`);
  console.log(`File size: ${(zigSource.length / 1024).toFixed(1)} KB`);
}

main().catch(console.error);
