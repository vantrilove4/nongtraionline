-- Upgrade the initial six-paddy rice field to one contiguous field.
-- Safe to run after 20261028_022_rice_field_v1.sql, and also creates the
-- rice catalog/table prerequisites if that earlier migration was not applied.
-- Existing planted paddies are merged into one crop cycle with batch-scaled yield.
-- Do not run against production without the project's normal migration review.

begin;

insert into public.crop_action_catalog_v2
  (crop_key, seed_item_key, unlock_level, harvest_xp, enabled, seed_price)
values ('rice', 'seed_rice', 1, 14, true, 18)
on conflict (crop_key) do update set
  seed_item_key=excluded.seed_item_key,
  unlock_level=excluded.unlock_level,
  harvest_xp=excluded.harvest_xp,
  enabled=true,
  seed_price=excluded.seed_price;

update public.game_global_config
set config=jsonb_set(
  coalesce(config,'{}'::jsonb),
  '{cropSellPrices}',
  coalesce(config->'cropSellPrices','{}'::jsonb) || '{"rice":36}'::jsonb,
  true
)
where id=1;

create table if not exists public.player_rice_paddies_v1 (
  user_id uuid not null references auth.users(id) on delete restrict,
  paddy_index smallint not null check (paddy_index between 0 and 5),
  planted_at timestamptz,
  ready_at timestamptz,
  updated_at timestamptz not null default transaction_timestamp(),
  harvest_batches smallint not null default 1 check (harvest_batches between 1 and 6),
  primary key (user_id,paddy_index),
  check ((planted_at is null) = (ready_at is null)),
  check (ready_at is null or ready_at > planted_at)
);
alter table public.player_rice_paddies_v1
  add column if not exists harvest_batches smallint not null default 1;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.player_rice_paddies_v1'::regclass
      and conname='player_rice_paddies_harvest_batches_v2_check'
  ) then
    alter table public.player_rice_paddies_v1
      add constraint player_rice_paddies_harvest_batches_v2_check
      check (harvest_batches between 1 and 6);
  end if;
end $$;

alter table public.player_rice_paddies_v1 enable row level security;
revoke all on table public.player_rice_paddies_v1 from public,anon,authenticated;
grant select on table public.player_rice_paddies_v1 to authenticated;
drop policy if exists player_rice_paddies_read_own_v1 on public.player_rice_paddies_v1;
create policy player_rice_paddies_read_own_v1 on public.player_rice_paddies_v1
  for select to authenticated using ((select auth.uid())=user_id);

-- Merge all growing legacy paddies per account. Their harvest is delayed to
-- the latest existing ready_at, while their eventual yield and XP are retained.
insert into public.player_rice_paddies_v1
  (user_id,paddy_index,planted_at,ready_at,updated_at,harvest_batches)
select user_id,0,min(planted_at),max(ready_at),transaction_timestamp(),count(*)::smallint
from public.player_rice_paddies_v1
where planted_at is not null and ready_at is not null
group by user_id
on conflict (user_id,paddy_index) do update set
  planted_at=excluded.planted_at,
  ready_at=excluded.ready_at,
  updated_at=excluded.updated_at,
  harvest_batches=excluded.harvest_batches;

update public.player_rice_paddies_v1
set planted_at=null,ready_at=null,harvest_batches=1,updated_at=transaction_timestamp()
where paddy_index>0;

create or replace function public.get_my_rice_field_v2()
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_row public.player_rice_paddies_v1%rowtype;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  insert into public.player_rice_paddies_v1(user_id,paddy_index)
  values(v_uid,0) on conflict(user_id,paddy_index) do nothing;
  select * into v_row from public.player_rice_paddies_v1
  where user_id=v_uid and paddy_index=0;
  return jsonb_build_object('ok',true,'planted_at',v_row.planted_at,'ready_at',v_row.ready_at,
    'harvest_batches',v_row.harvest_batches);
end; $$;

