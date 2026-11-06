-- Migration 021: retention-focused harvest pacing.
-- Apply after 001-020 and after supabase-admin-config.sql has installed its RPC.
-- Existing crop ready_at and animal ready_at timestamps are preserved; new cycles
-- use the updated durations. No inventory, XP, or save data is modified.
-- This file has NOT been run against staging or production.

begin;

update public.game_global_config
set config = config || jsonb_build_object(
  'cropHarvestSeconds', jsonb_build_object('carrot',30,'tomato',120,'potato',300,'corn',600,'pumpkin',1200,'berry',1800,'sunflower',3600,'watermelon',7200,'eggplant',10800,'pineapple',14400,'grape',21600),
  'animalHarvestSeconds', jsonb_build_object('chicken',600,'pig',1200,'cow',1800,'fish',2700)
),
updated_at=transaction_timestamp()
where id=1;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.game_global_config WHERE id=1) THEN
    RAISE EXCEPTION 'game_global_config row id=1 is missing';
  END IF;
END $$;

-- Preserve the fractional growth progress of existing orchard trees while
-- moving their active cycle to the new duration. Trees already ready stay ready.
UPDATE public.player_orchard_trees AS t
SET planted_at = CASE
  WHEN transaction_timestamp() >= t.planted_at + make_interval(secs => cycles.old_seconds)
    THEN transaction_timestamp() - make_interval(secs => cycles.new_seconds)
  ELSE transaction_timestamp() - make_interval(secs => floor(
    extract(epoch FROM (transaction_timestamp() - t.planted_at))
    / cycles.old_seconds * cycles.new_seconds
  )::integer)
END,
updated_at = transaction_timestamp()
FROM (VALUES
  ('orange',240,90),('mango',360,1200),('guava',300,600),('lychee',480,1800)
) AS cycles(species,old_seconds,new_seconds)
WHERE t.species=cycles.species;

create or replace function public.save_game_global_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_crop numeric;
  v_animal numeric;
  v_sell numeric;
  v_xp numeric;
  v_feed integer;
  v_notice text;
  v_crop_times jsonb;
  v_crop_prices jsonb;
  v_animal_times jsonb;
  v_animal_prices jsonb;
  v_config jsonb;
