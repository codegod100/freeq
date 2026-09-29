/**
 * The Agents section: adding, removing and adding back a bot, against a stub
 * broker.
 *
 * The rig signs nobody in, so the page is given a signed-in account whose
 * browser key is published through `__setSignedInForTests`, and the list
 * reads the account's records from a URL this spec answers
 * (`__setAgentListingForTests`). The records the page posts to the broker's
 * `/enroll` are kept here and listed back, so the rows are the SDK's fold of
 * the records the page itself built and signed.
 */
import { test, expect } from '@playwright/test';
import { connectGuest, uniqueChannel, uniqueNick } from './helpers';

const OWNER = 'did:plc:e2eagentowner';
const BROKER = 'https://broker.e2e.example';
const BOT = 'did:key:z6MkwVDfCg9LbbY6xjH3EZk8YSFQZujV5Y4y1ZWeER9tDiN3';

test('adds, removes and adds back an agent', async ({ page }) => {
  await connectGuest(page, uniqueNick('agents'), uniqueChannel());

  const posted: { record: Record<string, unknown>; signer_public_key: string }[] = [];
  await page.route(`${BROKER}/enroll`, async (route) => {
    posted.push(route.request().postDataJSON());
    await route.fulfill({
      json: { ok: true, uri: `at://${OWNER}/at.freeq.agentKey/${posted.length}`, cid: 'bafy' },
    });
  });

  const device = await page.evaluate(
    async ([owner, broker]) => {
      const mod = await import('/src/e2e-support.ts');
      localStorage.setItem('freeq-broker-base', broker);
      localStorage.setItem('freeq-broker-token', 'BT-E2E');
      mod.__setAgentListingForTests('/__e2e/agent-records');
      return mod.__setSignedInForTests(owner);
    },
    [OWNER, BROKER],
  );
  await page.route('**/__e2e/agent-records', (route) =>
    route.fulfill({ json: { devices: [device], agents: posted.map((p) => p.record) } }),
  );

  await page.getByTitle('Settings').first().click();
  const agents = page.locator('[data-agent-row]');
  const meta = agents.locator('[data-agent-meta]');

  // Add.
  await page.getByRole('button', { name: '+ Add an agent' }).click();
  await page.getByLabel('Agent DID').fill(BOT);
  await page.getByLabel('Name').fill('helper');
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  await expect(agents).toHaveCount(1);
  await expect(agents.getByText('helper')).toBeVisible();
  await expect(meta).toHaveText(/^did:key:z6MkwVDf…9tDiN3 · since /);
  expect(posted[0].record).toMatchObject({ $type: 'at.freeq.agentKey', did: OWNER, agentDid: BOT, label: 'helper' });
  expect(posted[0].record.kid).toBe(device.kid);

  // Remove.
  await agents.getByRole('button', { name: 'Remove' }).click();
  const ask = page.getByRole('dialog');
  await expect(ask.getByText('Remove helper from your agents?')).toBeVisible();
  await ask.getByRole('button', { name: 'Remove' }).click();
  await expect(meta).toHaveText(/ · Removed · /);
  await expect(agents.getByRole('button', { name: 'Remove' })).toHaveCount(0);
  expect(posted[1].record).toMatchObject({ did: OWNER, revokes: BOT });

  // Add it back: a claim dated after the removal is live again.
  await page.getByRole('button', { name: '+ Add an agent' }).click();
  await page.getByLabel('Agent DID').fill(BOT);
  await page.getByLabel('Name').fill('helper');
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  await expect(meta).toHaveText(/ · since /);
  await expect(agents).toHaveCount(1);
  expect(posted).toHaveLength(3);
});
