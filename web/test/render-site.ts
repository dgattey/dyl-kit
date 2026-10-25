import type { Site } from "../src/site.ts";

/** The `site` components read, which `withDylKit` would inline. Import this before any component. */
export const testSite: Site = {
  name: "Demo",
  tagline: "A demo app.",
  siteUrl: "https://demo.example.com",
  accent: null,
  favicon: "light",
  headingFont: "sans",
  screenshots: [],
  features: [],
  assets: "https://demo.public.blob.vercel-storage.com",
};

process.env.DYLKIT_SITE = JSON.stringify(testSite);
