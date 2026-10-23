-- Vườn Nhỏ: one authenticated global chat room.
-- Additive migration. Review and run on staging first; this file is not run here.
-- Does not modify game_saves or any gameplay/economy tables.

begin;

create table public.global_chat_profiles_v1 (
  user_id uuid primary key references auth.users (id) on delete cascade,
  public_id uuid not null unique default gen_random_uuid(),
  display_name text not null check (char_length(btrim(display_name)) between 2 and 24),
  muted_until timestamptz,
  created_at timestamptz not null default transaction_timestamp(),
  updated_at timestamptz not null default transaction_timestamp()
);

create table public.global_chat_messages_v1 (
  id bigint generated always as identity primary key,
  sender_id uuid not null references public.global_chat_profiles_v1 (user_id) on delete cascade,
  request_id uuid not null,
  body text not null check (char_length(btrim(body)) between 1 and 300),
  created_at timestamptz not null default transaction_timestamp(),
  hidden_at timestamptz,
  unique (sender_id, request_id)
);

create index global_chat_messages_created_idx
  on public.global_chat_messages_v1 (id desc, created_at desc);
create index global_chat_messages_sender_created_idx
  on public.global_chat_messages_v1 (sender_id, created_at desc);

create table public.global_chat_blocks_v1 (
  user_id uuid not null references public.global_chat_profiles_v1 (user_id) on delete cascade,
  blocked_public_id uuid not null references public.global_chat_profiles_v1 (public_id) on delete cascade,
  created_at timestamptz not null default transaction_timestamp(),
  primary key (user_id, blocked_public_id)
);

create table public.global_chat_reports_v1 (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references auth.users (id) on delete cascade,
  message_id bigint references public.global_chat_messages_v1 (id) on delete set null,
  reported_public_id uuid not null,
  message_snapshot text not null check (char_length(message_snapshot) between 1 and 300),
  reason text not null check (reason in ('spam', 'harassment', 'inappropriate', 'other')),
  status text not null default 'open' check (status in ('open', 'dismissed', 'hidden', 'muted')),
  created_at timestamptz not null default transaction_timestamp(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null,
  review_note text,
  unique (reporter_id, message_id)
);

create index global_chat_reports_open_idx
  on public.global_chat_reports_v1 (created_at, id) where status = 'open';

alter table public.global_chat_profiles_v1 enable row level security;
alter table public.global_chat_messages_v1 enable row level security;
alter table public.global_chat_blocks_v1 enable row level security;
alter table public.global_chat_reports_v1 enable row level security;

revoke all on table public.global_chat_profiles_v1 from public, anon, authenticated;
revoke all on table public.global_chat_messages_v1 from public, anon, authenticated;
revoke all on table public.global_chat_blocks_v1 from public, anon, authenticated;
revoke all on table public.global_chat_reports_v1 from public, anon, authenticated;
revoke all on sequence public.global_chat_messages_v1_id_seq from public, anon, authenticated;
revoke all on sequence public.global_chat_reports_v1_id_seq from public, anon, authenticated;

create or replace function public.purge_global_chat_data_v1()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  delete from public.global_chat_messages_v1
   where created_at < pg_catalog.transaction_timestamp() - interval '30 days';
  delete from public.global_chat_reports_v1
   where created_at < pg_catalog.transaction_timestamp() - interval '180 days';
end;
$$;

create or replace function public.get_my_global_chat_profile_v1()
returns table (public_id uuid, display_name text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if not public.is_active_game_session_v1() then
    raise exception using errcode = '28000', message = 'Active game session required';
  end if;

  select pg_catalog.left(
           pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(gs.save_data ->> 'gardenName', '')), '[[:cntrl:]]', '', 'g'),
           24
         )
    into v_name
    from public.game_saves as gs
   where gs.user_id = v_uid;
  if pg_catalog.char_length(pg_catalog.btrim(coalesce(v_name, ''))) < 2 then
    v_name := 'Nhà vườn';
  end if;

  insert into public.global_chat_profiles_v1 (user_id, display_name)
  values (v_uid, v_name)
  on conflict (user_id) do nothing;

  return query
    select p.public_id, p.display_name
      from public.global_chat_profiles_v1 as p
     where p.user_id = v_uid;
end;
$$;

