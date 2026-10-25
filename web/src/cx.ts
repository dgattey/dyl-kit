/** Joins the class names that are set, so a component's own class and a page's `className` both apply. */
export function cx(...names: (string | false | undefined)[]): string {
  return names.filter(Boolean).join(" ");
}
