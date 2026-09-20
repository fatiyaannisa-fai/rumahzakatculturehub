-- ============================================================
-- RZ App — Cloud Sync Table Setup for Supabase
-- ============================================================
-- Run this once in Supabase Dashboard -> SQL Editor -> New query.
-- Safe to re-run: every statement uses IF NOT EXISTS / OR REPLACE
-- so running it again will not duplicate data or break anything.

-- 1) The table itself: one row per "bucket" of app data (rz_users,
--    rz_gamification, rz_forum, etc). "value" holds the JSON blob
--    exactly as the app already stores it in localStorage.
create table if not exists public.app_data (
    key         text primary key,
    value       text not null,
    updated_at  timestamptz not null default now()
);

-- 2) Guardrail: block absurdly large payloads (protects your Supabase
--    plan quota from a corrupted/huge upload; adjust the number if you
--    later store bigger things like large embedded images).
alter table public.app_data
    drop constraint if exists app_data_value_size_check;
alter table public.app_data
    add constraint app_data_value_size_check check (length(value) < 3000000);

-- 3) Only these exact keys may ever be written. Must match the
--    CLOUD_SYNC_KEYS array in the HTML file — if you add a new
--    synced key in the app, add it here too, or writes to it will
--    be silently rejected by Postgres.
create or replace function public.app_data_key_allowed(k text)
returns boolean
language sql
immutable
as $$
    select k = any (array[
        'rz_users', 'rz_gamification', 'rz_forum', 'rz_globecare_3d', 'rz_globecare_comments',
        'rz_philanthropy', 'rz_philanthropy_comments', 'rz_reports', 'rz_shoutouts',
        'rz_options', 'rz_xp_config', 'rz_participant_emails', 'rz_char_overrides',
        'rz_custom_chars', 'rz_sso_config', 'rz_missions_config', 'rz_eng_db',
        'rz_business_db', 'rz_biz_quiz_methods', 'rz_biz_ai_config'
    ]);
$$;

alter table public.app_data
    drop constraint if exists app_data_key_allowed_check;
alter table public.app_data
    add constraint app_data_key_allowed_check check (public.app_data_key_allowed(key));

-- 4) Row Level Security: turn it ON. Without this, anyone who ever
--    opens your site's browser console can read AND overwrite every
--    row using the same public key the app itself uses — RLS is what
--    actually enforces the rules below instead of relying on the key
--    being secret (it isn't; it's meant to be public).
alter table public.app_data enable row level security;

-- 5) Policies for the "anon" role (this is what your publishable /
--    anon key maps to). The app needs to read everything (to sync
--    to a new device) and write to the allowed keys above.
drop policy if exists "anon can read app_data" on public.app_data;
create policy "anon can read app_data"
    on public.app_data for select
    to anon
    using (true);

drop policy if exists "anon can insert allowed keys" on public.app_data;
create policy "anon can insert allowed keys"
    on public.app_data for insert
    to anon
    with check (public.app_data_key_allowed(key));

drop policy if exists "anon can update allowed keys" on public.app_data;
create policy "anon can update allowed keys"
    on public.app_data for update
    to anon
    using (public.app_data_key_allowed(key))
    with check (public.app_data_key_allowed(key));

-- Deliberately NO delete policy for anon — rows can only be
-- overwritten, never deleted, from the client. Only you (via the
-- Supabase Dashboard, logged in as the project owner) can delete rows.

-- 6) Keep updated_at honest even if a future code change forgets to
--    set it manually.
create or replace function public.app_data_set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists app_data_touch_updated_at on public.app_data;
create trigger app_data_touch_updated_at
    before insert or update on public.app_data
    for each row execute function public.app_data_set_updated_at();

-- ============================================================
-- IMPORTANT — read this
-- ============================================================
-- This app writes directly from the browser using the publishable
-- (anon) key, with no per-user Supabase Auth login. That means the
-- policies above stop STRANGERS from deleting data or writing to
-- random new keys, but they CANNOT stop a technically savvy visitor
-- from overwriting the 20 legitimate keys above with bad data, because
-- the same key the app uses to save your own data is, by design,
-- visible to every visitor's browser.
--
-- Practical mitigations available today, already covered above:
--   - RLS + allow-list of keys (blocks junk/new rows, blocks deletes)
--   - Size cap on each value (blocks quota-exhaustion abuse)
--   - Regular backups (see the guide) so you can always roll back
--
-- If you eventually need real per-person data isolation (e.g. each
-- student's XP truly locked to their own account, un-editable by
-- anyone else), that requires migrating logins to Supabase Auth and
-- adding a user_id column with an "owner can only touch their own
-- row" policy — a bigger change than this file, happy to help with
-- it separately if/when you want it.
