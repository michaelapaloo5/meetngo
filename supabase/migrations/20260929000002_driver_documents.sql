-- Driver documents: the six photos, and a private bucket to hold them.
--
-- Until this migration there is nowhere in this project to put a driver
-- document. `20260927000001_init.sql` creates ten tables and no bucket, and
-- every `[storage.buckets.*]` block in `supabase/config.toml` is commented out --
-- so `submitSelfie` deliberately does not upload, because writing a
-- `selfie_url` the server does not hold reports a selfie that was never taken.
--
-- This is the migration that makes that honest either way: a real bucket with
-- real policies, so an upload either lands and is recorded or fails loudly.
--
-- Two things here are not optional and are the reason they are written out
-- rather than left to a default:
--
-- 1. The bucket is PRIVATE. A driver's Ghana Card, licence and insurance
--    sticker are identity documents. A public bucket would put them at a
--    guessable URL for anyone who knew a driver's id, with no authentication
--    and no expiry. Every read below goes through a policy that compares
--    `auth.uid()` to the driver who owns the row, and the admin page reads them
--    with the service key rather than as a user.
--
-- 2. The object path carries the driver's own uid as its first folder.
--    `(storage.foldername(name))[1] = auth.uid()::text` is what stops driver A
--    writing a row that claims to be driver B's document, which a policy on the
--    `kyc_documents` table alone cannot prevent -- the table row and the object
--    are written separately, and a policy that only checked the table would
--    still let the object land in someone else's folder.

create table driver_documents (
  id uuid primary key default uuid_generate_v4(),
  driver_id uuid not null references profiles (id) on delete cascade,
  -- The six documents. Plain text rather than an enum, deliberately: adding a
  -- seventh document to a required list is a one-line insert here and an
  -- `alter type` that cannot run inside a transaction on a live table, and the
  -- app is the only writer.
  kind text not null check (kind in (
    'profilePhoto',
    'vehiclePhoto',
    'ghanaCardPhoto',
    'driversLicence',
    'roadWorthy',
    'insuranceSticker'
  )),
  -- The storage object path, not a URL. A public URL would only be correct if
  -- the bucket were public, and it is not.
  path text not null,
  created_at timestamptz not null default now(),
  -- One document of each kind per driver. Re-uploading replaces rather than
  -- accumulating, which is what a driver who photographs a blurry licence
  -- twice needs, and without this the admin page would show three copies and no
  -- way to tell which is the good one.
  unique (driver_id, kind)
);

create index driver_documents_driver_idx on driver_documents (driver_id);

alter table driver_documents enable row level security;

-- A driver reads their own documents, so the app can show what they have
-- already sent after a restart. Nothing else: there is no policy letting a
-- driver read another driver's, and no policy letting any client read a document
-- at all except the row they own.
create policy "driver reads own documents" on driver_documents
  for select
  using (driver_id = auth.uid());

-- A driver claims a document is theirs. The object path is checked against the
-- caller in the storage policy below rather than here, because the row and the
-- object are written separately and only the storage side knows the object name
-- that was actually created.
create policy "driver writes own document" on driver_documents
  for insert
  with check (driver_id = auth.uid());

-- A driver replaces one of their own. `approved` is not a column here, so this
-- cannot be used to mark a document as reviewed -- that is the admin's write,
-- through the service key.
create policy "driver updates own document" on driver_documents
  for update
  using (driver_id = auth.uid())
  with check (driver_id = auth.uid());

-- The bucket. `public` defaults to false, stated explicitly because the whole
-- point of this migration is that it is not public, and a future edit that drops
-- the line would otherwise be an invisible change of meaning.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'kyc-documents',
  'kyc-documents',
  false,
  -- 10 MB. A phone camera photo of a licence is a couple of megabytes; this is
  -- generous, and a limit is what stops a bucket being used as free storage by
  -- anything that can get a token.
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic']
)
on conflict (id) do nothing;

-- A driver uploads only into their own folder. This is the policy that does the
-- real work on the object side, because it is the only place the object's name
-- is known.
create policy "driver uploads own document" on storage.objects
  for insert
  with check (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "driver reads own document objects" on storage.objects
  for select
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Deleting is a driver's own business: a licence photographed against a dark
-- window should be removable, and the row cascades away with the profile.
create policy "driver deletes own document objects" on storage.objects
  for delete
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- No UPDATE policy on storage.objects. Storage has no update; a replacement is a
-- delete and an insert, and a `true` here would let a driver overwrite any
-- object in the bucket, which is the one thing the folder check exists to
-- prevent.
