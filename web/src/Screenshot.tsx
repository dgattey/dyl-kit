import type { ReactNode } from "react";
import { screenshotNamed } from "./content";
import { cx } from "./cx";
import { site } from "./site";
import type { Frame, Screenshot as Shot } from "./site";
import styles from "./Screenshot.module.css";

type Props = { className?: string };

/** A `[site] screenshots` entry by its `src`, with its dark variant, in the entry's frame unless `frame` overrides it. */
export function Screenshot({ src, frame, priority, className }: Props & { src: string; frame?: Frame; priority?: boolean }) {
  return <ScreenshotImage shot={screenshotNamed(site, src)} frame={frame} priority={priority} className={className} />;
}

export function ScreenshotImage({
  shot,
  frame = shot.frame,
  priority,
  className,
}: Props & { shot: Shot; frame?: Frame; priority?: boolean }) {
  const picture = (
    <picture className={frame ? styles.shot : cx(styles.shot, styles.window, className)}>
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
  return frame ? (
    <DeviceFrame kind={frame} className={className}>
      {picture}
    </DeviceFrame>
  ) : (
    picture
  );
}

/** A device bezel around an image. */
export function DeviceFrame({ kind, children, className }: Props & { kind: Frame; children: ReactNode }) {
  switch (kind) {
    case "iphone":
      return (
        <div className={cx(styles.iphone, className)}>
          <div className={styles.iphoneBezel}>{children}</div>
        </div>
      );
    default: {
      const unhandled: never = kind;
      throw new Error(`@dylkit/web: unknown frame ${unhandled}`);
    }
  }
}

/** A Mac window with an iPhone overlapping its lower right corner. */
export function Showcase({ mac, phone, className }: Props & { mac: string; phone: string }) {
  return (
    <div className={cx(styles.showcase, className)}>
      <Screenshot src={mac} className={styles.showcaseMac} />
      <Screenshot src={phone} frame="iphone" className={styles.showcasePhone} />
    </div>
  );
}

/** Every screenshot after the first, which the hero shows. */
export function Gallery({ className }: Props) {
  const shots = site.screenshots.slice(1);
  if (shots.length === 0) return null;
  return (
    <section className={cx(styles.gallery, className)} aria-label="Screenshots">
      {shots.map((shot) => (
        <ScreenshotImage key={shot.src} shot={shot} className={styles.galleryShot} />
      ))}
    </section>
  );
}
