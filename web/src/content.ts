import type { Release, ReleaseNotes } from "./release";
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

/** "5.9 MB · Oct 22, 2026" */
export function releaseFacts(release: Release): string {
  const size = `${(release.sizeBytes / 1_000_000).toFixed(1)} MB`;
  const date = release.publishedAt
    ? new Date(release.publishedAt).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" })
    : null;
  return date ? `${size} · ${date}` : size;
}

export type ReleaseHistory = {
  /** The newest versions, each shown as a card. */
  recent: ReleaseNotes[];
  /** The rest, folded into one card whose `summary` names them. */
  earlier: { summary: string; notes: ReleaseNotes[] } | null;
};

/** Splits `release.json`'s newest-first notes into the cards a page shows and the versions it folds away. */
export function releaseHistory(notes: ReleaseNotes[], recent = 3): ReleaseHistory {
  const earlier = notes.slice(recent);
  if (earlier.length === 0) return { recent: notes, earlier: null };
  const oldest = earlier.at(-1)!.version;
  const newest = earlier[0].version;
  const summary =
    earlier.length === 1
      ? `1 earlier version, ${newest}`
      : `${earlier.length} earlier versions, ${oldest} to ${newest}`;
  return { recent: notes.slice(0, recent), earlier: { summary, notes: earlier } };
}
