-- ============================================================
-- PATCH: doctors page + admin login (for the demo website)
-- Safe to run on the live database. Adds a table and two functions.
--
-- The website only needs your project URL and the PUBLISHABLE key.
-- The admin username and password are checked INSIDE the database and
-- stored hashed, so they never appear in the page source, and the secret
-- key never has to go near a browser.
--
-- BEFORE RUNNING: set your own admin username and password in the
-- block marked "EDIT THESE" below. The script refuses to run with the
-- placeholder values or a password shorter than 10 characters.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists admin_users (
  username       text primary key,
  password_hash  text not null,
  created_at     timestamptz not null default now()
);

-- nobody can read this table through the API
alter table admin_users enable row level security;
revoke all on admin_users from anon, authenticated;


-- ============================================================
-- EDIT THESE TWO VALUES (keep the quotes). Run this script again
-- with new values any time you want to change the login.
-- ============================================================
do $do$
declare
  v_user text := 'CHANGE_ME_USERNAME';
  v_pass text := 'CHANGE_ME_PASSWORD';
begin
  if v_user like 'CHANGE_ME%' or v_pass like 'CHANGE_ME%' then
    raise exception 'Set your own admin username and password in this block first.';
  end if;
  if length(v_pass) < 10 then
    raise exception 'Use a password of at least 10 characters.';
  end if;
  insert into admin_users (username, password_hash)
  values (v_user, crypt(v_pass, gen_salt('bf')))
  on conflict (username) do update set password_hash = excluded.password_hash;
end
$do$;


-- ============================================================
-- Public list of doctors: name and specialty only.
-- (security definer: the tables themselves stay locked)
-- ============================================================
create or replace function list_doctors()
returns table(full_name text, specialty text)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select d.full_name, coalesce(d.specialty, 'General Practice')
  from doctors d
  where d.active = true
  order by d.full_name;
$$;


-- ============================================================
-- Add a doctor. Needs the admin username and password.
-- ok = yes | denied | invalid | duplicate | error
-- A new doctor is bookable in the chat straight away.
-- ============================================================
create or replace function admin_add_doctor(
  p_username text, p_password text, p_full_name text, p_specialty text
) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_hash text; v_name text; v_spec text;
begin
  select password_hash into v_hash from admin_users where username = p_username;
  if v_hash is null or crypt(coalesce(p_password,''), v_hash) <> v_hash then
    perform pg_sleep(1);   -- slows down password guessing
    return json_build_object('ok','denied');
  end if;

  v_name := regexp_replace(trim(coalesce(p_full_name,'')), '\s+', ' ', 'g');
  v_spec := regexp_replace(trim(coalesce(p_specialty,'')), '\s+', ' ', 'g');

  if length(v_name) < 3 or length(v_name) > 100
     or length(v_spec) < 2 or length(v_spec) > 60
     or v_name !~ '^[[:alpha:]][[:alpha:] .''-]*$'
     or v_spec !~ '^[[:alpha:]][[:alpha:] ,&/''-]*$' then
    return json_build_object('ok','invalid');
  end if;

  if exists (select 1 from doctors where lower(full_name) = lower(v_name)) then
    return json_build_object('ok','duplicate');
  end if;

  insert into doctors (full_name, specialty, active) values (v_name, v_spec, true);
  return json_build_object('ok','yes');
exception when others then
  return json_build_object('ok','error');
end;
$$;


-- the website calls these with the public (publishable) key
revoke execute on function list_doctors() from public;
revoke execute on function admin_add_doctor(text, text, text, text) from public;
grant execute on function list_doctors() to anon, authenticated, service_role;
grant execute on function admin_add_doctor(text, text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- verify (run one at a time):
-- select * from list_doctors();                                              name and specialty only
-- select admin_add_doctor('nope','nope','Dr. Test Person','General Practice');   {"ok":"denied"} after about a second
-- select username from admin_users;                                          your username; the hash is never exposed

-- Remove a test doctor. Doctors that already have bookings cannot be deleted, so hide them instead:
-- update doctors set active = false where full_name = 'Dr. Test Person';
