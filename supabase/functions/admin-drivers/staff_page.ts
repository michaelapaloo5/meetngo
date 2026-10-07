import { DECLINE_REASONS } from './staff.ts';
import { DOCUMENT_LABELS, REQUIRED_DOCUMENTS } from './handler.ts';

/**
 * The page an employee uses to approve drivers.
 *
 * ## Who this is for
 *
 * Somebody who has been asked to check a folder of photographs and press a
 * button, and who is not going to read this file, has never used the Supabase
 * dashboard, and will be doing it on a phone. Everything below follows from
 * that.
 *
 * The previous version of this page signed people in with a Supabase email and
 * password and rendered a dense table. Both halves were wrong for that person.
 * Signing in meant the founder had to create a Supabase user in the Dashboard,
 * set a role in the SQL editor, and hand an employee a login for an account they
 * would never otherwise use -- and the deploy notes said a driver's own account
 * was fine, which throws away the only thing an approval log has to be. The
 * layout was a desktop table with six document links per row.
 *
 * ## The decisions this page supports
 *
 *   * **One driver at a time.** A list of seventeen cards is a queue nobody
 *     works through; one application with the judgement next to the button is
 *     one they can finish.
 *   * **The comparison, side by side.** What an employee is actually being asked
 *     is "is this the same person in these photographs". The face check photo,
 *     the profile picture and the licence are therefore shown together and
 *     large, because those are the three that answer it. Everything else is
 *     below and collapsed.
 *   * **Two buttons, both large.** Approve and Decline, full width, at the
 *     bottom of the screen where a thumb is.
 *   * **A decline has to say why.** Not a nice-to-have. A driver told "no" with
 *     no reason cannot do anything about it, and a rejection nobody can act on
 *     is worse than a slow one. The reason is chosen from a list and lands in
 *     `kyc_decisions.reason`.
 *
 * ## What it deliberately does not do
 *
 * It does not verify a face, and it does not check that a Ghana Card photograph
 * belongs to the same person as the licence. Both of those need a model, and
 * both are stated as absent rather than quietly passed -- the same position the
 * app's own checklist takes.
 */
