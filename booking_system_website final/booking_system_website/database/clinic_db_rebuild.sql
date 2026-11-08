-- ============================================================
-- CLINIC BOOKING SYSTEM: FULL REBUILD (teardown + clean create)
--
-- !! WARNING !!  Part 1 DELETES ALL patients, bookings, doctors and
-- message_log rows. Only run this if everything in there is test data.
-- It keeps app_settings (so your Zapier webhook URL survives) and the
-- extensions. Every row gets a NEW uuid, so any saved test inputs that
-- hold old doctor / patient / booking ids (Preview defaults in
-- Infobip, Zapier test data) must be refreshed afterwards.
--
-- Run top to bottom in the Supabase SQL Editor.
-- ============================================================


-- ============================================================
-- PART 0. EXTENSIONS
-- ============================================================
create extension if not exists pgcrypto;    -- gen_random_uuid()
create extension if not exists btree_gist;  -- double-booking guard
create extension if not exists pg_cron;     -- scheduled reminders
create extension if not exists pg_net;      -- outbound HTTP from pg_cron


-- ============================================================
-- PART 1. TEARDOWN
-- ============================================================

-- 1a. remove every old reminder job (7d / 24h / 1h / 10m); harmless if none exist
select cron.unschedule(jobname)
from cron.job
where jobname in ('reminder-7d', 'reminder-24h', 'reminder-1h', 'reminder-10m');

-- 1b. optional view and tables (app_settings is deliberately kept)
drop view if exists upcoming_appointments cascade;
drop table if exists message_log, bookings, patients, doctors cascade;

-- 1c. every function this project has ever used, whatever its signature
do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'set_updated_at',
        'get_available_slots', 'get_available_doctors',
        'get_available_doctors_text', 'get_available_slots_text',
        'get_doctor_by_choice', 'get_slot_by_choice',
        'get_patient_bookings', 'get_patient_bookings_text', 'cancel_booking_by_choice',
        'lookup_patient', 'upsert_patient',
        'create_booking', 'verify_and_list', 'resolve_booking',
        'cancel_booking_by_id', 'reschedule_booking',
        'is_valid_sa_id', 'set_patient_id', 'find_patient_by_id',
        'dob_from_sa_id', 'set_dob_from_id')
  loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end
$do$;


-- ============================================================
-- PART 2. TABLES
-- ============================================================

