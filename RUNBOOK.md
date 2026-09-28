# Meet 'N Go — pilot runbook

Everything needed to get this running on your own laptop, in the order you need
it. It is written for someone following it once, top to bottom, with a coffee.

**If you just want the apps on your phone, read section A and stop.** It needs no
laptop and no payment card.

The build in this repository is complete and its test suites are green. As of the
last commit the Supabase project is also created, migrated and live: the schema,
the row level security policies, the promo seed, all five Edge Functions, both
test accounts and the approved pilot driver are done. A full ride — request,
accept, arrive, start, complete, settle — has been run against the live backend
and balances to the cent. What is left is installing it on a phone.


Two things to know before you start, because they are the two that surprise
people:

1. **Both apps have a sign-up screen**, on the same screen as sign-in — tap
   "Sign Up" at the bottom of the login screen. Google and password sign-in are
   both there. You still need **two** accounts for a full run: one to ride, one
   to drive. One account cannot be both parties to the same trip. If you would
   rather not sign up on the phone, the two accounts below are already made.
2. **A driver has to be approved before the app will show them any work**, and
   no client is allowed to approve itself. `supabase/seed/pilot_driver.sql` does
   that for you. Without it no ride can ever happen.

---

## A. Just get the two APKs — no laptop, no card

If you only want the apps on your phone and not the source, skip everything below
this line. Sections 1–11 are for running the thing yourself.

The APKs are built in the cloud from `codemagic.yaml` at the repo root. Two apps,
one build, about 15 minutes.

1. **Delete the card from GitHub.** Settings → Billing and licensing → Payment
   → Remove. The build account has a billing lock and the card was added by
   mistake; nothing in this project needs to spend money. A public repository's
   GitHub Actions minutes are free, but the account is locked, so the APKs are
   built by Codemagic instead, whose free tier asks for no payment method.
