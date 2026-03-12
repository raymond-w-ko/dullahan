#!/usr/bin/env bun

import { writeFile } from "fs/promises";
import {
  countThemeFiles,
  ensureThemeSourceDir,
  loadThemeManifest,
  THEME_MANIFEST_FILE,
  type ThemeReleaseManifest,
} from "./theme-source";

const LATEST_RELEASE_URL = "https://api.github.com/repos/mbadolato/iTerm2-Color-Schemes/releases/latest";
const GHOSTTY_ASSET_NAME = "ghostty-themes.tgz";

interface GitHubAsset {
  name: string;
  browser_download_url: string;
  digest?: string;
}

interface GitHubRelease {
  tag_name: string;
  name: string;
  published_at: string;
  body: string;
  assets: GitHubAsset[];
}

async function fetchLatestManifest(): Promise<ThemeReleaseManifest> {
  const response = await fetch(LATEST_RELEASE_URL, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "dullahan-theme-updater",
    },
  });
  if (!response.ok) {
    throw new Error(`Failed to query latest theme release: ${response.status} ${response.statusText}`);
  }

  const release = await response.json() as GitHubRelease;
  const asset = release.assets.find((entry) => entry.name === GHOSTTY_ASSET_NAME);
  if (!asset?.digest) {
    throw new Error(`Latest release is missing ${GHOSTTY_ASSET_NAME} or its digest`);
  }

  const commitMatch = release.body.match(/Commit:\*\* \[`([0-9a-f]+)`\]/);
  if (!commitMatch) {
    throw new Error("Could not parse release commit from GitHub release body");
  }

  return {
    repo: "mbadolato/iTerm2-Color-Schemes",
    releaseTag: release.tag_name,
    releaseName: release.name,
    publishedAt: release.published_at,
    commit: commitMatch[1]!,
    assetName: asset.name,
    assetUrl: asset.browser_download_url,
    assetSha256: asset.digest.replace(/^sha256:/, ""),
  };
}

async function main() {
  const current = await loadThemeManifest().catch(() => null);
  const latest = await fetchLatestManifest();

  await writeThemeManifest(latest);

  const { themeDir } = await ensureThemeSourceDir(latest);
  const themeCount = await countThemeFiles(themeDir);

  console.log(`Theme release: ${current?.releaseTag ?? "none"} -> ${latest.releaseTag}`);
  console.log(`Pinned archive: ${latest.assetName}`);
  console.log(`Pinned sha256: ${latest.assetSha256}`);
  console.log(`Theme files: ${themeCount}`);
}

async function writeThemeManifest(manifest: ThemeReleaseManifest) {
  await writeFile(THEME_MANIFEST_FILE, `${JSON.stringify(manifest, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