export const staffPage = (supabaseUrl: string): string => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Driver approvals</title>
<style>
  :root {
    --brand:#F5B301; --ink:#111827; --sub:#5B6472; --line:#E5E7EB;
    --bad:#C62828; --good:#1B7F3B; --page:#F4F5F7;
  }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  body {
    margin:0; background:var(--page); color:var(--ink);
    font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
    font-size:16px; line-height:1.45;
    /* Employees are one-handed, often in a car park. Nothing is smaller than a
       fingertip target and nothing scrolls sideways. */
    overscroll-behavior-y:contain;
  }
  .wrap { max-width:640px; margin:0 auto; padding:0 14px 140px; }
  h1 { font-size:20px; margin:0; }
  h2 { font-size:17px; margin:0 0 4px; }
  .bar {
    position:sticky; top:0; z-index:5; background:var(--page);
    padding:12px 0 10px; border-bottom:1px solid var(--line);
    display:flex; align-items:center; gap:10px; margin:0 -14px 0; padding-left:14px; padding-right:14px;
  }
  .bar .who { margin-left:auto; font-size:13px; color:var(--sub); text-align:right; }
  .card { background:#fff; border:1px solid var(--line); border-radius:14px; padding:16px; margin:14px 0; }
  .row { display:flex; gap:10px; }
  .grow { flex:1; min-width:0; }
  .sub { color:var(--sub); font-size:14px; }
  .label { font-size:11px; text-transform:uppercase; letter-spacing:.07em; color:var(--sub); }
  .value { font-weight:600; overflow-wrap:anywhere; }

  /* The comparison. Three photographs side by side, large enough to actually
     look at a face, because this is the whole judgement. */
  .compare { display:grid; grid-template-columns:repeat(3,1fr); gap:8px; margin:10px 0 4px; }
  .shot { background:#000; border-radius:10px; overflow:hidden; aspect-ratio:3/4; position:relative; }
  .shot img { width:100%; height:100%; object-fit:cover; display:block; }
  .shot .cap {
    position:absolute; left:0; right:0; bottom:0; padding:4px 5px;
    background:rgba(0,0,0,.62); color:#fff; font-size:11px; line-height:1.2;
  }
  .shot.empty { background:#F3F4F6; display:flex; align-items:center; justify-content:center; }
  .shot.empty .cap { position:static; background:none; color:var(--sub); text-align:center; padding:8px; }

  /* The other documents: present, reachable, and not competing with the
     comparison above them. */
  details { border-top:1px solid var(--line); margin-top:12px; padding-top:10px; }
  summary { cursor:pointer; font-weight:600; font-size:15px; }
  .doc { display:flex; align-items:center; gap:8px; padding:9px 0; border-bottom:1px solid var(--line); }
  .doc:last-child { border-bottom:0; }
  .doc .n { flex:1; font-size:15px; }
  .doc .miss { color:var(--bad); font-size:13px; font-weight:600; }
  .doc .opt { color:var(--sub); font-size:13px; }
  .view {
    background:#fff; border:1px solid var(--line); border-radius:8px;
    padding:8px 12px; font:inherit; font-size:14px; min-height:40px;
  }

  /* The two buttons. Fixed to the bottom so the decision is always in the same
     place under the thumb, and never scrolled off below a long photo. */
  .decide {
    position:fixed; left:0; right:0; bottom:0; z-index:6;
    background:#fff; border-top:1px solid var(--line);
    padding:10px 14px calc(10px + env(safe-area-inset-bottom));
    display:flex; gap:10px; max-width:640px; margin:0 auto;
  }
  .decide button {
    flex:1; font:inherit; font-weight:700; font-size:17px;
    border:0; border-radius:12px; padding:15px 8px; min-height:56px; cursor:pointer;
  }
  .no { background:#fff; color:var(--bad); border:2px solid var(--bad); }
  .yes { background:var(--good); color:#fff; }
  button:disabled { opacity:.5; cursor:default; }
  button:focus-visible, summary:focus-visible, .view:focus-visible {
    outline:3px solid #1D4ED8; outline-offset:2px;
  }

  /* Queue rows. */
  .q { display:flex; align-items:center; gap:12px; padding:14px 0; border-bottom:1px solid var(--line); width:100%; background:none; border-left:0; border-right:0; border-top:0; font:inherit; text-align:left; cursor:pointer; }
  .q:last-child { border-bottom:0; }
  .q .who { font-weight:600; }
  .q .ago { color:var(--sub); font-size:13px; }
  /* The "what is this number" half of the queue row. Quieter than the age
     itself, which is the number being looked at. */
  .ago-when { color:var(--sub); opacity:.75; }

  /* The Ghana Card block. Two columns so a driver with a long name and a long
     plate do not push the photographs off the bottom of a phone screen, which
     is the thing this screen is for. */
  .cardgrid { display:grid; grid-template-columns:1fr 1fr; gap:10px 14px; margin-top:8px; }
  .crow { min-width:0; }
  .clabel { font-size:11px; text-transform:uppercase; letter-spacing:.07em; color:var(--sub); }
  .cvalue { font-weight:600; overflow-wrap:anywhere; }
  @media (max-width:380px) { .cardgrid { grid-template-columns:1fr; } }
  .badge { background:#FFF4D6; border:1px solid #F0D89B; color:#7A5A00; border-radius:999px; padding:3px 9px; font-size:12px; font-weight:600; white-space:nowrap; }

  .err { background:#FDECEC; border:1px solid #F3C2C2; color:#8A1A1A; border-radius:10px; padding:11px 13px; margin:12px 0; font-size:15px; }
  .note { background:#EEF3FF; border:1px solid #C7D7F7; border-radius:10px; padding:11px 13px; font-size:14px; }
  .empty { text-align:center; padding:44px 18px; color:var(--sub); }
  input, select {
    font:inherit; width:100%; padding:13px 12px; border:1px solid var(--line);
    border-radius:10px; background:#fff; min-height:50px;
  }
  label { display:block; font-size:14px; font-weight:600; margin:14px 0 6px; }
  .btn { font:inherit; font-weight:700; font-size:17px; border:0; border-radius:12px; padding:15px; width:100%; min-height:56px; margin-top:18px; background:var(--brand); color:var(--ink); cursor:pointer; }
  .link { background:none; border:0; font:inherit; color:var(--sub); text-decoration:underline; padding:10px; min-height:44px; }
  .sheet { position:fixed; inset:0; background:rgba(0,0,0,.55); z-index:9; display:flex; align-items:flex-end; }
  .sheet .panel { background:#fff; width:100%; max-width:640px; margin:0 auto; border-radius:16px 16px 0 0; padding:18px 16px calc(18px + env(safe-area-inset-bottom)); }
  .reason { display:flex; align-items:center; gap:12px; padding:13px 4px; border-bottom:1px solid var(--line); font-size:16px; }
  .reason input { width:22px; height:22px; min-height:0; flex:none; }
  .hide { display:none !important; }

  /* Two jobs, one page. Drivers waiting to be approved and riders who have
     complained are different queues with different urgencies, and the employee
     needs to be able to see whether either is non-empty without opening both.
     The count sits on the tab rather than only inside the list for that reason:
     the whole point is knowing from the queue you are already looking at. */
  .tabs { display:flex; gap:8px; padding:12px 0 4px; }
  .tab {
    flex:1; font:inherit; font-weight:600; font-size:15px; min-height:48px;
    border:1px solid var(--line); border-radius:12px; background:#fff;
    color:var(--sub); cursor:pointer; display:flex; align-items:center;
    justify-content:center; gap:7px; padding:0 8px;
  }
  .tab.on { background:var(--ink); color:#fff; border-color:var(--ink); }
  .pip {
    background:#E5E7EB; color:var(--ink); border-radius:999px;
    padding:1px 8px; font-size:13px; font-weight:700;
  }
  .tab.on .pip { background:#fff; color:var(--ink); }
  /* Red only when there is something open. A count that is always coloured
     trains people to stop looking at it. */
  .pip.alert { background:var(--bad); color:#fff; }
  .tab.on .pip.alert { background:#fff; color:var(--bad); }

  /* The rider's own words. Bigger than anything else on the screen, because it
     is the reason the screen exists -- the rest is context for it. */
  .say { font-size:19px; font-weight:700; line-height:1.3; overflow-wrap:anywhere; }
  .said { margin-top:8px; font-size:16px; line-height:1.5; white-space:pre-wrap; overflow-wrap:anywhere; }
  .leg { display:flex; gap:8px; align-items:flex-start; padding:9px 0; border-bottom:1px solid var(--line); }
  .leg:last-child { border-bottom:0; }
  .leg .n { flex:1; min-width:0; }
  .arrow { color:var(--sub); padding:0 2px; }
  .done { background:#E8F5EC; border-color:#B7DFC4; color:#14622F; }
  .rbar {
    position:fixed; left:0; right:0; bottom:0; z-index:6;
    background:#fff; border-top:1px solid var(--line);
    padding:10px 14px calc(10px + env(safe-area-inset-bottom));
    display:flex; gap:10px; max-width:640px; margin:0 auto;
  }
  .rbar button {
    flex:1; font:inherit; font-weight:700; font-size:16px; border:0;
    border-radius:12px; padding:14px 6px; min-height:56px; cursor:pointer;
  }
  .rbar .call { background:#fff; color:var(--ink); border:2px solid var(--ink); }
  .rbar .go { background:var(--brand); color:var(--ink); }
  .rbar .undo { background:#fff; color:var(--bad); border:2px solid var(--bad); }
</style>
</head>
<body>
<div class="wrap" id="wrap"></div>
<div id="modal"></div>
<script>
'use strict';

const REASONS = ${JSON.stringify(DECLINE_REASONS)};
const LABELS = ${JSON.stringify(DOCUMENT_LABELS)};
const ALL = ${JSON.stringify(Object.keys(DOCUMENT_LABELS))};
const REQUIRED = ${JSON.stringify(REQUIRED_DOCUMENTS)};

// sessionStorage, not localStorage. A shared phone -- and an office phone is a
// shared phone -- should not still be signed in tomorrow morning. The cost is
// re-entering a four-digit PIN when the tab is closed, which is the right trade
// for a tool that approves people to take paying passengers.
let token = sessionStorage.getItem('mng_staff') || '';
let me = sessionStorage.getItem('mng_staff_name') || '';

const wrap = document.getElementById('wrap');
const modal = document.getElementById('modal');

// Where the data calls go.
//
// Absolute, not \`location.pathname\`, because this page is served as a static
// file from Supabase Storage rather than from the edge function. It used to be
// served by the function, which meant the gateway was in charge of its
// Content-Type -- and the gateway rewrites that to \`text/plain\` no matter how the
// function sets it, so a browser displayed the markup as source instead of
// rendering it. Verified four ways: capitalised \`Content-Type\`, both cases at
// once, and lowercase alone. All three came back \`text/plain\`.
//
// Storage serves a static file with the right Content-Type and takes the gateway
// out of the path, so the API is named here rather than inferred. Cross-origin
// is fine: the function sends \`Access-Control-Allow-Origin: *\` and answers
// OPTIONS.
const API = '${supabaseUrl}/functions/v1/admin-drivers';

function esc(v) {
  return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

async function call(body) {
  try {
    const res = await fetch(API, {
      method: 'POST',
      headers: Object.assign(
        { 'Content-Type': 'application/json' },
        token ? { Authorization: 'Bearer ' + token } : {},
      ),
      body: JSON.stringify(body),
    });
    let data = {};
    try { data = await res.json(); } catch (e) { /* not json */ }
    return { status: res.status, data: data };
  } catch (e) {
    // A dropped connection, not a refusal. The two must not look the same: one
    // is "try again" and the other is "you are not allowed in", and telling
    // somebody they are signed out because the network blipped loses their
    // place in the queue.
    return { status: 0, data: { error: 'No connection. Check your network and try again.' } };
  }
}

function ago(iso) {
  const then = new Date(iso).getTime();
  if (!then) return '';
  const mins = Math.max(0, Math.round((Date.now() - then) / 60000));
  if (mins < 1) return 'just now';
  if (mins < 60) return mins + ' min ago';
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return hrs + ' hr' + (hrs === 1 ? '' : 's') + ' ago';
  const days = Math.round(hrs / 24);
  return days + ' day' + (days === 1 ? '' : 's') + ' ago';
}

function signedOut() {
  token = '';
  me = '';
  sessionStorage.removeItem('mng_staff');
  sessionStorage.removeItem('mng_staff_name');
}

// ---------------------------------------------------------------- sign in

function signIn(message) {
  // Same reason as load: the bar is fixed to the bottom of the viewport and
  // would otherwise sit over the sign-in form, offering to approve a driver to
  // somebody who had just been signed out.
  clearButtons();
  current = null;
  canApproveCurrent = false;

  wrap.innerHTML =
    '<div class="bar"><h1>Driver approvals</h1></div>' +
    '<div class="card">' +
    (message ? '<div class="err">' + esc(message) + '</div>' : '') +
    '<div class="note">Ask your supervisor for your name and 4-digit PIN.</div>' +
    '<label for="nm">Your name</label>' +
    '<input id="nm" autocomplete="name" enterkeyhint="next">' +
    '<label for="pn">Your PIN</label>' +
    '<input id="pn" type="password" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="off">' +
    '<button class="btn" id="go">Start</button>' +
    '</div>';

  const nm = document.getElementById('nm');
  const pn = document.getElementById('pn');
  nm.focus();

  async function submit() {
    const button = document.getElementById('go');
    button.disabled = true;
    const r = await call({
      action: 'staffsignin',
      name: nm.value,
      pin: pn.value,
    });
    if (r.status !== 200) {
      button.disabled = false;
      signIn(r.data.error || 'That did not work.');
      document.getElementById('nm').value = nm.value;
      document.getElementById('pn').value = '';
      document.getElementById('pn').focus();
      return;
    }
    token = r.data.token;
    me = r.data.name;
    sessionStorage.setItem('mng_staff', token);
    sessionStorage.setItem('mng_staff_name', me);
    load();
  }

  document.getElementById('go').onclick = submit;
  pn.onkeydown = function (e) { if (e.key === 'Enter') submit(); };
}

// ------------------------------------------------------------------- tabs

// Which of the two queues is on screen, and how many are open in the other one.
//
// Both counts live here rather than inside either screen, because a tab that can
// only tell you what is on the tab you are already looking at is not a tab, it
// is a link. An employee who has a complaint open and a driver waiting should be
// able to see that from either side without switching first.
let tab = 'drivers';
let openReports = 0;
let contactNote = '';

function tabsHtml() {
  const drivers = queue.length;
  // Wrapped in a div with an id so the counts can be refreshed by replacing one
  // element.
  //
  // It was done the other way round first -- rendering the tabs to a string and
  // pulling one button back out of it with a regular expression -- and that is
  // how the page stopped running at all. This whole file is a TypeScript template
  // literal, so an escaped forward slash collapses to a bare one on the way out,
  // and /...<\/button>/ became /...?</button>/: the slash in the closing tag
  // ended the regex and "button>" was read as its flags. Every screen died on
  // load with "Invalid regular expression flags". Replaced with an element swap,
  // which cannot be broken by a second layer of string escaping.
  return '<div id="tabs"><div class="tabs" role="tablist">' +
    '<button class="tab' + (tab === 'drivers' ? ' on' : '') + '" id="tabDrivers" role="tab"' +
    ' aria-selected="' + (tab === 'drivers') + '">Drivers' +
    (drivers ? ' <span class="pip' + (tab === 'drivers' ? '' : ' alert') + '">' + drivers + '</span>' : '') +
    '</button>' +
    '<button class="tab' + (tab === 'reports' ? ' on' : '') + '" id="tabReports" role="tab"' +
    ' aria-selected="' + (tab === 'reports') + '">Reports' +
    (openReports ? ' <span class="pip' + (tab === 'reports' ? '' : ' alert') + '">' + openReports + '</span>' : '') +
    '</button></div></div>';
}

function refreshTabs() {
  const box = document.getElementById('tabs');
  if (!box) return;
  box.outerHTML = tabsHtml();
  wireTabs();
}

function wireTabs() {
  const d = document.getElementById('tabDrivers');
  const r = document.getElementById('tabReports');
  if (d) d.onclick = function () { goTab('drivers'); };
  if (r) r.onclick = function () { goTab('reports'); };
}

function goTab(next) {
  if (tab === next) return;
  tab = next;
  if (tab === 'reports') reportsScreen();
  else load();
}

// The header and the sign-out button, in one place.
//
// It is here because three screens need it and the first two each had their own
// copy, which is how the sign-out button ended up with two different element ids
// -- "out" on one screen and "out2" on another -- and a third screen with none
// at all.
function chrome(title) {
  return '<div class="bar"><h1>' + esc(title) + '</h1>' +
    '<div class="who">' + esc(me) +
    '<br><button class="link" id="out">Sign out</button></div></div>';
}

function wireChrome() {
  wireTabs();
  const out = document.getElementById('out');
  if (!out) return;
  out.onclick = async function () {
    await call({ action: 'staffsignout' });
    signedOut();
    signIn();
  };
}

// ------------------------------------------------------------------ queue

let queue = [];

function load() {
  // Leaving the queue and the review screen, so the decision bar and the driver
  // it belongs to both go. Without this the bar is position: fixed and simply
  // outlives the screen: approve somebody, land back on the queue, and the
  // Approve button for the driver you just approved is still under your thumb.
  // Tapping it decided on a driver who was no longer open, which threw on a
  // null and looked like a button that had stopped working.
  clearButtons();
  current = null;
  currentReport = null;
  canApproveCurrent = false;
  tab = 'drivers';

  wrap.innerHTML = chrome('Driver approvals') + tabsHtml() +
    '<div class="card"><h2>Waiting</h2><div class="sub" id="count">Loading...</div></div>' +
    mine();
  wireChrome();

  // Fetched straight away rather than when the disclosure is opened: an
  // employee who opens it to check they have not already done somebody twice
  // should not then wait on the network.
  loadMine();

  call({ action: 'list' }).then(function (r) {
    if (r.status === 401) { signedOut(); signIn(); return; }
    if (r.status !== 200) {
      wrap.innerHTML =
        chrome('Driver approvals') +
        '<div class="card"><div class="err">' +
        esc(r.data.error || 'Could not load the list.') + '</div>' +
        '<button class="btn" id="retry">Try again</button></div>';
      document.getElementById('retry').onclick = load;
      return;
    }
    queue = r.data.drivers || [];
    renderQueue();
  });
  // The reports count, for the tab. A failure here must not stop the queue
  // loading, so it is not awaited and not checked: the tab simply shows no
  // number, which is a smaller wrong than an empty queue.
  call({ action: 'listreports' }).then(function (r) {
    if (r.status !== 200) return;
    reports = r.data.reports || [];
    openReports = reports.filter(function (x) { return x.open; }).length;
    refreshTabs();
  });
}

function renderQueue() {
  const card = document.getElementById('count');
  if (card === null) { load(); return; }
  if (queue.length === 0) {
    wrap.innerHTML =
      chrome('Driver approvals') + tabsHtml() +
      '<div class="empty">Nothing waiting.<br>New applications will appear here.</div>' +
      mine();
    wireChrome();
    loadMine();
    return;
  }
  card.parentElement.innerHTML =
    '<h2>Waiting: ' + queue.length + '</h2>' +
    '<div class="sub">Tap one to review it.</div>' +
    queue.map(function (d) {
      // Age on the queue row, not only on the review screen. It is the fastest
      // thing to check and the one that most often catches a card belonging to
      // somebody else -- so it is worth having while choosing which application
      // to open, and it costs one span.
      const age = (d.cardAge === null || d.cardAge === undefined)
        ? ''
        : ' &middot; ' + esc(String(d.cardAge)) + ' yrs';
      return '<button class="q" data-id="' + esc(d.id) + '">' +
        '<div class="grow"><div class="who">' + esc(d.fullName || '(no name)') + '</div>' +
        '<div class="ago">' + esc(ago(d.submittedAt)) +
        // Says what the number is, because it used to be something else and an
        // employee has no way to know which. It was the account creation date,
        // so a driver who signed up on Monday and sent everything on Wednesday
        // read as "2 days ago" next to six photographs taken that morning --
        // which is not a description of the evidence being judged.
        ' <span class="ago-when">last document</span>' + age + ' &middot; ' +
        esc((d.vehicle ? d.vehicle.make + ' ' + d.vehicle.model : 'no vehicle')) +
        '</div></div>' +
        '<span class="badge">Review</span></button>';
    }).join('');
  wireQueue();
}

function wireQueue() {
  wrap.querySelectorAll('.q').forEach(function (b) {
    b.onclick = function () {
      const d = queue.find(function (x) { return x.id === b.dataset.id; });
      if (d) review(d);
    };
  });
}

// ----------------------------------------------------------------- review

let current = null;

/// One label-and-value row of the Ghana Card block.
///
/// A row rather than a sentence, because these are being read against a
/// photograph of the same card one field at a time. A blank value says "not
/// given" rather than rendering as nothing: an empty row reads as a bug, and a
/// driver who thinks the app lost their date of birth will retype the whole
/// card.
function cardLine(label, value) {
  const shown = (value === null || value === undefined || String(value).trim() === '')
    ? 'not given'
    : String(value);
  return '<div class="crow"><div class="clabel">' + esc(label) + '</div>' +
    '<div class="cvalue">' + shown + '</div></div>';
}

// Whether the open driver has every required document, so Approve is offered.
// Set by review, read by decideButtons, cleared by load.
//
// Declared beside current rather than inside decideButtons because these two
// are one fact: they are both about *the driver on screen right now*, and either
// one being stale is the same bug. load clears both together.
let canApproveCurrent = false;

function review(d) {
  current = d;
  currentReport = null;
  contactNote = '';
  const have = new Set(d.documents || []);
  const missingRequired = REQUIRED.filter(function (k) { return !have.has(k); });
  canApproveCurrent = missingRequired.length === 0;

  // The three photographs that answer "is this the same person". Anything else
  // is below, folded away, because an employee should be looking at faces.
  function shot(kind, caption) {
    if (have.has(kind)) {
      return '<div class="shot"><img alt="' + esc(caption) + '" ' +
        'data-kind="' + esc(kind) + '" data-id="' + esc(d.id) + '" src="">' +
        '<div class="cap">' + esc(caption) + '</div></div>';
    }
    return '<div class="shot empty"><div class="cap">' + esc(caption) + '<br>not sent</div></div>';
  }

  const others = ALL.filter(function (k) {
    return k !== 'profilePhoto' && k !== 'driversLicence' && k !== 'livenessFrame';
  });

  wrap.innerHTML =
    '<div class="bar"><button class="link" id="back">&larr; Queue</button>' +
    '<div class="who">' + esc(me) + '</div></div>' +
    '<div class="card">' +
    '<h2>' + esc(d.fullName || '(no name)') + '</h2>' +
    '<div class="sub">' + esc(d.email) +
    (d.phone ? ' &middot; ' + esc(d.phone) : '') + '</div>' +
    (d.vehicle
      ? '<div class="sub">' + esc(d.vehicle.make + ' ' + d.vehicle.model) +
        ' &middot; ' + esc(d.vehicle.plate) + ' &middot; ' + esc(String(d.vehicle.seats)) + ' seats</div>'
      : '<div class="sub">No vehicle on file</div>') +

    // When the evidence arrived. The queue row shows it too, but this is the
    // screen where somebody actually looks at a Ghana Card photograph and
    // decides whether to trust it, and a card photo that is three weeks old is a
    // different judgement from one taken this morning. The number has to be in
    // front of them at the moment they make it, not one tap back.
    '<div class="sub" style="margin-top:12px">Last document sent ' +
    esc(ago(d.submittedAt)) + '.</div>' +

    '<div class="label" style="margin-top:16px">Ghana Card</div>' +
    '<div class="sub">What the driver typed. Check it against the card photo ' +
    'below.</div>' +
    '<div class="cardgrid">' +
    cardLine('Name on card', d.fullName) +
    cardLine('Date of birth', d.cardDob) +
    // The age sits beside the date rather than instead of it, because it is the
    // fastest thing to check against a face and the one that most often catches
    // a card belonging to somebody else.
    cardLine('Age', d.cardAge === null || d.cardAge === undefined
      ? 'not given'
      : String(d.cardAge)) +
    cardLine('Sex', d.cardSex) +
    cardLine('Nationality', d.cardNationality) +
    // Four digits presented as a card number is something an employee could
    // check and find wrong, or worse, not check -- so a partial one says so.
    cardLine('Card number', d.cardNumber
      ? (d.cardNumberIsPartial
        ? esc(d.cardNumber) + ' &middot; first four digits only'
        : esc(d.cardNumber))
      : 'not given') +
    cardLine('Date of issue', d.cardIssued) +
    cardLine('Expires', d.cardExpiry) +
    '</div>' +

    '<div class="label" style="margin-top:16px">Same person?</div>' +
    '<div class="sub">Compare the three. If they are not the same person, decline.</div>' +
    '<div class="compare">' +
    shot('profilePhoto', 'Profile') +
    shot('livenessFrame', 'Face check') +
    shot('driversLicence', 'Licence') +
    '</div>' +

    (missingRequired.length
      ? '<div class="err">' + missingRequired.length +
        ' required document' + (missingRequired.length === 1 ? ' is' : 's are') +
        ' missing. You cannot approve until ' +
        (missingRequired.length === 1 ? 'it is' : 'they are') + ' sent.</div>'
      : '') +

    '<details><summary>Other documents (' + (others.filter(function (k) { return have.has(k); }).length) +
    ')</summary><div style="margin-top:6px">' +
    others.map(function (k) {
      const present = have.has(k);
      const req = REQUIRED.indexOf(k) >= 0;
      return '<div class="doc"><span class="n">' + esc(LABELS[k] || k) + '</span>' +
        (present
          ? '<button class="view" data-kind="' + esc(k) + '">View</button>'
          : '<span class="' + (req ? 'miss' : 'opt') + '">' +
            (req ? 'not sent' : 'optional') + '</span>') +
        '</div>';
    }).join('') +
    '</div></details>' +

    '<details style="margin-top:8px"><summary>What this check cannot do</summary>' +
    '<div class="sub" style="margin-top:6px">' +
    'It does not compare faces automatically, and it does not check that the ' +
    'Ghana Card photo belongs to the same person as the licence. That is what ' +
    'your eyes are for on this screen.</div></details>' +
    '</div>';

  document.getElementById('back').onclick = function () { current = null; load(); };
  loadPhotos();
  wireViews();

  // The bar of buttons, without which this screen is read-only and the queue
  // cannot be emptied by anybody.
  //
  // It was missing here, and that is why the page looked like it had no Approve
  // button: decideButtons existed, and both of its only two callers were the
  // error paths inside send, so the bar was built *only* when a save had
  // already failed. Nobody could reach a failure without a button to press
  // first, so it was never built at all.
  //
  // Approve is withheld while a required document is missing, which is what the
  // red message above the photos already says. Decline is always offered.
  decideButtons();
}

function loadPhotos() {
  wrap.querySelectorAll('.shot img').forEach(function (img) {
    call({ action: 'document', driverId: img.dataset.id, kind: img.dataset.kind })
      .then(function (r) {
        if (r.status === 200 && r.data.url) img.src = r.data.url;
        else img.alt = 'Could not open';
      });
  });
}

function wireViews() {
  wrap.querySelectorAll('button.view').forEach(function (b) {
    b.onclick = async function () {
      b.disabled = true;
      const r = await call({
        action: 'document',
        driverId: current.id,
        kind: b.dataset.kind,
      });
      b.disabled = false;
      if (r.status !== 200 || !r.data.url) {
        alert(r.data.error || 'That document could not be opened.');
        return;
      }
      window.open(r.data.url, '_blank', 'noopener');
    };
  });
}

// --------------------------------------------------------------- decisions

let busy = false;

// Builds the fixed Approve/Decline bar.
//
// Whether Approve is offered is read from canApproveCurrent rather than passed
// in, because three places have to agree: review decides it, and send's two
// error paths have to rebuild the bar with the same answer. A parameter would
// have meant those two calls passing something, and one of them would have passed
// nothing -- which is falsy, and so would have disabled Approve on the one screen
// where the driver has every document and the save merely failed. That is a
// mistake this shape actively invites, so the flag lives in one place instead.
function decideButtons() {
  // Remove any bar already on the page before making another. Called from
  // review and again from both error paths in send, and without this a
  // failed save left two bars stacked on top of each other, the older one
  // covering the newer.
  clearButtons();

  const bar = document.createElement('div');
  bar.className = 'decide';
  bar.innerHTML =
    '<button class="no" id="noBtn">Decline</button>' +
    '<button class="yes" id="yesBtn"' +
    (canApproveCurrent ? '' : ' disabled') + '>Approve</button>';
  document.body.appendChild(bar);

  const no = document.getElementById('noBtn');
  const yes = document.getElementById('yesBtn');
  no.onclick = askReason;
  yes.onclick = function () { send('approve', null); };

  if (!canApproveCurrent) {
    // Declining stays available. Somebody who sent four documents instead of six
    // still has to be turned away, and a driver stuck in the queue forever
    // because there was no Decline button is a worse outcome than a wrong
    // rejection with a reason attached. Only Approve is withheld, because the
    // server refuses it anyway and a button that always fails teaches an
    // employee that this page is broken.
    yes.setAttribute(
      'title',
      'Every required document has to be sent before you can approve.',
    );
  }
}

function clearButtons() {
  // All of them, not the first, and both bars. A leftover bar is worse than no
  // bar: it is position: fixed at the bottom of the viewport, so it sits over
  // the queue after a decision, over the sign-in form after signing out, and --
  // once there were two kinds of bar -- a "Call rider" button belonging to a
  // report that had already been dealt with could sit under the thumb while
  // somebody was approving a driver.
  document.querySelectorAll('.decide, .rbar').forEach(function (bar) { bar.remove(); });
}

function askReason() {
  modal.innerHTML =
    '<div class="sheet"><div class="panel">' +
    '<h2>Why are you turning this driver away?</h2>' +
    '<div class="sub" style="margin-bottom:10px">They will be shown this, so they can fix it.</div>' +
    Object.keys(REASONS).map(function (k) {
      return '<label class="reason"><input type="radio" name="why" value="' + esc(k) + '">' +
        '<span>' + esc(REASONS[k]) + '</span></label>';
    }).join('') +
    '<div class="row" style="margin-top:16px">' +
    '<button class="view" id="cancelWhy" style="flex:1;min-height:50px">Cancel</button>' +
    '<button class="btn" id="sendWhy" style="flex:2;margin:0">Decline driver</button></div>' +
    '</div></div>';

  document.getElementById('cancelWhy').onclick = function () { modal.innerHTML = ''; };
  document.getElementById('sendWhy').onclick = function () {
    const picked = document.querySelector('input[name=why]:checked');
    if (!picked) {
      // Said here rather than sent as an empty rejection, because a rejection
      // with no reason is the one outcome that helps nobody.
      alert('Choose a reason so the driver knows what to fix.');
      return;
    }
    modal.innerHTML = '';
    send('reject', picked.value);
  };
}

async function send(decision, reason) {
  if (busy) return;

  // Nothing is open. A leftover button from a driver who has already been
  // decided, pressed on the queue, would otherwise reach d.id on a null and
  // throw inside an async function, which surfaces as a button that silently
  // does nothing -- the same symptom as the bug that made this bar unreachable
  // in the first place, so it is worth closing explicitly rather than waiting
  // to see whether it happens.
  if (!current) { clearButtons(); return; }

  busy = true;
  clearButtons();

  const d = current;
  const r = await call({
    action: 'decide',
    driverId: d.id,
    decision: decision,
    reason: reason,
  });

  busy = false;

  if (r.status === 0 || (r.status >= 500)) {
    // Not a decision. Say so and put the buttons back, because the alternative
    // -- quietly dropping the driver off the list -- looks to the employee like
    // it worked, and the driver waits for a call that is not coming.
    const note = document.createElement('div');
    note.className = 'err';
    note.textContent = (r.data && r.data.error) || 'That did not save. Try again.';
    wrap.insertBefore(note, wrap.children[1]);
    decideButtons();
    return;
  }

  if (r.status !== 200) {
    const note = document.createElement('div');
    note.className = 'err';
    note.textContent = r.data.error || 'That did not save.';
    wrap.insertBefore(note, wrap.children[1]);
    decideButtons();
    return;
  }

  // Gone. A warning is worth showing and is not worth blocking on: the driver is
  // approved either way, and the founder needs to know about the vehicle.
  if (r.data.warning) {
    modal.innerHTML =
      '<div class="sheet"><div class="panel"><h2>Approved, with a problem</h2>' +
      '<div class="err">' + esc(r.data.warning) + '</div>' +
      '<button class="btn" id="okWarn">OK</button></div></div>';
    document.getElementById('okWarn').onclick = function () {
      modal.innerHTML = '';
      current = null;
      load();
    };
    return;
  }

  current = null;
  load();
}

// ---------------------------------------------------------------- reports

let reports = [];
let currentReport = null;

// Money, in the one format this product uses: two decimals, no thousands
// separator. A fare that could not be read says so rather than showing 0.00,
// which is a number a rider could be charged.
function ghs(v) {
  if (v === null || v === undefined || v === '') return 'not recorded';
  const n = Number(v);
  return isNaN(n) ? 'not recorded' : 'GHS ' + n.toFixed(2);
}

function leg(label, value) {
  return '<div class="leg"><span class="n"><span class="clabel">' + esc(label) + '</span><br>' +
    '<span class="value">' + esc(value) + '</span></span></div>';
}

function reportsScreen() {
  clearButtons();
  current = null;
  currentReport = null;
  canApproveCurrent = false;
  contactNote = '';

  wrap.innerHTML = chrome('Reports') + tabsHtml() +
    '<div class="card"><h2>Loading...</h2></div>';
  wireChrome();

  call({ action: 'listreports' }).then(function (r) {
    if (r.status === 401) { signedOut(); signIn(); return; }
    if (r.status !== 200) {
      wrap.innerHTML = chrome('Reports') + tabsHtml() +
        '<div class="card"><div class="err">' +
        esc(r.data.error || 'Could not load the reports.') + '</div>' +
        '<button class="btn" id="retry">Try again</button></div>';
      wireChrome();
      document.getElementById('retry').onclick = reportsScreen;
      return;
    }
    reports = r.data.reports || [];
    openReports = reports.filter(function (x) { return x.open; }).length;
    renderReports();
  });
}

function reportRow(r) {
  return '<button class="q" data-rid="' + esc(r.id) + '">' +
    '<div class="grow"><div class="who">' + esc(r.riderName) + '</div>' +
    '<div class="ago">' + esc(r.reason) + ' &middot; ' + esc(ago(r.at)) +
    (r.contactedAt ? ' &middot; <span class="ago-when">called</span>' : '') +
    '</div></div>' +
    (r.open ? '<span class="badge">Open</span>' : '<span class="badge done">Handled</span>') +
    '</button>';
}

function renderReports() {
  const open = reports.filter(function (r) { return r.open; });
  const done = reports.filter(function (r) { return !r.open; });

  if (reports.length === 0) {
    wrap.innerHTML = chrome('Reports') + tabsHtml() +
      '<div class="empty">No reports.<br>Nothing a rider has complained about.</div>';
    wireChrome();
    return;
  }

  wrap.innerHTML = chrome('Reports') + tabsHtml() +
    (open.length
      ? '<div class="card"><h2>Waiting: ' + open.length + '</h2>' +
        '<div class="sub">Tap one to read it and call the rider.</div>' +
        open.map(reportRow).join('') + '</div>'
      : '<div class="card"><h2>Waiting: none</h2>' +
        '<div class="sub">Every report has been dealt with.</div></div>') +
    (done.length
      ? '<div class="card"><details><summary>Already handled (' + done.length + ')</summary>' +
        done.map(reportRow).join('') + '</details></div>'
      : '');
  wireChrome();
  wrap.querySelectorAll('.q').forEach(function (b) {
    b.onclick = function () {
      const r = reports.find(function (x) { return x.id === b.dataset.rid; });
      if (r) reportDetail(r);
    };
  });
}

function reportDetail(r) {
  currentReport = r;
  contactNote = '';

  // What the rider said, in their words, largest on the screen. Everything else
  // on this page is context for these two fields.
  const said = r.detail
    ? '<div class="said">' + esc(r.detail) + '</div>'
    : '<div class="sub" style="margin-top:8px">They did not add anything else.</div>';

  wrap.innerHTML =
    '<div class="bar"><button class="link" id="back">&larr; Reports</button>' +
    '<div class="who">' + esc(me) + '</div></div>' +
    '<div class="card">' +
    '<h2>' + esc(r.riderName) + '</h2>' +
    (r.hasRiderNumber
      ? '<div class="sub">' + esc(r.riderPhone) + '</div>'
      // Said rather than left blank. An employee needs to know the number is
      // missing because somebody did not enter one, not because the page is
      // broken -- and it is the difference between ringing the driver and
      // giving up on the complaint.
      : '<div class="err">This rider has no phone number on file, so there is nobody to call. ' +
        'Ask a supervisor to add one.</div>') +

    '<div class="label" style="margin-top:18px">What they reported</div>' +
    '<div class="say">' + esc(r.reason) + '</div>' + said +
    '<div class="sub" style="margin-top:8px">Reported ' + esc(ago(r.at)) + '.</div>' +

    '<div class="label" style="margin-top:20px">The ride</div>' +
    '<div style="margin-top:8px">' +
    leg('From', r.pickupText) +
    leg('To', r.dropoffText) +
    leg('Fare', ghs(r.fareGhs)) +
    leg('Type', r.category) +
    leg('Ride status', r.tripState) +
    leg('Driver', r.driverName) +
    '</div>' +

    '<label for="note" style="margin-top:18px">Note (optional)</label>' +
    '<input id="note" placeholder="What you did about it">' +
    '<div class="sub" style="margin-top:8px">' +
    (r.dismissNote ? 'Note on file: ' + esc(r.dismissNote) : '') + '</div>' +

    (r.contactedAt
      ? '<div class="note" style="margin-top:14px">Called ' + esc(ago(r.contactedAt)) +
        (r.contactedBy ? ' by ' + esc(r.contactedBy) : '') + '.</div>'
      : '') +
    (r.dismissedAt
      ? '<div class="note" style="margin-top:14px">Marked handled ' + esc(ago(r.dismissedAt)) +
        (r.dismissedBy ? ' by ' + esc(r.dismissedBy) : '') + '.</div>'
      : '') +
    '</div>';

  document.getElementById('back').onclick = function () { currentReport = null; reportsScreen(); };
  reportButtons(r);
}

// The bottom bar. Dismissed and reopened both go back to the list, because the
// thing an employee does after deciding is look at the next one.
function reportButtons(r) {
  clearButtons();
  const bar = document.createElement('div');
  bar.className = 'rbar';
  bar.innerHTML =
    '<button class="call" id="callBtn"' + (r.hasRiderNumber ? '' : ' disabled') + '>Call rider</button>' +
    (r.open
      ? '<button class="go" id="markBtn">Mark handled</button>'
      : '<button class="undo" id="reopenBtn">Reopen</button>');
  document.body.appendChild(bar);

  const callBtn = document.getElementById('callBtn');
  if (!r.hasRiderNumber) {
    callBtn.title = 'This rider has no phone number on file.';
  } else {
    callBtn.onclick = function () { callRider(r); };
  }

  const mark = document.getElementById('markBtn');
  if (mark) {
    mark.onclick = function () {
      const box = document.getElementById('note');
      decideReport(r, 'dismiss', box ? box.value : '');
    };
  }
  const reopen = document.getElementById('reopenBtn');
  if (reopen) {
    reopen.onclick = function () {
      const box = document.getElementById('note');
      decideReport(r, 'reopen', box ? box.value : '');
    };
  }
}

// Calling the rider, and recording that it happened.
//
// The order matters and it is the order that is easy to get wrong. Opening the
// dialler first and recording afterwards loses the record most of the time,
// because the phone app takes the screen away and the response lands on a page
// nobody is looking at any more. So the write goes first and the dialler opens
// on the way out.
//
// It opens the phone's own dialler. Nothing is sent: this product has no way to
// message a rider, and a button that looked like it could would be worse than no
// button at all.
async function callRider(r) {
  const res = await call({ action: 'decidereport', reportId: r.id, decision: 'contact' });
  contactNote = res.status === 200 ? '' : (res.data.error || 'The call was not recorded.');
  const shown = reports.find(function (x) { return x.id === r.id; });
  if (shown && res.status === 200) {
    shown.contactedAt = res.data.report ? res.data.report.contactedAt : shown.contactedAt;
    shown.contactedBy = res.data.report ? res.data.report.contactedBy : shown.contactedBy;
  }
  window.location.href = 'tel:' + String(r.riderPhone).replace(/[^0-9+]/g, '');
}

async function decideReport(r, decision, note) {
  clearButtons();
  const res = await call({
    action: 'decidereport',
    reportId: r.id,
    decision: decision,
    note: note || '',
  });

  // A refusal is shown, not swallowed. The one that matters is the second
  // dismiss, where the server refuses because somebody already handled it, and
  // an employee who pressed the button and watched nothing happen would assume
  // the page is broken.
  if (res.status !== 200) {
    const note2 = document.createElement('div');
    note2.className = 'err';
    note2.textContent = res.data.error || 'That did not save. Try again.';
    wrap.insertBefore(note2, wrap.children[1]);
    reportButtons(r);
    return;
  }

  // Re-read from the response rather than patching the row, so the screen shows
  // what the database holds.
  const updated = res.data.report;
  const at = reports.findIndex(function (x) { return x.id === r.id; });
  if (at >= 0 && updated) reports[at] = updated;
  openReports = reports.filter(function (x) { return x.open; }).length;
  currentReport = null;
  reportsScreen();
}

// -------------------------------------------------------- what I have done

function mine() {
  return '<div class="card"><details><summary>What I have decided</summary>' +
    '<div id="mineList" class="sub" style="margin-top:8px">Loading...</div></details></div>';
}

function loadMine() {
  const box = document.getElementById('mineList');
  if (box === null) return;
  call({ action: 'mydecisions' }).then(function (r) {
    if (r.status !== 200) { box.textContent = 'Could not load.'; return; }
    const rows = r.data.decisions || [];
    if (rows.length === 0) { box.textContent = 'Nothing yet today.'; return; }
    box.innerHTML = rows.map(function (d) {
      return '<div class="doc"><span class="n">' +
        (d.decision === 'approved' ? 'Approved' : 'Declined') + ' &middot; ' +
        esc(d.driverName || 'a driver') +
        (d.reason ? '<br><span class="sub">' + esc(REASONS[d.reason] || d.reason) + '</span>' : '') +
        '</span><span class="ago">' + esc(ago(d.at)) + '</span></div>';
    }).join('');
  });
}

if (token) { load(); } else { signIn(); }
</script>
</body>
</html>`;
