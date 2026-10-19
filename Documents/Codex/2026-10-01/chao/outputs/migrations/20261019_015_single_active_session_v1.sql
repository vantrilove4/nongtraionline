-- Enforce one active Supabase Auth session per player for the web game.
-- Apply in Supabase SQL Editor after reviewing. This migration is not run here.
-- The newest server-created auth.sessions row wins; device clocks are not used.

begin;

create table if not exists public.player_active_sessions_v1 (
  user_id uuid primary key references auth.users (id) on delete cascade,
  session_id uuid not null,
  session_created_at timestamptz not null,
  updated_at timestamptz not null default transaction_timestamp()
);

alter table public.player_active_sessions_v1 enable row level security;
revoke all on table public.player_active_sessions_v1 from public, anon, authenticated;

create or replace function public.claim_active_game_session_v1()
returns boolean
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_session_id uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_latest_id uuid;
  v_latest_created_at timestamptz;
begin
  if v_uid is null or v_session_id is null then
    raise exception using errcode = '28000', message = 'Authenticated session is required';
  end if;

  -- Serialize session claims with player-data writes for this account.
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 20261019));

  select s.id, s.created_at
    into v_latest_id, v_latest_created_at
  from auth.sessions as s
  where s.user_id = v_uid
  order by s.created_at desc, s.id desc
  limit 1;

  if v_latest_id is distinct from v_session_id then
    return false;
  end if;

  insert into public.player_active_sessions_v1 (user_id, session_id, session_created_at)
  values (v_uid, v_session_id, v_latest_created_at)
  on conflict (user_id) do update
    set session_id = excluded.session_id,
        session_created_at = excluded.session_created_at,
        updated_at = transaction_timestamp()
    where (excluded.session_created_at, excluded.session_id) >=
          (public.player_active_sessions_v1.session_created_at,
           public.player_active_sessions_v1.session_id);

  return exists (
    select 1 from public.player_active_sessions_v1 as a
    where a.user_id = v_uid and a.session_id = v_session_id
  );
end;
$$;

create or replace function public.is_active_game_session_v1()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  select auth.uid() is not null
     and nullif(auth.jwt() ->> 'session_id', '') is not null
     and exists (
       select 1
       from public.player_active_sessions_v1 as a
       join auth.sessions as current_session
         on current_session.id = a.session_id and current_session.user_id = a.user_id
       where a.user_id = auth.uid()
         and a.session_id = (auth.jwt() ->> 'session_id')::uuid
         and current_session.id = (
           select latest.id
           from auth.sessions as latest
           where latest.user_id = auth.uid()
           order by latest.created_at desc, latest.id desc
           limit 1
         )
     );
$$;

create or replace function public.enforce_active_game_session_write_v1()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
begin
  -- Allow trusted server jobs that do not carry an end-user JWT.
  if auth.uid() is not null then
    perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text, 20261019));
  end if;
  if auth.uid() is not null and not public.is_active_game_session_v1() then
    raise exception using errcode = '28000',
      message = 'This account is active in another session. Sign in again to continue.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.claim_active_game_session_v1() from public, anon, authenticated;
revoke all on function public.is_active_game_session_v1() from public, anon, authenticated;
revoke all on function public.enforce_active_game_session_write_v1() from public, anon, authenticated;
grant execute on function public.claim_active_game_session_v1() to authenticated;
grant execute on function public.is_active_game_session_v1() to authenticated;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'game_saves',
    'player_wallets', 'player_inventory', 'player_farm_state',
    'player_daily_quests', 'player_weekly_quests_v2',
    'player_daily_checkins_v2', 'player_daily_orders_v2',
    'player_achievements_v2', 'player_collections_v2',
    'economy_requests', 'reward_claims', 'market_listings'
  ] loop
    if to_regclass('public.' || v_table) is not null then
      execute format('drop trigger if exists enforce_active_game_session_v1 on public.%I', v_table);
      execute format(
        'create trigger enforce_active_game_session_v1 before insert or update or delete on public.%I for each row execute function public.enforce_active_game_session_write_v1()',
        v_table
      );
    end if;
  end loop;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'game_saves', 'player_wallets', 'player_inventory', 'player_farm_state',
    'player_daily_quests', 'player_weekly_quests_v2',
    'player_achievements_v2', 'player_collections_v2'
  ] loop
    if to_regclass('public.' || v_table) is not null then
      execute format('drop policy if exists active_session_read_gate_v1 on public.%I', v_table);
      execute format(
        'create policy active_session_read_gate_v1 on public.%I as restrictive for select to authenticated using (public.is_active_game_session_v1())',
        v_table
      );
    end if;
  end loop;
end;
$$;

comment on table public.player_active_sessions_v1 is
  'One server-verified current Supabase Auth session per player; no device time is trusted.';
comment on function public.claim_active_game_session_v1() is
  'Claims the newest server-created Supabase Auth session for this player; older sessions cannot reclaim it.';
comment on function public.is_active_game_session_v1() is
  'True only for the newest, claimed Supabase Auth session belonging to auth.uid().';

commit;
