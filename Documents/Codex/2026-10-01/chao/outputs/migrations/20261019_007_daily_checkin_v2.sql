-- Phase 2, server-authoritative daily check-in (dark launch).
-- Draft only; do not execute until reviewed and approved.
-- Depends on migration 001 canonical wallet/inventory/request/reward tables.
-- No client or legacy save is changed by this migration.

begin;

create table public.daily_checkin_catalog_v2 (
  cycle_day smallint primary key check (cycle_day between 1 and 7),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  reward_item_key text check (reward_item_key is null or reward_item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  reward_item_quantity bigint not null default 0 check (reward_item_quantity >= 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default transaction_timestamp(),
  check ((reward_item_key is null) = (reward_item_quantity = 0))
);

insert into public.daily_checkin_catalog_v2
  (cycle_day, reward_coins, reward_xp, reward_item_key, reward_item_quantity)
values
  (1, 20, 2, null, 0),
  (2, 30, 3, null, 0),
  (3, 40, 4, 'seed_carrot', 1),
  (4, 50, 5, null, 0),
  (5, 65, 6, 'feed_chicken', 1),
  (6, 80, 8, null, 0),
  (7, 120, 12, 'seed_carrot', 3);

create table public.player_daily_checkins_v2 (
  user_id uuid not null references auth.users (id) on delete restrict,
  checkin_date date not null,
  cycle_day smallint not null check (cycle_day between 1 and 7),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  reward_item_key text check (reward_item_key is null or reward_item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  reward_item_quantity bigint not null default 0 check (reward_item_quantity >= 0),
  level_up_coins bigint not null default 0 check (level_up_coins >= 0),
  request_id uuid not null,
  created_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, checkin_date),
  unique (user_id, request_id),
  foreign key (user_id, request_id)
    references public.economy_requests (user_id, request_id) on delete restrict,
  check ((reward_item_key is null) = (reward_item_quantity = 0))
);

create index player_daily_checkins_recent_idx
  on public.player_daily_checkins_v2 (user_id, checkin_date desc);

alter table public.daily_checkin_catalog_v2 enable row level security;
alter table public.player_daily_checkins_v2 enable row level security;
revoke all on table public.daily_checkin_catalog_v2 from public, anon, authenticated;
revoke all on table public.player_daily_checkins_v2 from public, anon, authenticated;

create function public.get_my_daily_checkin_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
  v_prev_day smallint;
  v_cycle_day smallint;
  v_today public.player_daily_checkins_v2%rowtype;
  v_reward public.daily_checkin_catalog_v2%rowtype;
  v_claimed boolean := false;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  select * into v_today from public.player_daily_checkins_v2
  where user_id = v_uid and checkin_date = v_date;
  v_claimed := found;
  if v_claimed then
    v_cycle_day := case when v_today.cycle_day = 7 then 1 else v_today.cycle_day + 1 end;
  else
    select cycle_day into v_prev_day from public.player_daily_checkins_v2
    where user_id = v_uid and checkin_date = v_date - 1;
    v_cycle_day := case when v_prev_day is null or v_prev_day = 7 then 1 else v_prev_day + 1 end;
  end if;
  select * into v_reward from public.daily_checkin_catalog_v2
  where cycle_day = v_cycle_day and enabled;
  if not found then
    raise exception using errcode = '55000', message = 'Daily check-in reward is not configured';
  end if;
  return jsonb_build_object(
    'ok', true, 'checkin_date', v_date, 'claimed_today', v_claimed,
    'streak_day', case when v_claimed then v_today.cycle_day else v_cycle_day end,
    'next_streak_day', v_cycle_day,
    'reward', jsonb_build_object('coins', case when v_claimed then v_today.reward_coins else v_reward.reward_coins end,
      'xp', case when v_claimed then v_today.reward_xp else v_reward.reward_xp end,
      'item_key', case when v_claimed then v_today.reward_item_key else v_reward.reward_item_key end,
      'item_quantity', case when v_claimed then v_today.reward_item_quantity else v_reward.reward_item_quantity end),
    'level_up_coins', case when v_claimed then v_today.level_up_coins else 0 end
  );
end;
$$;

create function public.claim_daily_checkin_v2(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
  v_request public.economy_requests%rowtype;
  v_wallet public.player_wallets%rowtype;
  v_prior public.player_daily_checkins_v2%rowtype;
  v_existing public.player_daily_checkins_v2%rowtype;
  v_reward public.daily_checkin_catalog_v2%rowtype;
  v_cycle_day smallint;
  v_payload_hash text;
  v_xp_after bigint;
  v_level_before integer := 1;
  v_level_after integer := 1;
  v_level_coins bigint := 0;
  v_item_quantity bigint;
  v_response jsonb;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'Request id is required';
  end if;
  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'claim_daily_checkin_v2'
  )::text, 'UTF8')), 'hex');

  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'claim_daily_checkin_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'claim_daily_checkin_v2'
     or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  -- Lock canonical wallet first to serialize distinct requests from multiple devices for the same account.
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;

  select * into v_existing from public.player_daily_checkins_v2
  where user_id = v_uid and checkin_date = v_date;
  if found then
    v_response := jsonb_build_object('ok', true, 'already_claimed', true,
      'checkin_date', v_date, 'streak_day', v_existing.cycle_day,
      'coins_awarded', v_existing.reward_coins, 'xp_awarded', v_existing.reward_xp,
      'item_key', v_existing.reward_item_key, 'item_quantity', v_existing.reward_item_quantity,
      'level_up_coins', v_existing.level_up_coins);
    update public.economy_requests set response = v_response, completed_at = v_now
    where user_id = v_uid and request_id = p_request_id;
    return v_response;
  end if;

  select * into v_prior from public.player_daily_checkins_v2
  where user_id = v_uid and checkin_date = v_date - 1;
  v_cycle_day := case when not found or v_prior.cycle_day = 7 then 1 else v_prior.cycle_day + 1 end;
  select * into v_reward from public.daily_checkin_catalog_v2
  where cycle_day = v_cycle_day and enabled;
  if not found then
    raise exception using errcode = '55000', message = 'Daily check-in reward is not configured';
  end if;

  v_xp_after := v_wallet.xp + v_reward.reward_xp;
  while v_level_before < 60 and v_wallet.xp >=
    (80 * v_level_before + 10 * v_level_before * (v_level_before - 1)) loop
    v_level_before := v_level_before + 1;
  end loop;
  while v_level_after < 60 and v_xp_after >=
    (80 * v_level_after + 10 * v_level_after * (v_level_after - 1)) loop
    v_level_after := v_level_after + 1;
  end loop;
  v_level_coins := greatest(0, v_level_after - v_level_before) * 30;

  update public.player_wallets
  set coins = coins + v_reward.reward_coins + v_level_coins,
      xp = v_xp_after, updated_at = v_now
  where user_id = v_uid;
  if v_reward.reward_item_key is not null then
    insert into public.player_inventory (user_id, item_key, quantity, updated_at)
    values (v_uid, v_reward.reward_item_key, v_reward.reward_item_quantity, v_now)
    on conflict (user_id, item_key) do update
      set quantity = public.player_inventory.quantity + excluded.quantity,
          updated_at = excluded.updated_at
    returning quantity into v_item_quantity;
  end if;

  insert into public.player_daily_checkins_v2
    (user_id, checkin_date, cycle_day, reward_coins, reward_xp,
     reward_item_key, reward_item_quantity, level_up_coins, request_id, created_at)
  values
    (v_uid, v_date, v_cycle_day, v_reward.reward_coins, v_reward.reward_xp,
     v_reward.reward_item_key, v_reward.reward_item_quantity, v_level_coins, p_request_id, v_now);

  v_response := jsonb_build_object('ok', true, 'already_claimed', false,
    'checkin_date', v_date, 'streak_day', v_cycle_day,
    'coins_awarded', v_reward.reward_coins, 'xp_awarded', v_reward.reward_xp,
    'item_key', v_reward.reward_item_key, 'item_quantity', v_reward.reward_item_quantity,
    'item_total', v_item_quantity, 'level_up_coins', v_level_coins);
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  insert into public.reward_claims
    (user_id, reward_kind, period_key, source_id, request_id, response, created_at)
  values (v_uid, 'daily_checkin', v_date::text, 'login', p_request_id, v_response, v_now);
  return v_response;
end;
$$;

revoke all on function public.get_my_daily_checkin_v2() from public, anon, authenticated;
revoke all on function public.claim_daily_checkin_v2(uuid) from public, anon, authenticated;
grant execute on function public.get_my_daily_checkin_v2() to authenticated;
grant execute on function public.claim_daily_checkin_v2(uuid) to authenticated;

comment on function public.claim_daily_checkin_v2(uuid) is
  'Claims the current Asia/Ho_Chi_Minh daily check-in once per account/day, using DB time and atomically awarding server catalog rewards.';
comment on function public.get_my_daily_checkin_v2() is
  'Returns the current server-date check-in preview and claim status without mutating progress or granting rewards.';

commit;
