-- Remove the level-60 stop from already-installed server RPCs.
-- Run only after confirming migrations 003-014 were applied.
-- This changes server function definitions only; it does not alter player rows or save data.

begin;

do $$
declare
  v_fn record;
  v_definition text;
  v_changed integer := 0;
begin
  for v_fn in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as definition
    from pg_proc as p
    join pg_namespace as n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.proname in (
        'till_plot_v2', 'plant_crop_v2', 'harvest_crop_v2',
        'purchase_farm_item_internal_v2', 'buy_animal_v2', 'apply_animal_action_v2',
        'claim_daily_checkin_v2', 'get_my_daily_orders_v2', 'fulfill_daily_order_v2',
        'claim_weekly_quest_v2', 'refresh_my_achievements_internal_v2', 'claim_achievement_v2'
      )
      and p.prosrc like '% < 60 and %'
  loop
    v_definition := v_fn.definition;
    v_definition := replace(v_definition, 'v_level < 60 and ', '');
    v_definition := replace(v_definition, 'v_level_before < 60 and ', '');
    v_definition := replace(v_definition, 'v_level_after < 60 and ', '');
    if v_definition = v_fn.definition then
      raise exception 'Found level-capped RPC %, but no recognized level condition was replaced', v_fn.proname;
    end if;
    execute v_definition;
    v_changed := v_changed + 1;
  end loop;

  if v_changed = 0 then
    raise exception 'No level-capped RPC was found. Confirm migrations 003-014 are installed before running this migration.';
  end if;
end;
$$;

