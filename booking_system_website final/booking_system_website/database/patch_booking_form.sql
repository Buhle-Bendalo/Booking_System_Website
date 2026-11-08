-- ============================================================
-- patch_booking_form.sql
-- Backup web booking form (book.html), for when people don't want the chat.
--
-- What this adds:
--   1. Patient columns the form collects (safe if some already exist)
--   2. bookings.booked_via  - chatbot | web_form | reception
--   3. Three public functions the form calls with the PUBLISHABLE key:
--        form_get_available_doctors(p_date)
--        form_get_available_slots(p_doctor_id, p_date)
--        form_submit_booking(p_form)
--   4. Reception can now Confirm (or Cancel) a pending booking
--
-- Safety rules built in:
--   * The public functions only ever return doctor names and free times.
--   * A form booking is saved as 'pending'. It holds the slot, but gets no
--     reminders until reception confirms it on the dashboard.
--   * The form can never change an existing patient whose ID number
--     doesn't match - it tells the person to call reception instead.
--   * Spam limits: 2 open form bookings per phone number,
--     40 form bookings per hour for the whole clinic.
--
-- Safe to run more than once. Deletes NO data.
-- Run AFTER clinic_db_rebuild.sql and patch_admin_dashboard.sql.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Columns
-- ------------------------------------------------------------
alter table patients
  add column if not exists gender             text,
  add column if not exists passport_number    text,
  add column if not exists address            text,
  add column if not exists payment_method     text,
  add column if not exists medical_aid_name   text,
  add column if not exists medical_aid_plan   text,
  add column if not exists medical_aid_number text,
  add column if not exists dependant_code     text,
  add column if not exists main_member_name   text,
  add column if not exists main_member_id     text;

alter table patients drop constraint if exists patients_gender_check;
alter table patients add constraint patients_gender_check
  check (gender is null or gender in ('male','female','other'));

alter table patients drop constraint if exists patients_payment_method_check;
alter table patients add constraint patients_payment_method_check
  check (payment_method is null or payment_method in ('cash','medical_aid'));

alter table patients drop constraint if exists patients_dependant_code_check;
alter table patients add constraint patients_dependant_code_check
  check (dependant_code is null or dependant_code ~ '^[0-9]{2}$');

alter table patients drop constraint if exists patients_passport_number_check;
alter table patients add constraint patients_passport_number_check
  check (passport_number is null or passport_number ~ '^[A-Z0-9]{6,20}$');

create unique index if not exists patients_passport_number_key
  on patients (passport_number) where passport_number is not null;

alter table bookings
  add column if not exists referral_path text,
  add column if not exists booked_via    text not null default 'chatbot';

alter table bookings drop constraint if exists bookings_booked_via_check;
alter table bookings add constraint bookings_booked_via_check
  check (booked_via in ('chatbot','web_form','reception'));


-- ------------------------------------------------------------
-- 2. Helper: turn a date typed on the form into a bookable date (or null)
-- ------------------------------------------------------------
create or replace function form_parse_date(p_date text) returns date
language plpgsql stable
set search_path = public, extensions, pg_temp
as $$
declare d date;
begin
  if p_date is null or trim(p_date) !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  begin d := trim(p_date)::date; exception when others then return null; end;
  if d < (now() at time zone 'Africa/Johannesburg')::date or d > current_date + 60 then
    return null;
  end if;
  return d;
end;
$$;


-- ------------------------------------------------------------
-- 3. Doctors with free times on a date
-- ok = yes | invalid ; doctors = [{doctor_id, full_name, specialty}]
-- ------------------------------------------------------------
create or replace function form_get_available_doctors(p_date text) returns json
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare d date := form_parse_date(p_date);
begin
  if d is null then
    return json_build_object('ok','invalid','doctors', '[]'::json);
  end if;
  return json_build_object('ok','yes','doctors', coalesce((
    select json_agg(json_build_object(
             'doctor_id', a.doctor_id::text,
             'full_name', a.full_name,
             'specialty', coalesce(a.specialty, 'General Practice'))
           order by a.full_name)
    from get_available_doctors(d) a), '[]'::json));
