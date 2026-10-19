-- One-time, authenticated import of the current server-stored legacy save.
-- This migration does not alter or delete game_saves. The RPC accepts no save
-- payload: it locks and reads the caller's existing row inside one transaction.
-- Legacy economy values remain grandfathered from a historically client-writable
-- save; this does not make their history independently verifiable.

begin;

create table public.legacy_save_imports_v2 (
  user_id uuid primary key references auth.users(id) on delete restrict,
  source_updated_at timestamptz not null,
  imported_at timestamptz not null default transaction_timestamp(),
  import_summary jsonb not null check (jsonb_typeof(import_summary) = 'object')
);

alter table public.legacy_save_imports_v2 enable row level security;
revoke all on table public.legacy_save_imports_v2 from public, anon, authenticated;

create function public.migrate_legacy_save_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_save jsonb;
  v_source_updated_at timestamptz;
  v_existing public.legacy_save_imports_v2%rowtype;
  v_coins bigint;
  v_xp bigint;
  v_item record;
  v_qty bigint;
  v_key text;
  v_seeds jsonb;
  v_feeds jsonb;
  v_plots jsonb := '[]'::jsonb;
  v_plot jsonb;
  v_crop text;
  v_plot_state text;
  v_duration integer;
  v_base_seconds integer;
  v_animals jsonb := '{}'::jsonb;
  v_animal_key text;
  v_count integer;
  v_animal jsonb;
  v_variants jsonb;
  v_variant record;
  v_variant_qty integer;
  v_variant_left integer;
  v_active boolean;
  v_animal_seconds integer;
  v_config jsonb := '{}'::jsonb;
  v_summary jsonb;
  v_plot_count integer := 0;
  v_inventory_count integer := 0;
  v_animal_count integer := 0;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;

  -- Serialize concurrent attempts from this account before checking either source
  -- or destination. A retry returns the original successful summary.
  perform 1 from auth.users where id = v_uid for update;
  select * into v_existing from public.legacy_save_imports_v2
  where user_id = v_uid for update;
  if found then
    return v_existing.import_summary || jsonb_build_object(
      'ok', true, 'already_imported', true, 'imported_at', v_existing.imported_at);
  end if;

  select gs.save_data, gs.updated_at into v_save, v_source_updated_at
  from public.game_saves as gs where gs.user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'No legacy save exists for this account';
  end if;
  if jsonb_typeof(v_save) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Legacy save is not a JSON object';
  end if;

  -- Never merge a legacy snapshot over canonical state. An initialized account
  -- without an import ledger needs manual reconciliation rather than overwrite.
  if exists (select 1 from public.player_wallets where user_id = v_uid)
     or exists (select 1 from public.player_farm_state where user_id = v_uid)
     or exists (select 1 from public.player_inventory where user_id = v_uid) then
    raise exception using errcode = '55000', message = 'Canonical state already exists; legacy save was not changed';
  end if;

  begin
    v_coins := greatest(0, floor(coalesce((v_save->>'coins')::numeric, 0)))::bigint;
    v_xp := greatest(0, floor(coalesce((v_save->>'xp')::numeric, 0)))::bigint;
  exception when others then
    raise exception using errcode = '22023', message = 'Legacy wallet values are invalid';
  end;
  if v_coins > 9000000000000000 or v_xp > 9000000000000000 then
    raise exception using errcode = '22023', message = 'Legacy wallet values exceed the supported range';
  end if;

  -- Transfer all syntactically valid inventory keys. Unknown or malformed source
  -- fields are still preserved byte-for-byte in farm_state.legacy_save.
  if jsonb_typeof(v_save->'inv') = 'object' then
    for v_item in select key, value from jsonb_each(v_save->'inv') loop
      v_key := case v_item.key
        when 'berryYogurt' then 'berry_yogurt'
        when 'pumpkinPie' then 'pumpkin_pie'
        when 'fishStew' then 'fish_stew'
        when 'cornSausage' then 'corn_sausage'
        else v_item.key end;
      if v_key ~ '^[a-z][a-z0-9_]{0,63}$' and jsonb_typeof(v_item.value) = 'number' then
        begin
          v_qty := floor((v_item.value #>> '{}')::numeric)::bigint;
        exception when others then v_qty := 0;
        end;
        if v_qty > 0 and v_qty <= 9000000000000000 then
          insert into public.player_inventory(user_id, item_key, quantity, updated_at)
          values (v_uid, v_key, v_qty, v_now)
          on conflict (user_id,item_key) do update set quantity = public.player_inventory.quantity + excluded.quantity,
            updated_at = excluded.updated_at;
          v_inventory_count := v_inventory_count + 1;
        end if;
      end if;
    end loop;
  end if;

  -- Legacy seed/feed maps are converted to canonical item keys.
  if jsonb_typeof(v_save->'seeds') = 'object' then
    for v_item in select key, value from jsonb_each(v_save->'seeds') loop
      v_key := case when left(v_item.key, 5) = 'seed_' then v_item.key else 'seed_' || v_item.key end;
      if v_key ~ '^seed_[a-z][a-z0-9_]{0,58}$'
         and exists (select 1 from public.crop_action_catalog_v2 where seed_item_key = v_key)
         and jsonb_typeof(v_item.value) = 'number' then
        begin v_qty := floor((v_item.value #>> '{}')::numeric)::bigint;
        exception when others then v_qty := 0; end;
        if v_qty > 0 and v_qty <= 9000000000000000 then
          insert into public.player_inventory(user_id,item_key,quantity,updated_at)
          values (v_uid,v_key,v_qty,v_now)
          on conflict (user_id,item_key) do update set quantity = public.player_inventory.quantity + excluded.quantity,
            updated_at = excluded.updated_at;
        end if;
      end if;
    end loop;
  end if;
  if jsonb_typeof(v_save->'feeds') = 'object' then
    for v_item in select key, value from jsonb_each(v_save->'feeds') loop
      if v_item.key in ('chicken','pig','cow','fish') and jsonb_typeof(v_item.value) = 'number' then
        begin v_qty := floor((v_item.value #>> '{}')::numeric)::bigint;
        exception when others then v_qty := 0; end;
        if v_qty > 0 and v_qty <= 9000000000000000 then
          insert into public.player_inventory(user_id,item_key,quantity,updated_at)
          values (v_uid,'feed_' || v_item.key,v_qty,v_now)
          on conflict (user_id,item_key) do update set quantity = public.player_inventory.quantity + excluded.quantity,
            updated_at = excluded.updated_at;
        end if;
      end if;
    end loop;
  elsif coalesce((v_save->>'feed')::numeric, 0) > 0 then
    -- The old shared feed counter belongs to the first species with animals;
    -- if none exist, retain it as chicken feed rather than discard it.
    v_animal_key := case
      when coalesce((v_save->'animalCounts'->>'chicken')::integer,0) > 0 then 'chicken'
      when coalesce((v_save->'animalCounts'->>'pig')::integer,0) > 0 then 'pig'
      when coalesce((v_save->'animalCounts'->>'cow')::integer,0) > 0 then 'cow'
      when coalesce((v_save->'animalCounts'->>'fish')::integer,0) > 0 then 'fish'
      else 'chicken' end;
    v_qty := greatest(0, floor((v_save->>'feed')::numeric))::bigint;
    if v_qty > 0 and v_qty <= 9000000000000000 then
      insert into public.player_inventory(user_id,item_key,quantity,updated_at)
      values (v_uid,'feed_' || v_animal_key,v_qty,v_now)
      on conflict (user_id,item_key) do update set quantity = public.player_inventory.quantity + excluded.quantity,
        updated_at = excluded.updated_at;
    end if;
  end if;

  -- Canonical plot slots are fixed at 18. Active crop growth restarts using
  -- server time and current server config; client-supplied timers are preserved
  -- only in the untouched legacy snapshot, never trusted for immediate harvest.
  select coalesce(config, '{}'::jsonb) into v_config from public.game_global_config where id = 1;
  if jsonb_typeof(v_save->'plots') = 'array' then
    for v_item in
      select value, ordinality from jsonb_array_elements(v_save->'plots') with ordinality
      where ordinality <= 18 order by ordinality
    loop
      v_plot := v_item.value;
      v_crop := null;
      v_plot_state := case when v_plot->>'state' = 'grass' then 'grass' else 'tilled' end;
      if coalesce(v_plot->>'crop','') <> ''
         and exists (select 1 from public.crop_action_catalog_v2 where crop_key = v_plot->>'crop' and enabled) then
        v_crop := v_plot->>'crop';
        v_plot_state := 'planted';
        v_base_seconds := case v_crop
          when 'carrot' then 300 when 'tomato' then 420 when 'potato' then 480
          when 'corn' then 540 when 'pumpkin' then 660 when 'berry' then 600
          when 'sunflower' then 720 when 'watermelon' then 780 when 'eggplant' then 840
          when 'pineapple' then 900 when 'grape' then 960 else 300 end;
        v_duration := greatest(1, round(v_base_seconds *
          coalesce((v_config->>'cropTimeMultiplier')::numeric,1)))::integer;
        v_plots := v_plots || jsonb_build_array(jsonb_build_object(
          'state','planted','crop_key',v_crop,'planted_at',v_now,
          'ready_at',v_now + make_interval(secs => v_duration),
          'watered',coalesce((v_plot->>'watered')::boolean,false)));
        v_plot_count := v_plot_count + 1;
      else
        v_plots := v_plots || jsonb_build_array(jsonb_build_object(
          'state',v_plot_state,'crop_key',null,'planted_at',null,'ready_at',null,'watered',false));
      end if;
    end loop;
  end if;
  while jsonb_array_length(v_plots) < 18 loop
    v_plots := v_plots || jsonb_build_array(jsonb_build_object(
      'state','grass','crop_key',null,'planted_at',null,'ready_at',null,'watered',false));
  end loop;

  -- Transfer owned animals and breed variants. Any active production starts a
  -- fresh server-timed batch so old client timestamps cannot mint ready goods.
  foreach v_animal_key in array array['chicken','pig','cow','fish'] loop
    begin
      v_count := greatest(0,least(8,coalesce((v_save->'animalCounts'->>v_animal_key)::integer,
        case when coalesce((v_save->'animalOwned'->>v_animal_key)::boolean,false) then 1 else 0 end)));
    exception when others then v_count := 0; end;
    if v_count > 0 then
      v_variants := '{}'::jsonb;
      v_variant_left := v_count;
      if jsonb_typeof(v_save->'animalBreeds') = 'object' then
        for v_variant in
          select c.variant_id, greatest(0,least(8,coalesce((e.value #>> '{}')::integer,0))) as quantity
          from jsonb_each(v_save->'animalBreeds') e
          join public.animal_variant_catalog_v2 c on c.variant_id = e.key and c.animal_key = v_animal_key
          where c.enabled and jsonb_typeof(e.value) = 'number' order by c.variant_id
        loop
          v_variant_qty := least(v_variant_left,v_variant.quantity);
          if v_variant_qty > 0 then
            v_variants := jsonb_set(v_variants,array[v_variant.variant_id],to_jsonb(v_variant_qty),true);
            v_variant_left := v_variant_left - v_variant_qty;
          end if;
          exit when v_variant_left = 0;
        end loop;
      end if;
      if v_variant_left > 0 then
        v_key := case v_animal_key when 'chicken' then 'chicken_field'
          when 'pig' then 'pig_pink' when 'cow' then 'cow_dairy' else 'fish_pond' end;
        v_variants := jsonb_set(v_variants,array[v_key],to_jsonb(v_variant_left),true);
      end if;
      v_animal := coalesce(v_save->'animals'->v_animal_key,'{}'::jsonb);
      v_active := coalesce(nullif(v_animal->>'fedAt','')::numeric,0) > 0
        or coalesce(nullif(v_animal->>'readyAt','')::numeric,0) > 0;
      if v_active then
        v_animal_seconds := case v_animal_key when 'chicken' then 300 when 'pig' then 420 else 360 end;
        v_animal_seconds := greatest(1,round(v_animal_seconds *
          coalesce((v_config->>'animalTimeMultiplier')::numeric,1)))::integer;
        v_animal := jsonb_build_object('count',v_count,'variants',v_variants,
          'fed_at',v_now,'ready_at',v_now + make_interval(secs => v_animal_seconds),
          'batch_count',v_count);
      else
        v_animal := jsonb_build_object('count',v_count,'variants',v_variants,
          'fed_at',null,'ready_at',null,'batch_count',0);
      end if;
      v_animals := jsonb_set(v_animals,array[v_animal_key],v_animal,true);
      v_animal_count := v_animal_count + v_count;
    end if;
  end loop;

  insert into public.player_wallets(user_id,coins,xp,updated_at)
  values (v_uid,v_coins,v_xp,v_now);
  insert into public.player_farm_state(user_id,farm_state,schema_version,revision,updated_at)
  values (v_uid,jsonb_build_object('plots',v_plots,'animals',v_animals,
    'schema_version',1,'garden_name',left(coalesce(v_save->>'gardenName',''),24),
    'legacy_save',v_save),1,1,v_now);

  v_summary := jsonb_build_object('ok',true,'already_imported',false,
    'coins',v_coins,'xp',v_xp,'planted_plots',v_plot_count,
    'animals',v_animal_count,'inventory_keys',v_inventory_count,
    'legacy_save_preserved',true,'source_updated_at',v_source_updated_at,
    'active_growth_restarted',true);
  insert into public.legacy_save_imports_v2(user_id,source_updated_at,imported_at,import_summary)
  values (v_uid,v_source_updated_at,v_now,v_summary);
  return v_summary;
end;
$$;

revoke all on function public.migrate_legacy_save_v2() from public, anon, authenticated;
grant execute on function public.migrate_legacy_save_v2() to authenticated;

comment on table public.legacy_save_imports_v2 is
  'Server-only idempotency ledger for one-time legacy save import; source game_saves remains untouched.';
comment on function public.migrate_legacy_save_v2() is
  'Imports only auth.uid() current game_saves row, with no client payload. One transaction; preserves original JSON and never overwrites existing canonical state.';

commit;
