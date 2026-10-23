// Plain JS with a .d.mts beside it: Node loads next.config.ts's imports itself and won't strip types in node_modules.
import fs from "node:fs";
import path from "node:path";
import { parse as parseToml } from "smol-toml";

/**
 * Wraps the site's Next config. When Next loads it, this reads the app's `DylApp.toml` and its screenshots' PNG sizes
 * and inlines them as `process.env.DYLKIT_SITE`, so the built site never reads either.
 * @param {import("next").NextConfig} [config]
 * @returns {import("next").NextConfig}
 */
export function withDylKit(config = {}) {
  return {
    ...config,
    transpilePackages: [...(config.transpilePackages ?? []), "@dylkit/web"],
    env: { ...config.env, DYLKIT_SITE: JSON.stringify(loadSite(findRoot(process.cwd()))) },
  };
}

/** @returns {import("./site").Site} */
function loadSite(root) {
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

function faviconFrom(value) {
  if (value === undefined || value === "light" || value === "dark") return value ?? "light";
  throw new Error('DylApp.toml: `site.favicon` must be "light" or "dark"');
}

function screenshotsFrom(value, artifactsDir) {
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

function pngSize(file) {
  const header = fs.readFileSync(file).subarray(0, 24);
  if (header.toString("latin1", 12, 16) !== "IHDR") throw new Error(`${file}: screenshots must be PNG`);
  return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
}

function findRoot(start) {
  for (let dir = start; ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, "DylApp.toml"))) return dir;
    if (path.dirname(dir) === dir) throw new Error(`no DylApp.toml at or above ${start}`);
  }
}

function lookup(table, key) {
  return key.split(".").reduce((value, part) => (isRecord(value) ? value[part] : undefined), table);
}

function requireString(table, key) {
  const value = lookup(table, key);
  if (typeof value !== "string" || !value) throw new Error(`DylApp.toml: missing required key \`${key}\``);
  return value;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
