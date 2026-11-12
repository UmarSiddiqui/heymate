// Run against `node website/preview.mjs` using:
// playwright-cli run-code --filename=website/tests/consent.browser.js
// All analytics requests are intercepted; no visitor data leaves this test.
async (page) => {
  const context = page.context();
  const origin = 'http://127.0.0.1:4173';
  const key = 'heymate.analytics-consent.v1';
  let requests = 0;
  const errors = [];
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  page.on('pageerror', error => errors.push(error.message));
  await context.route(/hotjar|contentsquare/, async route => {
    requests++;
    await route.fulfill({ contentType: 'application/javascript', body: 'window.__hotjarTestLoaded = true;' });
  });
  await page.goto(origin + '/');
  await page.evaluate(() => localStorage.clear());
  await page.goto(origin + '/privacy');
  const banner = page.getByRole('region', { name: 'A little insight. Your choice.' });
  const accept = page.getByRole('button', { name: 'Accept analytics', exact: true });
  const reject = page.getByRole('button', { name: 'Reject analytics', exact: true });
  const settings = page.getByRole('button', { name: 'Cookie settings', exact: true });
  await banner.waitFor({ state: 'visible' });
  check(requests === 0, 'Analytics requested before consent');
  check(!(await page.evaluate(() => window.hj)), 'Hotjar queue exists before consent');
  await reject.click();
  await page.reload();
  check(!(await banner.isVisible()), 'Rejection was not remembered');
  check(requests === 0, 'Analytics requested after rejection');
  await settings.click();
  check(await page.evaluate(() => document.activeElement.id === 'cookie-notice-title'), 'Settings did not focus notice');
  await accept.focus();
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => window.__hotjarTestLoaded === true);
  check(requests === 1, 'Acceptance should load analytics exactly once');
  await page.reload();
  await page.waitForFunction(() => window.__hotjarTestLoaded === true);
  check(requests === 2 && !(await banner.isVisible()), 'Acceptance was not remembered');
  await page.evaluate(() => {
    document.cookie = '_hjSession_test=fixture; Path=/';
    document.cookie = 'essential_fixture=keep; Path=/';
    localStorage.setItem('_hjSession_fixture', 'fixture');
    sessionStorage.setItem('hjActiveViewportIds', 'fixture');
  });
  await settings.click();
  await Promise.all([page.waitForEvent('load'), reject.click()]);
  check(requests === 2, 'Withdrawal reloaded analytics');
  const cleanup = await page.evaluate(() => ({
    cookie: document.cookie,
    local: localStorage.getItem('_hjSession_fixture'),
    session: sessionStorage.getItem('hjActiveViewportIds'),
    loaded: !!window.__hotjarTestLoaded
  }));
  check(!cleanup.loaded && !cleanup.cookie.includes('_hj') && cleanup.local === null && cleanup.session === null, 'Withdrawal left Hotjar running or stored data');
  check(cleanup.cookie.includes('essential_fixture=keep'), 'Withdrawal removed unrelated cookies');

  // New homepage visits show the choice, but even acceptance must not add recordings.
  await page.evaluate(() => localStorage.clear());
  await page.goto(origin + '/');
  await banner.waitFor({ state: 'visible' });
  await page.setViewportSize({ width: 1280, height: 850 });
  await page.screenshot({ path: 'output/playwright/consent-desktop.png' });
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    const bounds = await banner.boundingBox();
    check(bounds.x >= 0 && bounds.x + bounds.width <= width && bounds.y >= 0, 'Notice overflows mobile viewport');
    const first = await accept.boundingBox(), second = await reject.boundingBox();
    check(Math.abs(first.width - second.width) < 2 && first.height >= 40 && second.height >= 40, 'Choices lack equal usable targets');
    await page.screenshot({ path: `output/playwright/consent-mobile-${width}.png` });
  }
  await accept.click();
  check(requests === 2 && !(await page.evaluate(() => window.hj)), 'Homepage started recording');
  await page.goto(origin + '/blog');
  check(!(await banner.isVisible()) && await settings.isVisible(), 'Blog lost shared choice or settings');
  check(requests === 2, 'Blog unexpectedly started recording');

  // Revocation in another tab immediately tears down an active recorder.
  await page.goto(origin + '/privacy');
  await page.waitForFunction(() => window.__hotjarTestLoaded === true);
  const peer = await context.newPage();
  await peer.goto(origin + '/');
  await peer.getByRole('button', { name: 'Cookie settings', exact: true }).click();
  await Promise.all([
    page.waitForEvent('load'),
    peer.getByRole('button', { name: 'Reject analytics', exact: true }).click()
  ]);
  check(requests === 3 && !(await page.evaluate(() => window.__hotjarTestLoaded)), 'Cross-tab withdrawal failed');
  await peer.close();

  // Restore from browser history must re-read a choice changed while suspended.
  await settings.click();
  await accept.click();
  await page.waitForFunction(() => window.__hotjarTestLoaded === true);
  await Promise.all([page.waitForEvent('load'), page.evaluate(key => {
    localStorage.setItem(key, JSON.stringify({ version: 1, analytics: false, expiresAt: Date.now() + 60000 }));
    window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));
  }, key)]);
  check(requests === 4 && !(await page.evaluate(() => window.__hotjarTestLoaded)), 'History restore ignored withdrawal');

  for (const saved of ['invalid json', JSON.stringify({ version: 1, analytics: true, expiresAt: Date.now() - 1000 }), JSON.stringify({ version: 99, analytics: true, expiresAt: Date.now() + 1000 })]) {
    await page.evaluate(({ key, saved }) => localStorage.setItem(key, saved), { key, saved });
    await page.reload();
    check(await banner.isVisible() && requests === 4, 'Invalid or expired consent allowed tracking');
  }
  // Storage-denied browsers still get functional choices and fail closed on reload.
  const blocked = await context.newPage();
  await blocked.addInitScript(() => {
    Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('Blocked', 'SecurityError'); } });
  });
  await blocked.goto(origin + '/privacy');
  await blocked.getByRole('button', { name: 'Reject analytics', exact: true }).click();
  check(requests === 4, 'Storage denial enabled tracking');
  await blocked.reload();
  check(await blocked.getByRole('button', { name: 'Accept analytics', exact: true }).isVisible(), 'Storage denial broke notice');
  await blocked.close();
  check(errors.length === 0, 'Browser errors: ' + errors.join('; '));
  await page.setViewportSize({ width: 1280, height: 850 });
  await page.evaluate(() => localStorage.clear());
  await page.goto(origin + '/');
  return 'PASS: pre-consent blocking, reject/accept persistence, withdrawal cleanup, homepage/blog isolation, cross-tab and history withdrawal, expired/invalid/blocked storage, keyboard access, and 320/390px layouts.';
}
