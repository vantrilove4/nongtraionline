-- Phase 2 foundation + daily quest read path (dark launch).
-- Apply only to a reviewed staging database. This file has NOT been executed.
-- It does not read, update, or migrate game_saves and does not award anything.

begin;

create table public.player_wallets (
  user_id uuid primary key references auth.users (id) on delete restrict,
  coins bigint not null default 0 check (coins >= 0),
  xp bigint not null default 0 check (xp >= 0),
  updated_at timestamptz not null default transaction_timestamp()
);

create table public.player_inventory (
  user_id uuid not null references auth.users (id) on delete restrict,
  item_key text not null check (item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  quantity bigint not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, item_key)
);

create table public.player_farm_state (
  user_id uuid primary key references auth.users (id) on delete restrict,
  farm_state jsonb not null default '{}'::jsonb check (jsonb_typeof(farm_state) = 'object'),
  schema_version integer not null default 1 check (schema_version > 0),
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default transaction_timestamp()
);

create table public.daily_quest_catalog (
  quest_id text primary key check (quest_id ~ '^[a-z][a-z0-9_]{0,63}$'),
  action_type text not null check (action_type in ('plant', 'harvest', 'feed')),
  title text not null,
  target integer not null check (target > 0),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default transaction_timestamp()
);

insert into public.daily_quest_catalog
  (quest_id, action_type, title, target, reward_coins, reward_xp)
values
  ('plant', 'plant', 'Gieo 2 hạt giống', 2, 12, 5),
  ('harvest', 'harvest', 'Thu hoạch 1 cây trồng', 1, 18, 5),
  ('feed', 'feed', 'Cho vật nuôi ăn 1 lần', 1, 12, 5);

create table public.player_daily_quests (
  user_id uuid not null references auth.users (id) on delete restrict,
  period_date date not null,
  quest_id text not null references public.daily_quest_catalog (quest_id) on delete restrict,
  progress integer not null default 0 check (progress >= 0),
  target integer not null check (target > 0),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  claimed_at timestamptz,
  created_at timestamptz not null default transaction_timestamp(),
  updated_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, period_date, quest_id),
  check (progress <= target)
);

create table public.economy_requests (
  user_id uuid not null references auth.users (id) on delete restrict,
  request_id uuid not null,
  operation_type text not null check (operation_type ~ '^[a-z][a-z0-9_]{0,63}$'),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  response jsonb,
  completed_at timestamptz,
  created_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, request_id),
  check ((response is null) = (completed_at is null))
);

create table public.reward_claims (
  user_id uuid not null references auth.users (id) on delete restrict,
  reward_kind text not null check (reward_kind ~ '^[a-z][a-z0-9_]{0,63}$'),
  period_key text not null check (length(period_key) between 1 and 32),
  source_id text not null check (length(source_id) between 1 and 96),
  request_id uuid not null,
  response jsonb not null,
  created_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, reward_kind, period_key, source_id),
  unique (user_id, request_id),
  foreign key (user_id, request_id)
    references public.economy_requests (user_id, request_id) on delete restrict
);

create index player_daily_quests_period_idx
  on public.player_daily_quests (period_date, user_id);

alter table public.player_wallets enable row level security;
alter table public.player_inventory enable row level security;
alter table public.player_farm_state enable row level security;
alter table public.daily_quest_catalog enable row level security;
alter table public.player_daily_quests enable row level security;
alter table public.economy_requests enable row level security;
alter table public.reward_claims enable row level security;

revoke all on table public.player_wallets from public, anon, authenticated;
revoke all on table public.player_inventory from public, anon, authenticated;
revoke all on table public.player_farm_state from public, anon, authenticated;
revoke all on table public.daily_quest_catalog from public, anon, authenticated;
revoke all on table public.player_daily_quests from public, anon, authenticated;
revoke all on table public.economy_requests from public, anon, authenticated;
revoke all on table public.reward_claims from public, anon, authenticated;

grant select on table public.player_wallets to authenticated;
grant select on table public.player_inventory to authenticated;
grant select on table public.player_farm_state to authenticated;
grant select on table public.player_daily_quests to authenticated;

create policy player_wallets_read_own
  on public.player_wallets for select to authenticated
  using ((select auth.uid()) = user_id);
create policy player_inventory_read_own
  on public.player_inventory for select to authenticated
  using ((select auth.uid()) = user_id);
create policy player_farm_state_read_own
  on public.player_farm_state for select to authenticated
  using ((select auth.uid()) = user_id);
create policy player_daily_quests_read_own
  on public.player_daily_quests for select to authenticated
  using ((select auth.uid()) = user_id);

create function public.get_my_daily_quests_v2()
returns table (
  period_date date,
  quest_id text,
  action_type text,
  title text,
  progress integer,
  target integer,
  reward_coins bigint,
  reward_xp bigint,
  claimed_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_period_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;

  insert into public.player_daily_quests
    (user_id, period_date, quest_id, progress, target, reward_coins, reward_xp)
  select v_uid, v_period_date, c.quest_id, 0, c.target, c.reward_coins, c.reward_xp
  from public.daily_quest_catalog as c
  where c.enabled
  on conflict (user_id, period_date, quest_id) do nothing;

  return query
  select q.period_date, q.quest_id, c.action_type, c.title,
         q.progress, q.target, q.reward_coins, q.reward_xp, q.claimed_at
  from public.player_daily_quests as q
  join public.daily_quest_catalog as c using (quest_id)
  where q.user_id = v_uid and q.period_date = v_period_date
  order by q.quest_id;
end;
$$;

revoke all on function public.get_my_daily_quests_v2() from public, anon, authenticated;
grant execute on function public.get_my_daily_quests_v2() to authenticated;

comment on table public.player_wallets is
  'Dark-launch canonical wallet. Server RPCs only may mutate; client roles are read-only.';
comment on table public.player_inventory is
  'Dark-launch canonical inventory. Client roles are read-only; no legacy save import.';
comment on table public.player_farm_state is
  'Dark-launch canonical farm state. revision is conflict detection only, not economy validation.';
comment on table public.economy_requests is
  'Server-only idempotency records; payload hash and response must be written in the same transaction as effects.';
comment on table public.reward_claims is
  'Server-only domain-level deduplication for claims; no historical claims are imported.';
comment on function public.get_my_daily_quests_v2() is
  'Returns/initializes only the authenticated user daily quest display rows for Asia/Ho_Chi_Minh server date. It cannot advance progress or claim rewards.';

commit;
