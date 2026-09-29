// Persistent per-install config: bot nick, server URL, anything else
// the user wants stable across launches.
import { readFile, writeFile } from "node:fs/promises";
import { paths, ensureDir } from "./paths.js";

export interface Config {
  /** IRC nick to register with. */
  nick: string;
  /** Defaults to wss://irc.freeq.at/irc when omitted. */
  serverUrl?: string;
}

export async function loadConfig(): Promise<Config | null> {
  let raw: string;
  try {
    raw = await readFile(paths.config, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw err;
  }
  const parsed = JSON.parse(raw) as Config;
  if (typeof parsed.nick !== "string" || parsed.nick.length === 0) {
    throw new Error(`${paths.config} is missing 'nick'.`);
  }
  return parsed;
}

/** The config to save at launch, or null when it is unchanged: `nick` as
 *  chosen, and the `--server` flag if given, else the stored server. The
 *  server is saved so `status` and `doctor` ask the server the bot
 *  connects to. */
export function configToSave(
  stored: Config | null,
  nick: string,
  server: string | undefined,
): Config | null {
  const serverUrl = server ?? stored?.serverUrl;
  const next: Config = serverUrl === undefined ? { nick } : { nick, serverUrl };
  if (stored && stored.nick === next.nick && stored.serverUrl === next.serverUrl) {
    return null;
  }
  return next;
}

export async function saveConfig(cfg: Config): Promise<void> {
  await ensureDir();
  await writeFile(paths.config, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
}
