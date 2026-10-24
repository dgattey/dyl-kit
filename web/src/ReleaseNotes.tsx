import type { ReactNode } from "react";
import { formatDate, groupByMinor, newestFirst, splitHistory } from "./content";
import type { Version, VersionGroup, VersionRow } from "./content";
import { cx } from "./cx";
import { releaseHistory } from "./release";
import type { Release } from "./release";
import { Section } from "./Section";
import cards from "./Section.module.css";
import { site } from "./site";
import styles from "./ReleaseNotes.module.css";

/**
 * The newest versions' notes as cards, then every older version folded into one card that opens to them grouped by
 * minor version. Older versions come from `history.json`, which has every release, or from `release.json`'s newest ten
 * when it's missing. When they run past `rows` rows, the card shows the newest groups and links to `allReleases`.
 * The section's `id` is `release-notes`, which Sparkle's full-notes link and the "What's new" button point at.
 */
export async function ReleaseNotes({
  release,
  eyebrow = "Release notes",
  title = "What's new",
  recent = 3,
  rows = 12,
  allReleases = "/releases",
  className,
}: {
  release: Release | null;
  eyebrow?: ReactNode;
  title?: ReactNode;
  recent?: number;
  rows?: number;
  /** `app/releases/page.tsx`'s path, or null for an app without one, which shows every older version in place. */
  allReleases?: string | null;
  className?: string;
}) {
  if (!release?.notes.length) return null;
  const history = splitHistory(release, await releaseHistory(site), { recent, rows: allReleases ? rows : Infinity });
  return (
    <Section id="release-notes" eyebrow={eyebrow} title={title} className={className}>
      <ul className={styles.recent}>
        {history.recent.map((entry, index) => (
          <li key={entry.version} className={cx(cards.card, styles.release)}>
            <div className={styles.header}>
              <h3 className={styles.version}>Version {entry.version}</h3>
              {index === 0 ? <span className={styles.latest}>Latest</span> : null}
            </div>
            {entry.publishedAt ? <p className={styles.date}>{formatDate(entry.publishedAt)}</p> : null}
            <NotesBody html={entry.html} />
          </li>
        ))}
      </ul>
      {history.earlier ? (
        <details className={cx(cards.card, styles.earlier)}>
          <summary className={styles.summary}>{history.earlier.summary}</summary>
          <div className={styles.earlierBody}>
            <VersionGroups groups={history.earlier.groups} level={3} />
            {history.earlier.truncated && allReleases ? (
              <a className={styles.all} href={allReleases}>
                See all {history.total} releases
              </a>
            ) : null}
          </div>
        </details>
      ) : null}
    </Section>
  );
}

/**
 * Every release, newest first and grouped by minor version, for `app/releases/page.tsx`. Reads `history.json`, or
 * `release.json`'s newest ten when it's missing.
 */
export async function AllReleases({ release, className }: { release: Release | null; className?: string }) {
  const history = await releaseHistory(site);
  const versions: Version[] = history ? newestFirst(history) : (release?.notes ?? []);
  const count = versions.length === 1 ? "1 release" : `${versions.length} releases`;
  return (
    <div className={cx(styles.allPage, className)}>
      <header className={styles.allHeader}>
        <a href="/" className={styles.back}>
          <picture>
            <source srcSet="/icons/icon-256-dark.png" media="(prefers-color-scheme: dark)" />
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/icons/icon-256.png" alt="" width={256} height={256} className={styles.backIcon} />
          </picture>
          {site.name}
        </a>
        <h1 className={styles.allTitle}>Release history</h1>
        <p className={styles.allLead}>
          {count} of {site.name}, newest first.
        </p>
      </header>
      {versions.length ? (
        groupByMinor(versions).map((group) => (
          <div key={group.minor} className={cx(cards.card, styles.groupCard)}>
            <VersionGroups groups={[group]} level={2} />
          </div>
        ))
      ) : (
        <p className={styles.date}>No releases yet.</p>
      )}
    </div>
  );
}

function VersionGroups({ groups, level }: { groups: VersionGroup[]; level: 2 | 3 }) {
  const GroupHeading = level === 2 ? "h2" : "h3";
  const VersionHeading = level === 2 ? "h3" : "h4";
  return groups.map((group) => (
    <section key={group.minor} className={styles.group} aria-label={`Version ${group.minor}`}>
      <div className={styles.groupHeader}>
        <GroupHeading className={styles.groupTitle}>Version {group.minor}</GroupHeading>
        <span className={styles.groupMeta}>{group.meta}</span>
      </div>
      <ol className={styles.list}>
        {group.rows.map((row) => (
          <Row key={row.kind === "notes" ? row.entry.version : row.newest} row={row} Heading={VersionHeading} />
        ))}
      </ol>
    </section>
  ));
}

function Row({ row, Heading }: { row: VersionRow; Heading: "h3" | "h4" }) {
  switch (row.kind) {
    case "notes":
      return (
        <li className={styles.entry}>
          <div className={styles.entryHead}>
            <Heading className={styles.entryVersion}>{row.entry.version}</Heading>
            {row.entry.publishedAt ? (
              <time className={styles.date} dateTime={row.entry.publishedAt}>
                {formatDate(row.entry.publishedAt)}
              </time>
            ) : null}
          </div>
          <NotesBody html={row.entry.html} />
        </li>
      );
    case "quiet":
      return (
        <li className={cx(styles.entry, styles.quiet)}>
          <div className={styles.entryHead}>
            <Heading className={styles.entryVersion}>
              {row.count === 1 ? row.newest : `${row.oldest} – ${row.newest}`}
            </Heading>
          </div>
          <p className={styles.quietText}>{row.count === 1 ? "No release notes" : `${row.count} releases without notes`}</p>
        </li>
      );
    default: {
      const unhandled: never = row;
      throw new Error(`@dylkit/web: unknown row ${JSON.stringify(unhandled)}`);
    }
  }
}

/** release-kit renders each version's Markdown to HTML when it publishes `release.json` and `history.json`. */
function NotesBody({ html }: { html: string }) {
  return <div className={styles.notes} dangerouslySetInnerHTML={{ __html: html }} />;
}
