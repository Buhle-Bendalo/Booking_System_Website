# Clinic Booking System

Patients book, cancel and reschedule appointments in an Infobip chatbot or a backup web form. Reception manages bookings in a dashboard. Patients get WhatsApp reminders 24 hours and 1 hour before a confirmed appointment. Data is stored in Supabase (Postgres).

Live site: https://ttss-clinic.netlify.app/

> **No credentials are stored in this repository.** The web pages contain `PASTE_YOUR_...` placeholders. Add your own values locally or in your hosting setup. Never put the Supabase **secret** key in any file here.

## Architecture

- **Supabase**: tables, SQL functions called over the REST API (`/rest/v1/rpc/<function>`), Row Level Security, and `pg_cron` + `pg_net` reminder jobs.
- **Infobip**: Answers chatbot, Live Chat widget, WhatsApp template messages.
- **Zapier**: receives the reminder webhook from the database and sends the WhatsApp message through Infobip.
- **Website**: four static pages, no build step.

## Repository layout

| Path | Contents |
| --- | --- |
| `web/index.html` | Home page with the chat widget |
| `web/book.html` | Backup six-step booking form |
| `web/doctors.html` | Doctor profiles and add-doctor form |
| `web/admin.html` | Reception dashboard |
| `web/images/` | Doctor photos |
| `database/` | SQL scripts (run in the order below) |
| `chatbot/Clinic_Bot_Changes.md` | Step-by-step Infobip chatbot build guide |

## Setup

### 1. Database (Supabase SQL editor, in this order)

1. `database/clinic_db_rebuild.sql` (builds everything; **deletes existing data**, run once on a fresh project)
2. `database/patch_doctors_admin.sql` (first set your own admin username and a password of at least 10 characters in the marked block)
3. `database/patch_admin_dashboard.sql`
4. `database/patch_booking_form.sql`
5. `database/patch_cancel_reschedule.sql`
6. `database/patch_prescriptions_admin.sql` (needs the `prescriptions` table to exist first)
7. Optional test clean-up functions: `patch_clear_bookings.sql`, `patch_clear_patients.sql`

Then save your Zapier Catch Hook address:

```sql
insert into app_settings (key, value)
values ('zapier_reminder_webhook', 'https://hooks.zapier.com/hooks/catch/XXXX/YYYY/')
on conflict (key) do update set value = excluded.value;
```

### 2. Website

In `web/book.html`, `web/doctors.html` and `web/admin.html` replace:

- `PASTE_YOUR_SUPABASE_URL` with your project URL
- `PASTE_YOUR_PUBLISHABLE_KEY` with the Supabase **publishable** key

In `web/index.html`, set your Infobip Live Chat widget ID in `liveChat('init', ...)`.

### 3. Chatbot and reminders

Follow `chatbot/Clinic_Bot_Changes.md` to build the chatbot in Infobip. The Call API elements use the Supabase **secret** key inside Infobip only. Create a Zap with a Catch Hook, split on `reminder_type` (`24h` / `1h`) and send the approved WhatsApp template.

## Run locally

```bash
cd web
python3 -m http.server 8080
# open http://localhost:8080/book.html
```

Use a test Supabase project. Clear test data with `select clear_all_bookings();` or `select clear_all_patients();`.

## Deploy

Upload the contents of `web/` to any static host (this project uses Netlify: Add new site, Deploy manually, drag in the folder). There is no build command. The admin page is `/admin.html`, protected by the reception login.

## Security

- The publishable key is public by design. The secret key lives only in Infobip.
- Row Level Security is on for every table with no policies, so the public key cannot read tables directly. Access is only through the SQL functions.
- Reception passwords are stored as bcrypt hashes; sessions last 2 hours; staff actions are recorded in `admin_audit`.

## Documentation

Full documents (deployment guide, web UI and script documentation, database schema Figure 6.2) are supplied with the submission.
