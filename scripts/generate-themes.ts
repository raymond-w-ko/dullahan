#!/usr/bin/env bun
/**
 * Convert Ghostty themes to CSS
 * 
 * Usage: bun scripts/generate-themes.ts
 * Output: client/src/themes.css
 */

import { readdir, readFile, writeFile } from "fs/promises";
import { join } from "path";

const THEMES_DIR = "deps/themes/ghostty";
const OUTPUT_FILE = "client/src/themes.css";

interface Theme {
  name: string;
  background?: string;
  foreground?: string;
  cursorColor?: string;
  cursorText?: string;
  selectionBackground?: string;
  selectionForeground?: string;
  palette: Map<number, string>;
}

function parseTheme(name: string, content: string): Theme {
  const theme: Theme = {
    name,
    palette: new Map(),
  };

  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const match = trimmed.match(/^([a-z-]+)\s*=\s*(.+)$/i);
    if (!match) continue;

    const [, key, value] = match;
    const color = value.trim();

    switch (key) {
      case "background":
        theme.background = color;
        break;
      case "foreground":
        theme.foreground = color;
        break;
      case "cursor-color":
        theme.cursorColor = color;
        break;
      case "cursor-text":
        theme.cursorText = color;
        break;
      case "selection-background":
        theme.selectionBackground = color;
        break;
      case "selection-foreground":
        theme.selectionForeground = color;
        break;
      case "palette":
        // Parse "N=COLOR" format
        const paletteMatch = color.match(/^(\d+)=(.+)$/);
        if (paletteMatch) {
          const index = parseInt(paletteMatch[1], 10);
          theme.palette.set(index, paletteMatch[2]);
        }
        break;
    }
  }

  return theme;
}

function themeToCssSelector(name: string): string {
  // Convert theme name to valid CSS selector
  // "Catppuccin Mocha" -> "catppuccin-mocha"
  // "Dracula+" -> "dracula-plus"
  return name
    .toLowerCase()
    .replace(/\+/g, "-plus")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function themeToCSS(theme: Theme): string {
  const selector = themeToCssSelector(theme.name);
  const vars: string[] = [];

  // Use variable names that match dullahan.css
  if (theme.background) vars.push(`  --term-bg: ${theme.background};`);
  if (theme.foreground) vars.push(`  --term-fg: ${theme.foreground};`);
  if (theme.cursorColor) vars.push(`  --term-cursor-bg: ${theme.cursorColor};`);
  if (theme.cursorText) vars.push(`  --term-cursor-fg: ${theme.cursorText};`);
  if (theme.selectionBackground) vars.push(`  --term-selection-bg: ${theme.selectionBackground};`);
  if (theme.selectionForeground) vars.push(`  --term-selection-fg: ${theme.selectionForeground};`);

  // Add palette colors (0-15 are the standard ANSI colors)
  // Use --c0 through --c15 to match dullahan.css variable names
  for (let i = 0; i <= 15; i++) {
    const color = theme.palette.get(i);
    if (color) {
      vars.push(`  --c${i}: ${color};`);
    }
  }

  return `[data-theme="${selector}"] {\n${vars.join("\n")}\n}`;
}

async function main() {
  console.log(`Reading themes from ${THEMES_DIR}...`);
  
  const files = await readdir(THEMES_DIR);
  console.log(`Found ${files.length} theme files`);

  const themes: Theme[] = [];
  const themeIndex: { name: string; selector: string }[] = [];

  for (const file of files.sort()) {
    try {
      const content = await readFile(join(THEMES_DIR, file), "utf-8");
      const theme = parseTheme(file, content);
      themes.push(theme);
      themeIndex.push({
        name: theme.name,
        selector: themeToCssSelector(theme.name),
      });
    } catch (e) {
      console.error(`Error parsing ${file}:`, e);
    }
  }

  // Generate CSS
  const cssBlocks = themes.map(themeToCSS);
  
  const header = `/**
 * Ghostty Themes - Auto-generated
 * 
 * Generated from ${themes.length} themes
 * Run: bun scripts/generate-themes.ts
 * 
 * Usage: Add data-theme="theme-name" to your terminal container
 * Example: <div data-theme="dracula">...</div>
 */

`;

  const css = header + cssBlocks.join("\n\n") + "\n";

  await writeFile(OUTPUT_FILE, css);
  console.log(`Written ${themes.length} themes to ${OUTPUT_FILE}`);
  console.log(`File size: ${(css.length / 1024).toFixed(1)} KB`);

  // Also generate a TypeScript file with theme names for autocomplete
  const tsContent = `/**
 * Available Ghostty themes
 * Auto-generated - do not edit
 */

export const THEMES = ${JSON.stringify(themeIndex, null, 2)} as const;

export type ThemeName = typeof THEMES[number]['selector'];
`;

  await writeFile("client/src/themes.ts", tsContent);
  console.log(`Written theme index to client/src/themes.ts`);
}

main().catch(console.error);
