/**
 * Theme-driven 256-color palette generation for the web client.
 *
 * Generates indices 16..255 from base16 + fg/bg using CIELAB interpolation,
 * then applies overrides as CSS variables on `.app`.
 */

interface RGB {
  r: number;
  g: number;
  b: number;
}

interface LAB {
  l: number;
  a: number;
  b: number;
}

const REF_X = 0.95047;
const REF_Y = 1.0;
const REF_Z = 1.08883;
const EPSILON = 216 / 24389;
const KAPPA = 24389 / 27;

function clamp01(value: number): number {
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

function clampByte(value: number): number {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return Math.round(value);
}

function srgbToLinear(value: number): number {
  if (value <= 0.04045) return value / 12.92;
  return Math.pow((value + 0.055) / 1.055, 2.4);
}

function linearToSrgb(value: number): number {
  if (value <= 0.0031308) return 12.92 * value;
  return 1.055 * Math.pow(value, 1 / 2.4) - 0.055;
}

function rgbToLab(rgb: RGB): LAB {
  const r = srgbToLinear(rgb.r / 255);
  const g = srgbToLinear(rgb.g / 255);
  const b = srgbToLinear(rgb.b / 255);

  const x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375;
  const y = r * 0.2126729 + g * 0.7151522 + b * 0.072175;
  const z = r * 0.0193339 + g * 0.119192 + b * 0.9503041;

  const fx = xyzToLabF(x / REF_X);
  const fy = xyzToLabF(y / REF_Y);
  const fz = xyzToLabF(z / REF_Z);

  return {
    l: 116 * fy - 16,
    a: 500 * (fx - fy),
    b: 200 * (fy - fz),
  };
}

function labToRgb(lab: LAB): RGB {
  const fy = (lab.l + 16) / 116;
  const fx = fy + lab.a / 500;
  const fz = fy - lab.b / 200;

  const x = REF_X * labToXyzF(fx);
  const y = REF_Y * labToXyzF(fy);
  const z = REF_Z * labToXyzF(fz);

  const rLin = 3.2404542 * x + -1.5371385 * y + -0.4985314 * z;
  const gLin = -0.969266 * x + 1.8760108 * y + 0.041556 * z;
  const bLin = 0.0556434 * x + -0.2040259 * y + 1.0572252 * z;

  const r = clampByte(linearToSrgb(clamp01(rLin)) * 255);
  const g = clampByte(linearToSrgb(clamp01(gLin)) * 255);
  const b = clampByte(linearToSrgb(clamp01(bLin)) * 255);

  return { r, g, b };
}

function xyzToLabF(value: number): number {
  if (value > EPSILON) return Math.cbrt(value);
  return (KAPPA * value + 16) / 116;
}

function labToXyzF(value: number): number {
  const value3 = value * value * value;
  if (value3 > EPSILON) return value3;
  return (116 * value - 16) / KAPPA;
}

function lerpLab(t: number, left: LAB, right: LAB): LAB {
  return {
    l: left.l + t * (right.l - left.l),
    a: left.a + t * (right.a - left.a),
    b: left.b + t * (right.b - left.b),
  };
}

function toHex(rgb: RGB): string {
  return `#${rgb.r.toString(16).padStart(2, "0")}${rgb.g.toString(16).padStart(2, "0")}${rgb.b.toString(16).padStart(2, "0")}`;
}

function parseCssColor(value: string): RGB | null {
  const trimmed = value.trim().toLowerCase();
  if (!trimmed) return null;

  if (trimmed.startsWith("#")) {
    const hex = trimmed.slice(1);
    if (hex.length === 3) {
      const h0 = hex.charAt(0);
      const h1 = hex.charAt(1);
      const h2 = hex.charAt(2);
      const r = Number.parseInt(h0 + h0, 16);
      const g = Number.parseInt(h1 + h1, 16);
      const b = Number.parseInt(h2 + h2, 16);
      if (Number.isNaN(r) || Number.isNaN(g) || Number.isNaN(b)) return null;
      return { r, g, b };
    }

    if (hex.length === 6) {
      const r = Number.parseInt(hex.slice(0, 2), 16);
      const g = Number.parseInt(hex.slice(2, 4), 16);
      const b = Number.parseInt(hex.slice(4, 6), 16);
      if (Number.isNaN(r) || Number.isNaN(g) || Number.isNaN(b)) return null;
      return { r, g, b };
    }
  }

  const rgbMatch = trimmed.match(/rgba?\(([^)]+)\)/);
  if (!rgbMatch || !rgbMatch[1]) return null;

  const parts = rgbMatch[1]
    .split(/[,/ ]+/)
    .map((part) => part.trim())
    .filter((part) => part.length > 0);

  if (parts.length < 3) return null;

  const parseChannel = (part: string): number | null => {
    if (part.endsWith("%")) {
      const pct = Number.parseFloat(part);
      if (Number.isNaN(pct)) return null;
      return clampByte((pct / 100) * 255);
    }

    const raw = Number.parseFloat(part);
    if (Number.isNaN(raw)) return null;
    return clampByte(raw);
  };

  const r = parseChannel(parts[0] ?? "");
  const g = parseChannel(parts[1] ?? "");
  const b = parseChannel(parts[2] ?? "");

  if (r === null || g === null || b === null) return null;
  return { r, g, b };
}

