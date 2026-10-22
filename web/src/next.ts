import type { Metadata } from "next";
import type { Site } from "./site";

export function siteMetadata(site: Site): Metadata {
  const description = `Download ${site.name} for macOS. ${site.tagline}`;
  const image = site.screenshots[0] ?? { src: "/icon.png", width: 1024, height: 1024, alt: site.name };
  return {
    metadataBase: new URL(site.siteUrl),
    title: site.name,
    description,
    icons: { icon: "/favicon.ico", apple: "/apple-touch-icon.png" },
    alternates: { types: { "application/rss+xml": "/appcast.xml" } },
    openGraph: {
      title: site.name,
      description,
      url: "/",
      type: "website",
      images: [{ url: image.src, width: image.width, height: image.height, alt: image.alt }],
    },
  };
}
