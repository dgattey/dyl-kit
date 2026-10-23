import { iconResponse } from "./icons";
import { appcastResponse, downloadResponse } from "./release";
import { site } from "./site";

/** `app/appcast.xml/route.ts`: `export { appcast as GET } from "@dylkit/web/routes";` */
export const appcast = () => appcastResponse(site);

/** `app/download/macos/route.ts`: `export { download as GET } from "@dylkit/web/routes";` */
export const download = () => downloadResponse(site);

/** `app/icons/[name]/route.ts`, `app/icon.png/route.ts`, `app/apple-touch-icon.png/route.ts` and `app/favicon.ico/route.ts`. */
export const icon = (request: Request) => iconResponse(site, request);
