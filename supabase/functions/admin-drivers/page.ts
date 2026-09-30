import { ALL_DOCUMENTS, DOCUMENT_LABELS, REQUIRED_DOCUMENTS } from './handler.ts';

export const adminPage = (supabaseUrl: string): string => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Driver approvals</title>
<style>
  :root {
    --brand:#F5B301; --ink:#111827; --sub:#6B7280; --line:#E5E7EB;
    --bad:#E5484D; --good:#1DB954; --page:#F9FAFB;
  }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
         background:var(--page); color:var(--ink); }
  main { max-width:900px; margin:0 auto; padding:20px 16px 60px; }
  h1 { font-size:20px; margin:0 0 4px; }
  .note { background:#EEF3FF; border:1px solid #C7D7F7; border-radius:8px;
          padding:10px 12px; margin-bottom:16px; font-size:13px; }
  .label { font-size:11px; text-transform:uppercase; letter-spacing:.06em;
           color:var(--sub); margin-bottom:2px; }
  .value { font-weight:600; word-break:break-word; }
  .plain { font-weight:400; }
  .img { max-width:170px; max-height:170px; border-radius:8px;
         border:1px solid var(--line); display:block; }
  button { font:inherit; font-weight:600; border:0; border-radius:8px;
           padding:10px 18px; cursor:pointer; }
  .approve { background:var(--brand); color:var(--ink); }
  .approve[disabled] { opacity:.45; cursor:default; }
  .reject { background:#fff; color:var(--bad); border:1px solid var(--bad); }
  button:disabled { opacity:.45; cursor:default; }
  .warn { background:#FFF7E0; border:1px solid #F0D89B; border-radius:8px;
          padding:10px 12px; margin-top:12px; font-size:13px; }
  .empty { text-align:center; padding:48px 20px; color:var(--sub); }
  .bar { display:flex; gap:10px; margin-top:14px; }
  .card { background:#fff; border:1px solid var(--line); border-radius:12px;
          padding:16px; margin-bottom:16px; }
  .row { display:flex; gap:20px; flex-wrap:wrap; }
  .col { flex:1 1 220px; min-width:200px; }
  .sub { color:var(--sub); font-size:13px; }
  input { font:inherit; padding:10px 12px; border:1px solid var(--line);
          border-radius:8px; width:100%; margin-bottom:10px; }

  /* The documents. Sent and missing differ in colour as well as in label, so a
     column of rows is scannable at a glance rather than six lines of reading. */
  .docs { display:flex; flex-direction:column; gap:4px; margin-top:6px; }
  .doc { display:flex; align-items:center; gap:8px; font-size:13px; }
  .docname { flex:1; }
  .doc.absent .docname { color:var(--sub); }
  .doc.sent .docname { color:var(--ink); }
  .docmissing { font-size:12px; color:var(--bad); }
  .docoptional { font-size:11px; color:var(--sub); }
  .view { background:#fff; color:var(--ink); border:1px solid var(--line);
          padding:4px 10px; font-size:12px; }
</style>
</head>
<body>
<main id="main"></main>
<script>
'use strict';

const main = document.getElementById('main');
let token = sessionStorage.getItem('mng_admin_token') || '';

// The one thing on this page that comes from outside it.
//
// The project's own URL, so a driver photographed in the sign-in screen is sent
// to the right place. It is not a credential and it is not a secret: it is in
// every app this build ships, and it identifies nothing. The page holds no key
// at all, which the tests check by name.
const PROJECT_URL = '${supabaseUrl}';

const esc = function (v) {
  return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
};

async function call(body) {
  const res = await fetch(location.pathname, {
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
}

function signIn(message) {
  main.innerHTML =
    '<h1>Driver approvals</h1>' +
    (message ? '<div class="warn" style="margin:0 0 12px">' + esc(message) + '</div>' : '') +
    '<div class="card"><div class="label">Email</div>' +
    '<input id="email" type="email" autocomplete="username">' +
    '<div class="label" style="margin-top:8px">Password</div>' +
    '<input id="password" type="password" autocomplete="current-password">' +
    '<button class="approve" id="go">Sign in</button></div>';
  document.getElementById('go').onclick = async () => {
    const r = await call({
      action: 'signin',
      email: document.getElementById('email').value,
      password: document.getElementById('password').value,
    });
    if (r.status !== 200) { signIn(r.data.error || 'sign in failed'); return; }
    token = r.data.token;
    sessionStorage.setItem('mng_admin_token', token);
    load();
  };
}

// Which documents exist, and which of the seven are required. Kept in the page
// rather than fetched so a row can be drawn for something the server has not
// heard of, and so the "required" marker cannot disagree with the gate.
const ALL = ${JSON.stringify(ALL_DOCUMENTS)};
const REQUIRED = ${JSON.stringify(REQUIRED_DOCUMENTS)};
const LABELS = ${JSON.stringify(DOCUMENT_LABELS)};

// The documents, sent or not.
//
// This block is the reason the page exists. A card, a phone number and four
// digits off a Ghana Card are not a document anybody can check a licence
// against. The face check photo is the one item that can be compared with the
// licence photograph, so it gets its own row and is labelled optional while its
// detector is broken -- visible to the reviewer, not a bar to a driver's
// approval.
function documentsBlock(d) {
  const have = new Set(d.documents || []);
  const required = ALL.filter(function (k) { return REQUIRED.indexOf(k) >= 0; });
  const missingRequired = required.filter(function (k) { return !have.has(k); });
  const rows = ALL.map(function (k) {
    const sent = have.has(k);
    const isRequired = REQUIRED.indexOf(k) >= 0;
    return '<div class="doc ' + (sent ? 'sent' : 'absent') + '">' +
      '<span class="docname">' + esc(LABELS[k] || k) + '</span>' +
      (sent
        ? '<button class="view" data-kind="' + esc(k) + '">View</button>'
        : (isRequired
            ? '<span class="docmissing">not sent</span>'
            : '<span class="docoptional">not sent (optional)</span>')) +
      '</div>';
  }).join('');
  return '<div class="label" style="margin-top:10px">Documents</div>' +
    (missingRequired.length === 0
      ? '<div class="sub">All ' + required.length + ' required documents sent.</div>'
      : '<div class="warn" style="margin:6px 0 8px">' + missingRequired.length +
        ' of ' + required.length +
        ' still missing. This driver cannot be approved until they are sent.</div>') +
    '<div class="docs">' + rows + '</div>';
}

function card(d) {
  const v = d.vehicle;
  const have = new Set(d.documents || []);
  const complete = REQUIRED.every(function (k) { return have.has(k); });
  return '<div class="card" data-id="' + esc(d.id) + '">' +
    '<div class="row">' +
      '<div class="col">' +
        '<div class="label">Name</div><div class="value">' +
          esc(d.fullName || '(none given)') + '</div>' +
        '<div class="label" style="margin-top:10px">Email</div>' +
          '<div class="value plain">' + esc(d.email) + '</div>' +
        '<div class="label" style="margin-top:10px">Phone</div>' +
          '<div class="value plain">' + esc(d.phone || '(none given)') + '</div>' +
        documentsBlock(d) +
      '</div>' +
      '<div class="col">' +
        '<div class="label">Ghana Card</div>' +
          '<div class="value">' + (d.cardLast4 ? '&#8226;&#8226;&#8226;&#8226; ' + esc(d.cardLast4) : 'not stored') + '</div>' +
          '<div class="value plain">expires ' + esc(d.cardExpiry || '&mdash;') + '</div>' +
        '<div class="label" style="margin-top:10px">Vehicle</div>' +
          '<div class="value">' + (v ? esc(v.make + ' ' + v.model) : 'none') + '</div>' +
          '<div class="value plain">' + (v ? esc(v.plate) + ' &middot; ' + v.seats + ' seats' : '&mdash;') + '</div>' +
        '<div class="label" style="margin-top:10px">Submitted</div>' +
          '<div class="value plain">' + esc(d.submittedAt).slice(0, 10) + '</div>' +
      '</div>' +
      '<div class="col">' +
        '<div class="label">Selfie</div>' +
        (d.selfieUrl
          ? '<img class="img" src="' + esc(d.selfieUrl) + '" alt="Driver selfie">'
          : '<div class="sub">none uploaded</div>') +
      '</div>' +
    '</div>' +
    '<div class="bar">' +
      // Approve is dead until every REQUIRED document is there. The server
      // refuses with a 409 even if the page is bypassed, so this is so the
      // admin finds out before clicking rather than instead of.
      (complete
        ? '<button class="approve" data-decision="approve">Approve</button>'
        : '<button class="approve" disabled title="Send the missing documents first">Approve</button>') +
      '<button class="reject" data-decision="reject">Reject</button>' +
    '</div></div>';
}

async function load() {
  const r = await call({ action: 'list' });
  if (r.status === 401) { signIn(); return; }
  if (r.status === 403) {
    main.innerHTML = '<div class="empty">This account is not an admin.</div>';
    return;
  }
  if (r.status !== 200) {
    main.innerHTML = '<div class="warn">' + esc(r.data.error || String(r.status)) + '</div>';
    return;
  }
  const drivers = r.data.drivers || [];
  main.innerHTML =
    '<h1>Driver approvals</h1>' +
    '<div class="note">Approving flips the driver and their vehicle together. ' +
    'The six photographs are required; the face check photo is shown when a ' +
    'driver sent one but is not required yet, because the in-app check cannot ' +
    'read a frame on this build. If a face check photo is there, compare it ' +
    'with the licence.<br><br>Two things on this page cannot be verified here, ' +
    'and the page says so rather than implying otherwise. The Ghana Card is ' +
    'stored as four digits and an expiry, not as a picture, so there is ' +
    'nothing to look at -- what is shown is a number. And the selfie is not ' +
    'checked against the licence: that is a face match, and this page does not ' +
    'do one. The face check photo is the closest thing to that comparison on ' +
    'this screen, which is why it gets its own row.</div>' +
    (drivers.length === 0
      ? '<div class="empty">Nobody is waiting to be approved.</div>'
      : drivers.map(card).join(''));
  wire(drivers.length);
}

function wire(count) {
  main.querySelectorAll('button[data-decision]').forEach(function (btn) {
    btn.onclick = async function () {
      var el = btn.closest('.card');
      var id = el.dataset.id;
      // Disabled rather than hidden while the write is in flight, so a double
      // click cannot send two decisions for one driver.
      el.querySelectorAll('button').forEach(function (b) { b.disabled = true; });
      const r = await call({
        action: 'decide',
        driverId: id,
        decision: btn.dataset.decision,
      });
      if (r.status !== 200) {
        alert(r.data.error || ('That did not work (' + r.status + ').'));
        el.querySelectorAll('button').forEach(function (b) { b.disabled = false; });
        return;
      }
      if (r.data.warning) alert(r.data.warning);
      load();
    };
  });

  // Viewing a document.
  //
  // One signed URL per click, fetched at the moment it is wanted, rather than
  // six URLs sitting in the list response. The URL is a bearer credential for
  // somebody's passport, so the page holds it for as short a time as it can and
  // never stores it.
  main.querySelectorAll('button.view').forEach(function (btn) {
    btn.onclick = async function () {
      var el = btn.closest('.card');
      btn.disabled = true;
      const r = await call({
        action: 'document',
        driverId: el.dataset.id,
        kind: btn.dataset.kind,
      });
      btn.disabled = false;
      if (r.status !== 200 || !r.data.url) {
        alert(r.data.error || 'That document could not be opened.');
        return;
      }
      window.open(r.data.url, '_blank', 'noopener');
    };
  });
}

signIn();
</script>
</body>
</html>`;
