-- Vườn Nhỏ: shared, server-enforced game configuration.
-- Re-run this full file in Supabase SQL Editor to install or update the configuration schema.

create table if not exists public.game_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.game_admins enable row level security;
revoke all privileges on table public.game_admins from public, anon, authenticated;

create table if not exists public.game_global_config (
  id smallint primary key check (id = 1),
  config jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

alter table public.game_global_config enable row level security;
revoke all privileges on table public.game_global_config from public, anon, authenticated;

insert into public.game_global_config (id, config)
values (1, jsonb_build_object(
  'cropTimeMultiplier', 1,
  'animalTimeMultiplier', 1,
  'sellMultiplier', 1,
  'xpMultiplier', 1,
  'feedPrice', 8,
  'announcement', '',
  'cropHarvestSeconds', jsonb_build_object('carrot',300,'tomato',420,'potato',480,'corn',540,'pumpkin',660,'berry',600,'sunflower',720,'watermelon',780,'eggplant',840,'pineapple',900,'grape',960),
  'cropSellPrices', jsonb_build_object('carrot',18,'tomato',33,'potato',38,'corn',55,'pumpkin',72,'berry',78,'sunflower',96,'watermelon',118,'eggplant',145,'pineapple',180,'grape',225),
  'animalHarvestSeconds', jsonb_build_object('chicken',300,'pig',420,'cow',360,'fish',360),
  'animalSellPrices', jsonb_build_object('eggs',18,'milk',30,'pork',52,'fish',38)
))
on conflict (id) do nothing;

-- Add per-item settings to a project that already has the earlier global-only config.
update public.game_global_config as c
set config = c.config || jsonb_build_object(
  'cropHarvestSeconds', coalesce(c.config->'cropHarvestSeconds', jsonb_build_object('carrot',300,'tomato',420,'potato',480,'corn',540,'pumpkin',660,'berry',600,'sunflower',720,'watermelon',780,'eggplant',840,'pineapple',900,'grape',960)),
  'cropSellPrices', coalesce(c.config->'cropSellPrices', jsonb_build_object('carrot',18,'tomato',33,'potato',38,'corn',55,'pumpkin',72,'berry',78,'sunflower',96,'watermelon',118,'eggplant',145,'pineapple',180,'grape',225)),
  'animalHarvestSeconds', coalesce(c.config->'animalHarvestSeconds', jsonb_build_object('chicken',300,'pig',420,'cow',360,'fish',360)),
  'animalSellPrices', coalesce(c.config->'animalSellPrices', jsonb_build_object('eggs',18,'milk',30,'pork',52,'fish',38))
)
where c.id = 1;

create or replace function public.get_game_global_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select c.config || jsonb_build_object('updated_at', c.updated_at)
  from public.game_global_config as c
  where c.id = 1;
$$;

create or replace function public.is_game_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.game_admins as a where a.user_id = auth.uid()
  );
$$;

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

  if exists (select 1 from jsonb_each_text(v_crop_times) as e(key,value) where e.value::numeric < 60 or e.value::numeric > 86400 or trunc(e.value::numeric) <> e.value::numeric)
     or exists (select 1 from jsonb_each_text(v_animal_times) as e(key,value) where e.value::numeric < 60 or e.value::numeric > 86400 or trunc(e.value::numeric) <> e.value::numeric) then
    raise exception 'Thời gian thu hoạch phải là số nguyên từ 60 đến 86400 giây.' using errcode = '22023';
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

revoke all on function public.get_game_global_config() from public, anon, authenticated;
revoke all on function public.is_game_admin() from public, anon, authenticated;
revoke all on function public.save_game_global_config(jsonb) from public, anon, authenticated;
grant usage on schema public to anon, authenticated;
grant execute on function public.get_game_global_config() to anon, authenticated;
grant execute on function public.is_game_admin() to authenticated;
grant execute on function public.save_game_global_config(jsonb) to authenticated;

-- Bootstrap the first admin only after that person has registered in the game.
-- Run this in Supabase SQL Editor if the admin account has not already been added:
-- insert into public.game_admins (user_id)
-- select id from auth.users where lower(email) = lower('nvantri93@gmail.com')
-- on conflict (user_id) do nothing;