2. **Sign up at [codemagic.com](https://codemagic.io)** with your GitHub
   account. Free, no card.
3. **Add the repository.** Codemagic → Team settings → Codemagic.yaml settings →
   *Connect a repository* → pick `michaelapaloo5/meetngo`. Because the repository
   is public, read-only access is enough.
4. **Add two environment variables**, under *Team settings → Code signing &
   environment variables*:
   - `SB_URL` = `https://mkdbzddgafkqnejivikt.supabase.co`
   - `SB_KEY` = the project's anon key from Supabase → Project Settings → API.

   Both are baked into the APK at compile time by `--dart-define`. The anon key
   is meant to ship inside the app — every read it authorises is already
   filtered by the row level security policies in the migration, and the
   service-role key is never read by either app.
5. **Start the build.** Codemagic → your project → *Start new build* → workflow
   *Meet 'N Go — both APKs*. The first run also runs both test suites and the
   Edge Function tests; it fails if any of them is red.
6. **Download.** When it goes green, the build page has both APKs as artifacts.
   Install `rider-release.apk` on the phone you ride with and
   `driver-release.apk` on the one that drives. Android will ask you to allow
   installs from that app the first time; say yes.

If the build goes red, open the step that failed and read its output — the same
failures section 10 describes, and they are almost always the two environment
variables being mistyped.

---

## 1. What you need

- Flutter 3.47 or newer, with `flutter doctor` clean. Android Studio or Xcode.
- Node 18+ (only for the Supabase CLI, if you install it that way).
- A free Supabase account. The free tier is enough: this demo does not come
  close to its limits.
- A phone with Android, or two Android emulators. An iOS build works too but you
  need a Mac.

## 2. Get the code onto your laptop

Either way works. Push is nicer if you want history.

**Push to GitHub** (no remote is configured yet):

```bash
git clone https://github.com/michaelapaloo5/meetngo.git   # on the laptop
cd meetngo
git checkout feature/rides-marketplace
```

On Windows, set the long-paths option once before cloning, because Flutter's
generated paths exceed the 260-character default:

```powershell
git config --system core.longpaths true
```

**Or copy the folder.** The repository is 3.1 MB excluding `.git`. Copy
`meetngo` across, then delete the build caches, which are large and are
recreated anyway:

```bash
rm -rf meetngo/.dart_tool meetngo/**/.dart_tool
rm -rf meetngo/build meetngo/**/build
```

Then on the laptop:

```bash
cd ~/meet-n-go
flutter pub get          # once per package: see below
```

There are three Dart packages: `apps/rider`, `apps/driver`, `packages/mng_core`.
`flutter pub get` in each app pulls the core package through a path dependency,
so doing the two apps is enough.

## 3. Create the Supabase project

1. Sign in at <https://supabase.com>, **New project**, pick any name, any
   region near Ghana (Frankfurt or Singapore), and let it generate a database
   password. **Save that password** — it is the only time it is shown.
2. When it finishes, note two things from **Project Settings → API**:
   - **Project URL**, looks like `https://abcdefghijklm.supabase.co`
   - the **anon / publishable key** (`sb_publishable_...` or the older `eyJ...`)

   The anon key is not a secret. It ships inside the app bundle by design, and
   every read it authorises is already filtered by the row level security
   policies in the migration. The **service role** key is the one that must never
   reach a device, and nothing in this app ever asks for it.
3. Install the Supabase CLI and log in:

```bash
# macOS / Linux
brew install supabase/tap/supabase     # or see supabase.com/docs/guides/cli
supabase login
```

## 4. Create the database schema

Link the CLI to the project, then push the migration. The project reference is
the first part of the URL from step 3 (`abcdefghijklm`).

```bash
cd ~/meet-n-go
supabase link --project-ref abcdefghijklm
supabase db push
```

That applies one migration, `supabase/migrations/20260927000001_init.sql`: 13
tables, the trip state machine as a trigger, the offer-accepting function that
makes exactly one driver win, and the row level security policies for riders,
drivers and the public. It takes about a second.

It does **not** load the seed. Paste that into the dashboard yourself, because
`db push` is migrations only:

- **SQL Editor → New query**, paste the contents of `supabase/seed/seed.sql`,
  Run. It inserts the `RIDE30` promo code the rider home banner advertises.

## 5. Deploy the six Edge Functions

```bash
supabase functions deploy request-ride
supabase functions deploy offers
supabase functions deploy cancel-trip
supabase functions deploy complete-trip
supabase functions deploy demo-pay
```

Each takes a few seconds. No secrets to set: the functions authenticate callers
against Supabase Auth with the caller's own token and read and write with the
service role the platform injects.

## 6. Create the two accounts

**Authentication → Users → Add user**, twice. Tick **Auto Confirm User** so
there is no confirmation email to chase.

> **Already done on the project this runbook was written against.** If you are
> using that project, do not create these — they exist, and creating a second
> copy with the same address fails.
>
> | account | email | password |
> |---|---|---|
> | rider | `rider@meetngo.app` | `Meetngo2026` |
> | driver | `driver@meetngo.app` | `Meetngo2026` |
>
> They are demo credentials in a demo project with demo money. Change them
> before showing this to anyone, and do not reuse the password anywhere.

## 7. Seed the driver

**SQL Editor → New query**, open `supabase/seed/pilot_driver.sql`, change the
two email addresses at the top of the `do $$` block to the ones you just used,
and Run. It is idempotent, so re-running is safe.

It does four things no app is allowed to do for itself: sets the account's role
to `driver`, sets `kyc_status` to `approved`, creates an approved Toyota Corolla
for them, and parks them at Osu in Accra (which is where the rider app's default
pickup pin is, so the pickup distance is zero and a ride resolves to them
immediately).

> **Already run on the project this runbook was written against**, with those two
> accounts. The script raises if the accounts do not exist, which is why section 6
> comes first. On that project the driver is already online and has one settled
> trip in its wallet, so the driver app opens on a non-zero balance.

You should see a notice like:

```
Pilot driver ready: Ama Boateng (pilot.driver@example.com) vehicle GH-1234-A ...
Pilot rider ready: Kwame Mensah (rider@example.com).
```

Check it with:

```sql
select p.role, p.kyc_status, p.availability, v.make, v.model, v.approved
  from auth.users a
  join profiles p on p.id = a.id
  left join vehicles v on v.id = p.vehicle_id
 where a.email = 'pilot.driver@example.com';
```

Expected: `driver`, `approved`, `offline`, Toyota, Corolla, `t`. The driver
stays **offline** on purpose — they tap Go online in the app, which is also what
proves that toggle writes through.

## 8. Run the two apps

```bash
cd ~/meet-n-go/apps/driver
flutter run --dart-define=SUPABASE_URL=https://abcdefghijklm.supabase.co \
            --dart-define=SUPABASE_ANON_KEY=sb_publishable_xxxx
```

```bash
cd ~/meet-n-go/apps/rider
flutter run --dart-define=SUPABASE_URL=https://abcdefghijklm.supabase.co \
            --dart-define=SUPABASE_ANON_KEY=sb_publishable_xxxx
```

Same two values for both. If you leave them off, the app still launches and
tells you which value is missing rather than crashing — that is deliberate, and
it is a fast way to check you pasted the flag correctly.

For a second device without a second phone, run one app on an emulator and the
other on hardware.

## 9. What a successful ride looks like

Do these in this order on two devices. It takes about three minutes.

1. **Driver app** — log in as the driver, tap **Go online**. The header turns
   amber.
2. **Rider app** — log in as the rider. The home screen shows the greeting, the
   `RIDE30` promo banner, and four available cars.
3. Tap **Where would you go?**. The route sheet opens with pickup Osu and
   dropoff Airport Residential, 2.3 km, about 6 minutes, and a fare.
4. Tap **Confirm route**. Choose a car — the tabs are Standard, Premium and Van
   with different fares. Tap a card to select it, then **Find driver**.
5. **Driver app** — an offer card appears with a 20-second countdown. Tap
   **Accept** before it expires.
6. **Rider app** — the screen changes to the tracking view: the driver's name,
   car and plate, and an ETA badge counting down.
7. **Driver app** — the trip screen opens. Tap **Start navigation**, then
   **Arrived at pickup**. A sheet opens with a four-digit field: ask the rider
   for the code, which is on their tracking screen in an amber panel, and type
   it in. Tap **Start trip**.
8. **Driver app** — **Complete the trip**.
9. **Rider app** — the receipt appears: fare, the 15% commission, the driver's
   payout, and a star row. Tap a star and submit.
10. **Driver app** — the Earnings tab now shows the payout in the balance.

## 10. When it breaks

| symptom | cause | fix |
|---|---|---|
| "No Supabase project is connected" | the `--dart-define` flags are missing or misspelled | re-run `flutter run` with both, exactly as in step 8 |
| Driver app stays on the KYC screen | `kyc_status` is not `approved` | re-run `supabase/seed/pilot_driver.sql`, check the query at the end of step 7 |
| Rider books, no offer ever appears | the driver is offline, or parked more than 5 km away | driver taps **Go online**; the matcher needs a row in `driver_locations` |
| Rider books, no offer, driver is online and approved | the driver was approved but the app was still open through it | fully close and reopen the driver app so it re-reads the profile |
| Offer appears, rider's screen says "looking for another driver" | the offer expired after 20 seconds, or the driver declined | the rider's search restarts on its own; the driver should accept faster |
| Driver taps Accept and gets a red toast | another driver, or the same driver's earlier accept, already won | the single-winner rule working; the rider sees a fresh search |
| Trip completed, driver balance unchanged | the wallet is the session balance; a reload restores it | pull to refresh, or reopen the app. Payouts are deliberately not persisted — see the limits below |
| `Error: something went wrong (500)` | an Edge Function threw; the app shows a generic message because the body is not JSON | check **Logs → Edge Functions** in the dashboard, and **Logs → Postgres** for the trip row |
| Google sign-in does nothing | the OAuth provider is not configured | use the email and password. The appendix covers Google |

To clear a trip a rider abandoned, paste this into the SQL editor:

```sql
update trips set state = 'cancelled', cancelled_at = now()
 where state in ('requested','matched','arriving');
update offers set state = 'released' where state = 'pending';
update profiles set availability = 'offline'
 where id = (select id from auth.users where email = 'pilot.driver@example.com');
```

The first statement matters more than it looks: `activeTrip()` returns the most
recent trip in an active state, so a rider whose trip is stuck looks stuck
forever.

## 11. What this demo deliberately does not do

Better to know these now than to be asked later in front of a customer.

- **No money moves.** Every fare, payout and commission is DEMO data with
  `is_demo = true` on the row. The rider's card is never charged. There is a
  mock MoMo prompt, and the prompt-pin sheet is the payment.
- **The driver is not paid.** `requestPayout` adjusts the balance in the
  running session and writes nothing. A driver who withdraws GHS 200 and closes
  the app has a wallet that was never debited anywhere durable. **This is the
  single thing most likely to be mistaken for real when you demonstrate it.**
- **Password reset does nothing yet.** The screens are built, tested, and wired,
  but the `otp-mail` Edge Function is not written, so "Forgot password?" will
  fail at the send step.
- **The pickup code proves very little.** `trips.pickup_otp` sits on a table the
  assigned driver can read in full, because row level security is row-level and
  a column grant only narrows writes, so the driver could read the code off the
  trip row instead of asking. The comparison is therefore made in the driver
  app against a column the driver can also read, and the honest statement is
  that the code proves a rider said four digits — not that the rider is
  standing there. A real build moves the code to a table with no client policy
  at all, and compares it in an Edge Function. The schema and the runbook are
  otherwise ready for that: `verify-pickup` was written, measured, and then
  deleted rather than left as a deployed function nothing called.
- **Apple sign-in is absent by design.** iOS cannot pass App Store review
  without it, so an iOS launch needs it added back first.
- **The map is OpenStreetMap raster tiles, not Google Maps.** Real tiles, real
  pins and a real polyline on the rider's tracking screen, and the driver's
  position and pickup on the active trip. `flutter_map` draws the free OSM
  endpoint: no API key, no account, no billing, which is the only kind of thing
  this pilot can afford. Google Maps bills per load, so choosing it is a
  decision rather than a default. The trade is the OSM tile usage policy — no
  bulk or offline downloading, and a real launch moves to a paid or self-hosted
  provider.
- **The driver's `onTrip` state is a window, not a lock.** Availability is
  written twice around a trip. A phone that dies between accepting and the first
  write leaves a driver reading `online` while carrying a rider; the app
  reconciles that on next launch, but it is a reconciliation and not a
  guarantee.
- **The bottom-nav tabs are built, not placeholders.** Rider: Home, Bookings,
  Chat, Profile. Driver: Drivers, Trips, Earnings, Profile. The chat reads and
  writes real rows and the trip history is real; what is thin is the depth of
  the screens, not the wiring behind them.

## Appendix: turning on Google sign-in

Only worth doing if you want to show it. The password path needs nothing.

1. In the Google Cloud console, create an OAuth 2.0 client of type **Web
   application**.
2. Add `https://<project-ref>.supabase.co/auth/v1/callback` as an authorised
   redirect URI.
3. **Authentication → Providers → Google**: tick it on, paste the client id and
   client secret, save.
4. **Authentication → URL Configuration**: add
   `io.supabase.meetngo://login-callback` to the redirect allow-list, and
   uncheck "Use the exact URLs above" if you want wildcards.
5. The app registers that scheme itself
   (`Supabase.initialize(publishableKey:)` uses the default
   `io.supabase.<app-name>` scheme). If you renamed the Flutter project, the
   scheme follows the new name and the allow-list has to match.
