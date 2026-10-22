import fs from "node:fs";
import path from "node:path";
import { parse as parseToml } from "smol-toml";

export type Screenshot = {
  /** Path under the artifacts dir, served from the site root. */
  src: string;
  /** Dark-appearance variant, shown when the visitor's system is in dark mode. */
  darkSrc?: string;
  alt: string;
  width: number;
  height: number;
};

export type Site = {
  name: string;
  tagline: string;
  siteUrl: string;
  accent: { light: string; dark: string } | null;
  /** `site.favicon`: which appearance the browser tab shows, for an icon whose light variant vanishes on a light tab. */
  favicon: "light" | "dark";
  screenshots: Screenshot[];
  /** `release.assets`: the public Blob store release-kit uploads each release to, without a trailing slash. */
  assets: string;
};

/**
 * Reads the app's `DylApp.toml` at build time. `root` defaults to the nearest directory at or above the working
 * directory that holds `DylApp.toml`, so a site in `server/` finds its repo's.
 */
export function loadSite(root: string = findRoot(process.cwd())): Site {
  const manifest = parseToml(fs.readFileSync(path.join(root, "DylApp.toml"), "utf8"));
  const artifactsDir = path.join(root, requireString(manifest, "release.artifacts-dir"));
  const accent = lookup(manifest, "site.accent");

  return {
    name: requireString(manifest, "app.name"),
    tagline: requireString(manifest, "site.tagline"),
    siteUrl: requireString(manifest, "release.site-url"),
    accent: isRecord(accent) ? { light: requireString(manifest, "site.accent.light"), dark: requireString(manifest, "site.accent.dark") } : null,
    favicon: faviconFrom(lookup(manifest, "site.favicon")),
    screenshots: screenshotsFrom(lookup(manifest, "site.screenshots"), artifactsDir),
    assets: requireString(manifest, "release.assets").replace(/\/$/, ""),
  };
}

function faviconFrom(value: unknown): Site["favicon"] {
  if (value === undefined || value === "light" || value === "dark") return value ?? "light";
  throw new Error('DylApp.toml: `site.favicon` must be "light" or "dark"');
}

function screenshotsFrom(value: unknown, artifactsDir: string): Screenshot[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error("DylApp.toml: `site.screenshots` must be an array of tables");
  return value.map((entry, index) => {
    if (!isRecord(entry) || typeof entry.src !== "string" || typeof entry.alt !== "string") {
      throw new Error(`DylApp.toml: site.screenshots[${index}] needs \`src\` and \`alt\` strings`);
    }
    const darkSrc = typeof entry["dark-src"] === "string" ? entry["dark-src"] : undefined;
    const { width, height } = pngSize(path.join(artifactsDir, entry.src));
    return { src: `/${entry.src}`, darkSrc: darkSrc && `/${darkSrc}`, alt: entry.alt, width, height };
  });
}

function pngSize(file: string): { width: number; height: number } {
  const header = fs.readFileSync(file).subarray(0, 24);
  if (header.toString("latin1", 12, 16) !== "IHDR") throw new Error(`${file}: screenshots must be PNG`);
  return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
}

function findRoot(start: string): string {
  for (let dir = start; ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, "DylApp.toml"))) return dir;
    if (path.dirname(dir) === dir) throw new Error(`no DylApp.toml at or above ${start}`);
  }
}

function lookup(table: unknown, key: string): unknown {
  return key.split(".").reduce<unknown>((value, part) => (isRecord(value) ? value[part] : undefined), table);
}

function requireString(table: unknown, key: string): string {
  const value = lookup(table, key);
  if (typeof value !== "string" || !value) throw new Error(`DylApp.toml: missing required key \`${key}\``);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
