// The admin page, as a string.
//
// Kept out of `index.ts` so the file that holds the service role key and the
// markup that renders driver-supplied text are not the same file. That is not a
// security boundary -- they ship in one bundle -- but the difference between
// "text that gets built" and "text that gets interpolated" is where an XSS
// lives, and `esc` below exists because `full_name`, `plate` and `email` are
// strings a driver chose.
//
// No framework and no build step, and the page holds no credential of its own.
// It does not even hold the anon key: sign-in is a call to the same function,
// which verifies the password and hands back a short-lived user JWT. So the
// only secret in this whole surface is the service role key, and it never
// leaves `index.ts`.
//
// The page is served for an unauthenticated GET, which is deliberate and is the
// one thing here worth being explicit about: it is markup and a sign-in form,
// with no data in it. Every driver record it displays arrives from an
// authenticated call that the function answers only to an admin.
export function adminPage(supabaseUrl: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Meet 'N Go &mdash; driver approvals</title>
<style>
  :root { --ink:#1A1A1A; --sub:#6E6E73; --line:#EDEDF0; --bg:#F5F5F7;
          --brand:#F5B301; --ok:#1DB954; --bad:#E5484D; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--ink);
         font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  header { background:#fff; border-bottom:1px solid var(--line); padding:16px 20px; }
  h1 { font-size:18px; margin:0 0 2px; }
  h2 { font-size:16px; margin:0 0 8px; }
  .sub { color:var(--sub); font-size:13px; }
  main { max-width:920px; margin:0 auto; padding:20px; }
  .card { background:#fff; border:1px solid var(--line); border-radius:12px;
          padding:16px; margin-bottom:12px; }
  .row { display:flex; gap:16px; flex-wrap:wrap; }
  .col { flex:1 1 210px; min-width:0; }
  .label { font-size:11px; text-transform:uppercase; letter-spacing:.04em;
           color:var(--sub); margin-bottom:2px; }
  .value { font-weight:600; word-break:break-word; }
  .plain { font-weight:400; }
  .img { max-width:170px; max-height:170px; border-radius:8px;
         border:1px solid var(--line); display:block; }
  button { font:inherit; font-weight:600; border:0; border-radius:8px;
           padding:10px 18px; cursor:pointer; }
  .approve { background:var(--brand); color:var(--ink); }
  .reject { background:#fff; color:var(--bad); border:1px solid var(--bad); }
  button:disabled { opacity:.45; cursor:default; }
  /* The six documents. Sent and missing differ in colour as well as in label,
     so a column of six rows is scannable at a glance rather than six lines of
     reading. */
  .docs { display:flex; flex-direction:column; gap:4px; margin-top:6px; }
  .doc { display:flex; align-items:center; gap:8px; font-size:13px; }
  .docname { flex:1; }
  .doc.absent .docname { color:var(--sub); }
  .docmissing { font-size:12px; color:var(--bad); }
  .view { background:#fff; color:var(--ink); border:1px solid var(--line);
          padding:4px 10px; font-size:12px; }
  input { font:inherit; padding:10px 12px; border:1px solid var(--line);
          border-radius:8px; width:100%; margin-bottom:10px; }
  .warn { background:#FFF7E0; border:1px solid #F0D89B; border-radius:8px;
          padding:10px 12px; margin-top:12px; font-size:13px; }
  .note { background:#EEF3FF; border:1px solid #C7D7F7; border-radius:8px;
          padding:10px 12px; margin-bottom:16px; font-size:13px; }
  .empty { text-align:center; padding:48px 20px; color:var(--sub); }
  .bar { display:flex; gap:10px; margin-top:14px; }
</style>
</head>
<body>
<header>
  <h1>Driver approvals</h1>
  <div class="sub">Meet &apos;N Go pilot</div>
</header>
<main id="main"></main>

<script>
const URL = ${JSON.stringify(supabaseUrl)};
const main = document.getElementById('main');

/** Every value printed below is a string a driver typed or chose. */
const esc = (v) => String(v === null || v === undefined ? '' : v)
  .replace(/[&<>"']/g, (c) => ({ '&':'&amp;','<':'&lt;','>':'&gt;',
                                 '"':'&quot;',"'":'&#39;' }[c]));

/** The short-lived user JWT, held in memory only. Never persisted. */
let token = null;

async function call(body) {
  const res = await fetch(location.pathname, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: JSON.stringify(body),
  });
  let data = {};
  try { data = await res.json(); } catch (_) {}
  return { status: res.status, data };
}

function signIn(message) {
  main.innerHTML =
    '<div class="card" style="max-width:420px;margin:40px auto">' +
    '<h2>Sign in</h2>' +
    '<p class="sub">An account whose <code>profiles.role</code> is ' +
    '<code>admin</code>. Everyone else is refused by the function, not by ' +
    'this page.</p>' +
    (message ? '<div class="warn" style="margin:0 0 12px">' + esc(message) + '</div>' : '') +
    '<input id="email" type="email" placeholder="admin@example.com" autocomplete="username">' +
    '<input id="password" type="password" placeholder="Password" autocomplete="current-password">' +
    '<button class="approve" id="go">Sign in</button></div>';
  document.getElementById('go').onclick = async () => {
    const { status, data } = await call({
      action: 'signin',
      email: document.getElementById('email').value,
      password: document.getElementById('password').value,
    });
    if (status !== 200) { signIn(data.error || 'Sign in failed.'); return; }
    token = data.token;
    load();
  };
}

// The six documents, in the order the app asks for them.
//
// Written out here rather than taken from the server so the page can show what
// is *missing* as well as what is sent, and so the list cannot silently change
// shape if the server sends something unexpected. These are the same six wire
// values as REQUIRED_DOCUMENTS in handler.ts and the check constraint in
// 20260929000002_driver_documents.sql.
//
// No backticks in this comment: this whole file is one template literal, so a
// backtick here ends the string and the page becomes a syntax error rather
// than a comment.
const DOCS = [
  ['profilePhoto', 'Profile picture'],
  ['vehiclePhoto', 'Vehicle photo'],
  ['ghanaCardPhoto', 'Ghana card photo'],
  ['driversLicence', "Driver's licence photo"],
  ['roadWorthy', 'Road worthy certificate'],
  ['insuranceSticker', 'Insurance sticker']
];

// The six rows, sent or not.
//
// This block is the reason the page exists. A card, a phone number and four
// digits off a Ghana Card are not a document anybody can check a licence
// against; the licence, the road worthy and the insurance sticker are the
// actual decision. An admin who cannot see them is not reviewing, and the
// approve button would be a stamp on nothing.
function documentsBlock(d) {
  const have = new Set(d.documents || []);
  const missing = DOCS.filter(function (x) { return !have.has(x[0]); }).length;
  const rows = DOCS.map(function (x) {
    const sent = have.has(x[0]);
    return '<div class="doc' + (sent ? ' sent' : ' absent') + '">' +
      '<span class="docname">' + esc(x[1]) + '</span>' +
      (sent
        ? '<button class="view" data-kind="' + esc(x[0]) + '">View</button>'
        : '<span class="docmissing">not sent</span>') +
      '</div>';
  }).join('');
  return '<div class="label" style="margin-top:10px">Documents</div>' +
    (missing === 0
      ? '<div class="sub">All six sent.</div>'
      : '<div class="warn" style="margin:6px 0 8px">' + missing +
        ' of 6 still missing. This driver cannot be approved until they are sent.</div>') +
    '<div class="docs">' + rows + '</div>';
}

function card(d) {
  const v = d.vehicle;
  const have = new Set(d.documents || []);
  const complete = DOCS.every(function (x) { return have.has(x[0]); });
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
      // Approve is dead until all six are sent. The server refuses it anyway --
      // this is so the admin finds out before clicking, not instead of.
      (complete
        ? '<button class="approve" data-decision="approve">Approve</button>'
        : '<button class="approve" disabled title="Send the missing documents first">Approve</button>') +
      '<button class="reject" data-decision="reject">Reject</button>' +
    '</div></div>';
}

async function load() {
  const { status, data } = await call({ action: 'list' });
  if (status === 401) { signIn(); return; }
  if (status === 403) {
    main.innerHTML = '<div class="empty">This account is not an admin.</div>';
    return;
  }
  if (status !== 200) {
    main.innerHTML = '<div class="empty">Could not load drivers: ' +
      esc(data.error || String(status)) + '</div>';
    return;
  }
  const drivers = data.drivers || [];
  if (drivers.length === 0) {
    main.innerHTML = '<div class="empty">No drivers waiting on a decision.</div>';
    return;
  }
  main.innerHTML =
    '<div class="note">The Ghana Card is stored as four digits and an expiry, ' +
    'not as a picture &mdash; there is nothing here to check the card against. ' +
    'The selfie is the only document here you can actually look at.</div>' +
    drivers.map(card).join('');

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
}
