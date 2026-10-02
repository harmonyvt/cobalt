// Shared builder helpers for the cobalt Shortcuts (build.mjs -> cobalt-webp,
// studio.mjs -> cobalt-studio). Node built-ins + macOS `plutil`/`shortcuts` only.
//
//   const sc = createShortcut({ slug: 'cobalt-webp' });
//   sc.act(...); sc.ifBlock(...); ...
//   sc.finish({ workflow, keyAction, kind, keyQuestion })
//
// The plist schema follows the community-documented format (Cherri,
// sebj/iOS-Shortcuts-Reference) and Apple's own Gallery .wflow files.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { writeFileSync, statSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const here = dirname(fileURLToPath(import.meta.url));
export const BASE_URL = 'https://api.capybaraharmony.com';
export const OBJ = '￼'; // object replacement char: placeholder for an inline variable

// Dictionary item types, and legacy integer WFCondition codes (still read by
// current Shortcuts).
export const TEXT = 0;
export const NUMBER = 3;
export const IS = 4;
export const LESS = 0;
export const GREATER = 2;
export const ANY = 100;
export const EMPTY = 101;

// References to values (the action-output one is on the builder: it needs the
// shortcut's UUID namespace).
export const variable = (name) => ({ VariableName: name, Type: 'Variable' });
export const EXT_INPUT = { Type: 'ExtensionInput' };
export const att = (ref) => ({ Value: ref, WFSerializationType: 'WFTextTokenAttachment' });

/** Text with inline variables: strings and refs interleaved. */
export const tstr = (...parts) => {
  let string = '';
  const attachmentsByRange = {};
  for (const p of parts) {
    if (typeof p === 'string') string += p;
    else {
      attachmentsByRange[`{${string.length}, 1}`] = p;
      string += OBJ;
    }
  }
  const Value = { string };
  if (Object.keys(attachmentsByRange).length) Value.attachmentsByRange = attachmentsByRange;
  return { Value, WFSerializationType: 'WFTextTokenString' };
};

export const dict = (items) => ({
  Value: {
    WFDictionaryFieldValueItems: items.map(([key, type, value]) => ({
      WFItemType: type,
      WFKey: tstr(key),
      WFValue: value,
    })),
  },
  WFSerializationType: 'WFDictionaryFieldValue',
});

const condInput = (ref) => ({ Type: 'Variable', Variable: att(ref) });
// A text comparison needs its left side typed as Text ("Get As Text"). An
// untyped Dictionary Value made macOS 27 show "If Dictionary Value is ___" with
// the text field empty even when WFConditionalActionString was set (2026-09-30).
const asText = (ref) => ({
  ...ref,
  Aggrandizements: [{ Type: 'WFCoercionVariableAggrandizement', CoercionItemClass: 'WFStringContentItem' }],
});
// The comparison text must be a WFTextTokenString: macOS 27 imported a plain
// string as an empty field ("If Dictionary Value is ___") and every run failed
// with "Please choose a value for each parameter in this action" (2026-09-30).
export const isText = (s) => ({ WFConditionalActionString: tstr(s) });

// ----------------------------------------------------------- plist writer ---

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
export const plist = (v, ind = '') => {
  const nx = `${ind}\t`;
  if (typeof v === 'string') return `${ind}<string>${esc(v)}</string>\n`;
  if (typeof v === 'boolean') return `${ind}<${v}/>\n`;
  if (typeof v === 'number') {
    return Number.isInteger(v) ? `${ind}<integer>${v}</integer>\n` : `${ind}<real>${v}</real>\n`;
  }
  if (Array.isArray(v)) {
    return v.length ? `${ind}<array>\n${v.map((x) => plist(x, nx)).join('')}${ind}</array>\n` : `${ind}<array/>\n`;
  }
  const keys = Object.keys(v).filter((k) => v[k] !== undefined);
  if (!keys.length) return `${ind}<dict/>\n`;
  return `${ind}<dict>\n${keys.map((k) => `${nx}<key>${esc(k)}</key>\n${plist(v[k], nx)}`).join('')}${ind}</dict>\n`;
};

