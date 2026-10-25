import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { compareVersions, recentReleases, releaseFacts, releaseList, requirements, screenshotNamed } from "../src/content.ts";
import type { HistoryEntry, Release } from "../src/release.ts";
import type { Site } from "../src/site.ts";

const release = (overrides: Partial<Release> = {}): Release => ({
  version: "1.1.11",
  build: 42,
  minimumSystemVersion: "14.0",
  appleSiliconOnly: false,
  publishedAt: "2026-10-22T18:30:00Z",
  download: "https://demo.public.blob.vercel-storage.com/Demo-1.1.11.zip",
  sizeBytes: 5_912_345,
  notes: [],
  ...overrides,
});

const notes = (...versions: string[]) => versions.map((version) => ({ version, html: `<ul><li>${version}</li></ul>` }));

const entry = (version: string, html = `<p>${version}</p>`, publishedAt?: string): HistoryEntry => ({ version, html, publishedAt });

const history = [
  entry("1.10.0", "<p>1.10.0</p>", "2026-10-22T10:00:00Z"),
  entry("1.9.3"),
  entry("1.9.2", ""),
  entry("1.9.1"),
  entry("1.8.0", "", "2026-10-10T10:00:00Z"),
];

describe("recentReleases", () => {
  it("shows release.json's newest notes as cards, dated from history.json", () => {
    const { cards, total } = recentReleases(release({ version: "1.10.0", notes: notes("1.10.0", "1.9.3", "1.9.1", "1.8.0") }), history);
    assert.deepEqual(
      cards.map((card) => [card.version, card.publishedAt]),
      [
        ["1.10.0", "2026-10-22T10:00:00Z"],
        ["1.9.3", undefined],
        ["1.9.1", undefined],
      ],
    );
    assert.equal(total, 5);
  });

  it("counts only release.json's versions without history.json", () => {
    const { cards, total } = recentReleases(release({ version: "1.2", notes: notes("1.2", "1.1") }), null, 1);
    assert.deepEqual(cards.map((card) => card.version), ["1.2"]);
    assert.equal(total, 2);
  });
});

describe("releaseList", () => {
  it("lists every release in history.json newest first, keeping those without notes", () => {
    assert.deepEqual(
      releaseList(release({ version: "1.10.0" }), [...history].reverse()).map((version) => [version.version, version.html]),
      [
        ["1.10.0", "<p>1.10.0</p>"],
        ["1.9.3", "<p>1.9.3</p>"],
        ["1.9.2", ""],
        ["1.9.1", "<p>1.9.1</p>"],
        ["1.8.0", ""],
      ],
    );
  });

  it("leaves out releases newer than release.json, which history.json is uploaded before", () => {
    assert.deepEqual(
      releaseList(release({ version: "1.9.3" }), history).map((version) => version.version),
      ["1.9.3", "1.9.2", "1.9.1", "1.8.0"],
    );
  });

  it("falls back to release.json's notes", () => {
    assert.deepEqual(
      releaseList(release({ notes: notes("1.1.11", "1.1.10") }), null).map((version) => version.version),
      ["1.1.11", "1.1.10"],
    );
    assert.deepEqual(releaseList(null, null), []);
  });
});

describe("compareVersions", () => {
  it("compares each part as a number", () => {
    assert.ok(compareVersions("1.10.0", "1.9.3") > 0);
    assert.ok(compareVersions("1.0", "1.0.0") === 0);
    assert.ok(compareVersions("0.9", "1.0") < 0);
  });
});

describe("requirements", () => {
  it("drops a trailing .0 and notes Apple Silicon", () => {
    assert.equal(requirements(release()), "macOS 14+");
    assert.equal(requirements(release({ minimumSystemVersion: "15.4", appleSiliconOnly: true })), "macOS 15.4+ · Apple Silicon");
  });
});

describe("releaseFacts", () => {
  it("gives the size and the UTC publish date", () => {
    assert.equal(releaseFacts(release()), "5.9 MB · Oct 22, 2026");
    assert.equal(releaseFacts(release({ publishedAt: undefined })), "5.9 MB");
  });
});

describe("screenshotNamed", () => {
  const site = {
    screenshots: [
      { src: "/board.png", alt: "A board", width: 10, height: 10 },
      { src: "/phone.webp", alt: "On iPhone", width: 10, height: 20, frame: "iphone" },
    ],
  } as Site;

  it("finds an entry by the src DylApp.toml gives it", () => {
    assert.equal(screenshotNamed(site, "phone.webp").frame, "iphone");
  });

  it("fails the build for an unknown src and lists the known ones", () => {
    assert.throws(() => screenshotNamed(site, "missing.png"), /no \[site\] screenshots entry has src "missing\.png" \(known: board\.png, phone\.webp\)/);
    assert.throws(() => screenshotNamed({ screenshots: [] } as unknown as Site, "x.png"), /\(known: none\)/);
  });
});
