-- Chợ giao dịch giữa người chơi Vườn Nhỏ.
-- Chạy một lần trong Supabase Dashboard > SQL Editor.
-- Giao dịch được thực hiện qua RPC để khóa save và cập nhật hai bên nguyên tử.

create table if not exists public.market_listings (
  id bigint generated always as identity primary key,
  seller_id uuid not null references auth.users (id) on delete cascade,
  item_key text not null check (item_key in (
    'carrot','tomato','potato','corn','pumpkin','berry','sunflower',
    'watermelon','eggplant','pineapple','grape',
    'eggs','milk','pork','fish',
    'berryYogurt','pumpkinPie','fishStew','cornSausage'
  )),
  quantity integer not null check (quantity between 1 and 999),
  price_each bigint not null check (price_each between 1 and 1000000000),
  status text not null default 'active' check (status in ('active','sold','cancelled')),
  buyer_id uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

create index if not exists market_listings_active_created_idx
  on public.market_listings (created_at desc) where status = 'active';
create index if not exists market_listings_seller_active_idx
  on public.market_listings (seller_id, created_at desc) where status = 'active';

alter table public.market_listings enable row level security;
revoke all on table public.market_listings from anon, authenticated;
revoke all on sequence public.market_listings_id_seq from anon, authenticated;

create or replace function public.market_get_listings(p_scope text default 'all')
returns table (
  id bigint,
  item_key text,
  quantity integer,
  price_each bigint,
  created_at timestamptz,
  seller_name text,
  is_mine boolean
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Hãy đăng nhập để vào chợ.'; end if;
  return query
    select l.id, l.item_key, l.quantity, l.price_each, l.created_at,
      coalesce(nullif(left(regexp_replace(btrim(coalesce(gs.save_data ->> 'gardenName','')), '[[:cntrl:]]', '', 'g'), 24), ''), 'Nhà vườn') as seller_name,
      l.seller_id = v_uid as is_mine
    from public.market_listings l
    left join public.game_saves gs on gs.user_id = l.seller_id
    where l.status = 'active'
      and (coalesce(p_scope,'all') <> 'mine' or l.seller_id = v_uid)
    order by l.created_at desc, l.id desc
    limit 200;
end;
$$;

create or replace function public.market_create_listing(
  p_item_key text,
  p_quantity integer,
  p_price_each bigint
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_save jsonb;
  v_inv jsonb;
  v_have bigint;
  v_listing_id bigint;
begin
  if v_uid is null then raise exception 'Hãy đăng nhập để đăng bán.'; end if;
  if p_item_key is null or p_item_key not in ('carrot','tomato','potato','corn','pumpkin','berry','sunflower','watermelon','eggplant','pineapple','grape','eggs','milk','pork','fish','berryYogurt','pumpkinPie','fishStew','cornSausage') then
    raise exception 'Vật phẩm này không được phép giao dịch.';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 999 then raise exception 'Số lượng phải từ 1 đến 999.'; end if;
  if p_price_each is null or p_price_each < 1 or p_price_each > 1000000000 then raise exception 'Giá mỗi món phải từ 1 đến 1.000.000.000 xu.'; end if;

  select save_data into v_save from public.game_saves where user_id = v_uid for update;
  if v_save is null then raise exception 'Chưa tìm thấy nông trại trên cloud. Hãy đồng bộ tài khoản rồi thử lại.'; end if;
  v_inv := coalesce(v_save -> 'inv', '{}'::jsonb);
  if coalesce(v_inv ->> p_item_key, '0') !~ '^[0-9]{1,12}$' then raise exception 'Kho vật phẩm không hợp lệ.'; end if;
  v_have := (v_inv ->> p_item_key)::bigint;
  if v_have < p_quantity then raise exception 'Bạn không có đủ vật phẩm trong kho.'; end if;

  v_inv := jsonb_set(v_inv, array[p_item_key], to_jsonb(v_have - p_quantity), true);
  v_save := jsonb_set(v_save, '{inv}', v_inv, true);
  update public.game_saves set save_data = v_save, updated_at = now() where user_id = v_uid;
  insert into public.market_listings (seller_id, item_key, quantity, price_each)
    values (v_uid, p_item_key, p_quantity, p_price_each)
    returning id into v_listing_id;
  return v_listing_id;
end;
$$;

create or replace function public.market_buy_listing(p_listing_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.market_listings%rowtype;
  v_buyer jsonb;
  v_seller jsonb;
  v_buyer_inv jsonb;
  v_seller_inv jsonb;
  v_coins bigint;
  v_seller_coins bigint;
  v_item_count bigint;
  v_total numeric;
begin
  if v_uid is null then raise exception 'Hãy đăng nhập để mua.'; end if;
  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found or v_listing.status <> 'active' then raise exception 'Tin bán này không còn khả dụng.'; end if;
  if v_listing.seller_id = v_uid then raise exception 'Bạn không thể tự mua tin của mình.'; end if;
  v_total := v_listing.quantity::numeric * v_listing.price_each::numeric;

  perform 1 from public.game_saves
    where user_id in (v_uid, v_listing.seller_id)
    order by user_id for update;
  select save_data into v_buyer from public.game_saves where user_id = v_uid;
  select save_data into v_seller from public.game_saves where user_id = v_listing.seller_id;
  if v_buyer is null or v_seller is null then raise exception 'Không tìm thấy save cloud của người mua hoặc người bán.'; end if;
  if coalesce(v_buyer ->> 'coins','0') !~ '^[0-9]{1,15}$' then raise exception 'Số xu của bạn không hợp lệ.'; end if;
  if coalesce(v_seller ->> 'coins','0') !~ '^[0-9]{1,15}$' then raise exception 'Số xu người bán không hợp lệ.'; end if;
  v_coins := (v_buyer ->> 'coins')::bigint;
  v_seller_coins := (v_seller ->> 'coins')::bigint;
  if v_coins < v_total then raise exception 'Bạn không đủ xu cho giao dịch này.'; end if;
  v_buyer_inv := coalesce(v_buyer -> 'inv', '{}'::jsonb);
  v_seller_inv := coalesce(v_seller -> 'inv', '{}'::jsonb);
  if coalesce(v_buyer_inv ->> v_listing.item_key,'0') !~ '^[0-9]{1,12}$'
    or coalesce(v_seller_inv ->> v_listing.item_key,'0') !~ '^[0-9]{1,12}$' then
    raise exception 'Kho vật phẩm không hợp lệ.';
  end if;
  v_item_count := (v_buyer_inv ->> v_listing.item_key)::bigint;
  v_buyer_inv := jsonb_set(v_buyer_inv, array[v_listing.item_key], to_jsonb(v_item_count + v_listing.quantity), true);
  v_buyer := jsonb_set(v_buyer, '{inv}', v_buyer_inv, true);
  v_buyer := jsonb_set(v_buyer, '{coins}', to_jsonb(v_coins - v_total), true);
  v_seller := jsonb_set(v_seller, '{coins}', to_jsonb(v_seller_coins + v_total), true);
  update public.game_saves set save_data = v_buyer, updated_at = now() where user_id = v_uid;
  update public.game_saves set save_data = v_seller, updated_at = now() where user_id = v_listing.seller_id;
  update public.market_listings set status = 'sold', buyer_id = v_uid, closed_at = now() where id = v_listing.id;
  return jsonb_build_object('coins', v_coins - v_total, 'inv', v_buyer_inv);
end;
$$;

create or replace function public.market_cancel_listing(p_listing_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_listing public.market_listings%rowtype;
  v_save jsonb;
  v_inv jsonb;
  v_have bigint;
begin
  if v_uid is null then raise exception 'Hãy đăng nhập để gỡ tin.'; end if;
  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found or v_listing.status <> 'active' then raise exception 'Tin bán này không còn khả dụng.'; end if;
  if v_listing.seller_id <> v_uid then raise exception 'Bạn chỉ có thể gỡ tin của mình.'; end if;
  select save_data into v_save from public.game_saves where user_id = v_uid for update;
  if v_save is null then raise exception 'Không tìm thấy save cloud.'; end if;
  v_inv := coalesce(v_save -> 'inv', '{}'::jsonb);
  if coalesce(v_inv ->> v_listing.item_key,'0') !~ '^[0-9]{1,12}$' then raise exception 'Kho vật phẩm không hợp lệ.'; end if;
  v_have := (v_inv ->> v_listing.item_key)::bigint;
  v_inv := jsonb_set(v_inv, array[v_listing.item_key], to_jsonb(v_have + v_listing.quantity), true);
  v_save := jsonb_set(v_save, '{inv}', v_inv, true);
  update public.game_saves set save_data = v_save, updated_at = now() where user_id = v_uid;
  update public.market_listings set status = 'cancelled', closed_at = now() where id = v_listing.id;
  return jsonb_build_object('coins', (v_save ->> 'coins')::bigint, 'inv', v_inv);
end;
$$;

revoke all on function public.market_get_listings(text) from public;
revoke all on function public.market_create_listing(text, integer, bigint) from public;
revoke all on function public.market_buy_listing(bigint) from public;
revoke all on function public.market_cancel_listing(bigint) from public;
grant execute on function public.market_get_listings(text) to authenticated;
grant execute on function public.market_create_listing(text, integer, bigint) to authenticated;
grant execute on function public.market_buy_listing(bigint) to authenticated;
grant execute on function public.market_cancel_listing(bigint) to authenticated;

notify pgrst, 'reload schema';
