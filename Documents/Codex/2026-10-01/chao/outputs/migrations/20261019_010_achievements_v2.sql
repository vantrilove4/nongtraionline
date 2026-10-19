-- Phase 2, server-derived achievements (dark launch).
-- Draft only; do not execute until reviewed and approved.
-- Depends on migration 001. Progress comes only from committed server RPC ledger rows.
-- No history is imported from game_saves or s.collections.

begin;

create table public.achievement_catalog_v2 (
  achievement_id text primary key check (achievement_id ~ '^[a-z][a-z0-9_]{0,63}$'),
  action_type text not null check (action_type in ('plant','harvest','feed','order','level')),
  title text not null,
  description text not null,
  target bigint not null check (target > 0),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default transaction_timestamp()
);

insert into public.achievement_catalog_v2
  (achievement_id, action_type, title, description, target, reward_coins, reward_xp)
values
  ('first_plant', 'plant', 'Mầm xanh đầu tiên', 'Gieo cây lần đầu tiên.', 1, 10, 5),
  ('first_harvest', 'harvest', 'Vụ mùa đầu tiên', 'Thu hoạch cây trồng lần đầu tiên.', 1, 20, 10),
  ('plant_25', 'plant', 'Bàn tay gieo trồng', 'Gieo tổng cộng 25 cây.', 25, 100, 30),
  ('harvest_25', 'harvest', 'Mùa bội thu', 'Thu hoạch tổng cộng 25 cây.', 25, 120, 40),
  ('feed_10', 'feed', 'Người bạn của vật nuôi', 'Cho vật nuôi ăn 10 lần.', 10, 100, 30),
  ('orders_10', 'order', 'Nhà cung ứng tin cậy', 'Hoàn thành 10 đơn hàng nông sản.', 10, 180, 50),
  ('level_10', 'level', 'Nông dân lành nghề', 'Đạt cấp 10.', 10, 150, 50);

create table public.player_achievements_v2 (
  user_id uuid not null references auth.users (id) on delete restrict,
  achievement_id text not null references public.achievement_catalog_v2 (achievement_id) on delete restrict,
  progress bigint not null default 0 check (progress >= 0),
  target bigint not null check (target > 0),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  unlocked_at timestamptz,
  claimed_at timestamptz,
  created_at timestamptz not null default transaction_timestamp(),
  updated_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, achievement_id),
  check (progress <= target),
  check (claimed_at is null or unlocked_at is not null)
);

create index if not exists economy_requests_completed_action_idx
  on public.economy_requests (user_id, operation_type, completed_at)
  where completed_at is not null;

alter table public.achievement_catalog_v2 enable row level security;
alter table public.player_achievements_v2 enable row level security;
revoke all on table public.achievement_catalog_v2 from public, anon, authenticated;
revoke all on table public.player_achievements_v2 from public, anon, authenticated;
grant select on table public.player_achievements_v2 to authenticated;
create policy player_achievements_read_own_v2
  on public.player_achievements_v2 for select to authenticated
  using ((select auth.uid()) = user_id);

create function public.refresh_my_achievements_internal_v2()
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_wallet public.player_wallets%rowtype;
  v_achievement public.achievement_catalog_v2%rowtype;
  v_level bigint := 1;
  v_count bigint;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  select * into v_wallet from public.player_wallets where user_id = v_uid;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  while v_level < 60 and v_wallet.xp >= (80 * v_level + 10 * v_level * (v_level - 1)) loop
    v_level := v_level + 1;
  end loop;

  insert into public.player_achievements_v2
    (user_id, achievement_id, progress, target, reward_coins, reward_xp)
  select v_uid, c.achievement_id, 0, c.target, c.reward_coins, c.reward_xp
  from public.achievement_catalog_v2 c where c.enabled
  on conflict (user_id, achievement_id) do nothing;

  for v_achievement in
    select * from public.achievement_catalog_v2 where enabled
  loop
    if v_achievement.action_type = 'level' then
      v_count := v_level;
    elsif v_achievement.action_type = 'plant' then
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'plant_crop_v2'
        and r.completed_at is not null and r.response->>'ok' = 'true';
    elsif v_achievement.action_type = 'harvest' then
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'harvest_crop_v2'
        and r.completed_at is not null and r.response->>'ok' = 'true';
    elsif v_achievement.action_type = 'feed' then
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'feed_animal_v2'
        and r.completed_at is not null and r.response->>'ok' = 'true';
    else
      select count(*) into v_count from public.economy_requests r
      where r.user_id = v_uid and r.operation_type = 'fulfill_daily_order_v2'
        and r.completed_at is not null and r.response->>'ok' = 'true'
        and r.response->>'already_fulfilled' = 'false';
    end if;
    update public.player_achievements_v2
    set progress = greatest(progress, least(v_achievement.target, coalesce(v_count, 0))),
        unlocked_at = case
          when unlocked_at is not null then unlocked_at
          when greatest(progress, least(v_achievement.target, coalesce(v_count, 0))) >= target then v_now
          else null end,
        updated_at = v_now
    where user_id = v_uid and achievement_id = v_achievement.achievement_id
      and claimed_at is null;
  end loop;
