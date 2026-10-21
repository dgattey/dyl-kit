import type { Metadata } from "next";
import type { Site } from "./site";

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
