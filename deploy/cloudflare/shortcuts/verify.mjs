#!/usr/bin/env node
// Structural check of an unsigned workflow plist (independent of build.mjs/lib.mjs).
//   node verify.mjs cobalt-webp.unsigned.shortcut [webp|studio]
// The kind defaults to "studio" when the file name contains "studio", else "webp".
// COBALT_SHORTCUT_PERSONAL=1 checks a personal build (key embedded, no import question).
import { execFileSync } from 'node:child_process';

const file = process.argv[2];
if (!file) {
  console.error('usage: verify.mjs <unsigned.shortcut> [webp|studio]');
  process.exit(2);
}
const kind = process.argv[3] ?? (/studio/.test(file) ? 'studio' : 'webp');
if (kind !== 'webp' && kind !== 'studio') {
  console.error(`unknown kind ${kind}`);
  process.exit(2);
}
const wf = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', file]).toString());
const acts = wf.WFWorkflowActions;
const errors = [];
const fail = (m) => errors.push(m);
const short = (a) => a.WFWorkflowActionIdentifier.replace('is.workflow.actions.', '');
const params = (a) => a.WFWorkflowActionParameters ?? {};

// Walk every value inside a parameter tree.
const walk = (v, fn) => {
  if (Array.isArray(v)) v.forEach((x) => walk(x, fn));
  else if (v && typeof v === 'object') {
    fn(v);
    Object.values(v).forEach((x) => walk(x, fn));
  }
};

// 1. Output UUID references resolve to an earlier action; named variables are set earlier.
const definedAt = new Map();
const varSetAt = new Map();
acts.forEach((a, i) => {
  const p = params(a);
  if (p.UUID) {
    if (definedAt.has(p.UUID)) fail(`duplicate UUID at action ${i}`);
    definedAt.set(p.UUID, i);
  }
  walk(p, (o) => {
    if (o.OutputUUID) {
      if (!definedAt.has(o.OutputUUID) || definedAt.get(o.OutputUUID) >= i) {
        fail(`action ${i} (${short(a)}) references OutputUUID ${o.OutputUUID} not defined earlier`);
      }
    }
    if (o.Type === 'Variable' && o.VariableName && !(varSetAt.get(o.VariableName) < i)) {
      fail(`action ${i} (${short(a)}) reads variable "${o.VariableName}" before any setvariable`);
    }
  });
  if (short(a) === 'setvariable' && !varSetAt.has(p.WFVariableName)) varSetAt.set(p.WFVariableName, i);
});

// 2. Control flow: If/Otherwise/End If and Repeat are properly nested and closed.
const stack = [];
acts.forEach((a, i) => {
  const id = short(a);
  const p = params(a);
  if (id !== 'conditional' && id !== 'repeat.count') return;
  const g = p.GroupingIdentifier;
  const mode = p.WFControlFlowMode;
  if (!g) return fail(`action ${i} ${id} missing GroupingIdentifier`);
  if (mode === 0) stack.push({ id, g, sawElse: false, i });
  else {
    const top = stack[stack.length - 1];
    if (!top || top.g !== g || top.id !== id) return fail(`action ${i} ${id} mode ${mode} does not match open block`);
    if (mode === 1) {
      if (id !== 'conditional' || top.sawElse) fail(`action ${i} bad Otherwise`);
      top.sawElse = true;
    } else if (mode === 2) {
      stack.pop();
      if (!p.UUID) fail(`action ${i} end block has no UUID`);
    } else fail(`action ${i} bad WFControlFlowMode ${mode}`);
  }
  if (id === 'repeat.count' && mode === 0 && kind === 'webp' && p.WFRepeatCount !== 15) fail('repeat count is not 15');
});
if (stack.length) fail(`unclosed blocks: ${stack.map((s) => `${s.id}@${s.i}`).join(', ')}`);

// 2b. Every If: the comparison text is a WFTextTokenString (a plain string imports
// as an empty field on macOS 27) and the input is coerced to Text (asText), or the
// field also imports empty.
acts.forEach((a, i) => {
  const p = params(a);
  if (short(a) !== 'conditional' || p.WFControlFlowMode !== 0) return;
  const s = p.WFConditionalActionString;
  if (s?.WFSerializationType !== 'WFTextTokenString' || typeof s?.Value?.string !== 'string' || !s.Value.string) {
    fail(`action ${i} If: WFConditionalActionString is not a non-empty WFTextTokenString`);
  }
  const coerced = (p.WFInput?.Variable?.Value?.Aggrandizements ?? []).some(
    (g) => g.Type === 'WFCoercionVariableAggrandizement' && g.CoercionItemClass === 'WFStringContentItem',
  );
  if (!coerced) fail(`action ${i} If: WFInput is not coerced to Text (asText aggrandizement missing)`);
});

