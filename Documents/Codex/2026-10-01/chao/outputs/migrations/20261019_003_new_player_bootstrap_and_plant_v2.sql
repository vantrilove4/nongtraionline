-- Phase 2, first trusted gameplay slice (dark launch).
-- Apply only after review on staging. This file has NOT been executed.
-- Existing game_saves are never imported, edited, or deleted.

begin;

create table public.crop_action_catalog_v2 (
  crop_key text primary key check (crop_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  seed_item_key text not null unique check (seed_item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  unlock_level integer not null check (unlock_level > 0),
  harvest_xp bigint not null check (harvest_xp >= 0),
  enabled boolean not null default true
);

insert into public.crop_action_catalog_v2
  (crop_key, seed_item_key, unlock_level, harvest_xp)
values
  ('carrot', 'seed_carrot', 1, 6),
  ('tomato', 'seed_tomato', 1, 10),
  ('potato', 'seed_potato', 3, 11),
  ('corn', 'seed_corn', 5, 15),
  ('pumpkin', 'seed_pumpkin', 7, 19),
  ('berry', 'seed_berry', 8, 21),
  ('sunflower', 'seed_sunflower', 10, 24),
  ('watermelon', 'seed_watermelon', 12, 27),
  ('eggplant', 'seed_eggplant', 15, 30),
  ('pineapple', 'seed_pineapple', 18, 34),
  ('grape', 'seed_grape', 22, 38);

alter table public.crop_action_catalog_v2 enable row level security;
revoke all on table public.crop_action_catalog_v2 from public, anon, authenticated;

create function public.bootstrap_new_player_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_coins bigint;
  v_seed_quantity bigint;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;

  -- Serialize bootstrap for this account. Existing legacy saves are left alone;
  -- their reconciliation policy has not been approved.
  perform 1 from auth.users where id = v_uid for update;
  if exists (select 1 from public.game_saves where user_id = v_uid) then
    raise exception using errcode = '55000',
      message = 'Legacy farm detected; automatic migration is disabled';
  end if;

  v_state := jsonb_build_object(
    'plots', (
      select jsonb_agg(jsonb_build_object(
        'state', 'grass', 'crop_key', null, 'planted_at', null,
        'ready_at', null, 'watered', false
      ) order by n)
      from generate_series(0, 17) as gs(n)
    ),
    'animals', jsonb_build_object(),
    'schema_version', 1
  );

  insert into public.player_wallets (user_id, coins, xp)
  values (v_uid, 80, 0)
  on conflict (user_id) do nothing;

  insert into public.player_inventory (user_id, item_key, quantity)
  values (v_uid, 'seed_carrot', 3)
  on conflict (user_id, item_key) do nothing;

  insert into public.player_farm_state (user_id, farm_state, schema_version, revision)
  values (v_uid, v_state, 1, 1)
  on conflict (user_id) do nothing;

  if not exists (select 1 from public.player_farm_state where user_id = v_uid)
     or not exists (select 1 from public.player_wallets where user_id = v_uid) then
    raise exception using errcode = '55000', message = 'Canonical farm bootstrap did not complete';
  end if;

  select coins into v_coins from public.player_wallets where user_id = v_uid;
  select quantity into v_seed_quantity from public.player_inventory
  where user_id = v_uid and item_key = 'seed_carrot';
  return jsonb_build_object('ok', true, 'coins', v_coins,
                            'carrot_seeds', coalesce(v_seed_quantity, 0),
                            'farm_schema_version', 1);
end;
$$;

create function public.till_plot_v2(p_request_id uuid, p_plot_index integer)
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
  v_farm public.player_farm_state%rowtype;
  v_request public.economy_requests%rowtype;
  v_plots jsonb;
  v_plot jsonb;
  v_level integer := 1;
  v_unlocked_plots integer;
  v_payload_hash text;
  v_response jsonb;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_plot_index is null or p_plot_index < 0 or p_plot_index > 17 then
    raise exception using errcode = '22023', message = 'Invalid request or plot index';
  end if;

  v_payload_hash := encode(sha256(convert_to(jsonb_build_object(
    'operation', 'till_plot_v2', 'plot_index', p_plot_index
  )::text, 'UTF8')), 'hex');
  insert into public.economy_requests (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'till_plot_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'till_plot_v2' or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different action';
  end if;
  if v_request.response is not null then return v_request.response; end if;

  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then raise exception using errcode = '55000', message = 'Canonical wallet is not initialized'; end if;
  select * into v_farm from public.player_farm_state where user_id = v_uid for update;
  if not found then raise exception using errcode = '55000', message = 'Canonical farm is not initialized'; end if;

  while v_level < 60 and v_wallet.xp >= (80 * v_level + 10 * v_level * (v_level - 1)) loop
    v_level := v_level + 1;
  end loop;
  v_unlocked_plots := least(18, 4 + floor(v_level / 5.0)::integer * 2);
  if p_plot_index >= v_unlocked_plots then
    raise exception using errcode = '55000', message = 'Plot is still locked';
  end if;

  v_plots := v_farm.farm_state->'plots';
  if jsonb_typeof(v_plots) <> 'array' or jsonb_array_length(v_plots) <> 18 then
    raise exception using errcode = '55000', message = 'Canonical plot data is invalid';
  end if;
  v_plot := v_plots->p_plot_index;
  if v_plot->>'state' <> 'grass' or nullif(v_plot->>'crop_key', '') is not null then
    raise exception using errcode = '55000', message = 'Plot cannot be tilled in its current state';
  end if;
  v_plot := jsonb_build_object('state', 'tilled', 'crop_key', null,
                               'planted_at', null, 'ready_at', null, 'watered', false);
  v_plots := jsonb_set(v_plots, array[p_plot_index::text], v_plot, false);
  update public.player_farm_state
  set farm_state = jsonb_set(farm_state, '{plots}', v_plots, false),
      revision = revision + 1, updated_at = v_now
  where user_id = v_uid;

  v_response := jsonb_build_object('ok', true, 'action', 'till',
    'plot_index', p_plot_index, 'farm_revision', v_farm.revision + 1);
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;

create function public.plant_crop_v2(
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
  if v_plot->>'state' <> 'tilled' or nullif(v_plot->>'crop_key', '') is not null then
    raise exception using errcode = '55000', message = 'Plot must be empty and tilled';
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

revoke all on function public.bootstrap_new_player_v2() from public, anon, authenticated;
grant execute on function public.bootstrap_new_player_v2() to authenticated;
revoke all on function public.plant_crop_v2(uuid, integer, text) from public, anon, authenticated;
grant execute on function public.plant_crop_v2(uuid, integer, text) to authenticated;
revoke all on function public.till_plot_v2(uuid, integer) from public, anon, authenticated;
grant execute on function public.till_plot_v2(uuid, integer) to authenticated;

comment on function public.bootstrap_new_player_v2() is
  'Creates a starter canonical farm only when the authenticated user has no legacy game_saves row. Never imports or overwrites a save.';
comment on function public.plant_crop_v2(uuid, integer, text) is
  'Atomically consumes one server catalog seed, plants one unlocked empty plot using DB time/config, awards XP, advances daily plant quest, and stores idempotent response.';
comment on function public.till_plot_v2(uuid, integer) is
  'Atomically changes one unlocked grass plot to tilled soil with request idempotency. It does not award currency or XP.';

commit;
