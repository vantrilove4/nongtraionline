-- Canonical economy coverage for processing, animal sales, visitor rewards,
-- cosmetics/decorations, and player marketplace.
-- Draft only: have the operator review and apply to staging first. It does not
-- modify game_saves or import old balances. The market read RPC uses only gardenName
-- as a display label; the legacy save-backed marketplace is never used for economy.

begin;

-- Processing queue: ingredients are reserved at enqueue time. Completion uses
-- server timestamps and is materialized exactly once by the read/enqueue RPCs.
create table if not exists public.player_processing_jobs_v1 (
  job_id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete restrict,
  recipe_id text not null check (recipe_id in ('berryYogurt','pumpkinPie','fishStew','cornSausage')),
  output_key text not null check (output_key in ('berry_yogurt','pumpkin_pie','fish_stew','corn_sausage')),
  needs jsonb not null check (jsonb_typeof(needs)='array'),
  output_quantity integer not null default 1 check (output_quantity=1),
  xp_reward integer not null check (xp_reward between 0 and 1000),
  duration_seconds integer not null check (duration_seconds between 1 and 86400),
  queued_at timestamptz not null default transaction_timestamp(),
  starts_at timestamptz not null,
  completes_at timestamptz not null,
  status text not null check (status in ('queued','processing','completed')),
  completed_at timestamptz,
  constraint player_processing_jobs_time_ck check (completes_at > starts_at),
  constraint player_processing_jobs_completion_ck check ((status='completed')=(completed_at is not null))
);
create index if not exists player_processing_jobs_user_queue_idx
  on public.player_processing_jobs_v1(user_id, status, starts_at, job_id);
alter table public.player_processing_jobs_v1 enable row level security;
revoke all on table public.player_processing_jobs_v1 from public, anon, authenticated;

create table if not exists public.player_cosmetic_ownership_v1 (
  user_id uuid not null references auth.users(id) on delete restrict,
  item_type text not null check (item_type in ('character','skin')),
  item_id text not null check (item_id ~ '^[a-z][a-z0-9_-]{0,63}$'),
  purchased_at timestamptz not null default transaction_timestamp(),
  primary key(user_id,item_type,item_id)
);
alter table public.player_cosmetic_ownership_v1 enable row level security;
revoke all on table public.player_cosmetic_ownership_v1 from public, anon, authenticated;
grant select on table public.player_cosmetic_ownership_v1 to authenticated;
drop policy if exists player_cosmetic_ownership_read_own_v1 on public.player_cosmetic_ownership_v1;
create policy player_cosmetic_ownership_read_own_v1 on public.player_cosmetic_ownership_v1
  for select to authenticated using ((select auth.uid())=user_id);

create table if not exists public.player_animal_vouchers_v1 (
  user_id uuid not null references auth.users(id) on delete restrict,
  variant_id text not null references public.animal_variant_catalog_v2(variant_id) on delete restrict,
  quantity integer not null default 0 check (quantity>=0),
  updated_at timestamptz not null default transaction_timestamp(),
  primary key(user_id,variant_id)
);
alter table public.player_animal_vouchers_v1 enable row level security;
revoke all on table public.player_animal_vouchers_v1 from public, anon, authenticated;
grant select on table public.player_animal_vouchers_v1 to authenticated;
drop policy if exists player_animal_vouchers_read_own_v1 on public.player_animal_vouchers_v1;
create policy player_animal_vouchers_read_own_v1 on public.player_animal_vouchers_v1
  for select to authenticated using ((select auth.uid())=user_id);

create table if not exists public.player_visitor_missions_v1 (
  user_id uuid primary key references auth.users(id) on delete restrict,
  cycle text not null default 'waiting' check (cycle in ('waiting','active','wandering')),
  batch integer not null default 1 check (batch>0),
  accepted_at timestamptz,
  leave_at timestamptz,
  next_arrival_at timestamptz,
  progress jsonb not null default '{}'::jsonb check (jsonb_typeof(progress)='object'),
  claimed jsonb not null default '{}'::jsonb check (jsonb_typeof(claimed)='object'),
  updated_at timestamptz not null default transaction_timestamp(),
  check ((cycle='active')=(accepted_at is not null and leave_at is not null))
);
alter table public.player_visitor_missions_v1 enable row level security;
revoke all on table public.player_visitor_missions_v1 from public, anon, authenticated;
grant select on table public.player_visitor_missions_v1 to authenticated;
drop policy if exists player_visitor_missions_read_own_v1 on public.player_visitor_missions_v1;
create policy player_visitor_missions_read_own_v1 on public.player_visitor_missions_v1
  for select to authenticated using ((select auth.uid())=user_id);

