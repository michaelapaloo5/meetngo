// Deploying and using the driver-approvals page.
//
// One function, no website, because the service role key can never reach a
// browser and this is the only code that can flip `kyc_status` to `approved`.
//
// 1. Apply the audit-trail migration first. The function writes
//    `approved_by` and `approved_at`, and without those columns the decision
//    write fails against a column that does not exist.
//
//      supabase db push
//
//    or, in the Dashboard, paste the contents of
//    `supabase/migrations/20260929000001_admin_audit_trail.sql` into the SQL
//    editor and run it.
//
// 2. Deploy the function.
//
//      supabase functions deploy admin-drivers
//
// 3. Give yourself an admin account. The `role` check is `profiles.role =
//    'admin'` and nothing else, so an account that is not admin sees "This
//    account is not an admin" and is refused server-side.
//
//    In the Dashboard -> SQL editor, with YOUR email substituted:
//
//      update profiles
//         set role = 'admin'
//       where id = (
//         select id from auth.users
//          where lower(email) = lower('you@example.com')
//       );
//
//    A driver whose account you are using is fine. Nothing about the page
//    requires a separate admin account, only a row with that role.
//
// 4. Open the page. It is the function's own URL:
//
//      https://<project-ref>.supabase.co/functions/v1/admin-drivers
//
//    Sign in with the admin account. The page holds no credential of its own --
//    not even the anon key -- so signing in is a call to this function, and the
//    only secret in the surface is the service role key, which never leaves
//    `index.ts`.
//
// What it does, and why each part is there:
//
//   * Lists drivers with `kyc_status = 'pending'`, newest first.
//   * Approving flips the profile AND the vehicle in one call. The vehicle is
//     the part people forget: `match_offers_for_trip` joins `vehicles v on
//     v.owner_id = d.id and v.approved`, so an approved profile with an
//     unapproved vehicle is invisible to the matcher however online the driver
//     is, while their own app shows them as ready.
//   * Approving a driver with no vehicle returns a warning rather than a
//     success, because that is the case where the admin needs to know something
//     is still missing.
//   * Both decisions record `approved_by` and `approved_at`, so "why is this
//     driver online" has an answer.
//
// The page does not verify a Ghana Card, because it cannot: the app stores four
// digits and an expiry and no picture of the card. The page says so on screen
// rather than implying a check it cannot make. The selfie is the only document
// here an admin can actually look at. Storing the card image is the change that
// would make that column real.
