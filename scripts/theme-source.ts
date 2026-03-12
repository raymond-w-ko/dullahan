import { createHash } from "crypto";
import { access, mkdir, readFile, readdir, writeFile } from "fs/promises";
import { dirname, join, resolve } from "path";

export interface ThemeReleaseManifest {
  repo: string;
  releaseTag: string;
  releaseName: string;
  publishedAt: string;
  commit: string;
  assetName: string;
  assetUrl: string;
  assetSha256: string;
}

const REPO_ROOT = resolve(import.meta.dir, "..");
export const THEME_MANIFEST_FILE = join(REPO_ROOT, "scripts", "theme-release.json");
const THEME_CACHE_DIR = join(REPO_ROOT, "deps", "themes", "cache");
const THEME_RELEASE_DIR = join(REPO_ROOT, "deps", "themes", "releases");

export async function loadThemeManifest(): Promise<ThemeReleaseManifest> {
  const raw = await readFile(THEME_MANIFEST_FILE, "utf-8");
  return JSON.parse(raw) as ThemeReleaseManifest;
}

export function themeToCssSelector(name: string): string {
  return name
    .toLowerCase()
    .replace(/\+/g, "-plus")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

export async function ensureThemeSourceDir(
  manifest: ThemeReleaseManifest,
): Promise<{ themeDir: string; archivePath: string }> {
  const archivePath = await ensureThemeArchive(manifest);
  const releaseRoot = join(THEME_RELEASE_DIR, manifest.releaseTag);
  const themeDir = join(releaseRoot, "ghostty");
  const stampPath = join(releaseRoot, ".complete");

  if (await pathExists(themeDir) && await pathExists(stampPath)) {
    return { themeDir, archivePath };
  }

  await mkdir(releaseRoot, { recursive: true });

  const proc = Bun.spawn(["tar", "-xzf", archivePath, "-C", releaseRoot], {
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`tar exited with status ${exitCode}`);
  }

  await writeFile(stampPath, `${manifest.releaseTag}\n`);
  return { themeDir, archivePath };
}

async function ensureThemeArchive(manifest: ThemeReleaseManifest): Promise<string> {
  await mkdir(THEME_CACHE_DIR, { recursive: true });

  const archivePath = join(THEME_CACHE_DIR, `${manifest.releaseTag}-${manifest.assetName}`);
  const expectedSha = normalizeSha256(manifest.assetSha256);

  if (await pathExists(archivePath)) {
    const actualSha = await sha256File(archivePath);
    if (actualSha === expectedSha) {
      return archivePath;
    }
  }

  const response = await fetch(manifest.assetUrl, {
    headers: {
      "User-Agent": "dullahan-theme-updater",
      Accept: "application/octet-stream",
    },
  });
  if (!response.ok) {
    throw new Error(`Failed to download ${manifest.assetUrl}: ${response.status} ${response.statusText}`);
  }

  const bytes = new Uint8Array(await response.arrayBuffer());
  const actualSha = sha256Bytes(bytes);
  if (actualSha !== expectedSha) {
    throw new Error(`Theme archive sha256 mismatch: expected ${expectedSha}, got ${actualSha}`);
  }

  await mkdir(dirname(archivePath), { recursive: true });
  await writeFile(archivePath, bytes);
  return archivePath;
}

async function sha256File(path: string): Promise<string> {
  const file = await readFile(path);
  return sha256Bytes(file);
}

function sha256Bytes(bytes: Uint8Array): string {
  const hash = createHash("sha256");
  hash.update(bytes);
  return hash.digest("hex");
}

function normalizeSha256(value: string): string {
  return value.replace(/^sha256:/, "");
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

export async function countThemeFiles(themeDir: string): Promise<number> {
  const entries = await readdir(themeDir, { withFileTypes: true });
  return entries.filter((entry) => entry.isFile()).length;
}
