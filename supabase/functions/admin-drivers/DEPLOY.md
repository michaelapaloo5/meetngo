// Deploying and using the driver-approvals page.
//
// One function, no website, because the service role key can never reach a
// browser and this is the only code that can flip `kyc_status` to `approved`.
//
// 1. Apply BOTH migrations first, in this order.
//
//    a. `supabase/migrations/20260929000001_admin_audit_trail.sql`
//       The function writes `approved_by` and `approved_at`, and without those
//       columns the decision write fails against a column that does not exist.
//
//    b. `supabase/migrations/20260929000002_driver_documents.sql`
//       The `driver_documents` table and the private `kyc-documents` bucket.
//       Without it there is nowhere for a driver's documents to go, so the
//       app's uploads fail and every driver reads as having sent nothing --
//       which is also what a driver who really sent none reads as, so the
//       page cannot tell you which of the two you are looking at.
//
//    c. `supabase/migrations/20260929000003_liveness_frame.sql`
//       Widens the kind check constraint to allow livenessFrame, the photo
//       the face check produces. Without it the app cannot store the one item
//       on the list an admin can compare against the licence, and a driver who
//       has passed the check cannot finish onboarding.
//       app's uploads fail and every driver reads as having sent nothing --
//       which is also what a driver who really sent nothing reads as, so the
//       page cannot tell you which of the two you are looking at.
//
//      supabase db push
//
//    or, in the Dashboard, paste the contents of each file into the SQL editor
//    and run them in that order.
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
//   * Shows the six documents each driver has sent, and how many are missing.
//     Approve is dead until all seven are there, and the server refuses with a
//     409 naming them even if the page is bypassed. This is the substance of
//     the decision: a licence, a road worthy and an insurance sticker are what
//     "may drive this vehicle for paying passengers" is made of. Without them
//     the button is a rubber stamp with an audit trail attached, which is worse
//     than no button because it records a check that never happened.
//   * Each document opens through a signed URL minted at the moment it is
//     clicked, valid for five minutes. Not six URLs per driver in the list
//     response: those are bearer credentials for somebody's passport, and one
//     JSON body is exactly the kind of thing that ends up in a log.
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
//   * A REJECTION is always allowed, documents or not. There is no case for
//     refusing to let an admin turn a driver away.
//
// The page still does not verify a face, because it cannot: liveness and a face
// match against the licence are bought from a provider and are not connected
// (`_LivenessRow.provider` in the app is null, and the app says so on the
// checklist rather than claiming a check it did not perform). Nor does it check
// that a Ghana Card photograph is the same person as the licence photograph.
// Those two are the remaining gaps in "this driver is who they say they are",
// and both are visible as absent rather than quietly passed.