create or replace function public.plant_rice_field_v2(p_request_id uuid)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,auth as $$
declare
  v_uid uuid:=auth.uid(); v_now timestamptz:=transaction_timestamp(); v_seconds integer;
  v_req jsonb; v_field public.player_rice_paddies_v1%rowtype; v_stock bigint;
  v_wallet public.player_wallets%rowtype; v_xp bigint:=2; v_bonus bigint; v_coins bigint;
  v_date date:=timezone('Asia/Ho_Chi_Minh',transaction_timestamp())::date; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if p_request_id is null then raise exception using errcode='22023',message='Request ID is required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'plant_rice_field_v2','{}'::jsonb);
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_wallet from public.player_wallets where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
  insert into public.player_rice_paddies_v1(user_id,paddy_index)
  values(v_uid,0) on conflict(user_id,paddy_index) do nothing;
  select * into v_field from public.player_rice_paddies_v1
  where user_id=v_uid and paddy_index=0 for update;
  if v_field.planted_at is not null then raise exception using errcode='55000',message='Rice field is already planted'; end if;
  select quantity into v_stock from public.player_inventory
  where user_id=v_uid and item_key='seed_rice' for update;
  if not found or v_stock<1 then raise exception using errcode='55000',message='No rice seeds available'; end if;
  select greatest(30,least(604800,round(
    coalesce(nullif(config->'cropHarvestSeconds'->>'rice','')::numeric,900)
    *coalesce(nullif(config->>'cropTimeMultiplier','')::numeric,1)
  )::integer)) into v_seconds from public.game_global_config where id=1;
  if v_seconds is null then raise exception using errcode='55000',message='Server game configuration is unavailable'; end if;
  update public.player_inventory set quantity=quantity-1,updated_at=v_now
  where user_id=v_uid and item_key='seed_rice';
  update public.player_rice_paddies_v1 set planted_at=v_now,
    ready_at=v_now+make_interval(secs=>v_seconds),harvest_batches=6,updated_at=v_now
  where user_id=v_uid and paddy_index=0;
  v_bonus:=public.canonical_level_bonus_v1(v_wallet.xp,v_xp);
  update public.player_wallets set xp=xp+v_xp,coins=coins+v_bonus,updated_at=v_now where user_id=v_uid;
  insert into public.player_daily_quests(user_id,period_date,quest_id,progress,target,reward_coins,reward_xp)
  select v_uid,v_date,c.quest_id,0,c.target,c.reward_coins,c.reward_xp
  from public.daily_quest_catalog c where c.enabled
  on conflict(user_id,period_date,quest_id) do nothing;
  update public.player_daily_quests set progress=least(target,progress+1),updated_at=v_now
  where user_id=v_uid and period_date=v_date and quest_id='plant';
  select coins into v_coins from public.player_wallets where user_id=v_uid;
  v_resp:=jsonb_build_object('ok',true,'planted_at',v_now,
    'ready_at',v_now+make_interval(secs=>v_seconds),'harvest_batches',6,
    'seed_quantity',v_stock-1,'xp_awarded',v_xp,'xp_total',v_wallet.xp+v_xp,
    'coins_remaining',v_coins);
  perform public.finish_economy_request_v1(p_request_id,v_resp);
  return v_resp;
end; $$;

