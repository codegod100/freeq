#!/usr/bin/env npx tsx
/** One-shot: join #ship-it as a transient guest, find the "5/5 green"
 *  message in the JOIN history replay, react 🎉, and leave. Reactions are
 *  server-persisted, so they survive this connection closing. */
import { FreeqClient } from "../src/index.js";

const CHANNEL = process.env.STAGE_CHANNEL || "#ship-it";
const client = new FreeqClient({ url: "wss://irc.freeq.at/irc", nick: "kai" });

let done = false;
client.on("registered", () => {
  client.join(CHANNEL);
  // JOIN alone doesn't replay history to SDK consumers — ask for it.
  setTimeout(() => client.requestHistory(CHANNEL), 1500);
});
function tryReact(msg: any) {
  if (done) return;
  if (/5\/5 green/.test(msg?.text || "") && msg.id && !msg.id.includes("-")) {
    // ULID msgids have no dashes; random UUID fallbacks do.
    done = true;
    client.sendReaction(CHANNEL, "🎉", msg.id);
    console.log(`[react] 🎉 on ${msg.id}`);
    setTimeout(() => process.exit(0), 1500);
  }
}
client.on("message", (_buf: string, msg: any) => tryReact(msg));
client.on("historyBatch", (_buf: string, msgs: any[]) => msgs.forEach(tryReact));
client.connect();
setTimeout(() => {
  console.log(done ? "ok" : "[react] TIMEOUT — no target found");
  process.exit(done ? 0 : 1);
}, 20000);