// ---------------------------------------------------------------- builder ---

/**
 * `slug` names the shortcut: it prefixes the deterministic UUIDs and the output
 * files (<slug>.unsigned.shortcut, <slug>.shortcut).
 *
 * Personal build: COBALT_SHORTCUT_KEY_FILE (JSON {"key": "<uuid>"}, chmod 600)
 * embeds that key and drops the import question, and COBALT_SHORTCUT_OUT is the
 * signed output path (outside the repo). The v1 import question re-prompted
 * forever on macOS 27 (2026-09-30). The unsigned intermediates go to a private
 * temp dir and are deleted, so the key never lands in the worktree.
 */
export const createShortcut = ({ slug }) => {
  const KEY_FILE = process.env.COBALT_SHORTCUT_KEY_FILE;
  const PERSONAL_KEY = KEY_FILE ? JSON.parse(readFileSync(KEY_FILE, 'utf8')).key : '';
  if (KEY_FILE && !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(PERSONAL_KEY)) {
    throw new Error('COBALT_SHORTCUT_KEY_FILE must hold {"key": "<lowercase uuidv4>"}');
  }
  if (KEY_FILE && !process.env.COBALT_SHORTCUT_OUT) throw new Error('personal build needs COBALT_SHORTCUT_OUT');
  const workDir = KEY_FILE ? mkdtempSync(join(tmpdir(), 'cobalt-shortcut-')) : here;
  const XML_OUT = join(workDir, `${slug}.unsigned.xml`);
  const UNSIGNED = join(workDir, `${slug}.unsigned.shortcut`);
  const SIGNED = KEY_FILE ? process.env.COBALT_SHORTCUT_OUT : join(here, `${slug}.shortcut`);

  /** Deterministic UUID so rebuilds are byte-stable. */
  const uuid = (label) => {
    const h = createHash('sha256').update(`${slug}:${label}`).digest('hex').toUpperCase();
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-A${h.slice(17, 20)}-${h.slice(20, 32)}`;
  };
  const out = (label, name) => ({ OutputUUID: uuid(label), OutputName: name, Type: 'ActionOutput' });

  const actions = [];
  const idx = () => actions.length; // index the next pushed action will get
  const act = (id, params = {}) => {
    actions.push({
      WFWorkflowActionIdentifier: `is.workflow.actions.${id}`,
      WFWorkflowActionParameters: params,
    });
    return actions.length - 1;
  };

  let groupN = 0;
  const group = () => uuid(`group-${groupN++}`);

  /** If block. `body`/`orElse` are callbacks that push the inner actions. */
  const ifBlock = (ref, code, extra, body, orElse) => {
    const g = group();
    act('conditional', {
      GroupingIdentifier: g,
      WFControlFlowMode: 0,
      WFInput: condInput('WFConditionalActionString' in extra ? asText(ref) : ref),
      WFCondition: code,
      ...extra,
    });
    body();
    if (orElse) {
      act('conditional', { GroupingIdentifier: g, WFControlFlowMode: 1 });
      orElse();
    }
    act('conditional', { GroupingIdentifier: g, WFControlFlowMode: 2, UUID: uuid(`${g}-end`) });
  };

  const setVar = (name, ref) => act('setvariable', { WFVariableName: name, WFInput: att(ref) });
  const comment = (text) => act('comment', { WFCommentActionText: text });

  const alertAct = (title, ...msg) =>
    act('alert', {
      WFAlertActionTitle: title,
      WFAlertActionMessage: tstr(...msg),
      WFAlertActionCancelButtonShown: false,
    });
  const notify = (title, ...body) =>
    act('notification', {
      WFNotificationActionTitle: title,
      WFNotificationActionBody: tstr(...body),
      WFNotificationActionSound: true,
    });

  const headers = () =>
    dict([
      ['Authorization', TEXT, tstr('Api-Key ', variable('apikey'))],
      ['Content-Type', TEXT, tstr('application/json')],
      ['Accept', TEXT, tstr('application/json')],
    ]);

  const post = (label, urlParts, body) =>
    act('downloadurl', {
      UUID: uuid(label),
      WFURL: tstr(...urlParts),
      WFHTTPMethod: 'POST',
      WFHTTPHeaders: headers(),
      WFHTTPBodyType: 'JSON',
      WFJSONValues: body,
      ShowHeaders: true,
    });

  const get = (label, urlParts, withAuth) =>
    act('downloadurl', {
      UUID: uuid(label),
      WFURL: tstr(...urlParts),
      WFHTTPMethod: 'GET',
      ...(withAuth ? { WFHTTPHeaders: headers() } : {}),
      ShowHeaders: true,
    });

  const dictValue = (label, key, from) =>
    act('getvalueforkey', {
      UUID: uuid(label),
      WFInput: att(from),
      WFGetDictionaryValueType: 'Value',
      WFDictionaryKey: key,
    });

  /** Config prelude: the API key Text (import-question target; the personal key when built personally) and the base URL. */
  const configActions = () => {
    const keyAction = idx();
    act('gettext', { UUID: uuid('key'), WFTextActionText: PERSONAL_KEY });
    setVar('apikey', out('key', 'Text'));
    act('gettext', { UUID: uuid('base'), WFTextActionText: BASE_URL });
    setVar('base', out('base', 'Text'));
    return keyAction;
  };

  /**
   * The link input: ONE Text holding the share-sheet input and the clipboard
   * (no If, no WFWorkflowNoInputBehavior, no "Get URLs from Input"; see the
   * lessons in README.md), stored in variable `link`. The API Worker takes the
   * first http(s) link out of it. COBALT_SHORTCUT_DEBUG_URL swaps the
   * clipboard for a fixed Text, to tell "can't read the clipboard" apart from
   * a later-step bug.
   */
  const linkInput = () => {
    if (process.env.COBALT_SHORTCUT_DEBUG_URL) {
      act('gettext', { UUID: uuid('clip'), WFTextActionText: process.env.COBALT_SHORTCUT_DEBUG_URL });
    } else {
      act('getclipboard', { UUID: uuid('clip') });
    }
    act('gettext', { UUID: uuid('src'), WFTextActionText: tstr(EXT_INPUT, '\n', out('clip', 'Clipboard')) });
    setVar('link', out('src', 'Text'));
  };

  /**
   * Write, lint, verify and sign. `workflow` is the top-level WFWorkflow dict
   * without actions / import questions. `kind` selects the verify.mjs checks.
   */
  const finish = ({ workflow, keyAction, kind, keyQuestion }) => {
    const full = {
      ...workflow,
      WFWorkflowImportQuestions: KEY_FILE ? [] : [
        {
          Category: 'Parameter',
          ActionIndex: keyAction,
          ParameterKey: 'WFTextActionText',
          Text: keyQuestion,
          DefaultValue: '',
        },
      ],
      WFWorkflowActions: actions,
    };
    const xml =
      '<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
      `<plist version="1.0">\n${plist(full)}</plist>\n`;

    writeFileSync(XML_OUT, xml);
    execFileSync('plutil', ['-lint', XML_OUT], { stdio: 'inherit' });
    execFileSync('plutil', ['-convert', 'binary1', '-o', UNSIGNED, XML_OUT]);
    execFileSync('rm', ['-f', XML_OUT]);
    console.log(`wrote ${UNSIGNED} (${statSync(UNSIGNED).size} bytes, ${actions.length} actions)`);

    execFileSync('node', [join(here, 'verify.mjs'), UNSIGNED, kind], {
      stdio: 'inherit',
      env: { ...process.env, COBALT_SHORTCUT_PERSONAL: KEY_FILE ? '1' : '' },
    });

    execFileSync('shortcuts', ['sign', '--mode', 'anyone', '--input', UNSIGNED, '--output', SIGNED], {
      stdio: 'inherit',
    });
    console.log(`signed ${SIGNED} (${statSync(SIGNED).size} bytes)`);
    if (KEY_FILE) rmSync(workDir, { recursive: true, force: true });
  };

  return {
    uuid, out, group, actions, idx, act, ifBlock, setVar, comment, alertAct, notify,
    headers, post, get, dictValue, configActions, linkInput, finish,
  };
};
