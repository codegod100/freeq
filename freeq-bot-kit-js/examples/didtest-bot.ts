#!/usr/bin/env node
/**
 * didtest-bot — a throwaway did:key echo bot for exercising DID-addressed DMs.
 *
 * Mints a fresh did:key (a clean identity the server has never seen), joins a
 * channel so you can click it in the member list, and echoes any DM back so a
 * DM has two-way history under the canonical DID-pair key. Use it to check
 * that a did:key peer renders as a name rather than a raw did:key:z6Mk… and
 * that one peer is one thread.
 *
 *   npm --prefix freeq-sdk-js run build
 *   npx tsx freeq-bot-kit-js/examples/didtest-bot.ts \
 *     --owner did:plc:<your-did> --server wss://irc.zerosum.org/irc
 */

import { FreeqBot } from "../src/index.js";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    server: { type: "string", default: "wss://irc.zerosum.org/irc" },
    channel: { type: "string", default: "#didtest" },
    nick: { type: "string", default: "didtestbot" },
    // Fresh identity per run by default, so the server has no prior record.
    name: { type: "string", default: `didtest-${Math.random().toString(36).slice(2, 8)}` },
    owner: { type: "string" },
  },
  strict: true,
});

if (!values.owner) {
  console.error(
    "Usage: didtest-bot --owner did:plc:<your-did> [--server wss://…/irc] [--channel #didtest] [--nick didtestbot]",
  );
  process.exit(1);
}

const bot = await FreeqBot.create({
  name: values.name!,
  ownerDid: values.owner,
  nick: values.nick!,
  url: values.server!,
  channels: [values.channel!],
});

bot.on("message", (channel, msg) => {
  if (msg.isSelf) return;
  const isDM = !channel.startsWith("#") && !channel.startsWith("&");
  // Echo DMs; in-channel, only answer when addressed, to stay quiet.
  if (isDM) {
    console.error(`[didtest-bot] DM in thread "${channel}" from ${msg.from}: ${msg.text}`);
    bot.client.sendMessage(channel, `echo: ${msg.text}`);
  }
});

await bot.start();
console.error(`[didtest-bot] up as ${bot.client.nick}`);
console.error(`[didtest-bot] identity ${bot.identity.did}`);
console.error(`[didtest-bot] in ${values.channel} on ${values.server}`);

process.once("SIGINT", () => bot.stop("SIGINT").then(() => process.exit(0)));
process.once("SIGTERM", () => bot.stop("SIGTERM").then(() => process.exit(0)));
