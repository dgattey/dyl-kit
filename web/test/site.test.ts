import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { downloadResponse } from "../src/next.ts";
import { loadSite, parseAppcast, releaseNotes } from "../src/site.ts";

const here = path.dirname(new URL(import.meta.url).pathname);
const fixture = (name: string) => fs.readFileSync(path.join(here, "fixtures", name), "utf8");
const missingZip = () => null;

describe("parseAppcast on the apps' real appcasts", () => {
  it("reads Gattey Photos' newest item and its legacy <h3> notes", () => {
    const release = parseAppcast(fixture("photos-appcast.xml"), "https://photos.gattey.com", () => 42);
    assert.ok(release);
    assert.equal(release.version, "1.1.10");
    assert.equal(release.minimumSystemVersion, "14.0");
    assert.equal(release.appleSiliconOnly, true);
    assert.equal(release.publishedAt, "2026-10-16T22:55:49.000Z");
    assert.equal(release.sizeBytes, 42);
    assert.equal(release.downloadReady, true);
    assert.deepEqual(
      release.notes.map((entry) => entry.version),
      ["1.1.10", "1.1.9"],
    );
    assert.doesNotMatch(release.notes[0].html, /style=/);
  });

  it("reads Saga's GitHub-hosted item as not deployed on the site", () => {
    const release = parseAppcast(fixture("saga-appcast.xml"), "https://saga.gattey.com", missingZip);
    assert.ok(release);
    assert.equal(release.version, "1.6.1");
    assert.equal(release.minimumSystemVersion, "15.0");
    assert.equal(release.appleSiliconOnly, false);
    assert.equal(release.downloadReady, false);
    assert.match(release.downloadUrl, /^https:\/\/github\.com\//);
    assert.equal(release.notes[0].version, "1.6.1");
  });

  it("picks the highest build when an appcast lists several items", () => {
    const item = (build: number) =>
      `<item><sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>1.0.${build}</sparkle:shortVersionString>` +
      `<enclosure url="https://app.gattey.com/App-1.0.${build}.zip" length="9"/></item>`;
    const release = parseAppcast(`<rss>${item(3)}${item(7)}${item(5)}</rss>`, "https://app.gattey.com", missingZip);
    assert.equal(release?.version, "1.0.7");
    assert.equal(release?.zipPath, "/App-1.0.7.zip");
    assert.equal(release?.sizeBytes, 9);
  });

  it("returns null without an item or an enclosure", () => {
    assert.equal(parseAppcast("<rss></rss>", "https://app.gattey.com", missingZip), null);
    assert.equal(parseAppcast("<rss><item><title>1.0</title></item></rss>", "https://app.gattey.com", missingZip), null);
  });
});

describe("releaseNotes", () => {
  it("splits release-kit's stamped sections and drops the Sparkle styling", () => {
    const section = (build: number, version: string, note: string) =>
      `<section data-sparkle-version="${build}">\n<h3 style="margin: 14px 0 6px 0;">${version}</h3>\n` +
      `<ul>\n  <li style="margin-bottom: 6px;">${note}</li>\n</ul>\n</section>`;
    const html =
      "<style>.sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }</style>\n" +
      [section(30, "1.0.13", "New thing."), section(29, "1.0.12", "Queue."), section(28, "1.0.11", "Faster.")].join("\n");
    const notes = releaseNotes(html);
    assert.deepEqual(
      notes.map((entry) => entry.version),
      ["1.0.13", "1.0.12", "1.0.11"],
    );
    assert.match(notes[0].html, /New thing\./);
    assert.doesNotMatch(notes[0].html, /style=/);
  });

  it("leaves out versions that shipped without notes", () => {
    const html = `<section data-sparkle-version="9" data-version="1.0.9"></section><section><h3>1.0.8</h3><ul><li>Fix.</li></ul></section>`;
    assert.deepEqual(
      releaseNotes(html).map((entry) => entry.version),
      ["1.0.8"],
    );
  });
});

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
    fs.writeFileSync(
      path.join(publicDir, "appcast.xml"),
      `<rss><item><sparkle:version>4</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>` +
        `<enclosure url="https://demo.gattey.com/Demo-2.0.0.zip" length="1"/></item></rss>`,
    );
    fs.writeFileSync(path.join(publicDir, "Demo-2.0.0.zip"), "zip");
    fs.mkdirSync(path.join(root, "server", "app"));
    return root;
  };
  const manifest = `[app]
name = "Demo"
[release]
site-url = "https://demo.gattey.com"
artifacts-dir = "server/public"
[site]
tagline = "A demo app."
accent = { light = "#123456", dark = "#abcdef" }
screenshots = [{ src = "shot.png", alt = "The main window", dark-src = "shot-dark.png" }]
`;

  it("reads DylApp.toml from the nearest ancestor and the committed appcast", () => {
    const root = app(manifest);
    const site = loadSite(root);
    assert.equal(site.name, "Demo");
    assert.equal(site.tagline, "A demo app.");
    assert.deepEqual(site.accent, { light: "#123456", dark: "#abcdef" });
    assert.deepEqual(site.screenshots, [
      { src: "/shot.png", darkSrc: "/shot-dark.png", alt: "The main window", width: 1200, height: 800 },
    ]);
    assert.equal(site.release?.version, "2.0.0");
    assert.equal(site.release?.sizeBytes, 3);
    assert.equal(site.release?.downloadReady, true);
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

  it("names the missing key", () => {
    assert.throws(() => loadSite(app(manifest.replace(/tagline = .*\n/, ""))), /`site\.tagline`/);
    assert.throws(
      () => loadSite(app(manifest.replace('light = "#123456", ', ""))),
      /`site\.accent\.light`/,
    );
  });

  it("redirects downloads to the deployed zip, and 503s until it's there", () => {
    const root = app(manifest);
    const ready = downloadResponse(loadSite(root));
    assert.equal(ready.status, 302);
    assert.equal(ready.headers.get("Location"), "/Demo-2.0.0.zip");

    fs.rmSync(path.join(root, "server", "public", "Demo-2.0.0.zip"));
    assert.equal(downloadResponse(loadSite(root)).status, 503);
  });
});
