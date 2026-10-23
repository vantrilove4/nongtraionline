# Global chat v1 rollout

## Scope

One authenticated global room only. The client reads and writes chat data through RPCs. The database assigns sender identity from the saved garden name and server timestamps, enforces message length, idempotency and per-account rate limits, and filters blocked authors. Realtime Broadcast sends only the display name, opaque chat profile ID, message ID, body and server timestamp. Chat does not read or update `game_saves` except to seed a display name when creating a profile; it does not touch gameplay, wallet, inventory or quest tables.

## Files

- `20261023_017_global_chat_v1.sql`: additive schema/RPC/RLS/realtime policy. This file has **not** been run against any Supabase project.
- `../global-chat.js`: web chat client and compact scene panel.
- `../assets/vendor/supabase-js-2.118.0.js`: pinned official Supabase JavaScript SDK UMD build; `supabase-js-LICENSE.txt` accompanies it.
- `../game-i18n.js`: English labels for chat.
- `../admin.html`: admin-only report queue and review actions.

## Dependencies and rollout

The migration expects the project's Supabase Auth/PostgREST/Realtime schemas, `public.is_active_game_session_v1()` from `20261019_015_single_active_session_v1.sql`, and `public.is_game_admin()` from `supabase-admin-config.sql`. Apply the chat migration only after checking those prerequisites in the intended environment. Apply it once, first in staging, and inspect the results before any production decision. Do not paste this migration into production by default. The migration uses a transaction but is not designed to be re-run after a partial/manual edit; if it fails, inspect the transaction result and schema state before retrying.

After the schema is available, deploy the `outputs` web files together. Android WebView asset copies are updated with the same client and SDK; rebuild/sign an Android package separately if an APK release is wanted. The UI is present before migration, but authenticated chat actions will show a server error until the migration exists.

## Data access and server authority

- All four chat tables have RLS enabled and no client table grants/policies. Authenticated users can access only the explicitly granted RPCs; anonymous users receive no RPC execute privilege.
- Profile, message, block and report writes occur only in `SECURITY DEFINER` functions with an empty `search_path`. Functions derive identity from `auth.uid()` and require the active game session. Client-supplied sender IDs and timestamps are never accepted.
- Message sends use `request_id` plus a per-user transaction advisory lock and a unique `(sender_id, request_id)` key. Reusing the ID with the same content returns the original message; reusing it with different content fails. The send and message insert are one database transaction.
- A report is unique per reporter/message. Repeating a report returns the existing report. Report submission is capped at ten per account per hour. Admin report/review functions check `is_game_admin()` server-side.
- Realtime reads are authenticated and restricted to the private topic `global-chat:v1`. Clients cannot write to Realtime as the source of truth. The DB trigger broadcasts sanitized payload fields after insert and a message ID after moderation hides a message; a broadcast failure does not roll back stored state.
- Messages are purged after 30 days when an authenticated chat RPC runs. Report snapshots are purged after 180 days on the same lazy-cleanup path. No scheduled job is created.

## Rollback

Rollback is a separate, manual operation and removes chat data. First pause chat traffic by taking the new client scripts out of the deployment. Export any moderation records that must be retained. Then, in a reviewed SQL transaction, drop policy `global_chat_receive_v1` on `realtime.messages`, trigger `global_chat_broadcast_v1` on `public.global_chat_messages_v1`, functions `public.broadcast_global_chat_message_v1()`, `public.review_global_chat_report_v1(bigint,text,text)`, `public.get_global_chat_reports_v1(smallint)`, `public.report_global_chat_message_v1(bigint,text)`, `public.send_global_chat_message_v1(uuid,text)`, `public.get_global_chat_messages_v1(bigint,smallint)`, `public.block_global_chat_user_v1(uuid,boolean)`, `public.get_my_global_chat_blocks_v1()`,  `public.get_my_global_chat_profile_v1()`, `public.purge_global_chat_data_v1()`, then the four `global_chat_*_v1` tables. Do not drop the existing `realtime.messages` table or any shared admin/session functions. Since this destroys chat history and reports, do not run rollback without explicit approval and a backup.

## Verification cases

Run these only in a disposable/staging environment after manual approval to apply the migration:

1. Two authenticated accounts with active game sessions: send from A, verify B receives one message and can page the latest 50.
2. Anonymous send and anonymous/private-topic subscribe: denied.
3. Forged `sender_id`, timestamp or unknown RPC argument: unsupported/rejected; message identity/time match the authenticated profile and DB time.
4. Body of 301 characters, blank content, or invalid UTF input: rejected; no row inserted.
5. Ten messages in one minute / less than two seconds between messages: rate-limited; identical request retry still returns one original row.
6. Repeat the same request ID concurrently and then sequentially: exactly one row; changing content under that ID fails.
7. Drop network after submit and retry the same request ID: one persisted row, client deduplicates by message ID after reconnect.
8. Concurrent sends from several accounts: all accepted within individual limits; unique IDs and server timestamps remain valid.
9. User A blocks B: B's messages disappear from A's read RPC and client; other users still see them; A cannot block self.
10. Report then repeat: one report; ordinary users cannot read/report queue or review actions; authorized admin can hide, mute or dismiss.
11. Body `<script>alert(1)</script>` displays as literal text in both game and admin panel; no script executes.
12. Account without active session, profile ownership, or admin role cannot access protected operations.

No staging or production connection was exercised by the implementation work. Browser visual validation still requires deployment behind HTTPS and a migrated staging project; `file://` is not a supported Realtime origin.