end;
$$;


-- ------------------------------------------------------------
-- 4. Free times for one doctor on a date
-- ok = yes | invalid ; slots = [{slot, label}]  (label = "09:30")
-- ------------------------------------------------------------
create or replace function form_get_available_slots(p_doctor_id text, p_date text) returns json
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare d date := form_parse_date(p_date); v_doc uuid;
begin
  begin v_doc := p_doctor_id::uuid; exception when others then v_doc := null; end;
  if d is null or v_doc is null
     or not exists (select 1 from doctors where id = v_doc and active = true) then
    return json_build_object('ok','invalid','slots', '[]'::json);
  end if;
  return json_build_object('ok','yes','slots', coalesce((
    select json_agg(json_build_object(
             'slot',  s.slot,
             'label', to_char(s.slot at time zone 'Africa/Johannesburg','HH24:MI'))
           order by s.slot)
    from get_available_slots(v_doc, d) s), '[]'::json));
end;
$$;


-- ------------------------------------------------------------
-- 5. Submit the whole form
-- p_form is one JSON object (see book.html for the exact keys).
-- ok = yes | invalid (+ field) | taken | mismatch | limit | error
-- On yes: reference, doctor_name, slot_label
-- ------------------------------------------------------------
create or replace function form_submit_booking(p_form jsonb) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  f           jsonb := coalesce(p_form, '{}'::jsonb);
  v_first     text := trim(coalesce(f->>'first_name',''));
  v_last      text := trim(coalesce(f->>'surname',''));
  v_id_type   text := coalesce(f->>'id_type','');
  v_id_number text := regexp_replace(coalesce(f->>'id_number',''), '[ -]', '', 'g');
  v_passport  text := upper(regexp_replace(coalesce(f->>'passport_number',''), '[^A-Za-z0-9]', '', 'g'));
  v_dob       date;
  v_gender    text := coalesce(f->>'gender','');
  v_phone     text := regexp_replace(coalesce(f->>'phone_number',''), '[^0-9+]', '', 'g');
  v_email     text := lower(trim(coalesce(f->>'email','')));
  v_street    text := trim(coalesce(f->>'street',''));
  v_city      text := trim(coalesce(f->>'city',''));
  v_province  text := trim(coalesce(f->>'province',''));
  v_postal    text := trim(coalesce(f->>'postal_code',''));
  v_pay       text := coalesce(f->>'payment_method','');
  v_aid_name  text := trim(coalesce(f->>'medical_aid_name',''));
  v_aid_plan  text := trim(coalesce(f->>'medical_aid_plan',''));
  v_aid_no    text := trim(coalesce(f->>'medical_aid_number',''));
  v_is_main   boolean := coalesce((f->>'is_main_member')::boolean, true);
  v_dep_code  text := trim(coalesce(f->>'dependant_code',''));
  v_mm_name   text := trim(coalesce(f->>'main_member_name',''));
  v_mm_id     text := upper(regexp_replace(coalesce(f->>'main_member_id',''), '[^A-Za-z0-9]', '', 'g'));
  v_chronic   text := trim(coalesce(f->>'chronic_illness',''));
  v_reason    text := trim(coalesce(f->>'reason',''));
  v_doctor    uuid;
  v_slot      timestamptz;
  v_by_phone  patients%rowtype;
  v_by_ident  patients%rowtype;
  v_patient   uuid;
  v_booking   uuid;
  v_doc_name  text;
