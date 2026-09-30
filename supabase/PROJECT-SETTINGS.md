# Hosted project settings

`supabase/config.toml` configures a **local** Supabase. It has no effect on the
hosted project at `mkdbzddgafkqnejivikt`. This file records the hosted settings
that a migration cannot set, because they are not in the database schema — they
are in the project's auth configuration, and a reviewer reading the migrations
would reasonably assume the schema was the whole story.

Read them:

```
GET  https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/config/auth
PATCH https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/config/auth
Authorization: Bearer $SUPABASE_ACCESS_TOKEN
Content-Type: application/json
```

## `mailer_autoconfirm = true`

**Changed 2026-09-30. It was `false`, and that was a live bug.**

With it off, `POST /auth/v1/signup` creates the account and returns **no session**:
the driver has to click a link in an email before they have a usable session. The
signup screen had a branch for this, and the app's whole onboarding — seven
documents, a face check, a vehicle — sat behind an email round-trip that never
completes on a poor connection. `apps/driver` also had a `session == null` path
whose message promised an email that, on a bad day, was not reliably delivered.

It is now `true`. Verified against the hosted project with a real signup to an
address that has never received mail:

| field | before | after |
| --- | --- | --- |
| `access_token` in the signup response | absent | present |
| `auth.users.email_confirmed_at` | null | set |
| `auth.users.confirmation_sent_at` | set | null |

`confirmation_sent_at` being null is the load-bearing part: no email is sent at
all, rather than one being sent and clicked automatically. A driver who signs up
is in the app immediately.

### The trade-off, stated plainly

Anyone can now sign up with any email address and get a usable account without
proving they own it. They can also sign up as `someone.else@gmail.com` and
create a profile under that name.

What they cannot do is drive. Reaching a paying passenger needs all of:

* `profiles.kyc_status = 'approved'` — an admin writes this after a person
  compares seven documents by eye. A client may only move it *to* `pending`.
* `vehicles.approved = true` — the insert policy forces `false` and the update
  policy carries `with check (approved = false)`.
* a `driver_locations` row and `availability = 'online'`, within 5 km.

So the exposure is "an account exists with a name and an email on it", not
"somebody else's identity is usable". The KYC documents, not the email address,
are the identity check — which is the correct place for it in this product.

This is the normal trade for ride-hailing onboarding and the alternative is worse:
requiring a click on an email means real drivers on bad data never finish
signing up. If this ever needs to be reversed it is one PATCH, and
`SupabaseDriverAuthRepository.signUp` already handles a null session with a
sentence rather than a stack trace.

## `password_min_length = 6`

Supabase's default, and left alone. It is the weakest setting on this project and
the one most worth revisiting before there is money in the system: a six-character
password on an account that can see KYC photographs and a live trip. There is no
rate-limit change here that fixes that, only a longer password. Raising it to 12
is a one-line PATCH, but it would lock out any existing account below the new
floor, so it wants a plan rather than a change made in passing.

## `security_captcha_enabled = false`

Bot signups are unmitigated. This is a direct consequence of autoconfirm: before,
each signup cost an email round-trip; now a bot can create accounts for free.
Enabling it needs an hCaptcha secret, which is not configured, so it could not be
switched on meaningfully today. The exposure is the same as above — queue
entries — and the queue is one driver at a time, so a flood is visible and
deletable rather than silent.

## API keys

The project exposes both the old JWT pair and the new publishable/secret pair.
`anon` and `service_role` are `type: legacy`; the new pair is `default` with
`publishable` and `secret`. The app ships the `anon` JWT, which is public by
design. Anything written with the `service_role` key is a privileged write and
bypasses RLS — that is what admin approval is.

Note for scripts: filter the key list on `name`, not `type`. Both JWT keys report
`type: legacy`, so filtering for `type = 'anon'` matches nothing and the script
carries on with an empty key, which surfaces as `Invalid Compact JWS` and reads
like a permissions problem rather than a lookup that matched no rows.
