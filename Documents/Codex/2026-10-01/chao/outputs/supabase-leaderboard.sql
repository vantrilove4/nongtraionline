-- Apply the matching migration from outputs/migrations/20261112_025_canonical_leaderboard_v3.sql.
-- This standalone copy is kept in sync for convenience.
begin;

-- Canonical leaderboard: rank only values confirmed in server-owned player tables.
-- game_saves is consulted only for the garden display name, never for score data.
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
  with item_values(item_key, value_xu) as (
    values
      ('carrot',18),('tomato',33),('potato',38),('corn',55),('pumpkin',72),
      ('berry',78),('sunflower',96),('watermelon',118),('eggplant',145),
      ('pineapple',180),('grape',225),('rice',36),
      ('eggs',18),('milk',30),('pork',52),('fish',38),
      ('orange_fruit',18),('mango_fruit',30),('guava_fruit',24),('lychee_fruit',42),
      ('berry_yogurt',260),('pumpkin_pie',165),('fish_stew',220),('corn_sausage',260),
      ('seed_carrot',8),('seed_tomato',14),('seed_potato',16),('seed_corn',22),
      ('seed_pumpkin',28),('seed_berry',30),('seed_sunflower',36),('seed_watermelon',42),
      ('seed_eggplant',50),('seed_pineapple',62),('seed_grape',76),('seed_rice',18),
      ('feed_chicken',8),('feed_pig',8),('feed_cow',8),('feed_fish',8),
      ('decor_shrub',30),('decor_lamp',50),('decor_flower',35),
      ('decor_cottage',140),('decor_scarecrow',90)
  ),
  candidates as (
    select
      w.user_id,
      coalesce(
        nullif(left(regexp_replace(btrim(coalesce(gs.save_data ->> 'gardenName', '')), '[[:cntrl:]]', '', 'g'), 24), ''),
        'Nhà vườn'
      ) as display_name,
      w.coins::numeric as wallet_coins,
      w.xp::numeric as xp,
      coalesce(f.farm_state, '{}'::jsonb) as farm_state
    from public.player_wallets as w
    left join public.game_saves as gs on gs.user_id = w.user_id
    left join public.player_farm_state as f on f.user_id = w.user_id
  ),
  valued as (
    select
      c.user_id,
      c.display_name,
      c.xp,
      c.wallet_coins
        + coalesce((
          select sum(i.quantity::numeric * iv.value_xu::numeric)
          from public.player_inventory as i
          join item_values as iv on iv.item_key = i.item_key
          where i.user_id = c.user_id
        ), 0)
        + coalesce((
          select sum(
            case when variant.quantity ~ '^[0-9]{1,12}$' then variant.quantity::numeric else 0 end
            * catalog.price::numeric
          )
          from jsonb_each(
            case when jsonb_typeof(c.farm_state -> 'animals') = 'object'
              then c.farm_state -> 'animals' else '{}'::jsonb end
          ) as animal(animal_key, animal_data)
          cross join lateral jsonb_each_text(
            case when jsonb_typeof(animal.animal_data -> 'variants') = 'object'
              then animal.animal_data -> 'variants' else '{}'::jsonb end
          ) as variant(variant_id, quantity)
          join public.animal_variant_catalog_v2 as catalog
            on catalog.variant_id = variant.variant_id
           and catalog.animal_key = animal.animal_key
          where variant.quantity ~ '^[0-9]{1,12}$'
        ), 0)
        + coalesce((
          select sum(case tree.species when 'orange' then 250 when 'mango' then 440 when 'guava' then 340 when 'lychee' then 680 else 0 end)::numeric
          from public.player_orchard_trees as tree
          where tree.user_id = c.user_id
        ), 0)
        + coalesce((
          select sum(case decoration.value ->> 'type'
            when 'shrub' then 30 when 'lamp' then 50 when 'flower' then 35
            when 'cottage' then 140 when 'scarecrow' then 90 else 0 end)::numeric
          from jsonb_array_elements(
            case when jsonb_typeof(c.farm_state -> 'decorations') = 'array'
              then c.farm_state -> 'decorations' else '[]'::jsonb end
          ) as decoration(value)
        ), 0)
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

revoke all on function public.get_game_leaderboard_v2(text, integer) from public, anon, authenticated;
grant execute on function public.get_game_leaderboard_v2(text, integer) to anon, authenticated;
notify pgrst, 'reload schema';

commit;