begin
  if auth.uid() is null then
    raise exception 'Bạn cần đăng nhập bằng tài khoản quản trị.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.game_admins as a where a.user_id = auth.uid()) then
    raise exception 'Tài khoản này không có quyền quản trị.' using errcode = '42501';
  end if;

  if jsonb_typeof(p_config) is distinct from 'object'
     or not (p_config ?& array['cropTimeMultiplier','animalTimeMultiplier','sellMultiplier','xpMultiplier','feedPrice','announcement','cropHarvestSeconds','cropSellPrices','animalHarvestSeconds','animalSellPrices']) then
    raise exception 'Cấu hình không đầy đủ hoặc sai định dạng.' using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_object_keys(p_config) as k(key)
    where k.key not in ('cropTimeMultiplier','animalTimeMultiplier','sellMultiplier','xpMultiplier','feedPrice','announcement','cropHarvestSeconds','cropSellPrices','animalHarvestSeconds','animalSellPrices')
  ) then
    raise exception 'Cấu hình chứa trường không được hỗ trợ.' using errcode = '22023';
  end if;

  if jsonb_typeof(p_config->'cropTimeMultiplier') is distinct from 'number'
     or jsonb_typeof(p_config->'animalTimeMultiplier') is distinct from 'number'
     or jsonb_typeof(p_config->'sellMultiplier') is distinct from 'number'
     or jsonb_typeof(p_config->'xpMultiplier') is distinct from 'number'
     or jsonb_typeof(p_config->'feedPrice') is distinct from 'number'
     or jsonb_typeof(p_config->'announcement') is distinct from 'string'
     or jsonb_typeof(p_config->'cropHarvestSeconds') is distinct from 'object'
     or jsonb_typeof(p_config->'cropSellPrices') is distinct from 'object'
     or jsonb_typeof(p_config->'animalHarvestSeconds') is distinct from 'object'
     or jsonb_typeof(p_config->'animalSellPrices') is distinct from 'object' then
    raise exception 'Một hoặc nhiều giá trị có sai kiểu dữ liệu.' using errcode = '22023';
  end if;

  v_crop_times := p_config->'cropHarvestSeconds';
  v_crop_prices := p_config->'cropSellPrices';
  v_animal_times := p_config->'animalHarvestSeconds';
  v_animal_prices := p_config->'animalSellPrices';

  if not (v_crop_times ?& array['carrot','tomato','potato','corn','pumpkin','berry','sunflower','watermelon','eggplant','pineapple','grape'])
     or not (v_crop_prices ?& array['carrot','tomato','potato','corn','pumpkin','berry','sunflower','watermelon','eggplant','pineapple','grape'])
     or not (v_animal_times ?& array['chicken','pig','cow','fish'])
     or not (v_animal_prices ?& array['eggs','milk','pork','fish']) then
    raise exception 'Thiếu thông tin thời gian hoặc giá của một loại cây/vật nuôi.' using errcode = '22023';
  end if;

  if exists (select 1 from jsonb_object_keys(v_crop_times) as k(key) where k.key not in ('carrot','tomato','potato','corn','pumpkin','berry','sunflower','watermelon','eggplant','pineapple','grape'))
     or exists (select 1 from jsonb_object_keys(v_crop_prices) as k(key) where k.key not in ('carrot','tomato','potato','corn','pumpkin','berry','sunflower','watermelon','eggplant','pineapple','grape'))
     or exists (select 1 from jsonb_object_keys(v_animal_times) as k(key) where k.key not in ('chicken','pig','cow','fish'))
     or exists (select 1 from jsonb_object_keys(v_animal_prices) as k(key) where k.key not in ('eggs','milk','pork','fish')) then
    raise exception 'Cấu hình có chứa loại cây hoặc vật nuôi không được hỗ trợ.' using errcode = '22023';
  end if;

  if exists (select 1 from jsonb_each(v_crop_times) as e(key,value) where jsonb_typeof(e.value) is distinct from 'number')
     or exists (select 1 from jsonb_each(v_crop_prices) as e(key,value) where jsonb_typeof(e.value) is distinct from 'number')
     or exists (select 1 from jsonb_each(v_animal_times) as e(key,value) where jsonb_typeof(e.value) is distinct from 'number')
     or exists (select 1 from jsonb_each(v_animal_prices) as e(key,value) where jsonb_typeof(e.value) is distinct from 'number') then
    raise exception 'Thời gian và giá từng loại phải là số.' using errcode = '22023';
  end if;

  if exists (select 1 from jsonb_each_text(v_crop_times) as e(key,value) where e.value::numeric < 30 or e.value::numeric > 86400 or trunc(e.value::numeric) <> e.value::numeric)
     or exists (select 1 from jsonb_each_text(v_animal_times) as e(key,value) where e.value::numeric < 60 or e.value::numeric > 86400 or trunc(e.value::numeric) <> e.value::numeric) then
    raise exception 'Thời gian cây trồng phải từ 30 đến 86400 giây; thời gian vật nuôi phải từ 60 đến 86400 giây.' using errcode = '22023';
  end if;

  if exists (select 1 from jsonb_each_text(v_crop_prices) as e(key,value) where e.value::numeric < 1 or e.value::numeric > 1000000 or trunc(e.value::numeric) <> e.value::numeric)
     or exists (select 1 from jsonb_each_text(v_animal_prices) as e(key,value) where e.value::numeric < 1 or e.value::numeric > 1000000 or trunc(e.value::numeric) <> e.value::numeric) then
    raise exception 'Giá bán phải là số nguyên từ 1 đến 1000000 xu.' using errcode = '22023';
  end if;

  v_crop := (p_config->>'cropTimeMultiplier')::numeric;
  v_animal := (p_config->>'animalTimeMultiplier')::numeric;
  v_sell := (p_config->>'sellMultiplier')::numeric;
  v_xp := (p_config->>'xpMultiplier')::numeric;
  v_feed := (p_config->>'feedPrice')::integer;
  v_notice := btrim(p_config->>'announcement');

  if v_crop < 0.25 or v_crop > 5
     or v_animal < 0.25 or v_animal > 5
     or v_sell < 0.25 or v_sell > 5
     or v_xp < 0.25 or v_xp > 5 then
    raise exception 'Các hệ số phải nằm trong khoảng 0,25 đến 5.' using errcode = '22023';
  end if;
  if v_feed < 1 or v_feed > 500 or v_feed::numeric <> (p_config->>'feedPrice')::numeric then
    raise exception 'Giá thức ăn phải là số nguyên từ 1 đến 500.' using errcode = '22023';
  end if;
  if char_length(v_notice) > 240 then
    raise exception 'Thông báo chung tối đa 240 ký tự.' using errcode = '22023';
  end if;

  v_config := jsonb_build_object(
    'cropTimeMultiplier', v_crop,
    'animalTimeMultiplier', v_animal,
    'sellMultiplier', v_sell,
    'xpMultiplier', v_xp,
    'feedPrice', v_feed,
    'announcement', v_notice,
    'cropHarvestSeconds', v_crop_times,
    'cropSellPrices', v_crop_prices,
    'animalHarvestSeconds', v_animal_times,
    'animalSellPrices', v_animal_prices
  );

  insert into public.game_global_config (id, config, updated_at, updated_by)
  values (1, v_config, now(), auth.uid())
  on conflict (id) do update
    set config = excluded.config,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by
  returning config into v_config;

  return v_config || jsonb_build_object('updated_at', now());
