import type { CSSProperties, ReactNode } from "react";
import type { Site } from "./site";
import "./theme.css";

/** The root `<html>` for an app's site: the shared theme, tinted with the app's `[site] accent`. */
export function SiteLayout({ site, children }: { site: Site; children: ReactNode }) {
  const accent = site.accent && ({ "--accent-light": site.accent.light, "--accent-dark": site.accent.dark } as CSSProperties);
  const hero = site.screenshots[0];
  return (
    <html lang="en">
      <head>{hero ? <link rel="preload" href={hero.src} as="image" /> : null}</head>
      <body style={accent || undefined}>{children}</body>
    </html>
  );
}