function clearGeneratedPalette(appEl: HTMLElement): void {
  for (let i = 16; i < 256; i++) {
    appEl.style.removeProperty(`--c${i}`);
  }
}

function generate256Palette(base16: RGB[], bg: RGB, fg: RGB, harmonious: boolean): RGB[] {
  const base8Lab: LAB[] = [
    rgbToLab(bg),
    rgbToLab(base16[1]!),
    rgbToLab(base16[2]!),
    rgbToLab(base16[3]!),
    rgbToLab(base16[4]!),
    rgbToLab(base16[5]!),
    rgbToLab(base16[6]!),
    rgbToLab(fg),
  ];

  const isLightTheme = base8Lab[7]!.l < base8Lab[0]!.l;
  if (isLightTheme && !harmonious) {
    const tmp = base8Lab[0]!;
    base8Lab[0] = base8Lab[7]!;
    base8Lab[7] = tmp;
  }

  const palette: RGB[] = [...base16];

  for (let r = 0; r < 6; r++) {
    const c0 = lerpLab(r / 5, base8Lab[0]!, base8Lab[1]!);
    const c1 = lerpLab(r / 5, base8Lab[2]!, base8Lab[3]!);
    const c2 = lerpLab(r / 5, base8Lab[4]!, base8Lab[5]!);
    const c3 = lerpLab(r / 5, base8Lab[6]!, base8Lab[7]!);
    for (let g = 0; g < 6; g++) {
      const c4 = lerpLab(g / 5, c0, c1);
      const c5 = lerpLab(g / 5, c2, c3);
      for (let b = 0; b < 6; b++) {
        palette.push(labToRgb(lerpLab(b / 5, c4, c5)));
      }
    }
  }

  for (let i = 0; i < 24; i++) {
    const t = (i + 1) / 25;
    palette.push(labToRgb(lerpLab(t, base8Lab[0]!, base8Lab[7]!)));
  }

  return palette;
}

export function applyGeneratedPaletteFromTheme(enabled: boolean): void {
  if (typeof document === "undefined") return;
  const appEl = document.querySelector(".app");
  if (!(appEl instanceof HTMLElement)) return;

  if (!enabled) {
    clearGeneratedPalette(appEl);
    return;
  }

  const style = getComputedStyle(appEl);

  const base16: RGB[] = [];
  for (let i = 0; i < 16; i++) {
    const color = parseCssColor(style.getPropertyValue(`--c${i}`));
    if (!color) {
      clearGeneratedPalette(appEl);
      return;
    }
    base16.push(color);
  }

  const termBg = parseCssColor(style.getPropertyValue("--term-bg")) ?? base16[0];
  const termFg = parseCssColor(style.getPropertyValue("--term-fg")) ?? base16[7];
  if (!termBg || !termFg) {
    clearGeneratedPalette(appEl);
    return;
  }

  const palette = generate256Palette(base16, termBg, termFg, false);
  for (let i = 16; i < 256; i++) {
    appEl.style.setProperty(`--c${i}`, toHex(palette[i]!));
  }
}
