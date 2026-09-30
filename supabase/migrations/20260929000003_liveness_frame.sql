-- The face check's proof frame, as a seventh document.
--
-- `20260929000002_driver_documents.sql` created the table with a check
-- constraint listing exactly six kinds. The face check produces a seventh --
-- the still taken at the moment the driver passed -- and it has to be stored,
-- because "the app said a live face was verified" is not something an admin
-- approving a stranger can act on. The frame goes beside the licence photo so
-- a person can make that call.
--
-- The constraint is replaced rather than the app narrowed. The alternative --
-- storing the liveness result somewhere other than `driver_documents` -- means
-- two places to look on the admin page and two places to forget to look, and
-- the one that gets forgotten is the one that decides whether a real person
-- is driving.
--
-- The face *check* itself is not in the database. It runs on the phone, in
-- ML Kit's on-device model, and what is stored is its photograph. A server
-- that re-derived a verdict from an image would need the same model and would
-- be judging a compressed photograph of a screen rather than a face in front
-- of a camera; storing the frame and letting a human compare it against the
-- licence is both cheaper and more honest than a number nobody can audit.

alter table driver_documents
  drop constraint if exists driver_documents_kind_check;

alter table driver_documents
  add constraint driver_documents_kind_check check (kind in (
    'profilePhoto',
    'vehiclePhoto',
    'ghanaCardPhoto',
    'driversLicence',
    'roadWorthy',
    'insuranceSticker',
    'livenessFrame'
  ));

-- When the driver passed, so the admin page can show it without opening the
-- frame and so a support answer to "did I do the face check" does not depend on
-- a file existing.
--
-- Client-writable, deliberately. The driver runs the check and writes when it
-- passed, and `guard_profile_update` does not block this column because it
-- blocks the three that would let a driver promote themselves: `role`,
-- `rating`, `trip_count`, and `kyc_status` beyond `pending`. This column
-- confers nothing on its own -- no matcher reads it, and approval is still a
-- human looking at the frame. Blocking it would only have produced a liveness
-- result that exists in the app and nowhere else.
alter table profiles
  add column if not exists liveness_passed_at timestamptz;