create or replace function public.get_game_leaderboard_v2(
  p_kind text default 'level',
  p_limit integer default 20
)
returns table (
  place bigint,
  display_name text,
  level integer,
  coins bigint,
  xp numeric,
  is_you boolean
)
language sql
stable
security definer
set search_path = pg_catalog, auth
as $$
  with item_values(item_key, value_xu, save_group) as (
    values
      ('carrot',18,'inv'),('tomato',33,'inv'),('potato',38,'inv'),
      ('corn',55,'inv'),('pumpkin',72,'inv'),('berry',78,'inv'),
      ('sunflower',96,'inv'),('watermelon',118,'inv'),('eggplant',145,'inv'),
      ('pineapple',180,'inv'),('grape',225,'inv'),('eggs',18,'inv'),
      ('milk',30,'inv'),('pork',52,'inv'),('fish',38,'inv'),
      ('berryYogurt',260,'inv'),('pumpkinPie',165,'inv'),
      ('fishStew',220,'inv'),('cornSausage',260,'inv'),
      ('carrot',8,'seeds'),('tomato',14,'seeds'),('potato',16,'seeds'),
      ('corn',22,'seeds'),('pumpkin',28,'seeds'),('berry',30,'seeds'),
      ('sunflower',36,'seeds'),('watermelon',42,'seeds'),('eggplant',50,'seeds'),
      ('pineapple',62,'seeds'),('grape',76,'seeds'),
      ('chicken',8,'feeds'),('pig',8,'feeds'),('cow',8,'feeds'),('fish',8,'feeds')
  ),
  animal_values(item_key, value_xu) as (
    values
      ('chicken_field',180),('chicken_silkie',320),('chicken_golden',480),
      ('chicken_special_scarf',980),('chicken_special_strawhat',1280),('chicken_special_amber',1680),
      ('pig_pink',400),('pig_cream',620),('pig_spotted',880),
      ('pig_special_flower',1450),('pig_special_sprout',1850),
      ('cow_dairy',700),('cow_brown',1080),('cow_golden',1560),
      ('cow_special_bell',2200),('cow_special_rosette',2800),('cow_special_bellcloud',3200),
      ('fish_pond',500),('fish_blue',780),('fish_koi',1160),
      ('fish_special_crown',1780),('fish_special_pearl',2300)
  ),
  candidates as (
    select
      gs.user_id,
      coalesce(
        nullif(left(regexp_replace(btrim(coalesce(gs.save_data ->> 'gardenName', '')), '[[:cntrl:]]', '', 'g'), 24), ''),
        'Nhà vườn ' || upper(substr(replace(gs.user_id::text, '-', ''), 1, 5))
      ) as display_name,
      case when gs.save_data ->> 'coins' ~ '^[0-9]{1,15}$'
        then least((gs.save_data ->> 'coins')::numeric, 999999999999)::numeric
        else 0::numeric end as wallet_coins,
      case when gs.save_data ->> 'xp' ~ '^[0-9]{1,15}([.][0-9]{1,2})?$'
        then least((gs.save_data ->> 'xp')::numeric, 999999999999::numeric)
        else 0::numeric end as xp,
      gs.save_data
    from public.game_saves as gs
    where jsonb_typeof(gs.save_data) = 'object'
  ),
  valued as (
    select
      c.user_id,
      c.display_name,
      c.xp,
      c.wallet_coins
        + coalesce((select sum(iv.value_xu::numeric * case when q.quantity ~ '^[0-9]{1,12}$' then q.quantity::numeric else 0 end)
          from jsonb_each_text(case when jsonb_typeof(c.save_data -> 'inv') = 'object' then c.save_data -> 'inv' else '{}'::jsonb end) as q(item_key, quantity)
          join item_values as iv on iv.save_group = 'inv' and iv.item_key = q.item_key
          where q.quantity ~ '^[0-9]{1,12}$'), 0)
        + coalesce((select sum(iv.value_xu::numeric * case when q.quantity ~ '^[0-9]{1,12}$' then q.quantity::numeric else 0 end)
          from jsonb_each_text(case when jsonb_typeof(c.save_data -> 'seeds') = 'object' then c.save_data -> 'seeds' else '{}'::jsonb end) as q(item_key, quantity)
          join item_values as iv on iv.save_group = 'seeds' and iv.item_key = q.item_key
          where q.quantity ~ '^[0-9]{1,12}$'), 0)
        + coalesce((select sum(iv.value_xu::numeric * case when q.quantity ~ '^[0-9]{1,12}$' then q.quantity::numeric else 0 end)
          from jsonb_each_text(case when jsonb_typeof(c.save_data -> 'feeds') = 'object' then c.save_data -> 'feeds' else '{}'::jsonb end) as q(item_key, quantity)
          join item_values as iv on iv.save_group = 'feeds' and iv.item_key = q.item_key
          where q.quantity ~ '^[0-9]{1,12}$'), 0)
        + coalesce((select sum(av.value_xu::numeric * case when q.quantity ~ '^[0-9]{1,12}$' then q.quantity::numeric else 0 end)
          from jsonb_each_text(case when jsonb_typeof(c.save_data -> 'animalBreeds') = 'object' then c.save_data -> 'animalBreeds' else '{}'::jsonb end) as q(item_key, quantity)
          join animal_values as av on av.item_key = q.item_key
          where q.quantity ~ '^[0-9]{1,12}$'), 0)
        as total_assets
    from candidates as c
  ),
  stats as (
    select
      v.user_id,
      v.display_name,
      least(v.total_assets, 999999999999)::bigint as total_assets,
      v.xp,
      greatest(1, floor((sqrt(4900::numeric + 40::numeric * v.xp) - 70::numeric) / 20::numeric) + 1)::integer as level
    from valued as v
  ),
  ranked as (
    select
      s.user_id,
      s.display_name,
      s.total_assets,
      s.xp,
      s.level,
      row_number() over (
        order by
          case when lower(coalesce(p_kind, 'level')) in ('gold', 'coins') then s.total_assets end desc nulls last,
          case when lower(coalesce(p_kind, 'level')) not in ('gold', 'coins') then s.level end desc nulls last,
          s.xp desc,
          s.total_assets desc,
          s.user_id
      ) as place
    from stats as s
  )
  select
    r.place,
    r.display_name,
    r.level,
    r.total_assets as coins,
    r.xp,
    coalesce(auth.uid() = r.user_id, false) as is_you
  from ranked as r
  where r.place <= greatest(1, least(coalesce(p_limit, 20), 100))
     or (auth.uid() is not null and r.user_id = auth.uid())
  order by r.place;
$$;

revoke all on function public.get_game_leaderboard_v2(text, integer) from public;
grant execute on function public.get_game_leaderboard_v2(text, integer) to anon, authenticated;
notify pgrst, 'reload schema';


commit;

-- Read-only postflight: this should return no rows.
select n.nspname as schema_name, p.proname as routine_name
from pg_proc as p
join pg_namespace as n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prokind = 'f'
  and p.proname in (
    'till_plot_v2', 'plant_crop_v2', 'harvest_crop_v2',
    'purchase_farm_item_internal_v2', 'buy_animal_v2', 'apply_animal_action_v2',
    'claim_daily_checkin_v2', 'get_my_daily_orders_v2', 'fulfill_daily_order_v2',
    'claim_weekly_quest_v2', 'refresh_my_achievements_internal_v2', 'claim_achievement_v2'
  )
  and p.prosrc like '% < 60 and %';
