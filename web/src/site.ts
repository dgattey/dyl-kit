export type Screenshot = {
  /** Path under the artifacts dir, served from the site root. */
  src: string;
  /** Dark-appearance variant, shown when the visitor's system is in dark mode. */
  darkSrc?: string;
  alt: string;
  width: number;
  height: number;
};

export type Site = {
  name: string;
  tagline: string;
  siteUrl: string;
  accent: { light: string; dark: string } | null;
  /** `site.favicon`: which appearance the browser tab shows, for an icon whose light variant vanishes on a light tab. */
  favicon: "light" | "dark";
  screenshots: Screenshot[];
  /** `release.assets`: the public Blob store release-kit uploads each release to, without a trailing slash. */
  assets: string;
};

// Next replaces `process.env.DYLKIT_SITE` with the literal `withDylKit` set, so only that exact expression works.
const json = process.env.DYLKIT_SITE;
if (!json) throw new Error("@dylkit/web: wrap next.config.ts's config in withDylKit from @dylkit/web/config");

/** The app's `DylApp.toml` and screenshot sizes, as `withDylKit` read them when Next loaded the config. */
export const site: Site = JSON.parse(json);
