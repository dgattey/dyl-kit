import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { compareVersions, releaseFacts, requirements, screenshotNamed, splitHistory } from "../src/content.ts";
import type { VersionGroup } from "../src/content.ts";
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

const versionsOf = (groups: VersionGroup[]) =>
  groups.map((group) => [group.minor, group.rows.map((row) => (row.kind === "notes" ? row.entry.version : `${row.oldest}–${row.newest}`))]);

const entry = (version: string, html = `<p>${version}</p>`, publishedAt?: string): HistoryEntry => ({ version, html, publishedAt });

describe("splitHistory without history.json", () => {
  const latest = (...versions: string[]) => release({ version: versions[0], notes: notes(...versions) });

  it("shows every version as a card when there are three or fewer", () => {
    const history = splitHistory(latest("1.2", "1.1"), null);
    assert.deepEqual(
      history.recent.map((card) => card.version),
      ["1.2", "1.1"],
    );
    assert.equal(history.earlier, null);
  });

  it("folds the rest of release.json into one card named by its oldest and newest versions", () => {
    const history = splitHistory(latest("1.2.1", "1.2.0", "1.1.9", "1.1.8", "1.1.7", "1.0.2"), null);
    assert.deepEqual(
      history.recent.map((card) => card.version),
      ["1.2.1", "1.2.0", "1.1.9"],
    );
    assert.equal(history.earlier?.summary, "3 earlier versions, 1.0.2 to 1.1.8");
    assert.deepEqual(versionsOf(history.earlier!.groups), [
      ["1.1", ["1.1.8", "1.1.7"]],
      ["1.0", ["1.0.2"]],
    ]);
  });

  it("names a single earlier version on its own and takes how many cards to show", () => {
    assert.equal(splitHistory(latest("4", "3", "2", "1"), null).earlier?.summary, "1 earlier version, 1");
    const history = splitHistory(latest("3", "2", "1"), null, { recent: 1 });
    assert.equal(history.recent.length, 1);
    assert.equal(history.earlier?.summary, "2 earlier versions, 1 to 2");
  });
});

describe("splitHistory with history.json", () => {
  const history = [
    entry("1.10.0", "<p>1.10.0</p>", "2026-10-22T10:00:00Z"),
    entry("1.9.3"),
    entry("1.9.2", ""),
    entry("1.9.1"),
    entry("1.9.0"),
    entry("1.8.2", "", "2026-10-14T10:00:00Z"),
    entry("1.8.1", "", "2026-10-12T10:00:00Z"),
    entry("1.8.0", "<p>1.8.0</p>", "2026-10-10T10:00:00Z"),
    entry("1.0.0", ""),
  ];
  const cards = release({ version: "1.10.0", notes: notes("1.10.0", "1.9.3", "1.9.1", "1.9.0") });

  it("folds every older release, grouped by minor version with runs without notes collapsed", () => {
    const split = splitHistory(cards, history);
    assert.deepEqual(
      split.recent.map((card) => [card.version, card.publishedAt]),
      [
        ["1.10.0", "2026-10-22T10:00:00Z"],
        ["1.9.3", undefined],
        ["1.9.1", undefined],
      ],
    );
    assert.equal(split.earlier?.summary, "5 earlier versions, 1.0.0 to 1.9.0");
    assert.deepEqual(versionsOf(split.earlier!.groups), [
      ["1.9", ["1.9.0"]],
      ["1.8", ["1.8.1–1.8.2", "1.8.0"]],
      ["1.0", ["1.0.0–1.0.0"]],
    ]);
    assert.match(split.earlier!.groups[1].meta, /^3 releases · Oct 10\s–\s14, 2026$/);
    assert.equal(split.total, 9);
    assert.equal(split.earlier?.truncated, false);
  });

  it("shows whole groups while they fit in the row budget, and always the newest", () => {
    assert.deepEqual(versionsOf(splitHistory(cards, history, { rows: 3 }).earlier!.groups).map(([minor]) => minor), ["1.9", "1.8"]);
    const tight = splitHistory(cards, history, { rows: 0 });
    assert.deepEqual(versionsOf(tight.earlier!.groups).map(([minor]) => minor), ["1.9"]);
    assert.equal(tight.earlier?.truncated, true);
  });

  it("leaves out releases newer than release.json, which history.json is uploaded before", () => {
    const split = splitHistory(release({ version: "1.9.3", notes: notes("1.9.3", "1.9.1", "1.9.0") }), history);
    assert.equal(split.total, 8);
    assert.equal(split.earlier?.summary, "4 earlier versions, 1.0.0 to 1.8.2");
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
