import type { ReactNode } from "react";
import { DownloadPage } from "./DownloadPage";
import { siteMetadata } from "./next";
import { latestRelease } from "./release";
import { site } from "./site";
import { SiteLayout } from "./SiteLayout";

/** `app/layout.tsx`: `export { Layout as default, metadata } from "@dylkit/web/app";` */
export const metadata = siteMetadata(site);

export function Layout({ children }: { children: ReactNode }) {
  return <SiteLayout site={site}>{children}</SiteLayout>;
}

/** `app/page.tsx`: `export { Page as default } from "@dylkit/web/app";` */
export async function Page() {
  return <DownloadPage site={site} release={await latestRelease(site)} />;
}
