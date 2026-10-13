// Browser-Test der Buttonloesung im CI-Container (synthetische Testdaten).
// Erwartet ENV BASE_URL, DESKTOP_SLUG, LANDSCAPE_SLUG, PLAIN_SLUG, ARTIFACTS.
// Prueft: Browsersprache fr, Formular trotzdem Deutsch; Abschluss-Schaltflaeche
// traegt die Beschriftung (Desktop und Handy quer); Kopfzeilen-Schaltflaeche
// unsichtbar; Vorgang ohne Ausloeser bleibt unveraendert. Legt Screenshots als
// Referenzaufnahmen ab.
import { mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';

// Playwright liegt in der CI ausserhalb des Repos (PLAYWRIGHT_DIR), daher createRequire.
const requirePw = createRequire(`${process.env.PLAYWRIGHT_DIR || process.cwd()}/package.json`);
const { chromium, devices } = requirePw('playwright');

const base = process.env.BASE_URL || 'http://localhost:3000';
const out = process.env.ARTIFACTS || 'ci-artifacts';
const LABEL = 'Zahlungspflichtig / provisionspflichtig abschließen';
mkdirSync(out, { recursive: true });

const norm = (s) => String(s || '').replace(/\s+/g, ' ').trim();
const fail = (msg) => { console.error(`FEHLER: ${msg}`); process.exitCode = 1; };

async function sign(browser, slug, name, contextOptions) {
  const context = await browser.newContext({ locale: 'fr-FR', ...contextOptions });
  const page = await context.newPage();
  page.on('pageerror', (e) => console.log(`[${name}] pageerror: ${e.message}`));
  await page.goto(`${base}/s/${slug}`, { waitUntil: 'networkidle' });

  const language = await page.locator('submission-form').getAttribute('data-language');
  if (language !== 'de') fail(`${name}: data-language=${language}, erwartet de`);

  const expand = page.locator('#expand_form_button');
  if (await expand.isVisible().catch(() => false)) await expand.click();

  const input = page.locator('#steps_form input[type="text"], #steps_form textarea').first();
  await input.waitFor({ state: 'visible', timeout: 30000 });
  await input.fill('3,57 % inkl. USt (CI)');

  const button = page.locator('#submit_form_button');
  await page.waitForFunction((l) => {
    const b = document.querySelector('#submit_form_button');
    return b && b.textContent.replace(/\s+/g, ' ').trim() === l;
  }, LABEL, { timeout: 15000 }).catch(async () => fail(`${name}: Schaltflaeche nicht beschriftet: "${norm(await button.textContent())}"`));

  const shown = norm(await button.innerText());
  console.log(`[${name}] sichtbar: "${shown}"`);
  if (shown.toLowerCase() !== LABEL.toUpperCase().toLowerCase()) fail(`${name}: sichtbarer Text "${shown}"`);
  const headerVisible = await page.locator('.complete-button').first().isVisible().catch(() => false);
  if (headerVisible) fail(`${name}: Kopfzeilen-Schaltflaeche sichtbar`);

  await page.screenshot({ path: `${out}/${name}-vor-klick.png` });
  await button.screenshot({ path: `${out}/${name}-schaltflaeche.png` });
  await button.click();
  await page.waitForSelector('#form_completed', { timeout: 60000 }).catch(() => fail(`${name}: Abschluss nicht erreicht`));
  await page.screenshot({ path: `${out}/${name}-nach-klick.png` });
  await context.close();
}

async function plainCheck(browser, slug) {
  const context = await browser.newContext({ locale: 'fr-FR' });
  const page = await context.newPage();
  await page.goto(`${base}/s/${slug}`, { waitUntil: 'networkidle' });
  if (await page.locator('#okorn_payment_notice_button').count()) fail('plain: Buttonloesung aktiv, obwohl kein Ausloeser');
  const language = await page.locator('submission-form').getAttribute('data-language');
  console.log(`[plain] data-language=${language} (Browsersprache bleibt erhalten)`);
  await page.screenshot({ path: `${out}/plain.png` });
  await context.close();
}

const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
try {
  await sign(browser, process.env.DESKTOP_SLUG, 'desktop', { viewport: { width: 1280, height: 900 } });
  await sign(browser, process.env.LANDSCAPE_SLUG, 'handy-quer', { ...devices['iPhone 13 landscape'] });
  await plainCheck(browser, process.env.PLAIN_SLUG);
} finally {
  await browser.close();
}
