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

/** `[release.forge]`: where release-kit publishes each release's zip, `appcast.xml` and `release.json`. */
export type Forge =
  | { kind: "github"; repo: string }
  | {
      kind: "origin";
      repo: string;
      /** The public Blob store's base URL, without a trailing slash. */
      assets: string;
    };

export type Site = {
  name: string;
  tagline: string;
  siteUrl: string;
  accent: { light: string; dark: string } | null;
  /** The home-screen icon: the artifacts dir's full-bleed `apple-icon.png`, else the rounded `app-icon.png`. */
  appleIcon: string;
  screenshots: Screenshot[];
  forge: Forge;
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
    appleIcon: fs.existsSync(path.join(artifactsDir, "apple-icon.png")) ? "/apple-icon.png" : "/app-icon.png",
    screenshots: screenshotsFrom(lookup(manifest, "site.screenshots"), artifactsDir),
    forge: forgeFrom(manifest),
  };
}

function forgeFrom(manifest: unknown): Forge {
  const repo = requireString(manifest, "release.forge.repo");
  const kind = requireString(manifest, "release.forge.kind");
  switch (kind) {
    case "github":
      return { kind, repo };
    case "origin":
      return { kind, repo, assets: requireString(manifest, "release.forge.assets").replace(/\/$/, "") };
    default:
      throw new Error(`DylApp.toml: \`release.forge.kind\` must be \`github\` or \`origin\`, got \`${kind}\``);
  }
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
