import "./render-site.ts";
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AllReleases } from "../src/ReleaseNotes.tsx";
import type { Release } from "../src/release.ts";

const release: Release = {
  version: "1.0.0",
  build: 1,
  minimumSystemVersion: "14.0",
  appleSiliconOnly: false,
  publishedAt: "2026-10-22T18:30:00Z",
  download: "https://demo.public.blob.vercel-storage.com/Demo-1.0.0.zip",
  sizeBytes: 5_912_345,
  notes: [{ version: "1.0.0", html: "<ul><li>First release</li></ul>" }],
};

describe("AllReleases", () => {
  beforeEach(() => mock.method(globalThis, "fetch", async () => new Response(null, { status: 404 })));
  afterEach(() => mock.restoreAll());

  it("says the app hasn't shipped, without an icon, before the first release", async () => {
    const html = renderToStaticMarkup(await AllReleases({ release: null }));
    assert.doesNotMatch(html, /<img|\/icons\//);
    assert.match(html, /<a href="\/" class="back">Demo<\/a>/);
    assert.match(html, /Demo hasn&#x27;t been released yet\./);
    assert.doesNotMatch(html, /0 releases|newest first|<ol/);
  });

  it("shows the app icon beside the back link once a release exists", async () => {
    const html = renderToStaticMarkup(await AllReleases({ release }));
    assert.match(html, /<a href="\/" class="back"><picture>.*<img src="\/icons\/icon-256\.png"/);
    assert.match(html, /1 release of Demo, newest first\./);
    assert.match(html, /Version 1\.0\.0/);
  });
});
