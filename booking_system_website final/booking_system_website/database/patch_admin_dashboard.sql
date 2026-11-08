-- ============================================================
-- PATCH: reception dashboard (admin.html)
-- Safe to run on the live database. Adds two tables and eight functions.
-- Changes no existing data.
--
-- REQUIRES patch_doctors_admin.sql to have been run first: the dashboard
-- uses the same admin username and password (stored hashed in admin_users).
--
-- How it stays safe:
--  * The page only holds your project URL and the PUBLISHABLE key.
--  * Signing in returns a random token that lasts 2 hours. Only a hash of it
--    is stored, and every data function refuses a missing or expired token.
--  * The tables stay locked. Nothing is readable except through these functions.
--  * Viewing a patient file, changing a booking status and signing in are
--    written to admin_audit.
-- ============================================================

do $do$
begin
  if to_regclass('public.admin_users') is null then
    raise exception 'Run patch_doctors_admin.sql first. It creates the admin login this dashboard uses.';
  end if;
end
$do$;

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- Tables (not readable through the API)
-- ------------------------------------------------------------
create table if not exists admin_sessions (
  token_hash  text primary key,
  username    text not null,
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now()
);
alter table admin_sessions enable row level security;
revoke all on admin_sessions from anon, authenticated;

create table if not exists admin_audit (
  id        bigserial primary key,
  happened_at  timestamptz not null default now(),
  username  text not null,
  action    text not null,
  detail    text
);
alter table admin_audit enable row level security;
revoke all on admin_audit from anon, authenticated;


-- ------------------------------------------------------------
-- Internal helper: who does this token belong to? (null = nobody)
-- Not callable from the browser.
-- ------------------------------------------------------------
create or replace function admin_check_token(p_token text) returns text
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select username
  from admin_sessions
  where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
    and expires_at > now();
$$;


-- ------------------------------------------------------------
-- Sign in / sign out
-- ------------------------------------------------------------
create or replace function admin_login(p_username text, p_password text) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_hash text; v_token text;
begin
  select password_hash into v_hash from admin_users where username = p_username;
  if v_hash is null or crypt(coalesce(p_password, ''), v_hash) <> v_hash then
    insert into admin_audit (username, action) values (left(coalesce(p_username, ''), 60), 'login_failed');
    perform pg_sleep(1);   -- slows down password guessing
    return json_build_object('ok', 'denied');
  end if;

  delete from admin_sessions where expires_at < now();
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into admin_sessions (token_hash, username, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), p_username, now() + interval '2 hours');
  insert into admin_audit (username, action) values (p_username, 'login');

  return json_build_object('ok', 'yes', 'token', v_token, 'username', p_username, 'minutes', 120);
exception when others then
  return json_build_object('ok', 'error');
end;
$$;

create or replace function admin_logout(p_token text) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  delete from admin_sessions
  where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  return json_build_object('ok', 'yes');
end;
$$;


-- ------------------------------------------------------------
-- Overview: numbers, a 14-day chart and today's schedule (Johannesburg time)
-- ------------------------------------------------------------
create or replace function admin_overview(p_token text) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user   text := admin_check_token(p_token);
  v_today  date := (now() at time zone 'Africa/Johannesburg')::date;
  v_result json;
begin
  if v_user is null then return json_build_object('ok', 'denied'); end if;

  select json_build_object(
    'ok', 'yes',
    'today_confirmed', (select count(*) from bookings
                         where status = 'confirmed'
                           and (chosen_slot at time zone 'Africa/Johannesburg')::date = v_today),
    'week_confirmed',  (select count(*) from bookings
                         where status = 'confirmed'
                           and (chosen_slot at time zone 'Africa/Johannesburg')::date between v_today and v_today + 6),
    'patients_total',  (select count(*) from patients),
    'patients_new_7d', (select count(*) from patients where created_at >= now() - interval '7 days'),
    'missing_id',      (select count(*) from patients where id_number is null),
    'cancelled_30d',   (select count(*) from bookings
                         where status = 'cancelled' and updated_at >= now() - interval '30 days'),
    'no_show_30d',     (select count(*) from bookings
                         where status = 'no_show' and updated_at >= now() - interval '30 days'),
    'by_day', (
      select coalesce(json_agg(json_build_object('day', to_char(g.d, 'YYYY-MM-DD'), 'n', coalesce(c.n, 0)) order by g.d), '[]'::json)
      from generate_series(v_today::timestamp, (v_today + 13)::timestamp, interval '1 day') as g(d)
      left join (
        select (chosen_slot at time zone 'Africa/Johannesburg')::date as d, count(*) as n
        from bookings
        where status = 'confirmed'
        group by 1
      ) c on c.d = g.d::date
    ),
    'today_schedule', (
      select coalesce(json_agg(json_build_object('time', b.chosen_slot, 'patient', p.patient_name,
                                                 'doctor', d.full_name, 'status', b.status) order by b.chosen_slot), '[]'::json)
      from bookings b
      join patients p on p.id = b.patient_id
      join doctors d on d.id = b.doctor_id
      where b.status in ('confirmed', 'completed', 'no_show')
        and (b.chosen_slot at time zone 'Africa/Johannesburg')::date = v_today
    )
  ) into v_result;

  return v_result;
