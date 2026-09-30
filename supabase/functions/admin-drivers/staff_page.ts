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
  canApproveCurrent = false;

  wrap.innerHTML =
    '<div class="bar"><h1>Driver approvals</h1>' +
    '<div class="who">' + esc(me) + '<br><button class="link" id="out">Sign out</button></div></div>';

  document.getElementById('out').onclick = async function () {
    await call({ action: 'staffsignout' });
    signedOut();
    signIn();
  };

  wrap.insertAdjacentHTML(
    'beforeend',
    '<div class="card"><h2>Waiting</h2><div class="sub" id="count">Loading...</div></div>' +
    mine(),
  );
  // Fetched straight away rather than when the disclosure is opened: an
  // employee who opens it to check they have not already done somebody twice
  // should not then wait on the network.
  loadMine();

  call({ action: 'list' }).then(function (r) {
    if (r.status === 401) { signedOut(); signIn(); return; }
    if (r.status !== 200) {
      wrap.innerHTML =
        '<div class="bar"><h1>Driver approvals</h1></div>' +
        '<div class="card"><div class="err">' +
        esc(r.data.error || 'Could not load the list.') + '</div>' +
        '<button class="btn" id="retry">Try again</button></div>';
      document.getElementById('retry').onclick = load;
      return;
    }
    queue = r.data.drivers || [];
    renderQueue();
  });
}

function renderQueue() {
  const card = document.getElementById('count');
  if (card === null) { load(); return; }
  if (queue.length === 0) {
    wrap.innerHTML =
      '<div class="bar"><h1>Driver approvals</h1>' +
      '<div class="who">' + esc(me) + '<br><button class="link" id="out2">Sign out</button></div></div>' +
      '<div class="empty">Nothing waiting.<br>New applications will appear here.</div>' +
      mine();
    document.getElementById('out2').onclick = function () { signedOut(); signIn(); };
    loadMine();
    return;
  }
  card.parentElement.innerHTML =
    '<h2>Waiting: ' + queue.length + '</h2>' +
    '<div class="sub">Tap one to review it.</div>' +
    queue.map(function (d) {
      return '<button class="q" data-id="' + esc(d.id) + '">' +
        '<div class="grow"><div class="who">' + esc(d.fullName || '(no name)') + '</div>' +
        '<div class="ago">' + esc(ago(d.submittedAt)) +
        // Says what the number is, because it used to be something else and an
        // employee has no way to know which. It was the account creation date,
        // so a driver who signed up on Monday and sent everything on Wednesday
        // read as "2 days ago" next to six photographs taken that morning --
        // which is not a description of the evidence being judged.
        ' <span class="ago-when">last document</span> &middot; ' +
        esc((d.vehicle ? d.vehicle.make + ' ' + d.vehicle.model : 'no vehicle')) + '</div></div>' +
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

// Whether the open driver has every required document, so Approve is offered.
// Set by review, read by decideButtons, cleared by load.
//
// Declared beside current rather than inside decideButtons because these two
// are one fact: they are both about *the driver on screen right now*, and either
// one being stale is the same bug. load clears both together.
let canApproveCurrent = false;

function review(d) {
  current = d;
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
  // All of them, not the first. A leftover bar is worse than no bar: it is
  // position: fixed at the bottom of the viewport, so it sits over the queue
  // after a decision and over the sign-in form after signing out, and pressing
  // it would decide on a driver who is no longer open.
  document.querySelectorAll('.decide').forEach(function (bar) { bar.remove(); });
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
