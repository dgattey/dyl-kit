import type { ReactNode } from "react";
import { formatDate, recentReleases, releaseList } from "./content";
import type { Version } from "./content";
import { cx } from "./cx";
import { releaseHistory } from "./release";
import type { Release } from "./release";
import { Section } from "./Section";
import cards from "./Section.module.css";
import { site } from "./site";
import styles from "./ReleaseNotes.module.css";

/**
 * The newest versions' notes as cards, with a link to `allReleases` when there are more releases than cards. The
 * section's `id` is `release-notes`, which the "What's new" button points at.
 */
export async function ReleaseNotes({
  release,
  eyebrow = "Release notes",
  title = "What's new",
  recent = 3,
  allReleases = "/releases",
  className,
}: {
  release: Release | null;
  eyebrow?: ReactNode;
  title?: ReactNode;
  recent?: number;
  /** `app/releases/page.tsx`'s path, or null for an app without one. */
  allReleases?: string | null;
  className?: string;
}) {
  if (!release?.notes.length) return null;
  const { cards: shown, total } = recentReleases(release, await releaseHistory(site), recent);
  return (
    <Section id="release-notes" eyebrow={eyebrow} title={title} className={className}>
      <ol className={styles.recent}>
        {shown.map((entry, index) => (
          <ReleaseCard key={entry.version} entry={entry} latest={index === 0} className={styles.third} />
        ))}
      </ol>
      {allReleases && total > shown.length ? (
        <a className={styles.all} href={allReleases}>
          All releases
        </a>
      ) : null}
    </Section>
  );
}

/**
 * Every release as a card, newest first, for `app/releases/page.tsx`. Reads `history.json`, or `release.json`'s newest
 * ten when it's missing.
 */
export async function AllReleases({ release, className }: { release: Release | null; className?: string }) {
  const versions = releaseList(release, await releaseHistory(site));
  const lead = !versions.length
    ? `${site.name} hasn't been released yet. Each version's notes will be listed here once it ships.`
    : `${versions.length === 1 ? "1 release" : `${versions.length} releases`} of ${site.name}, newest first.`;
  return (
    <div className={cx(styles.allPage, className)}>
      <header className={styles.allHeader}>
        <a href="/" className={styles.back}>
          {/* Each release uploads the icons before release.json, so without a release there's no icon to show. */}
          {release ? (
            <picture>
              <source srcSet="/icons/icon-256-dark.png" media="(prefers-color-scheme: dark)" />
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/icons/icon-256.png" alt="" width={256} height={256} className={styles.backIcon} />
            </picture>
          ) : null}
          {site.name}
        </a>
        <h1 className={styles.allTitle}>Release history</h1>
        <p className={styles.allLead}>{lead}</p>
      </header>
      {versions.length ? (
        <ol className={styles.allList}>
          {versions.map((entry, index) => (
            <ReleaseCard key={entry.version} entry={entry} latest={index === 0} Heading="h2" />
          ))}
        </ol>
      ) : null}
    </div>
  );
}

/** One release: version, date and notes. release-kit renders the notes' Markdown to HTML when it publishes. */
function ReleaseCard({
  entry,
  latest,
  Heading = "h3",
  className,
}: {
  entry: Version;
  latest: boolean;
  Heading?: "h2" | "h3";
  className?: string;
}) {
  return (
    <li className={cx(cards.card, styles.release, className)}>
      <div className={styles.header}>
        <Heading className={styles.version}>Version {entry.version}</Heading>
        {latest ? <span className={styles.latest}>Latest</span> : null}
      </div>
      {entry.publishedAt ? (
        <time className={styles.date} dateTime={entry.publishedAt}>
          {formatDate(entry.publishedAt)}
        </time>
      ) : null}
      {entry.html.trim() ? (
        <div className={styles.notes} dangerouslySetInnerHTML={{ __html: entry.html }} />
      ) : (
        <p className={styles.noNotes}>No release notes.</p>
      )}
    </li>
  );
}
