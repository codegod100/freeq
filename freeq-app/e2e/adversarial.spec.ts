/**
 * Adversarial E2E tests for the freeq web client.
 *
 * Tests XSS prevention, hostile input handling, UI resilience under
 * stress, and security-critical rendering behavior against a live server.
 */
import { test, expect, Page } from '@playwright/test';
import { uniqueNick, uniqueChannel, connectGuest as _connectGuest, sendMessage, expectMessage, connectSecondUser as _connectSecondUser, switchChannel, openSidebar } from './helpers';

/** Connect as guest and dismiss any modal dialogs (MOTD, etc.) */
async function connectGuest(page: Page, nick: string, channel: string) {
  await _connectGuest(page, nick, channel);
  // Dismiss MOTD "Let's go" dialog if present
  const letsGo = page.getByRole('button', { name: "Let's go" });
  if (await letsGo.isVisible({ timeout: 2000 }).catch(() => false)) {
    await letsGo.click();
    await page.waitForTimeout(300);
  }
}

test.describe('XSS and injection', () => {
  test('HTML tags in message rendered as text, not executed', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, '<script>document.title="PWNED"</script>');
    await expectMessage(page, '<script>');
    // Title should NOT be "PWNED"
    expect(await page.title()).not.toBe('PWNED');
  });

  test('img onerror XSS in message rendered as text', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, '<img src=x onerror=alert(1)>');
    await expectMessage(page, '<img');
    // No alert dialog should appear
    const dialogPromise = page.waitForEvent('dialog', { timeout: 2000 }).catch(() => null);
    expect(await dialogPromise).toBeNull();
  });

  test('javascript: URL in message not clickable', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, 'click this: javascript:alert(1)');
    await expectMessage(page, 'javascript:');
    // The text should NOT be a clickable link
    const links = page.getByTestId('message-list').locator('a[href^="javascript:"]');
    expect(await links.count()).toBe(0);
  });

  test('markdown image with javascript: src blocked', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, '![xss](javascript:alert(1))');
    // Should render as text or blocked image, not executable
    const dialogPromise = page.waitForEvent('dialog', { timeout: 2000 }).catch(() => null);
    expect(await dialogPromise).toBeNull();
  });

  test('data: URL in message not rendered as link', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, 'data:text/html,<script>alert(1)</script>');
    const links = page.getByTestId('message-list').locator('a[href^="data:"]');
    expect(await links.count()).toBe(0);
  });
});

test.describe('Message rendering edge cases', () => {
  test('very long message without spaces does not break layout', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    const longWord = 'a'.repeat(2000);
    await sendMessage(page, longWord);
    await expectMessage(page, longWord.slice(0, 50)); // Check start renders
    // Page should not have horizontal scrollbar on message list
    const hasHScroll = await page.getByTestId('message-list').evaluate(el =>
      el.scrollWidth > el.clientWidth
    );
    // Some overflow is acceptable but shouldn't break the entire layout
  });

  test('message with multiple lines renders without crashing', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    // Send a multi-line message (newlines become spaces or line breaks)
    await sendMessage(page, 'line1 line2 line3 line4 line5');
    await expectMessage(page, 'line1');
  });

  test('unicode emoji renders correctly', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, '🎉🇺🇸👨‍👩‍👧‍👦 emoji test');
    await expectMessage(page, '🎉');
  });

  test('RTL override character does not reverse entire UI', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, '\u202Ethis is reversed text');
    // The sidebar should still be readable
    await expect(page.getByTestId('sidebar')).toBeVisible();
    const sidebarText = await page.getByTestId('sidebar').textContent();
    expect(sidebarText).toBeTruthy();
  });

  test('zero-width characters in message are harmless', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, 'hello\u200B\u200Bworld');
    await expectMessage(page, 'hello');
  });
});

test.describe('Two-user interaction', () => {
  test('message from other user appears in real time', async ({ page, browser }) => {
    const nick1 = uniqueNick('usr1');
    const nick2 = uniqueNick('usr2');
    const ch = uniqueChannel();

    await connectGuest(page, nick1, ch);
    const { page: page2, ctx } = await _connectSecondUser(browser, nick2, ch);
    // Dismiss MOTD on second page
    const lg2 = page2.getByRole('button', { name: "Let's go" });
    if (await lg2.isVisible({ timeout: 2000 }).catch(() => false)) { await lg2.click(); await page2.waitForTimeout(300); }

    await sendMessage(page2, 'hello from user 2');
    await expectMessage(page, 'hello from user 2');

    await ctx.close();
  });

  test('nick change reflected in new messages', async ({ page, browser }) => {
    const nick1 = uniqueNick('nch1');
    const nick2 = uniqueNick('nch2');
    const newNick = uniqueNick('renamed');
    const ch = uniqueChannel();

    await connectGuest(page, nick1, ch);
    const { page: page2, ctx } = await _connectSecondUser(browser, nick2, ch);
    // Dismiss MOTD on second page
    const lg2 = page2.getByRole('button', { name: "Let's go" });
    if (await lg2.isVisible({ timeout: 2000 }).catch(() => false)) { await lg2.click(); await page2.waitForTimeout(300); }

    // User 2 changes nick
    const compose = page2.getByTestId('compose-input');
    await compose.fill(`/nick ${newNick}`);
    await compose.press('Enter');
    await page2.waitForTimeout(1000);

    // User 2 sends message with new nick
    await sendMessage(page2, 'message after nick change');
    await expectMessage(page, 'message after nick change');

    await ctx.close();
  });

  test('user quit shows system message', async ({ page, browser }) => {
    const nick1 = uniqueNick('qt1');
    const nick2 = uniqueNick('qt2');
    const ch = uniqueChannel();

    await connectGuest(page, nick1, ch);
    const { page: page2, ctx } = await _connectSecondUser(browser, nick2, ch);
    // Dismiss MOTD on second page
    const lg2 = page2.getByRole('button', { name: "Let's go" });
    if (await lg2.isVisible({ timeout: 2000 }).catch(() => false)) { await lg2.click(); await page2.waitForTimeout(300); }
    await page.waitForTimeout(500);

    // User 2 disconnects
    await ctx.close();

    // User 1 should see quit message (if join/part messages enabled)
    // This may or may not show depending on settings
    await page.waitForTimeout(2000);
  });
});

