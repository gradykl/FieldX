-- =====================================================================
-- FieldX: NFL Player Exchange — Supabase schema
-- Run this once in Supabase → SQL Editor → New query → Run.
-- =====================================================================

-- ---------- Tables ----------
create table public.players (
  tk        text primary key,
  name      text not null,
  pos       text not null check (pos in ('QB','RB','WR','TE')),
  team      text not null,
  base_ppg  double precision not null          -- PPR points per game when the game opened
);

-- Weekly stats updates. Never edit or delete old rows: past trades keep the prices they had.
create table public.stats_versions (
  id       bigserial primary key,
  from_ts  timestamptz not null default now(),
  label    text not null,                       -- e.g. 'Week 8'
  ppg      jsonb not null                       -- {"JSN": 27.9, "GIBB": 26.1, ...}
);

create table public.allowed_emails (email text primary key);      -- invite list
create table public.admins (user_id uuid primary key references auth.users(id) on delete cascade);

create table public.traders (
  id          uuid primary key references auth.users(id) on delete cascade,
  handle      text not null,
  created_at  timestamptz not null default now()
);
create unique index traders_handle_lower on public.traders (lower(handle));

create table public.trades (
  id            bigserial primary key,
  trader_id     uuid not null references public.traders(id) on delete cascade,
  tk            text not null references public.players(tk),
  side          text not null check (side in ('buy','sell')),
  qty           int  not null check (qty between 1 and 10),
  ts            timestamptz not null default now(),
  total         double precision not null,
  price_before  double precision not null,
  price_after   double precision not null,
  mv_before     double precision not null,
  mv_after      double precision not null
);
create index trades_tk_ts     on public.trades (tk, ts);
create index trades_trader_ts on public.trades (trader_id, ts);

create table public.market_reopens (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  by_user  uuid
);

-- ---------- Security: everyone signed in can read; nobody can write directly ----------
alter table public.players        enable row level security;
alter table public.stats_versions enable row level security;
alter table public.allowed_emails enable row level security;
alter table public.admins         enable row level security;
alter table public.traders        enable row level security;
alter table public.trades         enable row level security;
alter table public.market_reopens enable row level security;

create policy "signed-in read" on public.players        for select to authenticated using (true);
create policy "signed-in read" on public.stats_versions for select to authenticated using (true);
create policy "signed-in read" on public.traders        for select to authenticated using (true);
create policy "signed-in read" on public.trades         for select to authenticated using (true);
create policy "signed-in read" on public.market_reopens for select to authenticated using (true);
create policy "read own admin row" on public.admins     for select to authenticated using (user_id = auth.uid());
-- No insert/update/delete policies anywhere: all writes go through the functions below.

-- ---------- Pricing model (same formulas as the page) ----------
create or replace function public.fx_pv(p_tk text, p_t timestamptz) returns double precision
language sql stable set search_path = public as $$
  select 40 + 10 * greatest(0,
           coalesce((select (sv.ppg ->> p.tk)::double precision
                       from stats_versions sv
                      where sv.from_ts <= p_t and sv.ppg ? p.tk
                      order by sv.from_ts desc, sv.id desc limit 1),
                    p.base_ppg)
           - case p.pos when 'QB' then 15 when 'RB' then 9 when 'WR' then 9 else 6 end)
  from players p where p.tk = p_tk
$$;

create or replace function public.fx_demand(p_tk text, p_t timestamptz) returns double precision
language plpgsql stable set search_path = public as $$
declare b double precision; s double precision; v double precision;
begin
  select coalesce(sum(case when side = 'buy'  then qty * power(0.5, extract(epoch from (p_t - ts)) / 86400.0) end), 0),
         coalesce(sum(case when side = 'sell' then qty * power(0.5, extract(epoch from (p_t - ts)) / 86400.0) end), 0)
    into b, s
    from trades where tk = p_tk and ts <= p_t;
  v := b + s;
  if v <= 0 then return 1; end if;
  return exp(0.25 * ((b - s) / v) * least(1, v / 3.0));     -- GAMMA 0.25, full strength at 3 shares
end $$;

create or replace function public.fx_mv(p_pv double precision, p_held int, p_d double precision) returns double precision
language sql immutable as $$
  select least(2.5 * p_pv, greatest(0.5 * p_pv, p_pv * exp(p_held / 10.0) * p_d))   -- scarcity e^(owned/10)
$$;

-- ---------- Trading hours: closed from Sunday 9:30 AM ET until the next stats update or owner reopen ----------
create or replace function public.fx_last_kickoff(p_t timestamptz) returns timestamptz
language plpgsql stable as $$
declare loc timestamp := p_t at time zone 'America/New_York'; k timestamp;
begin
  k := date_trunc('week', loc + interval '1 day') - interval '1 day' + interval '9 hours 30 minutes';  -- this week's Sunday 9:30
  if k > loc then k := k - interval '7 days'; end if;
  return k at time zone 'America/New_York';