// 3. Token strings: every attachment range points at an object-replacement char.
walk(wf.WFWorkflowActions, (o) => {
  if (o.WFSerializationType === 'WFTextTokenString' && o.Value?.attachmentsByRange) {
    const s = o.Value.string;
    const ranges = Object.keys(o.Value.attachmentsByRange);
    const chars = [...s].filter((c) => c === '￼').length;
    if (chars !== ranges.length) fail(`token string ${JSON.stringify(s)}: ${chars} placeholders vs ${ranges.length} ranges`);
    for (const r of ranges) {
      const m = /^\{(\d+), 1\}$/.exec(r);
      if (!m || s[Number(m[1])] !== '￼') fail(`token string ${JSON.stringify(s)}: bad range ${r}`);
    }
  }
});

// 4. Import question -> the API key Text action.
const q = wf.WFWorkflowImportQuestions ?? [];
const personal = process.env.COBALT_SHORTCUT_PERSONAL === '1';
if (personal) {
  // Personal build: key embedded, no import question.
  if (q.length !== 0) fail(`personal build should have no import question, got ${q.length}`);
  const keyText = acts.find((a) => short(a) === 'gettext' && /^[0-9a-f-]{36}$/.test(params(a).WFTextActionText ?? ''));
  if (!keyText) fail('personal build: no embedded key Text action');
} else if (q.length !== 1) fail(`expected 1 import question, got ${q.length}`);
for (const iq of q) {
  const a = acts[iq.ActionIndex];
  if (!a || short(a) !== 'gettext') fail('import question does not point at a gettext action');
  else {
    if (!(iq.ParameterKey in params(a))) fail('import question ParameterKey not on target action');
    if (params(a)[iq.ParameterKey] !== '') fail('API key text is not empty (real key embedded?)');
    const uuid = params(a).UUID;
    const setter = acts[iq.ActionIndex + 1];
    if (short(setter) !== 'setvariable' || params(setter).WFVariableName !== 'apikey'
      || params(setter).WFInput.Value.OutputUUID !== uuid) fail('key Text is not stored in variable "apikey"');
  }
}
if (!personal) {
  // Default build: whatever the key Text is, it must be empty.
  const keyAction = acts.find((a) => short(a) === 'gettext' && params(a).UUID && acts[acts.indexOf(a) + 1]
    && short(acts[acts.indexOf(a) + 1]) === 'setvariable' && params(acts[acts.indexOf(a) + 1]).WFVariableName === 'apikey');
  if (!keyAction) fail('no Text -> Set Variable "apikey" pair found');
  else if (params(keyAction).WFTextActionText !== '') fail('default build: key Text is not empty');
}

// 5. Every HTTP request to the API sends the auth header built from $apikey (except the tunnel GET).
const requests = acts.filter((a) => short(a) === 'downloadurl');
const isAuthed = (a) => JSON.stringify(params(a).WFHTTPHeaders ?? '').includes('"VariableName":"apikey"');
const authed = requests.filter(isAuthed);
for (const a of authed) {
  const items = params(a).WFHTTPHeaders.Value.WFDictionaryFieldValueItems;
  const names = items.map((i) => i.WFKey.Value.string);
  for (const h of ['Authorization', 'Content-Type', 'Accept']) if (!names.includes(h)) fail(`request missing header ${h}`);
  const auth = items.find((i) => i.WFKey.Value.string === 'Authorization');
  if (!auth?.WFValue?.Value?.string?.startsWith('Api-Key ')) fail('Authorization header is not "Api-Key <key>"');
}