-- Market escrow is separate from the legacy marketplace tables/RPCs. Existing
-- listings remain untouched and are not merged into canonical inventory.
create table if not exists public.market_listings_v2 (
  listing_id bigint generated always as identity primary key,
  seller_id uuid not null references auth.users(id) on delete restrict,
  item_key text not null check (item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  quantity integer not null check (quantity between 1 and 1000000),
  price_each bigint not null check (price_each between 1 and 1000000000),
  status text not null default 'open' check (status in ('open','sold','cancelled')),
  created_at timestamptz not null default transaction_timestamp(),
  updated_at timestamptz not null default transaction_timestamp(),
  buyer_id uuid references auth.users(id) on delete restrict,
  sold_at timestamptz,
  check ((status='sold')=(buyer_id is not null and sold_at is not null))
);
create index if not exists market_listings_v2_open_idx on public.market_listings_v2(created_at desc) where status='open';
create index if not exists market_listings_v2_seller_idx on public.market_listings_v2(seller_id,status,created_at desc);
alter table public.market_listings_v2 enable row level security;
revoke all on table public.market_listings_v2 from public, anon, authenticated;

-- Shared idempotency helper. Calling RPCs still authenticate with auth.uid().
create or replace function public.reserve_economy_request_v1(p_request_id uuid,p_operation text,p_payload jsonb)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_hash text; v_row public.economy_requests%rowtype;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if p_request_id is null then raise exception using errcode='22023',message='Request id is required'; end if;
  v_hash:=encode(sha256(convert_to(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'UTF8')),'hex');
  insert into public.economy_requests(user_id,request_id,operation_type,payload_hash)
  values(v_uid,p_request_id,p_operation,v_hash) on conflict(user_id,request_id) do nothing;
  select * into v_row from public.economy_requests where user_id=v_uid and request_id=p_request_id for update;
  if v_row.operation_type<>p_operation or v_row.payload_hash<>v_hash then
    raise exception using errcode='22023',message='Request id was already used for a different action';
  end if;
  if v_row.response is not null then return jsonb_build_object('replay',true,'response',v_row.response); end if;
  return jsonb_build_object('replay',false);
end; $$;

create or replace function public.finish_economy_request_v1(p_request_id uuid,p_response jsonb)
returns void language sql volatile security definer set search_path=pg_catalog,public,auth as $$
  update public.economy_requests set response=p_response,completed_at=transaction_timestamp()
  where user_id=auth.uid() and request_id=p_request_id and response is null;
$$;

create or replace function public.canonical_level_bonus_v1(p_xp bigint,p_xp_add bigint)
returns bigint language plpgsql immutable security definer set search_path=pg_catalog,public as $$
declare v_before integer:=1; v_after integer:=1; v_total bigint:=greatest(0,p_xp); v_next bigint:=greatest(0,p_xp)+greatest(0,p_xp_add);
begin
  while v_before<60 and p_xp >= (80*v_before+10*v_before*(v_before-1)) loop v_before:=v_before+1; end loop;
  while v_after<60 and v_next >= (80*v_after+10*v_after*(v_after-1)) loop v_after:=v_after+1; end loop;
  return greatest(0,v_after-v_before)*30;
end; $$;

create or replace function public.materialize_processing_jobs_v1(p_uid uuid)
returns void language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_job public.player_processing_jobs_v1%rowtype; v_wallet public.player_wallets%rowtype; v_bonus bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_uid::text,21));
  for v_job in select * from public.player_processing_jobs_v1
    where user_id=p_uid and status<>'completed' and completes_at<=transaction_timestamp()
    order by completes_at,job_id for update
  loop
    select * into v_wallet from public.player_wallets where user_id=p_uid for update;
    if not found then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
    v_bonus:=public.canonical_level_bonus_v1(v_wallet.xp,v_job.xp_reward);
    insert into public.player_inventory(user_id,item_key,quantity,updated_at)
    values(p_uid,v_job.output_key,v_job.output_quantity,transaction_timestamp())
    on conflict(user_id,item_key) do update set quantity=public.player_inventory.quantity+excluded.quantity,updated_at=excluded.updated_at;
    update public.player_wallets set xp=xp+v_job.xp_reward,coins=coins+v_bonus,updated_at=transaction_timestamp() where user_id=p_uid;
    update public.player_processing_jobs_v1 set status='completed',completed_at=transaction_timestamp()
    where job_id=v_job.job_id and status<>'completed';
  end loop;
end; $$;

create or replace function public.get_my_processing_v1()
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_jobs jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  perform public.materialize_processing_jobs_v1(v_uid);
  with ranked as (
    select job_id,row_number() over(order by starts_at,job_id) as rn
    from public.player_processing_jobs_v1 where user_id=v_uid and status<>'completed'
  ) update public.player_processing_jobs_v1 j set status=case when r.rn=1 then 'processing' else 'queued' end
    from ranked r where j.job_id=r.job_id;
  select coalesce(jsonb_agg(jsonb_build_object('id',recipe_id,'startedAt',(extract(epoch from starts_at)*1000)::bigint,
    'durationMs',duration_seconds*1000,'status',status,'jobId',job_id) order by starts_at,job_id),'[]'::jsonb)
  into v_jobs from public.player_processing_jobs_v1 where user_id=v_uid and status<>'completed';
  return jsonb_build_object('jobs',v_jobs);
end; $$;

