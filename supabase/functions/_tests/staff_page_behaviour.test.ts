// The employee page, actually executed.
//
// ## Why this file runs the script rather than reading it
//
// Because the bug it guards was invisible to every check that had ever been
// applied to this page, and reading the source would not have caught it either.
//
// `decideButtons` built the Approve/Decline bar. It existed, it was correct, and
// its two only callers were the two error paths inside `send`. So the bar was
// built *only when a save had already failed* -- and no employee could reach a
// failed save without a button to press first. It was never built at all, and
// the review screen had no Approve button on it.
//
// Every other kind of check passed while that was true:
//
//   * the function type-checked, and the deploy succeeded
//   * `admin_page.test.ts` confirmed the HTML was a document, the script tag was
//     balanced, no credential was embedded, driver text was escaped, and the
//     two decisions were wired to distinct buttons -- all true throughout
//   * the string `decideButtons` was present in the page, because the function
//     was in the page
//   * `grep`ping for `yesBtn` found it
//
// The page was not wrong in a way you could read. It was wrong in a way you
// could only *do*.
//
// So this does the doing. It pulls the `<script>` out of the rendered page, runs
// it against a DOM stub small enough to see into, and then asks the question an
// employee asks: open a driver, is there a button I can press?
//
// The stub is deliberately not a DOM. It models only the handful of operations
// the page performs, and every assertion below is about something the stub can
// answer honestly -- which elements were attached to `body`, and what markup
// `decideButtons` produced. It is not a browser, and it does not claim to be.
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { staffPage } from '../admin-drivers/staff_page.ts';

const html = staffPage('https://project.supabase.co');

/** The page's own script, with nothing added. */
function script(): string {
  const open = html.indexOf('<script>');
  const close = html.indexOf('</script>');
  assert(open > -1 && close > open, 'the page has no script to run');
  return html.slice(open + '<script>'.length, close);
}

/** An element that records what the page did to it. */
interface El {
  tagName: string;
  className: string;
  innerHTML: string;
  dataset: Record<string, string>;
  onclick: null | (() => void);
  onkeydown: null | ((e: unknown) => void);
  disabled: boolean;
  focused: boolean;
  attrs: Record<string, string>;
  children: El[];
  parent: El | null;
  appended: number;
  removed: boolean;
  setAttribute(k: string, v: string): void;
  remove(): void;
  appendChild(c: El): El;
  insertBefore(c: El, before: El | null): El;
  focus(): void;
  insertAdjacentHTML(_where: string, _html: string): void;
  querySelectorAll(_sel: string): El[];
  querySelector(sel: string): El | null;
}

function el(tagName: string): El {
  const e: El = {
    tagName,
    className: '',
    innerHTML: '',
    dataset: {},
    onclick: null,
    onkeydown: null,
    disabled: false,
    focused: false,
    attrs: {},
    children: [],
    parent: null,
    appended: 0,
    removed: false,
    setAttribute(k, v) {
      e.attrs[k] = v;
      // The one attribute that changes behaviour on a real button. Modelling it
      // means the "is Approve offered" assertion tests markup the page chose
      // rather than a separate variable set alongside it.
      if (k === 'disabled') e.disabled = true;
    },
    remove() {
      e.removed = true;
      if (e.parent) e.parent.children = e.parent.children.filter((c) => c !== e);
    },
    appendChild(c) {
      c.parent = e;
      e.children.push(c);
      c.appended++;
      return c;
    },
    insertBefore(c) {
      return e.appendChild(c);
    },
    focus() {
      e.focused = true;
    },
    insertAdjacentHTML() {},
    querySelectorAll: () => [],
    querySelector: () => null,
  };
  return e;
}

/** What the page produced, plus a way to drive it. */
interface Harness {
  review(d: unknown): void;
  load(): void;
  send(decision: string, reason: string | null): Promise<void>;
  decideButtons(): void;
  clearButtons(): void;
  bars(): El[];
  wrap: El;
}

