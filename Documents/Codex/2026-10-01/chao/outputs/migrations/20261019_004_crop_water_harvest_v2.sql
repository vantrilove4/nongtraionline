-- Phase 2, second trusted gameplay slice (dark launch).
-- Depends on migrations 001-003. This file has NOT been executed.
-- It does not modify game_saves or connect either game client.

begin;

create function public.apply_crop_plot_action_v2(
  p_request_id uuid,
  p_plot_index integer,
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
  v_crop public.crop_action_catalog_v2%rowtype;
  v_config jsonb;
  v_plots jsonb;
  v_plot jsonb;
  v_crop_key text;
  v_operation text;
  v_payload_hash text;
  v_response jsonb;
  v_ready_at timestamptz;
  v_planted_at timestamptz;
  v_total_seconds integer;
  v_watered boolean;
  v_xp_award bigint := 0;
  v_xp_after bigint;
  v_level_before integer := 1;
  v_level_after integer := 1;
  v_level_coins bigint := 0;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_plot_index is null or p_plot_index < 0 or p_plot_index > 17
     or p_action is null or p_action not in ('water', 'harvest') then
    raise exception using errcode = '22023', message = 'Invalid crop action request';
  end if;
  v_operation := case p_action when 'water' then 'water_crop_v2' else 'harvest_crop_v2' end;

  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', v_operation,
    'plot_index', p_plot_index
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (
    v_uid, p_request_id,
    v_operation,
    v_payload_hash
  )
  on conflict (user_id, request_id) do nothing;

  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> v_operation or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  select * into v_farm from public.player_farm_state where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical farm is not initialized';
  end if;
  select config into v_config from public.game_global_config where id = 1;
  if v_config is null then
    raise exception using errcode = '55000', message = 'Server game configuration is unavailable';
  end if;

  v_plots := v_farm.farm_state->'plots';
  if jsonb_typeof(v_plots) is distinct from 'array' then
    raise exception using errcode = '55000', message = 'Canonical plot data is invalid';
  end if;
  if jsonb_array_length(v_plots) <> 18 then
    raise exception using errcode = '55000', message = 'Canonical plot data is invalid';
  end if;
  v_plot := v_plots->p_plot_index;
  if v_plot->>'state' <> 'planted' then
    raise exception using errcode = '55000', message = 'Plot has no growing crop';
  end if;

  v_crop_key := v_plot->>'crop_key';
  select * into v_crop from public.crop_action_catalog_v2
  where crop_key = v_crop_key and enabled;
  if not found then
    raise exception using errcode = '55000', message = 'Crop state is invalid or disabled';
  end if;
  begin
    v_planted_at := (v_plot->>'planted_at')::timestamptz;
    v_ready_at := (v_plot->>'ready_at')::timestamptz;
    v_watered := coalesce((v_plot->>'watered')::boolean, false);
  exception when others then
    raise exception using errcode = '55000', message = 'Crop timestamps or water state are invalid';
  end;
  if v_planted_at is null or v_ready_at is null or v_ready_at < v_planted_at then
    raise exception using errcode = '55000', message = 'Crop timestamps are invalid';
  end if;

  if p_action = 'water' then
    if v_now >= v_ready_at then
      raise exception using errcode = '55000', message = 'Crop is already ready to harvest';
    end if;
    if v_watered then
      raise exception using errcode = '55000', message = 'Crop was already watered';
    end if;
    v_total_seconds := greatest(0, extract(epoch from (v_ready_at - v_planted_at))::integer);
    v_ready_at := v_ready_at - make_interval(secs => floor(v_total_seconds * 0.25)::integer);
    v_plot := jsonb_set(v_plot, '{ready_at}', to_jsonb(v_ready_at), false);
    v_plot := jsonb_set(v_plot, '{watered}', 'true'::jsonb, false);
  else
    if v_now < v_ready_at then
      raise exception using errcode = '55000', message = 'Crop is not ready to harvest';
    end if;

    v_xp_award := greatest(0, round(
      v_crop.harvest_xp * coalesce((v_config->>'xpMultiplier')::numeric, 1)
    ))::bigint;
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

    insert into public.player_inventory (user_id, item_key, quantity, updated_at)
    values (v_uid, v_crop_key, 1, v_now)
    on conflict (user_id, item_key) do update
      set quantity = public.player_inventory.quantity + 1,
          updated_at = excluded.updated_at;

    update public.player_wallets
    set xp = v_xp_after, coins = coins + v_level_coins, updated_at = v_now
    where user_id = v_uid;

    insert into public.player_daily_quests
      (user_id, period_date, quest_id, progress, target, reward_coins, reward_xp)
    select v_uid, v_period_date, c.quest_id, 0, c.target, c.reward_coins, c.reward_xp
    from public.daily_quest_catalog c where c.enabled
    on conflict (user_id, period_date, quest_id) do nothing;
    update public.player_daily_quests
    set progress = least(target, progress + 1), updated_at = v_now
    where user_id = v_uid and period_date = v_period_date and quest_id = 'harvest';

    v_plot := jsonb_build_object('state', 'tilled', 'crop_key', null,
                                 'planted_at', null, 'ready_at', null, 'watered', false);
  end if;

  v_plots := jsonb_set(v_plots, array[p_plot_index::text], v_plot, false);
  update public.player_farm_state
  set farm_state = jsonb_set(farm_state, '{plots}', v_plots, false),
      revision = revision + 1, updated_at = v_now
  where user_id = v_uid;

  if p_action = 'water' then
    v_response := jsonb_build_object(
      'ok', true, 'action', 'water', 'plot_index', p_plot_index,
      'ready_at', v_ready_at, 'farm_revision', v_farm.revision + 1
    );
  else
    v_response := jsonb_build_object(
      'ok', true, 'action', 'harvest', 'plot_index', p_plot_index,
      'crop_key', v_crop_key, 'quantity_added', 1,
      'xp_awarded', v_xp_award, 'level_up_coins', v_level_coins,
      'farm_revision', v_farm.revision + 1
    );
  end if;

  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;

create function public.water_crop_v2(p_request_id uuid, p_plot_index integer)
returns jsonb
language sql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
  select public.apply_crop_plot_action_v2(p_request_id, p_plot_index, 'water');
$$;

create function public.harvest_crop_v2(p_request_id uuid, p_plot_index integer)
returns jsonb
language sql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
  select public.apply_crop_plot_action_v2(p_request_id, p_plot_index, 'harvest');
$$;

revoke all on function public.apply_crop_plot_action_v2(uuid, integer, text)
  from public, anon, authenticated;
revoke all on function public.water_crop_v2(uuid, integer) from public, anon, authenticated;
revoke all on function public.harvest_crop_v2(uuid, integer) from public, anon, authenticated;
grant execute on function public.water_crop_v2(uuid, integer) to authenticated;
grant execute on function public.harvest_crop_v2(uuid, integer) to authenticated;

comment on function public.water_crop_v2(uuid, integer) is
  'Applies one 25-percent grow-time reduction to a planted crop using server timestamps; request is idempotent.';
comment on function public.harvest_crop_v2(uuid, integer) is
  'Harvests only after DB ready_at, atomically adds one crop, server XP, level-up coins, daily quest progress, and idempotency response.';

commit;
