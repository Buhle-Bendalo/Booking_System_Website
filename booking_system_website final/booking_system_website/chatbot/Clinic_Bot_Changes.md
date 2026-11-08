# Clinic Booking Bot — Changes from Original Export

Since the rebuilt `.export` file can't be imported (Infobip signs exports with
encryption that only their own export function can produce — see note at the
end), use this as your manual build checklist inside the Answers UI, starting
from your **original, unmodified import**.

---

## 1. Bug fixes to existing elements

### "New patient" dialog — broken API call body
The element that posts patient info to a Zapier hook has malformed JSON (a
stray `},` splitting the object, trailing comma before the closing brace). It
will fail on send. Replace the body with valid JSON (see §3 below — this
element is being replaced entirely with a Supabase upsert, not just fixed).

### "Existing patient" dialog — wrong response captured
The API call that fetches slots uses `responseCodeAttributeId`, which saves
the HTTP **status code** (e.g. `200`) into `available_slots` — not the actual
list of slots. The next message then displays `{{available_slots}}` to the
patient, which would show "200" instead of real times. Needs to use the
**Response body attributes** mapping instead (see "API element → Response"
docs), pointing at the actual field in the response body.

### New patients never reach booking
After collecting their info, the flow just says "Thanks for your info!" and
stops — there's no path from there into date/doctor/slot selection. New
patients currently can't book at all. Fixed in §3.

---

## 2. Removed entirely

- **13-digit South African ID number** step, in both "New patient" and
  "Existing patient" dialogs. We're not using a separate patient ID — Supabase
  identifies patients by phone number.
- **`patient_id` attribute** — delete this attribute from the bot's attribute
  list once the ID-number steps referencing it are removed.
- **`chosen_slots` attribute** — replaced by two new attributes, `slot_choice`
  (what the patient typed) and `chosen_slot` (the actual resolved timestamp).

---

## 3. New attributes to create

Create these as Text attributes (Global scope) before building the dialogs
below, since the new steps reference them:

| Attribute | Purpose |
|---|---|
| `doctor_id` | UUID of the doctor the patient picked |
| `doctor_name` | Display name of that doctor |
| `patient_uuid` | The real Supabase `patients.id`, returned after upsert |
| `booking_id` | The new `bookings.id`, returned after insert |
| `available_doctors` | Formatted text list shown to the patient |
| `doctor_choice` | The number the patient replies with |
| `slot_choice` | The number the patient replies with for time slot |
| `chosen_slot` | Resolved appointment start time |
| `chosen_slot_end` | Resolved appointment end time |
| `chronic_illness_flag` | Captures the Yes/No button payload before branching |
| `upcoming_bookings` | Formatted text list of a patient's bookings, for cancelling |
| `cancel_booking_choice` | The number the patient replies with to cancel |
| `cancelled_doctor_name` | Confirmation detail after a cancellation |
| `cancelled_slot_display` | Confirmation detail after a cancellation |

---

## 4. New dialog logic

### "New patient" dialog — rebuilt
Same questions as before (name, DOB, email), **minus the ID-number step**,
plus:

1. After chronic-illness branching, add an **API call** (POST) to:
   ```
   {SUPABASE_URL}/rest/v1/patients?on_conflict=phone_number
   ```
   Headers: `apikey`, `Authorization: Bearer <key>`, `Content-Type: application/json`,
   `Prefer: resolution=merge-duplicates,return=representation`

   Body:
   ```json
   { "phone_number": "{{phone_number}}", "patient_name": "{{patient_name}}",
     "dob": "{{DOB}}", "email": "{{email}}", "chronic_illness": "{{chronic_illness}}",
     "consent": true, "consent_at": "now()" }
   ```
   Response body attribute mapping: first array item's `id` → `patient_uuid`.

2. Send message: *"Thanks {{patient_name}}! Let's get you booked in."*
3. **Go to dialog** → Scheduling (see below) — this is the fix for the
   dead-end bug.

### "Existing patient" dialog → rename to **"Scheduling"**, rebuilt
This dialog now handles both new and existing patients (new patients land
here after the upsert step above). New flow:

1. Ask: *"What date would you like to book? (e.g. 2026-10-09)"* → `preferred_date`
2. **API call** → `{SUPABASE_URL}/rest/v1/rpc/get_available_doctors_text`
   Body: `{ "p_date": "{{preferred_date}}" }`
   Response body → `available_doctors`
3. Ask: *"Here are the doctors available on {{preferred_date}}:
   {{available_doctors}}\n\nReply with the number of your choice."* → `doctor_choice`
4. **API call** → `{SUPABASE_URL}/rest/v1/rpc/get_doctor_by_choice`
   Body: `{ "p_date": "{{preferred_date}}", "p_choice": {{doctor_choice}} }`
   Response body → `doctor_id`, `doctor_name`
5. **API call** → `{SUPABASE_URL}/rest/v1/rpc/get_available_slots_text`
   Body: `{ "p_doctor_id": "{{doctor_id}}", "p_date": "{{preferred_date}}" }`
   Response body → `available_slots`
6. Ask: *"{{doctor_name}}'s available times on {{preferred_date}}:
   {{available_slots}}\n\nReply with the number of your choice, or type
   \"back\" to pick a different doctor."* → `slot_choice`
7. **Condition**: if `slot_choice` equals `back` → go back to step 3.
   Otherwise continue.
8. **API call** → `{SUPABASE_URL}/rest/v1/rpc/get_slot_by_choice`
   Body: `{ "p_doctor_id": "{{doctor_id}}", "p_date": "{{preferred_date}}", "p_choice": {{slot_choice}} }`
   Response body → `chosen_slot`, `chosen_slot_end`
