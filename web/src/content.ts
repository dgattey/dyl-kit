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

/** Consecutive versions without notes collapse into one row. */
export type VersionRow =
  | { kind: "notes"; entry: Version }
  | { kind: "quiet"; newest: string; oldest: string; count: number };

/** Every version of one minor release, newest first: "1.8" with 1.8.2, 1.8.1 and 1.8.0. */
export type VersionGroup = {
  minor: string;
  count: number;
  /** "3 releases · Oct 14 – 21, 2026" */
  meta: string;
  rows: VersionRow[];
};

export type SplitHistory = {
  /** The newest versions, each shown as a card. */
  recent: Version[];
  /** The rest, folded into one card whose `summary` names them. Groups past the row budget are left to `/releases`. */
  earlier: { summary: string; groups: VersionGroup[]; truncated: boolean } | null;
  /** Every release the history knows. */
  total: number;
};

/**
 * Splits the release's history into the cards a page shows and the versions it folds away. The cards are
 * `release.json`'s newest notes; the folded versions come from `history.json` when there is one, which carries every
 * release, and otherwise from the rest of `release.json`'s ten. The folded card shows whole minor-version groups while
 * they fit in `rows` rows.
 */
export function splitHistory(
  release: Release,
  history: HistoryEntry[] | null,
  { recent = 3, rows = Infinity }: { recent?: number; rows?: number } = {},
): SplitHistory {
  const dated = new Map(history?.map((entry) => [entry.version, entry.publishedAt]));
  const cards = release.notes.slice(0, recent).map((entry) => ({ ...entry, publishedAt: dated.get(entry.version) }));
  const all = history ? newestFirst(history.filter((entry) => compareVersions(entry.version, release.version) <= 0)) : release.notes;
  const oldestCard = cards.at(-1)?.version ?? release.version;
  const folded = all.filter((entry) => compareVersions(entry.version, oldestCard) < 0);
  const total = Math.max(all.length, cards.length);
  if (folded.length === 0) return { recent: cards, earlier: null, total };

  const groups = groupByMinor(folded);
  const shown: VersionGroup[] = [];
  let budget = rows;
  for (const group of groups) {
    if (shown.length > 0 && group.rows.length > budget) break;
    shown.push(group);
    budget -= group.rows.length;
  }
  const newest = folded[0].version;
  const oldest = folded.at(-1)!.version;
  const summary = folded.length === 1 ? `1 earlier version, ${newest}` : `${folded.length} earlier versions, ${oldest} to ${newest}`;
  return { recent: cards, earlier: { summary, groups: shown, truncated: shown.length < groups.length }, total };
}

/** Newest-first versions grouped by minor version, each run of versions without notes collapsed into one row. */
export function groupByMinor(versions: Version[]): VersionGroup[] {
  const groups: { minor: string; versions: Version[] }[] = [];
  for (const entry of versions) {
    const minor = entry.version.split(".").slice(0, 2).join(".");
    if (groups.at(-1)?.minor === minor) groups.at(-1)!.versions.push(entry);
    else groups.push({ minor, versions: [entry] });
  }
  return groups.map(({ minor, versions: inGroup }) => ({
    minor,
    count: inGroup.length,
    meta: groupMeta(inGroup),
    rows: rowsOf(inGroup),
  }));
}

function rowsOf(versions: Version[]): VersionRow[] {
  const rows: VersionRow[] = [];
  for (const entry of versions) {
    const last = rows.at(-1);
    if (entry.html.trim()) rows.push({ kind: "notes", entry });
    else if (last?.kind === "quiet") rows[rows.length - 1] = { ...last, oldest: entry.version, count: last.count + 1 };
    else rows.push({ kind: "quiet", newest: entry.version, oldest: entry.version, count: 1 });
  }
  return rows;
}

function groupMeta(versions: Version[]): string {
  const count = versions.length === 1 ? "1 release" : `${versions.length} releases`;
  const published = versions.flatMap((entry) => (entry.publishedAt ? [new Date(entry.publishedAt)] : []));
  if (published.length === 0) return count;
  const newest = published[0];
  const oldest = published.at(-1)!;
  return `${count} · ${oldest.getTime() === newest.getTime() ? dates.format(newest) : dates.formatRange(oldest, newest)}`;
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