create or replace function public.harvest_rice_field_v2(p_request_id uuid)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,auth as $$
declare
  v_uid uuid:=auth.uid(); v_now timestamptz:=transaction_timestamp(); v_req jsonb;
  v_field public.player_rice_paddies_v1%rowtype; v_wallet public.player_wallets%rowtype;
  v_config jsonb; v_batches integer; v_quantity bigint; v_xp bigint;
  v_bonus bigint; v_inventory bigint; v_coins bigint;
  v_date date:=timezone('Asia/Ho_Chi_Minh',transaction_timestamp())::date; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if p_request_id is null then raise exception using errcode='22023',message='Request ID is required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'harvest_rice_field_v2','{}'::jsonb);
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_wallet from public.player_wallets where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
  select * into v_field from public.player_rice_paddies_v1
  where user_id=v_uid and paddy_index=0 for update;
  if not found or v_field.ready_at is null then raise exception using errcode='55000',message='Rice field has no crop'; end if;
  if v_now<v_field.ready_at then raise exception using errcode='55000',message='Rice is not ready to harvest'; end if;
  select config into v_config from public.game_global_config where id=1;
  if v_config is null then raise exception using errcode='55000',message='Server game configuration is unavailable'; end if;
  v_batches:=greatest(1,least(6,v_field.harvest_batches));
  v_quantity:=2*v_batches;
  v_xp:=greatest(0,round(14*coalesce(nullif(v_config->>'xpMultiplier','')::numeric,1)))::bigint*v_batches;
  v_bonus:=public.canonical_level_bonus_v1(v_wallet.xp,v_xp);
  insert into public.player_inventory(user_id,item_key,quantity,updated_at)
  values(v_uid,'rice',v_quantity,v_now)
  on conflict(user_id,item_key) do update
    set quantity=public.player_inventory.quantity+excluded.quantity,updated_at=excluded.updated_at
  returning quantity into v_inventory;
  update public.player_wallets set xp=xp+v_xp,coins=coins+v_bonus,updated_at=v_now where user_id=v_uid;
  insert into public.player_daily_quests(user_id,period_date,quest_id,progress,target,reward_coins,reward_xp)
  select v_uid,v_date,c.quest_id,0,c.target,c.reward_coins,c.reward_xp
  from public.daily_quest_catalog c where c.enabled
  on conflict(user_id,period_date,quest_id) do nothing;
  update public.player_daily_quests set progress=least(target,progress+1),updated_at=v_now
  where user_id=v_uid and period_date=v_date and quest_id='harvest';
  update public.player_rice_paddies_v1 set planted_at=null,ready_at=null,
    harvest_batches=1,updated_at=v_now where user_id=v_uid and paddy_index=0;
  select coins into v_coins from public.player_wallets where user_id=v_uid;
  v_resp:=jsonb_build_object('ok',true,'quantity_added',v_quantity,'harvest_batches',v_batches,
    'inventory_quantity',v_inventory,'xp_awarded',v_xp,'xp_total',v_wallet.xp+v_xp,
    'coins_remaining',v_coins);
  perform public.finish_economy_request_v1(p_request_id,v_resp);
  return v_resp;
end; $$;

-- Keep older web tabs consistent with the single-field model. Legacy index 0
-- maps to the whole field; indexes 1-5 can no longer create hidden crops.
create or replace function public.get_my_rice_paddies_v1()
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_rows jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  insert into public.player_rice_paddies_v1(user_id,paddy_index)
  select v_uid,n::smallint from generate_series(0,5) gs(n)
  on conflict(user_id,paddy_index) do nothing;
  select coalesce(jsonb_agg(jsonb_build_object(
    'paddy_index',paddy_index,'planted_at',planted_at,'ready_at',ready_at
  ) order by paddy_index),'[]'::jsonb)
  into v_rows from public.player_rice_paddies_v1 where user_id=v_uid;
  return v_rows;
end; $$;

create or replace function public.plant_rice_paddy_v1(p_request_id uuid,p_paddy_index smallint)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,auth as $$
begin
  if p_paddy_index is distinct from 0 then
    raise exception using errcode='22023',message='The rice field is one contiguous plot';
  end if;
  return public.plant_rice_field_v2(p_request_id);
end; $$;

create or replace function public.harvest_rice_paddy_v1(p_request_id uuid,p_paddy_index smallint)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,auth as $$
begin
  if p_paddy_index is distinct from 0 then
    raise exception using errcode='22023',message='The rice field is one contiguous plot';
  end if;
  return public.harvest_rice_field_v2(p_request_id);
end; $$;

revoke all on function public.get_my_rice_field_v2() from public,anon,authenticated;
revoke all on function public.plant_rice_field_v2(uuid) from public,anon,authenticated;
revoke all on function public.harvest_rice_field_v2(uuid) from public,anon,authenticated;
revoke all on function public.get_my_rice_paddies_v1() from public,anon,authenticated;
revoke all on function public.plant_rice_paddy_v1(uuid,smallint) from public,anon,authenticated;
revoke all on function public.harvest_rice_paddy_v1(uuid,smallint) from public,anon,authenticated;
grant execute on function public.get_my_rice_field_v2() to authenticated;
grant execute on function public.plant_rice_field_v2(uuid) to authenticated;
grant execute on function public.harvest_rice_field_v2(uuid) to authenticated;
grant execute on function public.get_my_rice_paddies_v1() to authenticated;
grant execute on function public.plant_rice_paddy_v1(uuid,smallint) to authenticated;
grant execute on function public.harvest_rice_paddy_v1(uuid,smallint) to authenticated;

notify pgrst,'reload schema';
commit;