begin
  -- spam trap: a hidden field people never see; bots fill it in
  if coalesce(f->>'website','') <> '' then
    return json_build_object('ok','invalid','field','form');
  end if;

  -- ---------- check every field ----------
  if length(v_first) not between 1 and 60 then return json_build_object('ok','invalid','field','first_name'); end if;
  if length(v_last)  not between 1 and 60 then return json_build_object('ok','invalid','field','surname'); end if;

  if v_id_type = 'sa_id' then
    if not is_valid_sa_id(v_id_number) then return json_build_object('ok','invalid','field','id_number'); end if;
    v_dob := dob_from_sa_id(v_id_number);
    v_passport := null;
  elsif v_id_type = 'passport' then
    if v_passport !~ '^[A-Z0-9]{6,20}$' then return json_build_object('ok','invalid','field','passport_number'); end if;
    begin v_dob := (f->>'dob')::date; exception when others then v_dob := null; end;
    if v_dob is null or v_dob < date '1900-01-01' or v_dob > current_date then
      return json_build_object('ok','invalid','field','dob');
    end if;
    v_id_number := null;
  else
    return json_build_object('ok','invalid','field','id_type');
  end if;

  if v_gender not in ('male','female','other') then return json_build_object('ok','invalid','field','gender'); end if;

  if v_phone ~ '^0[0-9]{9}$' then v_phone := '+27' || substr(v_phone, 2); end if;
  if v_phone ~ '^27[0-9]{9}$' then v_phone := '+' || v_phone; end if;
  if v_phone !~ '^\+[0-9]{10,15}$' then return json_build_object('ok','invalid','field','phone_number'); end if;

  if v_email = '' then v_email := null;
  elsif v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then
    return json_build_object('ok','invalid','field','email');
  end if;

  if length(v_street) not between 3 and 150 then return json_build_object('ok','invalid','field','street'); end if;
  if length(v_city)   not between 2 and 60  then return json_build_object('ok','invalid','field','city'); end if;
  if v_province not in ('Eastern Cape','Free State','Gauteng','KwaZulu-Natal','Limpopo',
                        'Mpumalanga','North West','Northern Cape','Western Cape') then
    return json_build_object('ok','invalid','field','province');
  end if;
  if v_postal !~ '^[0-9]{4}$' then return json_build_object('ok','invalid','field','postal_code'); end if;

  if v_pay = 'medical_aid' then
    if length(v_aid_name) not between 2 and 80 then return json_build_object('ok','invalid','field','medical_aid_name'); end if;
    if length(v_aid_plan) not between 1 and 80 then return json_build_object('ok','invalid','field','medical_aid_plan'); end if;
    if length(v_aid_no)   not between 3 and 30 then return json_build_object('ok','invalid','field','medical_aid_number'); end if;
    if v_is_main then
      v_dep_code := '00'; v_mm_name := null; v_mm_id := null;
    else
      if v_dep_code !~ '^[0-9]{2}$' or v_dep_code = '00' then return json_build_object('ok','invalid','field','dependant_code'); end if;
      if length(v_mm_name) not between 2 and 120 then return json_build_object('ok','invalid','field','main_member_name'); end if;
      if v_mm_id !~ '^[A-Z0-9]{6,20}$' then return json_build_object('ok','invalid','field','main_member_id'); end if;
    end if;
  elsif v_pay = 'cash' then
    v_aid_name := null; v_aid_plan := null; v_aid_no := null;
    v_dep_code := null; v_mm_name := null; v_mm_id := null;
  else
    return json_build_object('ok','invalid','field','payment_method');
  end if;

  if v_chronic = '' then v_chronic := null; end if;
  if length(coalesce(v_chronic,'')) > 300 then return json_build_object('ok','invalid','field','chronic_illness'); end if;
  if length(v_reason) not between 3 and 500 then return json_build_object('ok','invalid','field','reason'); end if;

  if coalesce((f->>'consent')::boolean, false) is not true then
    return json_build_object('ok','invalid','field','consent');
  end if;

  -- the chosen time must be one of that doctor's free times right now
  begin
    v_doctor := (f->>'doctor_id')::uuid;
    v_slot   := (f->>'slot')::timestamptz;
  exception when others then
    return json_build_object('ok','invalid','field','slot');
  end;
  select full_name into v_doc_name from doctors where id = v_doctor and active = true;
  if v_doc_name is null then return json_build_object('ok','invalid','field','doctor_id'); end if;
  if not exists (
    select 1 from get_available_slots(v_doctor, (v_slot at time zone 'Africa/Johannesburg')::date) s
    where s.slot = v_slot
  ) then
    return json_build_object('ok','taken');
  end if;

  -- ---------- spam limits ----------
  if (select count(*) from bookings
       where booked_via = 'web_form' and created_at > now() - interval '1 hour') >= 40 then
    return json_build_object('ok','limit');
  end if;

  -- ---------- match the patient ----------
  select * into v_by_phone from patients where phone_number = v_phone;
  select * into v_by_ident from patients
   where (v_id_number is not null and id_number = v_id_number)
      or (v_passport  is not null and passport_number = v_passport)
   limit 1;

  if v_by_phone.id is not null then
    -- known phone number: the ID on file must be this person's (or there is none yet)
    if v_by_ident.id is not null and v_by_ident.id <> v_by_phone.id then
      return json_build_object('ok','mismatch');
    end if;
    if (v_by_phone.id_number is not null and v_by_phone.id_number is distinct from v_id_number)
       or (v_by_phone.passport_number is not null and v_by_phone.passport_number is distinct from v_passport) then
      return json_build_object('ok','mismatch');
    end if;
    v_patient := v_by_phone.id;
  elsif v_by_ident.id is not null then
    -- ID already registered under another phone number: reception must check
    return json_build_object('ok','mismatch');
  end if;

  if v_patient is not null and (
       select count(*) from bookings
        where patient_id = v_patient and booked_via = 'web_form'
          and status = 'pending' and chosen_slot > now()) >= 2 then
    return json_build_object('ok','limit');
  end if;

  -- ---------- save the patient ----------
  if v_patient is null then
    insert into patients (patient_name, phone_number, email, id_number, passport_number, dob, gender,
                          address, payment_method, medical_aid_name, medical_aid_plan, medical_aid_number,
                          dependant_code, main_member_name, main_member_id, chronic_illness,
                          consent, consent_at)
    values (v_first || ' ' || v_last, v_phone, v_email, v_id_number, v_passport, v_dob, v_gender,
            concat_ws(', ', v_street, v_city, v_province, v_postal), v_pay,
            v_aid_name, v_aid_plan, v_aid_no, v_dep_code, v_mm_name, v_mm_id, v_chronic,
            true, now())
    returning id into v_patient;
  else
    update patients set
      patient_name       = v_first || ' ' || v_last,
      email              = coalesce(v_email, email),
      id_number          = coalesce(id_number, v_id_number),
      passport_number    = coalesce(passport_number, v_passport),
      dob                = coalesce(v_dob, dob),
      gender             = v_gender,
      address            = concat_ws(', ', v_street, v_city, v_province, v_postal),
      payment_method     = v_pay,
      medical_aid_name   = v_aid_name,
      medical_aid_plan   = v_aid_plan,
      medical_aid_number = v_aid_no,
      dependant_code     = v_dep_code,
      main_member_name   = v_mm_name,
      main_member_id     = v_mm_id,
      chronic_illness    = coalesce(v_chronic, chronic_illness),
      consent            = true,
      consent_at         = now()
    where id = v_patient;
  end if;

  -- ---------- save the booking (pending until reception confirms) ----------
  insert into bookings (patient_id, doctor_id, chosen_slot, ends_at, symptoms, status, booked_via)
  values (v_patient, v_doctor, v_slot, v_slot + interval '30 minutes', v_reason, 'pending', 'web_form')
  returning id into v_booking;

  return json_build_object(
    'ok', 'yes',
    'reference', upper(left(v_booking::text, 8)),
    'doctor_name', v_doc_name,
    'slot_label', to_char(v_slot at time zone 'Africa/Johannesburg', 'FMDay DD FMMonth YYYY, HH24:MI'));