/**
 * Runs the page's script against the stub.
 *
 * The epilogue is appended to the *same* function body rather than kept
 * separate, because the page's functions are top-level `function`
 * declarations and `const` bindings: inside a `new Function` body they are
 * scoped to that body, so a separate evaluation could not see `review` at all.
 */
function run(): Harness {
  const wrap = el('div');
  const modal = el('div');
  const body = el('body');
  const created: El[] = [];
  const store: Record<string, string> = {};

  const document = {
    getElementById(id: string): El {
      if (id === 'wrap') return wrap;
      if (id === 'modal') return modal;
      // The page builds its buttons by assigning `innerHTML`, so the only way to
      // find one is to look for its id in the markup that was just written.
      // Searching the elements created so far is the honest version of "the
      // document can find this id", and it is what makes
      // `decideButtons`'s own `getElementById('yesBtn')` resolve.
      for (const e of created) {
        if (e.innerHTML.includes(`id="${id}"`)) return e;
      }
      return el('div');
    },
    createElement(tag: string): El {
      const e = el(tag);
      created.push(e);
      return e;
    },
    querySelectorAll(sel: string): El[] {
      // A selector list, which a real querySelectorAll accepts.
      //
      // This compared the whole string against '.decide' and returned an empty
      // list for anything else. The page clears two kinds of bottom bar in one
      // call -- the driver's Approve/Decline bar and the report's Call/Handle
      // bar -- so `clearButtons()` passed '.decide, .rbar', matched nothing and
      // silently stopped clearing anything. The bar assertions still passed,
      // because they only ever built driver bars: the harness was reporting "no
      // bars" when it meant "no bars of the kind it knows about".
      return sel
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s !== '')
        // The leading dot is part of the selector, not of the class name.
        .flatMap((s) =>
          created.filter((e) => e.className === s.replace(/^\./, '') && !e.removed)
        );
    },
    querySelector(sel: string): El | null {
      return document.querySelectorAll(sel)[0] ?? null;
    },
    body,
  };

  const globals: Record<string, unknown> = {
    document,
    sessionStorage: {
      getItem: (k: string) => store[k] ?? null,
      setItem: (k: string, v: string) => {
        store[k] = v;
      },
      removeItem: (k: string) => {
        delete store[k];
      },
    },
    location: { pathname: '/' },
    // Never resolves. The page's data calls are not what this file is about, and
    // a resolved promise would run the `list` callback on a microtask after the
    // assertions have already been made, which is the kind of thing that makes a
    // test suite lie by being racy rather than wrong.
    fetch: () => new Promise(() => {}),
    alert: () => {},
    window: { open: () => {} },
    Set,
    console,
  };

  const epilogue = `
;globalThis.__h = {
  review: review,
  load: load,
  send: send,
  decideButtons: decideButtons,
  clearButtons: clearButtons,
};`;

  // The stub globals are passed as ARGUMENTS, not assigned to `globalThis`.
  //
  // `new Function('a', 'b', body)` declares a function whose parameters are
  // named `a` and `b` -- the strings are names, not values. The first version of
  // this called `factory()` with nothing, so every stub arrived as `undefined`
  // and the page died on its first line with "cannot read properties of
  // undefined (reading 'getItem')". That is a harness bug, and the page was
  // innocent; worth separating the two, because a harness that fails for its own
  // reasons is how a real bug gets dismissed as a broken test.
  //
  // Passing rather than assigning also keeps each test's stubs to itself. On
  // `globalThis` they would leak between tests in this file, and the second test
  // would silently be asserting against the first one's state.
  const factory = new Function(
    ...Object.keys(globals),
    script() + epilogue,
  );
  factory(...Object.values(globals));

  const h = (globalThis as unknown as { __h: Omit<Harness, 'bars' | 'wrap'> }).__h;
  return {
    ...h,
    bars: () => document.querySelectorAll('.decide'),
    wrap,
  };
}

