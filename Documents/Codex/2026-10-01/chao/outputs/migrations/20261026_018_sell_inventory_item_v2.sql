-- Authenticated, idempotent server-side sale for canonical inventory.
-- Requires migrations 001, 003, 005 and public.game_global_config.
-- Applies only to the caller's canonical inventory and wallet.

begin;

create or replace function public.sell_inventory_item_v2(
  p_request_id uuid,
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
  v_config jsonb;
  v_stock bigint;
  v_inventory_key text;
  v_base_price numeric;
  v_multiplier numeric;
  v_unit_price bigint;
  v_total bigint;
  v_xp_award bigint;
  v_xp_after bigint;
  v_level_before integer := 1;
  v_level_after integer := 1;
  v_level_coins bigint := 0;
  v_is_product boolean := false;
  v_payload_hash text;
  v_response jsonb;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_item_key is null
     or p_quantity is null or p_quantity < 1 or p_quantity > 99 then
    raise exception using errcode = '22023', message = 'Invalid sale request';
  end if;
  v_inventory_key := case p_item_key
    when 'berryYogurt' then 'berry_yogurt'
    when 'pumpkinPie' then 'pumpkin_pie'
    when 'fishStew' then 'fish_stew'
    when 'cornSausage' then 'corn_sausage'
    else p_item_key
  end;

  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'sell_inventory_item_v2',
    'item_key', p_item_key,
    'quantity', p_quantity
  )::text, 'UTF8')), 'hex');

  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'sell_inventory_item_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'sell_inventory_item_v2'
     or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different sale';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select config into v_config from public.game_global_config where id = 1;
  if v_config is null then
    raise exception using errcode = '55000', message = 'Server sale configuration is unavailable';
  end if;
  v_multiplier := greatest(0, coalesce(nullif(v_config->>'sellMultiplier','')::numeric, 1));

  if exists (select 1 from public.crop_action_catalog_v2 where crop_key = p_item_key and enabled) then
    -- Prices are chosen by the server. Keep a server-owned fallback so older
    -- game_global_config rows missing newer crop prices do not block sales.
    v_base_price := coalesce(
      nullif(v_config->'cropSellPrices'->>p_item_key, '')::numeric,
      case p_item_key
        when 'carrot' then 18 when 'tomato' then 33 when 'potato' then 38
        when 'corn' then 55 when 'pumpkin' then 72 when 'berry' then 78
        when 'sunflower' then 96 when 'watermelon' then 118
        when 'eggplant' then 145 when 'pineapple' then 180 when 'grape' then 225
        else null
      end
    );
  elsif p_item_key in ('eggs','milk','pork','fish') then
    v_base_price := coalesce(
      nullif(v_config->'animalSellPrices'->>p_item_key, '')::numeric,
      case p_item_key
        when 'eggs' then 18 when 'milk' then 30 when 'pork' then 52 when 'fish' then 38
        else null
      end
    );
    v_is_product := true;
  else
    v_base_price := case p_item_key
      when 'berryYogurt' then 260
      when 'pumpkinPie' then 165
      when 'fishStew' then 220
      when 'cornSausage' then 260
      when 'orange_fruit' then 18
      when 'mango_fruit' then 30
      when 'guava_fruit' then 24
      when 'lychee_fruit' then 42
      else null
    end;
    v_is_product := true;
  end if;
  if v_base_price is null or v_base_price <= 0 or v_multiplier <= 0 then
    raise exception using errcode = '22023', message = 'Item cannot be sold or server price is missing';
  end if;
  v_unit_price := greatest(1, round(v_base_price * v_multiplier))::bigint;
  v_total := v_unit_price * p_quantity;
  if v_is_product then
    v_xp_award := greatest(0, round(
      p_quantity * 2 * coalesce(nullif(v_config->>'xpMultiplier','')::numeric, 1)
    ))::bigint;
  else
    v_xp_award := greatest(0, round(
      greatest(1, floor(p_quantity * v_unit_price / 12))
      * coalesce(nullif(v_config->>'xpMultiplier','')::numeric, 1)
    ))::bigint;
  end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  select quantity into v_stock from public.player_inventory
  where user_id = v_uid and item_key = v_inventory_key for update;
  if not found or v_stock < p_quantity then
    raise exception using errcode = '22023',
      message = 'Insufficient inventory: server stock is lower than requested quantity';
  end if;

  v_xp_after := v_wallet.xp + v_xp_award;
  while v_level_before < 60 and v_wallet.xp >=
    (80 * v_level_before + 10 * v_level_before * (v_level_before - 1)) loop
    v_level_before := v_level_before + 1;
  end loop;
  while v_level_after < 60 and v_xp_after >=
    (80 * v_level_after + 10 * v_level_after * (v_level_after - 1)) loop
    v_level_after := v_level_after + 1;
  end loop;
  v_level_coins := greatest(0, v_level_after - v_level_before) * 30;

  update public.player_inventory
  set quantity = quantity - p_quantity, updated_at = v_now
  where user_id = v_uid and item_key = v_inventory_key;
  update public.player_wallets
  set coins = coins + v_total + v_level_coins,
      xp = v_xp_after,
      updated_at = v_now
  where user_id = v_uid;

  v_response := jsonb_build_object(
    'ok', true,
    'item_key', p_item_key,
    'quantity_sold', p_quantity,
    'unit_price', v_unit_price,
    'total_earned', v_total,
    'level_up_coins', v_level_coins,
    'coins_remaining', v_wallet.coins + v_total + v_level_coins,
    'xp_total', v_xp_after,
    'inventory_quantity', v_stock - p_quantity
  );
  update public.economy_requests
  set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;

revoke all on function public.sell_inventory_item_v2(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function public.sell_inventory_item_v2(uuid, text, integer)
  to authenticated;

comment on function public.sell_inventory_item_v2(uuid, text, integer) is
  'Sell only server-approved crop, animal, crafted or orchard inventory at server-configured prices; deduct stock and credit the authenticated wallet atomically and idempotently.';

commit;
