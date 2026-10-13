import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const view = readFileSync(path.join(root, 'overrides/app/views/submit_form/show.html.erb'), 'utf8');
const block = view.match(/<script id="okorn_payment_notice_button"[^\n]*>\r?\n([\s\S]*?)<\/script>/);
assert.ok(block, 'The real payment-notice script must remain identifiable');

const LABEL = 'Zahlungspflichtig / provisionspflichtig abschließen';

// Minimal DOM: Elemente mit Kindern, Textknoten, einfache Selektoren (tag, #id, .klasse).
class TextNode {
  constructor(value) { this.nodeType = 3; this._value = value; this.writes = 0; this.parentElement = null; }
  get nodeValue() { return this._value; }
  set nodeValue(v) { this.writes += 1; this._value = v; }
  get textContent() { return this._value; }
}

// Wie ActiveSupport json_escape(value.to_json) auf dem Server.
const serverJson = (value) => JSON.stringify(value)
  .replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026')
  .replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

class El {
  constructor(tag, opts = {}, children = []) {
    this.nodeType = 1;
    this.tag = tag;
    this.tagName = tag.toUpperCase();
    this.id = opts.id || '';
    this.cls = opts.cls || [];
    this.style = opts.style || {};
    this.dataset = opts.dataset || {};
    this.disabled = !!opts.disabled;
    this.href = opts.href || '';
    this.visible = opts.visible !== false;
    this.children = [];
    this.parentElement = null;
    this.classList = { contains: (c) => this.cls.includes(c) };
    children.forEach((c) => this.append(typeof c === 'string' ? new TextNode(c) : c));
  }
  append(child) { child.parentElement = this; this.children.push(child); return child; }
  get firstChild() { return this.children[0] || null; }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  get innerText() { return this.style.textTransform === 'uppercase' ? this.textContent.toUpperCase() : this.textContent; }
  matches(selector) {
    return selector.split(',').map((s) => s.trim()).some((s) => {
      if (s.startsWith('#')) return this.id === s.slice(1);
      if (s.startsWith('.')) return this.cls.includes(s.slice(1));
      if (s.startsWith('a[href*=')) return this.tag === 'a' && this.href.includes(s.match(/"(.*)"/)[1]);
      return this.tag === s;
    });
  }
  closest(selector) {
    for (let e = this; e; e = e.parentElement) if (e.matches(selector)) return e;
    return null;
  }
  contains(node) {
    for (let n = node; n; n = n.parentElement) if (n === this) return true;
    return false;
  }
  getBoundingClientRect() { return { left: 10, top: 700, width: 360, height: 48 }; }
  checkVisibility() { return this.visible; }
}

function walk(node, fn) {
  fn(node);
  (node.children || []).forEach((c) => walk(c, fn));
}

function buildPage({ drawerText = 'Unterzeichnen und abschließen', headerText = 'Abschließen', extra = [], language = 'de' } = {}) {
  const drawerLabel = new TextNode(drawerText);
  const drawer = new El('button', { id: 'submit_form_button', cls: ['base-button'], style: { textTransform: 'uppercase' } }, [
    new El('span', { cls: ['flex'] }, [new El('span', {}, [drawerLabel])]),
  ]);
  const header = new El('button', { cls: ['complete-button'] }, [new El('span', {}, [new El('span', {}, [headerText])])]);
  const form = new El('submission-form', { dataset: { language } }, [new El('div', {}, [drawer, ...extra])]);
  const body = new El('body', {}, [
    new El('header', {}, [new El('span', { id: 'complete_button_container' }, [header])]),
    form,
  ]);
  return { body, drawer, drawerLabel, header, form };
}