end $$;

create or replace function public.fx_market_closed(p_t timestamptz) returns boolean
language plpgsql stable set search_path = public as $$
declare k timestamptz := fx_last_kickoff(p_t);
begin
  if k < timestamptz '2026-10-30 12:00+00' then return false; end if;
  if exists (select 1 from stats_versions where from_ts > k and from_ts <= p_t) then return false; end if;
  if exists (select 1 from market_reopens where at > k and at <= p_t) then return false; end if;
  return true;
end $$;

-- ---------- Actions the page can call ----------
create or replace function public.create_trader(p_handle text) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text; v_handle text := trim(coalesce(p_handle, ''));
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  select email into v_email from auth.users where id = auth.uid();
  if not exists (select 1 from allowed_emails where lower(email) = lower(v_email)) then
    raise exception 'This email isn''t on the invite list. Ask the owner to add it.';
  end if;
  if v_handle !~ '^[-A-Za-z0-9 _.]{2,20}$' then
    raise exception 'Use 2–20 letters, numbers, spaces, dots, dashes or underscores.';
  end if;
  if exists (select 1 from traders where id = auth.uid()) then raise exception 'You already have an account.'; end if;
  if exists (select 1 from traders where lower(handle) = lower(v_handle)) then raise exception 'That name is taken. Try another.'; end if;
  insert into traders (id, handle) values (auth.uid(), v_handle);
end $$;

create or replace function public.place_trade(p_tk text, p_side text, p_qty int) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
  v_pv double precision; v_d double precision; v_held int; v_hold int; v_cash double precision;
  v_total double precision := 0; v_mv_b double precision; v_mv_a double precision; v_id bigint; j int;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  perform 1 from traders where id = v_uid for update;            -- one order at a time per trader
  if not found then raise exception 'Create your trader account first.'; end if;
  perform 1 from players where tk = p_tk for update;             -- one order at a time per player
  if not found then raise exception 'Unknown player.'; end if;
  if p_side not in ('buy', 'sell') then raise exception 'Invalid order.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 10 then raise exception 'Invalid quantity.'; end if;
  if fx_market_closed(v_now) then raise exception 'The market is closed for games. It reopens after this week''s stats update.'; end if;

  v_pv := fx_pv(p_tk, v_now);
  v_d  := fx_demand(p_tk, v_now);
  select coalesce(sum(case when side = 'buy' then qty else -qty end), 0) into v_held from trades where tk = p_tk;
  select coalesce(sum(case when side = 'buy' then qty else -qty end), 0) into v_hold from trades where tk = p_tk and trader_id = v_uid;
  select 5000 + coalesce(sum(case when side = 'sell' then total else -total end), 0) into v_cash from trades where trader_id = v_uid;
  v_mv_b := fx_mv(v_pv, v_held, v_d);

  if p_side = 'buy' then
    if v_held + p_qty > 10 then raise exception 'Not enough shares left.'; end if;
    if v_hold + p_qty > 3  then raise exception 'That would put you over the 3-share limit for this player.'; end if;
    for j in 0 .. p_qty - 1 loop v_total := v_total + 0.5 * (v_pv + fx_mv(v_pv, v_held + j, v_d)); end loop;
    if v_total > v_cash + 1e-6 then raise exception 'Not enough cash.'; end if;
  else
    if v_hold < p_qty then raise exception 'You don''t own enough shares.'; end if;
    for j in 1 .. p_qty loop v_total := v_total + 0.5 * (v_pv + fx_mv(v_pv, v_held - j, v_d)); end loop;
  end if;

  insert into trades (trader_id, tk, side, qty, ts, total, price_before, price_after, mv_before, mv_after)
  values (v_uid, p_tk, p_side, p_qty, v_now, v_total, 0.5 * (v_pv + v_mv_b), 0, v_mv_b, 0)
  returning id into v_id;

  v_mv_a := fx_mv(v_pv, v_held + case when p_side = 'buy' then p_qty else -p_qty end, fx_demand(p_tk, v_now));
  update trades set price_after = 0.5 * (v_pv + v_mv_a), mv_after = v_mv_a where id = v_id;

  return json_build_object('total', v_total, 'price_before', 0.5 * (v_pv + v_mv_b), 'price_after', 0.5 * (v_pv + v_mv_a));
end $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

create or replace function public.reopen_market() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then raise exception 'Only the owner can reopen the market.'; end if;
  insert into market_reopens (at, by_user) values (now(), auth.uid());
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.create_trader(text), public.place_trade(text, text, int),
                         public.is_admin(), public.reopen_market() to authenticated;