-- 2a. Doctors
create table doctors (
  id            uuid primary key default gen_random_uuid(),
  full_name     text not null,
  specialty     text,
  phone_number  text,
  email         text,
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

-- 2b. Patients: the uuid is the key; the phone number is how the bot finds them;
--     id_number (13-digit South African ID) lets the doctor open the patient file.
create table patients (
  id               uuid primary key default gen_random_uuid(),
  patient_name     text not null,
  dob              date,
  phone_number     text not null unique,
  email            text,
  id_number        text,
  chronic_illness  text,
  consent          boolean not null default false,
  consent_at       timestamptz,
  created_at       timestamptz not null default now(),
  constraint phone_e164_check check (phone_number ~ '^\+[0-9]{10,15}$'),
  constraint patients_id_number_format check (id_number is null or id_number ~ '^[0-9]{13}$')
);

-- one ID number per patient record (blank values are not compared)
create unique index patients_id_number_key on patients (id_number) where id_number is not null;

-- 2c. Bookings
create table bookings (
  id                    uuid primary key default gen_random_uuid(),
  patient_id            uuid not null references patients(id) on delete cascade,
  doctor_id             uuid not null references doctors(id),
  symptoms              text,
  chosen_slot           timestamptz not null,     -- start time
  ends_at               timestamptz not null,     -- end time
  status                text not null default 'pending'
                         check (status in ('pending','confirmed','reschedule_requested',
                                           'cancelled','completed','no_show')),
  reminder_24h_sent_at  timestamptz,              -- null = reminder not sent yet
  reminder_1h_sent_at   timestamptz,              -- null = 1-hour reminder not sent yet
  calendar_event_id     text,
  appointment_range     tstzrange
                         generated always as (tstzrange(chosen_slot, ends_at)) stored,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint bookings_time_order check (ends_at > chosen_slot),
  -- a doctor can never have two live bookings that overlap in time
  constraint no_doctor_double_booking exclude using gist (
    doctor_id with =,
    appointment_range with &&
  ) where (status not in ('cancelled', 'no_show'))
);

create index bookings_slot_idx    on bookings (chosen_slot) where status in ('pending','confirmed');
create index bookings_patient_idx on bookings (patient_id);
create index bookings_doctor_idx  on bookings (doctor_id);

-- 2d. Message log (written by Zapier)
create table message_log (
  id                  uuid primary key default gen_random_uuid(),
  booking_id          uuid references bookings(id) on delete set null,
  direction           text not null check (direction in ('outbound','inbound')),
  kind                text not null,
  infobip_message_id  text,
  delivery_status     text,
  payload             jsonb,
  created_at          timestamptz not null default now()
);

-- 2e. Settings (kept across rebuilds; holds the Zapier webhook URL)
create table if not exists app_settings (
  key    text primary key,
  value  text not null
);

-- >>> SET YOUR ZAPIER CATCH HOOK URL HERE (an existing value is kept) <<<
insert into app_settings (key, value)
values ('zapier_reminder_webhook', 'https://hooks.zapier.com/hooks/catch/REPLACE_ME/reminders/')
on conflict (key) do nothing;
-- to change it later:
--   update app_settings set value = 'https://...' where key = 'zapier_reminder_webhook';


-- ============================================================
-- PART 3. TRIGGER + ROW LEVEL SECURITY
-- ============================================================
create or replace function set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end;
$$ language plpgsql;

create trigger bookings_updated_at
before update on bookings
for each row execute function set_updated_at();

-- RLS on, no policies: only the service role (Infobip + Zapier secret key) can touch the data
alter table doctors      enable row level security;
alter table patients     enable row level security;
alter table bookings     enable row level security;
alter table message_log  enable row level security;
alter table app_settings enable row level security;


-- ============================================================
-- PART 4. FUNCTIONS
-- ============================================================

-- ---------- availability ----------

-- Every open 30-minute slot for a doctor on a date.
-- 09:00-17:00, lunch 12:00-13:00 blocked, no past times, no clashes, 60-day window.
create or replace function get_available_slots(p_doctor_id uuid, p_date date)
returns table(slot timestamptz) as $$
  select s as slot
  from generate_series(
    (p_date + time '09:00') at time zone 'Africa/Johannesburg',
    (p_date + time '16:30') at time zone 'Africa/Johannesburg',
    interval '30 minutes'
  ) as s
  where p_date <= current_date + 60
    -- and extract(isodow from p_date) < 6   -- uncomment if the clinic is closed on weekends
    and s > now()
    and ((s at time zone 'Africa/Johannesburg')::time < time '12:00'
         or (s at time zone 'Africa/Johannesburg')::time >= time '13:00')
    and not exists (
      select 1 from bookings b
      where b.doctor_id = p_doctor_id
        and b.status not in ('cancelled','no_show')
        and tstzrange(b.chosen_slot, b.ends_at) && tstzrange(s, s + interval '30 minutes')
    )
  order by s;
$$ language sql stable;

-- Doctors with at least one open slot on a date
create or replace function get_available_doctors(p_date date)
returns table(doctor_id uuid, full_name text, specialty text) as $$
  select d.id, d.full_name, d.specialty
  from doctors d
  where d.active = true
    and exists (select 1 from get_available_slots(d.id, p_date))
  order by d.full_name;
$$ language sql stable;

-- ---------- chatbot helpers: booking ----------

-- Numbered doctor list. Date arrives as text so a bad date returns INVALID, not an error.
create or replace function get_available_doctors_text(p_date text) returns json as $$
declare d date;
begin
  if p_date is null or left(trim(p_date),10) !~ '^\d{4}-\d{2}-\d{2}$' then
    return json_build_object('list','INVALID');
  end if;
  begin
    d := left(trim(p_date),10)::date;
  exception when others then
    return json_build_object('list','INVALID');
  end;
  return (
    select json_build_object('list', coalesce(
      string_agg(format('%s. %s (%s)', rn, full_name, coalesce(specialty,'General')), E'\n' order by rn), 'NONE'))
    from (select full_name, specialty, row_number() over (order by full_name) as rn
          from get_available_doctors(d)) ranked
  );
end;
$$ language plpgsql stable;

-- Turn the number the patient typed into a doctor (plain 1-2 digit numbers only)
create or replace function get_doctor_by_choice(p_date date, p_choice text) returns json as $$
  select coalesce(
    (select json_build_object('ok','yes','doctor_id', doctor_id::text, 'doctor_name', full_name)
     from (select d.doctor_id, d.full_name, row_number() over (order by d.full_name) as rn
           from get_available_doctors(p_date) d) ranked
     where rn = case when trim(coalesce(p_choice,'')) ~ '^[0-9]{1,2}$'
                     then trim(p_choice)::int else -1 end),
    json_build_object('ok','no','doctor_id','','doctor_name',''));
$$ language sql stable;

-- Numbered time list, NONE when empty
create or replace function get_available_slots_text(p_doctor_id uuid, p_date date) returns json as $$
  select json_build_object('list', coalesce(
    string_agg(format('%s. %s', rn, to_char(slot at time zone 'Africa/Johannesburg', 'HH24:MI')), E'\n' order by rn), 'NONE'))
  from (select slot, row_number() over (order by slot) as rn
        from get_available_slots(p_doctor_id, p_date)) ranked;
$$ language sql stable;

-- Turn the number the patient typed into a time
create or replace function get_slot_by_choice(p_doctor_id uuid, p_date date, p_choice text) returns json as $$
  select coalesce(
    (select json_build_object('ok','yes','chosen_slot', slot, 'chosen_slot_end', slot + interval '30 minutes',
            'slot_label', to_char(slot at time zone 'Africa/Johannesburg','Dy DD Mon, HH24:MI'))
     from (select s.slot, row_number() over (order by s.slot) as rn
           from get_available_slots(p_doctor_id, p_date) s) ranked
     where rn = case when trim(coalesce(p_choice,'')) ~ '^[0-9]{1,2}$'
                     then trim(p_choice)::int else -1 end),
    json_build_object('ok','no','chosen_slot','','chosen_slot_end','','slot_label',''));
$$ language sql stable;

-- ---------- patients ----------

-- Is this phone number a known patient, and is an ID number on file?
create or replace function lookup_patient(p_phone text) returns json as $$
  select coalesce(
    (select json_build_object('found','yes','patient_uuid', id::text, 'patient_name', patient_name,
            'has_id', case when id_number is not null then 'yes' else 'no' end)
     from patients where phone_number = p_phone limit 1),
    json_build_object('found','no','patient_uuid','','patient_name','','has_id','no'));
$$ language sql stable;

-- Create or update a patient by phone number. ok = yes | invalid | error
create or replace function upsert_patient(
  p_phone text, p_name text, p_dob text, p_email text, p_chronic text
) returns json as $$
declare v_id uuid; v_dob date;
begin
  if p_phone is null or p_phone !~ '^\+[0-9]{10,15}$'
     or length(trim(coalesce(p_name,''))) < 2 then
    return json_build_object('ok','invalid','patient_uuid','');
  end if;

  begin v_dob := p_dob::date; exception when others then v_dob := null; end;
  if v_dob < date '1900-01-01' or v_dob > current_date then v_dob := null; end if;

  insert into patients (phone_number, patient_name, dob, email, chronic_illness, consent, consent_at)
  values (p_phone, trim(p_name), v_dob,
          case when lower(trim(coalesce(p_email,''))) in ('','none','unset') then null
               else lower(trim(p_email)) end,
          nullif(trim(coalesce(p_chronic,'')),''), true, now())
  on conflict (phone_number) do update
    set patient_name    = excluded.patient_name,
        dob             = coalesce(excluded.dob, patients.dob),
        email           = coalesce(excluded.email, patients.email),
        chronic_illness = coalesce(excluded.chronic_illness, patients.chronic_illness)
  returning id into v_id;

  return json_build_object('ok','yes','patient_uuid', v_id::text);
exception when others then
  return json_build_object('ok','error','patient_uuid','');
end;
$$ language plpgsql;

-- Full validity check for a South African ID number:
-- 13 digits, a real YYMMDD date, citizenship digit 0 or 1, Luhn checksum.
create or replace function is_valid_sa_id(p_id text) returns boolean as $$
declare s int := 0; d int; k int; yy int; mm int; dd int; okdate boolean := false;
begin
  if p_id is null or p_id !~ '^[0-9]{13}$' then return false; end if;
  if substr(p_id,11,1) not in ('0','1') then return false; end if;

  yy := substr(p_id,1,2)::int; mm := substr(p_id,3,2)::int; dd := substr(p_id,5,2)::int;
  begin perform make_date(1900 + yy, mm, dd); okdate := true; exception when others then null; end;
  if not okdate then
    begin perform make_date(2000 + yy, mm, dd); okdate := true; exception when others then null; end;
  end if;
  if not okdate then return false; end if;

  for k in 0..12 loop
    d := substr(p_id, 13 - k, 1)::int;
    if k % 2 = 1 then
      d := d * 2;
      if d > 9 then d := d - 9; end if;
    end if;
    s := s + d;
  end loop;
  return s % 10 = 0;
end;
$$ language plpgsql immutable;

-- A South African ID starts with the date of birth (YYMMDD), so the bot does not ask for it.
-- Century rule: assume 20YY; if that date is still in the future it must be 19YY.
create or replace function dob_from_sa_id(p_id text) returns date as $$
declare yy int; mm int; dd int; d date;
begin
  if p_id is null or p_id !~ '^[0-9]{13}$' then return null; end if;
  yy := substr(p_id,1,2)::int; mm := substr(p_id,3,2)::int; dd := substr(p_id,5,2)::int;
  begin d := make_date(2000 + yy, mm, dd); exception when others then d := null; end;
  if d is null or d > current_date then
    begin d := make_date(1900 + yy, mm, dd); exception when others then d := null; end;
  end if;
  return d;
end;
$$ language plpgsql stable;

-- Whenever an id_number is saved, fill in dob from it
create or replace function set_dob_from_id() returns trigger as $$
begin
  if new.id_number is not null then
    new.dob := coalesce(dob_from_sa_id(new.id_number), new.dob);
  end if;
  return new;
end;
$$ language plpgsql;

create trigger patients_dob_from_id
before insert or update of id_number on patients
for each row execute function set_dob_from_id();

-- Save the ID number for the patient with this phone number.
-- ok = yes | invalid | duplicate | nopatient | error
create or replace function set_patient_id(p_phone text, p_id text) returns json as $$
declare v_id text; v_pat patients%rowtype;
begin
  v_id := regexp_replace(coalesce(p_id,''), '[ -]', '', 'g');
  select * into v_pat from patients where phone_number = p_phone;
  if not found then return json_build_object('ok','nopatient'); end if;
  if not is_valid_sa_id(v_id) then return json_build_object('ok','invalid'); end if;
  update patients set id_number = v_id where id = v_pat.id;
  return json_build_object('ok','yes');
exception
  when unique_violation then return json_build_object('ok','duplicate');
  when others then return json_build_object('ok','error');
end;
$$ language plpgsql;

-- Before registering an unknown phone number: does this ID number already belong to a patient?
-- ok = new | found | invalid | error
create or replace function find_patient_by_id(p_id text) returns json as $$
declare v_id text;
begin
  v_id := regexp_replace(coalesce(p_id,''), '[ -]', '', 'g');
  if not is_valid_sa_id(v_id) then
    return json_build_object('ok','invalid');
  end if;
  if exists (select 1 from patients where id_number = v_id) then
    return json_build_object('ok','found');
  end if;
  return json_build_object('ok','new');
exception when others then
  return json_build_object('ok','error');
end;
$$ language plpgsql stable;

-- ---------- bookings ----------

-- Save a booking. ok = yes | taken (someone got the slot first) | error (see detail)
create or replace function create_booking(
  p_patient_id text, p_doctor_id text, p_slot text, p_end text, p_symptoms text
) returns json as $$
declare v_id uuid;
begin
  insert into bookings (patient_id, doctor_id, chosen_slot, ends_at, symptoms, status)
  values (p_patient_id::uuid, p_doctor_id::uuid, p_slot::timestamptz, p_end::timestamptz, p_symptoms, 'confirmed')
  returning id into v_id;
  return json_build_object('ok', 'yes', 'booking_id', v_id::text, 'detail', '');
exception
  when exclusion_violation then
    return json_build_object('ok', 'taken', 'booking_id', '', 'detail', '');
  when others then
    return json_build_object('ok', 'error', 'booking_id', '', 'detail', sqlstate || ': ' || sqlerrm);
end;
$$ language plpgsql;

-- A patient's upcoming confirmed bookings, numbered
create or replace function get_patient_bookings(p_phone text)
returns table(idx int, booking_id uuid, doctor_name text, chosen_slot timestamptz) as $$
  select row_number() over (order by b.chosen_slot)::int, b.id, d.full_name, b.chosen_slot
  from bookings b
  join patients p on p.id = b.patient_id
  join doctors d on d.id = b.doctor_id
  where p.phone_number = p_phone
    and b.status = 'confirmed'
    and b.chosen_slot > now();
$$ language sql stable;

-- Verify phone + ID number, then return the upcoming bookings.
-- (A SA ID already contains the date of birth, so a typed date proves little.)
-- Every failure (unknown number, no ID on file, wrong ID) returns ok = "no",
-- so the bot cannot be used to discover who is registered.
create or replace function verify_and_list(p_phone text, p_id text) returns json as $$
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

-- Turn the number the patient typed into a real booking
create or replace function resolve_booking(p_phone text, p_choice text) returns json as $$
  select coalesce(
    (select json_build_object('ok','yes','booking_id', booking_id::text,
            'label', to_char(chosen_slot at time zone 'Africa/Johannesburg','Dy DD Mon, HH24:MI') || ' with ' || doctor_name)
     from get_patient_bookings(p_phone)
     where idx = case when trim(coalesce(p_choice,'')) ~ '^[0-9]{1,2}$'
                      then trim(p_choice)::int else -1 end),
    json_build_object('ok','no','booking_id','','label',''));
$$ language sql stable;

-- Cancel one booking: it must belong to the phone number, be confirmed and still upcoming.
-- Safe to call twice: the second call returns ok = "no".
create or replace function cancel_booking_by_id(p_phone text, p_booking_id text) returns json as $$
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

-- Move a booking: create the new one and cancel the old one in a single step.
-- If the new time is taken, the old booking is left exactly as it was.
create or replace function reschedule_booking(
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


-- ============================================================
-- PART 5. PERMISSIONS
-- Only the service role (your Infobip + Zapier secret key) may call these
-- functions through the API. The public/anon key cannot.
-- If the bot ever returns "permission denied" after this, comment this block out.
-- ============================================================
do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'get_available_slots', 'get_available_doctors',
        'get_available_doctors_text', 'get_available_slots_text',
        'get_doctor_by_choice', 'get_slot_by_choice',
        'get_patient_bookings', 'lookup_patient', 'upsert_patient',
        'create_booking', 'verify_and_list', 'resolve_booking',
        'cancel_booking_by_id', 'reschedule_booking',
        'is_valid_sa_id', 'set_patient_id', 'find_patient_by_id', 'dob_from_sa_id')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end
$do$;


-- ============================================================
-- PART 6. REMINDERS: 24 HOURS AND 1 HOUR
-- Every 10 minutes, find confirmed bookings between 23 and 24 hours away
-- that have not been reminded, and post them to the Zapier webhook.
-- The wider window means one missed run does not mean a missed reminder.
-- Zapier sets reminder_24h_sent_at after sending. If that step fails the
-- reminder repeats on the next run: a duplicate is better than a missed one.
-- The payload deliberately leaves out symptoms and ID number.
-- ============================================================
select cron.schedule(
  'reminder-24h',
  '*/10 * * * *',
  $$
  select net.http_post(
    url := (select value from app_settings where key = 'zapier_reminder_webhook'),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object(
      'booking_id', b.id,
      'id', b.id,
      'reminder_type', '24h',
      'chosen_slot', b.chosen_slot,
      'ends_at', b.ends_at,
      'status', b.status,
      'doctor_name', d.full_name,
      'patient_name', p.patient_name,
      'phone_number', p.phone_number
    )
  )
  from bookings b
  join doctors d on d.id = b.doctor_id
  join patients p on p.id = b.patient_id
  where b.status = 'confirmed'
    and b.reminder_24h_sent_at is null
    and b.chosen_slot >  now() + interval '23 hours'
    and b.chosen_slot <= now() + interval '24 hours';
  $$
);

-- 1-hour reminder: every 5 minutes, confirmed bookings that start in 45 to 60 minutes.
-- A booking made less than 45 minutes ahead gets no 1-hour reminder.
select cron.schedule(
  'reminder-1h',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := (select value from app_settings where key = 'zapier_reminder_webhook'),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object(
      'booking_id', b.id,
      'id', b.id,
      'reminder_type', '1h',
      'chosen_slot', b.chosen_slot,
      'ends_at', b.ends_at,
      'status', b.status,
      'doctor_name', d.full_name,
      'patient_name', p.patient_name,
      'phone_number', p.phone_number
    )
  )
  from bookings b
  join doctors d on d.id = b.doctor_id
  join patients p on p.id = b.patient_id
  where b.status = 'confirmed'
    and b.reminder_1h_sent_at is null
    and b.chosen_slot >  now() + interval '45 minutes'
    and b.chosen_slot <= now() + interval '1 hour';
  $$
);


