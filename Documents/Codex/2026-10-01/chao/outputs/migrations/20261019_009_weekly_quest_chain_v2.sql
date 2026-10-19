-- Phase 2, server-derived weekly quest chain (dark launch).
-- Draft only; do not execute until reviewed and approved.
-- Depends on migration 001. Progress is derived from completed server RPC requests.
-- Does not import client save history or trust client-provided progress.

begin;

create table public.weekly_quest_catalog_v2 (
  quest_id text primary key check (quest_id ~ '^[a-z][a-z0-9_]{0,63}$'),
  chain_step smallint not null unique check (chain_step between 1 and 4),
  action_type text not null check (action_type in ('plant','harvest','feed','order')),
  title text not null,
  target integer not null check (target > 0),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default transaction_timestamp()
);

insert into public.weekly_quest_catalog_v2
  (quest_id, chain_step, action_type, title, target, reward_coins, reward_xp)
values
  ('weekly_plant', 1, 'plant', 'Chuỗi tuần 1: Gieo 8 cây trồng', 8, 80, 15),
  ('weekly_harvest', 2, 'harvest', 'Chuỗi tuần 2: Thu hoạch 6 cây trồng', 6, 120, 25),
  ('weekly_feed', 3, 'feed', 'Chuỗi tuần 3: Cho vật nuôi ăn 3 lần', 3, 100, 20),
  ('weekly_orders', 4, 'order', 'Chuỗi tuần 4: Hoàn thành 3 đơn hàng', 3, 200, 40);

create table public.player_weekly_quests_v2 (
  user_id uuid not null references auth.users (id) on delete restrict,
  week_start date not null,
  quest_id text not null references public.weekly_quest_catalog_v2 (quest_id) on delete restrict,
  progress integer not null default 0 check (progress >= 0),
  target integer not null check (target > 0),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  claimed_at timestamptz,
  created_at timestamptz not null default transaction_timestamp(),
  updated_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, week_start, quest_id),
  check (progress <= target)
);

create index player_weekly_quests_period_idx
  on public.player_weekly_quests_v2 (week_start, user_id);
create index economy_requests_completed_action_idx
  on public.economy_requests (user_id, operation_type, completed_at)
  where completed_at is not null;

alter table public.weekly_quest_catalog_v2 enable row level security;
alter table public.player_weekly_quests_v2 enable row level security;
revoke all on table public.weekly_quest_catalog_v2 from public, anon, authenticated;
revoke all on table public.player_weekly_quests_v2 from public, anon, authenticated;
grant select on table public.player_weekly_quests_v2 to authenticated;
create policy player_weekly_quests_read_own_v2
  on public.player_weekly_quests_v2 for select to authenticated
  using ((select auth.uid()) = user_id);

create function public.refresh_my_weekly_quests_internal_v2()
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
  v_week_start date;
  v_week_begin timestamptz;
  v_week_end timestamptz;
  v_from timestamptz;
  v_previous_claim timestamptz;
  v_quest public.weekly_quest_catalog_v2%rowtype;
  v_count bigint;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  v_week_start := v_date - (extract(isodow from v_date)::integer - 1);
  v_week_begin := v_week_start::timestamp at time zone 'Asia/Ho_Chi_Minh';
  v_week_end := (v_week_start + 7)::timestamp at time zone 'Asia/Ho_Chi_Minh';

  insert into public.player_weekly_quests_v2
    (user_id, week_start, quest_id, progress, target, reward_coins, reward_xp)
  select v_uid, v_week_start, c.quest_id, 0, c.target, c.reward_coins, c.reward_xp
  from public.weekly_quest_catalog_v2 c where c.enabled
  on conflict (user_id, week_start, quest_id) do nothing;

  for v_quest in
    select * from public.weekly_quest_catalog_v2 where enabled order by chain_step
  loop
    if v_quest.chain_step = 1 then
      v_from := v_week_begin;
    else
      select q.claimed_at into v_previous_claim
      from public.weekly_quest_catalog_v2 prior
      join public.player_weekly_quests_v2 q
        on q.quest_id = prior.quest_id and q.user_id = v_uid and q.week_start = v_week_start
      where prior.chain_step = v_quest.chain_step - 1;
      if v_previous_claim is null then
        update public.player_weekly_quests_v2
        set progress = 0, updated_at = v_now
        where user_id = v_uid and week_start = v_week_start and quest_id = v_quest.quest_id;
        continue;
      end if;
      v_from := v_previous_claim;
    end if;

    if v_quest.action_type = 'plant' then
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'plant_crop_v2'
        and r.completed_at >= v_from and r.completed_at < least(v_week_end, v_now + interval '1 microsecond')
        and r.response->>'ok' = 'true';
    elsif v_quest.action_type = 'harvest' then
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'harvest_crop_v2'
        and r.completed_at >= v_from and r.completed_at < least(v_week_end, v_now + interval '1 microsecond')
        and r.response->>'ok' = 'true';
    elsif v_quest.action_type = 'feed' then
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'feed_animal_v2'
        and r.completed_at >= v_from and r.completed_at < least(v_week_end, v_now + interval '1 microsecond')
        and r.response->>'ok' = 'true';
    else
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'fulfill_daily_order_v2'
        and r.completed_at >= v_from and r.completed_at < least(v_week_end, v_now + interval '1 microsecond')
        and r.response->>'ok' = 'true' and r.response->>'already_fulfilled' = 'false';
    end if;
    update public.player_weekly_quests_v2
    set progress = least(v_quest.target, coalesce(v_count, 0))::integer, updated_at = v_now
    where user_id = v_uid and week_start = v_week_start and quest_id = v_quest.quest_id
      and claimed_at is null;
  end loop;