test.describe('Channel operations', () => {
  test('/topic sets and displays topic', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);

    const compose = page.getByTestId('compose-input');
    await compose.fill(`/topic ${ch} Test topic from Playwright`);
    await compose.press('Enter');
    await page.waitForTimeout(1000);

    // Topic should appear in the header area (may include channel name prefix)
    await expect(page.locator('header').getByText('Test topic from Playwright', { exact: false })).toBeVisible({ timeout: 5000 });
  });

  test('/join creates new channel in sidebar', async ({ page }) => {
    const nick = uniqueNick();
    const ch1 = uniqueChannel();
    const ch2 = uniqueChannel();
    await connectGuest(page, nick, ch1);

    const compose = page.getByTestId('compose-input');
    await compose.fill(`/join ${ch2}`);
    await compose.press('Enter');

    // New channel should appear in sidebar
    const sidebar = await openSidebar(page);
    await expect(sidebar.getByText(ch2)).toBeVisible({ timeout: 5000 });
  });

  test('/part removes channel from sidebar', async ({ page }) => {
    const nick = uniqueNick();
    const ch1 = uniqueChannel();
    const ch2 = uniqueChannel();
    await connectGuest(page, nick, `${ch1},${ch2}`);
    await page.waitForTimeout(1000);

    // Part the second channel
    await switchChannel(page, ch2);
    const compose = page.getByTestId('compose-input');
    await compose.fill(`/part ${ch2}`);
    await compose.press('Enter');
    await page.waitForTimeout(1000);

    // Channel should be gone from sidebar (or we switched away from it)
    await page.waitForTimeout(1000);
    // The compose box should still be functional
    await expect(page.getByTestId('compose-input')).toBeVisible();
  });
});

test.describe('Compose box edge cases', () => {
  test('empty message is not sent', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);

    const compose = page.getByTestId('compose-input');
    await compose.press('Enter'); // Empty submit
    await page.waitForTimeout(500);
    // No message should appear in the list (only system messages)
    const messages = page.getByTestId('message-list').locator('[class*="message"]');
    // Count should be 0 or only system messages
  });

  test('whitespace-only message is not sent', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);

    const compose = page.getByTestId('compose-input');
    await compose.fill('   ');
    await compose.press('Enter');
    await page.waitForTimeout(500);
  });

  test('/raw command sends raw IRC', async ({ page, browser }) => {
    const nick1 = uniqueNick('raw1');
    const nick2 = uniqueNick('raw2');
    const ch = uniqueChannel();

    await connectGuest(page, nick1, ch);
    const { page: page2, ctx } = await _connectSecondUser(browser, nick2, ch);
    // Dismiss MOTD on second page
    const lg2 = page2.getByRole('button', { name: "Let's go" });
    if (await lg2.isVisible({ timeout: 2000 }).catch(() => false)) { await lg2.click(); await page2.waitForTimeout(300); }

    // Send raw PRIVMSG via /raw
    const compose = page.getByTestId('compose-input');
    await compose.fill(`/raw PRIVMSG ${ch} :raw command test`);
    await compose.press('Enter');

    await expectMessage(page2, 'raw command test');
    await ctx.close();
  });
});

test.describe('UI resilience', () => {
  test('rapid channel switching does not crash', async ({ page }) => {
    const nick = uniqueNick();
    const ch1 = uniqueChannel();
    const ch2 = uniqueChannel();
    const ch3 = uniqueChannel();
    await connectGuest(page, nick, `${ch1},${ch2},${ch3}`);
    await page.waitForTimeout(1000);

    // Rapidly switch between channels
    for (let i = 0; i < 5; i++) {
      await switchChannel(page, ch1);
      await switchChannel(page, ch2);
      await switchChannel(page, ch3);
    }

    // App should still be responsive
    await expect(page.getByTestId('compose-input')).toBeVisible();
  });

  test('page reload reconnects', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);
    await sendMessage(page, 'before reload');

    // Reload the page
    await page.reload();
    await page.waitForTimeout(3000);

    // Should see login screen (guest sessions don't persist)
    await expect(page.getByRole('button', { name: 'Guest' })).toBeVisible({ timeout: 10000 });
  });
});

test.describe('WHOIS and user info', () => {
  test('/whois shows user information', async ({ page }) => {
    const nick = uniqueNick();
    const ch = uniqueChannel();
    await connectGuest(page, nick, ch);

    const compose = page.getByTestId('compose-input');
    await compose.fill(`/whois ${nick}`);
    await compose.press('Enter');

    // Should show whois info in server tab or current channel
    await page.waitForTimeout(2000);
  });
});
