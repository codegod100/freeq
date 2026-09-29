// The addresses freeqcc's CLI asks about its bot: on the server the bot
// connects to, the configured serverUrl, not a fixed host.
import { serverApiOrigin } from "@freeq/bot-kit";

/** The server the bot connects to when none is configured. */
export const DEFAULT_SERVER_URL = "wss://irc.freeq.at/irc";

/** The actors route for `did` on the server at `serverUrl`. */
export function actorStatusUrl(serverUrl: string | undefined, did: string): string {
  const origin = serverApiOrigin(serverUrl ?? DEFAULT_SERVER_URL);
  return `${origin}/api/v1/actors/${encodeURIComponent(did)}`;
}

/** The health route on the server at `serverUrl`. */
export function healthUrl(serverUrl: string | undefined): string {
  return `${serverApiOrigin(serverUrl ?? DEFAULT_SERVER_URL)}/api/v1/health`;
}
