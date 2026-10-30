-- =====================================================================
-- Run AFTER you've signed up on the site yourself.
-- Replace the emails, then run in Supabase → SQL Editor.
-- =====================================================================

-- 1. Invite list: you plus your friends (anyone not listed can't create a trader account)
insert into public.allowed_emails (email) values
  ('you@example.com'),
  ('friend1@example.com'),
  ('friend2@example.com');

-- 2. Make yourself the owner (shows the "Reopen trading now" button)
insert into public.admins (user_id)
select id from auth.users where lower(email) = lower('you@example.com');

-- Later, to invite someone else:
-- insert into public.allowed_emails (email) values ('new.friend@example.com');