-- ---------- Live updates to everyone's page ----------
alter publication supabase_realtime add table public.trades, public.traders, public.stats_versions, public.market_reopens;

-- ---------- The 100 players (2026 PPR points per game through the Week 8 Thursday game) ----------
insert into public.players (tk, name, pos, team, base_ppg) values
  ('JSN', 'Jaxon Smith-Njigba', 'WR', 'SEA', 28.028571),
  ('GIBB', 'Jahmyr Gibbs', 'RB', 'DET', 28.5),
  ('ALLN', 'Josh Allen', 'QB', 'BUF', 26.883333),
  ('LAMB', 'CeeDee Lamb', 'WR', 'DAL', 22.214286),
  ('LOVE', 'Jordan Love', 'QB', 'GB', 18.6),
  ('KW3', 'Kenneth Walker III', 'RB', 'KC', 24.616667),
  ('WATS', 'Christian Watson', 'WR', 'GB', 18.35),
  ('PRDY', 'Brock Purdy', 'QB', 'SF', 20.857143),
  ('BIJN', 'Bijan Robinson', 'RB', 'ATL', 20.814286),
  ('CMC', 'Christian McCaffrey', 'RB', 'SF', 20.571429),
  ('MAYE', 'Drake Maye', 'QB', 'NE', 19.785714),
  ('JT', 'Jonathan Taylor', 'RB', 'IND', 19.642857),
  ('KYRN', 'Kyren Williams', 'RB', 'LAR', 19.585714),
  ('GOFF', 'Jared Goff', 'QB', 'DET', 22.166667),
  ('CHUB', 'Chuba Hubbard', 'RB', 'CAR', 19.0),
  ('GLDN', 'Matthew Golden', 'WR', 'GB', 16.4375),
  ('COUS', 'Kirk Cousins', 'QB', 'LV', 18.785714),
  ('JAVO', 'Javonte Williams', 'RB', 'DAL', 18.642857),
  ('MCBR', 'Trey McBride', 'TE', 'ARI', 18.6),
  ('BURR', 'Joe Burrow', 'QB', 'CIN', 21.683333),
  ('CJS', 'C.J. Stroud', 'QB', 'HOU', 18.385714),
  ('ARSB', 'Amon-Ra St. Brown', 'WR', 'DET', 21.4),
  ('DAK', 'Dak Prescott', 'QB', 'DAL', 18.3),
  ('BRYC', 'Bryce Young', 'QB', 'CAR', 18.028571),
  ('SHOU', 'Tyler Shough', 'QB', 'NO', 17.985714),
  ('OLAV', 'Chris Olave', 'WR', 'NO', 17.8),
  ('STAF', 'Matthew Stafford', 'QB', 'LAR', 17.628571),
  ('SWIF', 'D''Andre Swift', 'RB', 'CHI', 17.542857),
  ('HENR', 'Derrick Henry', 'RB', 'BAL', 17.528571),
  ('FLOW', 'Zay Flowers', 'WR', 'BAL', 20.366667),
  ('JEAN', 'Ashton Jeanty', 'RB', 'LV', 17.428571),
  ('NABE', 'Malik Nabers', 'WR', 'NYG', 17.214286),
  ('WARR', 'Jaylen Warren', 'RB', 'PIT', 17.071429),
  ('LAWR', 'Trevor Lawrence', 'QB', 'JAX', 19.033333),
  ('PUKA', 'Puka Nacua', 'WR', 'LAR', 22.72),
  ('COOK', 'James Cook', 'RB', 'BUF', 18.933333),
  ('LIKE', 'Isaiah Likely', 'TE', 'NYG', 16.071429),
  ('RODG', 'Aaron Rodgers', 'QB', 'PIT', 16.042857),
  ('IRVI', 'Bucky Irving', 'RB', 'TB', 15.657143),
  ('MCMI', 'Tetairoa McMillan', 'WR', 'CAR', 15.557143),
  ('LOND', 'Drake London', 'WR', 'ATL', 15.428571),
  ('BRIS', 'Jacoby Brissett', 'QB', 'ARI', 15.385714),
  ('DWAT', 'Deshaun Watson', 'QB', 'CLE', 15.257143),
  ('GENO', 'Geno Smith', 'QB', 'NYJ', 15.014286),
  ('KITT', 'George Kittle', 'TE', 'SF', 14.928571),
  ('HIGG', 'Tee Higgins', 'WR', 'CIN', 17.016667),
  ('ADAM', 'Davante Adams', 'WR', 'LAR', 17.0),
  ('MAHO', 'Patrick Mahomes', 'QB', 'KC', 16.683333),
  ('TUCK', 'Tre Tucker', 'WR', 'LV', 14.257143),
  ('WILS', 'Garrett Wilson', 'WR', 'NYJ', 14.2),
  ('PICK', 'George Pickens', 'WR', 'DAL', 13.928571),
  ('CHAS', 'Ja''Marr Chase', 'WR', 'CIN', 16.183333),
  ('BURD', 'Luther Burden III', 'WR', 'CHI', 13.857143),
  ('NIX', 'Bo Nix', 'QB', 'DEN', 13.685714),
  ('BOWR', 'Brock Bowers', 'TE', 'LV', 19.1),
  ('WASH', 'Parker Washington', 'WR', 'JAX', 15.316667),
  ('EVNS', 'Mike Evans', 'WR', 'SF', 14.833333),
  ('KRAF', 'Tucker Kraft', 'TE', 'GB', 11.0625),
  ('TUTE', 'Bhayshul Tuten', 'RB', 'JAX', 14.733333),
  ('POLL', 'Tony Pollard', 'RB', 'TEN', 12.542857),
  ('STEV', 'Rhamondre Stevenson', 'RB', 'NE', 12.414286),
  ('WILL', 'Malik Willis', 'QB', 'MIA', 14.433333),
  ('VELE', 'Devaughn Vele', 'WR', 'NO', 12.257143),
  ('JD5', 'Jayden Daniels', 'QB', 'WAS', 21.425),
  ('PENI', 'Michael Penix Jr.', 'QB', 'ATL', 16.94),
  ('JAMO', 'Jameson Williams', 'WR', 'DET', 13.95),
  ('CALB', 'Caleb Williams', 'QB', 'CHI', 20.9),
  ('MWIL', 'Michael Wilson', 'WR', 'ARI', 11.7),
  ('COKE', 'Jalen Coker', 'WR', 'CAR', 13.566667),
  ('HURT', 'Jalen Hurts', 'QB', 'PHI', 16.0),
  ('JUDK', 'Quinshon Judkins', 'RB', 'CLE', 13.283333),
  ('LAPO', 'Sam LaPorta', 'TE', 'DET', 13.233333),
  ('LJ8', 'Lamar Jackson', 'QB', 'BAL', 19.775),
  ('TATE', 'Carnell Tate', 'WR', 'TEN', 11.042857),
  ('BOST', 'Denzel Boston', 'WR', 'CLE', 11.028571),
  ('METC', 'DK Metcalf', 'WR', 'PIT', 10.928571),
  ('ALLE', 'Braelon Allen', 'RB', 'NYJ', 10.9),
  ('COLL', 'Nico Collins', 'WR', 'HOU', 15.22),
  ('DARN', 'Sam Darnold', 'QB', 'SEA', 12.466667),
  ('BROW', 'Chase Brown', 'RB', 'CIN', 12.466667),
  ('EWIL', 'Emanuel Wilson', 'RB', 'SEA', 10.685714),
  ('WARD', 'Cam Ward', 'QB', 'TEN', 10.614286),
  ('AJON', 'Aaron Jones', 'RB', 'MIN', 12.3),
  ('JJET', 'Justin Jefferson', 'WR', 'MIN', 14.42),
  ('EGBU', 'Emeka Egbuka', 'WR', 'TB', 11.85),
  ('SKAT', 'Cam Skattebo', 'RB', 'NYG', 11.733333),
  ('KELC', 'Travis Kelce', 'TE', 'KC', 11.716667),
  ('TWAR', 'Tyler Warren', 'TE', 'IND', 13.98),
  ('CORU', 'Blake Corum', 'RB', 'LAR', 9.928571),
  ('DIGG', 'Stefon Diggs', 'WR', 'WAS', 13.88),
  ('DEVO', 'DeVonta Smith', 'WR', 'PHI', 17.25),
  ('HHEN', 'Hunter Henry', 'TE', 'NE', 9.657143),
  ('JOHN', 'Juwan Johnson', 'TE', 'NO', 9.642857),
  ('FREI', 'Pat Freiermuth', 'TE', 'PIT', 9.628571),
  ('HARV', 'RJ Harvey', 'RB', 'DEN', 11.233333),
  ('MMAY', 'Michael Mayer', 'TE', 'LV', 9.542857),
  ('NOEL', 'Jaylin Noel', 'WR', 'HOU', 9.528571),
  ('FANN', 'Harold Fannin Jr.', 'TE', 'CLE', 9.528571),
  ('KAMA', 'Alvin Kamara', 'RB', 'NO', 10.966667),
  ('COLE', 'Keon Coleman', 'WR', 'BUF', 10.883333);
