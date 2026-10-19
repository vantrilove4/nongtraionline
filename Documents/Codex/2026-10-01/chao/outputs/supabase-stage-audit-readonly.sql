-- Read-only security audit for the Vườn Nhỏ Supabase project.
-- Run only in the intended STAGING project (Dashboard > SQL Editor).
-- This file contains SELECT statements only and does not return save contents,
-- account emails, access tokens, or other player-identifying data.

-- 1) Confirm which database/role the SQL editor is connected to.
select current_database() as database_name, current_user as sql_editor_role,
       current_setting('server_version') as postgres_version;

-- 2) RLS status and FORCE RLS status for game tables.
select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as force_rls
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','p')
  and c.relname in ('game_saves','market_listings','game_admins','game_global_config')
order by c.relname;

-- 3) Policies and their predicates. Review that player-owned rows compare to auth.uid().
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_catalog.pg_policies
where schemaname = 'public'
  and tablename in ('game_saves','market_listings','game_admins','game_global_config')
order by tablename, policyname;

-- 4) Effective table privileges for browser-facing roles.
select table_name, grantee, privilege_type, is_grantable
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('game_saves','market_listings','game_admins','game_global_config')
  and grantee in ('anon','authenticated','service_role','public')
order by table_name, grantee, privilege_type;

-- 5) Relevant RPC security mode, search_path, and execute access.
select p.oid::regprocedure as function_signature,
       p.prosecdef as security_definer,
       p.provolatile as volatility,
       p.proconfig as function_settings,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute,
       exists (
         select 1
         from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) acl
         where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
       ) as public_can_execute
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'market_get_listings','market_create_listing','market_buy_listing',
    'market_cancel_listing','get_game_leaderboard_v2',
    'get_game_global_config','is_game_admin','save_game_global_config'
  )
order by p.proname, p.oid::regprocedure::text;

-- 6) Foreign keys and delete behavior for relevant tables.
select conrelid::regclass as table_name, conname as constraint_name,
       confrelid::regclass as referenced_table,
       pg_catalog.pg_get_constraintdef(oid) as definition
from pg_catalog.pg_constraint
where contype = 'f'
  and (conrelid::regclass::text in ('public.game_saves','public.market_listings','public.game_admins','public.game_global_config')
       or confrelid::regclass::text in ('public.game_saves','public.market_listings','public.game_admins','public.game_global_config'))
 order by conrelid::regclass::text, conname;

-- 7) Aggregate-only data health checks. These do not reveal any save documents.
select count(*) as game_save_rows,
       count(*) filter (where jsonb_typeof(save_data) is distinct from 'object') as non_object_save_rows,
       count(*) filter (where coalesce(save_data ->> 'coins', '') !~ '^[0-9]{1,15}$') as malformed_coin_rows,
       count(*) filter (where coalesce(save_data ->> 'xp', '') !~ '^[0-9]{1,15}([.][0-9]{1,2})?$') as malformed_xp_rows
from public.game_saves;

select status, count(*) as listing_count
from public.market_listings
group by status
order by status;

-- 8) Confirm browser roles do not own sensitive tables or have BYPASSRLS.
select rolname, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb
from pg_catalog.pg_roles
where rolname in ('anon','authenticated','authenticator','service_role','postgres')
order by rolname;