end;
$$;


-- ------------------------------------------------------------
-- Bookings in a date range (max 93 days, max 500 rows)
-- p_status: all | pending | confirmed | completed | cancelled | no_show
-- p_doctor: all | a doctor's full name
-- ------------------------------------------------------------
create or replace function admin_list_bookings(
  p_token text, p_from text, p_to text, p_status text, p_doctor text
) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user  text := admin_check_token(p_token);
  v_today date := (now() at time zone 'Africa/Johannesburg')::date;
  v_from  date;
  v_to    date;
  v_rows  json;
begin
  if v_user is null then return json_build_object('ok', 'denied'); end if;

  begin v_from := p_from::date; exception when others then v_from := null; end;
  begin v_to   := p_to::date;   exception when others then v_to   := null; end;
  v_from := coalesce(v_from, v_today);
  v_to   := coalesce(v_to, v_from + 14);
  if v_to < v_from then v_to := v_from; end if;
  if v_to > v_from + 92 then v_to := v_from + 92; end if;

  select coalesce(json_agg(r order by r.chosen_slot), '[]'::json) into v_rows
  from (
    select b.id as booking_id, b.chosen_slot, b.ends_at, b.status, b.symptoms,
           p.id as patient_id, p.patient_name, p.phone_number, d.full_name as doctor
    from bookings b
    join patients p on p.id = b.patient_id
    join doctors d on d.id = b.doctor_id
    where (b.chosen_slot at time zone 'Africa/Johannesburg')::date between v_from and v_to
      and (coalesce(p_status, '') in ('', 'all') or b.status = p_status)
      and (coalesce(p_doctor, '') in ('', 'all') or d.full_name = p_doctor)
    order by b.chosen_slot
    limit 500
  ) r;

  return json_build_object('ok', 'yes', 'from', v_from, 'to', v_to, 'rows', v_rows);
end;
$$;


-- ------------------------------------------------------------
-- Change a booking's status.
--   cancelled           only for a confirmed booking that has not started yet
--   completed / no_show only for a confirmed booking that has already started
-- Cancelling frees the slot. The patient is NOT notified automatically.
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
  if coalesce(p_status, '') not in ('completed', 'no_show', 'cancelled') then
    return json_build_object('ok', 'invalid');
  end if;

  begin v_id := p_booking_id::uuid; exception when others then return json_build_object('ok', 'invalid'); end;

  select * into v_b from bookings where id = v_id;
  if not found then return json_build_object('ok', 'notfound'); end if;
  if v_b.status <> 'confirmed' then return json_build_object('ok', 'notallowed'); end if;
  if p_status = 'cancelled' and v_b.chosen_slot <= now() then return json_build_object('ok', 'notallowed'); end if;
  if p_status in ('completed', 'no_show') and v_b.chosen_slot > now() then return json_build_object('ok', 'notallowed'); end if;

  update bookings set status = p_status where id = v_id;
  insert into admin_audit (username, action, detail)
  values (v_user, 'set_status', v_id::text || ' -> ' || p_status);

  return json_build_object('ok', 'yes', 'status', p_status);
exception when others then
  return json_build_object('ok', 'error');
end;
$$;


