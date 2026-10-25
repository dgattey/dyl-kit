import type { ReactNode } from "react";
import { cx } from "./cx";
import { site } from "./site";
import styles from "./Section.module.css";

type Props = { className?: string; children?: ReactNode };

/** The page: its width, the accent backdrop, the spacing between sections, and the footer. */
export function SitePage({ children, className }: Props) {
  return (
    <main className={cx(styles.page, className)}>
      {children}
      <footer className={styles.footer}>
        Made by <a href="https://dylangattey.com">Dylan Gattey</a>
      </footer>
    </main>
  );
}

/** A titled block of the page. The title and its eyebrow and lead are centered above the children. */
export function Section({
  eyebrow,
  title,
  lead,
  id,
  children,
  className,
}: Props & { eyebrow?: ReactNode; title?: ReactNode; lead?: ReactNode; id?: string }) {
  const titleId = id && title ? `${id}-title` : undefined;
  return (
    <section id={id} className={cx(styles.section, className)} aria-labelledby={titleId}>
      {title ? (
        <div className={styles.heading}>
          {eyebrow ? <p className={styles.eyebrow}>{eyebrow}</p> : null}
          <h2 id={titleId} className={styles.title}>
            {title}
          </h2>
          {lead ? <p className={styles.lead}>{lead}</p> : null}
        </div>
      ) : null}
      {children}
    </section>
  );
}

/** A grid of feature cards: `[site] features` by default, or `Feature` children. Four wrap two by two. */
export function Features({ children, className }: Props) {
  const cards =
    children ??
    site.features.map((feature) => (
      <Feature key={feature.title} title={feature.title}>
        {feature.body}
      </Feature>
    ));
  if (!children && site.features.length === 0) return null;
  return (
    <ul className={cx(styles.features, className)} aria-label="Features">
      {cards}
    </ul>
  );
}

/** One feature card, with an optional glyph above its title. */
export function Feature({ title, glyph, children, className }: Props & { title: ReactNode; glyph?: ReactNode }) {
  return (
    <li className={cx(styles.card, styles.feature, className)}>
      {glyph ? (
        <div className={styles.glyph} aria-hidden>
          {glyph}
        </div>
      ) : null}
      <h3 className={styles.cardTitle}>{title}</h3>
      <p className={styles.cardBody}>{children}</p>
    </li>
  );
}