import type { Site } from "./site";

/** Other sites can fetch `/icon.png` and `/apple-touch-icon.png` cross-origin, and show a new icon within the hour. */
const cacheControl = "public, max-age=3600, stale-while-revalidate=86400";

/**
 * An icon the latest release rendered from the app's icon and uploaded to the store's `icons/`, named by the request's
 * last path segment: `/icons/<name>`, so a size or format release-kit adds is live without a site change, and the root
 * `/icon.png`, `/apple-touch-icon.png` and `/favicon.ico`. The store's ETag passes through, so revalidating answers 304.
 */
export async function iconResponse(site: Site, request: Request): Promise<Response> {
  const { pathname } = new URL(request.url);
  const name = pathname === "/favicon.ico" && site.favicon === "dark" ? "favicon-dark.ico" : pathname.split("/").pop();
  if (!name || !/^[a-z0-9-]+\.(png|ico)$/.test(name)) return new Response(null, { status: 404 });
  const etag = request.headers.get("If-None-Match");
  const upstream = await fetch(`${site.assets}/icons/${name}`, {
    headers: etag ? { "If-None-Match": etag } : {},
    cache: "no-store",
  }).catch(() => null);
  if (upstream?.status !== 200 && upstream?.status !== 304) {
    return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
  }
  const headers = new Headers({ "Cache-Control": cacheControl, "Access-Control-Allow-Origin": "*" });
  for (const key of ["ETag", "Content-Type", "Last-Modified"]) {
    const value = upstream.headers.get(key);
    if (value) headers.set(key, value);
  }
  return new Response(upstream.status === 304 ? null : upstream.body, { status: upstream.status, headers });
}
