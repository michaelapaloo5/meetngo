# Admin page: reports and locations

Decided with the product owner on 3 October 2026. Nothing here is built yet.

## What already exists

`admin-page/index.html` — one self-contained mobile-first page titled "Driver
approvals". Staff sign in with a 4-digit PIN (`staffsignin`), it holds a bearer
token, and it calls the `admin-drivers` Edge Function. It lists drivers waiting on
KYC and lets staff approve them.

**KYC acceptance is therefore already built.** It is not currently in git; that is
the first thing to fix.

It has no reports view and no locations view.

## Out of bounds

Everything in the repo root — `bundles*.html`, `reseller*.html`, `store*.html`, the
`moolre_verify_order.php` family and the rest — belongs to a different project and
is not to be touched, read for reference, or "tidied". Also untracked and in the
way: `driver-release.apk` and `rider-release.apk` in the root.

## The spec

### Reports

`trip_reports` already has rows; the rider app writes them through "Report a
problem" on a finished ride. There is simply nowhere to read them.

Staff can:

- **read** reports — list and detail
- **dismiss** a report, marking it handled and keeping the record
- **contact the rider** from the page

### Who uses the page

**Other staff as well as the owner.**

This is the decision with the most consequence on this page, because it widens what
the sign-in guards. Today the PIN guards "approve somebody to take paying
passengers". After this work the same page can read what a rider complained about
and where riders and drivers were.

Recommendation made and not yet answered: **named staff accounts, each with their
own PIN, rather than one shared code**, so an action is attributable to a person.
This matters most for "contact the rider" and for the location keep button, because
both touch a real person's data. A shared PIN is acceptable as a first version and
naming the accounts later should not require rework — but decide it now, because
the auth shape is the one thing here that is expensive to change afterwards.

### Locations

- **Last known position** — where the app last reported. Not continuous tracking.
- **Kept 2 weeks.**
- **A control that starts keeping recording and runs until it is switched off**, for
  safety or law reasons.

The owner answered "keep a few days" on a separate retention question and "2 weeks"
on the location question. **2 weeks is the figure being built**, being the more
specific of the two, plus the manual keep on top. Correct it here if wrong.

- **Visible to anyone who can approve drivers.**

## Two consequences of this spec, recorded so they are not lost

**The keep-recording control needs a visible state.** If it is ever left on and
nobody remembers, it becomes permanent surveillance of identifiable people. It
should show a clear, unmissable banner with how long it has been running, and it
should not be possible to leave it on without noticing. Consider whether it can be
turned on at all while no trip is active, and who may turn it off.

**Riders' locations are more sensitive than drivers'.** A rider's location traces
their home and their movements between trips. "Last known" is chosen over live
tracking, which is the right side of that line, but "last known" is still a record
of where a rider was. Worth deciding explicitly whether rider locations are
recorded while no trip is active at all — the recommendation is that they are not.

## Order of work

1. Get `admin-page/` into git. Nothing is built on an untracked file.
2. Clean up or gitignore the root APKs.
3. Decide the staff auth shape (shared PIN vs named accounts) — it is the expensive
   thing to change later.
4. **Reports: read, dismiss, contact rider.** Fully specified, data already exists.
   Needs a new path in the Edge Function.
5. **Locations: last-known view** for riders and drivers.
6. **Retention: 2 weeks**, plus the keep-recording control and its banner.

Each step is its own path in the Edge Function and its own verification. Do not
widen what exists before step 4 is working.

## Verification note

Every one of the bugs found in this project was invisible to `flutter analyze` and
to a passing test suite. The route that never drew, the gold-on-gold splash, the
missing `Material`, the asset key that resolved to nothing, and the double blue line
were all found by looking at a screen. **The admin page gets the same treatment**,
and none of it counts as done until it has been used on a real handset and a real
staff account.
