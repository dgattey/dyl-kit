import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it, mock } from "node:test";
import { iconResponse } from "../src/icons.ts";
import type { NextConfig } from "next";
import { withDylKit } from "../src/config.mjs";
import type { Site } from "../src/site.ts";

describe("withDylKit", () => {
  const app = (manifest: string) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "dylkit-web-"));
    const publicDir = path.join(root, "server", "public");
    fs.mkdirSync(publicDir, { recursive: true });
    fs.writeFileSync(path.join(root, "DylApp.toml"), manifest);
    const png = Buffer.alloc(24);
    png.write("IHDR", 12, "latin1");
    png.writeUInt32BE(1200, 16);
    png.writeUInt32BE(800, 20);
    fs.writeFileSync(path.join(publicDir, "shot.png"), png);
    return root;
  };
  /** Loads the config from `server/` under `root`, the way Next does for a site in `server/`. */
  const configIn = (root: string, config?: NextConfig) => {
    const cwd = process.cwd();
    process.chdir(path.join(root, "server"));
    try {
      return withDylKit(config);
    } finally {
      process.chdir(cwd);
    }
  };
  const siteIn = (root: string): Site => JSON.parse(configIn(root).env?.DYLKIT_SITE ?? "");
  const manifest = `[app]
name = "Demo"
[release]
site-url = "https://demo.example.com"
artifacts-dir = "server/public"
assets = "https://demo.public.blob.vercel-storage.com/"
[site]
tagline = "A demo app."
accent = { light = "#123456", dark = "#abcdef" }
screenshots = [{ src = "shot.png", alt = "The main window", dark-src = "shot-dark.png" }]
`;

  it("inlines the nearest DylApp.toml and the screenshots' sizes", () => {
    const site = siteIn(app(manifest));
    assert.equal(site.name, "Demo");
    assert.equal(site.tagline, "A demo app.");
    assert.deepEqual(site.accent, { light: "#123456", dark: "#abcdef" });
    assert.deepEqual(site.screenshots, [
      { src: "/shot.png", darkSrc: "/shot-dark.png", alt: "The main window", width: 1200, height: 800 },
    ]);
    assert.equal(site.assets, "https://demo.public.blob.vercel-storage.com");
    assert.equal(site.favicon, "light");
    assert.equal(site.headingFont, "sans");
    assert.deepEqual(site.features, []);
  });

  it("reads heading-font, frames and features", () => {
    const site = siteIn(
      app(`${manifest.replace('dark-src = "shot-dark.png"', 'frame = "iphone"')}heading-font = "serif"
features = [{ title = "Seeded puzzles", body = "Every board has one answer." }]
`),
    );
    assert.equal(site.headingFont, "serif");
    assert.equal(site.screenshots[0].frame, "iphone");
    assert.deepEqual(site.features, [{ title: "Seeded puzzles", body: "Every board has one answer." }]);
  });

  it("reads WebP sizes from each of its three headers", () => {
    const root = app(manifest);
    const webp = (chunk: string, body: (header: Buffer) => void) => {
      const header = Buffer.alloc(30);
      header.write("RIFF", 0, "latin1");
      header.write("WEBP", 8, "latin1");
      header.write(chunk, 12, "latin1");
      body(header);
      return header;
    };
    const files = {
      "extended.webp": webp("VP8X", (header) => {
        header.writeUIntLE(1599, 24, 3);
        header.writeUIntLE(899, 27, 3);
      }),
      "lossy.webp": webp("VP8 ", (header) => {
        header.writeUInt16LE(1600, 26);
        header.writeUInt16LE(900, 28);
      }),
      "lossless.webp": webp("VP8L", (header) => {
        header.writeUInt8(0x2f, 20);
        header.writeUInt32LE(1599 | (899 << 14), 21);
      }),
    };
    for (const [name, bytes] of Object.entries(files)) {
      fs.writeFileSync(path.join(root, "server", "public", name), bytes);
    }
    const shots = Object.keys(files)
      .map((name) => `{ src = "${name}", alt = "${name}" }`)
      .join(", ");
    fs.writeFileSync(path.join(root, "DylApp.toml"), manifest.replace(/screenshots = .*/, `screenshots = [${shots}]`));
    assert.deepEqual(
      siteIn(root).screenshots.map(({ width, height }) => [width, height]),
      [
        [1600, 900],
        [1600, 900],
        [1600, 900],
      ],
    );
  });

  it("keeps the app's own config and transpiles @dylkit/web", () => {
    const config = configIn(app(manifest), { transpilePackages: ["other"], env: { KEEP: "1" }, poweredByHeader: false });
    assert.deepEqual(config.transpilePackages, ["other", "@dylkit/web"]);
    assert.equal(config.env?.KEEP, "1");
    assert.equal(config.poweredByHeader, false);
  });

  it("names the missing key", () => {
    assert.throws(() => siteIn(app(manifest.replace(/tagline = .*\n/, ""))), /`site\.tagline`/);
    assert.throws(
      () => siteIn(app(manifest.replace('light = "#123456", ', ""))),
      /`site\.accent\.light`/,
    );
    assert.throws(() => siteIn(app(manifest.replace(/assets = .*\n/, ""))), /`release\.assets`/);
    assert.throws(() => siteIn(app(`${manifest}favicon = "blue"\n`)), /`site\.favicon`/);
    assert.throws(() => siteIn(app(`${manifest}heading-font = "mono"\n`)), /`site\.heading-font` must be "sans" or "serif"/);
    assert.throws(
      () => siteIn(app(manifest.replace('dark-src = "shot-dark.png"', 'frame = "picture-frame"'))),
      /`site\.screenshots\[0\]\.frame` must be "iphone"/,
    );
    assert.throws(() => siteIn(app(`${manifest}features = [{ title = "No body" }]\n`)), /site\.features\[0\] needs `title` and `body`/);
  });

  it("names a screenshot that isn't PNG or WebP", () => {
    const root = app(manifest);
    fs.writeFileSync(path.join(root, "server", "public", "shot.png"), Buffer.from([0xff, 0xd8, 0xff, ...Array(27).fill(0)]));
    assert.throws(() => siteIn(root), /shot\.png: screenshots must be PNG or WebP/);
  });
});