-- ------------------------------------------------------------
-- Find patients by name, cellphone number or ID number (max 50).
-- The ID number is masked here; the full number is only in the detail view.
-- ------------------------------------------------------------
create or replace function admin_search_patients(p_token text, p_q text) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user   text := admin_check_token(p_token);
  v_q      text := lower(trim(coalesce(p_q, '')));
  v_digits text := regexp_replace(coalesce(p_q, ''), '[^0-9]', '', 'g');
  v_phone  text;
  v_rows   json;
begin
  if v_user is null then return json_build_object('ok', 'denied'); end if;

  -- 0821234567 is stored as +27821234567
  v_phone := case when v_digits like '0%' then '27' || substr(v_digits, 2) else v_digits end;

  select coalesce(json_agg(r order by r.created_at desc), '[]'::json) into v_rows
  from (
    select p.id as patient_id, p.patient_name, p.phone_number,
           case when p.id_number is null then null else repeat('*', 9) || right(p.id_number, 4) end as id_masked,
           p.created_at,
           (select count(*) from bookings b
             where b.patient_id = p.id and b.status = 'confirmed' and b.chosen_slot > now()) as upcoming
    from patients p
    where v_q = ''
       or lower(p.patient_name) like '%' || v_q || '%'
       or (v_digits <> '' and (p.phone_number like '%' || v_phone || '%'
                               or coalesce(p.id_number, '') like '%' || v_digits || '%'))
    order by p.created_at desc
    limit 50
  ) r;

  return json_build_object('ok', 'yes', 'rows', v_rows);
end;
$$;


-- ------------------------------------------------------------
-- One patient's full file plus their last 25 bookings. Every view is logged.
-- ------------------------------------------------------------
create or replace function admin_patient_detail(p_token text, p_patient_id text) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user text := admin_check_token(p_token);
  v_id   uuid;
  v_p    patients%rowtype;
  v_hist json;
begin
  if v_user is null then return json_build_object('ok', 'denied'); end if;

  begin v_id := p_patient_id::uuid; exception when others then return json_build_object('ok', 'invalid'); end;

  select * into v_p from patients where id = v_id;
  if not found then return json_build_object('ok', 'notfound'); end if;

  select coalesce(json_agg(h order by h.chosen_slot desc), '[]'::json) into v_hist
  from (
    select b.id as booking_id, b.chosen_slot, b.status, b.symptoms, d.full_name as doctor
    from bookings b
    join doctors d on d.id = b.doctor_id
    where b.patient_id = v_id
    order by b.chosen_slot desc
    limit 25
  ) h;

  insert into admin_audit (username, action, detail) values (v_user, 'view_patient', v_id::text);

  return json_build_object(
    'ok', 'yes',
    'patient', json_build_object(
      'patient_id', v_p.id, 'patient_name', v_p.patient_name, 'phone_number', v_p.phone_number,
      'email', v_p.email, 'id_number', v_p.id_number, 'dob', v_p.dob,
      'chronic_illness', v_p.chronic_illness, 'consent', v_p.consent,
      'consent_at', v_p.consent_at, 'created_at', v_p.created_at),
    'history', v_hist);
exception when others then
  return json_build_object('ok', 'error');
end;
$$;


-- ------------------------------------------------------------
-- Permissions: the page calls these with the publishable key.
-- Each one refuses a missing or expired token, except admin_login.
-- ------------------------------------------------------------
revoke execute on function
  admin_login(text, text),
  admin_logout(text),
  admin_overview(text),
  admin_list_bookings(text, text, text, text, text),
  admin_set_booking_status(text, text, text),
  admin_search_patients(text, text),
  admin_patient_detail(text, text)
from public;

grant execute on function
  admin_login(text, text),
  admin_logout(text),
  admin_overview(text),
  admin_list_bookings(text, text, text, text, text),
  admin_set_booking_status(text, text, text),
  admin_search_patients(text, text),
  admin_patient_detail(text, text)
to anon, authenticated, service_role;

revoke execute on function admin_check_token(text) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- verify (run one at a time):
-- select admin_overview('not-a-token');                      {"ok":"denied"}
-- select admin_login('nope', 'nope');                        {"ok":"denied"} after about a second
-- select happened_at, username, action from admin_audit order by happened_at desc limit 10;     the failed login is recorded
--
-- Review who looked at what:
-- select happened_at, username, action, detail from admin_audit order by happened_at desc limit 50;
--
-- Sign everyone out:
-- delete from admin_sessions;