create or replace function public.enqueue_processing_v1(p_request_id uuid,p_recipe_id text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare
  v_uid uuid:=auth.uid(); v_now timestamptz:=transaction_timestamp(); v_req jsonb;
  v_recipe text; v_output text; v_needs jsonb; v_xp integer; v_secs integer; v_count integer;
  v_start timestamptz; v_end timestamptz; v_item text; v_need integer; v_stock bigint;
  v_job_id bigint; v_response jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'enqueue_processing_v1',jsonb_build_object('recipe_id',p_recipe_id));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select r.recipe_id,r.output_key,r.needs,r.xp_reward,r.duration_seconds into v_recipe,v_output,v_needs,v_xp,v_secs
  from (values
    ('berryYogurt','berry_yogurt','[{"item":"berry","quantity":2},{"item":"milk","quantity":1}]'::jsonb,28,35),
    ('pumpkinPie','pumpkin_pie','[{"item":"pumpkin","quantity":1},{"item":"eggs","quantity":2}]'::jsonb,22,45),
    ('fishStew','fish_stew','[{"item":"fish","quantity":1},{"item":"corn","quantity":2}]'::jsonb,26,40),
    ('cornSausage','corn_sausage','[{"item":"pork","quantity":1},{"item":"corn","quantity":2}]'::jsonb,30,50)
  ) r(recipe_id,output_key,needs,xp_reward,duration_seconds) where r.recipe_id=p_recipe_id;
  if not found then raise exception using errcode='22023',message='Unknown processing recipe'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text,21));
  perform public.materialize_processing_jobs_v1(v_uid);
  select count(*) into v_count from public.player_processing_jobs_v1 where user_id=v_uid and status<>'completed';
  if v_count>=8 then raise exception using errcode='22023',message='Processing queue is full'; end if;
  for v_item,v_need in select e->>'item',(e->>'quantity')::integer from jsonb_array_elements(v_needs) e order by e->>'item'
  loop
    select quantity into v_stock from public.player_inventory where user_id=v_uid and item_key=v_item for update;
    if not found or v_stock<v_need then raise exception using errcode='22023',message='Insufficient inventory for processing: '||v_item; end if;
    update public.player_inventory set quantity=quantity-v_need,updated_at=v_now where user_id=v_uid and item_key=v_item;
  end loop;
  select coalesce(max(completes_at),v_now) into v_start from public.player_processing_jobs_v1 where user_id=v_uid and status<>'completed';
  v_start:=greatest(v_start,v_now); v_end:=v_start+make_interval(secs=>v_secs);
  insert into public.player_processing_jobs_v1(user_id,recipe_id,output_key,needs,xp_reward,duration_seconds,queued_at,starts_at,completes_at,status)
  values(v_uid,v_recipe,v_output,v_needs,v_xp,v_secs,v_now,v_start,v_end,case when v_count=0 then 'processing' else 'queued' end)
  returning job_id into v_job_id;
  v_response:=jsonb_build_object('ok',true,'job_id',v_job_id,'recipe_id',v_recipe,'starts_at_ms',(extract(epoch from v_start)*1000)::bigint,
    'duration_ms',v_secs*1000,'completes_at_ms',(extract(epoch from v_end)*1000)::bigint,'jobs_used',v_count+1);
  perform public.finish_economy_request_v1(p_request_id,v_response); return v_response;
end; $$;

create or replace function public.sell_animal_v1(p_request_id uuid,p_variant_id text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare
  v_uid uuid:=auth.uid(); v_now timestamptz:=transaction_timestamp(); v_req jsonb; v_wallet public.player_wallets%rowtype;
  v_farm public.player_farm_state%rowtype; v_variant public.animal_variant_catalog_v2%rowtype;
  v_animals jsonb; v_animal jsonb; v_variants jsonb; v_count integer; v_breed integer; v_refund bigint; v_response jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'sell_animal_v1',jsonb_build_object('variant_id',p_variant_id));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_variant from public.animal_variant_catalog_v2 where variant_id=p_variant_id and enabled;
  if not found then raise exception using errcode='22023',message='Unknown animal variant'; end if;
  select * into v_wallet from public.player_wallets where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
  select * into v_farm from public.player_farm_state where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical farm is not initialized'; end if;
  v_animals:=v_farm.farm_state->'animals'; v_animal:=v_animals->v_variant.animal_key;
  if jsonb_typeof(v_animal) is distinct from 'object' then raise exception using errcode='22023',message='Animal does not belong to this farm'; end if;
  v_variants:=coalesce(v_animal->'variants','{}'::jsonb); v_breed:=coalesce((v_variants->>p_variant_id)::integer,0);
  v_count:=coalesce((v_animal->>'count')::integer,0);
  if v_breed<1 or v_count<1 then raise exception using errcode='22023',message='Animal does not belong to this farm'; end if;
  if v_count=1 and nullif(v_animal->>'ready_at','') is not null then raise exception using errcode='55000',message='Collect products before selling the last animal'; end if;
  v_refund:=greatest(1,round(v_variant.price*0.5)::bigint);
  v_variants:=jsonb_set(v_variants,array[p_variant_id],to_jsonb(v_breed-1),true);
  v_animal:=jsonb_set(v_animal,'{count}',to_jsonb(v_count-1),true);
  v_animal:=jsonb_set(v_animal,'{variants}',v_variants,true);
  v_animals:=jsonb_set(v_animals,array[v_variant.animal_key],v_animal,false);
  update public.player_wallets set coins=coins+v_refund,updated_at=v_now where user_id=v_uid;
  update public.player_farm_state set farm_state=jsonb_set(farm_state,'{animals}',v_animals,false),revision=revision+1,updated_at=v_now where user_id=v_uid;
  v_response:=jsonb_build_object('ok',true,'animal_key',v_variant.animal_key,'variant_id',p_variant_id,'count',v_count-1,'breed_count',v_breed-1,'refund',v_refund,'coins_remaining',v_wallet.coins+v_refund,'farm_revision',v_farm.revision+1);
  perform public.finish_economy_request_v1(p_request_id,v_response); return v_response;
end; $$;

create or replace function public.update_visitor_progress_v1()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_key text; v_m public.player_visitor_missions_v1%rowtype; v_now timestamptz:=transaction_timestamp(); v_add integer:=1;
begin
  if new.response is null or old.response is not null then return new; end if;
  v_key:=case new.operation_type when 'plant_crop_v2' then 'plant' when 'harvest_crop_v2' then 'harvest' when 'harvest_orchard_fruit_v1' then 'harvest'
    when 'water_crop_v2' then 'water' when 'feed_animal_v2' then 'feed' when 'collect_animal_v2' then 'animal' else null end;
  if v_key is null then return new; end if;
  select * into v_m from public.player_visitor_missions_v1 where user_id=new.user_id for update;
  if not found or v_m.cycle<>'active' or v_m.leave_at<=v_now then return new; end if;
  update public.player_visitor_missions_v1 set progress=jsonb_set(progress,array[v_key],to_jsonb(least(
    case v_key when 'plant' then 3 when 'harvest' then 2 when 'water' then 2 when 'feed' then 2 else 1 end,
    coalesce((progress->>v_key)::integer,0)+v_add)),true),updated_at=v_now where user_id=new.user_id;
  return new;