/** A driver with every required document, which is the case that must work. */
function completeDriver() {
  return {
    id: '5fa134a9-910a-4b17-9c99-8661924b54ca',
    fullName: 'Apaloo Michael Edem',
    email: 'apaloo@example.com',
    phone: '0240000000',
    vehicle: { make: 'Toyota', model: 'Corolla', plate: 'GR-1234-22', seats: 4 },
    documents: [
      'profilePhoto',
      'vehiclePhoto',
      'ghanaCardPhoto',
      'driversLicence',
      'roadWorthy',
      'insuranceSticker',
      'livenessFrame',
    ],
    submittedAt: '2026-09-30T08:13:12.000Z',
  };
}

Deno.test('opening a driver puts an Approve button on the screen', () => {
  // The whole bug, as one assertion. Before the fix this found no bar at all:
  // `review` never called `decideButtons`, and the only callers were the error
  // paths inside `send`.
  const h = run();
  h.review(completeDriver());
  assertEquals(
    h.bars().length,
    1,
    'reviewing a driver must build the decision bar, or the queue cannot be emptied',
  );
});

Deno.test('the bar has both buttons, and Approve is live when documents are complete', () => {
  const h = run();
  h.review(completeDriver());
  const bar = h.bars()[0];
  assertStringIncludes(bar.innerHTML, 'id="noBtn"');
  assertStringIncludes(bar.innerHTML, 'id="yesBtn"');
  assertStringIncludes(bar.innerHTML, '>Approve<');
  assertStringIncludes(bar.innerHTML, '>Decline<');
  assert(
    !bar.innerHTML.includes('disabled'),
    'Approve must be offered for a driver who sent all six required documents',
  );
});

Deno.test('Approve is withheld when a document is missing, and Decline is not', () => {
  const h = run();
  h.review({ ...completeDriver(), documents: ['profilePhoto', 'ghanaCardPhoto'] });
  const bar = h.bars()[0];
  assert(
    bar.innerHTML.includes('disabled'),
    'Approve must be withheld when required documents are missing -- the server '
      + 'refuses it, and a button that always fails teaches an employee the page '
      + 'is broken',
  );
  // Approve is disabled, not the whole bar. Somebody who sent four documents
  // instead of six still has to be turned away, and a driver stuck in the queue
  // forever because there was no Decline button is worse than a wrong rejection
  // with a reason attached.
  assertEquals(
    /id="noBtn"[^>]*disabled/.test(bar.innerHTML),
    false,
    'Decline must stay available: a driver with missing documents can still be '
      + 'turned away, with a reason',
  );
});

Deno.test('the bar is rebuilt, not stacked, when a save fails', () => {
  // `send` clears the bar and then rebuilds it on both error paths. Before the
  // fix `decideButtons` appended unconditionally, so a failed save left two
  // bars with the older one covering the newer.
  const h = run();
  h.review(completeDriver());
  assertEquals(h.bars().length, 1);
  h.decideButtons();
  assertEquals(h.bars().length, 1, 'a second decideButtons must replace, not stack');
  h.decideButtons();
  assertEquals(h.bars().length, 1);
});

Deno.test('the bar does not outlive the review screen', () => {
  // It is `position: fixed`, so a bar left over after a decision sits over the
  // queue under the employee's thumb, offering to approve the driver they have
  // just decided on.
  const h = run();
  h.review(completeDriver());
  assertEquals(h.bars().length, 1);
  h.load();
  assertEquals(
    h.bars().length,
    0,
    'leaving the review screen must take the decision bar with it, or it floats '
      + 'over the queue and decides on a driver who is no longer open',
  );
});

Deno.test('a stale button on the queue decides on nobody rather than throwing', async () => {
  // The symptom of the previous two bugs is a button that silently does nothing,
  // so this asserts the guard exists rather than that it produces a message.
  const h = run();
  h.load();
  // No driver is open. `current` is null, and `d.id` on null throws inside an
  // async function -- which the browser reports as an unhandled rejection and
  // the employee sees as nothing happening at all.
  await h.send('approve', null);
  assertEquals(h.bars().length, 0);
});

Deno.test('the page still holds no credential after any of this', () => {
  // The stub is elaborate; the one thing that must not have been lost is that
  // none of it turned into an embedded key.
  assert(!/service_role/i.test(html));
  assert(!html.includes('eyJ'));
  assertStringIncludes(html, "action: 'staffsignin'");
});
