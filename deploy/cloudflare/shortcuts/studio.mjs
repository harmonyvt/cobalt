#!/usr/bin/env node
// Generates the "cobalt studio" macOS Shortcut for the private cobalt instance.
//
//   node deploy/cloudflare/shortcuts/studio.mjs
//
// Writes cobalt-studio.unsigned.shortcut, verifies it (verify.mjs studio), signs
// it into cobalt-studio.shortcut. Same personal-build mode as build.mjs
// (COBALT_SHORTCUT_KEY_FILE + COBALT_SHORTCUT_OUT; see README.md).
//
// Flow (deploy/cloudflare/STUDIO-CONTRACT.md): send the share input + clipboard
// to POST /studio, and on {status: "success", url} open the studio page in the
// default browser and notify. Otherwise show the error code. Nothing is
// downloaded and nothing is polled: the studio page does the rest.

import { createShortcut, tstr, dict, variable, TEXT, IS, isText, att } from './lib.mjs';

const sc = createShortcut({ slug: 'cobalt-studio' });
const { out, act, ifBlock, comment, alertAct, notify, post, dictValue } = sc;

const NAME = 'cobalt studio';
const KEY_QUESTION = 'paste your cobalt api key (settings → instances → api keys)';

// ---------------------------------------------------------------- actions ---

comment(
  `${NAME}: saves the video behind a link on the cobalt instance and opens its studio page, ` +
    'where you pick up to 10 s and render animated webps. Run from the share sheet (link or page) or with a link on the clipboard.',
);
const keyAction = sc.configActions();

// One Text holds the share input and the clipboard; the API Worker takes the
// first http(s) link from it. No If / Get URLs / NoInputBehavior (README lessons).
comment('1. The link: share-sheet input first, otherwise the clipboard.');
sc.linkInput();

comment('2. Start the studio session. The API answers at once with the studio page url.');
post('studio', [variable('base'), '/studio'], dict([['url', TEXT, tstr(variable('link'))]]));
dictValue('status', 'status', out('studio', 'Contents of URL'));

comment('3. success: open the studio page and notify. Otherwise: show the error code.');
ifBlock(
  out('status', 'Dictionary Value'),
  IS,
  isText('success'),
  () => {
    dictValue('url', 'url', out('studio', 'Contents of URL'));
    // Open URLs takes its input as WFInput (an action-output attachment; Text
    // coerces to URL). Parameter name from the community action reference,
    // not yet confirmed by a run on macOS 27.
    act('openurl', { WFInput: att(out('url', 'Dictionary Value')) });
    notify(NAME, 'studio ready: ', out('url', 'Dictionary Value'));
  },
  () => {
    dictValue('err', 'error.code', out('studio', 'Contents of URL'));
    ifBlock(
      out('err', 'Dictionary Value'),
      IS,
      isText('error.studio.no_link'),
      () => {
        alertAct(NAME, out('err', 'Dictionary Value'), ': copy a link first');
      },
      () => {
        alertAct(NAME, out('err', 'Dictionary Value'));
      },
    );
  },
);

// -------------------------------------------------------------- workflow ---

sc.finish({
  kind: 'studio',
  keyAction,
  keyQuestion: KEY_QUESTION,
  workflow: {
    WFWorkflowClientVersion: '4018.0.4',
    WFWorkflowMinimumClientVersion: 900,
    WFWorkflowMinimumClientVersionString: '900',
    WFWorkflowIcon: {
      WFWorkflowIconStartColor: 463140863, // blue (Shortcuts palette), to tell it apart from cobalt → webp
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
  },
});
