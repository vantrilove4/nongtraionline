  -- Canonical fruit orchard actions. This migration preserves existing orchard trees,
  -- but restarts their current growing cycle at migration time; it awards no
  -- historical fruit. All future purchases and harvests are server-authoritative.
  -- Requires canonical economy tables, public.game_saves, and migration 018's
  -- public.sell_inventory_item_v2(uuid,text,integer) RPC.

  begin;

  create table if not exists public.player_orchard_trees (
    user_id uuid not null references auth.users(id) on delete restrict,
    tree_id text not null check (length(tree_id) between 1 and 96),
    species text not null check (species in ('orange','mango','guava','lychee')),
    slot smallint not null check (slot between 0 and 7),
    planted_at timestamptz not null default transaction_timestamp(),
    updated_at timestamptz not null default transaction_timestamp(),
    primary key (user_id, tree_id),
    unique (user_id, slot)
  );

  alter table public.player_orchard_trees enable row level security;
  revoke all on table public.player_orchard_trees from public, anon, authenticated;

  -- Preserve trees from existing cloud saves. Historical timestamps are reset so
  -- importing a save cannot claim fruit that became ready before this migration.
  with legacy_trees as (
    select gs.user_id,
           left(coalesce(nullif(t.value->>'id',''), 'legacy-fruit-tree-' || (t.value->>'slot')), 96) as tree_id,
           t.value->>'species' as species,
           (t.value->>'slot')::smallint as slot,
           row_number() over (
             partition by gs.user_id, (t.value->>'slot')::smallint
             order by coalesce(t.value->>'id','')
           ) as slot_rank
    from public.game_saves gs
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(gs.save_data->'orchard'->'trees') = 'array'
        then gs.save_data->'orchard'->'trees' else '[]'::jsonb end
    ) as t(value)
    where t.value->>'species' in ('orange','mango','guava','lychee')
      and (t.value->>'slot') ~ '^[0-7]$'
  )
  insert into public.player_orchard_trees (user_id, tree_id, species, slot, planted_at, updated_at)
  select user_id, tree_id, species, slot, transaction_timestamp(), transaction_timestamp()
  from legacy_trees
  where slot_rank = 1
  on conflict do nothing;

  create or replace function public.get_my_orchard_trees_v1()
  returns jsonb
  language plpgsql
  volatile
  security definer
  set search_path = pg_catalog, public, auth
  as $$
  declare
    v_uid uuid := auth.uid();
    v_trees jsonb;
  begin
    if v_uid is null then
      raise exception using errcode = '28000', message = 'Authentication required';
    end if;
    if not exists (select 1 from public.player_orchard_trees where user_id = v_uid) then
      insert into public.player_orchard_trees(user_id, tree_id, species, slot)
      values (v_uid, 'orange-starter', 'orange', 0)
      on conflict do nothing;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', tree_id,
      'species', species,
      'slot', slot,
      'plantedAt', (extract(epoch from planted_at) * 1000)::bigint
    ) order by slot), '[]'::jsonb)
    into v_trees
    from public.player_orchard_trees where user_id = v_uid;
    return v_trees;
  end;
  $$;

  create or replace function public.buy_orchard_tree_v1(
    p_request_id uuid,
    p_species text,
    p_slot smallint
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
    v_price bigint;
    v_wallet public.player_wallets%rowtype;
    v_request public.economy_requests%rowtype;
    v_payload_hash text;
    v_tree_id text;
    v_response jsonb;
  begin
    if v_uid is null then raise exception using errcode = '28000', message = 'Authentication required'; end if;
    if p_request_id is null or p_species is null or p_species not in ('orange','mango','guava','lychee') or p_slot is null or p_slot not between 0 and 7 then
      raise exception using errcode = '22023', message = 'Invalid orchard purchase';
    end if;
    v_price := case p_species when 'orange' then 250 when 'mango' then 440 when 'guava' then 340 when 'lychee' then 680 end;
    v_payload_hash := encode(sha256(convert_to(jsonb_build_object('operation','buy_orchard_tree_v1','species',p_species,'slot',p_slot)::text,'UTF8')),'hex');
    insert into public.economy_requests(user_id,request_id,operation_type,payload_hash)
    values(v_uid,p_request_id,'buy_orchard_tree_v1',v_payload_hash) on conflict(user_id,request_id) do nothing;
    select * into v_request from public.economy_requests where user_id=v_uid and request_id=p_request_id for update;
    if not found or v_request.operation_type<>'buy_orchard_tree_v1' or v_request.payload_hash<>v_payload_hash then
      raise exception using errcode = '22023', message = 'Request id was already used for a different purchase';
    end if;
    if v_request.response is not null then return v_request.response; end if;
    select * into v_wallet from public.player_wallets where user_id=v_uid for update;
    if not found then raise exception using errcode = '55000', message = 'Canonical wallet is not initialized'; end if;
    if exists(select 1 from public.player_orchard_trees where user_id=v_uid and slot=p_slot) then
      raise exception using errcode = '23505', message = 'Orchard slot is occupied';
    end if;
    if (select count(*) from public.player_orchard_trees where user_id=v_uid) >= 8 then
      raise exception using errcode = '22023', message = 'Orchard is full';
    end if;
    if v_wallet.coins < v_price then raise exception using errcode = '22023', message = 'Insufficient coins'; end if;
    v_tree_id := 'fruit-tree-' || replace(gen_random_uuid()::text,'-','');
    update public.player_wallets set coins=coins-v_price,updated_at=v_now where user_id=v_uid;
    insert into public.player_orchard_trees(user_id,tree_id,species,slot,planted_at,updated_at)
    values(v_uid,v_tree_id,p_species,p_slot,v_now,v_now);
    v_response := jsonb_build_object('ok',true,'coins_remaining',v_wallet.coins-v_price,
      'tree',jsonb_build_object('id',v_tree_id,'species',p_species,'slot',p_slot,'plantedAt',(extract(epoch from v_now)*1000)::bigint));
    update public.economy_requests set response=v_response,completed_at=v_now where user_id=v_uid and request_id=p_request_id;
    return v_response;
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
    v_cycle_seconds := case v_tree.species when 'orange' then 240 when 'mango' then 360 when 'guava' then 300 when 'lychee' then 480 end;
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

  create or replace function public.sell_orchard_tree_v1(p_request_id uuid,p_tree_id text)
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
    v_refund bigint;
    v_payload_hash text;
    v_response jsonb;
  begin
    if v_uid is null then raise exception using errcode = '28000', message = 'Authentication required'; end if;
    if p_request_id is null or p_tree_id is null or length(p_tree_id) not between 1 and 96 then
      raise exception using errcode = '22023', message = 'Invalid orchard tree sale';
    end if;
    v_payload_hash := encode(sha256(convert_to(jsonb_build_object('operation','sell_orchard_tree_v1','tree_id',p_tree_id)::text,'UTF8')),'hex');
    insert into public.economy_requests(user_id,request_id,operation_type,payload_hash)
    values(v_uid,p_request_id,'sell_orchard_tree_v1',v_payload_hash) on conflict(user_id,request_id) do nothing;
    select * into v_request from public.economy_requests where user_id=v_uid and request_id=p_request_id for update;
    if not found or v_request.operation_type<>'sell_orchard_tree_v1' or v_request.payload_hash<>v_payload_hash then
      raise exception using errcode = '22023', message = 'Request id was already used for a different tree sale';
    end if;
    if v_request.response is not null then return v_request.response; end if;
    select * into v_wallet from public.player_wallets where user_id=v_uid for update;
    if not found then raise exception using errcode = '55000', message = 'Canonical wallet is not initialized'; end if;
    select * into v_tree from public.player_orchard_trees where user_id=v_uid and tree_id=p_tree_id for update;
    if not found then raise exception using errcode = '42501', message = 'Orchard tree does not belong to this account'; end if;
    if v_now >= v_tree.planted_at + make_interval(secs => case v_tree.species when 'orange' then 240 when 'mango' then 360 when 'guava' then 300 when 'lychee' then 480 end) then
      raise exception using errcode = '22023', message = 'Harvest fruit before selling this tree';
    end if;
    v_refund := case v_tree.species when 'orange' then 125 when 'mango' then 220 when 'guava' then 170 when 'lychee' then 340 end;
    delete from public.player_orchard_trees where user_id=v_uid and tree_id=p_tree_id;
    update public.player_wallets set coins=coins+v_refund,updated_at=v_now where user_id=v_uid;
    v_response := jsonb_build_object('ok',true,'tree_id',p_tree_id,'coins_remaining',v_wallet.coins+v_refund);
    update public.economy_requests set response=v_response,completed_at=v_now where user_id=v_uid and request_id=p_request_id;
    return v_response;
  end;
  $$;

  revoke all on function public.get_my_orchard_trees_v1() from public, anon, authenticated;
  revoke all on function public.buy_orchard_tree_v1(uuid,text,smallint) from public, anon, authenticated;
  revoke all on function public.harvest_orchard_fruit_v1(uuid,text) from public, anon, authenticated;
  revoke all on function public.sell_orchard_tree_v1(uuid,text) from public, anon, authenticated;
  grant execute on function public.get_my_orchard_trees_v1() to authenticated;
  grant execute on function public.buy_orchard_tree_v1(uuid,text,smallint) to authenticated;
  grant execute on function public.harvest_orchard_fruit_v1(uuid,text) to authenticated;
  grant execute on function public.sell_orchard_tree_v1(uuid,text) to authenticated;

  notify pgrst, 'reload schema';

  commit;
