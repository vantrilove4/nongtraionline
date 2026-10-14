-- Run in Supabase Dashboard > SQL Editor after creating public.game_saves.
-- Versioned RPC keeps the game from reading an older leaderboard column mapping.
-- Only a garden display name and public ranking stats are returned; no email,
-- auth user ID, or private save document is exposed.

drop function if exists public.get_game_leaderboard_v2(text, integer);

create function public.get_game_leaderboard_v2(
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
  with candidates as (
    select
      gs.user_id,
      coalesce(
        nullif(
          left(regexp_replace(btrim(coalesce(gs.save_data ->> 'gardenName', '')), '[[:cntrl:]]', '', 'g'), 24),
          ''
        ),
        'Nhà vườn ' || upper(substr(replace(gs.user_id::text, '-', ''), 1, 5))
      ) as display_name,
      case
        when gs.save_data ->> 'coins' ~ '^[0-9]{1,15}$'
          then least((gs.save_data ->> 'coins')::numeric, 999999999999)::bigint
        else 0::bigint
      end as coins,
      case
        when gs.save_data ->> 'xp' ~ '^[0-9]{1,15}([.][0-9]{1,2})?$'
          then least((gs.save_data ->> 'xp')::numeric, 999999999999::numeric)
        else 0::numeric
      end as xp
    from public.game_saves as gs
    where jsonb_typeof(gs.save_data) = 'object'
  ),
  stats as (
    select
      c.user_id,
      c.display_name,
      c.coins,
      c.xp,
      coalesce((
        select max(level_no)::integer
        from generate_series(1, 60) as levels(level_no)
        where c.xp >= 80::numeric * (level_no - 1)
          + 10::numeric * (level_no - 1) * (level_no - 2)
      ), 1) as level
    from candidates as c
  ),
  ranked as (
    select
      s.user_id,
      s.display_name,
      s.coins,
      s.xp,
      s.level,
      row_number() over (
        order by
          case when lower(coalesce(p_kind, 'level')) in ('gold', 'coins')
            then s.coins::numeric end desc nulls last,
          case when lower(coalesce(p_kind, 'level')) not in ('gold', 'coins')
            then s.level end desc nulls last,
          s.xp desc,
          s.coins desc,
          s.user_id
      ) as place
    from stats as s
  )
  select
    r.place as place,
    r.display_name as display_name,
    r.level::integer as level,
    r.coins::bigint as coins,
    r.xp::numeric as xp,
    coalesce(auth.uid() = r.user_id, false) as is_you
  from ranked as r
  where r.place <= greatest(1, least(coalesce(p_limit, 20), 100))
     or (auth.uid() is not null and r.user_id = auth.uid())
  order by r.place;
$$;

revoke all on function public.get_game_leaderboard_v2(text, integer) from public;
grant execute on function public.get_game_leaderboard_v2(text, integer) to anon, authenticated;
notify pgrst, 'reload schema';