exception
  when exclusion_violation then return json_build_object('ok','taken');
  when unique_violation    then return json_build_object('ok','mismatch');
  when others              then return json_build_object('ok','error');
end;
$$;


-- ------------------------------------------------------------
-- 6. Dashboard: reception can confirm or cancel a pending booking
-- (replaces the version from patch_admin_dashboard.sql)
--   pending   -> confirmed | cancelled   (only before the appointment)
--   confirmed -> cancelled               (only before the appointment)
--   confirmed -> completed | no_show     (only after it has started)
-- ok = yes | denied | invalid | notfound | notallowed | error
-- ------------------------------------------------------------
create or replace function admin_set_booking_status(
  p_token text, p_booking_id text, p_status text
) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user text := admin_check_token(p_token);
  v_id   uuid;
  v_b    bookings%rowtype;
begin
  if v_user is null then return json_build_object('ok', 'denied'); end if;
  if coalesce(p_status, '') not in ('confirmed', 'completed', 'no_show', 'cancelled') then
    return json_build_object('ok', 'invalid');
  end if;

  begin v_id := p_booking_id::uuid; exception when others then return json_build_object('ok', 'invalid'); end;

  select * into v_b from bookings where id = v_id;
  if not found then return json_build_object('ok', 'notfound'); end if;

  if v_b.status = 'pending' then
    if p_status not in ('confirmed', 'cancelled') or v_b.chosen_slot <= now() then
      return json_build_object('ok', 'notallowed');
    end if;
  elsif v_b.status = 'confirmed' then
    if p_status = 'confirmed' then return json_build_object('ok', 'notallowed'); end if;
    if p_status = 'cancelled' and v_b.chosen_slot <= now() then return json_build_object('ok', 'notallowed'); end if;
    if p_status in ('completed', 'no_show') and v_b.chosen_slot > now() then return json_build_object('ok', 'notallowed'); end if;
  else
    return json_build_object('ok', 'notallowed');
  end if;

  update bookings set status = p_status where id = v_id;
  insert into admin_audit (username, action, detail)
  values (v_user, 'set_status', v_id::text || ' -> ' || p_status);

  return json_build_object('ok', 'yes', 'status', p_status);
