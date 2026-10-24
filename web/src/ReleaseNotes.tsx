import type { ReactNode } from "react";
import { releaseHistory } from "./content";
import { cx } from "./cx";
import type { Release, ReleaseNotes as Notes } from "./release";
import { Section } from "./Section";
import cards from "./Section.module.css";
import styles from "./ReleaseNotes.module.css";

/**
 * The newest versions' notes as cards, then every older version folded into one card that opens to a compact list.
 * The section's `id` is `release-notes`, which Sparkle's full-notes link and the "What's new" button point at.
 */
export function ReleaseNotes({
  release,
  eyebrow = "Release notes",
  title = "What's new",
  recent = 3,
  className,
}: {
  release: Release | null;
  eyebrow?: ReactNode;
  title?: ReactNode;
  recent?: number;
  className?: string;
}) {
  if (!release?.notes.length) return null;
  const history = releaseHistory(release.notes, recent);
  return (
    <Section id="release-notes" eyebrow={eyebrow} title={title} className={className}>
      <ul className={styles.recent}>
        {history.recent.map((entry, index) => (
          <li key={entry.version} className={cx(cards.card, styles.release)}>
            <div className={styles.header}>
              <h3 className={styles.version}>Version {entry.version}</h3>
              {index === 0 ? <span className={styles.latest}>Latest</span> : null}
            </div>
            <NotesBody entry={entry} />
          </li>
        ))}
      </ul>
      {history.earlier ? (
        <details className={cx(cards.card, styles.earlier)}>
          <summary className={styles.summary}>{history.earlier.summary}</summary>
          <ol className={styles.list}>
            {history.earlier.notes.map((entry) => (
              <li key={entry.version} className={styles.entry}>
                <h3 className={styles.entryVersion}>{entry.version}</h3>
                <NotesBody entry={entry} />
              </li>
            ))}
          </ol>
        </details>
      ) : null}
    </Section>
  );
}

/** release-kit renders each version's Markdown to HTML when it publishes `release.json`. */
function NotesBody({ entry }: { entry: Notes }) {
  return <div className={styles.notes} dangerouslySetInnerHTML={{ __html: entry.html }} />;
}
