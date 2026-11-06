# Migration 020 — Canonical economy gaps

This is a draft migration for the web game. It has not been run against staging or production. Apply only after review, and apply after migrations `001` through `019`, including the orchard migration `019`.

It adds server-owned processing jobs, visitor mission state and vouchers, cosmetic entitlements, canonical decoration stock/layout, and a new player marketplace. All mutation RPCs identify players through `auth.uid()`, use server prices/rewards/timestamps and run their economy effects in one transaction. Idempotency records live in `economy_requests`. RLS is enabled on the new tables; clients receive only own-row reads where needed, while writes occur through authenticated RPCs.

The migration leaves `game_saves` and the legacy marketplace table rows unchanged. It revokes the old game-save-backed marketplace RPCs when they exist, so the older marketplace client will stop working after this migration. Existing legacy listings are not copied into the canonical market. Local-only craft queues, visitor rewards, decorations, cosmetics, and voucher counts are saved to a per-account recovery snapshot by the web client before canonical state is loaded; they are not automatically credited because local history is not independently verifiable. Character and garden-skin purchase plus auto-equip are one server transaction. Successful visitor reward receipts include authoritative cycle/return timestamps so a temporary refresh failure cannot make the client grant twice or start the next visitor early. The existing `s.collections` save field is left untouched and is not converted into collection rewards.

## Web deployment order

1. Review and run this migration on staging, then verify the queries below.
2. Deploy the updated `outputs/index.html` to Vercel after the RPCs exist. Until then, online flows affected by this migration intentionally show a server-sync error and do not charge or grant items locally.
3. Test with two staging accounts before using the shared marketplace. Do not run this migration directly on production without the normal approval process.

## Read-only postflight

```sql
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in (
  'player_processing_jobs_v1','player_cosmetic_ownership_v1',
  'player_animal_vouchers_v1','player_visitor_missions_v1','market_listings_v2'
)
order by c.relname;

select p.proname as routine_name, r.rolname as grantee
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
cross join lateral aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) a
join pg_roles r on r.oid=a.grantee
where n.nspname='public' and p.proname in (
  'get_my_processing_v1','enqueue_processing_v1','sell_animal_v1',
  'get_my_visitor_missions_v1','accept_visitor_missions_v1','claim_visitor_quest_v1',
  'redeem_animal_voucher_v1','buy_farm_item_v1','set_my_cosmetic_v1',
  'update_farm_decorations_v1','get_my_farm_cosmetics_v1',
  'market_get_listings_v2','market_create_listing_v2','market_buy_listing_v2','market_cancel_listing_v2'
) and r.rolname in ('anon','authenticated','public')
order by p.proname,r.rolname;
```

For mutating functions, only `authenticated` should have `EXECUTE`; `anon` and `public` should have none. Internal helper functions and trigger functions should not be executable by API roles. All new tables should report RLS enabled.

## Acceptance checks on staging

- Enqueueing the same processing request ID twice reserves ingredients once; a second distinct request without enough stock fails without changing stock. Finished output and XP appear once, using server time.
- Two simultaneous sells of the same animal cannot reduce canonical count below zero or credit duplicate refunds.
- Visitor plant/harvest/water/feed/animal progress changes only after successful server RPCs. Repeated and concurrent reward claims grant coins, XP, seeds, and vouchers once. Server expiry/return time is used, not device time.
- A voucher cannot bypass unlock level or animal capacity. A retry cannot consume two vouchers.
- Decorations can be bought only at server prices; placement consumes owned stock; storing returns stock. Concurrent or retried requests cannot duplicate placement stock.
- Character/skin purchases charge once; equip requires server ownership.
- Two accounts can list/buy/cancel. A buyer pays and receives the item once; the seller receives the same amount; self-buy, insufficient coins/stock, closed listings, and replayed IDs fail safely.
- Confirm legacy marketplace rows and `s.collections` remain present and are not automatically imported as canonical inventory or rewards.
