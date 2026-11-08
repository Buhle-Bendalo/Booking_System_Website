-- ============================================================
-- patch_clear_patients.sql
-- Adds ONE callable function: clear_all_patients()
--   * deletes every row in the patients table
--   * ALSO deletes all their bookings (bookings belong to patients,
--     so they go with them automatically)
--   * leaves doctors, admin login, reminder jobs and settings untouched
--   * message_log rows are kept (their booking link just becomes empty)
--   * NO UNDO. Locked so only you (SQL Editor) can run it, not the
--     public key, Infobip or Zapier.
-- ============================================================

create or replace function clear_all_patients()
returns json
language plpgsql
as $$
declare
  v_bookings int;
  v_patients int;
begin
  select count(*) into v_bookings from bookings;
  delete from patients where true;          -- bookings cascade with them
  get diagnostics v_patients = row_count;
  return json_build_object(
    'patients_deleted', v_patients,
    'bookings_deleted', v_bookings
  );
end;
$$;

revoke execute on function clear_all_patients() from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- LOOK FIRST (optional):
--   select count(*) from patients;
--   select count(*) from bookings;
--
-- RUN WHEN YOU WANT A FULL RESET:
--   select clear_all_patients();
--
-- VERIFY:
--   select count(*) from patients;   -- 0
--   select count(*) from bookings;   -- 0
--   select count(*) from doctors;    -- unchanged
-- ------------------------------------------------------------
