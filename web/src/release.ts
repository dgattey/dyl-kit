import type { Forge, Site } from "./site";

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

/** Where the forge serves the asset `name` of its newest release. */
export function latestAssetURL(forge: Forge, name: string): string {
  switch (forge.kind) {
    case "github":
      return `https://github.com/${forge.repo}/releases/latest/download/${name}`;
    case "origin":
      return `${forge.assets}/${name}`;
    default: {
      const unknown: never = forge;
      throw new Error(`unknown forge ${JSON.stringify(unknown)}`);
    }
  }
}

/** The newest release, or null when it can't be read or is older than the build this deploy replaced. */
export async function latestRelease(site: Site): Promise<Release | null> {
  try {
    const response = await fetch(latestAssetURL(site.forge, "release.json"), { next: { revalidate: 60 } });
    if (!response.ok) return null;
    const release: Release = await response.json();
    return Number.isInteger(release.build) && release.build >= liveBuildFloor() ? release : null;
  } catch {
    return null;
  }
}

/** `/appcast.xml`: the forge's newest feed, which Sparkle polls. */
export async function appcastResponse(site: Site): Promise<Response> {
  const feed = await fetch(latestAssetURL(site.forge, "appcast.xml"), { next: { revalidate: 60 } })
    .then((response) => (response.ok ? response.text() : null))
    .catch(() => null);
  const build = feed === null ? null : newestBuild(feed);
  if (build === null || build < liveBuildFloor()) return unavailable("The update feed");
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

/**
 * The newest build in the deployed site's `appcast.xml`, or 0 when the site has none yet. Anything else throws, so a
 * build never deploys without knowing what it replaces.
 */
export async function liveBuild(siteUrl: string): Promise<number> {
  const url = `${siteUrl.replace(/\/$/, "")}/appcast.xml`;
  const response = await fetch(url).catch((error: Error) => {
    throw new Error(`${url}: ${error.message}`, { cause: error });
  });
  if (response.status === 404) return 0;
  const build = response.ok ? newestBuild(await response.text()) : null;
  if (build === null) throw new Error(`${url}: HTTP ${response.status} isn't an appcast`);
  return build;
}

/** Set by `withDylKit` during `next build`. */
function liveBuildFloor(): number {
  return Number(process.env.DYLKIT_LIVE_BUILD ?? 0);
}

/** Null unless the feed is complete and every item has an integer build: a truncated feed must not read as a short one. */
function newestBuild(feed: string): number | null {
  if (!/<\/rss>\s*$/.test(feed)) return null;
  const items = [...feed.matchAll(/<item\b[\s\S]*?<\/item>/g)];
  if (items.length === 0 || items.length !== feed.match(/<item\b/g)?.length) return null;
  const builds = items.map(([item]) => item.match(/<sparkle:version>\s*(\d+)\s*<\/sparkle:version>/)?.[1]);
  if (builds.some((build) => build === undefined)) return null;
  return Math.max(...builds.map(Number));
}

function unavailable(what: string): Response {
  return Response.json(
    { error: `${what} is unavailable. Try again in a minute.` },
    { status: 503, headers: { "Retry-After": "60" } },
  );
}