end;
$$;

create function public.get_my_weekly_quests_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
  v_week_start date;
  v_wallet public.player_wallets%rowtype;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  v_week_start := v_date - (extract(isodow from v_date)::integer - 1);
  perform public.refresh_my_weekly_quests_internal_v2();
  return jsonb_build_object('ok', true, 'week_start', v_week_start,
    'week_end', v_week_start + 6, 'quests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'quest_id', q.quest_id, 'chain_step', c.chain_step, 'action_type', c.action_type,
        'title', c.title, 'progress', q.progress, 'target', q.target,
        'reward_coins', q.reward_coins, 'reward_xp', q.reward_xp,
        'claimed_at', q.claimed_at,
        'locked', case when c.chain_step = 1 then false else not exists (
          select 1 from public.weekly_quest_catalog_v2 prior
          join public.player_weekly_quests_v2 pq
            on pq.quest_id = prior.quest_id and pq.user_id = v_uid and pq.week_start = v_week_start
          where prior.chain_step = c.chain_step - 1 and pq.claimed_at is not null
        ) end
      ) order by c.chain_step)
      from public.player_weekly_quests_v2 q
      join public.weekly_quest_catalog_v2 c using (quest_id)
      where q.user_id = v_uid and q.week_start = v_week_start
    ), '[]'::jsonb));
end;
$$;

create function public.claim_weekly_quest_v2(p_request_id uuid, p_quest_id text)
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
  v_week_start date;
  v_request public.economy_requests%rowtype;
  v_wallet public.player_wallets%rowtype;
  v_quest public.weekly_quest_catalog_v2%rowtype;
  v_player_quest public.player_weekly_quests_v2%rowtype;
  v_previous_claim timestamptz;
  v_xp_after bigint;
  v_level_before integer := 1;
  v_level_after integer := 1;
  v_level_coins bigint := 0;
  v_payload_hash text;
  v_response jsonb;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_quest_id is null then
    raise exception using errcode = '22023', message = 'Invalid weekly quest claim';
  end if;
  v_week_start := v_date - (extract(isodow from v_date)::integer - 1);
  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'claim_weekly_quest_v2', 'quest_id', p_quest_id
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'claim_weekly_quest_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'claim_weekly_quest_v2' or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  perform public.refresh_my_weekly_quests_internal_v2();
  select * into v_quest from public.weekly_quest_catalog_v2
  where quest_id = p_quest_id and enabled;
  if not found then
    raise exception using errcode = '22023', message = 'Unknown or disabled weekly quest';
  end if;
  select * into v_player_quest from public.player_weekly_quests_v2
  where user_id = v_uid and week_start = v_week_start and quest_id = p_quest_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Weekly quest state is unavailable';
  end if;
  if v_player_quest.claimed_at is not null then
    v_response := jsonb_build_object('ok', true, 'already_claimed', true,
      'quest_id', p_quest_id, 'week_start', v_week_start,
      'reward_coins', v_player_quest.reward_coins, 'reward_xp', v_player_quest.reward_xp);
    update public.economy_requests set response = v_response, completed_at = v_now
    where user_id = v_uid and request_id = p_request_id;
    return v_response;
  end if;
  if v_quest.chain_step > 1 then
    select pq.claimed_at into v_previous_claim
    from public.weekly_quest_catalog_v2 prior
    join public.player_weekly_quests_v2 pq
      on pq.quest_id = prior.quest_id and pq.user_id = v_uid and pq.week_start = v_week_start
    where prior.chain_step = v_quest.chain_step - 1;
    if v_previous_claim is null then
      raise exception using errcode = '55000', message = 'Previous weekly quest step is not claimed';
    end if;
  end if;
  if v_player_quest.progress < v_player_quest.target then
    raise exception using errcode = '55000', message = 'Weekly quest is not complete';
  end if;

  v_xp_after := v_wallet.xp + v_player_quest.reward_xp;
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
  set coins = coins + v_player_quest.reward_coins + v_level_coins,
      xp = v_xp_after, updated_at = v_now
  where user_id = v_uid;
  update public.player_weekly_quests_v2 set claimed_at = v_now, updated_at = v_now
  where user_id = v_uid and week_start = v_week_start and quest_id = p_quest_id;

  v_response := jsonb_build_object('ok', true, 'already_claimed', false,
    'quest_id', p_quest_id, 'week_start', v_week_start,
    'reward_coins', v_player_quest.reward_coins, 'reward_xp', v_player_quest.reward_xp,
    'level_up_coins', v_level_coins);
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  insert into public.reward_claims
    (user_id, reward_kind, period_key, source_id, request_id, response, created_at)
  values (v_uid, 'weekly_quest', v_week_start::text, p_quest_id, p_request_id, v_response, v_now);
  return v_response;
end;
$$;

revoke all on function public.refresh_my_weekly_quests_internal_v2() from public, anon, authenticated;
revoke all on function public.get_my_weekly_quests_v2() from public, anon, authenticated;
revoke all on function public.claim_weekly_quest_v2(uuid, text) from public, anon, authenticated;
grant execute on function public.get_my_weekly_quests_v2() to authenticated;
grant execute on function public.claim_weekly_quest_v2(uuid, text) to authenticated;

comment on function public.get_my_weekly_quests_v2() is
  'Returns the authenticated user weekly chain using Asia/Ho_Chi_Minh Monday weeks and progress derived only from completed server RPC ledger rows.';
comment on function public.claim_weekly_quest_v2(uuid, text) is
  'Atomically claims a server-computed weekly quest reward once; prior chain step and unique reward ledger are enforced.';

commit;
