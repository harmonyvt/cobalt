#!/usr/bin/env node
// Generates the "cobalt → webp" macOS Shortcut for the private cobalt instance.
//
//   node deploy/cloudflare/shortcuts/build.mjs
//
// Writes cobalt-webp.unsigned.shortcut (binary WFWorkflow plist), verifies its
// structure (verify.mjs), then signs it with `shortcuts sign --mode anyone` into
// cobalt-webp.shortcut. Node built-ins + macOS `plutil`/`shortcuts` only. The
// shared helpers (plist writer, token strings, If blocks, personal-build mode)
// live in lib.mjs; studio.mjs builds the sibling "cobalt studio" shortcut.
//
// No API key is embedded in the default build: the key is a Text action filled
// in by an import question. Personal build: see lib.mjs / README.md
// (COBALT_SHORTCUT_KEY_FILE + COBALT_SHORTCUT_OUT).

import { createShortcut, tstr, dict, variable, TEXT, IS, isText, att } from './lib.mjs';

const sc = createShortcut({ slug: 'cobalt-webp' });
const { out, act, ifBlock, setVar, comment, alertAct, notify, post, get, dictValue, uuid, group } = sc;

const NAME = 'cobalt → webp';
const KEY_QUESTION = 'paste your cobalt api key (settings → instances → api keys)';

// ---------------------------------------------------------------- actions ---

// 1. Config: API key (import question) and base URL.
comment(
  `${NAME}: downloads the original video AND turns the whole video (up to the API's limit) into an animated webp on the cobalt instance. ` +
    'Run from the share sheet (link or page) or with a link on the clipboard.',
);
const keyAction = sc.configActions();

// 2. Input: share-sheet input first, then the clipboard; first URL wins.
// No If here on purpose. v1 branched on "Shortcut Input has any value" and
// alerted "no link found" with an x.com link on the clipboard; v2 relied on
// WFWorkflowNoInputBehaviorGetClipboard, but macOS 27 imported it as "If
// there's no input: Continue", so "Get URLs from Input" got nothing and failed
// with "Please choose a value for each parameter" (2026-09-30). Now one Text
// action holds the share input and the clipboard, and the first URL in it is
// used; an empty share input just contributes nothing.
comment('1. The link: share-sheet input first, otherwise the clipboard.');
// The text goes to the API as-is; the API Worker takes the first http(s) link
// from it (normalizeUrlField). "Get URLs from Input" -> "Get First Item" here
// produced an empty string on macOS 27 even with a fixed URL (request_log,
// 2026-09-30). COBALT_SHORTCUT_DEBUG_URL (see lib.mjs) replaces the clipboard.
sc.linkInput();

// 3. No clip window: the whole video is converted and the API rejects videos
// that are too long (error.webp.too_long), per the owner (2026-09-30).

// 4. Original download FIRST (tunnel links expire in 90 s).
comment('3. Original download -> Downloads. A failure here only notifies; the webp step still runs.');
post('orig', [variable('base'), '/'], dict([['url', TEXT, tstr(variable('link'))]]));
dictValue('orig-status', 'status', out('orig', 'Contents of URL'));
ifBlock(
  out('orig-status', 'Dictionary Value'),
  IS,
  isText('error'),
  () => {
    dictValue('orig-err', 'error.code', out('orig', 'Contents of URL'));
    notify('original download failed', 'error: ', out('orig-err', 'Dictionary Value'));
  },
  () => {
    // Otherwise: tunnel / redirect / picker.
    ifBlock(
      out('orig-status', 'Dictionary Value'),
      IS,
      isText('picker'),
      () => {
        dictValue('pick-list', 'picker', out('orig', 'Contents of URL'));
        act('getitemfromlist', {
          UUID: uuid('pick-first'),
          WFInput: att(out('pick-list', 'Dictionary Value')),
          WFItemSpecifier: 'First Item',
        });
        dictValue('pick-url', 'url', out('pick-first', 'Item from List'));
        setVar('dlurl', out('pick-url', 'Dictionary Value'));
        dictValue('pick-name', 'filename', out('pick-first', 'Item from List'));
        setVar('dlname', out('pick-name', 'Dictionary Value'));
      },
      () => {
        dictValue('dl-url', 'url', out('orig', 'Contents of URL'));
        setVar('dlurl', out('dl-url', 'Dictionary Value'));
        dictValue('dl-name', 'filename', out('orig', 'Contents of URL'));
        setVar('dlname', out('dl-name', 'Dictionary Value'));
      },
    );
    get('orig-file', [variable('dlurl')], false);
    act('documentpicker.save', {
      WFInput: att(out('orig-file', 'Contents of URL')),
      WFAskWhereToSave: false,
      WFFolder: {
        fileLocation: { WFFileLocationType: 'Home', relativeSubpath: 'Downloads' },
        filename: 'Downloads',
        displayName: 'Downloads',
      },
      WFFileDestinationPath: tstr(variable('dlname')),
      WFSaveFileOverwrite: true,
    });
  },
);