end; $$;
drop trigger if exists economy_request_visitor_progress_v1 on public.economy_requests;
create trigger economy_request_visitor_progress_v1 after update of response on public.economy_requests
for each row execute function public.update_visitor_progress_v1();

create or replace function public.get_my_visitor_missions_v1()
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_now timestamptz:=transaction_timestamp(); v_m public.player_visitor_missions_v1%rowtype;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  insert into public.player_visitor_missions_v1(user_id) values(v_uid) on conflict(user_id) do nothing;
  select * into v_m from public.player_visitor_missions_v1 where user_id=v_uid for update;
  if v_m.cycle='active' and v_m.leave_at<=v_now then
    update public.player_visitor_missions_v1 set cycle='wandering',accepted_at=null,leave_at=null,next_arrival_at=v_now+interval '30 minutes',updated_at=v_now where user_id=v_uid;
  elsif v_m.cycle='wandering' and v_m.next_arrival_at<=v_now then
    update public.player_visitor_missions_v1 set cycle='waiting',batch=batch+1,next_arrival_at=null,progress='{}',claimed='{}',updated_at=v_now where user_id=v_uid;
  end if;
  select * into v_m from public.player_visitor_missions_v1 where user_id=v_uid;
  return jsonb_build_object('cycle',v_m.cycle,'batch',v_m.batch,'acceptedAt',case when v_m.accepted_at is null then 0 else (extract(epoch from v_m.accepted_at)*1000)::bigint end,
    'leaveAt',case when v_m.leave_at is null then 0 else (extract(epoch from v_m.leave_at)*1000)::bigint end,
    'nextArrivalAt',case when v_m.next_arrival_at is null then 0 else (extract(epoch from v_m.next_arrival_at)*1000)::bigint end,
    'progress',v_m.progress,'claimed',v_m.claimed);
end; $$;

create or replace function public.accept_visitor_missions_v1(p_request_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_now timestamptz:=transaction_timestamp(); v_req jsonb; v_m public.player_visitor_missions_v1%rowtype; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'accept_visitor_missions_v1','{}'::jsonb);
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  perform public.get_my_visitor_missions_v1();
  select * into v_m from public.player_visitor_missions_v1 where user_id=v_uid for update;
  if v_m.cycle<>'waiting' then raise exception using errcode='55000',message='Visitor missions are not available'; end if;
  update public.player_visitor_missions_v1 set cycle='active',accepted_at=v_now,leave_at=v_now+interval '30 minutes',progress='{}',claimed='{}',updated_at=v_now where user_id=v_uid;
  v_resp:=jsonb_build_object('ok',true,'cycle','active','acceptedAt',(extract(epoch from v_now)*1000)::bigint,'leaveAt',(extract(epoch from (v_now+interval '30 minutes'))*1000)::bigint,'progress','{}'::jsonb,'claimed','{}'::jsonb);
  perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

create or replace function public.claim_visitor_quest_v1(p_request_id uuid,p_quest_id text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare
  v_uid uuid:=auth.uid(); v_now timestamptz:=transaction_timestamp(); v_req jsonb; v_m public.player_visitor_missions_v1%rowtype;
  v_wallet public.player_wallets%rowtype; v_coins bigint; v_xp bigint; v_level_bonus bigint; v_target integer; v_seed text; v_seed_qty integer;
  v_vouchers jsonb; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'claim_visitor_quest_v1',jsonb_build_object('quest_id',p_quest_id));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_wallet from public.player_wallets where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
  select * into v_m from public.player_visitor_missions_v1 where user_id=v_uid for update;
  if not found or v_m.cycle<>'active' or v_m.leave_at<=v_now then raise exception using errcode='55000',message='Visitor mission has expired'; end if;
  select coins,xp,target,seed,seed_qty,vouchers into v_coins,v_xp,v_target,v_seed,v_seed_qty,v_vouchers from (values
    ('plant',30::bigint,8::bigint,3,'seed_carrot',2,'{}'::jsonb),
    ('harvest',65::bigint,16::bigint,2,'seed_potato',2,'{"chicken_silkie":1}'::jsonb),
    ('water',75::bigint,20::bigint,2,'seed_corn',3,'{"chicken_golden":1}'::jsonb),
    ('feed',145::bigint,36::bigint,2,'seed_pumpkin',3,'{"pig_cream":1}'::jsonb),
    ('animal',280::bigint,72::bigint,1,'seed_berry',4,'{"cow_special_bellcloud":1,"fish_koi":1}'::jsonb)
  ) q(id,coins,xp,target,seed,seed_qty,vouchers) where q.id=p_quest_id;
  if not found then raise exception using errcode='22023',message='Unknown visitor quest'; end if;
  if coalesce((v_m.claimed->>p_quest_id)::boolean,false) then raise exception using errcode='23505',message='Visitor reward already claimed'; end if;
  if coalesce((v_m.progress->>p_quest_id)::integer,0)<v_target then raise exception using errcode='55000',message='Visitor quest is not complete'; end if;
  v_level_bonus:=public.canonical_level_bonus_v1(v_wallet.xp,v_xp);
  update public.player_wallets set coins=coins+v_coins+v_level_bonus,xp=xp+v_xp,updated_at=v_now where user_id=v_uid;
  insert into public.player_inventory(user_id,item_key,quantity,updated_at) values(v_uid,v_seed,v_seed_qty,v_now)
  on conflict(user_id,item_key) do update set quantity=public.player_inventory.quantity+excluded.quantity,updated_at=v_now;
  insert into public.player_animal_vouchers_v1(user_id,variant_id,quantity,updated_at)
  select v_uid,key,value::integer,v_now from jsonb_each_text(v_vouchers)
  on conflict(user_id,variant_id) do update set quantity=public.player_animal_vouchers_v1.quantity+excluded.quantity,updated_at=v_now;
  if (select count(*) from jsonb_each_text(v_m.claimed||jsonb_build_object(p_quest_id,true)) where value='true')>=5 then
    update public.player_visitor_missions_v1 set claimed=jsonb_set(claimed,array[p_quest_id],'true'::jsonb,true),cycle='wandering',accepted_at=null,leave_at=null,next_arrival_at=v_now+interval '30 minutes',updated_at=v_now where user_id=v_uid;
  else
    update public.player_visitor_missions_v1 set claimed=jsonb_set(claimed,array[p_quest_id],'true'::jsonb,true),updated_at=v_now where user_id=v_uid;
  end if;
  v_resp:=jsonb_build_object('ok',true,'quest_id',p_quest_id,'coins_awarded',v_coins,'xp_awarded',v_xp,'coins_remaining',v_wallet.coins+v_coins+v_level_bonus,'level_up_coins',v_level_bonus,'xp_total',v_wallet.xp+v_xp,'seed_key',v_seed,'seed_quantity',v_seed_qty,'vouchers',v_vouchers,'cycle',case when (select count(*) from jsonb_each_text(v_m.claimed||jsonb_build_object(p_quest_id,true)) where value='true')>=5 then 'wandering' else 'active' end,'next_arrival_at_ms',case when (select count(*) from jsonb_each_text(v_m.claimed||jsonb_build_object(p_quest_id,true)) where value='true')>=5 then (extract(epoch from (v_now+interval '30 minutes'))*1000)::bigint else null end);
  perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

