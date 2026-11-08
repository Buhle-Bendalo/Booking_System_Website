-- ============================================================
-- patch_cancel_reschedule.sql
-- Creates (or replaces) the 5 functions the Cancel/Reschedule
-- chatbot flow needs:
--   get_patient_bookings  - a patient's upcoming bookings, numbered
--   verify_and_list       - check phone + ID number, return the list
--   resolve_booking       - "2" -> the real booking id
--   cancel_booking_by_id  - cancel one booking
--   reschedule_booking    - move a booking to a new time in one step
--
-- Safe to run more than once. Deletes NO data.
-- Older versions are dropped first, because Postgres won't
-- "replace" a function whose parameter names or return shape changed
-- (e.g. an old verify_and_list that took a date of birth).
-- ============================================================

-- 1. Remove any older versions (all overloads) of these 5 functions
do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_patient_bookings','verify_and_list','resolve_booking',
                        'cancel_booking_by_id','reschedule_booking')
  loop
    execute format('drop function %s', r.sig);
  end loop;
end
$do$;


-- 2. A patient's upcoming confirmed bookings, numbered 1, 2, 3...
create function get_patient_bookings(p_phone text)
returns table(idx int, booking_id uuid, doctor_name text, chosen_slot timestamptz) as $$
  select row_number() over (order by b.chosen_slot)::int, b.id, d.full_name, b.chosen_slot
  from bookings b
  join patients p on p.id = b.patient_id
  join doctors d on d.id = b.doctor_id
  where p.phone_number = p_phone
    and b.status = 'confirmed'
    and b.chosen_slot > now();
$$ language sql stable;


-- 3. Verify phone + ID number, then return the upcoming bookings.
-- Every failure (unknown number, no ID on file, wrong ID) returns ok = "no",
-- so the bot can't be used to discover who is registered.
-- Returns: ok (yes/no/error), patient_uuid, patient_name, list, count
-- list = "NONE" when the patient has no upcoming bookings.
create function verify_and_list(p_phone text, p_id text) returns json as $$
declare v_pat patients%rowtype; v_id text; v_list text; v_count int;
begin
  v_id := regexp_replace(coalesce(p_id,''), '[ -]', '', 'g');
  select * into v_pat from patients where phone_number = p_phone;
  if not found or v_pat.id_number is null or v_pat.id_number <> v_id then
    return json_build_object('ok','no','patient_uuid','','patient_name','','list','','count','0');
  end if;
  select count(*),
         coalesce(string_agg(format('%s. %s - %s', idx,
                  to_char(chosen_slot at time zone 'Africa/Johannesburg','Dy DD Mon, HH24:MI'),
                  doctor_name), E'\n' order by idx), 'NONE')
    into v_count, v_list
    from get_patient_bookings(p_phone);
  return json_build_object('ok','yes','patient_uuid', v_pat.id::text,
                           'patient_name', v_pat.patient_name, 'list', v_list, 'count', v_count::text);
exception when others then
  return json_build_object('ok','error','patient_uuid','','patient_name','','list','','count','0');
end;
$$ language plpgsql stable;


-- 4. Turn the number the patient typed into a real booking.
-- Returns: ok (yes/no), booking_id, label ("Mon 12 Oct, 14:30 with Dr. D Khumalo")
create function resolve_booking(p_phone text, p_choice text) returns json as $$
  select coalesce(
    (select json_build_object('ok','yes','booking_id', booking_id::text,
            'label', to_char(chosen_slot at time zone 'Africa/Johannesburg','Dy DD Mon, HH24:MI') || ' with ' || doctor_name)
     from get_patient_bookings(p_phone)
     where idx = case when trim(coalesce(p_choice,'')) ~ '^[0-9]{1,2}$'
                      then trim(p_choice)::int else -1 end),
    json_build_object('ok','no','booking_id','','label',''));
$$ language sql stable;


-- 5. Cancel one booking. It must belong to this phone number,
-- be confirmed and still upcoming. Calling it twice is harmless
-- (the second call returns ok = "no").
-- The row is kept with status 'cancelled', so the slot frees up,
-- reminders stop, and reception still sees the history.
-- Returns: ok (yes/no/error)
create function cancel_booking_by_id(p_phone text, p_booking_id text) returns json as $$
declare v_id uuid; v_n int;
begin
  v_id := p_booking_id::uuid;
  update bookings b set status = 'cancelled'
    from patients p
   where b.id = v_id and p.id = b.patient_id and p.phone_number = p_phone
     and b.status = 'confirmed' and b.chosen_slot > now();
  get diagnostics v_n = row_count;
  return json_build_object('ok', case when v_n = 1 then 'yes' else 'no' end);
exception when others then
  return json_build_object('ok','error');
end;
$$ language plpgsql;


-- 6. Move a booking: create the new one and cancel the old one in one step.
-- If the new time is taken, the old booking is left exactly as it was.
-- Returns: ok (yes/notfound/taken/error), booking_id (the NEW one), detail
create function reschedule_booking(
  p_old_booking_id text, p_patient_id text, p_doctor_id text,
  p_slot text, p_end text, p_symptoms text
) returns json as $$
declare v_old uuid; v_new uuid; v_patient uuid; v_found int;
begin
  v_old := p_old_booking_id::uuid;
  v_patient := p_patient_id::uuid;

  select count(*) into v_found from bookings
   where id = v_old and patient_id = v_patient
     and status = 'confirmed' and chosen_slot > now();
  if v_found = 0 then
    return json_build_object('ok','notfound','booking_id','','detail','');
  end if;

  -- free the old slot first, so moving to an overlapping time with the same doctor works
  update bookings set status = 'cancelled' where id = v_old;

  insert into bookings (patient_id, doctor_id, chosen_slot, ends_at, symptoms, status)
  values (v_patient, p_doctor_id::uuid, p_slot::timestamptz, p_end::timestamptz, p_symptoms, 'confirmed')
  returning id into v_new;

  return json_build_object('ok','yes','booking_id', v_new::text,'detail','');
exception
  when exclusion_violation then
    -- everything above is rolled back, including the cancel
    return json_build_object('ok','taken','booking_id','','detail','');
  when others then
    return json_build_object('ok','error','booking_id','','detail', sqlstate || ': ' || sqlerrm);
end;
$$ language plpgsql;


-- 7. Permissions: only the secret key (Infobip / Zapier) may call these.
do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_patient_bookings','verify_and_list','resolve_booking',
                        'cancel_booking_by_id','reschedule_booking')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end
$do$;

notify pgrst, 'reload schema';


-- ------------------------------------------------------------
-- CHECK: should list exactly 5 rows
--   select proname, pg_get_function_identity_arguments(oid) as args
--   from pg_proc
--   where proname in ('get_patient_bookings','verify_and_list','resolve_booking',
--                     'cancel_booking_by_id','reschedule_booking');
--
-- TRY IT (swap in a real patient's phone + ID):
--   select verify_and_list('0734567645', '8002145231088');
--   select resolve_booking('0734567645', '1');
--   select cancel_booking_by_id('0734567645', '<booking_id from the line above>');
-- ------------------------------------------------------------
