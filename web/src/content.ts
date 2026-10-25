import type { HistoryEntry, Release } from "./release";
import type { Screenshot, Site } from "./site";

/** The `[site] screenshots` entry whose `src` is `src`, as written in `DylApp.toml`. An unknown name fails the build. */
export function screenshotNamed(site: Site, src: string): Screenshot {
  const shot = site.screenshots.find((entry) => entry.src === `/${src}`);
  if (shot) return shot;
  const known = site.screenshots.map((entry) => entry.src.slice(1)).join(", ") || "none";
  throw new Error(`@dylkit/web: no [site] screenshots entry has src "${src}" (known: ${known})`);
}

/** "macOS 14+ · Apple Silicon" */
export function requirements(release: Release): string {
  const os = `macOS ${release.minimumSystemVersion.replace(/\.0$/, "")}+`;
  return release.appleSiliconOnly ? `${os} · Apple Silicon` : os;
}

const dates = new Intl.DateTimeFormat("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });

/** "Oct 22, 2026" */
export function formatDate(iso: string): string {
  return dates.format(new Date(iso));
}

/** "5.9 MB · Oct 22, 2026" */
export function releaseFacts(release: Release): string {
  const size = `${(release.sizeBytes / 1_000_000).toFixed(1)} MB`;
  return release.publishedAt ? `${size} · ${formatDate(release.publishedAt)}` : size;
}

/** A version's notes, with its date when `history.json` has one. Empty `html` means it shipped without notes. */
export type Version = { version: string; publishedAt?: string; html: string };

/**
 * Every release, newest first: `history.json` when there is one, which carries every release, and otherwise
 * `release.json`'s newest ten. Releases newer than `release.json` are left out, since `history.json` is uploaded first.
 */
export function releaseList(release: Release | null, history: HistoryEntry[] | null): Version[] {
  if (!history) return release?.notes ?? [];
  const published = release ? history.filter((entry) => compareVersions(entry.version, release.version) <= 0) : history;
  return newestFirst(published);
}

/** `release.json`'s newest `count` notes as cards, dated from `history.json`, and how many releases there are in all. */
export function recentReleases(
  release: Release,
  history: HistoryEntry[] | null,
  count = 3,
): { cards: Version[]; total: number } {
  const dated = new Map(history?.map((entry) => [entry.version, entry.publishedAt]));
  const cards = release.notes.slice(0, count).map((entry) => ({ ...entry, publishedAt: dated.get(entry.version) }));
  return { cards, total: Math.max(releaseList(release, history).length, cards.length) };
}

/** Newest first, one entry per version. */
export function newestFirst<T extends { version: string }>(entries: T[]): T[] {
  const seen = new Set<string>();
  return [...entries]
    .sort((a, b) => compareVersions(b.version, a.version))
    .filter((entry) => !seen.has(entry.version) && seen.add(entry.version));
}

/** Compares dotted versions numerically: 1.10.0 is after 1.9.3. */
export function compareVersions(a: string, b: string): number {
  const left = a.match(/\d+/g)?.map(Number) ?? [];
  const right = b.match(/\d+/g)?.map(Number) ?? [];
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}
