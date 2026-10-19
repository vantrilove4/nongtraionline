-- Phase 2, canonical animal gameplay slice (dark launch).
-- Draft only. Depends on migrations 001-005 and staging behavior tests for 003-005.
-- Do not execute until reviewed and approved. Does not update game_saves or clients.

begin;

create table public.animal_variant_catalog_v2 (
  variant_id text primary key check (variant_id ~ '^[a-z][a-z0-9_]{0,63}$'),
  animal_key text not null check (animal_key in ('chicken', 'pig', 'cow', 'fish')),
  display_name text not null,
  price bigint not null check (price > 0),
  unlock_level integer not null check (unlock_level > 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default transaction_timestamp(),
  unique (variant_id, animal_key)
);

insert into public.animal_variant_catalog_v2
  (variant_id, animal_key, display_name, price, unlock_level)
values
  ('chicken_field', 'chicken', 'Gà ta', 180, 5),
  ('chicken_silkie', 'chicken', 'Gà ác', 320, 5),
  ('chicken_golden', 'chicken', 'Gà vàng mơ', 480, 5),
  ('chicken_special_scarf', 'chicken', 'Gà đào hồng', 980, 5),
  ('chicken_special_strawhat', 'chicken', 'Gà lam ngọc', 1280, 5),
  ('chicken_special_amber', 'chicken', 'Gà Mơ Lửa', 1680, 5),
  ('pig_pink', 'pig', 'Heo hồng', 400, 10),
  ('pig_cream', 'pig', 'Heo sữa', 620, 10),
  ('pig_spotted', 'pig', 'Heo đốm', 880, 10),
  ('pig_special_flower', 'pig', 'Heo mật ong', 1450, 10),
  ('pig_special_sprout', 'pig', 'Heo tím khoai', 1850, 10),
  ('cow_dairy', 'cow', 'Bò sữa', 700, 15),
  ('cow_brown', 'cow', 'Bò nâu', 1080, 15),
  ('cow_golden', 'cow', 'Bò vàng', 1560, 15),
  ('cow_special_bell', 'cow', 'Bò nâu đỏ', 2200, 15),
  ('cow_special_rosette', 'cow', 'Bò hồng sữa', 2800, 15),
  ('cow_special_bellcloud', 'cow', 'Bò mây', 3200, 15),
  ('fish_pond', 'fish', 'Cá vàng', 500, 20),
  ('fish_blue', 'fish', 'Cá xanh ngọc', 780, 20),
  ('fish_koi', 'fish', 'Cá koi', 1160, 20),
  ('fish_special_crown', 'fish', 'Cá vương miện', 1780, 20),
  ('fish_special_pearl', 'fish', 'Cá ngọc trai', 2300, 20);

alter table public.animal_variant_catalog_v2 enable row level security;
revoke all on table public.animal_variant_catalog_v2 from public, anon, authenticated;

create function public.buy_animal_v2(p_request_id uuid, p_variant_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_variant public.animal_variant_catalog_v2%rowtype;
  v_wallet public.player_wallets%rowtype;
  v_farm public.player_farm_state%rowtype;
  v_request public.economy_requests%rowtype;
  v_animals jsonb;
  v_animal jsonb;
  v_variants jsonb;
  v_count integer;
  v_level integer := 1;
  v_payload_hash text;
  v_response jsonb;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_variant_id is null then
    raise exception using errcode = '22023', message = 'Invalid animal purchase request';
  end if;
  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'buy_animal_v2', 'variant_id', p_variant_id
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'buy_animal_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then raise exception using errcode = '55000', message = 'Could not establish idempotency record'; end if;
  if v_request.operation_type <> 'buy_animal_v2' or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select * into v_variant from public.animal_variant_catalog_v2
  where variant_id = p_variant_id and enabled;
  if not found then raise exception using errcode = '22023', message = 'Unknown or disabled animal'; end if;
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then raise exception using errcode = '55000', message = 'Canonical wallet is not initialized'; end if;
  select * into v_farm from public.player_farm_state where user_id = v_uid for update;
  if not found then raise exception using errcode = '55000', message = 'Canonical farm is not initialized'; end if;

  while v_level < 60 and v_wallet.xp >= (80 * v_level + 10 * v_level * (v_level - 1)) loop
    v_level := v_level + 1;
  end loop;
  if v_level < v_variant.unlock_level then
    raise exception using errcode = '55000', message = 'Animal is still locked';
  end if;

  v_animals := v_farm.farm_state->'animals';
  if jsonb_typeof(v_animals) is distinct from 'object' then
    raise exception using errcode = '55000', message = 'Canonical animal data is invalid';
  end if;
  v_animal := coalesce(v_animals->v_variant.animal_key, '{}'::jsonb);
  if jsonb_typeof(v_animal) is distinct from 'object' then
    raise exception using errcode = '55000', message = 'Canonical animal data is invalid';
  end if;
  begin
    v_count := coalesce((v_animal->>'count')::integer, 0);
    v_variants := coalesce(v_animal->'variants', '{}'::jsonb);
  exception when others then
    raise exception using errcode = '55000', message = 'Canonical animal count is invalid';
  end;
  if v_count < 0 or v_count >= 8 or jsonb_typeof(v_variants) is distinct from 'object' then
    raise exception using errcode = '55000', message = 'Animal capacity reached or variant data is invalid';
  end if;
  if v_wallet.coins < v_variant.price then
    raise exception using errcode = '55000', message = 'Insufficient coins';
  end if;

  v_count := v_count + 1;
  v_variants := jsonb_set(v_variants, array[v_variant.variant_id],
    to_jsonb(coalesce((v_variants->>v_variant.variant_id)::integer, 0) + 1), true);
  v_animal := jsonb_set(v_animal, '{count}', to_jsonb(v_count), true);
  v_animal := jsonb_set(v_animal, '{variants}', v_variants, true);
  -- Fill defaults without resetting an active production batch when buying more animals.
  v_animal := jsonb_build_object('fed_at', null, 'ready_at', null, 'batch_count', 0) || v_animal;
  v_animals := jsonb_set(v_animals, array[v_variant.animal_key], v_animal, true);

  update public.player_wallets set coins = coins - v_variant.price, updated_at = v_now
  where user_id = v_uid;
  update public.player_farm_state
  set farm_state = jsonb_set(farm_state, '{animals}', v_animals, false),
      revision = revision + 1, updated_at = v_now
  where user_id = v_uid;

  v_response := jsonb_build_object('ok', true, 'animal_key', v_variant.animal_key,
    'variant_id', v_variant.variant_id, 'count', v_count, 'unit_price', v_variant.price,
    'coins_remaining', v_wallet.coins - v_variant.price,
    'farm_revision', v_farm.revision + 1);
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;

create function public.apply_animal_action_v2(
  p_request_id uuid,
  p_animal_key text,
  p_action text
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
  v_period_date date := timezone('Asia/Ho_Chi_Minh', v_now)::date;
  v_wallet public.player_wallets%rowtype;
  v_farm public.player_farm_state%rowtype;
  v_request public.economy_requests%rowtype;
  v_config jsonb;
  v_animals jsonb;
  v_animal jsonb;
  v_species text;
  v_feed_key text;
  v_product_key text;
  v_count integer;
  v_batch integer;
  v_feed_quantity bigint;
  v_ready_at timestamptz;
  v_fed_at timestamptz;
  v_duration integer;
  v_xp bigint;
  v_level_before integer := 1;
  v_level_after integer := 1;
  v_level_coins bigint := 0;
  v_payload_hash text;
  v_operation text;
  v_response jsonb;
begin
  if v_uid is null then raise exception using errcode = '28000', message = 'Authentication required'; end if;
  if p_request_id is null or p_animal_key is null
     or p_animal_key not in ('chicken','pig','cow','fish')
     or p_action is null or p_action not in ('feed','collect') then
    raise exception using errcode = '22023', message = 'Invalid animal action request';
  end if;
  v_operation := case p_action when 'feed' then 'feed_animal_v2' else 'collect_animal_v2' end;
  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', v_operation, 'animal_key', p_animal_key
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, v_operation, v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then raise exception using errcode = '55000', message = 'Could not establish idempotency record'; end if;
  if v_request.operation_type <> v_operation or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then raise exception using errcode = '55000', message = 'Canonical wallet is not initialized'; end if;
  select * into v_farm from public.player_farm_state where user_id = v_uid for update;
  if not found then raise exception using errcode = '55000', message = 'Canonical farm is not initialized'; end if;
  select config into v_config from public.game_global_config where id = 1;
  if v_config is null then raise exception using errcode = '55000', message = 'Server game configuration is unavailable'; end if;

  v_animals := v_farm.farm_state->'animals';
  if jsonb_typeof(v_animals) is distinct from 'object' then
    raise exception using errcode = '55000', message = 'Canonical animal data is invalid';
  end if;
  v_animal := v_animals->p_animal_key;
  if jsonb_typeof(v_animal) is distinct from 'object' then
    raise exception using errcode = '55000', message = 'No animals of this type';
  end if;
  begin
    v_count := (v_animal->>'count')::integer;
    v_batch := coalesce((v_animal->>'batch_count')::integer, 0);
    v_fed_at := nullif(v_animal->>'fed_at', '')::timestamptz;
    v_ready_at := nullif(v_animal->>'ready_at', '')::timestamptz;
  exception when others then
    raise exception using errcode = '55000', message = 'Canonical animal state is invalid';
  end;
  if v_count is null or v_count < 1 or v_count > 8 then
    raise exception using errcode = '55000', message = 'Animal count is invalid';
  end if;
  v_feed_key := 'feed_' || p_animal_key;
  v_product_key := case p_animal_key when 'chicken' then 'eggs' when 'pig' then 'pork'
    when 'cow' then 'milk' else 'fish' end;

  if p_action = 'feed' then
    if v_ready_at is not null or v_fed_at is not null or v_batch <> 0 then
      raise exception using errcode = '55000', message = 'Animal is already producing';
    end if;
    select quantity into v_feed_quantity from public.player_inventory
    where user_id = v_uid and item_key = v_feed_key for update;
    if not found or v_feed_quantity < v_count then
      raise exception using errcode = '55000', message = 'Insufficient animal feed';
    end if;
    v_duration := greatest(1, round(
      coalesce((v_config->'animalHarvestSeconds'->>p_animal_key)::numeric,
        case p_animal_key when 'chicken' then 300 when 'pig' then 420 else 360 end)
      * coalesce((v_config->>'animalTimeMultiplier')::numeric, 1)
    ))::integer;
    update public.player_inventory set quantity = quantity - v_count, updated_at = v_now
    where user_id = v_uid and item_key = v_feed_key;
    v_animal := jsonb_set(v_animal, '{fed_at}', to_jsonb(v_now), true);
    v_animal := jsonb_set(v_animal, '{ready_at}', to_jsonb(v_now + make_interval(secs => v_duration)), true);
    v_animal := jsonb_set(v_animal, '{batch_count}', to_jsonb(v_count), true);
    v_xp := 2;
  else
    if v_ready_at is null or v_batch < 1 or v_batch > v_count or v_ready_at > v_now then
      raise exception using errcode = '55000', message = 'Animal products are not ready';
    end if;
    insert into public.player_inventory (user_id, item_key, quantity, updated_at)
    values (v_uid, v_product_key, v_batch, v_now)
    on conflict (user_id, item_key) do update
      set quantity = public.player_inventory.quantity + excluded.quantity,
          updated_at = excluded.updated_at;
    v_animal := jsonb_set(v_animal, '{fed_at}', 'null'::jsonb, true);
    v_animal := jsonb_set(v_animal, '{ready_at}', 'null'::jsonb, true);
    v_animal := jsonb_set(v_animal, '{batch_count}', '0'::jsonb, true);
    v_xp := 8;
  end if;

  while v_level_before < 60 and v_wallet.xp >= (80 * v_level_before + 10 * v_level_before * (v_level_before - 1)) loop
    v_level_before := v_level_before + 1;
  end loop;
  while v_level_after < 60 and v_wallet.xp + v_xp >= (80 * v_level_after + 10 * v_level_after * (v_level_after - 1)) loop
    v_level_after := v_level_after + 1;
  end loop;
  v_level_coins := greatest(0, v_level_after - v_level_before) * 30;
  update public.player_wallets set xp = xp + v_xp, coins = coins + v_level_coins, updated_at = v_now
  where user_id = v_uid;

  if p_action = 'feed' then
    insert into public.player_daily_quests
      (user_id, period_date, quest_id, progress, target, reward_coins, reward_xp)
    select v_uid, v_period_date, c.quest_id, 0, c.target, c.reward_coins, c.reward_xp
    from public.daily_quest_catalog c where c.enabled
    on conflict (user_id, period_date, quest_id) do nothing;
    update public.player_daily_quests set progress = least(target, progress + 1), updated_at = v_now
    where user_id = v_uid and period_date = v_period_date and quest_id = 'feed';
  end if;

  v_animals := jsonb_set(v_animals, array[p_animal_key], v_animal, false);
  update public.player_farm_state
  set farm_state = jsonb_set(farm_state, '{animals}', v_animals, false),
      revision = revision + 1, updated_at = v_now
  where user_id = v_uid;
  if p_action = 'feed' then
    v_response := jsonb_build_object('ok', true, 'action', 'feed', 'animal_key', p_animal_key,
      'animals_fed', v_count, 'fed_at', v_now, 'ready_at', v_now + make_interval(secs => v_duration),
      'duration_seconds', v_duration, 'xp_awarded', v_xp, 'level_up_coins', v_level_coins,
      'farm_revision', v_farm.revision + 1);
  else
    v_response := jsonb_build_object('ok', true, 'action', 'collect', 'animal_key', p_animal_key,
      'product_key', v_product_key, 'quantity_added', v_batch, 'xp_awarded', v_xp,
      'level_up_coins', v_level_coins, 'farm_revision', v_farm.revision + 1);
  end if;
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;

create function public.feed_animal_v2(p_request_id uuid, p_animal_key text)
returns jsonb language sql volatile security definer
set search_path = pg_catalog, public, auth
as $$ select public.apply_animal_action_v2(p_request_id, p_animal_key, 'feed'); $$;

create function public.collect_animal_v2(p_request_id uuid, p_animal_key text)
returns jsonb language sql volatile security definer
set search_path = pg_catalog, public, auth
as $$ select public.apply_animal_action_v2(p_request_id, p_animal_key, 'collect'); $$;

revoke all on function public.buy_animal_v2(uuid, text) from public, anon, authenticated;
revoke all on function public.apply_animal_action_v2(uuid, text, text) from public, anon, authenticated;
revoke all on function public.feed_animal_v2(uuid, text) from public, anon, authenticated;
revoke all on function public.collect_animal_v2(uuid, text) from public, anon, authenticated;
grant execute on function public.buy_animal_v2(uuid, text) to authenticated;
grant execute on function public.feed_animal_v2(uuid, text) to authenticated;
grant execute on function public.collect_animal_v2(uuid, text) to authenticated;

comment on function public.buy_animal_v2(uuid, text) is
  'Purchases one server-priced individual animal variant, enforcing species capacity and unlock level atomically.';
comment on function public.feed_animal_v2(uuid, text) is
  'Consumes feed equal to the current herd size, records server-time production completion, awards XP, and advances one daily feed quest.';
comment on function public.collect_animal_v2(uuid, text) is
  'Collects the snapshotted product batch after DB ready_at, adds canonical inventory and XP atomically, and clears the production cycle.';

commit;