-- ============================================================
-- PART 7. STARTER DATA
-- ============================================================

-- 7a. The doctor the bot needs in order to offer anything. Add the clinic's real doctors here.
insert into doctors (full_name, specialty)
select 'Dr. D Khumalo', 'General Practice'
where not exists (select 1 from doctors where full_name = 'Dr. D Khumalo');

-- 7b. OPTIONAL test patients and bookings (tomorrow 15:00 and 16:00).
--     To use, remove the leading "-- " from each line.
-- insert into patients (patient_name, phone_number, dob, id_number, consent, consent_at) values
--   ('Test Patient One', '+27820000001', '2000-01-01', '0001015009085', true, now()),
--   ('Test Patient Two', '+27820000002', '2002-11-03', '0211035009086', true, now());
--
-- insert into bookings (patient_id, doctor_id, chosen_slot, ends_at, status, symptoms)
-- select p.id, d.id,
--        (((now() at time zone 'Africa/Johannesburg')::date + 1) + time '15:00') at time zone 'Africa/Johannesburg',
--        (((now() at time zone 'Africa/Johannesburg')::date + 1) + time '16:00') at time zone 'Africa/Johannesburg',
--        'confirmed', 'Test booking'
-- from patients p, doctors d
-- where p.phone_number = '+27820000001' and d.full_name = 'Dr. D Khumalo'
-- union all
-- select p.id, d.id,
--        (((now() at time zone 'Africa/Johannesburg')::date + 1) + time '16:00') at time zone 'Africa/Johannesburg',
--        (((now() at time zone 'Africa/Johannesburg')::date + 1) + time '17:00') at time zone 'Africa/Johannesburg',
--        'confirmed', 'Test booking'
-- from patients p, doctors d
-- where p.phone_number = '+27820000002' and d.full_name = 'Dr. D Khumalo';


-- ============================================================
-- PART 8. REFRESH THE API + VERIFY
-- ============================================================
notify pgrst, 'reload schema';

-- Run these one at a time afterwards:
-- select jobname, schedule from cron.job;
--     expect two rows: reminder-1h and reminder-24h
-- select value from app_settings where key = 'zapier_reminder_webhook';
--     expect your real Zapier URL, not REPLACE_ME
-- select get_available_doctors_text('2026-02-31');
--     expect {"list":"INVALID"}
-- select get_available_doctors_text((current_date + 3)::text);
--     expect a numbered doctor list, or NONE if that day is a closed weekend
-- select upsert_patient('+27710000001', 'Test Patient', '2001-11-01', 'none', 'None');
--     expect {"ok":"yes","patient_uuid":"..."}
-- select is_valid_sa_id('0001015009085');
--     expect true
-- select lookup_patient('+27710000001');
--     expect found yes, has_id no
-- delete from patients where phone_number = '+27710000001';   -- clean up