end;
$$;

create function public.get_my_achievements_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_wallet public.player_wallets%rowtype;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  perform public.refresh_my_achievements_internal_v2();
  return jsonb_build_object('ok', true, 'achievements', coalesce((
    select jsonb_agg(jsonb_build_object(
      'achievement_id', p.achievement_id, 'title', c.title, 'description', c.description,
      'progress', p.progress, 'target', p.target, 'reward_coins', p.reward_coins,
      'reward_xp', p.reward_xp, 'unlocked_at', p.unlocked_at, 'claimed_at', p.claimed_at
    ) order by c.action_type, c.achievement_id)
    from public.player_achievements_v2 p
    join public.achievement_catalog_v2 c using (achievement_id)
    where p.user_id = v_uid
  ), '[]'::jsonb));
end;
$$;

create function public.claim_achievement_v2(p_request_id uuid, p_achievement_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_request public.economy_requests%rowtype;
  v_wallet public.player_wallets%rowtype;
  v_achievement public.achievement_catalog_v2%rowtype;
  v_player_achievement public.player_achievements_v2%rowtype;
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
  if p_request_id is null or p_achievement_id is null then
    raise exception using errcode = '22023', message = 'Invalid achievement claim';
  end if;
  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'claim_achievement_v2', 'achievement_id', p_achievement_id
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'claim_achievement_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'claim_achievement_v2' or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  perform public.refresh_my_achievements_internal_v2();
  select * into v_achievement from public.achievement_catalog_v2
  where achievement_id = p_achievement_id and enabled;
  if not found then
    raise exception using errcode = '22023', message = 'Unknown or disabled achievement';
  end if;
  select * into v_player_achievement from public.player_achievements_v2
  where user_id = v_uid and achievement_id = p_achievement_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Achievement state is unavailable';
  end if;
  if v_player_achievement.claimed_at is not null then
    v_response := jsonb_build_object('ok', true, 'already_claimed', true,
      'achievement_id', p_achievement_id, 'reward_coins', v_player_achievement.reward_coins,
      'reward_xp', v_player_achievement.reward_xp);
    update public.economy_requests set response = v_response, completed_at = v_now
    where user_id = v_uid and request_id = p_request_id;
    return v_response;
  end if;
  if v_player_achievement.unlocked_at is null or v_player_achievement.progress < v_player_achievement.target then
    raise exception using errcode = '55000', message = 'Achievement is not unlocked';
  end if;

  v_xp_after := v_wallet.xp + v_player_achievement.reward_xp;
  while v_level_before < 60 and v_wallet.xp >= (80 * v_level_before + 10 * v_level_before * (v_level_before - 1)) loop
    v_level_before := v_level_before + 1;
  end loop;
  while v_level_after < 60 and v_xp_after >= (80 * v_level_after + 10 * v_level_after * (v_level_after - 1)) loop
    v_level_after := v_level_after + 1;
  end loop;
  v_level_coins := greatest(0, v_level_after - v_level_before) * 30;
  update public.player_wallets
  set coins = coins + v_player_achievement.reward_coins + v_level_coins,
      xp = v_xp_after, updated_at = v_now
  where user_id = v_uid;
  update public.player_achievements_v2 set claimed_at = v_now, updated_at = v_now
  where user_id = v_uid and achievement_id = p_achievement_id;

  v_response := jsonb_build_object('ok', true, 'already_claimed', false,
    'achievement_id', p_achievement_id, 'reward_coins', v_player_achievement.reward_coins,
    'reward_xp', v_player_achievement.reward_xp, 'level_up_coins', v_level_coins);
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  insert into public.reward_claims
    (user_id, reward_kind, period_key, source_id, request_id, response, created_at)
  values (v_uid, 'achievement', 'once', p_achievement_id, p_request_id, v_response, v_now);
  return v_response;
end;
$$;

revoke all on function public.refresh_my_achievements_internal_v2() from public, anon, authenticated;
revoke all on function public.get_my_achievements_v2() from public, anon, authenticated;
revoke all on function public.claim_achievement_v2(uuid, text) from public, anon, authenticated;
grant execute on function public.get_my_achievements_v2() to authenticated;
grant execute on function public.claim_achievement_v2(uuid, text) to authenticated;

comment on function public.get_my_achievements_v2() is
  'Returns achievements whose progress is calculated from canonical wallet level and completed server RPC ledger events; legacy save history is excluded.';
comment on function public.claim_achievement_v2(uuid, text) is
  'Claims an unlocked achievement reward once, atomically updating canonical wallet and reward ledger.';

commit;
