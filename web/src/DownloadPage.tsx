import openAnyway from "./open-anyway.png";
import type { Release } from "./release";
import type { Screenshot, Site } from "./site";
import styles from "./DownloadPage.module.css";

/**
 * An app's download page: icon, name, tagline, download button, the Gatekeeper and MDM steps for an ad-hoc signed
 * app, screenshots and cumulative release notes. `release` comes from `latestRelease(site)`.
 */
export function DownloadPage({ site, release }: { site: Site; release: Release | null }) {
  const [hero, ...gallery] = site.screenshots;
  return (
    <main className={styles.page}>
      <section className={styles.hero}>
        {hero ? <ScreenshotImage shot={hero} className={styles.heroShot} priority /> : null}
        <div className={styles.intro}>
          <div className={styles.brand}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/app-icon.png" alt="" width={64} height={64} className={styles.icon} />
            {release ? <span className={styles.badge}>{requirements(release)}</span> : null}
          </div>
          <h1 className={styles.title}>{site.name}</h1>
          <p className={styles.tagline}>{site.tagline}</p>
          {release ? (
            <Download name={site.name} release={release} />
          ) : (
            <p className={styles.muted}>A macOS build isn&apos;t published yet. Check back after the next release.</p>
          )}
        </div>
      </section>

      {gallery.length ? (
        <section className={styles.gallery} aria-label="Screenshots">
          {gallery.map((shot) => (
            <ScreenshotImage key={shot.src} shot={shot} className={styles.galleryShot} />
          ))}
        </section>
      ) : null}

      {release?.notes.length ? (
        <section id="release-notes" className={styles.notes} aria-labelledby="release-notes-title">
          <h2 id="release-notes-title" className={styles.sectionTitle}>
            What&apos;s new
          </h2>
          {release.notes.map((entry) => (
            <article key={entry.version} className={styles.note}>
              <h3 className={styles.noteVersion}>{entry.version}</h3>
              <div className={styles.noteBody} dangerouslySetInnerHTML={{ __html: entry.html }} />
            </article>
          ))}
        </section>
      ) : null}

      <footer className={styles.footer}>
        Made by <a href="https://dylangattey.com">Dylan Gattey</a>
      </footer>
    </main>
  );
}

function Download({ name, release }: { name: string; release: Release }) {
  const facts = [`Version ${release.version}`, release.sizeBytes && megabytes(release.sizeBytes), date(release.publishedAt)];
  return (
    <div className={styles.download}>
      <a className={styles.button} href="/download/macos">
        Download for macOS
      </a>
      <p className={styles.facts}>{facts.filter(Boolean).join(" · ")}</p>
      <details className={styles.gatekeeper}>
        <summary>First time on this Mac? macOS may block the app</summary>
        <div className={styles.gatekeeperBody}>
          <ol>
            <li>
              Open <strong>{name}</strong> from Applications once, so macOS records the block.
            </li>
            <li>
              Open <strong>System Settings → Privacy &amp; Security</strong>.
            </li>
            <li>
              Under Security, click <strong>Open Anyway</strong> next to the {name} message, then open the app again.
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
            On a Mac managed by your organization, Open Anyway may be turned off. Clear the download quarantine once
            in Terminal instead; later updates install without it.
          </p>
          <pre className={styles.command}>
            <code>xattr -cr /Applications/{name}.app</code>
          </pre>
        </div>
      </details>
    </div>
  );
}

function ScreenshotImage({ shot, className, priority }: { shot: Screenshot; className: string; priority?: boolean }) {
  return (
    <picture className={className}>
      {shot.darkSrc ? <source srcSet={shot.darkSrc} media="(prefers-color-scheme: dark)" /> : null}
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={shot.src}
        alt={shot.alt}
        width={shot.width}
        height={shot.height}
        fetchPriority={priority ? "high" : undefined}
        loading={priority ? undefined : "lazy"}
        decoding="async"
      />
    </picture>
  );
}

function requirements(release: Release): string {
  const os = release.minimumSystemVersion ? `macOS ${release.minimumSystemVersion.replace(/\.0$/, "")}+` : "macOS";
  return release.appleSiliconOnly ? `${os} · Apple Silicon` : os;
}

function megabytes(bytes: number): string {
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

function date(iso: string | null): string | null {
  return iso
    ? new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" })
    : null;
}
