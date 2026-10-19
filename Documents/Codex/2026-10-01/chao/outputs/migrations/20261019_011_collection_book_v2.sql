-- Phase 2, server-verified collection book (dark launch).
-- Draft only; do not execute until reviewed and approved.
-- Depends on migrations 001, 003, 006 and canonical RPC request logging.
-- Does not read, update, convert, or reward legacy s.collections.

begin;

create table public.collection_catalog_v2 (
  collection_id text primary key check (collection_id ~ '^[a-z][a-z0-9_]{0,63}$'),
  category text not null check (category in ('crop','animal','product')),
  item_key text not null check (item_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  display_name text not null,
  activated_at timestamptz not null default transaction_timestamp(),
  enabled boolean not null default true,
  unique (category, item_key)
);

insert into public.collection_catalog_v2
  (collection_id, category, item_key, display_name)
values
  ('crop_carrot','crop','carrot','Cà rốt'),
  ('crop_tomato','crop','tomato','Cà chua'),
  ('crop_potato','crop','potato','Khoai tây'),
  ('crop_corn','crop','corn','Bắp ngô'),
  ('crop_pumpkin','crop','pumpkin','Bí đỏ'),
  ('crop_berry','crop','berry','Dâu tây'),
  ('crop_sunflower','crop','sunflower','Hoa hướng dương'),
  ('crop_watermelon','crop','watermelon','Dưa hấu'),
  ('crop_eggplant','crop','eggplant','Cà tím'),
  ('crop_pineapple','crop','pineapple','Thơm'),
  ('crop_grape','crop','grape','Nho'),
  ('product_eggs','product','eggs','Trứng gà'),
  ('product_milk','product','milk','Sữa bò'),
  ('product_pork','product','pork','Thịt heo'),
  ('product_fish','product','fish','Cá');

insert into public.collection_catalog_v2 (collection_id, category, item_key, display_name)
select 'animal_' || variant_id, 'animal', variant_id, display_name
from public.animal_variant_catalog_v2;

create table public.player_collections_v2 (
  user_id uuid not null references auth.users (id) on delete restrict,
  collection_id text not null references public.collection_catalog_v2 (collection_id) on delete restrict,
  discovered_at timestamptz not null,
  source_request_id uuid not null,
  created_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, collection_id),
  foreign key (user_id, source_request_id)
    references public.economy_requests (user_id, request_id) on delete restrict
);

create index player_collections_user_idx
  on public.player_collections_v2 (user_id, collection_id);

alter table public.collection_catalog_v2 enable row level security;
alter table public.player_collections_v2 enable row level security;
revoke all on table public.collection_catalog_v2 from public, anon, authenticated;
revoke all on table public.player_collections_v2 from public, anon, authenticated;
grant select on table public.player_collections_v2 to authenticated;
create policy player_collections_read_own_v2
  on public.player_collections_v2 for select to authenticated
  using ((select auth.uid()) = user_id);

create function public.refresh_my_collection_internal_v2()
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  insert into public.player_collections_v2
    (user_id, collection_id, discovered_at, source_request_id)
  select distinct on (c.collection_id)
    v_uid, c.collection_id, r.completed_at, r.request_id
  from public.collection_catalog_v2 c
  join public.economy_requests r on r.user_id = v_uid
  where c.enabled and r.completed_at is not null and r.completed_at >= c.activated_at
    and r.response->>'ok' = 'true'
    and (
      (c.category = 'crop' and r.operation_type = 'harvest_crop_v2'
        and r.response->>'crop_key' = c.item_key)
      or (c.category = 'animal' and r.operation_type = 'buy_animal_v2'
        and r.response->>'variant_id' = c.item_key)
      or (c.category = 'product' and r.operation_type = 'collect_animal_v2'
        and r.response->>'product_key' = c.item_key)
    )
  order by c.collection_id, r.completed_at, r.request_id
  on conflict (user_id, collection_id) do nothing;
end;
$$;

create function public.get_my_collection_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_wallet public.player_wallets%rowtype;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  perform public.refresh_my_collection_internal_v2();
  return jsonb_build_object('ok', true, 'collections', coalesce((
    select jsonb_agg(jsonb_build_object(
      'collection_id', c.collection_id, 'category', c.category,
      'item_key', c.item_key, 'display_name', c.display_name,
      'discovered', p.collection_id is not null, 'discovered_at', p.discovered_at
    ) order by case c.category when 'crop' then 1 when 'animal' then 2 else 3 end,
      c.display_name)
    from public.collection_catalog_v2 c
    left join public.player_collections_v2 p
      on p.user_id = v_uid and p.collection_id = c.collection_id
    where c.enabled
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.refresh_my_collection_internal_v2() from public, anon, authenticated;
revoke all on function public.get_my_collection_v2() from public, anon, authenticated;
grant execute on function public.get_my_collection_v2() to authenticated;

comment on table public.player_collections_v2 is
  'New collection discoveries backed by post-activation successful server RPC events only; never imported from legacy s.collections.';
comment on function public.get_my_collection_v2() is
  'Returns the authenticated user collection book using successful post-activation server requests, without rewards or legacy save conversion.';

commit;