create or replace function public.redeem_animal_voucher_v1(p_request_id uuid,p_variant_id text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_req jsonb; v_var public.animal_variant_catalog_v2%rowtype; v_farm public.player_farm_state%rowtype; v_wallet public.player_wallets%rowtype; v_level integer:=1;
  v_animal jsonb; v_animals jsonb; v_vars jsonb; v_qty integer; v_count integer; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'redeem_animal_voucher_v1',jsonb_build_object('variant_id',p_variant_id));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_var from public.animal_variant_catalog_v2 where variant_id=p_variant_id and enabled;
  if not found then raise exception using errcode='22023',message='Unknown animal variant'; end if;
  select * into v_wallet from public.player_wallets where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
  select quantity into v_qty from public.player_animal_vouchers_v1 where user_id=v_uid and variant_id=p_variant_id for update;
  if not found or v_qty<1 then raise exception using errcode='55000',message='Animal voucher is unavailable'; end if;
  while v_level<60 and v_wallet.xp >= (80*v_level+10*v_level*(v_level-1)) loop v_level:=v_level+1; end loop;
  if v_level<v_var.unlock_level then raise exception using errcode='55000',message='Animal is still locked'; end if;
  select * into v_farm from public.player_farm_state where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical farm is not initialized'; end if;
  v_animals:=v_farm.farm_state->'animals'; v_animal:=coalesce(v_animals->v_var.animal_key,'{}'::jsonb);
  v_count:=coalesce((v_animal->>'count')::integer,0); if v_count>=8 then raise exception using errcode='55000',message='Animal capacity reached'; end if;
  v_vars:=coalesce(v_animal->'variants','{}'::jsonb); v_vars:=jsonb_set(v_vars,array[p_variant_id],to_jsonb(coalesce((v_vars->>p_variant_id)::integer,0)+1),true);
  v_animal:=jsonb_build_object('fed_at',null,'ready_at',null,'batch_count',0)||v_animal;
  v_animal:=jsonb_set(v_animal,'{count}',to_jsonb(v_count+1),true); v_animal:=jsonb_set(v_animal,'{variants}',v_vars,true);
  v_animals:=jsonb_set(v_animals,array[v_var.animal_key],v_animal,true);
  update public.player_farm_state set farm_state=jsonb_set(farm_state,'{animals}',v_animals,false),revision=revision+1,updated_at=transaction_timestamp() where user_id=v_uid;
  update public.player_animal_vouchers_v1 set quantity=quantity-1,updated_at=transaction_timestamp() where user_id=v_uid and variant_id=p_variant_id;
  v_resp:=jsonb_build_object('ok',true,'variant_id',p_variant_id,'animal_key',v_var.animal_key,'count',v_count+1,'breed_count',coalesce((v_vars->>p_variant_id)::integer,1),'voucher_quantity',v_qty-1,'farm_revision',v_farm.revision+1);
  perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

