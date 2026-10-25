import type { CSSProperties, ReactNode } from "react";
import type { Site } from "./site";
import "./theme.css";

/** The root `<html>` for an app's site: the shared theme, tinted with `[site] accent` and set in `[site] heading-font`. */
export function SiteLayout({ site, children }: { site: Site; children: ReactNode }) {
  const tokens: Record<string, string> = {};
  if (site.accent) {
    tokens["--accent-light"] = site.accent.light;
    tokens["--accent-dark"] = site.accent.dark;
  }
  if (site.headingFont === "serif") tokens["--font-display"] = "var(--font-serif)";
  return (
    <html lang="en">
      <body style={Object.keys(tokens).length ? (tokens as CSSProperties) : undefined}>{children}</body>
    </html>
  );
}
