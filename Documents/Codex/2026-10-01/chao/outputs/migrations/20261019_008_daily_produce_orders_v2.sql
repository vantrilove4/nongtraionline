-- Phase 2, canonical daily produce orders (dark launch).
-- Draft only; do not execute until reviewed and approved.
-- Depends on migrations 001 and 003 plus public.game_global_config.
-- No client or legacy game_saves writes are changed here.

begin;

create table public.daily_order_catalog_v2 (
  template_id text primary key check (template_id ~ '^[a-z][a-z0-9_]{0,63}$'),
  item_key text not null unique check (item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  quantity_requested integer not null check (quantity_requested between 1 and 99),
  reward_xp bigint not null check (reward_xp >= 0),
  unlock_level integer not null check (unlock_level > 0),
  coin_factor numeric(5,2) not null default 1.25 check (coin_factor between 1 and 5),
  enabled boolean not null default true,
  updated_at timestamptz not null default transaction_timestamp()
);

insert into public.daily_order_catalog_v2
  (template_id, item_key, quantity_requested, reward_xp, unlock_level)
values
  ('carrot_crate', 'carrot', 3, 4, 1),
  ('tomato_crate', 'tomato', 3, 5, 1),
  ('potato_sack', 'potato', 3, 6, 3),
  ('corn_bundle', 'corn', 4, 8, 5),
  ('pumpkin_cart', 'pumpkin', 2, 10, 7),
  ('berry_basket', 'berry', 4, 9, 8),
  ('sunflower_bundle', 'sunflower', 3, 10, 10),
  ('watermelon_cart', 'watermelon', 2, 12, 12),
  ('eggplant_crate', 'eggplant', 2, 13, 15),
  ('pineapple_crate', 'pineapple', 2, 15, 18),
  ('grape_box', 'grape', 2, 16, 22),
  ('egg_basket', 'eggs', 4, 7, 5),
  ('milk_cans', 'milk', 2, 9, 15),
  ('pork_delivery', 'pork', 2, 10, 10),
  ('fish_crate', 'fish', 3, 8, 20);

create table public.player_daily_orders_v2 (
  user_id uuid not null references auth.users (id) on delete restrict,
  order_date date not null,
  slot_no smallint not null check (slot_no between 1 and 3),
  template_id text not null references public.daily_order_catalog_v2 (template_id) on delete restrict,
  item_key text not null check (item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  quantity_requested integer not null check (quantity_requested between 1 and 99),
  reward_coins bigint not null check (reward_coins >= 0),
  reward_xp bigint not null check (reward_xp >= 0),
  status text not null default 'open' check (status in ('open', 'fulfilled')),
  fulfilled_at timestamptz,
  request_id uuid,
  created_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, order_date, slot_no),
  unique (user_id, order_date, item_key),
  foreign key (user_id, request_id)
    references public.economy_requests (user_id, request_id) on delete restrict,
  check ((status = 'open' and fulfilled_at is null and request_id is null)
      or (status = 'fulfilled' and fulfilled_at is not null and request_id is not null))
);

create index player_daily_orders_recent_idx
  on public.player_daily_orders_v2 (user_id, order_date desc);

alter table public.daily_order_catalog_v2 enable row level security;
alter table public.player_daily_orders_v2 enable row level security;
revoke all on table public.daily_order_catalog_v2 from public, anon, authenticated;
revoke all on table public.player_daily_orders_v2 from public, anon, authenticated;

create function public.get_my_daily_orders_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
  v_wallet public.player_wallets%rowtype;
  v_config jsonb;
  v_level integer := 1;
  v_slot integer;
  v_template public.daily_order_catalog_v2%rowtype;
  v_price numeric;
  v_reward_coins bigint;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  select config into v_config from public.game_global_config where id = 1;
  if v_config is null then
    raise exception using errcode = '55000', message = 'Server game configuration is unavailable';
  end if;
  while v_level < 60 and v_wallet.xp >=
    (80 * v_level + 10 * v_level * (v_level - 1)) loop
    v_level := v_level + 1;
  end loop;

  for v_slot in 1..3 loop
    if exists (select 1 from public.player_daily_orders_v2
      where user_id = v_uid and order_date = v_date and slot_no = v_slot) then
      continue;
    end if;
    select c.* into v_template
    from public.daily_order_catalog_v2 c
    where c.enabled and c.unlock_level <= v_level
      and not exists (
        select 1 from public.player_daily_orders_v2 o
        where o.user_id = v_uid and o.order_date = v_date and o.item_key = c.item_key
      )
    order by md5(v_uid::text || v_date::text || v_slot::text || c.template_id)
    limit 1;
    if not found then
      raise exception using errcode = '55000', message = 'Not enough daily order templates for this level';
    end if;

    if v_template.item_key in ('eggs', 'milk', 'pork', 'fish') then
      v_price := (v_config->'animalSellPrices'->>v_template.item_key)::numeric;
    else
      v_price := (v_config->'cropSellPrices'->>v_template.item_key)::numeric;
    end if;
    if v_price is null or v_price <= 0 then
      raise exception using errcode = '55000', message = 'Order item price is missing from server configuration';
    end if;
    v_reward_coins := greatest(0, round(v_price * v_template.quantity_requested
      * v_template.coin_factor * coalesce((v_config->>'sellMultiplier')::numeric, 1)))::bigint;
    insert into public.player_daily_orders_v2
      (user_id, order_date, slot_no, template_id, item_key,
       quantity_requested, reward_coins, reward_xp)
    values (v_uid, v_date, v_slot, v_template.template_id, v_template.item_key,
      v_template.quantity_requested, v_reward_coins,
      greatest(0, round(v_template.reward_xp * coalesce((v_config->>'xpMultiplier')::numeric, 1)))::bigint);
  end loop;

  return jsonb_build_object('ok', true, 'order_date', v_date, 'orders',
    coalesce((select jsonb_agg(jsonb_build_object(
      'slot', o.slot_no, 'item_key', o.item_key, 'quantity', o.quantity_requested,
      'reward_coins', o.reward_coins, 'reward_xp', o.reward_xp, 'status', o.status,
      'fulfilled_at', o.fulfilled_at
    ) order by o.slot_no)
    from public.player_daily_orders_v2 o
    where o.user_id = v_uid and o.order_date = v_date), '[]'::jsonb));
end;
$$;

create function public.fulfill_daily_order_v2(p_request_id uuid, p_slot_no smallint)
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
  v_order public.player_daily_orders_v2%rowtype;
  v_item_quantity bigint;
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
  if p_request_id is null or p_slot_no is null or p_slot_no not between 1 and 3 then
    raise exception using errcode = '22023', message = 'Invalid daily order request';
  end if;
  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'fulfill_daily_order_v2', 'slot', p_slot_no
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'fulfill_daily_order_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'fulfill_daily_order_v2'
     or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  -- Also creates the day's deterministic three orders if the client did not fetch the board first.
  perform public.get_my_daily_orders_v2();
  select * into v_order from public.player_daily_orders_v2
  where user_id = v_uid and order_date = v_date and slot_no = p_slot_no for update;
  if not found then
    raise exception using errcode = '55000', message = 'Daily order does not exist';
  end if;
  if v_order.status = 'fulfilled' then
    v_response := jsonb_build_object('ok', true, 'already_fulfilled', true,
      'order_date', v_date, 'slot', p_slot_no, 'item_key', v_order.item_key,
      'quantity', v_order.quantity_requested, 'reward_coins', v_order.reward_coins,
      'reward_xp', v_order.reward_xp);
    update public.economy_requests set response = v_response, completed_at = v_now
    where user_id = v_uid and request_id = p_request_id;
    return v_response;
  end if;

  select quantity into v_item_quantity from public.player_inventory
  where user_id = v_uid and item_key = v_order.item_key for update;
  if not found or v_item_quantity < v_order.quantity_requested then
    raise exception using errcode = '55000', message = 'Insufficient inventory for this order';
  end if;

  update public.player_inventory set quantity = quantity - v_order.quantity_requested, updated_at = v_now
  where user_id = v_uid and item_key = v_order.item_key;
  v_xp_after := v_wallet.xp + v_order.reward_xp;
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
  set coins = coins + v_order.reward_coins + v_level_coins,
      xp = v_xp_after, updated_at = v_now
  where user_id = v_uid;
  update public.player_daily_orders_v2
  set status = 'fulfilled', fulfilled_at = v_now, request_id = p_request_id
  where user_id = v_uid and order_date = v_date and slot_no = p_slot_no;

  v_response := jsonb_build_object('ok', true, 'already_fulfilled', false,
    'order_date', v_date, 'slot', p_slot_no, 'item_key', v_order.item_key,
    'quantity_delivered', v_order.quantity_requested, 'reward_coins', v_order.reward_coins,
    'reward_xp', v_order.reward_xp, 'level_up_coins', v_level_coins,
    'inventory_remaining', v_item_quantity - v_order.quantity_requested);
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  insert into public.reward_claims
    (user_id, reward_kind, period_key, source_id, request_id, response, created_at)
  values (v_uid, 'daily_order', v_date::text, p_slot_no::text, p_request_id, v_response, v_now);
  return v_response;
end;
$$;

revoke all on function public.get_my_daily_orders_v2() from public, anon, authenticated;
revoke all on function public.fulfill_daily_order_v2(uuid, smallint) from public, anon, authenticated;
grant execute on function public.get_my_daily_orders_v2() to authenticated;
grant execute on function public.fulfill_daily_order_v2(uuid, smallint) to authenticated;

comment on function public.get_my_daily_orders_v2() is
  'Returns or creates three deterministic daily orders from server catalog, level, prices, and Asia/Ho_Chi_Minh date.';
comment on function public.fulfill_daily_order_v2(uuid, smallint) is
  'Consumes only canonical inventory and grants the stored order reward atomically; duplicate fulfilment cannot pay twice.';

commit;
