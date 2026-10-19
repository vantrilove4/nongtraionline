-- Phase 2, canonical purchase slice (dark launch).
-- Depends on migrations 001-003 and public.game_global_config.
-- Draft only: do not execute until migrations 003-004 have passed staging behavior tests.
-- Does not update game_saves or connect the game clients.

begin;

alter table public.crop_action_catalog_v2
  add column seed_price bigint;

update public.crop_action_catalog_v2
set seed_price = case crop_key
  when 'carrot' then 8
  when 'tomato' then 14
  when 'potato' then 16
  when 'corn' then 22
  when 'pumpkin' then 28
  when 'berry' then 30
  when 'sunflower' then 36
  when 'watermelon' then 42
  when 'eggplant' then 50
  when 'pineapple' then 62
  when 'grape' then 76
  else null
end;

alter table public.crop_action_catalog_v2
  alter column seed_price set not null,
  add constraint crop_action_catalog_v2_seed_price_check check (seed_price > 0);

create function public.purchase_farm_item_internal_v2(
  p_request_id uuid,
  p_item_type text,
  p_item_key text,
  p_quantity integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_wallet public.player_wallets%rowtype;
  v_request public.economy_requests%rowtype;
  v_crop public.crop_action_catalog_v2%rowtype;
  v_config jsonb;
  v_seed_item_key text;
  v_inventory_key text;
  v_price bigint;
  v_total bigint;
  v_level integer := 1;
  v_payload_hash text;
  v_response jsonb;
  v_stock bigint;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_item_type is null or p_item_key is null
     or p_quantity is null or p_quantity < 1 or p_quantity > 99
     or p_item_type not in ('seed', 'feed') then
    raise exception using errcode = '22023', message = 'Invalid purchase request';
  end if;

  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'purchase_farm_item_v2', 'item_type', p_item_type,
    'item_key', p_item_key, 'quantity', p_quantity
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'purchase_farm_item_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'purchase_farm_item_v2'
     or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different purchase';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  if p_item_type = 'seed' then
    select * into v_crop from public.crop_action_catalog_v2
    where crop_key = p_item_key and enabled;
    if not found then
      raise exception using errcode = '22023', message = 'Unknown or disabled seed';
    end if;
    v_inventory_key := v_crop.seed_item_key;
    v_price := v_crop.seed_price;
  else
    v_inventory_key := case p_item_key
      when 'chicken' then 'feed_chicken'
      when 'pig' then 'feed_pig'
      when 'cow' then 'feed_cow'
      when 'fish' then 'feed_fish'
      else null
    end;
    if v_inventory_key is null then
      raise exception using errcode = '22023', message = 'Unknown animal feed';
    end if;
    select config into v_config from public.game_global_config where id = 1;
    if v_config is null then
      raise exception using errcode = '55000', message = 'Server shop configuration is unavailable';
    end if;
    v_price := round(coalesce((v_config->>'feedPrice')::numeric, 8))::bigint;
    if v_price < 1 then
      raise exception using errcode = '55000', message = 'Server feed price is invalid';
    end if;
  end if;

  v_total := v_price * p_quantity;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  if p_item_type = 'seed' then
    while v_level < 60 and v_wallet.xp >=
      (80 * v_level + 10 * v_level * (v_level - 1)) loop
      v_level := v_level + 1;
    end loop;
    if v_level < v_crop.unlock_level then
      raise exception using errcode = '55000', message = 'Seed is still locked';
    end if;
  end if;
  if v_wallet.coins < v_total then
    raise exception using errcode = '55000', message = 'Insufficient coins';
  end if;

  update public.player_wallets
  set coins = coins - v_total, updated_at = v_now
  where user_id = v_uid;
  insert into public.player_inventory (user_id, item_key, quantity, updated_at)
  values (v_uid, v_inventory_key, p_quantity, v_now)
  on conflict (user_id, item_key) do update
    set quantity = public.player_inventory.quantity + excluded.quantity,
        updated_at = excluded.updated_at
  returning quantity into v_stock;

  v_response := jsonb_build_object(
    'ok', true, 'item_type', p_item_type, 'item_key', p_item_key,
    'inventory_key', v_inventory_key, 'quantity_bought', p_quantity,
    'unit_price', v_price, 'total_paid', v_total,
    'coins_remaining', v_wallet.coins - v_total, 'inventory_quantity', v_stock
  );
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;

create function public.buy_seed_v2(p_request_id uuid, p_crop_key text, p_quantity integer)
returns jsonb
language sql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
  select public.purchase_farm_item_internal_v2(p_request_id, 'seed', p_crop_key, p_quantity);
$$;

create function public.buy_animal_feed_v2(p_request_id uuid, p_animal_key text, p_quantity integer)
returns jsonb
language sql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
  select public.purchase_farm_item_internal_v2(p_request_id, 'feed', p_animal_key, p_quantity);
$$;

revoke all on function public.purchase_farm_item_internal_v2(uuid, text, text, integer)
  from public, anon, authenticated;
revoke all on function public.buy_seed_v2(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.buy_animal_feed_v2(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.buy_seed_v2(uuid, text, integer) to authenticated;
grant execute on function public.buy_animal_feed_v2(uuid, text, integer) to authenticated;

comment on function public.buy_seed_v2(uuid, text, integer) is
  'Buys 1-99 units of an unlocked server-catalog seed with canonical coins and idempotent atomic inventory update.';
comment on function public.buy_animal_feed_v2(uuid, text, integer) is
  'Buys 1-99 units of the selected animal feed using server-configured price and idempotent atomic wallet/inventory update.';

commit;
