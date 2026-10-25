import assert from "node:assert/strict";
import { afterEach, describe, it, mock } from "node:test";
import { appcastResponse, downloadResponse, latestRelease } from "../src/release.ts";
import type { Release } from "../src/release.ts";
import type { Site } from "../src/site.ts";

const site: Site = {
  name: "Demo",
  tagline: "A demo app.",
  siteUrl: "https://demo.example.com",
  accent: null,
  appleIcon: "/app-icon.png",
  screenshots: [],
  assets: "https://demo.public.blob.vercel-storage.com",
};
const latest = (name: string) => `https://demo.public.blob.vercel-storage.com/${name}`;

const release: Release = {
  version: "1.2.0",
  build: 31,
  minimumSystemVersion: "15.0",
  appleSiliconOnly: true,
  publishedAt: "2026-10-20T00:47:26.000Z",
  download: "https://demo.public.blob.vercel-storage.com/releases/v1.2.0/Demo-1.2.0.zip",
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

afterEach(() => mock.restoreAll());

describe("latestRelease", () => {
  it("reads the Blob store's release.json", async () => {
    serve({ [latest("release.json")]: () => Response.json(release) });
    assert.deepEqual(await latestRelease(site), release);
  });

  it("is null when release.json can't be read", async () => {
    serve({ [latest("release.json")]: () => new Response("Not Found", { status: 404 }) });
    assert.equal(await latestRelease(site), null);
    serve({});
    assert.equal(await latestRelease(site), null);
  });

  it("is null when the build isn't an integer", async () => {
    serve({ [latest("release.json")]: () => Response.json({ ...release, build: "31b" }) });
    assert.equal(await latestRelease(site), null);
  });
});

describe("appcastResponse", () => {
  it("serves the Blob store's newest feed for a minute", async () => {
    serve({ [latest("appcast.xml")]: () => new Response(feed(29, 31, 30)) });
    const response = await appcastResponse(site);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "application/xml");
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=60");
    assert.equal(await response.text(), feed(29, 31, 30));
  });

  it("is unavailable when the feed can't be read or fully parsed", async () => {
    const truncated = feed(29, 31, 30).slice(0, -40);
    const nonIntegerBuild = feed(29, 31).replace("<sparkle:version>29", "<sparkle:version>1.0b");
    const bodies = [truncated, nonIntegerBuild, "<html></html>"].map((body) => new Response(body));
    for (const answer of [...bodies, new Response("oops", { status: 500 })]) {
      serve({ [latest("appcast.xml")]: () => answer });
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