create or replace function public.buy_farm_item_v1(p_request_id uuid,p_item_type text,p_item_id text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_req jsonb; v_wallet public.player_wallets%rowtype; v_farm public.player_farm_state%rowtype; v_cos jsonb; v_price bigint; v_key text; v_name text; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'buy_farm_item_v1',jsonb_build_object('item_type',p_item_type,'item_id',p_item_id));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  if p_item_type='decoration' then
    v_price:=case p_item_id when 'shrub' then 30 when 'lamp' then 50 when 'flower' then 35 when 'cottage' then 140 when 'scarecrow' then 90 end;
    v_key:='decor_'||p_item_id;
  elsif p_item_type='character' and p_item_id in ('piko','scout_farmer') then
    v_price:=case p_item_id when 'piko' then 6800 else 5200 end;
  elsif p_item_type='skin' and p_item_id='garden-moc' then v_price:=3200;
  else raise exception using errcode='22023',message='Unknown shop item'; end if;
  select * into v_wallet from public.player_wallets where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
  if v_wallet.coins<v_price then raise exception using errcode='22023',message='Insufficient coins'; end if;
  if p_item_type='decoration' then
    insert into public.player_inventory(user_id,item_key,quantity,updated_at) values(v_uid,v_key,1,transaction_timestamp())
    on conflict(user_id,item_key) do update set quantity=public.player_inventory.quantity+1,updated_at=excluded.updated_at;
  else
    insert into public.player_cosmetic_ownership_v1(user_id,item_type,item_id) values(v_uid,p_item_type,p_item_id)
    on conflict(user_id,item_type,item_id) do nothing;
    if not found then raise exception using errcode='23505',message='Item already owned'; end if;
    select * into v_farm from public.player_farm_state where user_id=v_uid for update;
    if not found then raise exception using errcode='55000',message='Canonical farm is not initialized'; end if;
    v_cos:=coalesce(v_farm.farm_state->'cosmetics','{}'::jsonb);
    if p_item_type='character' then v_cos:=jsonb_set(v_cos,'{character}',to_jsonb(p_item_id),true);
    else v_cos:=jsonb_set(v_cos,'{garden_skin}',to_jsonb(p_item_id),true); end if;
    update public.player_farm_state set farm_state=jsonb_set(farm_state,'{cosmetics}',v_cos,true),revision=revision+1,updated_at=transaction_timestamp() where user_id=v_uid;
  end if;
  update public.player_wallets set coins=coins-v_price,updated_at=transaction_timestamp() where user_id=v_uid;
  v_resp:=jsonb_build_object('ok',true,'item_type',p_item_type,'item_id',p_item_id,'price',v_price,'coins_remaining',v_wallet.coins-v_price,'inventory_quantity',case when p_item_type='decoration' then coalesce((select quantity from public.player_inventory where user_id=v_uid and item_key=v_key),0) else null end,'cosmetics',v_cos,'farm_revision',case when p_item_type='decoration' then null else v_farm.revision+1 end);
  perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

create or replace function public.set_my_cosmetic_v1(p_item_type text,p_item_id text,p_active boolean)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_farm public.player_farm_state%rowtype; v_cos jsonb; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if p_item_type not in ('character','skin') then raise exception using errcode='22023',message='Unknown cosmetic type'; end if;
  if p_active and not exists(select 1 from public.player_cosmetic_ownership_v1 where user_id=v_uid and item_type=p_item_type and item_id=p_item_id) then
    raise exception using errcode='42501',message='Cosmetic is not owned by this account'; end if;
  select * into v_farm from public.player_farm_state where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical farm is not initialized'; end if;
  v_cos:=coalesce(v_farm.farm_state->'cosmetics','{}'::jsonb);
  if p_item_type='character' then v_cos:=jsonb_set(v_cos,'{character}',case when p_active then to_jsonb(p_item_id) else '"default"'::jsonb end,true);
  else v_cos:=jsonb_set(v_cos,'{garden_skin}',case when p_active then to_jsonb(p_item_id) else '"classic"'::jsonb end,true); end if;
  update public.player_farm_state set farm_state=jsonb_set(farm_state,'{cosmetics}',v_cos,true),revision=revision+1,updated_at=transaction_timestamp() where user_id=v_uid;
  v_resp:=jsonb_build_object('ok',true,'cosmetics',v_cos,'farm_revision',v_farm.revision+1); return v_resp;
end; $$;

create or replace function public.update_farm_decorations_v1(p_request_id uuid,p_decorations jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_req jsonb; v_farm public.player_farm_state%rowtype; v_old jsonb; v_new jsonb; v_type text; v_diff integer; v_key text; v_stock bigint; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if jsonb_typeof(p_decorations) is distinct from 'array' or jsonb_array_length(p_decorations)>100 then raise exception using errcode='22023',message='Invalid decoration layout'; end if;
  if exists(select 1 from jsonb_array_elements(p_decorations) d where d->>'type' not in ('shrub','lamp','flower','cottage','scarecrow') or d->>'type' is null or length(coalesce(d->>'id','')) not between 1 and 96 or coalesce((d->>'x')::numeric,-1) not between 0 and 1920 or coalesce((d->>'y')::numeric,-1) not between 0 and 1080) then
    raise exception using errcode='22023',message='Invalid decoration placement'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'update_farm_decorations_v1',jsonb_build_object('decorations',p_decorations));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_farm from public.player_farm_state where user_id=v_uid for update;
  if not found then raise exception using errcode='55000',message='Canonical farm is not initialized'; end if;
  v_old:=case when jsonb_typeof(v_farm.farm_state->'decorations')='array' then v_farm.farm_state->'decorations' else '[]'::jsonb end;
  v_new:=p_decorations;
  foreach v_type in array array['shrub','lamp','flower','cottage','scarecrow'] loop
    v_diff:=(select count(*) from jsonb_array_elements(v_new) d where d->>'type'=v_type)::integer-(select count(*) from jsonb_array_elements(v_old) d where d->>'type'=v_type)::integer;
    v_key:='decor_'||v_type;
    if v_diff>0 then
      select quantity into v_stock from public.player_inventory where user_id=v_uid and item_key=v_key for update;
      if not found or v_stock<v_diff then raise exception using errcode='55000',message='Insufficient decoration stock: '||v_type; end if;
      update public.player_inventory set quantity=quantity-v_diff,updated_at=transaction_timestamp() where user_id=v_uid and item_key=v_key;
    elsif v_diff<0 then
      insert into public.player_inventory(user_id,item_key,quantity,updated_at) values(v_uid,v_key,-v_diff,transaction_timestamp())
      on conflict(user_id,item_key) do update set quantity=public.player_inventory.quantity+excluded.quantity,updated_at=excluded.updated_at;
    end if;
  end loop;
  update public.player_farm_state set farm_state=jsonb_set(farm_state,'{decorations}',v_new,true),revision=revision+1,updated_at=transaction_timestamp() where user_id=v_uid;
  v_resp:=jsonb_build_object('ok',true,'decorations',v_new,'farm_revision',v_farm.revision+1); perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