function run(page, { label = LABEL, token = 'signiertes-token--abc', beacon = () => true, fetchImpl = null, topElement = null } = {}) {
  const sent = [];
  const fetched = [];
  const listeners = [];
  let observerCallback;
  let subscription;
  const document = {
    body: page.body,
    querySelectorAll(selector) {
      const found = [];
      walk(page.body, (n) => { if (n.nodeType === 1 && n.matches(selector)) found.push(n); });
      return found;
    },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
    getElementById(id) { return this.querySelector(`#${id}`); },
    createTreeWalker(rootNode) {
      const texts = [];
      walk(rootNode, (n) => { if (n.nodeType === 3) texts.push(n); });
      let i = 0;
      return { nextNode: () => texts[i++] ?? null };
    },
    elementFromPoint() { return topElement; },
    addEventListener(type, fn, capture) { listeners.push({ type, fn, capture }); },
  };
  class FakeBlob { constructor(parts, opts) { this.text = parts.join(''); this.type = opts.type; } }
  const window = {
    innerWidth: 390,
    innerHeight: 844,
    devicePixelRatio: 3,
    screen: { orientation: { type: 'portrait-primary' } },
    getComputedStyle: (el) => ({ fontSize: '16px', fontWeight: '600', color: 'rgb(255, 255, 255)', backgroundColor: 'rgb(41, 19, 52)', textTransform: el.style.textTransform || 'none', opacity: '1', display: 'flex', visibility: 'visible' }),
    fetch: fetchImpl || ((url, opts) => { fetched.push({ url, opts }); return Promise.resolve(); }),
  };
  const navigator = { sendBeacon: (url, blob) => { sent.push({ url, body: JSON.parse(blob.text), type: blob.type }); return beacon(); } };
  const code = block[1]
    .replace('<%= raw json_escape(okorn_button.label.to_json) %>', () => serverJson(label))
    .replace('<%= raw json_escape(okorn_token.to_json) %>', () => serverJson(token));
  assert.ok(!code.includes('<%'), 'No unhandled server template expression in executed script');
  vm.runInNewContext(code, {
    document, window, navigator, Blob: FakeBlob, location: { pathname: '/s/AbCdEf12' }, screen: window.screen,
    NodeFilter: { SHOW_TEXT: 4 },
    MutationObserver: class {
      constructor(fn) { observerCallback = fn; }
      observe(target, options) { subscription = { target, options }; }
    },
  }, { timeout: 1000 });
  assert.equal(subscription?.target, page.body, 'Dynamic form changes must be observed');
  assert.equal(subscription.options.characterData, true);
  const click = (target, isTrusted = true) => listeners.filter((l) => l.type === 'click').forEach((l) => l.fn({ type: 'click', target, isTrusted }));
  const key = (target, k = 'Enter') => listeners.filter((l) => l.type === 'keydown').forEach((l) => l.fn({ type: 'keydown', key: k, target, isTrusted: true }));
  return { sent, fetched, listeners, click, key, mutate: () => observerCallback() };
}

test('script never cancels or intercepts the signing submit', () => {
  for (const forbidden of ['preventDefault', 'stopPropagation', 'stopImmediatePropagation', 'requestSubmit']) {
    assert.ok(!block[1].includes(forbidden), `must not use ${forbidden}`);
  }
});

test('relabels the drawer button by changing the existing Vue text node only', () => {
  const page = buildPage();
  const outerSpan = page.drawer.children[0];
  run(page);
  assert.equal(page.drawerLabel.nodeValue, LABEL);
  assert.equal(page.drawer.children[0], outerSpan, 'element structure stays intact');
  assert.equal(outerSpan.children[0].children[0], page.drawerLabel, 'same text node object');
});

test('relabels every completion path: header, Einreichen (landscape), invite form, hint text', () => {
  const invite = new El('button', { cls: ['base-button'] }, [new El('span', {}, ['Abschließen'])]);
  const landscape = new El('button', {}, [new El('span', {}, ['Einreichen'])]);
  const hint = new El('div', {}, ['klicken Sie auf ', new El('span', { cls: ['font-semibold'] }, ['Abschließen'])]);
  const page = buildPage({ extra: [invite, landscape, hint] });
  run(page);
  assert.equal(page.header.textContent, LABEL);
  assert.equal(invite.textContent, LABEL);
  assert.equal(landscape.textContent, LABEL);
  assert.equal(hint.children[1].textContent, LABEL);
});

test('leaves unrelated buttons and plain text alone', () => {
  const next = new El('button', {}, [new El('span', {}, ['Weiter'])]);
  const download = new El('button', {}, ['Download']);
  const paragraph = new El('p', {}, ['Abschließen']);
  const page = buildPage({ extra: [next, download, paragraph] });
  run(page);
  assert.equal(next.textContent, 'Weiter');
  assert.equal(download.textContent, 'Download');
  assert.equal(paragraph.textContent, 'Abschließen');
});

test('re-patches after Vue re-renders and stays idempotent', () => {
  const page = buildPage({ drawerText: 'Weiter' });
  const r = run(page);
  assert.equal(page.drawerLabel.nodeValue, 'Weiter');
  page.drawerLabel.nodeValue = 'Abschließen';
  r.mutate(); r.mutate();
  assert.equal(page.drawerLabel.nodeValue, LABEL);
});

test('removes both marker spellings and updates the disclosure line', () => {
  const disclosureText = new TextNode('Mit Klick auf "Unterzeichnen und abschließen" stimmen Sie dem');
  const disclosure = new El('div', {}, [disclosureText, new El('a', { href: 'https://www.docuseal.com/esign-disclosure' }, ['ESIGN'])]);
  const fieldA = new El('label', {}, ['Name ##button: Eigener Text##']);
  const fieldB = new El('label', {}, ['Titel ##button->Weiter##']);
  const page = buildPage({ extra: [disclosure, fieldA, fieldB] });
  run(page);
  assert.equal(disclosureText.nodeValue, `Mit Klick auf "${LABEL}" stimmen Sie dem`);
  assert.equal(fieldA.textContent, 'Name ');
  assert.equal(fieldB.textContent, 'Titel ');
});

test('custom labels arrive verbatim, including quotes, ampersands and markup-like text', () => {
  const label = 'Kosten & "Provision" <b>\'zahlungspflichtig\'</b> </script>';
  const page = buildPage();
  run(page, { label });
  assert.equal(page.drawerLabel.nodeValue, label);
});