describe("icons", () => {
  const site = { assets: "https://demo.public.blob.vercel-storage.com", favicon: "light" } as Site;
  const store = (respond: (url: string, init: RequestInit) => Response) => {
    const requests: string[] = [];
    mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
      requests.push(url);
      return respond(url, init);
    });
    return requests;
  };
  afterEach(() => mock.restoreAll());

  it("passes the store's icon and ETag through with the cross-origin headers", async () => {
    const requests = store(
      (_, init) =>
        new Headers(init.headers).get("If-None-Match") === '"v1"'
          ? new Response(null, { status: 304, headers: { ETag: '"v1"' } })
          : new Response("png", { headers: { ETag: '"v1"', "Content-Type": "image/png" } }),
    );
    const response = await iconResponse(site, new Request("https://demo.example.com/icons/icon.png"));
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "png");
    assert.equal(response.headers.get("ETag"), '"v1"');
    assert.equal(response.headers.get("Content-Type"), "image/png");
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=3600, stale-while-revalidate=86400");
    assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
    assert.deepEqual(requests, [`${site.assets}/icons/icon.png`]);

    const conditional = new Request("https://demo.example.com/icon.png", { headers: { "If-None-Match": '"v1"' } });
    assert.equal((await iconResponse(site, conditional)).status, 304);
  });

  it("names the icon by the request's last path segment, with the dark favicon when the site asks", async () => {
    const requests = store(() => new Response("icon"));
    for (const url of ["/icon.png", "/apple-touch-icon.png", "/favicon.ico", "/icons/icon-256.png", "/icons/favicon.ico"]) {
      await iconResponse(site, new Request(`https://demo.example.com${url}`));
    }
    await iconResponse({ ...site, favicon: "dark" }, new Request("https://demo.example.com/favicon.ico"));
    assert.deepEqual(
      requests.map((url) => url.replace(`${site.assets}/icons/`, "")),
      ["icon.png", "apple-touch-icon.png", "favicon.ico", "icon-256.png", "favicon.ico", "favicon-dark.ico"],
    );
  });

  it("answers 404 for a missing icon and never reaches outside icons/", async () => {
    const requests = store(() => new Response("nope", { status: 404 }));
    const at = (url: string) => iconResponse(site, new Request(`https://demo.example.com${url}`));
    assert.equal((await at("/icons/icon-512.png")).status, 404);
    assert.equal((await at("/icons/..%2Fappcast.xml")).status, 404);
    assert.deepEqual(requests, [`${site.assets}/icons/icon-512.png`]);
  });
});