create or replace function public.get_my_farm_cosmetics_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_owned jsonb; v_farm jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('type',item_type,'id',item_id)),'[]'::jsonb) into v_owned from public.player_cosmetic_ownership_v1 where user_id=v_uid;
  select farm_state into v_farm from public.player_farm_state where user_id=v_uid;
  return jsonb_build_object('owned',v_owned,'cosmetics',coalesce(v_farm->'cosmetics','{}'::jsonb),'decorations',coalesce(v_farm->'decorations','[]'::jsonb));
end; $$;

create or replace function public.market_get_listings_v2()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_rows jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',l.listing_id,'item_key',l.item_key,'quantity',l.quantity,'price_each',l.price_each,
    'seller_name',coalesce(nullif(gs.save_data->>'gardenName',''),'Nhà vườn'),'is_mine',l.seller_id=v_uid,'created_at',l.created_at)
    order by l.created_at desc),'[]'::jsonb) into v_rows
  from public.market_listings_v2 l left join public.game_saves gs on gs.user_id=l.seller_id where l.status='open';
  return v_rows;
end; $$;

create or replace function public.market_create_listing_v2(p_request_id uuid,p_item_key text,p_quantity integer,p_price_each bigint)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_req jsonb; v_item text; v_stock bigint; v_id bigint; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_item:=case p_item_key when 'berryYogurt' then 'berry_yogurt' when 'pumpkinPie' then 'pumpkin_pie' when 'fishStew' then 'fish_stew' when 'cornSausage' then 'corn_sausage' else p_item_key end;
  if p_quantity not between 1 and 1000000 or p_price_each not between 1 and 1000000000 or v_item not in
    ('carrot','tomato','potato','corn','pumpkin','berry','sunflower','watermelon','eggplant','pineapple','grape','eggs','milk','pork','fish','orange_fruit','mango_fruit','guava_fruit','lychee_fruit','berry_yogurt','pumpkin_pie','fish_stew','corn_sausage') then raise exception using errcode='22023',message='Invalid marketplace listing'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'market_create_listing_v2',jsonb_build_object('item_key',p_item,'quantity',p_quantity,'price_each',p_price_each));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select quantity into v_stock from public.player_inventory where user_id=v_uid and item_key=v_item for update;
  if not found or v_stock<p_quantity then raise exception using errcode='55000',message='Insufficient inventory'; end if;
  update public.player_inventory set quantity=quantity-p_quantity,updated_at=transaction_timestamp() where user_id=v_uid and item_key=v_item;
  insert into public.market_listings_v2(seller_id,item_key,quantity,price_each) values(v_uid,v_item,p_quantity,p_price_each) returning listing_id into v_id;
  v_resp:=jsonb_build_object('ok',true,'listing_id',v_id,'item_key',v_item,'quantity',p_quantity,'inventory_quantity',v_stock-p_quantity);
  perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

create or replace function public.market_buy_listing_v2(p_request_id uuid,p_listing_id bigint)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_req jsonb; v_l public.market_listings_v2%rowtype; v_buyer public.player_wallets%rowtype; v_seller public.player_wallets%rowtype; v_total bigint; v_inv bigint; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'market_buy_listing_v2',jsonb_build_object('listing_id',p_listing_id));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_l from public.market_listings_v2 where listing_id=p_listing_id for update;
  if not found or v_l.status<>'open' then raise exception using errcode='55000',message='Listing is no longer available'; end if;
  if v_l.seller_id=v_uid then raise exception using errcode='22023',message='Cannot buy your own listing'; end if;
  v_total:=v_l.quantity*v_l.price_each;
  perform 1 from public.player_wallets where user_id in (v_uid,v_l.seller_id) order by user_id for update;
  select * into v_buyer from public.player_wallets where user_id=v_uid;
  select * into v_seller from public.player_wallets where user_id=v_l.seller_id;
  if v_buyer.user_id is null or v_seller.user_id is null then raise exception using errcode='55000',message='Canonical wallet is not initialized'; end if;
  if v_buyer.coins<v_total then raise exception using errcode='55000',message='Insufficient coins'; end if;
  update public.player_wallets set coins=coins-v_total,updated_at=transaction_timestamp() where user_id=v_uid;
  update public.player_wallets set coins=coins+v_total,updated_at=transaction_timestamp() where user_id=v_l.seller_id;
  insert into public.player_inventory(user_id,item_key,quantity,updated_at) values(v_uid,v_l.item_key,v_l.quantity,transaction_timestamp())
  on conflict(user_id,item_key) do update set quantity=public.player_inventory.quantity+excluded.quantity,updated_at=excluded.updated_at returning quantity into v_inv;
  update public.market_listings_v2 set status='sold',buyer_id=v_uid,sold_at=transaction_timestamp(),updated_at=transaction_timestamp() where listing_id=p_listing_id;
  v_resp:=jsonb_build_object('ok',true,'listing_id',p_listing_id,'coins',v_buyer.coins-v_total,'item_key',v_l.item_key,'inventory_quantity',v_inv);
  perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

