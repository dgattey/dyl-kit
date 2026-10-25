// Plain JS with a .d.mts beside it: Node loads next.config.ts's imports itself and won't strip types in node_modules.
import fs from "node:fs";
import path from "node:path";
import { parse as parseToml } from "smol-toml";

/**
 * Wraps the site's Next config. When Next loads it, this reads the app's `DylApp.toml` and its screenshots' sizes
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
    favicon: oneOf(manifest, "site.favicon", ["light", "dark"]),
    headingFont: oneOf(manifest, "site.heading-font", ["sans", "serif"]),
    screenshots: tablesFrom(manifest, "site.screenshots", ["src", "alt"], (entry, key) => {
      const darkSrc = typeof entry["dark-src"] === "string" ? entry["dark-src"] : undefined;
      const frame = entry.frame === undefined ? undefined : oneOf(entry, "frame", ["iphone"], `${key}.`);
      const { width, height } = imageSize(path.join(artifactsDir, entry.src));
      return { src: `/${entry.src}`, darkSrc: darkSrc && `/${darkSrc}`, alt: entry.alt, width, height, frame };
    }),
    features: tablesFrom(manifest, "site.features", ["title", "body"], ({ title, body }) => ({ title, body })),
    assets: requireString(manifest, "release.assets").replace(/\/$/, ""),
  };
}

/** The value at `key`, which must be one of `allowed`; the first is the default. */
function oneOf(table, key, allowed, prefix = "") {
  const value = lookup(table, key) ?? allowed[0];
  if (allowed.includes(value)) return value;
  throw new Error(`DylApp.toml: \`${prefix}${key}\` must be ${allowed.map((option) => `"${option}"`).join(" or ")}`);
}

/** Maps each table in the array at `key`, after checking that it has every key in `strings` as a string. */
function tablesFrom(manifest, key, strings, map) {
  const value = lookup(manifest, key);
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error(`DylApp.toml: \`${key}\` must be an array of tables`);
  return value.map((entry, index) => {
    if (!isRecord(entry) || strings.some((name) => typeof entry[name] !== "string")) {
      throw new Error(`DylApp.toml: ${key}[${index}] needs ${strings.map((name) => `\`${name}\``).join(" and ")} strings`);
    }
    return map(entry, `${key}[${index}]`);
  });
}

/** A PNG's or WebP's pixel size, read from its header. */
function imageSize(file) {
  const header = fs.readFileSync(file).subarray(0, 30);
  if (header.toString("latin1", 12, 16) === "IHDR") return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
  if (header.toString("latin1", 0, 4) === "RIFF" && header.toString("latin1", 8, 12) === "WEBP") {
    switch (header.toString("latin1", 12, 16)) {
      case "VP8X":
        return { width: header.readUIntLE(24, 3) + 1, height: header.readUIntLE(27, 3) + 1 };
      case "VP8 ":
        return { width: header.readUInt16LE(26) & 0x3fff, height: header.readUInt16LE(28) & 0x3fff };
      case "VP8L": {
        const bits = header.readUInt32LE(21);
        return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 };
      }
    }
  }
  throw new Error(`${file}: screenshots must be PNG or WebP`);
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
