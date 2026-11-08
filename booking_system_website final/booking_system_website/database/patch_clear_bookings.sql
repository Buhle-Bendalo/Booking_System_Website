-- ============================================================
-- patch_clear_bookings.sql
-- Adds ONE callable function: clear_all_bookings()
--   * deletes every row in the bookings table
--   * leaves patients, doctors, admin login, reminders, settings untouched
--   * message_log rows are kept (their booking link just becomes empty)
--   * NO UNDO. Locked so only you (SQL Editor) can run it, not the
--     public key, Infobip or Zapier.
-- ============================================================

create or replace function clear_all_bookings()
returns json
language plpgsql
as $$
declare
  v_n int;
begin
  delete from bookings where true;
  get diagnostics v_n = row_count;
  return json_build_object('bookings_deleted', v_n);
end;
$$;

revoke execute on function clear_all_bookings() from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- LOOK FIRST (optional): see how many bookings would be removed
--   select count(*) from bookings;
--
-- RUN WHEN YOU WANT A RESET:
--   select clear_all_bookings();
--
-- VERIFY:
--   select count(*) from bookings;   -- 0
--   select count(*) from patients;   -- unchanged
-- ------------------------------------------------------------
