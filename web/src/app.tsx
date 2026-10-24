import type { ReactNode } from "react";
import { Hero } from "./Hero";
import { siteMetadata } from "./next";
import { latestRelease } from "./release";
import { ReleaseNotes } from "./ReleaseNotes";
import { Gallery } from "./Screenshot";
import { Features, SitePage } from "./Section";
import { site } from "./site";
import { SiteLayout } from "./SiteLayout";

/** `app/layout.tsx`: `export { Layout as default, metadata } from "@dylkit/web/app";` */
export const metadata = siteMetadata(site);

export function Layout({ children }: { children: ReactNode }) {
  return <SiteLayout site={site}>{children}</SiteLayout>;
}

/**
 * `app/page.tsx`: `export { Page as default } from "@dylkit/web/app";`. An app that wants another layout writes its
 * own page from the same components, which `@dylkit/web` exports.
 */
export async function Page() {
  const release = await latestRelease(site);
  return (
    <SitePage>
      <Hero release={release} />
      <Gallery />
      <Features />
      <ReleaseNotes release={release} />
    </SitePage>
  );
}
