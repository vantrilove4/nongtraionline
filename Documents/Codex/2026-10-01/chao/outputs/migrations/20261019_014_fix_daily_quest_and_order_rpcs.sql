-- Fixes two issues reported from the deployed web UI:
-- 1) PL/pgSQL output column period_date conflicts with an unqualified
--    ON CONFLICT target in get_my_daily_quests_v2.
-- 2) Older/incomplete admin config JSON may omit a per-item order price.
-- Uses per-item config when present, with the same game defaults as the web UI.

begin;

create or replace function public.get_my_daily_quests_v2()
returns table (
  period_date date,
  quest_id text,
  action_type text,
  title text,
  progress integer,
  target integer,
  reward_coins bigint,
  reward_xp bigint,
  claimed_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_period_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;

  insert into public.player_daily_quests
    (user_id, period_date, quest_id, progress, target, reward_coins, reward_xp)
  select v_uid, v_period_date, c.quest_id, 0, c.target, c.reward_coins, c.reward_xp
  from public.daily_quest_catalog as c
  where c.enabled
  on conflict on constraint player_daily_quests_pkey do nothing;

  return query
  select q.period_date, q.quest_id, c.action_type, c.title,
         q.progress, q.target, q.reward_coins, q.reward_xp, q.claimed_at
  from public.player_daily_quests as q
  join public.daily_quest_catalog as c using (quest_id)
  where q.user_id = v_uid and q.period_date = v_period_date
  order by q.quest_id;
end;
$$;

create or replace function public.get_my_daily_orders_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
  v_wallet public.player_wallets%rowtype;
  v_config jsonb;
  v_level integer := 1;
  v_slot integer;
  v_template public.daily_order_catalog_v2%rowtype;
  v_price numeric;
  v_reward_coins bigint;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical wallet is not initialized';
  end if;
  select config into v_config from public.game_global_config where id = 1;
  if v_config is null then
    raise exception using errcode = '55000', message = 'Server game configuration is unavailable';
  end if;
  while v_level < 60 and v_wallet.xp >=
    (80 * v_level + 10 * v_level * (v_level - 1)) loop
    v_level := v_level + 1;
  end loop;

  for v_slot in 1..3 loop
    if exists (select 1 from public.player_daily_orders_v2 as existing_order
      where existing_order.user_id = v_uid
        and existing_order.order_date = v_date
        and existing_order.slot_no = v_slot) then
      continue;
    end if;
    select c.* into v_template
    from public.daily_order_catalog_v2 as c
    where c.enabled and c.unlock_level <= v_level
      and not exists (
        select 1 from public.player_daily_orders_v2 as existing_item
        where existing_item.user_id = v_uid
          and existing_item.order_date = v_date
          and existing_item.item_key = c.item_key
      )
    order by md5(v_uid::text || v_date::text || v_slot::text || c.template_id)
    limit 1;
    if not found then
      raise exception using errcode = '55000', message = 'Not enough daily order templates for this level';
    end if;

    if v_template.item_key in ('eggs', 'milk', 'pork', 'fish') then
      v_price := coalesce(
        nullif(v_config->'animalSellPrices'->>v_template.item_key, '')::numeric,
        case v_template.item_key when 'eggs' then 18 when 'milk' then 30
          when 'pork' then 52 when 'fish' then 38 end);
    else
      v_price := coalesce(
        nullif(v_config->'cropSellPrices'->>v_template.item_key, '')::numeric,
        case v_template.item_key
          when 'carrot' then 18 when 'tomato' then 33 when 'potato' then 38
          when 'corn' then 55 when 'pumpkin' then 72 when 'berry' then 78
          when 'sunflower' then 96 when 'watermelon' then 118
          when 'eggplant' then 145 when 'pineapple' then 180 when 'grape' then 225
        end);
    end if;
    if v_price is null or v_price <= 0 then
      raise exception using errcode = '55000', message = 'Order item has no configured or default price';
    end if;
    v_reward_coins := greatest(0, round(v_price * v_template.quantity_requested
      * v_template.coin_factor * coalesce((v_config->>'sellMultiplier')::numeric, 1)))::bigint;
    insert into public.player_daily_orders_v2
      (user_id, order_date, slot_no, template_id, item_key,
       quantity_requested, reward_coins, reward_xp)
    values (v_uid, v_date, v_slot, v_template.template_id, v_template.item_key,
      v_template.quantity_requested, v_reward_coins,
      greatest(0, round(v_template.reward_xp * coalesce((v_config->>'xpMultiplier')::numeric, 1)))::bigint);
  end loop;

  return jsonb_build_object('ok', true, 'order_date', v_date, 'orders',
    coalesce((select jsonb_agg(jsonb_build_object(
      'slot', o.slot_no, 'item_key', o.item_key, 'quantity', o.quantity_requested,
      'reward_coins', o.reward_coins, 'reward_xp', o.reward_xp, 'status', o.status,
      'fulfilled_at', o.fulfilled_at
    ) order by o.slot_no)
    from public.player_daily_orders_v2 as o
    where o.user_id = v_uid and o.order_date = v_date), '[]'::jsonb));
end;
$$;

revoke all on function public.get_my_daily_quests_v2() from public, anon, authenticated;
grant execute on function public.get_my_daily_quests_v2() to authenticated;
revoke all on function public.get_my_daily_orders_v2() from public, anon, authenticated;
grant execute on function public.get_my_daily_orders_v2() to authenticated;

comment on function public.get_my_daily_quests_v2() is
  'Returns/initializes the authenticated user daily quest rows; uses the named primary-key constraint to avoid output-column ambiguity.';
comment on function public.get_my_daily_orders_v2() is
  'Creates deterministic daily orders using configured prices when present and the canonical game defaults for omitted item prices.';

commit;
