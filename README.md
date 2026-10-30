# FieldX — NFL Player Exchange

Static web page (index.html + config.js) on Vercel, with Supabase for logins and the trade database.
Every trade is checked and priced by the database itself, so players can only trade — not edit data.

## Files
- `index.html` — the app
- `config.js` — your Supabase URL and publishable key (edit this)
- `supabase/schema.sql` — tables, security rules, pricing and trading functions, and the 100 players
- `supabase/setup-people.sql` — invite list and owner setup

## Setup
1. **Supabase → SQL Editor:** paste all of `supabase/schema.sql`, click Run.
2. **Supabase → Project Settings → API (or the Connect button):** copy the Project URL and the publishable/anon key into `config.js`.
3. **GitHub:** create a repository named `fieldx` and upload `index.html`, `config.js`, `README.md` and the `supabase` folder.
4. **Vercel → Add New → Project:** import the `fieldx` repo. Framework preset: Other. No build command. Deploy.
5. **Supabase → Authentication → URL Configuration:** set Site URL to your Vercel address (e.g. https://fieldx-yourname.vercel.app).
6. Open your Vercel address, click "Create a login", confirm your email, sign in.
7. **Supabase → SQL Editor:** edit and run `supabase/setup-people.sql` (your email + friends' emails; makes you owner).
8. Refresh the site and create your trader account. Send your friends the link.

## Weekly stats update
Run the SQL Claude gives you after Monday night's game:
`insert into public.stats_versions (label, ppg) values ('Week 9', '{"JSN": 27.4, ...}');`
Never edit or delete old rows in `stats_versions` — that would change past prices.

## Backups (free plan has none)
Supabase → Table Editor → `trades` and `traders` → Export to CSV, every week or so.