exception when others then
  return json_build_object('ok', 'error');
end;
$$;


-- ------------------------------------------------------------
-- 7. Permissions
-- The three form_ functions may be called with the publishable key.
-- form_parse_date is internal only.
-- ------------------------------------------------------------
revoke execute on function form_parse_date(text) from public, anon, authenticated;

revoke execute on function form_get_available_doctors(text)       from public;
revoke execute on function form_get_available_slots(text, text)   from public;
revoke execute on function form_submit_booking(jsonb)             from public;
grant  execute on function form_get_available_doctors(text)       to anon, authenticated, service_role;
grant  execute on function form_get_available_slots(text, text)   to anon, authenticated, service_role;
grant  execute on function form_submit_booking(jsonb)             to anon, authenticated, service_role;

revoke execute on function admin_set_booking_status(text, text, text) from public;
grant  execute on function admin_set_booking_status(text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ------------------------------------------------------------
-- CHECK (run these one at a time)
--   select form_get_available_doctors(to_char(current_date + 1, 'YYYY-MM-DD'));
--   select form_get_available_slots('<a doctor_id from above>', to_char(current_date + 1, 'YYYY-MM-DD'));
--
-- Form bookings waiting for reception:
--   select b.chosen_slot, p.patient_name, p.phone_number
--   from bookings b join patients p on p.id = b.patient_id
--   where b.booked_via = 'web_form' and b.status = 'pending'
--   order by b.chosen_slot;
-- ------------------------------------------------------------
