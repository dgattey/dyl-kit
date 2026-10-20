import type { Metadata } from "next";
import type { Site } from "./site";

/** `/download/macos`: redirects to the latest zip. Export it from a `force-static` route so it runs at build time. */
export function downloadResponse(site: Site): Response {
  const release = site.release;
  if (!release) return Response.json({ error: "No macOS release is published yet." }, { status: 404 });
  if (!release.downloadReady) {
    return Response.json(
      { error: "That release is still deploying. Try again in a minute." },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
  const sameSite = new URL(release.downloadUrl).origin === new URL(site.siteUrl).origin;
  return new Response(null, { status: 302, headers: { Location: sameSite ? release.zipPath : release.downloadUrl } });
}

export function siteMetadata(site: Site): Metadata {
  const description = `Download ${site.name} for macOS. ${site.tagline}`;
  const image = site.screenshots[0];
  return {
    metadataBase: new URL(site.siteUrl),
    title: site.name,
    description,
    icons: { icon: "/app-icon.png", apple: site.appleIcon },
    alternates: { types: { "application/rss+xml": "/appcast.xml" } },
    openGraph: {
      title: site.name,
      description,
      url: "/",
      type: "website",
      images: image ? [{ url: image.src, width: image.width, height: image.height, alt: image.alt }] : undefined,
    },
  };
}
