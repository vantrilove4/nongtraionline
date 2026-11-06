-- Vườn Nhỏ: plant directly into an empty plot; no separate till operation.
-- Additive replacement of plant_crop_v2. All checks, seed use, timing, XP,
-- quest progress, and idempotency remain server-authoritative and transactional.
-- This does not modify existing planted crops or any player save.
begin;
create or replace function public.plant_crop_v2(
  p_request_id uuid,
  p_plot_index integer,
  p_crop_key text
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
  v_crop public.crop_action_catalog_v2%rowtype;
  v_wallet public.player_wallets%rowtype;
  v_farm public.player_farm_state%rowtype;
  v_request public.economy_requests%rowtype;
  v_item_quantity bigint;
  v_level integer := 1;
  v_unlocked_plots integer;
  v_grow_seconds integer;
  v_plot jsonb;
  v_plots jsonb;
  v_payload_hash text;
  v_response jsonb;
  v_xp_before bigint;
  v_xp_after bigint;
  v_level_before integer;
  v_level_reward bigint := 0;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_plot_index is null or p_crop_key is null
     or p_plot_index < 0 or p_plot_index > 17 then
    raise exception using errcode = '22023', message = 'Invalid request or plot index';
  end if;

  select * into v_crop from public.crop_action_catalog_v2
  where crop_key = p_crop_key and enabled;
  if not found then
    raise exception using errcode = '22023', message = 'Unknown or disabled crop';
  end if;

  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'plant_crop_v2', 'plot_index', p_plot_index, 'crop_key', p_crop_key
  )::text, 'UTF8')), 'hex');

  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'plant_crop_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;

  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'plant_crop_v2' or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then
    return v_request.response;
  end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  select * into v_farm from public.player_farm_state where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical farm is not initialized';
  end if;

  v_xp_before := v_wallet.xp;
  while v_level < 60 and v_wallet.xp >=
    (80 * v_level + 10 * v_level * (v_level - 1)) loop
    v_level := v_level + 1;
  end loop;
  v_level_before := v_level;
  if v_level < v_crop.unlock_level then
    raise exception using errcode = '55000', message = 'Crop is still locked';
  end if;
  v_unlocked_plots := least(18, 4 + floor(v_level / 5.0)::integer * 2);
  if p_plot_index >= v_unlocked_plots then
    raise exception using errcode = '55000', message = 'Plot is still locked';
  end if;

  v_plots := v_farm.farm_state->'plots';
  if jsonb_typeof(v_plots) <> 'array' or jsonb_array_length(v_plots) <> 18 then
    raise exception using errcode = '55000', message = 'Canonical plot data is invalid';
  end if;
  v_plot := v_plots->p_plot_index;
  if coalesce(v_plot->>'state', '') not in ('grass', 'tilled')
     or nullif(v_plot->>'crop_key', '') is not null then
    raise exception using errcode = '55000', message = 'Plot must be empty before planting';
  end if;

  select quantity into v_item_quantity from public.player_inventory
  where user_id = v_uid and item_key = v_crop.seed_item_key for update;
  if not found or v_item_quantity < 1 then
    raise exception using errcode = '55000', message = 'Insufficient seed inventory';
  end if;

  select greatest(1, round(
    coalesce((config->'cropHarvestSeconds'->>p_crop_key)::numeric, 300)
    * coalesce((config->>'cropTimeMultiplier')::numeric, 1)
  ))::integer into v_grow_seconds
  from public.game_global_config where id = 1;
  if v_grow_seconds is null then
    raise exception using errcode = '55000', message = 'Server crop configuration is unavailable';
  end if;

  update public.player_inventory set quantity = quantity - 1, updated_at = v_now
  where user_id = v_uid and item_key = v_crop.seed_item_key;

  v_plot := jsonb_build_object(
    'state', 'planted', 'crop_key', p_crop_key, 'planted_at', v_now,
    'ready_at', v_now + make_interval(secs => v_grow_seconds), 'watered', false
  );
  v_plots := jsonb_set(v_plots, array[p_plot_index::text], v_plot, false);
  update public.player_farm_state
  set farm_state = jsonb_set(farm_state, '{plots}', v_plots, false),
      revision = revision + 1, updated_at = v_now
  where user_id = v_uid;

  v_xp_after := v_wallet.xp + 2;
  v_level := 1;
  while v_level < 60 and v_xp_after >=
    (80 * v_level + 10 * v_level * (v_level - 1)) loop
    v_level := v_level + 1;
  end loop;
  v_level_reward := greatest(0, v_level - v_level_before) * 30;
  update public.player_wallets
  set xp = v_xp_after, coins = coins + v_level_reward, updated_at = v_now
  where user_id = v_uid;

  insert into public.player_daily_quests
    (user_id, period_date, quest_id, progress, target, reward_coins, reward_xp)
  select v_uid, v_period_date, c.quest_id, 0, c.target, c.reward_coins, c.reward_xp
  from public.daily_quest_catalog c where c.enabled
  on conflict (user_id, period_date, quest_id) do nothing;
  update public.player_daily_quests
  set progress = least(target, progress + 1), updated_at = v_now
  where user_id = v_uid and period_date = v_period_date and quest_id = 'plant';

  v_response := jsonb_build_object(
    'ok', true, 'action', 'plant', 'plot_index', p_plot_index, 'crop_key', p_crop_key,
    'planted_at', v_now, 'ready_at', v_now + make_interval(secs => v_grow_seconds),
    'grow_seconds', v_grow_seconds, 'xp_awarded', 2, 'level_up_coins', v_level_reward,
    'farm_revision', v_farm.revision + 1
  );
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;
revoke all on function public.plant_crop_v2(uuid, integer, text) from public, anon, authenticated;
grant execute on function public.plant_crop_v2(uuid, integer, text) to authenticated;
comment on function public.plant_crop_v2(uuid, integer, text) is
  'Plants one crop directly into an empty grass or tilled plot; seed consumption, timing, XP, quest progress, and idempotency are server-authoritative.';
notify pgrst, 'reload schema';
commit;