test('a label that equals a DocuSeal text does not loop the observer', () => {
  const page = buildPage({ drawerText: 'Abschließen' });
  const r = run(page, { label: 'Abschließen' });
  r.mutate(); r.mutate(); r.mutate();
  assert.equal(page.drawerLabel.writes, 0, 'no write when the text already equals the label');
});

test('click on the labelled button reports what was shown to the own server', () => {
  const page = buildPage();
  const r = run(page, { topElement: null });
  r.click(page.drawer.children[0].children[0]);
  assert.equal(r.sent.length, 1);
  const { url, body, type } = r.sent[0];
  assert.equal(url, '/okorn/button_evidence');
  assert.equal(type, 'application/json');
  assert.equal(body.token, 'signiertes-token--abc');
  assert.equal(body.text, LABEL);
  assert.equal(body.rendered, LABEL.toUpperCase());
  assert.equal(body.kind, 'drawer');
  assert.equal(body.form_language, 'de');
  assert.equal(body.visible, true);
  assert.equal(body.covered, false);
  assert.equal(body.is_trusted, true);
  assert.equal(body.style.text_transform, 'uppercase');
  assert.deepEqual(body.rect, { w: 360, h: 48 });
  for (const field of ['slug', 'lang', 'user_agent', 'viewport', 'dpr', 'orientation', 'path', 'client_ts', 'top_element']) {
    assert.ok(!(field in body), `no ${field}: only data about the button`);
  }
});

test('Enter inside the form reports the drawer button (completion without click)', () => {
  const input = new El('input');
  const page = buildPage({ extra: [input] });
  const r = run(page);
  r.key(input);
  r.key(input, 'a');
  assert.equal(r.sent.length, 1);
  assert.equal(r.sent[0].body.event_type, 'keydown_enter');
  assert.equal(r.sent[0].body.text, LABEL);
});

test('reports covered buttons, header clicks and unpatched completion buttons', () => {
  const overlay = new El('div', { id: 'cookie' });
  const page = buildPage();
  const r = run(page, { topElement: overlay });
  r.click(page.drawer);
  assert.equal(r.sent[0].body.covered, true);
  r.click(page.header);
  assert.equal(r.sent[1].body.kind, 'header');
});

test('ignores clicks that are not on a completion button', () => {
  const next = new El('button', {}, [new El('span', {}, ['Weiter'])]);
  const page = buildPage({ extra: [next] });
  const r = run(page);
  r.click(next.children[0]);
  r.click(page.form);
  r.click(null);
  assert.equal(r.sent.length, 0);
});

test('falls back to keepalive fetch and never throws into the signing flow', () => {
  const page = buildPage();
  const r = run(page, { beacon: () => false });
  r.click(page.drawer);
  assert.equal(r.fetched.length, 1);
  assert.equal(r.fetched[0].opts.keepalive, true);

  const page2 = buildPage();
  const broken = run(page2, { beacon: () => { throw new Error('blocked'); } });
  assert.doesNotThrow(() => broken.click(page2.drawer));
  assert.equal(broken.sent.length, 1, 'beacon was attempted, the error stayed inside the handler');
});

test('view renders the form in German and hides the header button when the label is active', () => {
  assert.match(view, /okorn_button = OkornButtonLabel\.compute\(@submitter\)/);
  assert.match(view, /okorn_token = OkornEvidence::RailsHooks\.served_button\(request, @submitter, okorn_button\)/);
  assert.ok(!/<%= j /.test(block[1]), 'no double-escaping j helper inside the script');
  assert.match(view, /I18n\.with_locale\(okorn_button \? :de : I18n\.locale\) \{ render 'submit_form\/submission_form'/);
  assert.match(view, /\.complete-button \{ display: none !important; \}/);
  assert.match(view, /<% if okorn_button %>/);
});

test('overlay keeps attribution implementation upstream and pins the base version', () => {
  for (const rel of ['overrides/app/views/shared/_attribution.html.erb', 'overrides/app/views/shared/_powered_by.html.erb', 'overrides/lib/docuseal.rb']) {
    assert.equal(existsSync(path.join(root, rel)), false, `Attribution/product source must not be overridden: ${rel}`);
  }
  assert.match(view, /render 'shared\/attribution'/);
  const docker = readFileSync(path.join(root, 'Dockerfile'), 'utf8');
  assert.match(docker, /^ARG DOCUSEAL_VERSION=\d+\.\d+\.\d+$/m);
  assert.match(docker, /AGPL-3\.0-or-later/);
  assert.match(docker, /COPY overrides\/config\/ \/app\/config\//, 'initializer and okorn modules must be in the image');
  assert.match(docker, /COPY overrides\/app\/ \/app\/app\//, 'views and the evidence controller must be in the image');
  assert.ok(existsSync(path.join(root, 'overrides/config/initializers/zz_okorn_evidence.rb')));
});
