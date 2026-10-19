-- Phase 2 hardening: use the same wallet-before-quest lock order as gameplay RPCs.
-- Migration 002 has already been applied in staging; this follow-up replaces its function.
-- Draft only. Do not execute until reviewed and approved.

begin;

create or replace function public.claim_daily_quest_v2(p_request_id uuid, p_quest_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := transaction_timestamp();
  v_period_date date := timezone('Asia/Ho_Chi_Minh', transaction_timestamp())::date;
  v_payload jsonb;
  v_payload_hash text;
  v_request public.economy_requests%rowtype;
  v_wallet public.player_wallets%rowtype;
  v_quest public.player_daily_quests%rowtype;
  v_response jsonb;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if p_request_id is null or p_quest_id is null then
    raise exception using errcode = '22023', message = 'Request id and quest id are required';
  end if;

  v_payload := jsonb_build_object(
    'operation', 'claim_daily_quest_v2',
    'quest_id', p_quest_id
  );
  v_payload_hash := encode(sha256(convert_to(v_payload::text, 'UTF8')), 'hex');
  insert into public.economy_requests
    (user_id, request_id, operation_type, payload_hash)
  values (v_uid, p_request_id, 'claim_daily_quest_v2', v_payload_hash)
  on conflict (user_id, request_id) do nothing;
  select * into v_request from public.economy_requests
  where user_id = v_uid and request_id = p_request_id for update;
  if not found then
    raise exception using errcode = '55000', message = 'Could not establish idempotency record';
  end if;
  if v_request.operation_type <> 'claim_daily_quest_v2'
     or v_request.payload_hash <> v_payload_hash then
    raise exception using errcode = '22023', message = 'Request id was already used for a different operation';
  end if;
  if v_request.response is not null then return v_request.response; end if;
  if v_request.completed_at is not null then
    raise exception using errcode = '55000', message = 'Stored request result is inconsistent';
  end if;

  -- Match gameplay order: request -> wallet -> quest. This avoids wallet/quest deadlocks.
  select * into v_wallet from public.player_wallets where user_id = v_uid for update;
  if not found then
    raise exception using errcode = '55000', message = 'Canonical player wallet is not initialized';
  end if;
  insert into public.player_daily_quests
    (user_id, period_date, quest_id, progress, target, reward_coins, reward_xp)
  select v_uid, v_period_date, c.quest_id, 0, c.target, c.reward_coins, c.reward_xp
  from public.daily_quest_catalog c where c.enabled
  on conflict (user_id, period_date, quest_id) do nothing;

  select * into v_quest from public.player_daily_quests
  where user_id = v_uid and period_date = v_period_date and quest_id = p_quest_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'Unknown daily quest';
  end if;
  if v_quest.claimed_at is not null then
    v_response := jsonb_build_object('ok', true, 'already_claimed', true,
      'period_date', v_period_date, 'quest_id', p_quest_id,
      'coins_awarded', v_quest.reward_coins, 'xp_awarded', v_quest.reward_xp,
      'claimed_at', v_quest.claimed_at);
    update public.economy_requests set response = v_response, completed_at = v_now
    where user_id = v_uid and request_id = p_request_id;
    return v_response;
  end if;
  if v_quest.progress < v_quest.target then
    raise exception using errcode = '55000', message = 'Daily quest is not complete';
  end if;

  update public.player_wallets
  set coins = coins + v_quest.reward_coins,
      xp = xp + v_quest.reward_xp,
      updated_at = v_now
  where user_id = v_uid;
  v_response := jsonb_build_object(
    'ok', true, 'already_claimed', false, 'period_date', v_period_date,
    'quest_id', p_quest_id, 'coins_awarded', v_quest.reward_coins,
    'xp_awarded', v_quest.reward_xp, 'claimed_at', v_now
  );
  insert into public.reward_claims
    (user_id, reward_kind, period_key, source_id, request_id, response, created_at)
  values (v_uid, 'daily_quest', to_char(v_period_date, 'YYYY-MM-DD'),
    p_quest_id, p_request_id, v_response, v_now);
  update public.player_daily_quests
  set claimed_at = v_now, updated_at = v_now
  where user_id = v_uid and period_date = v_period_date and quest_id = p_quest_id;
  update public.economy_requests set response = v_response, completed_at = v_now
  where user_id = v_uid and request_id = p_request_id;
  return v_response;
end;
$$;

revoke all on function public.claim_daily_quest_v2(uuid, text) from public, anon, authenticated;
grant execute on function public.claim_daily_quest_v2(uuid, text) to authenticated;
comment on function public.claim_daily_quest_v2(uuid, text) is
  'Atomically claims the authenticated user daily quest for the HCM server date. Locks request then wallet then quest to match gameplay RPC lock order.';

commit;
