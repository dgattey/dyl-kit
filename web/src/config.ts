import type { NextConfig } from "next";
import { PHASE_PRODUCTION_BUILD } from "next/constants";
import { liveBuild } from "./release";
import { loadSite, type Site } from "./site";

/**
 * Wraps `next.config.ts`. During `next build` it records the newest build the deployed site serves as
 * `DYLKIT_LIVE_BUILD`, so this deploy refuses any feed or release older than what it replaces. Import it from
 * `@dylkit/web/config`: the package root pulls in the React page, which Next can't load into its config.
 */
export function withDylKit(nextConfig: NextConfig, site: Site = loadSite()) {
  return async (phase: string): Promise<NextConfig> => {
    if (phase !== PHASE_PRODUCTION_BUILD) return nextConfig;
    const build = await liveBuild(site.siteUrl);
    return { ...nextConfig, env: { ...nextConfig.env, DYLKIT_LIVE_BUILD: String(build) } };
  };
}
