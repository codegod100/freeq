#!/usr/bin/env node
// freeq-fabro — relays Fabro run notifications into a freeq channel.
//
// Runs next to the Fabro server (on the boxd executor VM under systemd, see
// .fabro/executor/freeq-fabro.service). Connects to freeq as its own did:key
// agent, owner-bound to FREEQ_OWNER_DID, joins FREEQ_CHANNEL, and listens on
// 127.0.0.1:FABRO_RELAY_PORT for Fabro's HTTP hooks (.fabro/project.toml).
//
// Configuration (environment):
//   FREEQ_OWNER_DID   required — the human who owns this bot
//   FREEQ_URL         default wss://irc.freeq.at/irc
//   FREEQ_CHANNEL     default #freeq-dev
//   FREEQ_NICK        default fabro
//   FABRO_RELAY_PORT  default 8091
//   FABRO_WEB_URL     optional — public Fabro web UI, for run links
//   FABRO_REPO        default freeq-irc/freeq — where run PRs are looked up
//   GITHUB_TOKEN      optional — only needed for a private repo / higher rate limit
//   FREEQ_ACCEPT_POLICY  "1" to accept the channel's join policy (POLICY <ch>
//                     ACCEPT) on the owner's behalf when a join returns 477
import { FreeqBot } from "@freeq/bot-kit";
import { findRunPr } from "./pr.js";
import { createRelay } from "./relay.js";

function env(name: string, fallback?: string): string {
  const v = process.env[name]?.trim() || fallback;
  if (!v) {
    console.error(`freeq-fabro: ${name} is required`);
    process.exit(2);
  }
  return v;
}

const ownerDid = env("FREEQ_OWNER_DID");
const url = env("FREEQ_URL", "wss://irc.freeq.at/irc");
const channel = env("FREEQ_CHANNEL", "#freeq-dev");
const nick = env("FREEQ_NICK", "fabro");
const port = Number(env("FABRO_RELAY_PORT", "8091"));
const repo = env("FABRO_REPO", "freeq-irc/freeq");
const webUrl = process.env.FABRO_WEB_URL?.trim() || undefined;
const acceptPolicy = process.env.FREEQ_ACCEPT_POLICY === "1";

const log = (msg: string): void => console.log(`${new Date().toISOString()} ${msg}`);

const bot = await FreeqBot.create({
  name: "fabro",
  ownerDid,
  nick,
  url,
  channels: [channel],
  initialStatus: "relaying Fabro runs",
});
// Report the real join outcome. A +i channel can refuse the auto-join when it
// races the server's provenance check (see CLAUDE.md "JOIN races
// PROVENANCE"), so retry a refused join a few times, spaced out.
let joinRetries = 0;
bot.on("channelJoined", (ch) => {
  if (ch.toLowerCase() === channel.toLowerCase()) {
    joinRetries = 0;
    log(`joined ${ch}`);
  }
});
bot.on("joinRejected", (ch, numeric, reason) => {
  log(`join ${ch} refused (${numeric}): ${reason}`);
  if (ch.toLowerCase() !== channel.toLowerCase() || joinRetries >= 3) return;
  joinRetries++;
  // 477 = the channel has a join policy (rules) to accept first.
  if (numeric === "477" && acceptPolicy) {
    log(`accepting ${channel} join policy (FREEQ_ACCEPT_POLICY=1)`);
    bot.client.raw(`POLICY ${channel} ACCEPT`);
  }
  setTimeout(() => bot.client.join(channel), 5_000 * joinRetries);
});
bot.on("systemMessage", (_target, text) => {
  if (/polic/i.test(text)) log(`server: ${text}`);
});
bot.on("serverFail", (text) => log(`server FAIL: ${text}`));

await bot.start();
log(`connected as ${bot.client.nick} (${bot.identity.did})`);

const relay = createRelay({
  post: (line) => {
    try {
      bot.client.sendMessage(channel, line);
      log(`posted: ${line}`);
    } catch (err) {
      log(`post failed (${String(err)}): ${line}`);
    }
  },
  findPr: (runId) => findRunPr(runId, { repo, token: process.env.GITHUB_TOKEN }),
  webUrl,
  log,
});
relay.listen(port, "127.0.0.1", () => log(`listening on 127.0.0.1:${port}/hook`));

const shutdown = async (signal: string): Promise<void> => {
  log(`${signal} — shutting down`);
  relay.close();
  await bot.stop("freeq-fabro stopping");
  process.exit(0);
};
process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
