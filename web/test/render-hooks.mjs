// Lets `node --test` import the components the way Next does: `.tsx` compiled with React's automatic JSX runtime,
// extensionless relative imports resolved to `.ts`/`.tsx`, and CSS Modules mapped to their class names.
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";
import { transformSync } from "esbuild";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith(".") && !/\.\w+$/.test(specifier) && context.parentURL?.startsWith("file:")) {
      for (const extension of [".ts", ".tsx"]) {
        const url = new URL(specifier + extension, context.parentURL);
        if (existsSync(fileURLToPath(url))) return nextResolve(url.href, context);
      }
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.endsWith(".module.css")) {
      return {
        format: "module",
        shortCircuit: true,
        source: "export default new Proxy({}, { get: (_, name) => String(name) });",
      };
    }
    if (url.endsWith(".tsx")) {
      const { source } = nextLoad(url, { ...context, format: "module" });
      const { code } = transformSync(String(source), { loader: "tsx", jsx: "automatic", format: "esm", sourcefile: url });
      return { format: "module", shortCircuit: true, source: code };
    }
    return nextLoad(url, context);
  },
});
