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
site-url = "https://demo.gattey.com"
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

  it("passes the store's icon and ETag through with dylangattey.com's headers", async () => {
    const requests = store(
      (_, init) =>
        new Headers(init.headers).get("If-None-Match") === '"v1"'
          ? new Response(null, { status: 304, headers: { ETag: '"v1"' } })
          : new Response("png", { headers: { ETag: '"v1"', "Content-Type": "image/png" } }),
    );
    const response = await iconResponse(site, new Request("https://demo.gattey.com/icons/icon.png"));
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "png");
    assert.equal(response.headers.get("ETag"), '"v1"');
    assert.equal(response.headers.get("Content-Type"), "image/png");
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=3600, stale-while-revalidate=86400");
    assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
    assert.deepEqual(requests, [`${site.assets}/icons/icon.png`]);

    const conditional = new Request("https://demo.gattey.com/icon.png", { headers: { "If-None-Match": '"v1"' } });
    assert.equal((await iconResponse(site, conditional)).status, 304);
  });

  it("names the icon by the request's last path segment, with the dark favicon when the site asks", async () => {
    const requests = store(() => new Response("icon"));
    for (const url of ["/icon.png", "/apple-touch-icon.png", "/favicon.ico", "/icons/icon-256.png", "/icons/favicon.ico"]) {
      await iconResponse(site, new Request(`https://demo.gattey.com${url}`));
    }
    await iconResponse({ ...site, favicon: "dark" }, new Request("https://demo.gattey.com/favicon.ico"));
    assert.deepEqual(
      requests.map((url) => url.replace(`${site.assets}/icons/`, "")),
      ["icon.png", "apple-touch-icon.png", "favicon.ico", "icon-256.png", "favicon.ico", "favicon-dark.ico"],
    );
  });

  it("answers 404 for a missing icon and never reaches outside icons/", async () => {
    const requests = store(() => new Response("nope", { status: 404 }));
    const at = (url: string) => iconResponse(site, new Request(`https://demo.gattey.com${url}`));
    assert.equal((await at("/icons/icon-512.png")).status, 404);
    assert.equal((await at("/icons/..%2Fappcast.xml")).status, 404);
    assert.deepEqual(requests, [`${site.assets}/icons/icon-512.png`]);
  });
});
