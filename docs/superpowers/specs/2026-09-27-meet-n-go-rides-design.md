# Meet 'N Go — Sub-project 1: Rides Marketplace — Design Spec

Date: 2026-09-27
Status: approved in chat, pending file review
Super-app roadmap: Rides (this spec) → Food delivery → Essentials → Goods courier.
Later verticals reuse auth, map, wallet, chat, and trip primitives from this build.

## 1. Outcome + scope

Build a working ride-hailing marketplace for Accra, Ghana:

- Rider app (Flutter, iOS + Android)
- Driver app (Flutter, iOS + Android)
- Backend on Supabase (Postgres + Auth + Realtime + Storage + Edge Functions)
- Day-1 admin via Supabase Studio; custom admin panel is out of scope

Success: a rider can sign up, request a ride, get matched, track the driver
live on a 3D-styled map, complete the trip with demo payment, and rate the
driver. A driver can onboard with KYC, go online, accept offers, and earn to
a demo wallet.

Out of scope: food, essentials, courier verticals; real money movement;
custom admin UI; iOS Apple-login (see auth).

## 2. Reference UI (from supplied videos)

The 3 supplied clips are `@dailyflutterui` Flutter taxi-demo recordings
("Beeway"), not the real Meet 'N Go app. They define the target look:

- Amber-yellow primary CTA, light theme, dark text, grey subtext
- Cards radius 16–20, bottom sheets with drag handles
- Rider flow: splash → Welcome-Back login → home (greeting, "Where would you
  go?", category chips, promo banner with code, nearby-car cards) → route
  entry (pickup/dropoff, km + min estimate) → Choose-car tabs + cards
  (photo, rating, seats, price) → Finding-driver (3D isometric city map,
  match list, decline offer) → Ride-confirmed → Driver-on-way (ETA countdown
  4→1 min, Call / Message / Cancel) → receipt + rating
- Auth extras: forgot-password → 6-digit email OTP with resend timer →
  new-password with strength rules → success screen
- Demo stack visible in clips: Flutter + ScreenUtil, 390×844 baseline.
  We adopt the same baseline.

## 3. Apps + screens

### 3.1 Rider app

Bottom nav: Home / Bookings / Chat / Profile.

1. Splash onboarding (brand + 3 slides max)
2. Login: Google + email/password. No Apple login (Android-first launch;
   App Store mandates Apple Sign-In wherever Google login ships on iOS,
   so iOS launch must add it back)
3. Forgot password: email → 6-digit OTP (resend timer) → new password
   (min 6 chars, match check) → success → login
4. Home: greeting, "Where would you go?" search, category chips
   (Standard / Premium / Van — no moto at launch), promo banner,
   nearby-car cards
5. Route entry: pickup + dropoff, distance + ETA + upfront fare
6. Choose car: category tabs, cards with photo, rating, seats, price,
   pay method row, "Find driver" CTA
7. Finding driver: 3D-styled map, nearby driver count, offer list with
   decline, cancel search
8. Tracking: ride-confirmed → driver-on-way with live ETA, Safety button,
   Call / Message / Cancel, share-trip link
9. Receipt + 2-way rating, Bookings history, Profile + wallet (demo)

### 3.2 Driver app

1. Login + onboarding: phone OTP, Ghana Card OCR + selfie liveness,
   vehicle docs, approval states (pending / approved / rejected)
2. Go-online toggle, offer queue (fare, pickup distance, rider rating,
   accept / decline with expiry countdown)
3. Active trip: navigation to pickup, rider pickup-OTP confirm, trip start,
   dropoff + fare summary, earnings feed, demo wallet + payout history,
   ratings

## 4. Backend (Supabase-centric)

### 4.1 Tables (Postgres + PostGIS)

- profiles (rider/driver roles, KYC status, phone, avatar)
- vehicles (driver link, category, plate, docs, approval)
- trips (status machine: requested → matched → arriving → ongoing →
  completed / cancelled, pickup/dropoff geo, fare, category)
- offers (trip link, driver link, expiry, state: pending / accepted /
  declined / expired)
- locations (driver GPS pings, PostGIS point, timestamp)
- payments (trip link, amount GHS, method, state — DEMO stamped)
- payouts (driver wallet ledger, demo disbursement records)
- ratings (2-way, trip link)
- promos (code, percent, caps)
- chat_messages (trip-scoped rider↔driver)
- sos_events (trip link, timestamp, status)

RLS: riders read/write own trips + related rows; drivers read own offers,
assigned trips, write own locations; service role for Edge Functions.

### 4.2 Realtime channels

- `trip_{id}`: status transitions + assigned-driver GPS to rider
- `driver_{id}`: incoming offers + cancellations to driver

Driver GPS ping every ~5 s while online/on-trip.

### 4.3 Edge Functions (Deno)

- request-ride: fare = base + per-km GHS rate per category × surge
  (cap, shown upfront); radius match, create offers with TTL
- offer respond (accept/decline/expire), first-accept wins, rest cancelled
- cancel-trip (policy: free window, then fee to driver)
- complete-trip (payout split by configurable commission, ledger entries)
- demo-pay: creates payments rows stamped DEMO, instant-settle;
  interface shaped like a real provider collect + webhook pair so a live
  provider drops in later without app changes
- otp-mail: 6-digit codes for password reset
- sos ingests sos_events

## 5. Money + trust (demo mode)

- All payments are DEMO: mock wallet, mock MoMo prompt-pin sheet in-app,
  every row/ledger entry stamped demo, no real settlement anywhere.
- Fares in GHS, per-category rates, surge cap displayed before confirm.
- Real-provider integration is a later phase behind the demo-pay interface.
- KYC: drivers Ghana Card OCR + selfie liveness + vehicle docs; riders
  phone OTP only.
- Safety: share-trip link, SOS button → sos_event, pickup OTP anti-fraud,
  2-way ratings, support via Chat tab.

## 6. Look + feel

- Tokens: amber-yellow primary CTA, white cards radius 16–20, light theme,
  dark text / grey subtext, system-style font.
- Map: Google Maps SDK with custom-styled tiles, tilted 3D camera on
  tracking screens, car markers, route polyline.
- Car imagery on white cards; bottom sheets with drag handles.
- Flutter + ScreenUtil, 390×844 design baseline.

## 7. Monorepo + quality + rollout

```
meet-n-go/
  apps/rider/        # Flutter rider app
  apps/driver/       # Flutter driver app
  supabase/          # migrations, seed, functions/
  docs/              # specs
```

- CI on PR: flutter analyze + flutter test; edge-function unit tests.
- Tests: widget tests per screen, trip-lifecycle integration against a
  Supabase branch, fare + commission unit tests.
- Rollout: internal Accra pilot (~10 drivers), demo payments end-to-end,
  then real-provider phase, then public launch.
- Reuse contract for food/essentials/courier: auth, map, wallet, chat,
  trip/offer primitives stay vertical-agnostic.

## 8. Open risks

- Google Maps SDK keys + billing for Ghana tile volume.
- Driver supply: 10-driver pilot is thin for matching demos.
- iOS launch blocked on adding Apple Sign-In (App Store rule).
- Supabase free-tier caps (realtime connections, edge invocations) under
  live load — monitor before public launch.
