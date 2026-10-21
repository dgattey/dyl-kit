import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { loadSite } from "../src/site.ts";

describe("loadSite", () => {
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
    fs.mkdirSync(path.join(root, "server", "app"));
    return root;
  };
  const manifest = `[app]
name = "Demo"
[release]
site-url = "https://demo.gattey.com"
artifacts-dir = "server/public"
[release.forge]
kind = "github"
repo = "dgattey/demo"
[site]
tagline = "A demo app."
accent = { light = "#123456", dark = "#abcdef" }
screenshots = [{ src = "shot.png", alt = "The main window", dark-src = "shot-dark.png" }]
`;

  it("reads DylApp.toml from the nearest ancestor", () => {
    const root = app(manifest);
    const site = loadSite(root);
    assert.equal(site.name, "Demo");
    assert.equal(site.tagline, "A demo app.");
    assert.deepEqual(site.accent, { light: "#123456", dark: "#abcdef" });
    assert.deepEqual(site.screenshots, [
      { src: "/shot.png", darkSrc: "/shot-dark.png", alt: "The main window", width: 1200, height: 800 },
    ]);
    assert.deepEqual(site.forge, { kind: "github", repo: "dgattey/demo" });
    assert.equal(site.appleIcon, "/app-icon.png");
    fs.writeFileSync(path.join(root, "server", "public", "apple-icon.png"), "png");
    assert.equal(loadSite(root).appleIcon, "/apple-icon.png");

    const cwd = process.cwd();
    process.chdir(path.join(root, "server", "app"));
    try {
      assert.equal(loadSite().name, "Demo");
    } finally {
      process.chdir(cwd);
    }
  });

  it("reads an Origin forge's Blob store", () => {
    const origin = manifest.replace(
      'kind = "github"',
      'kind = "origin"\nassets = "https://demo.public.blob.vercel-storage.com/"',
    );
    assert.deepEqual(loadSite(app(origin)).forge, {
      kind: "origin",
      repo: "dgattey/demo",
      assets: "https://demo.public.blob.vercel-storage.com",
    });
  });

  it("names the missing key", () => {
    assert.throws(() => loadSite(app(manifest.replace(/tagline = .*\n/, ""))), /`site\.tagline`/);
    assert.throws(
      () => loadSite(app(manifest.replace('light = "#123456", ', ""))),
      /`site\.accent\.light`/,
    );
    assert.throws(() => loadSite(app(manifest.replace(/repo = .*\n/, ""))), /`release\.forge\.repo`/);
    assert.throws(() => loadSite(app(manifest.replace('kind = "github"', 'kind = "origin"'))), /`release\.forge\.assets`/);
    assert.throws(() => loadSite(app(manifest.replace('kind = "github"', 'kind = "gitlab"'))), /`gitlab`/);
  });
});
