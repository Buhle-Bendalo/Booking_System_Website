-- ============================================================
-- Prescriptions on the reception dashboard
-- Run AFTER patch_admin_dashboard.sql, and after the prescriptions table exists.
-- Safe to run again.
--
--   1. Locks the prescriptions table (it holds health information).
--   2. admin_list_prescriptions : the new Prescriptions tab.
--   3. admin_patient_detail     : the patient file now lists their prescriptions.
-- ============================================================

do $do$
begin
  if to_regclass('public.prescriptions') is null then
    raise exception 'The prescriptions table does not exist yet. Create it first.';
  end if;
  if to_regclass('public.admin_sessions') is null then
    raise exception 'Run patch_admin_dashboard.sql first.';
  end if;
end
$do$;

-- 1. Lock the table. Without this, anyone holding the publishable key
--    (it is in the web pages) could read every prescription directly.
--    service_role and the security-definer functions below still work.
--    If another page of yours reads or writes this table directly with the
--    publishable key, it will stop working: give it a function instead.
alter table public.prescriptions enable row level security;
revoke all on public.prescriptions from anon, authenticated;

create index if not exists prescriptions_patient_idx on public.prescriptions (patient_id);
create index if not exists prescriptions_status_idx  on public.prescriptions (status);


-- 2. List prescriptions. p_status = '' for all, or a status such as 'Pending Review'.
create or replace function admin_list_prescriptions(p_token text, p_status text default '')
returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user text := admin_check_token(p_token);
  v_rows json;
begin
  if v_user is null then return json_build_object('ok', 'denied'); end if;

  select coalesce(json_agg(r order by r.created_at desc), '[]'::json) into v_rows
  from (
    select rx.id as prescription_id, rx.patient_id, p.patient_name, p.phone_number,
           rx.medication_name, rx.prescription_file, rx.status,
           rx.created_at, rx.collection_at, rx.reviewed_at, rx.rejection_reason
    from prescriptions rx
    join patients p on p.id = rx.patient_id
    where coalesce(p_status, '') = '' or lower(rx.status) = lower(p_status)
    order by rx.created_at desc
    limit 200
  ) r;

  insert into admin_audit (username, action, detail) values (v_user, 'list_prescriptions', coalesce(p_status, ''));

  return json_build_object('ok', 'yes', 'rows', v_rows);
exception when others then
  return json_build_object('ok', 'error');
end;
$$;


-- 3. Patient file: same as before, plus the patient's prescriptions.
create or replace function admin_patient_detail(p_token text, p_patient_id text) returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user text := admin_check_token(p_token);
  v_id   uuid;
  v_p    patients%rowtype;
  v_hist json;
  v_rx   json;
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

  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) into v_rx
  from (
    select rx.id as prescription_id, rx.medication_name, rx.prescription_file, rx.status,
           rx.created_at, rx.collection_at, rx.reviewed_at, rx.rejection_reason
    from prescriptions rx
    where rx.patient_id = v_id
    order by rx.created_at desc
    limit 25
  ) x;

  insert into admin_audit (username, action, detail) values (v_user, 'view_patient', v_id::text);

  return json_build_object(
    'ok', 'yes',
    'patient', json_build_object(
      'patient_id', v_p.id, 'patient_name', v_p.patient_name, 'phone_number', v_p.phone_number,
      'email', v_p.email, 'id_number', v_p.id_number, 'dob', v_p.dob,
      'chronic_illness', v_p.chronic_illness, 'consent', v_p.consent,
      'consent_at', v_p.consent_at, 'created_at', v_p.created_at),
    'history', v_hist,
    'prescriptions', v_rx);
exception when others then
  return json_build_object('ok', 'error');
end;
$$;


-- Permissions, same pattern as the other dashboard functions.
revoke execute on function admin_list_prescriptions(text, text) from public;
grant  execute on function admin_list_prescriptions(text, text) to anon, authenticated, service_role;
revoke execute on function admin_patient_detail(text, text) from public;
grant  execute on function admin_patient_detail(text, text) to anon, authenticated, service_role;
