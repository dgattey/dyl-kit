import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { releaseFacts, releaseHistory, requirements, screenshotNamed } from "../src/content.ts";
import type { Release } from "../src/release.ts";
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

describe("releaseHistory", () => {
  it("shows every version as a card when there are three or fewer", () => {
    const history = releaseHistory(notes("1.2", "1.1"));
    assert.deepEqual(
      history.recent.map((entry) => entry.version),
      ["1.2", "1.1"],
    );
    assert.equal(history.earlier, null);
  });

  it("folds the rest into one card named by its oldest and newest versions", () => {
    const history = releaseHistory(notes("1.1.11", "1.1.10", "1.1.9", "1.1.8", "1.1.7", "1.1.6", "1.1.5", "1.1.4", "1.1.3", "1.1.2"));
    assert.deepEqual(
      history.recent.map((entry) => entry.version),
      ["1.1.11", "1.1.10", "1.1.9"],
    );
    assert.equal(history.earlier?.summary, "7 earlier versions, 1.1.2 to 1.1.8");
    assert.deepEqual(
      history.earlier?.notes.map((entry) => entry.version),
      ["1.1.8", "1.1.7", "1.1.6", "1.1.5", "1.1.4", "1.1.3", "1.1.2"],
    );
  });

  it("names a single earlier version on its own", () => {
    assert.equal(releaseHistory(notes("4", "3", "2", "1")).earlier?.summary, "1 earlier version, 1");
  });

  it("takes how many cards to show", () => {
    const history = releaseHistory(notes("3", "2", "1"), 1);
    assert.equal(history.recent.length, 1);
    assert.equal(history.earlier?.summary, "2 earlier versions, 1 to 2");
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