create or replace function public.market_cancel_listing_v2(p_request_id uuid,p_listing_id bigint)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,auth as $$
declare v_uid uuid:=auth.uid(); v_req jsonb; v_l public.market_listings_v2%rowtype; v_inv bigint; v_resp jsonb;
begin
  if v_uid is null then raise exception using errcode='28000',message='Authentication required'; end if;
  v_req:=public.reserve_economy_request_v1(p_request_id,'market_cancel_listing_v2',jsonb_build_object('listing_id',p_listing_id));
  if (v_req->>'replay')::boolean then return v_req->'response'; end if;
  select * into v_l from public.market_listings_v2 where listing_id=p_listing_id for update;
  if not found or v_l.seller_id<>v_uid then raise exception using errcode='42501',message='Listing does not belong to this account'; end if;
  if v_l.status<>'open' then raise exception using errcode='55000',message='Listing is no longer open'; end if;
  update public.market_listings_v2 set status='cancelled',updated_at=transaction_timestamp() where listing_id=p_listing_id;
  insert into public.player_inventory(user_id,item_key,quantity,updated_at) values(v_uid,v_l.item_key,v_l.quantity,transaction_timestamp())
  on conflict(user_id,item_key) do update set quantity=public.player_inventory.quantity+excluded.quantity,updated_at=excluded.updated_at returning quantity into v_inv;
  v_resp:=jsonb_build_object('ok',true,'listing_id',p_listing_id,'item_key',v_l.item_key,'inventory_quantity',v_inv);
  perform public.finish_economy_request_v1(p_request_id,v_resp); return v_resp;
end; $$;

-- All mutating functions are callable only by authenticated users. They derive
-- user identity from auth.uid(); prices, grants, timings, and stock are server-owned.
do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('reserve_economy_request_v1','finish_economy_request_v1','materialize_processing_jobs_v1','update_visitor_progress_v1','canonical_level_bonus_v1')
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig); end loop;
end $$;
revoke all on function public.get_my_processing_v1() from public,anon,authenticated;
revoke all on function public.enqueue_processing_v1(uuid,text) from public,anon,authenticated;
revoke all on function public.sell_animal_v1(uuid,text) from public,anon,authenticated;
revoke all on function public.get_my_visitor_missions_v1() from public,anon,authenticated;
revoke all on function public.accept_visitor_missions_v1(uuid) from public,anon,authenticated;
revoke all on function public.claim_visitor_quest_v1(uuid,text) from public,anon,authenticated;
revoke all on function public.redeem_animal_voucher_v1(uuid,text) from public,anon,authenticated;
revoke all on function public.buy_farm_item_v1(uuid,text,text) from public,anon,authenticated;
revoke all on function public.set_my_cosmetic_v1(text,text,boolean) from public,anon,authenticated;
revoke all on function public.update_farm_decorations_v1(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.get_my_farm_cosmetics_v1() from public,anon,authenticated;
revoke all on function public.market_get_listings_v2() from public,anon,authenticated;
revoke all on function public.market_create_listing_v2(uuid,text,integer,bigint) from public,anon,authenticated;
revoke all on function public.market_buy_listing_v2(uuid,bigint) from public,anon,authenticated;
revoke all on function public.market_cancel_listing_v2(uuid,bigint) from public,anon,authenticated;
grant execute on function public.get_my_processing_v1() to authenticated;
grant execute on function public.enqueue_processing_v1(uuid,text) to authenticated;
grant execute on function public.sell_animal_v1(uuid,text) to authenticated;
grant execute on function public.get_my_visitor_missions_v1() to authenticated;
grant execute on function public.accept_visitor_missions_v1(uuid) to authenticated;
grant execute on function public.claim_visitor_quest_v1(uuid,text) to authenticated;
grant execute on function public.redeem_animal_voucher_v1(uuid,text) to authenticated;
grant execute on function public.buy_farm_item_v1(uuid,text,text) to authenticated;
grant execute on function public.set_my_cosmetic_v1(text,text,boolean) to authenticated;
grant execute on function public.update_farm_decorations_v1(uuid,jsonb) to authenticated;
grant execute on function public.get_my_farm_cosmetics_v1() to authenticated;
grant execute on function public.market_get_listings_v2() to authenticated;
grant execute on function public.market_create_listing_v2(uuid,text,integer,bigint) to authenticated;
grant execute on function public.market_buy_listing_v2(uuid,bigint) to authenticated;
grant execute on function public.market_cancel_listing_v2(uuid,bigint) to authenticated;

do $$ begin
  if to_regprocedure('public.market_get_listings(text)') is not null then execute 'revoke all on function public.market_get_listings(text) from public,anon,authenticated'; end if;
  if to_regprocedure('public.market_create_listing(text,integer,bigint)') is not null then execute 'revoke all on function public.market_create_listing(text,integer,bigint) from public,anon,authenticated'; end if;
  if to_regprocedure('public.market_buy_listing(bigint)') is not null then execute 'revoke all on function public.market_buy_listing(bigint) from public,anon,authenticated'; end if;
  if to_regprocedure('public.market_cancel_listing(bigint)') is not null then execute 'revoke all on function public.market_cancel_listing(bigint) from public,anon,authenticated'; end if;
end $$;

notify pgrst,'reload schema';
commit;
