import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { appcastResponse, downloadResponse, latestAssetURL, latestRelease, liveBuild } from "../src/release.ts";
import type { Release } from "../src/release.ts";
import type { Site } from "../src/site.ts";

const site: Site = {
  name: "Demo",
  tagline: "A demo app.",
  siteUrl: "https://demo.gattey.com",
  accent: null,
  appleIcon: "/app-icon.png",
  screenshots: [],
  forge: { kind: "github", repo: "dgattey/demo" },
};
const latest = (name: string) => `https://github.com/dgattey/demo/releases/latest/download/${name}`;
const live = "https://demo.gattey.com/appcast.xml";

const release: Release = {
  version: "1.2.0",
  build: 31,
  minimumSystemVersion: "15.0",
  appleSiliconOnly: true,
  publishedAt: "2026-10-20T00:47:26.000Z",
  download: "https://github.com/dgattey/demo/releases/download/v1.2.0/Demo-1.2.0.zip",
  sizeBytes: 5921083,
  notes: [{ version: "1.2.0", html: "<ul><li>New icon.</li></ul>" }],
};

const feed = (...builds: number[]) =>
  `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>` +
  builds.map((build) => `<item><sparkle:version>${build}</sparkle:version></item>`).join("") +
  `</channel></rss>`;

/** Answers each URL in `routes`; any other URL fails like an unreachable host. */
function serve(routes: Record<string, () => Response>) {
  mock.method(globalThis, "fetch", async (input: string) => {
    const route = routes[input];
    if (!route) throw new TypeError("fetch failed");
    return route();
  });
}

beforeEach(() => delete process.env.DYLKIT_LIVE_BUILD);
afterEach(() => mock.restoreAll());

describe("latestAssetURL", () => {
  it("points at the forge's newest release", () => {
    assert.equal(
      latestAssetURL({ kind: "github", repo: "dgattey/saga" }, "appcast.xml"),
      "https://github.com/dgattey/saga/releases/latest/download/appcast.xml",
    );
    assert.equal(
      latestAssetURL({ kind: "origin", repo: "dgattey/saga", assets: "https://saga.public.blob.vercel-storage.com" }, "release.json"),
      "https://saga.public.blob.vercel-storage.com/release.json",
    );
  });
});

describe("latestRelease", () => {
  it("reads the forge's release.json", async () => {
    serve({ [latest("release.json")]: () => Response.json(release) });
    assert.deepEqual(await latestRelease(site), release);
  });

  it("is null when release.json can't be read", async () => {
    serve({ [latest("release.json")]: () => new Response("Not Found", { status: 404 }) });
    assert.equal(await latestRelease(site), null);
    serve({});
    assert.equal(await latestRelease(site), null);
  });

  it("is null when the release is older than the build this deploy replaced", async () => {
    serve({ [latest("release.json")]: () => Response.json(release) });
    process.env.DYLKIT_LIVE_BUILD = "32";
    assert.equal(await latestRelease(site), null);
    process.env.DYLKIT_LIVE_BUILD = "31";
    assert.deepEqual(await latestRelease(site), release);
  });

  it("is null when the build isn't an integer", async () => {
    serve({ [latest("release.json")]: () => Response.json({ ...release, build: "31b" }) });
    assert.equal(await latestRelease(site), null);
  });
});

describe("appcastResponse", () => {
  it("serves the forge's newest feed for a minute", async () => {
    serve({ [latest("appcast.xml")]: () => new Response(feed(29, 31, 30)) });
    process.env.DYLKIT_LIVE_BUILD = "31";
    const response = await appcastResponse(site);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "application/xml");
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=60");
    assert.equal(await response.text(), feed(29, 31, 30));
  });

  it("is unavailable when the feed's newest build is older than the build this deploy replaced", async () => {
    serve({ [latest("appcast.xml")]: () => new Response(feed(29, 31, 30)) });
    process.env.DYLKIT_LIVE_BUILD = "32";
    const response = await appcastResponse(site);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("Retry-After"), "60");
  });

  it("is unavailable when the feed can't be fully parsed", async () => {
    const truncated = feed(29, 31, 30).slice(0, -40);
    const nonIntegerBuild = feed(29, 31).replace("<sparkle:version>29", "<sparkle:version>1.0b");
    for (const body of [truncated, nonIntegerBuild]) {
      serve({ [latest("appcast.xml")]: () => new Response(body) });
      assert.equal((await appcastResponse(site)).status, 503);
    }
    serve({ [live]: () => new Response(truncated) });
    await assert.rejects(liveBuild("https://demo.gattey.com"), /isn't an appcast/);
  });

  it("is unavailable when the feed can't be read", async () => {
    for (const answer of [() => new Response("oops", { status: 500 }), () => new Response("<html></html>")]) {
      serve({ [latest("appcast.xml")]: answer });
      assert.equal((await appcastResponse(site)).status, 503);
    }
    serve({});
    const response = await appcastResponse(site);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("Retry-After"), "60");
  });
});

describe("downloadResponse", () => {
  it("redirects to the newest release's zip", async () => {
    serve({ [latest("release.json")]: () => Response.json(release) });
    const response = await downloadResponse(site);
    assert.equal(response.status, 302);
    assert.equal(response.headers.get("Location"), release.download);
  });

  it("is unavailable without a release", async () => {
    serve({});
    const response = await downloadResponse(site);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("Retry-After"), "60");
  });
});

describe("liveBuild", () => {
  it("is the deployed feed's newest build", async () => {
    serve({ [live]: () => new Response(feed(29, 31, 30)) });
    assert.equal(await liveBuild("https://demo.gattey.com/"), 31);
  });

  it("is 0 on a site's first deploy", async () => {
    serve({ [live]: () => new Response("Not Found", { status: 404 }) });
    assert.equal(await liveBuild("https://demo.gattey.com"), 0);
  });

  it("throws when the deployed feed can't be read", async () => {
    serve({ [live]: () => new Response("oops", { status: 500 }) });
    await assert.rejects(liveBuild("https://demo.gattey.com"), /HTTP 500/);
    serve({ [live]: () => new Response("<html>Vercel login</html>") });
    await assert.rejects(liveBuild("https://demo.gattey.com"), /HTTP 200 isn't an appcast/);
    serve({});
    await assert.rejects(liveBuild("https://demo.gattey.com"), /demo\.gattey\.com\/appcast\.xml: fetch failed/);
  });
});
