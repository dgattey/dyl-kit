import type { ReactNode } from "react";
import { releaseFacts, requirements } from "./content";
import { cx } from "./cx";
import openAnyway from "./open-anyway.png";
import type { Release } from "./release";
import { ScreenshotImage } from "./Screenshot";
import { site } from "./site";
import styles from "./Hero.module.css";

type Props = { release: Release | null; className?: string };

/**
 * The top of the page: `visual` beside the copy. `visual` defaults to the first screenshot, and the copy defaults to
 * `Intro` and `DownloadPanel`, which `children` replace. With no visual, the hero centers one column under a large icon.
 */
export function Hero({
  release,
  visual,
  title,
  lead,
  children,
  className,
}: Props & { visual?: ReactNode; title?: ReactNode; lead?: ReactNode; children?: ReactNode }) {
  const first = site.screenshots[0];
  const shown = visual === undefined && first ? <ScreenshotImage shot={first} priority /> : visual;
  return (
    <section className={cx(styles.hero, !shown && styles.centered, className)}>
      <div className={styles.copy}>
        {children ?? (
          <>
            <Intro release={release} title={title} lead={lead} />
            <DownloadPanel release={release} />
          </>
        )}
      </div>
      {shown ? <div className={styles.visual}>{shown}</div> : null}
    </section>
  );
}

/** The icon, the requirements badge, the title (default: the app's name) and the lead (default: its tagline). */
export function Intro({ release, title = site.name, lead = site.tagline, className }: Props & { title?: ReactNode; lead?: ReactNode }) {
  return (
    <div className={cx(styles.intro, className)}>
      {/* Each release uploads the icons before release.json, so without a release there's no icon to show. */}
      {release ? (
        <div className={styles.brand}>
          <picture>
            <source srcSet="/icons/icon-256-dark.png" media="(prefers-color-scheme: dark)" />
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/icons/icon-256.png" alt="" width={256} height={256} className={styles.icon} />
          </picture>
          <span className={styles.badge}>{requirements(release)}</span>
        </div>
      ) : null}
      <h1 className={styles.title}>{title}</h1>
      <p className={styles.lead}>{lead}</p>
    </div>
  );
}

/** The download button, the release's size and date, and the steps past Gatekeeper for an ad-hoc signed app. */
export function DownloadPanel({ release, className }: Props) {
  if (!release) {
    return (
      <p className={cx(styles.muted, className)}>A macOS build isn&apos;t published yet. Check back after the next release.</p>
    );
  }
  return (
    <div className={cx(styles.panel, className)}>
      <div className={styles.buttons}>
        <a className={styles.button} href="/download/macos">
          Download for Mac <span className={styles.version}>v{release.version}</span>
        </a>
        {release.notes.length ? (
          <a className={styles.secondary} href="#release-notes">
            What&apos;s new
          </a>
        ) : null}
      </div>
      <p className={styles.facts}>{releaseFacts(release)}</p>
      <details className={styles.gatekeeper}>
        <summary>First time on this Mac? macOS may block the app</summary>
        <div className={styles.gatekeeperBody}>
          <ol>
            <li>
              Open <strong>{site.name}</strong> from Applications once, so macOS records the block.
            </li>
            <li>
              Open <strong>System Settings → Privacy &amp; Security</strong>.
            </li>
            <li>
              Under Security, click <strong>Open Anyway</strong> next to the {site.name} message, then open the app again.
            </li>
          </ol>
          <figure className={styles.figure}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={openAnyway.src}
              width={openAnyway.width}
              height={openAnyway.height}
              alt="Privacy & Security settings showing a blocked app with an Open Anyway button"
              loading="lazy"
              decoding="async"
            />
            <figcaption>Open Anyway appears after you try to open the app once.</figcaption>
          </figure>
          <p>
            On a Mac managed by your organization, Open Anyway may be turned off. Clear the download quarantine once in
            Terminal instead; later updates install without it.
          </p>
          <pre className={styles.command}>
            <code>xattr -cr &quot;/Applications/{site.name}.app&quot;</code>
          </pre>
        </div>
      </details>
    </div>
  );
}
