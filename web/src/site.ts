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

export type ReleaseNotes = { version: string; html: string };

export type Release = {
  version: string;
  minimumSystemVersion: string;
  appleSiliconOnly: boolean;
  /** ISO 8601. */
  publishedAt: string | null;
  /** Site path of the zip, e.g. `/Sconeos-1.0.1.zip`. */
  zipPath: string;
  /** The appcast's enclosure URL. */
  downloadUrl: string;
  sizeBytes: number | null;
  /** False while the appcast names a zip that isn't deployed yet. */
  downloadReady: boolean;
  /** Newest first, versions without notes left out. */
  notes: ReleaseNotes[];
};

export type Site = {
  name: string;
  tagline: string;
  siteUrl: string;
  accent: { light: string; dark: string } | null;
  /** The home-screen icon: the artifacts dir's full-bleed `apple-icon.png`, else the rounded `app-icon.png`. */
  appleIcon: string;
  screenshots: Screenshot[];
  release: Release | null;
};

/**
 * Reads the app's `DylApp.toml` and its committed `appcast.xml` at build time. `root` defaults to the nearest
 * directory at or above the working directory that holds `DylApp.toml`, so a site in `server/` finds its repo's.
 */
export function loadSite(root: string = findRoot(process.cwd())): Site {
  const manifest = parseToml(fs.readFileSync(path.join(root, "DylApp.toml"), "utf8"));
  const name = requireString(manifest, "app.name");
  const siteUrl = requireString(manifest, "release.site-url");
  const artifactsDir = path.join(root, requireString(manifest, "release.artifacts-dir"));
  const accent = lookup(manifest, "site.accent");
  const appcastPath = path.join(artifactsDir, "appcast.xml");

  return {
    name,
    tagline: requireString(manifest, "site.tagline"),
    siteUrl,
    accent: isRecord(accent) ? { light: requireString(manifest, "site.accent.light"), dark: requireString(manifest, "site.accent.dark") } : null,
    appleIcon: fs.existsSync(path.join(artifactsDir, "apple-icon.png")) ? "/apple-icon.png" : "/app-icon.png",
    screenshots: screenshotsFrom(lookup(manifest, "site.screenshots"), artifactsDir),
    release: fs.existsSync(appcastPath)
      ? parseAppcast(fs.readFileSync(appcastPath, "utf8"), siteUrl, (zipPath) => zipSize(artifactsDir, zipPath))
      : null,
  };
}

/** The newest item of a Sparkle appcast. `zipSize` returns the deployed zip's size, or null when it's missing. */
export function parseAppcast(
  xml: string,
  siteUrl: string,
  zipSize: (zipPath: string) => number | null,
): Release | null {
  const items = [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((match) => match[1]);
  const newest = items
    .map((item) => ({ item, build: Number(tag(item, "sparkle:version") ?? 0) }))
    .sort((a, b) => b.build - a.build)[0]?.item;
  if (!newest) return null;

  const version = tag(newest, "sparkle:shortVersionString") ?? tag(newest, "title");
  const enclosure = newest.match(/<enclosure\b([^>]*)>/)?.[1] ?? "";
  const downloadUrl = attribute(enclosure, "url");
  if (!version || !downloadUrl) return null;

  const zipPath = new URL(downloadUrl, siteUrl).pathname;
  const deployedSize = zipSize(zipPath);
  const length = Number(attribute(enclosure, "length"));
  const published = tag(newest, "pubDate");
  return {
    version,
    minimumSystemVersion: tag(newest, "sparkle:minimumSystemVersion") ?? "",
    appleSiliconOnly: tag(newest, "sparkle:hardwareRequirements")?.includes("arm64") ?? false,
    publishedAt: published ? new Date(published).toISOString() : null,
    zipPath,
    downloadUrl,
    sizeBytes: deployedSize ?? (length > 0 ? length : null),
    downloadReady: deployedSize !== null,
    notes: releaseNotes(tag(newest, "description") ?? ""),
  };
}

/**
 * Splits release-kit's cumulative notes into versions: `<section>`-wrapped ones, or legacy `<h3>`-headed ones.
 * Inline styles and the Sparkle `<style>` rule are for the update dialog, so they're dropped.
 */
export function releaseNotes(description: string): ReleaseNotes[] {
  const html = description
    .replace(/<style\b[\s\S]*?<\/style>/gi, "")
    .replace(/\sstyle="[^"]*"/gi, "");
  const sections = [...html.matchAll(/<section\b([^>]*)>([\s\S]*?)<\/section>/gi)];
  const entries = sections.length
    ? sections.map(([, attributes, inner]) => {
        const heading = inner.match(/<h3\b[^>]*>([\s\S]*?)<\/h3>/i);
        return {
          version: heading ? text(heading[1]) : (attribute(attributes, "data-version") ?? ""),
          html: heading ? inner.replace(heading[0], "") : inner,
        };
      })
    : html
        .split(/(?=<h3\b)/i)
        .map((chunk) => chunk.match(/^<h3\b[^>]*>([\s\S]*?)<\/h3>([\s\S]*)$/i))
        .filter((match) => match !== null)
        .map(([, heading, body]) => ({ version: text(heading), html: body }));
  return entries.map((entry) => ({ ...entry, html: entry.html.trim() })).filter((entry) => entry.html && entry.version);
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

function zipSize(artifactsDir: string, zipPath: string): number | null {
  const file = path.join(artifactsDir, decodeURIComponent(zipPath));
  return fs.existsSync(file) ? fs.statSync(file).size : null;
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

function tag(xml: string, name: string): string | undefined {
  const value = xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1];
  return value?.replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, "$1").trim();
}

function attribute(attributes: string, name: string): string | undefined {
  return attributes.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1];
}

function text(html: string): string {
  return html
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .trim();
}