create or replace function public.get_my_global_chat_blocks_v1()
returns table (blocked_public_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if not public.is_active_game_session_v1() then
    raise exception using errcode = '28000', message = 'Active game session required';
  end if;
  return query
    select b.blocked_public_id
      from public.global_chat_blocks_v1 as b
     where b.user_id = v_uid;
end;
$$;

create or replace function public.block_global_chat_user_v1(p_public_id uuid, p_block boolean default true)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_target uuid;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if not public.is_active_game_session_v1() then
    raise exception using errcode = '28000', message = 'Active game session required';
  end if;
  perform 1 from public.get_my_global_chat_profile_v1();
  select p.user_id into v_target
    from public.global_chat_profiles_v1 as p
   where p.public_id = p_public_id;
  if v_target is null or v_target = v_uid then
    raise exception using errcode = '22023', message = 'Invalid chat user';
  end if;
  if p_block then
    insert into public.global_chat_blocks_v1 (user_id, blocked_public_id)
    values (v_uid, p_public_id)
    on conflict do nothing;
  else
    delete from public.global_chat_blocks_v1 as b
     where b.user_id = v_uid and b.blocked_public_id = p_public_id;
  end if;
  return p_block;
end;
$$;

create or replace function public.get_global_chat_messages_v1(p_after_id bigint default null, p_limit smallint default 50)
returns table (
  id bigint,
  sender_public_id uuid,
  display_name text,
  body text,
  created_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if not public.is_active_game_session_v1() then
    raise exception using errcode = '28000', message = 'Active game session required';
  end if;
  perform 1 from public.get_my_global_chat_profile_v1();
  perform public.purge_global_chat_data_v1();

  if p_after_id is null then
    return query
      select page.id, page.public_id, page.display_name, page.body, page.created_at
        from (
          select m.id, p.public_id, p.display_name, m.body, m.created_at
            from public.global_chat_messages_v1 as m
            join public.global_chat_profiles_v1 as p on p.user_id = m.sender_id
           where m.hidden_at is null
             and not exists (
               select 1 from public.global_chat_blocks_v1 as b
                where b.user_id = v_uid and b.blocked_public_id = p.public_id
             )
           order by m.id desc
           limit least(greatest(coalesce(p_limit, 50), 1), 50)
        ) as page
       order by page.id;
  else
    return query
      select m.id, p.public_id, p.display_name, m.body, m.created_at
        from public.global_chat_messages_v1 as m
        join public.global_chat_profiles_v1 as p on p.user_id = m.sender_id
       where m.id > p_after_id
         and m.hidden_at is null
         and not exists (
           select 1 from public.global_chat_blocks_v1 as b
            where b.user_id = v_uid and b.blocked_public_id = p.public_id
         )
       order by m.id
       limit least(greatest(coalesce(p_limit, 50), 1), 50);
  end if;
end;
$$;

create or replace function public.send_global_chat_message_v1(p_request_id uuid, p_body text)
returns table (
  id bigint,
  sender_public_id uuid,
  display_name text,
  body text,
  created_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
  v_public_id uuid;
  v_body text := pg_catalog.btrim(coalesce(p_body, ''));
  v_id bigint;
  v_saved_body text;
  v_created_at timestamptz;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if not public.is_active_game_session_v1() then
    raise exception using errcode = '28000', message = 'Active game session required';
  end if;
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'Request ID is required';
  end if;
  if pg_catalog.char_length(v_body) not between 1 and 300 then
    raise exception using errcode = '22023', message = 'Message must be 1 to 300 characters';
  end if;

  perform 1 from public.get_my_global_chat_profile_v1();
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('global-chat:' || v_uid::text, 0));

  select m.id, m.body, m.created_at, p.public_id, p.display_name
    into v_id, v_saved_body, v_created_at, v_public_id, v_name
    from public.global_chat_messages_v1 as m
    join public.global_chat_profiles_v1 as p on p.user_id = m.sender_id
   where m.sender_id = v_uid and m.request_id = p_request_id;
  if v_id is not null then
    if v_saved_body <> v_body then
      raise exception using errcode = '22023', message = 'Request ID was already used for different content';
    end if;
    return query select v_id, v_public_id, v_name, v_saved_body, v_created_at;
    return;
  end if;

  perform public.purge_global_chat_data_v1();
  select p.display_name, p.public_id into v_name, v_public_id
    from public.global_chat_profiles_v1 as p
   where p.user_id = v_uid and (p.muted_until is null or p.muted_until <= pg_catalog.transaction_timestamp())
   for update;
  if v_public_id is null then
    raise exception using errcode = '42501', message = 'Chat sending is temporarily unavailable for this account';
  end if;
  if exists (
    select 1 from public.global_chat_messages_v1 as m
     where m.sender_id = v_uid and m.created_at > pg_catalog.transaction_timestamp() - interval '2 seconds'
  ) or (
    select count(*) from public.global_chat_messages_v1 as m
     where m.sender_id = v_uid and m.created_at > pg_catalog.transaction_timestamp() - interval '60 seconds'
  ) >= 10 then
    raise exception using errcode = '22023', message = 'Please wait before sending another message';
  end if;

  insert into public.global_chat_messages_v1 (sender_id, request_id, body)
  values (v_uid, p_request_id, v_body)
  returning global_chat_messages_v1.id, global_chat_messages_v1.created_at
    into v_id, v_created_at;
  return query select v_id, v_public_id, v_name, v_body, v_created_at;
end;
$$;

create or replace function public.report_global_chat_message_v1(p_message_id bigint, p_reason text)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_own_public_id uuid;
  v_report_id bigint;
  v_target_public_id uuid;
  v_body text;
begin
  if v_uid is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  if not public.is_active_game_session_v1() then
    raise exception using errcode = '28000', message = 'Active game session required';
  end if;
  if p_reason is null or p_reason not in ('spam', 'harassment', 'inappropriate', 'other') then
    raise exception using errcode = '22023', message = 'Invalid report reason';
  end if;

  select p.public_id, m.body into v_target_public_id, v_body
    from public.global_chat_messages_v1 as m
    join public.global_chat_profiles_v1 as p on p.user_id = m.sender_id
   where m.id = p_message_id;
  perform 1 from public.get_my_global_chat_profile_v1() as own_profile;
  select p.public_id into v_own_public_id
    from public.global_chat_profiles_v1 as p where p.user_id = v_uid;
  if v_target_public_id is null or v_target_public_id = v_own_public_id then
    raise exception using errcode = '22023', message = 'Message cannot be reported';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('global-chat-report:' || v_uid::text, 0));
  select r.id into v_report_id from public.global_chat_reports_v1 as r
   where r.reporter_id = v_uid and r.message_id = p_message_id;
  if v_report_id is not null then return v_report_id; end if;
  if (select count(*) from public.global_chat_reports_v1 as r
       where r.reporter_id = v_uid and r.created_at > pg_catalog.transaction_timestamp() - interval '1 hour') >= 10 then
    raise exception using errcode = '22023', message = 'Report rate limit reached';
  end if;

  insert into public.global_chat_reports_v1
    (reporter_id, message_id, reported_public_id, message_snapshot, reason)
  values (v_uid, p_message_id, v_target_public_id, v_body, p_reason)
  on conflict (reporter_id, message_id) do nothing
  returning id into v_report_id;
  if v_report_id is null then
    select r.id into v_report_id
      from public.global_chat_reports_v1 as r
     where r.reporter_id = v_uid and r.message_id = p_message_id;
  end if;
  return v_report_id;
end;
$$;

create or replace function public.get_global_chat_reports_v1(p_limit smallint default 50)
returns table (
  id bigint,
  message_id bigint,
  reported_public_id uuid,
  message_snapshot text,
  reason text,
  status text,
  created_at timestamptz,
  review_note text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not public.is_game_admin() then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  return query
    select r.id, r.message_id, r.reported_public_id, r.message_snapshot,
           r.reason, r.status, r.created_at, r.review_note
      from public.global_chat_reports_v1 as r
     where r.status = 'open'
     order by r.created_at, r.id
     limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

create or replace function public.review_global_chat_report_v1(p_report_id bigint, p_action text, p_note text default null)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_report public.global_chat_reports_v1%rowtype;
begin
  if v_uid is null or not public.is_game_admin() then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if p_action is null or p_action not in ('dismiss', 'hide', 'mute_1d') then
    raise exception using errcode = '22023', message = 'Invalid moderation action';
  end if;

  select r.* into v_report
    from public.global_chat_reports_v1 as r
   where r.id = p_report_id and r.status = 'open'
   for update;
  if not found then return false; end if;

  if p_action = 'hide' and v_report.message_id is not null then
    update public.global_chat_messages_v1 as m
       set hidden_at = pg_catalog.transaction_timestamp()
     where m.id = v_report.message_id;
  elsif p_action = 'mute_1d' then
    update public.global_chat_profiles_v1 as p
       set muted_until = greatest(coalesce(p.muted_until, pg_catalog.transaction_timestamp()), pg_catalog.transaction_timestamp()) + interval '1 day',
           updated_at = pg_catalog.transaction_timestamp()
     where p.public_id = v_report.reported_public_id;
  end if;

  update public.global_chat_reports_v1 as r
     set status = case p_action when 'dismiss' then 'dismissed' when 'hide' then 'hidden' else 'muted' end,
         reviewed_at = pg_catalog.transaction_timestamp(),
         reviewed_by = v_uid,
         review_note = pg_catalog.left(coalesce(p_note, ''), 500)
   where r.id = p_report_id;
  return true;
end;
$$;

create or replace function public.broadcast_global_chat_message_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_payload jsonb;
begin
  if tg_op = 'UPDATE' then
    if old.hidden_at is null and new.hidden_at is not null then
      begin
        perform realtime.send(pg_catalog.jsonb_build_object('id', new.id), 'global_chat_hide', 'global-chat:v1', true);
      exception when others then
        raise warning 'Global chat hide broadcast failed; hidden state remains stored. SQLSTATE=%', sqlstate;
      end;
    end if;
    return new;
  end if;
  if new.hidden_at is not null then return new; end if;
  select pg_catalog.jsonb_build_object(
           'id', new.id,
           'sender_public_id', p.public_id,
           'display_name', p.display_name,
           'body', new.body,
           'created_at', new.created_at
         )
    into v_payload
    from public.global_chat_profiles_v1 as p
   where p.user_id = new.sender_id;
  if v_payload is not null then
    begin
      perform realtime.send(v_payload, 'global_chat_message', 'global-chat:v1', true);
    exception when others then
      raise warning 'Global chat Realtime broadcast failed; message remains stored. SQLSTATE=%', sqlstate;
    end;
  end if;
  return new;
end;
$$;

create trigger global_chat_broadcast_v1
  after insert or update of hidden_at on public.global_chat_messages_v1
  for each row execute function public.broadcast_global_chat_message_v1();

-- Realtime manages this table; do not alter or enable RLS on it here.
drop policy if exists global_chat_receive_v1 on realtime.messages;
create policy global_chat_receive_v1
  on realtime.messages for select to authenticated
  using (extension = 'broadcast' and topic = 'global-chat:v1');

revoke all on function public.purge_global_chat_data_v1() from public, anon, authenticated;
revoke all on function public.get_my_global_chat_profile_v1() from public, anon, authenticated;
revoke all on function public.get_my_global_chat_blocks_v1() from public, anon, authenticated;
revoke all on function public.block_global_chat_user_v1(uuid, boolean) from public, anon, authenticated;
revoke all on function public.get_global_chat_messages_v1(bigint, smallint) from public, anon, authenticated;
revoke all on function public.send_global_chat_message_v1(uuid, text) from public, anon, authenticated;
revoke all on function public.report_global_chat_message_v1(bigint, text) from public, anon, authenticated;
revoke all on function public.get_global_chat_reports_v1(smallint) from public, anon, authenticated;
revoke all on function public.review_global_chat_report_v1(bigint, text, text) from public, anon, authenticated;
revoke all on function public.broadcast_global_chat_message_v1() from public, anon, authenticated;

grant execute on function public.get_my_global_chat_profile_v1() to authenticated;
grant execute on function public.get_my_global_chat_blocks_v1() to authenticated;
grant execute on function public.block_global_chat_user_v1(uuid, boolean) to authenticated;
grant execute on function public.get_global_chat_messages_v1(bigint, smallint) to authenticated;
grant execute on function public.send_global_chat_message_v1(uuid, text) to authenticated;
grant execute on function public.report_global_chat_message_v1(bigint, text) to authenticated;
grant execute on function public.get_global_chat_reports_v1(smallint) to authenticated;
grant execute on function public.review_global_chat_report_v1(bigint, text, text) to authenticated;

comment on table public.global_chat_profiles_v1 is
  'Server-owned display identity seeded from the saved garden name; public_id is not an Auth user ID.';
comment on table public.global_chat_messages_v1 is
  'Canonical messages for the single global room. Client access is through authenticated RPC only.';
comment on table public.global_chat_blocks_v1 is
  'Private per-user hides for the global chat; never changes or deletes another player messages.';
comment on table public.global_chat_reports_v1 is
  'Private moderation reports; message snapshots are retained up to 180 days.';
comment on function public.send_global_chat_message_v1(uuid, text) is
  'Authenticates sender via auth.uid(), checks active session, idempotency, content bounds and per-user rate limits atomically.';
comment on function public.get_global_chat_messages_v1(bigint, smallint) is
  'Returns at most 50 safe public fields; null cursor returns latest messages and a cursor returns later messages.';

commit;