end;
$$;

create or replace function public.harvest_orchard_fruit_v1(p_request_id uuid,p_tree_id text)
  returns jsonb
  language plpgsql
  volatile
  security definer
  set search_path = pg_catalog, public, auth
  as $$
  declare
    v_uid uuid := auth.uid();
    v_now timestamptz := transaction_timestamp();
    v_tree public.player_orchard_trees%rowtype;
    v_request public.economy_requests%rowtype;
    v_wallet public.player_wallets%rowtype;
    v_item_key text;
    v_quantity integer := 3;
    v_cycle_seconds integer;
    v_payload_hash text;
    v_response jsonb;
    v_inventory_quantity bigint;
  begin
    if v_uid is null then raise exception using errcode = '28000', message = 'Authentication required'; end if;
    if p_request_id is null or p_tree_id is null or length(p_tree_id) not between 1 and 96 then
      raise exception using errcode = '22023', message = 'Invalid orchard harvest';
    end if;
    v_payload_hash := encode(sha256(convert_to(jsonb_build_object('operation','harvest_orchard_fruit_v1','tree_id',p_tree_id)::text,'UTF8')),'hex');
    insert into public.economy_requests(user_id,request_id,operation_type,payload_hash)
    values(v_uid,p_request_id,'harvest_orchard_fruit_v1',v_payload_hash) on conflict(user_id,request_id) do nothing;
    select * into v_request from public.economy_requests where user_id=v_uid and request_id=p_request_id for update;
    if not found or v_request.operation_type<>'harvest_orchard_fruit_v1' or v_request.payload_hash<>v_payload_hash then
      raise exception using errcode = '22023', message = 'Request id was already used for a different harvest';
    end if;
    if v_request.response is not null then return v_request.response; end if;
    select * into v_wallet from public.player_wallets where user_id=v_uid for update;
    if not found then raise exception using errcode = '55000', message = 'Canonical wallet is not initialized'; end if;
    select * into v_tree from public.player_orchard_trees where user_id=v_uid and tree_id=p_tree_id for update;
    if not found then raise exception using errcode = '42501', message = 'Orchard tree does not belong to this account'; end if;
    v_item_key := v_tree.species || '_fruit';
    v_cycle_seconds := case v_tree.species when 'orange' then 90 when 'mango' then 1200 when 'guava' then 600 when 'lychee' then 1800 end;
    if v_now < v_tree.planted_at + make_interval(secs => v_cycle_seconds) then
      raise exception using errcode = '22023', message = 'Fruit is not ready';
    end if;
    insert into public.player_inventory(user_id,item_key,quantity,updated_at)
    values(v_uid,v_item_key,v_quantity,v_now)
    on conflict(user_id,item_key) do update set quantity=public.player_inventory.quantity+excluded.quantity,updated_at=v_now
    returning quantity into v_inventory_quantity;
    update public.player_orchard_trees set planted_at=v_now,updated_at=v_now where user_id=v_uid and tree_id=p_tree_id;
    update public.player_wallets set xp=xp+5,updated_at=v_now where user_id=v_uid;
    v_response := jsonb_build_object('ok',true,'tree_id',p_tree_id,'species',v_tree.species,
      'planted_at_ms',(extract(epoch from v_now)*1000)::bigint,'item_key',v_item_key,
      'quantity_added',v_quantity,'inventory_quantity',v_inventory_quantity,
      'coins_remaining',v_wallet.coins,'xp_total',v_wallet.xp+5);
    update public.economy_requests set response=v_response,completed_at=v_now where user_id=v_uid and request_id=p_request_id;
    return v_response;
  end;
  $$;

commit;
