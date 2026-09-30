// End-to-end check on the built artifact.
//
// Reads the index.html the user uploads to their host, pulls the script out of
// it, runs it against a DOM stub, and asks the employee question: open a
// driver, is there an Approve button?
//
// This is not the same as the test suite. The suite runs `staffPage()` -- the
// generator. This runs the *file on disk*, which is what a browser will load and
// what every previous check missed: the page can be generated correctly and the
// artifact can still be wrong, because the two are produced by different steps
// (a fetch, a write, a re-upload) and only the second one is what employees see.
const ARTIFACT = Deno.args[0] ??
  'C:/Windows/System32/meetngo/admin-page/index.html';

const html = await Deno.readTextFile(ARTIFACT);

const open = html.indexOf('<script>');
const close = html.indexOf('</script>');
if (open < 0 || close < open) {
  console.log('FAIL: the artifact has no script to run');
  Deno.exit(1);
}
const script = html.slice(open + '<script>'.length, close);

interface El {
  className: string;
  innerHTML: string;
  removed: boolean;
  setAttribute(k: string, _v: string): void;
  remove(): void;
  appendChild(c: El): El;
  insertBefore(c: El): El;
  focus(): void;
  insertAdjacentHTML(): void;
  querySelectorAll(): El[];
  querySelector(): null;
}
const el = (className = ''): El => ({
  className,
  innerHTML: '',
  removed: false,
  setAttribute() {},
  remove() {
    this.removed = true;
  },
  appendChild(c) {
    return c;
  },
  insertBefore(c) {
    return c;
  },
  focus() {},
  insertAdjacentHTML() {},
  querySelectorAll: () => [],
  querySelector: () => null,
});

const created: El[] = [];
const store: Record<string, string> = {};
const document = {
  getElementById: (id: string) =>
    created.find((e) => e.innerHTML.includes(`id="${id}"`)) ?? el(),
  createElement: () => {
    const e = el();
    created.push(e);
    return e;
  },
  querySelectorAll: (sel: string) =>
    sel === '.decide'
      ? created.filter((e) => e.className === 'decide' && !e.removed)
      : [],
  querySelector: (sel: string) => document.querySelectorAll(sel)[0] ?? null,
  body: el(),
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
  fetch: () => new Promise(() => {}),
  alert: () => {},
  window: { open: () => {} },
  Set,
  console,
};

const factory = new Function(
  ...Object.keys(globals),
  script + '\n;globalThis.__review = review;',
);
factory(...Object.values(globals));

const review = (globalThis as unknown as {
  __review: (d: unknown) => void;
}).__review;

review({
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
});

const bars = document.querySelectorAll('.decide');
const bar = bars[0];
const barHtml = bar ? bar.innerHTML : '';

const checks: Array<[string, boolean]> = [
  ['a decision bar was built', bars.length === 1],
  ['it carries a Decline button', barHtml.includes('id="noBtn"')],
  ['it carries an Approve button', barHtml.includes('id="yesBtn"')],
  ['Approve is enabled for a complete driver', !barHtml.includes('disabled')],
  ['the page holds no JWT', !html.includes('eyJ')],
  ['the page holds no service role key', !/service_role/i.test(html)],
];

console.log(`artifact: ${ARTIFACT} (${html.length} bytes)`);
let bad = 0;
for (const [label, ok] of checks) {
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${label}`);
  if (!ok) bad++;
}
console.log(bad === 0 ? '\nARTIFACT OK' : `\n${bad} FAILED`);
Deno.exit(bad === 0 ? 0 : 1);