9. Ask (same as before, kept): *"Finally, please briefly describe the reason
   for your visit or your symptoms today"* → `symptoms`
10. Send message with Yes/No buttons:
    *"Please confirm your booking:\n\nDoctor: {{doctor_name}}\nWhen:
    {{chosen_slot}}\nReason: {{symptoms}}"*
    Buttons: "Yes, confirm" (payload `confirm_yes`) / "No, start over"
    (payload `confirm_no`) → capture into `info_confirmation` (reuse this
    existing attribute)
11. **Condition**: if `info_confirmation` equals `confirm_yes` → continue to
    step 12. Otherwise → go back to step 1 (restart date selection).
12. **API call** → `{SUPABASE_URL}/rest/v1/bookings` (POST)
    Headers include `Prefer: return=representation`
    Body:
    ```json
    { "patient_id": "{{patient_uuid}}", "doctor_id": "{{doctor_id}}",
      "chosen_slot": "{{chosen_slot}}", "ends_at": "{{chosen_slot_end}}",
      "symptoms": "{{symptoms}}", "status": "confirmed" }
    ```
    Response body → `booking_id`
    **Fallback on failure** → send to agent, with message: *"That slot was
    just taken by someone else. Let's try again."* (this is your
    double-booking safety net — the database's exclusion constraint will
    reject the insert if it clashes)
13. Send final message: *"You're all set! Your booking with {{doctor_name}}
    is confirmed for {{chosen_slot}}. We'll send you reminders so you don't
    miss it! 🩺"*

### "Cancel/ Reschedule" dialog — rebuilt (was a stub that just redirected)
1. **API call** → `{SUPABASE_URL}/rest/v1/rpc/get_patient_bookings_text`
   Body: `{ "p_phone": "{{phone_number}}" }`
   Response body → `upcoming_bookings`
2. **Condition**: if `upcoming_bookings` is empty → send: *"You don't have
   any upcoming bookings to cancel. Would you like to book one instead? Just
   say \"book\"."* and end.
3. Otherwise ask: *"Here are your upcoming bookings:\n{{upcoming_bookings}}
   \n\nReply with the number of the one you'd like to cancel."* → `cancel_booking_choice`
4. **API call** → `{SUPABASE_URL}/rest/v1/rpc/cancel_booking_by_choice`
   Body: `{ "p_phone": "{{phone_number}}", "p_choice": {{cancel_booking_choice}} }`
   Response body → `cancelled_doctor_name`, `cancelled_slot_display`
5. Send: *"Done — your appointment with {{cancelled_doctor_name}} on
   {{cancelled_slot_display}} has been cancelled. Message us anytime if
   you'd like to book another."*

### "Main menu" dialog — one small addition
Before the **Send to agent** step on the "Emergency & Reception" option, add
a message first: *"Connecting you with our reception team now. If this is a
medical emergency, please call [emergency number] or go to your nearest
emergency room immediately."* Replace `[emergency number]` with your clinic's
real number.

---

## 5. Required Supabase SQL (new RPC functions)

Run this in Supabase's SQL Editor before testing anything above — none of
these functions exist in your database yet:

```sql
create or replace function get_available_doctors_text(p_date date)
returns text as $$
  select string_agg(format('%s. %s (%s)', row_number() over (order by full_name), full_name, coalesce(specialty,'General')), E'\n')
  from get_available_doctors(p_date);
$$ language sql stable;

create or replace function get_doctor_by_choice(p_date date, p_choice int)
returns table(doctor_id uuid, doctor_name text) as $$
  select id, full_name
  from (
    select d.doctor_id as id, d.full_name, row_number() over (order by d.full_name) as rn
    from get_available_doctors(p_date) d
  ) ranked
  where rn = p_choice;
$$ language sql stable;

create or replace function get_available_slots_text(p_doctor_id uuid, p_date date)
returns text as $$
  select string_agg(format('%s. %s', row_number() over (order by slot), to_char(slot at time zone 'Africa/Johannesburg', 'HH24:MI')), E'\n')
  from get_available_slots(p_doctor_id, p_date);
$$ language sql stable;

create or replace function get_slot_by_choice(p_doctor_id uuid, p_date date, p_choice int)
returns table(chosen_slot timestamptz, chosen_slot_end timestamptz) as $$
  select slot, slot + interval '30 minutes'
  from (
    select s.slot, row_number() over (order by s.slot) as rn
    from get_available_slots(p_doctor_id, p_date) s
  ) ranked
  where rn = p_choice;
$$ language sql stable;

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

create or replace function get_patient_bookings_text(p_phone text)
returns text as $$
  select string_agg(format('%s. %s - %s', idx, to_char(chosen_slot at time zone 'Africa/Johannesburg', 'DD Mon, HH24:MI'), doctor_name), E'\n')
  from get_patient_bookings(p_phone);
$$ language sql stable;

create or replace function cancel_booking_by_choice(p_phone text, p_choice int)
returns table(cancelled_doctor_name text, cancelled_slot timestamptz) as $$
  update bookings b
  set status = 'cancelled'
  from get_patient_bookings(p_phone) t
  where b.id = t.booking_id and t.idx = p_choice
  returning t.doctor_name, t.chosen_slot;
$$ language sql;
```

---

## 6. Why the rebuilt .export file itself can't be imported

Infobip encrypts/signs every exported chatbot file. On import, the system
rejects a file "if it is either unencrypted or the encryption has been
modified." The `exportMetadata` value at the top of your original file is
that signature — it's generated by Infobip's backend at export time and tied
to the exact content. There's no way to hand-author a new signature that
matches edited content, so a manually edited file will always be rejected.
That's why this doc exists as a manual build guide instead of a second
importable file.
