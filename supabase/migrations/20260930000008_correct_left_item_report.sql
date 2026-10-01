-- Allow the reporter to correct their own report, and nothing else.
--
-- ## What went wrong in 20260930000007
--
-- That migration deliberately created no UPDATE policy, on the reasoning that "the
-- reporter cannot delete a report to remove a mistake, and they can correct it
-- instead". Both halves of that sentence were meant to be true. Only one was.
--
-- Row level security filters a statement *before* the row exists to be kept, and
-- a row with no matching policy is not a row the statement may touch. So with no
-- UPDATE policy, `authenticated`'s column grant from 00007 was dead on arrival:
-- PostgREST applied it, RLS discarded every candidate row, and the write matched
-- zero rows and answered 204. The grant and the trigger were both fine. There was
-- simply no policy to let the statement reach a row in the first place.
--
-- `toolchain/verify-left-item.mjs` found it, and found it the right way round --
-- by reading the row back after the write rather than trusting the 204. Six of the
-- checks reported the employee-column refusals as "accepted", because
-- `status < 300` is true of a refused update for exactly the reason above. The
-- description edit failed the same way and was not a refusal at all: it was the
-- correction path this migration was supposed to allow.
--
-- So this adds the missing policy. The reasoning in 00007 was not wrong about
-- *deletion*, only about *update*, and the distinction is worth being precise
-- about: an UPDATE policy scoped to the reporter is what makes a correction
-- possible, and its absence is what made one impossible.

create policy "correct your own left item report"
  on left_item_reports
  for update
  to public
  using (reporter_id = auth.uid())
  with check (reporter_id = auth.uid());

-- Both halves, and the second is not repetition.
--
-- `using` decides whether the *existing* row may be updated: only the reporter's
-- own. Without it, a driver who guessed another report's id could update it, and
-- `left_item_reports` ids are uuids -- guessable is the wrong word, but a row
-- that has been through a support call can leak its id through a screenshot.
--
-- `with_check` decides what the row may *become*: still the reporter's. Without
-- it, an update could set `reporter_id` to somebody else and the row would walk
-- out of its author's reach and into that person's. The trigger in 00007 refuses
-- the same change, so this is belt and braces -- and deliberately so, because the
-- policy is the first gate and the trigger the second, and a bug in either should
-- not be the only thing standing between a driver and somebody else's report.

-- Still no DELETE policy, and that one really is deliberate: a report is a
-- statement made to a member of staff, and a report that can be withdrawn is not
-- a statement. A mistake is corrected by editing it, which leaves the earlier
-- version in `staff_note`'s own history rather than erasing it.
--
-- Asserted rather than left to the absence of a policy, so that adding a DELETE
-- policy to this table later is a decision somebody sees:
do $$
begin
  if exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'left_item_reports'
       and cmd = 'DELETE'
  ) then
    raise exception
      'left_item_reports has a DELETE policy. A report a driver can withdraw is not a statement made to staff.';
  end if;
end;
$$;