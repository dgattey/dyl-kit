import type { Site } from "./site";

export type ReleaseNotes = { version: string; html: string };

/** `release.json`, which release-kit publishes beside each release's `appcast.xml`. */
export type Release = {
  version: string;
  build: number;
  minimumSystemVersion: string;
  appleSiliconOnly: boolean;
  /** ISO 8601. */
  publishedAt?: string;
  /** The zip's URL. */
  download: string;
  sizeBytes: number;
  /** Newest first, versions without notes left out. */
  notes: ReleaseNotes[];
};

/** The newest release, or null when it can't be read. */
export async function latestRelease(site: Site): Promise<Release | null> {
  try {
    const response = await fetch(`${site.assets}/release.json`, { next: { revalidate: 60 } });
    if (!response.ok) return null;
    const release: Release = await response.json();
    return Number.isInteger(release.build) ? release : null;
  } catch {
    return null;
  }
}

/** `/appcast.xml`: the Blob store's newest feed, which Sparkle polls. */
export async function appcastResponse(site: Site): Promise<Response> {
  const feed = await fetch(`${site.assets}/appcast.xml`, { next: { revalidate: 60 } })
    .then((response) => (response.ok ? response.text() : null))
    .catch(() => null);
  if (feed === null || !isCompleteFeed(feed)) return unavailable("The update feed");
  return new Response(feed, {
    headers: { "Content-Type": "application/xml", "Cache-Control": "public, max-age=60" },
  });
}

/** `/download/macos`: redirects to the newest release's zip. */
export async function downloadResponse(site: Site): Promise<Response> {
  const release = await latestRelease(site);
  if (!release) return unavailable("The download");
  return new Response(null, { status: 302, headers: { Location: release.download } });
}

/** A truncated feed must not read as a short one, so every item needs an integer build and the feed must end. */
function isCompleteFeed(feed: string): boolean {
  if (!/<\/rss>\s*$/.test(feed)) return false;
  const items = [...feed.matchAll(/<item\b[\s\S]*?<\/item>/g)];
  if (items.length === 0 || items.length !== feed.match(/<item\b/g)?.length) return false;
  return items.every(([item]) => /<sparkle:version>\s*\d+\s*<\/sparkle:version>/.test(item));
}

function unavailable(what: string): Response {
  return Response.json(
    { error: `${what} is unavailable. Try again in a minute.` },
    { status: 503, headers: { "Retry-After": "60" } },
  );
}
