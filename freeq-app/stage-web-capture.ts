/**
 * Capture the web client viewing #ship-it as guest "sam".
 * Run from freeq-app/ (where @playwright/test + browsers are installed):
 *   cd freeq-app && npx tsx ../freeq-site/staging/web-capture.ts
 * Output: freeq-site/static/shots/web.png (1440x900 viewport @2x)
 */
import { chromium } from "@playwright/test";

const OUT = "/Users/chad/src/freeq/freeq-site/static/shots/web.png";
const CHANNEL = process.env.STAGE_CHANNEL || "#ship-it";
const NICK = process.env.STAGE_WEB_NICK || "sam";

async function main() {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
    colorScheme: "dark",
  });
  // Pre-seed: skip the first-run onboarding tour (covers the app in a modal).
  await page.addInitScript(() => {
    try { localStorage.setItem("freeq-onboarding-done", "1"); } catch {}
  });
  await page.goto("https://irc.freeq.at", { waitUntil: "networkidle" });

  await page.getByRole("button", { name: "Guest", exact: true }).click();
  await page.getByPlaceholder("your_nick").fill(NICK);
  await page.getByPlaceholder("#freeq").fill(CHANNEL);
  await page.getByRole("button", { name: /connect/i }).click();

  // Wait for the staged conversation to replay from CHATHISTORY.
  await page.getByText("checkout smoke suite", { exact: false }).first()
    .waitFor({ timeout: 30_000 });

  // First-run modals (onboarding tour, MOTD) cover the app — dismiss them.
  for (const name of [/skip/i, /let's go/i]) {
    const btn = page.getByRole("button", { name });
    if (await btn.isVisible().catch(() => false)) {
      await btn.click();
      await page.waitForTimeout(600);
    }
  }
  await page.waitForTimeout(3500); // reactions + avatars settle

  await page.screenshot({ path: OUT });
  console.log(`[web-capture] wrote ${OUT}`);
  await browser.close();
}

main().catch((e) => {
  console.error("[web-capture] FAILED:", e);
  process.exit(1);
});