// 5. WebP: start job, poll up to 15 x ?wait=20 (~5 min; 60 s of video can take
// a few minutes to encode on the smallest container).
comment('4. WebP of the whole video: start the job, then poll (15 x up to 20 s).');
post(
  'webp',
  [variable('base'), '/webp'],
  dict([
    ['url', TEXT, tstr(variable('link'))],
  ]),
);
dictValue('webp-status', 'status', out('webp', 'Contents of URL'));
setVar('state', out('webp-status', 'Dictionary Value'));
ifBlock(variable('state'), IS, isText('error'), () => {
  dictValue('webp-err', 'error.code', out('webp', 'Contents of URL'));
  alertAct('cobalt → webp', 'webp step failed (start job): ', out('webp-err', 'Dictionary Value'));
  act('exit');
});
dictValue('webp-id', 'id', out('webp', 'Contents of URL'));
setVar('jobid', out('webp-id', 'Dictionary Value'));

{
  const g = group();
  act('repeat.count', { GroupingIdentifier: g, WFRepeatCount: 15, WFControlFlowMode: 0 });
  ifBlock(variable('state'), IS, isText('pending'), () => {
    get('poll', [variable('base'), '/webp/', variable('jobid'), '?wait=20'], true);
    setVar('poll', out('poll', 'Contents of URL'));
    dictValue('poll-status', 'status', out('poll', 'Contents of URL'));
    setVar('state', out('poll-status', 'Dictionary Value'));
  });
  act('repeat.count', { GroupingIdentifier: g, WFControlFlowMode: 2, UUID: uuid(`${g}-end`) });
}

// 6. Result.
comment('5. Result: copy the webp link, or show which step failed.');
ifBlock(
  variable('state'),
  IS,
  isText('success'),
  () => {
    dictValue('webp-url', 'url', variable('poll'));
    act('setclipboard', { WFInput: att(out('webp-url', 'Dictionary Value')) });
    notify('webp link copied', out('webp-url', 'Dictionary Value'));
  },
  () => {
    ifBlock(
      variable('state'),
      IS,
      isText('error'),
      () => {
        dictValue('poll-err', 'error.code', variable('poll'));
        alertAct('cobalt → webp', 'webp step failed (polling): ', out('poll-err', 'Dictionary Value'));
      },
      () => {
        alertAct('cobalt → webp', 'webp step timed out: job ', variable('jobid'), ' is still pending. Try again later.');
      },
    );
  },
);

// -------------------------------------------------------------- workflow ---

sc.finish({
  kind: 'webp',
  keyAction,
  keyQuestion: KEY_QUESTION,
  workflow: {
    WFWorkflowClientVersion: '4018.0.4',
    WFWorkflowMinimumClientVersion: 900,
    WFWorkflowMinimumClientVersionString: '900',
    WFWorkflowIcon: {
      WFWorkflowIconStartColor: -2873601, // green (Apple's Gallery value)
      WFWorkflowIconGlyphNumber: 59733, // filmstrip
    },
    WFWorkflowTypes: ['ActionExtension', 'MenuBar'],
    WFQuickActionSurfaces: [],
    WFWorkflowHasShortcutInputVariables: true,
    WFWorkflowHasOutputFallback: false,
    WFWorkflowOutputContentItemClasses: [],
    WFWorkflowInputContentItemClasses: [
      'WFArticleContentItem',
      'WFRichTextContentItem',
      'WFSafariWebPageContentItem',
      'WFStringContentItem',
      'WFURLContentItem',
    ],
    WFWorkflowNoInputBehavior: { Name: 'WFWorkflowNoInputBehaviorGetClipboard', Parameters: {} },
  },
});
