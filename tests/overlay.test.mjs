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

function run({ label = 'Testvertrag abschließen', spans = [], text = [], disclosure = null, button = true } = {}) {
  const nodes = text.map(nodeValue => ({ nodeValue }));
  const spanNodes = spans.map(textContent => ({ textContent }));
  const disclosureNode = disclosure === null ? null : { nodeType: 3, nodeValue: disclosure };
  let callback;
  let subscription;
  const document = {
    body: {},
    getElementById(id) { return button && id === 'submit_form_button' ? { querySelectorAll: () => spanNodes } : null; },
    querySelector() { return disclosureNode ? { parentElement: { firstChild: disclosureNode } } : null; },
    createTreeWalker() { let index = 0; return { nextNode: () => nodes[index++] ?? null }; },
  };
  const code = block[1].replace("'<%= j okorn_payment_label %>'", JSON.stringify(label));
  assert.ok(!code.includes('<%'), 'No unhandled server template expression in executed script');
  vm.runInNewContext(code, {
    document, NodeFilter: { SHOW_TEXT: 4 },
    MutationObserver: class {
      constructor(fn) { callback = fn; }
      observe(target, options) { subscription = { target, options }; }
    },
  }, { timeout: 1000 });
  assert.equal(subscription?.target, document.body, 'Dynamic form changes must be observed');
  assert.equal(subscription.options.childList, true);
  assert.equal(subscription.options.subtree, true);
  return { spanNodes, nodes, disclosureNode, callback };
}

test('updates German and English completion labels, retaining unrelated controls', () => {
  const r = run({ spans: ['Unterzeichnen und abschließen', 'Complete', 'Download'] });
  assert.deepEqual(r.spanNodes.map(x => x.textContent), ['Testvertrag abschließen', 'Testvertrag abschließen', 'Download']);
});

test('updates disclosure and removes both marker spellings', () => {
  const r = run({ disclosure: 'Mit Complete bestätige ich', text: ['Name ##button: Eigener Text##', 'Titel ##button->Weiter##'] });
  assert.equal(r.disclosureNode.nodeValue, 'Mit Testvertrag abschließen bestätige ich');
  assert.deepEqual(r.nodes.map(x => x.nodeValue), ['Name ', 'Titel ']);
});

test('handles absent form elements and repeated mutation callbacks', () => {
  assert.doesNotThrow(() => run({ button: false }).callback());
  const r = run({ spans: ['Complete'], text: ['##button: Los## Inhalt'] });
  r.callback(); r.callback();
  assert.equal(r.spanNodes[0].textContent, 'Testvertrag abschließen');
  assert.equal(r.nodes[0].nodeValue, ' Inhalt');
});

test('custom labels are text values, including quotes and markup-like text', () => {
  const label = 'Ja, "ich" <bestätige> diesen Test';
  assert.equal(run({ label, spans: ['Complete'] }).spanNodes[0].textContent, label);
});

test('overlay keeps attribution implementation upstream and pins the base version', () => {
  for (const rel of ['overrides/app/views/shared/_attribution.html.erb', 'overrides/app/views/shared/_powered_by.html.erb', 'overrides/lib/docuseal.rb']) {
    assert.equal(existsSync(path.join(root, rel)), false, `Attribution/product source must not be overridden: ${rel}`);
  }
  assert.match(view, /render 'shared\/attribution'/);
  const docker = readFileSync(path.join(root, 'Dockerfile'), 'utf8');
  assert.match(docker, /^ARG DOCUSEAL_VERSION=\d+\.\d+\.\d+$/m);
  assert.match(docker, /AGPL-3\.0-or-later/);
});