if (kind === 'webp') {
  if (requests.length !== 4 || authed.length !== 3) fail(`expected 4 requests / 3 authed, got ${requests.length} / ${authed.length}`);
} else {
  // studio: exactly one request, the authed POST to <base>/studio with {url: link}. Nothing else.
  if (requests.length !== 1 || authed.length !== 1) fail(`studio: expected 1 request / 1 authed, got ${requests.length} / ${authed.length}`);
  const r = requests[0] && params(requests[0]);
  if (r) {
    if (r.WFHTTPMethod !== 'POST') fail('studio: request is not a POST');
    if (r.WFHTTPBodyType !== 'JSON') fail('studio: request body is not JSON');
    const u = r.WFURL?.Value;
    if (u?.string !== '￼/studio' || !JSON.stringify(u.attachmentsByRange).includes('"base"')) {
      fail(`studio: URL is not <base>/studio (${JSON.stringify(u?.string)})`);
    }
    const bodyItems = r.WFJSONValues?.Value?.WFDictionaryFieldValueItems ?? [];
    if (bodyItems.length !== 1 || bodyItems[0].WFKey.Value.string !== 'url'
      || !JSON.stringify(bodyItems[0].WFValue).includes('"VariableName":"link"')) fail('studio: body is not {url: $link}');
  }
  // The base Text must be the API host.
  const base = acts.find((a) => short(a) === 'gettext' && /^https:\/\//.test(params(a).WFTextActionText ?? ''));
  if (base?.WFWorkflowActionParameters.WFTextActionText !== 'https://api.capybaraharmony.com') fail('studio: base URL is not the api host');

  const count = (id) => acts.filter((a) => short(a) === id).length;
  if (count('openurl') !== 1) fail(`studio: expected 1 Open URLs action, got ${count('openurl')}`);
  else {
    const o = acts.find((a) => short(a) === 'openurl');
    if (!params(o).WFInput?.Value?.OutputUUID) fail('studio: Open URLs input is not an action output');
  }
  for (const banned of ['repeat.count', 'documentpicker.save', 'getitemfromlist', 'setclipboard']) {
    if (count(banned)) fail(`studio: unexpected ${banned} action`);
  }
  if (count('notification') !== 1) fail(`studio: expected 1 notification, got ${count('notification')}`);
  const alerts = acts.filter((a) => short(a) === 'alert');
  if (alerts.length !== 2) fail(`studio: expected 2 alerts, got ${alerts.length}`);
  if (!alerts.some((a) => /copy a link first/.test(JSON.stringify(params(a).WFAlertActionMessage)))) fail('studio: no "copy a link first" hint');
  // Shape: the top-level If tests "success" and has an Otherwise; Open URLs sits inside its first branch.
  const firstIf = acts.findIndex((a) => short(a) === 'conditional' && params(a).WFControlFlowMode === 0);
  const s = params(acts[firstIf] ?? {}).WFConditionalActionString?.Value?.string;
  if (s !== 'success') fail(`studio: first If does not test "success" (${JSON.stringify(s)})`);
  const g = params(acts[firstIf] ?? {}).GroupingIdentifier;
  const elseAt = acts.findIndex((a) => short(a) === 'conditional' && params(a).GroupingIdentifier === g && params(a).WFControlFlowMode === 1);
  const openAt = acts.findIndex((a) => short(a) === 'openurl');
  if (elseAt < 0) fail('studio: first If has no Otherwise');
  if (!(firstIf < openAt && openAt < elseAt)) fail('studio: Open URLs is not inside the success branch');
}

// 6. No literal secret-looking strings anywhere.
if (/Api-Key [0-9a-f]{8}-|"[0-9a-f]{32,}"/i.test(JSON.stringify(wf))) fail('a literal key looks embedded');

// 7. Top-level fields.
for (const k of ['WFWorkflowIcon', 'WFWorkflowActions', 'WFWorkflowInputContentItemClasses', 'WFWorkflowTypes']) {
  if (!wf[k]) fail(`missing ${k}`);
}
for (const c of ['WFURLContentItem', 'WFStringContentItem', 'WFSafariWebPageContentItem']) {
  if (!wf.WFWorkflowInputContentItemClasses.includes(c)) fail(`input class ${c} missing`);
}

if (errors.length) {
  console.error(`verify (${kind}): ${errors.length} problem(s)\n - ${errors.join('\n - ')}`);
  process.exit(1);
}
console.log(
  `verify (${kind}): ok (${acts.length} actions, ${definedAt.size} output UUIDs, ${varSetAt.size} variables, ` +
    `${acts.filter((a) => short(a) === 'conditional' && params(a).WFControlFlowMode === 0).length} If blocks, ` +
    `${acts.filter((a) => short(a) === 'repeat.count' && params(a).WFControlFlowMode === 0).length} Repeat)`,
);
