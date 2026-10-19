# Giai đoạn 2 — migration nền tảng (dark launch)

## Phạm vi

`20261019_001_phase2_foundation.sql` bổ sung schema canonical và RPC đọc nhiệm vụ ngày. `20261019_002_claim_daily_quest_v2.sql` thêm RPC nhận thưởng giao dịch/idempotent. `20261019_003_new_player_bootstrap_and_plant_v2.sql` thêm khởi tạo an toàn cho tài khoản không có legacy save cùng RPC cuốc đất và gieo hạt. `20261019_004_crop_water_harvest_v2.sql` là draft RPC tưới/thu hoạch cây. `20261019_005_shop_purchase_v2.sql` là draft RPC mua hạt giống/thức ăn.

Các migration chỉ là dark-launch backend. Chúng không sửa `game_saves`, không chuyển save, không thay đổi HTML web/Android và không cấp quyền client ghi trực tiếp ví, kho, farm state, tiến độ quest hoặc phần thưởng. **Không nối client đến các RPC mới ở bước này.** Khởi tạo từ chối tài khoản có hàng `game_saves`; không có migration tự động cho người chơi cũ.

Migration chỉ được áp dụng lên staging sau khi kiểm tra schema đích và được phê duyệt triển khai môi trường đó. Chưa chạy SQL bằng Codex và chưa xác minh staging/production.

## Quyền và dữ liệu

| Bảng | Đọc | Ghi | Khóa / nguyên tử tính |
|---|---|---|---|
| `player_wallets` | Người chơi chỉ đọc hàng của mình qua RLS | Chỉ backend/RPC sau này | `user_id` PK; xu/XP không âm |
| `player_inventory` | Người chơi chỉ đọc hàng của mình qua RLS | Chỉ backend/RPC sau này | `(user_id,item_key)` PK; số lượng không âm |
| `player_farm_state` | Người chơi chỉ đọc hàng của mình qua RLS | Chỉ backend/RPC sau này | `user_id` PK; revision chỉ để phát hiện xung đột |
| `daily_quest_catalog` | Không cấp quyền client | Migration/DB owner | `quest_id` PK; các mục gieo/thu hoạch/cho ăn được khởi tạo cố định |
| `player_daily_quests` | Người chơi chỉ đọc hàng của mình qua RLS; RPC tạo hàng trong ngày | Chỉ backend/RPC sau này | `(user_id,period_date,quest_id)` PK; ngày do DB tính theo `Asia/Ho_Chi_Minh` |
| `economy_requests` | Không cấp quyền client | RPC claim | `(user_id,request_id)` PK; server hash, response và hiệu ứng cùng transaction |
| `reward_claims` | Không cấp quyền client | RPC claim | `(user_id,reward_kind,period_key,source_id)` PK và `(user_id,request_id)` unique |

Các FK dùng `ON DELETE RESTRICT` để không xóa tiến trình khi xóa tài khoản vô tình. Vì vậy cần thiết kế quy trình xóa tài khoản riêng trước khi hỗ trợ xóa Auth user. Không có RPC nhận `user_id`/ngày từ client. `get_my_daily_quests_v2()` chỉ đọc/khởi tạo quest display; `claim_daily_quest_v2()` chỉ được gọi bởi `authenticated`, tự lấy user từ `auth.uid()` và chỉ dựa trên progress/reward snapshot của server. Chưa có RPC nào tăng progress.

## Quan hệ

```text
auth.users 1──1 player_wallets
auth.users 1──* player_inventory
auth.users 1──1 player_farm_state
auth.users 1──* player_daily_quests *──1 daily_quest_catalog
auth.users 1──* economy_requests 1──* reward_claims
```

## Preflight staging (chỉ đọc)

Trước khi chạy migration, kiểm tra tên bảng/function đã tồn tại và so sánh schema với file. Dừng nếu có object cùng tên không thuộc migration này.

```sql
select n.nspname as schema_name, c.relname as object_name, c.relkind
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'player_wallets','player_inventory','player_farm_state',
    'daily_quest_catalog','player_daily_quests','economy_requests','reward_claims'
  )
order by c.relname;

select p.oid::regprocedure as function_name
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'get_my_daily_quests_v2';
```

Không dùng service key trong trình duyệt. Không chạy file lên production ở bước này.

## Postflight staging (chỉ đọc)

Sau khi migration được chủ dự án chạy/duyệt trên staging, xác nhận RLS, quyền và hàm:

```sql
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'player_wallets','player_inventory','player_farm_state',
    'daily_quest_catalog','player_daily_quests','economy_requests','reward_claims'
  )
order by c.relname;

select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'player_wallets','player_inventory','player_farm_state',
    'daily_quest_catalog','player_daily_quests','economy_requests','reward_claims'
  )
order by table_name, grantee, privilege_type;

select routine_name, grantee, privilege_type
from information_schema.role_routine_grants
where specific_schema = 'public'
  and routine_name in ('get_my_daily_quests_v2','claim_daily_quest_v2')
order by grantee, privilege_type;
```

Kỳ vọng: RLS bật trên cả bảy bảng; authenticated chỉ có SELECT trên wallet/inventory/farm/daily quest; không có quyền bảng cho anon. Với RPC, `authenticated` phải có EXECUTE để game gọi bằng phiên người chơi; `postgres` (owner) và `service_role` (backend bí mật) cũng có thể xuất hiện trong `information_schema.role_routine_grants` do quyền sở hữu/quyền mặc định Supabase. Không đưa service-role key vào trình duyệt. Các role công khai như `anon` và `PUBLIC` không được có EXECUTE. Catalog và ledger không được cấp quyền đọc cho các role client.

## Kiểm thử bắt buộc trước khi bật client

1. Gọi RPC khi chưa đăng nhập: bị từ chối.
2. Hai session authenticated gọi RPC đọc đồng thời cùng ngày: mỗi quest chỉ có một hàng nhờ PK; cả hai thấy cùng tiến độ.
3. Gọi RPC đọc lặp lại: không reset progress/claimed state và không tạo hàng trùng.
4. Người chơi A đọc hàng người chơi B: trả về không có hàng; DML trực tiếp của authenticated/anon bị từ chối.
5. Authenticated cố sửa target, progress, wallet, inventory hoặc ledger: bị từ chối.
6. Claim với progress chưa đủ hoặc chưa có wallet: bị từ chối và không đổi xu/XP/kho.
7. Cùng claim request id sau commit: nhận response đã lưu, không cộng thưởng lần hai.
8. Cùng request id nhưng quest khác: bị từ chối; UUID khác claim cùng quest: tối đa một thưởng.
9. Hai session đồng thời claim cùng quest: chỉ một thưởng được ghi; session sau nhận kết quả đã claim hoặc lỗi đã nhận, không có cộng đôi.
10. Đổi múi giờ thiết bị không làm đổi ngày RPC; ranh giới ngày là 00:00 Asia/Ho_Chi_Minh.
11. So sánh số lượng/hash `game_saves` trước và sau: không thay đổi; `s.collections` vẫn nguyên trạng.

Kiểm thử timeout trước/sau commit, thiếu kho và xung đột revision vẫn cần cho các RPC hành động tiếp theo. Claim này chỉ tác động xu/XP từ canonical wallet; hiện chưa có API nào tăng quest progress.

## Rollback

Rollback ứng dụng ở bước dark-launch: không gọi RPC mới từ client, giữ nguyên các bảng để điều tra, không xóa dữ liệu. Bản SQL chưa có lệnh `DROP`; xóa bảng không phải rollback an toàn nếu đã có hàng. Nếu staging migration thất bại giữa chừng, dừng và kiểm tra trạng thái từng object trước khi sửa; không chạy lại mù quáng. Không có khôi phục ngược `game_saves` vì migration này không đụng tới nó.

## Chưa triển khai

- RPC gieo/trồng, thu hoạch, cho ăn và cập nhật tiến độ phía server.
- Khởi tạo wallet/inventory/farm state và đối soát tài khoản cũ.
- Cutover web/Android, version gate APK cũ, marketplace migration.
- Nhiệm vụ tuần, điểm danh, đơn hàng, thành tích/sổ sưu tập.
- Áp dụng hoặc xác minh bất kỳ môi trường Supabase nào.

## Tích hợp giao diện Giai đoạn 2 (dark launch)

- Bản web `outputs/index.html` có nút **Nhiệm vụ & phần thưởng**; `outputs/phase2-retention.js` gọi các RPC ngày/tuần, điểm danh, đơn hàng, thành tích và sổ sưu tập. Bản APK không nằm trong phạm vi tích hợp này.
- Giao diện yêu cầu phiên đăng nhập đã đồng bộ và xác nhận có hàng `player_wallets` cùng `player_farm_state` qua quyền SELECT/RLS của chính người chơi. Tài khoản chỉ có save legacy bị chặn trước khi gọi RPC; không tự bootstrap, nhập save, sửa `game_saves` hoặc đổi `s.collections`.
- Không kết nối tính năng này cho production: migrations 004–012 còn phải được áp dụng và kiểm thử staging; cutover đầy đủ gameplay/save legacy vẫn là điều kiện riêng. HUD và save legacy chưa được hợp nhất với ví/kho canonical, nên không mở các phần thưởng cho legacy account.
- Thứ tự staging cho các migration còn lại: `20261019_012_daily_quest_lock_order_v2.sql`, sau đó `004`, `005`, `006`, rồi `007`–`011`. Chỉ chạy khi đã chọn đúng staging project; không chạy SQL production theo hướng dẫn này.
- Trạng thái kết nối: workspace không có Supabase CLI, project link hoặc database credential; migrations chưa được chạy từ Codex. Việc thêm UI/API wiring không chứng minh RPC đã tồn tại trên staging.

## Migration 002 — nhận nhiệm vụ ngày

`20261019_002_claim_daily_quest_v2.sql` phụ thuộc migration 001. RPC `claim_daily_quest_v2(request_id, quest_id)` tự tính ngày HCM, tạo idempotency fingerprint phía server, khóa hàng quest, kiểm tra progress/claimed, cập nhật ví, tạo domain ledger và lưu response trong một transaction. Không có tham số user id, phần thưởng, ngày, tiến độ hoặc số dư. Quyền EXECUTE chỉ cấp cho `authenticated`; client không được ghi trực tiếp vào ledger/ví.

Theo các kết quả postflight người dùng gửi ngày 2026-10-19:

- Hai RPC có EXECUTE cho `authenticated`, `postgres` và `service_role`.
- `authenticated` chỉ có SELECT trên `player_wallets`, `player_inventory`, `player_farm_state`, `player_daily_quests`; không có quyền `anon`.
- Cả bảy bảng đều có `relrowsecurity = true`. `relforcerowsecurity = false` không làm mất bảo vệ RLS đối với role client; owner/service role là vai trò đặc quyền.

Các kiểm tra quyền cơ bản trên staging đạt theo output được gửi; Codex chưa kết nối trực tiếp để xác minh độc lập. Điều này chưa kiểm chứng hành vi giao dịch, retry, RLS bằng hai tài khoản hay test RPC. Giao diện dark-launch hiện có gọi API nhưng bị chặn nếu không có wallet/farm canonical; không mở cho người chơi thật cho tới khi RPC hành động hợp lệ được hoàn tất và staging tests pass. `service_role` key chỉ được giữ ở backend.

## Migration 003 — bootstrap an toàn và cuốc đất / gieo hạt

Phụ thuộc các migration 001/002, `public.game_saves` và `public.game_global_config`. Trước khi chạy staging, dùng truy vấn chỉ đọc sau để xác nhận đủ đối tượng và không có đối tượng mới trùng tên:

```sql
select n.nspname as schema_name, c.relname as object_name, c.relkind
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('game_saves','game_global_config','crop_action_catalog_v2');

select p.oid::regprocedure as function_name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('bootstrap_new_player_v2','till_plot_v2','plant_crop_v2');
```

Dừng nếu `crop_action_catalog_v2` hoặc bất kỳ hàm mới nào đã tồn tại ngoài lần áp dụng migration này. Chạy 003 chỉ sau khi 001/002 và config đã được xác nhận; chưa chạy trên production.

| Đối tượng | Đọc/ghi và quyền | Ràng buộc và transaction |
|---|---|---|
| `crop_action_catalog_v2` | RLS bật, không có quyền cho client. Seed/điều chỉnh qua migration bởi DB owner. | `crop_key` PK; `seed_item_key` unique; level/XP không âm. |
| `bootstrap_new_player_v2()` | Chỉ `authenticated` gọi; user lấy từ `auth.uid()`. Không nhận save, user id, tiền hay item từ client. | Khóa hàng Auth user, từ chối nếu tồn tại `game_saves`; tạo canonical wallet 80 xu, 3 hạt cà rốt và 18 ô cỏ trong cùng transaction. Tạo lặp không nhân đôi do PK/ON CONFLICT. |
| `till_plot_v2(request_id, plot_index)` | Chỉ `authenticated` gọi; đọc/ghi farm state và idempotency ledger trong transaction. | Idempotency PK `(user_id,request_id)`; khóa ví/farm; chỉ mở ô theo XP; grass → tilled một lần; không thưởng tiền/XP. |
| `plant_crop_v2(request_id, plot_index, crop_key)` | Chỉ `authenticated` gọi; mọi user id, thời gian, tốc độ, XP, reward và tiến độ do DB quyết định. | Tiêu thụ một item seed, kiểm tra cấp/ô/trạng thái, lấy thời gian từ `game_global_config`, ghi `ready_at` theo DB clock, +2 XP, quest plant và idempotency response atomically. |

RLS của bảng wallet/inventory/farm/quest vẫn chỉ cho người chơi đọc hàng mình; không cấp DML trực tiếp. RPC là `SECURITY DEFINER` với `search_path` cố định và chỉ `authenticated` được EXECUTE. Owner/`service_role` vẫn là vai trò tin cậy; không đưa service key vào client. Revision chỉ tăng khi farm state thay đổi và chỉ dùng phát hiện xung đột.

**Giới hạn lát cắt:** chưa có mua hạt giống server-side, tưới, thu hoạch, cho ăn/thu sản phẩm vật nuôi, bán/chế biến/chợ, hay đồng bộ dữ liệu UI. `game_global_config` cung cấp thời lượng/crop multiplier nhưng mùa chưa áp dụng. Gieo hạt hiện tăng tiến độ quest ngày và XP trong canonical state, song bản game chưa đọc các giá trị này; chỉ dùng staging kiểm thử sau khi migration được người dùng áp dụng. Existing accounts có `game_saves` sẽ bị bootstrap từ chối cho tới khi chính sách reconciliation được phê duyệt.

### Kiểm thử staging cho migration 003

Dùng hai tài khoản test mới không có `game_saves` và không chứa dữ liệu người chơi thật. Lời gọi RPC người chơi phải dùng JWT của test user. Không dùng SQL Editor owner để giả lập `auth.uid()`.

1. Bootstrap tài khoản mới: kết quả đúng 80 xu, 3 `seed_carrot`, 18 ô; gọi lặp không cộng thêm.
2. Tạo trước một `game_saves` cho test user, gọi bootstrap: bị từ chối; hash/row save cũ không đổi.
3. Người chưa đăng nhập gọi ba RPC: bị từ chối.
4. Cuốc cùng ô hai lần với UUID khác nhau: lần hai bị từ chối; revision chỉ tăng một.
5. Gieo một hạt; gửi lại cùng UUID và payload: trả cùng kết quả, chỉ trừ 1 hạt, chỉ +2 XP, quest tăng một, revision tăng một.
6. Cùng UUID nhưng plot/crop khác hoặc operation khác: bị từ chối và không đổi state.
7. Hai thiết bị đồng thời gieo cùng ô bằng hai UUID: một giao dịch thành công, giao dịch kia bị từ chối; không tiêu seed đôi.
8. Hết hạt, sai crop, cây bị khóa, ô khóa hoặc ô chưa cuốc: request bị từ chối, số dư/kho/farm/quest không đổi.
9. Mất kết nối sau khi server commit rồi gửi lại cùng UUID: trả response đã lưu, không lặp hiệu ứng.
10. Kiểm tra `ready_at` dùng giờ server/config, đổi giờ thiết bị không đổi kết quả; revision xung đột không được dùng để xác nhận số dư hoặc vật phẩm.
11. Tài khoản A không đọc được row của B; authenticated/anon không thể ghi trực tiếp bảng canonical hoặc catalog; chỉ authenticated có EXECUTE RPC; không có EXECUTE cho PUBLIC/anon.
12. So sánh `game_saves` trước/sau migration và các lời gọi: không đổi; không đụng `s.collections`.

Sau khi người dùng áp dụng migration trên staging, dùng Postflight chỉ đọc để kiểm tra RLS, grants bảng, grants RPC và số lượng catalog. Chưa có kết quả staging cho migration 003.

```sql
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'crop_action_catalog_v2';

select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'crop_action_catalog_v2'
order by grantee, privilege_type;

select routine_name, grantee, privilege_type
from information_schema.role_routine_grants
where specific_schema = 'public'
  and routine_name in ('bootstrap_new_player_v2','till_plot_v2','plant_crop_v2')
order by routine_name, grantee, privilege_type;

select crop_key, seed_item_key, unlock_level, harvest_xp, enabled
from public.crop_action_catalog_v2 order by unlock_level, crop_key;
```

Kỳ vọng: catalog có RLS; không có grants bảng cho `anon`/`authenticated`; chỉ `authenticated` có EXECUTE trên ba RPC trong các role client; không có `PUBLIC`/`anon` EXECUTE; catalog có đúng 11 loại cây như migration. `postgres`/`service_role` có thể xuất hiện như vai trò đặc quyền. `relforcerowsecurity=false` chấp nhận được vì SECURITY DEFINER backend cần quyền owner; client vẫn bị giới hạn bởi quyền bảng và RPC.

### Rollback migration 003

Trước khi gọi RPC trên tài khoản staging, có thể gỡ tính năng dark-launch bằng cách thu hồi EXECUTE cho client và giữ nguyên dữ liệu. Không drop bảng/hàm/catalog nếu đã có canonical rows. Nếu migration lỗi trong transaction, PostgreSQL sẽ rollback DDL/seed theo transaction; trước khi chạy lại phải xác nhận object chưa tồn tại. Không rollback/xóa `game_saves` và không tự dọn canonical state.

## Migration 004 — tưới và thu hoạch cây (draft, chưa chạy)

Migration này phụ thuộc migration 003 đã được kiểm thử hành vi. Nó thêm `water_crop_v2` và `harvest_crop_v2`; hai hàm dùng chung logic nội bộ `apply_crop_plot_action_v2`, hàm nội bộ không được cấp EXECUTE cho client.

| RPC | Quyền và thay đổi atomic |
|---|---|
| `water_crop_v2(request_id, plot_index)` | `authenticated` EXECUTE. Chỉ tưới một cây chưa sẵn thu hoạch và chưa tưới; giảm 25% tổng thời gian trồng đã lưu theo timestamp server, đánh dấu watered, tăng revision. Không cộng xu/XP. |
| `harvest_crop_v2(request_id, plot_index)` | `authenticated` EXECUTE. Chỉ thu khi `ready_at <= transaction_timestamp()`; cộng 1 nông sản vào inventory, XP theo catalog × `xpMultiplier`, thưởng 30 xu mỗi cấp vừa lên, tăng quest harvest và đặt ô về tilled — cùng transaction. |

Cả hai RPC khóa request và farm row; request lặp cùng UUID/payload trả response cũ. UUID cũ dùng cho thao tác khác bị từ chối. Không dùng revision như xác thực tài nguyên. Hệ thống chỉ thay canonical state; game client và `game_saves` chưa thay đổi. Giờ tăng trưởng là thời gian đã ghi khi gieo; tưới/thu hoạch không dựa vào đồng hồ thiết bị.

**Rủi ro/giới hạn:** migration 003 và 004 chưa được chạy/kiểm thử hành vi end-to-end; không nên áp dụng 004 lên staging trước khi migration 003 behavior tests đạt. Mùa chưa tính vào tốc độ server-side; thao tác offline, `s.collections`, hình ảnh, UI, báo cáo nhiệm vụ NPC và luồng cũ chưa được nối/chuyển đổi. XP thu hoạch dùng catalog cây và hệ số XP cấu hình ở server. Không dùng thử trên tài khoản thật.

Preflight chỉ đọc:

```sql
select n.nspname as schema_name, c.relname as object_name, c.relkind
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('player_wallets','player_inventory','player_farm_state',
                    'player_daily_quests','economy_requests','crop_action_catalog_v2');

select p.oid::regprocedure as function_name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('apply_crop_plot_action_v2','water_crop_v2','harvest_crop_v2');
```

Khi đã được phép triển khai migration 004, các object đầu phải tồn tại, ba hàm mới chưa tồn tại. Postflight kiểm tra `authenticated` có EXECUTE chỉ trên hai wrapper; không có EXECUTE cho `anon`/`PUBLIC` hoặc quyền bảng ghi trực tiếp.

Test cases bắt buộc trước khi nối client:

1. Tưới hợp lệ giảm đúng 25% thời lượng gốc, đổi `watered` và revision một lần; lặp cùng request UUID không giảm thêm.
2. Tưới cây đã tưới, đã chín, plot rỗng/invalid, crop disabled hoặc farm chưa bootstrap: bị từ chối, không đổi state.
3. Thu trước `ready_at`: bị từ chối; đổi đồng hồ thiết bị không ảnh hưởng.
4. Thu sau `ready_at`: đúng một nông sản, XP, level coin và progress quest harvest; plot trở về tilled; lặp request không cộng lần hai.
5. Hai session thu đồng thời cùng plot bằng hai UUID: chỉ một thành công.
6. Mất mạng sau commit rồi retry cùng UUID trả kết quả cũ; cùng UUID gọi action khác bị từ chối.
7. Auth/RLS: unauthenticated không EXECUTE; user A không đọc dữ liệu user B; authenticated không DML bảng.
8. Transaction rollback khi lỗi phải để nguyên inventory, wallet, farm và quest.

Rollback ứng dụng: thu hồi EXECUTE của `authenticated` khỏi hai wrapper và không gọi từ client; giữ hàm/bảng và dữ liệu để điều tra. Không drop ledger/state nếu đã có dữ liệu.

## Migration 005 — mua hạt giống và thức ăn (draft, chưa chạy)

Phụ thuộc migrations 001-004, `crop_action_catalog_v2` và `game_global_config`. Bổ sung giá hạt giống server-side vào catalog, không cấp client quyền bảng, và thêm hai RPC:

| RPC | Quyền và transaction |
|---|---|
| `buy_seed_v2(request_id, crop_key, quantity)` | Chỉ `authenticated` EXECUTE. Số lượng 1–99; catalog quyết định item/giá/cấp; khóa wallet; kiểm tra đủ xu; trừ xu và cộng `seed_*` inventory atomically. |
| `buy_animal_feed_v2(request_id, animal_key, quantity)` | Chỉ `authenticated` EXECUTE. Loài phải là chicken/pig/cow/fish; giá lấy từ `game_global_config.feedPrice`; trừ xu/cộng đúng `feed_*` inventory atomically. |

RPC không nhận giá hoặc số dư từ client. `(user_id, request_id)` chống retry; fingerprint chứa loại hàng, key và số lượng. Retry sau commit trả response đã lưu kể cả khi giá/config sau đó đổi. UUID dùng lại cho payload khác bị từ chối. Bảng canonical vẫn chỉ SELECT own đối với client; catalog không cấp quyền client. Không sửa save cũ; giao diện shop legacy chưa được chuyển sang RPC này.

Test staging bắt buộc trước khi nối client:

1. Hạt từng loại mua đúng giá server/catalog; item đúng `seed_<crop>`; cấp khóa, crop sai và số lượng ngoài 1–99 bị từ chối.
2. Mua thức ăn từng loài dùng đúng `feed_<animal>` và giá server; key khác bị từ chối.
3. Không đủ xu: ví, kho không đổi.
4. Cùng UUID/payload gửi lặp: chỉ trừ một lần/cộng một lần; cùng UUID nhưng hàng hoặc số lượng khác bị từ chối.
5. Hai session mua đồng thời: số xu không âm; tổng trừ/cộng đúng theo thứ tự khóa.
6. Timeout sau commit rồi retry trả response cũ; rollback/error không để lại thay đổi ví/kho.
7. Unauthenticated không EXECUTE; authenticated không DML trực tiếp; user A không thể đọc hàng B; không lộ giá catalog qua bảng/RPC khác.

Postflight cần xác nhận `crop_action_catalog_v2.seed_price` có đủ giá dương cho 11 cây; không có client table grants cho catalog; `authenticated` có EXECUTE trên hai RPC mới, không có `anon`/`PUBLIC` EXECUTE. Giữ quyền owner/service role như trước.

Rollback dark-launch: thu hồi EXECUTE khỏi hai RPC và dừng gọi từ client. Không xóa giá/catalog/state nếu đã có giao dịch. Migration chưa chạy; chưa có kết quả test.

## Migration 006 — mua, cho ăn và thu hoạch vật nuôi (draft, chưa chạy)

Migration này phụ thuộc migrations 001-005 đã được duyệt và kiểm thử hành vi. Nó tạo `animal_variant_catalog_v2` với các mã/giá/level mở khóa tương ứng các lựa chọn đang hiển thị trong cửa hàng. Catalog bật RLS và không cấp quyền đọc/ghi trực tiếp cho `anon`/`authenticated`. Không có thay đổi trong `game_saves`, không import số lượng vật nuôi cũ và không nối client.

| RPC | Quyền và kết quả trong một transaction |
|---|---|
| `buy_animal_v2(request_id, variant_id)` | Chỉ `authenticated` EXECUTE. Server chọn giá, loài và level từ catalog; trừ xu, cộng đúng một biến thể vật nuôi trong `player_farm_state`; tối đa 8 con mỗi loài. |
| `feed_animal_v2(request_id, animal_key)` | Chỉ `authenticated` EXECUTE. Khấu trừ đúng một thức ăn cho mỗi con hiện có; ghi `fed_at`, `ready_at`, `batch_count` bằng giờ/cấu hình server; cộng XP và tăng một tiến độ nhiệm vụ ngày `feed`. |
| `collect_animal_v2(request_id, animal_key)` | Chỉ `authenticated` EXECUTE. Chỉ nhận sau `ready_at`; thêm đúng `batch_count` sản phẩm (`eggs`, `pork`, `milk`, `fish`) vào kho, cộng XP và xóa chu kỳ sản xuất. |

`buy_animal_v2` cập nhật số lượng theo `animals.<species>.count` và số lượng biến thể theo `animals.<species>.variants.<variant_id>`. Khi mua trong lúc sản phẩm đang chờ, `fed_at`/`ready_at`/`batch_count` được giữ nguyên; lứa đang xử lý chỉ tính số con tại lúc cho ăn. Cấu trúc này dùng JSON canonical đã có trong migration 003; chưa tạo bảng riêng cho từng con vật.

Các hàm khóa lần lượt request, ví, farm rồi inventory khi cần. `economy_requests` có khóa chính `(user_id,request_id)`; cùng UUID/payload trả phản hồi đã lưu, cùng UUID payload khác bị từ chối. Toàn bộ cấp phát xu, thức ăn, hàng hóa, XP, quest và farm state nằm cùng transaction. Quyết định chỉ do server: giá, unlock level, sức chứa, thời gian, số con trong lứa, sản phẩm, XP và thời điểm hoàn tất. Client chỉ truyền UUID, mã biến thể hoặc loài; không truyền số dư, giá, lượng thưởng hay thời gian.

### Preflight và postflight chỉ đọc

Trước khi xem xét áp dụng, xác nhận migration 001-005 đã có trong migration history staging; các tên bên dưới chưa tồn tại; và không có client grants bất ngờ. Không chạy migration nếu trạng thái khác dự kiến.

```sql
select n.nspname as schema_name, c.relname as object_name, c.relkind
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('animal_variant_catalog_v2');

select p.oid::regprocedure as function_name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('buy_animal_v2','apply_animal_action_v2','feed_animal_v2','collect_animal_v2');
```

Postflight sau khi được duyệt và chạy migration phải xác nhận bảng catalog bật RLS, không có `anon`/`authenticated` grants, và chỉ ba wrapper có EXECUTE cho `authenticated`. `apply_animal_action_v2` không được executable bởi client; không có EXECUTE cho `PUBLIC`/`anon`. Số biến thể catalog cần là 22, với loài/giá/level khớp cửa hàng hiện tại.

### Kiểm thử hành vi bắt buộc trước khi nối client

1. Mua từng biến thể ở đúng giá; level chưa mở khóa, xu thiếu, mã lạ/disabled và sức chứa 8 bị từ chối mà ví/farm không đổi.
2. Mua hai con cùng biến thể tăng count và variant count mỗi lần một; hai thiết bị mua đồng thời tại sức chứa 7 chỉ một request đạt count 8.
3. Gửi lại cùng request sau commit trả response cũ; cùng UUID với biến thể/loài/action khác bị từ chối.
4. Cho ăn tiêu thụ chính xác số thức ăn bằng số con; thiếu dù một phần thì ví/kho/farm/quest/XP không đổi. Loài không có con không thể ăn.
5. `ready_at` theo database clock và cấu hình; đồng hồ client không thể đẩy nhanh. Cho ăn lặp khi chu kỳ đang chạy bị từ chối.
6. Mua thêm con giữa lúc đang chờ thu không đổi `ready_at` hoặc `batch_count`; thu lứa chỉ cấp số sản phẩm đã chụp lúc cho ăn.
7. Thu trước hạn bị từ chối; thu sau hạn cấp đúng sản phẩm, XP và xóa chu kỳ một lần. Retry sau timeout trả kết quả đã commit, không cấp thêm.
8. Hai thiết bị cùng thu một lứa bằng UUID khác nhau: chỉ một thành công. Mất mạng trước commit không để sót thay đổi một phần.
9. Auth/RLS: không đăng nhập hoặc user khác không thể gọi thay chủ; không thể đọc catalog/tài khoản khác hoặc ghi trực tiếp các bảng canonical.
10. Thất bại quest/config/inventory giữa xử lý phải rollback cả wallet, inventory, farm, XP, quest và request ledger.

### Rủi ro và rollback

- Migration 006 là draft; chưa chạy, chưa được PostgreSQL kiểm tra và chưa có postflight/behavior test. Không áp dụng staging hoặc production lúc này.
- Mùa vụ hiện tại là ngày/ mùa giả lập phía client. Chu kỳ server dùng giây thực và cấu hình `animalHarvestSeconds`/`animalTimeMultiplier`; chưa mô phỏng hệ số mùa để tránh tin `day` từ client. Cần quyết định cách chuyển quy tắc mùa trước khi nối giao diện.
- Các account legacy chưa có canonical farm/animal counts; migration không chuyển đàn cũ. Bootstrap 003 hiện chỉ cho account không có `game_saves`.
- Bán sản phẩm, giá bán theo loại, chăm sóc offline và mô phỏng di chuyển vật nuôi chưa thuộc migration này. Không tuyên bố các luồng đó đã được chuyển sang server.
- Rollback dark-launch: thu hồi EXECUTE của `authenticated` khỏi ba wrapper và dừng gọi từ client; giữ catalog/ledger/state nếu đã có dữ liệu. Không drop dữ liệu canonical hay sửa `game_saves`.

## Migration 007 — điểm danh hằng ngày (draft, chưa chạy)

Migration này chỉ phụ thuộc bảng canonical từ migration 001: `player_wallets`, `player_inventory`, `economy_requests`, `reward_claims`, cùng tài khoản Supabase Auth. Nó không phụ thuộc hay chờ migration 004-006; tuy vậy vẫn phải kiểm thử migrations đã chạy trên staging trước khi bật thêm một luồng thưởng. Không sửa `game_saves` và không nối UI.

Thêm hai bảng server-owned:

| Bảng | Quyền/RLS | Khóa và trường server quyết định |
|---|---|---|
| `daily_checkin_catalog_v2` | RLS bật; không cấp quyền cho `anon`/`authenticated`; chỉ migration/role quản trị cập nhật | PK `cycle_day` (1–7); xu, XP, item và số lượng do catalog quyết định. |
| `player_daily_checkins_v2` | RLS bật; không cấp quyền đọc/ghi trực tiếp client; đọc trạng thái qua RPC | PK `(user_id,checkin_date)`, UNIQUE `(user_id,request_id)`, FK tới Auth và economy request; lưu snapshot phần thưởng đã trao. |

Catalog khởi tạo 7 ngày lặp lại: xu/XP tăng dần, ngày 3 tặng hạt cà rốt, ngày 5 tặng thức ăn gà, ngày 7 tặng thêm 3 hạt cà rốt. Mất một ngày thì chuỗi trở về ngày 1. Giá trị này chỉ là cấu hình ban đầu; chỉnh catalog sau cần quyền vận hành server. Không có phần thưởng lịch sử được backfill.

| RPC | Quyền và tác động |
|---|---|
| `get_my_daily_checkin_v2()` | Chỉ `authenticated` EXECUTE; đọc ngày HCM hiện tại, phần thưởng/claim status; không ghi tiến độ hoặc trao thưởng. |
| `claim_daily_checkin_v2(request_id)` | Chỉ `authenticated` EXECUTE; lấy ngày từ DB theo `Asia/Ho_Chi_Minh`, khóa ví tài khoản để tuần tự hóa thiết bị đồng thời, trao snapshot reward và ghi request/domain claim trong transaction. |

RPC không nhận ngày, chuỗi, cấp thưởng, item, số lượng, xu hoặc XP từ client. Cùng request UUID trả response đã lưu. Hai thiết bị dùng UUID khác nhau cùng claim trong cùng ngày: request đầu trao, request sau nhận `already_claimed=true` và không trao lần nữa. Mỗi lần đăng nhập không tự trao; chỉ claim do người chơi xác nhận mới có tác động.

### Preflight/postflight và kiểm thử

Preflight chỉ đọc, kiểm tra object mới chưa tồn tại và các bảng nền tảng từ 001 đã có. Postflight cần xác nhận hai bảng bật RLS, không có client table grants, và chỉ hai RPC công khai cho `authenticated`; không có `PUBLIC`/`anon` EXECUTE.

Kiểm thử staging trước khi nối UI:

1. Ngày đầu nhận đúng catalog ngày 1; nhận lại cùng UUID trả cùng response; UUID khác cùng ngày không cộng thêm xu/XP/item.
2. Hai thiết bị claim đồng thời: đúng một phần thưởng; cả hai kết quả thống nhất trạng thái claim.
3. Ngày liên tiếp tăng chuỗi, ngày bị bỏ qua đặt lại ngày 1, ngày 7 quay về ngày 1; mọi phép tính dùng ngày DB HCM, không ảnh hưởng đồng hồ client.
4. Mất mạng sau commit rồi retry cùng UUID trả kết quả cũ; lỗi trước commit để ví, kho, check-in, ledger và request response rollback toàn bộ.
5. Tài khoản thiếu canonical wallet bị từ chối; item reward cộng đúng kho; XP có thể lên cấp và cộng level-up xu theo quy tắc hiện tại.
6. User chưa đăng nhập không thể gọi RPC; user không thể đọc/sửa catalog, bảng check-in hoặc tài khoản người khác.
7. Tắt reward catalog cho ngày cần claim: request thất bại mà không ghi check-in hoặc phát thưởng.

Rollback dark-launch: thu hồi EXECUTE khỏi hai RPC và không gọi chúng từ client. Nếu chưa có claims, có thể gỡ code migration trong staging reset được; nếu có dữ liệu, giữ bảng/ledger và không xóa check-in hay hoàn tác phần thưởng bằng cách sửa ví thủ công. Chưa chạy, chưa kiểm thử cú pháp/hành vi và chưa xác minh staging/production.

## Migration 008 — đơn hàng nông sản hằng ngày (draft, chưa chạy)

Phụ thuộc migrations 001 và 003, bảng `crop_action_catalog_v2`, và `game_global_config`. Không phụ thuộc schema của các bản nháp 004-007. Mặc dù phụ thuộc ít hơn, không áp dụng trước khi đã có tài khoản staging chuyên dụng và hành vi migration nền tảng đã được kiểm tra.

`daily_order_catalog_v2` là catalog server-only với vật phẩm có thể giao, số lượng, XP, cấp mở khóa và hệ số xu. `player_daily_orders_v2` giữ ba đơn/người/ngày HCM, với khóa chính `(user_id,order_date,slot_no)` và unique `(user_id,order_date,item_key)` để không có hai đơn trùng mặt hàng trong cùng ngày. RLS bật và không cấp quyền bảng trực tiếp cho client. Các trường item/quantity/reward/status/fulfilled_at do server quyết định.

`get_my_daily_orders_v2()` chỉ cho `authenticated` EXECUTE; hàm gán tối đa ba đơn ổn định trong ngày dựa trên user/date/slot và cấp hiện tại. Giá bán được đọc từ config server lúc tạo đơn và nhân hệ số thưởng 1.25 của catalog; XP nhân `xpMultiplier`. Các đơn đã gán không đổi giữa ngày nếu giá/admin config đổi. Mỗi ngày mới tạo bộ mới; đơn cũ hết hạn theo ngày nhưng được giữ làm lịch sử.

`fulfill_daily_order_v2(request_id,slot)` khóa theo thứ tự request, ví, đơn, kho; kiểm tra đủ hàng; trừ kho; cộng xu/XP/level-up; đánh dấu giao; ghi economy request và reward claim cùng transaction. Hai request UUID khác nhau cùng giao một đơn: chỉ lần đầu nhận thưởng; lần sau trả `already_fulfilled`. Thiếu kho thì toàn bộ transaction rollback. Không nhận order ID, item, quantity, giá hoặc phần thưởng từ client.

Preflight/postflight chỉ đọc:

```sql
select n.nspname as schema_name, c.relname as object_name, c.relkind
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('daily_order_catalog_v2','player_daily_orders_v2');

select p.oid::regprocedure as function_name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('get_my_daily_orders_v2','fulfill_daily_order_v2');
```

Postflight cần xác nhận hai bảng bật RLS, không có `anon`/`authenticated` table grants, và hai RPC chỉ executable bởi `authenticated`; không có `PUBLIC`/`anon` execute.

Kiểm thử staging trước khi nối client:

1. Gọi board nhiều lần/cùng lúc trên hai thiết bị tạo đúng ba đơn, không trùng mặt hàng, ổn định trong ngày; ngày HCM mới tạo bộ mới.
2. Cấp khóa: không xuất hiện đơn có level lớn hơn người chơi; vật phẩm/giá config thiếu hoặc catalog rỗng làm board fail mà không có đơn một phần.
3. Giao đủ hàng giảm đúng lượng, cộng đúng xu/XP/level bonus và lưu một reward claim; lần lặp cùng request trả response cũ.
4. Hai thiết bị giao cùng slot với UUID khác nhau: tối đa một lần trừ kho/trao xu; request sau trả already fulfilled.
5. Kho thiếu dù một món, slot sai, user chưa xác thực, ngày cũ hoặc request UUID tái dùng sai payload: không có thay đổi kinh tế.
6. Mất mạng sau commit rồi retry cùng UUID không giao hàng lần hai; lỗi bất kỳ giữa debit, credit, order status hoặc ledger rollback mọi thay đổi.
7. User A không đọc/sửa orders của B; authenticated không có DML trực tiếp; catalog không đọc trực tiếp được.

Rollback dark-launch: thu hồi EXECUTE khỏi hai RPC và không gọi client. Giữ daily order history, catalog và ledger nếu đã được dùng; không đảo giao dịch qua SQL thủ công. Chưa chạy, chưa kiểm thử cú pháp/hành vi và chưa xác minh staging/production.

## Migration 009 — chuỗi nhiệm vụ tuần (draft, chưa chạy)

Migration này phụ thuộc migration 001 (`player_wallets`, `economy_requests`, `reward_claims`) và xác thực Supabase Auth. Nó không phụ thuộc bảng farm hoặc bất kỳ migration gameplay nào khác. Tiến độ chỉ xuất hiện khi các RPC hành động an toàn được dùng; dữ liệu save cũ và `s.collections` không được nhập.

Tạo `weekly_quest_catalog_v2` server-only và `player_weekly_quests_v2` có RLS, SELECT own và không có DML client. Khóa chính player state là `(user_id,week_start,quest_id)`; ngày bắt đầu tuần là thứ Hai theo `Asia/Ho_Chi_Minh`. Reward/target được snapshot khi khởi tạo tuần. Catalog là chuỗi bốn bước: gieo 8 cây, thu 6 cây, cho ăn 3 lần, hoàn thành 3 đơn.

Progress không nhận event từ client: `refresh_my_weekly_quests_internal_v2()` đếm các dòng `economy_requests` đã hoàn tất và response thành công từ RPC `plant_crop_v2`, `harvest_crop_v2`, `feed_animal_v2`, `fulfill_daily_order_v2`. Mỗi bước sau chỉ đếm event xảy ra từ lúc bước trước được claim; bước sau bị khóa tới khi claim bước trước. Các loại hành động chưa được chuyển lên server sẽ chưa tạo tiến độ tương ứng.

| RPC | Quyền và tác động |
|---|---|
| `get_my_weekly_quests_v2()` | Chỉ `authenticated` EXECUTE; khóa ví để đồng bộ, làm mới tiến độ từ ledger server, trả trạng thái chuỗi tuần hiện tại. |
| `claim_weekly_quest_v2(request_id,quest_id)` | Chỉ `authenticated` EXECUTE; khóa request/ví/quest, làm mới tiến độ, buộc claim bước trước, trao xu/XP/level-up bonus và ghi reward claim nguyên tử. |
| `refresh_my_weekly_quests_internal_v2()` | Không cấp EXECUTE cho client; helper nội bộ. |

Test staging bắt buộc trước khi nối UI:

1. Tuần luôn bắt đầu thứ Hai HCM; thời điểm UTC gần nửa đêm quy về đúng ngày HCM; không nhận tuần/ngày từ client.
2. Tiến độ chỉ tăng từ ledger có `completed_at` và response thành công; request chưa hoàn tất/không thành công hoặc thao tác client giả không được tính.
3. Tiến độ từng bước bị giới hạn target; bỏ qua bước trước thì bước sau khóa; event trước khi claim bước trước không được tính cho bước kế tiếp.
4. Đạt target rồi claim đúng xu/XP/level-up; claim lặp cùng UUID trả kết quả cũ; UUID khác không thể nhận lại.
5. Hai thiết bị claim đồng thời cùng quest chỉ được thưởng một lần; request thứ hai nhận `already_claimed`.
6. Request thiếu quyền, user khác, wallet chưa canonical, quest sai/tắt hoặc chưa đạt target không làm thay đổi ví/quest/ledger.
7. Mất mạng sau commit rồi retry không cộng lần hai; lỗi giữa wallet/claim/request ledger rollback toàn bộ.

Preflight/postflight chỉ đọc: xác nhận các bảng mới chưa tồn tại trước migration; sau migration xác nhận RLS, SELECT chỉ dữ liệu của chính user, không có table DML grants, và chỉ hai RPC public có EXECUTE cho authenticated. `refresh_my_weekly_quests_internal_v2` không được executable bởi client. Migration chưa chạy/kiểm thử; không chạy trước khi staging behavior tests cho nền tảng đạt.

```sql
select n.nspname as schema_name, c.relname as object_name, c.relrowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('weekly_quest_catalog_v2','player_weekly_quests_v2');

select p.oid::regprocedure as function_name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('refresh_my_weekly_quests_internal_v2',
                    'get_my_weekly_quests_v2','claim_weekly_quest_v2');
```

Rollback dark-launch: thu hồi EXECUTE của `authenticated` khỏi hai RPC public và dừng gọi từ client. Giữ catalog/progress/claim ledger nếu đã có dữ liệu; không drop reward history và không đụng `game_saves`.

## Migration 010 — thành tích (draft, chưa chạy)

Phụ thuộc migration 001 (`player_wallets`, `economy_requests`, `reward_claims`) và Supabase Auth. Không đọc hoặc chuyển đổi `s.collections`/legacy save. Tạo `achievement_catalog_v2` server-only và `player_achievements_v2` với RLS bật, SELECT own, không có DML client. PK player progress `(user_id,achievement_id)` đảm bảo một unlock/claim cho mỗi thành tích.

Tiến độ được tính từ cấp trong ví canonical hoặc các `economy_requests` đã hoàn tất với response thành công (`plant_crop_v2`, `harvest_crop_v2`, `feed_animal_v2`, `fulfill_daily_order_v2`). Catalog mẫu gồm gieo trồng, thu hoạch, cho vật nuôi ăn, giao đơn và đạt cấp. Tiến độ lưu theo max để không giảm; `unlocked_at` và `claimed_at` chỉ do server đặt. Migration thêm index theo user/operation/completed time để query ledger không quét toàn bảng.

`get_my_achievements_v2()` refresh và đọc tiến độ; `claim_achievement_v2(request_id,achievement_id)` xác nhận unlocked ở server, trao xu/XP/level-up và ghi `reward_claims` cùng transaction. Hai RPC chỉ cấp EXECUTE cho `authenticated`; helper không cấp quyền client. Request UUID chặn retry và reward domain key `('achievement','once',achievement_id)` chặn claim bằng UUID khác.

Kiểm thử staging bắt buộc:

1. Legacy `s.collections`/save không mở hoặc trao thành tích; chỉ hoạt động server requests sau cutover.
2. Các action thành công tăng tiến độ đúng một lần; response lỗi/không hoàn tất và request retry không tăng thêm.
3. Level achievement căn cứ `player_wallets.xp`; client không thể gửi progress/level/reward.
4. Khi đủ target mở khóa; trước đó claim bị từ chối mà ví không đổi.
5. Claim hợp lệ cộng đúng xu/XP/level-up; cùng UUID retry và UUID khác claim lại không phát lần hai.
6. Hai thiết bị claim đồng thời chỉ một giao dịch; lỗi giữa ví, achievement, request và reward ledger rollback toàn bộ.
7. Unauthenticated không EXECUTE; user A không đọc/sửa dữ liệu B; authenticated không DML trực tiếp catalog/progress.
8. Với lượng ledger lớn, xác nhận index được dùng; phải có chính sách retention/archival trước khi xóa `economy_requests`, nếu không thành tích chưa snapshot có thể không tính đủ lịch sử.

Preflight/postflight chỉ đọc: các tên bảng/function chưa tồn tại trước khi chạy; sau chạy xác nhận RLS, grants, hai RPC authenticated-only, helper internal không client EXECUTE, và index action-ledger có mặt. Rollback dark-launch: thu hồi EXECUTE khỏi hai RPC; giữ bảng và reward ledger nếu đã có dữ liệu. Chưa chạy, chưa kiểm thử và chưa xác minh staging/production.

## Migration 011 — sổ sưu tập (draft, chưa chạy)

Phụ thuộc migrations 001, 003, 006 để có canonical request ledger, crop catalog và animal variant catalog. `collection_catalog_v2` mô tả 11 cây, 22 biến thể vật nuôi và 4 sản phẩm. `player_collections_v2` lưu lần đầu phát hiện với PK `(user_id,collection_id)` và FK tới đúng server request làm nguồn. Hai bảng bật RLS; authenticated chỉ SELECT hàng của mình ở bảng người chơi; catalog không đọc trực tiếp. RPC `get_my_collection_v2()` là API đọc duy nhất và helper refresh không cấp EXECUTE cho client.

Mở khóa sưu tập dựa trên RPC thành công sau `activated_at`: thu hoạch cây, mua biến thể vật nuôi, thu sản phẩm vật nuôi. Các hành động trước thời điểm kích hoạt, kể cả dữ liệu staging có thật, không được backfill. `s.collections` không bị đọc/ghi/chuyển đổi. Sổ sưu tập chỉ ghi nhận; không tự trao xu, XP, vật phẩm hay phần thưởng hồi tố.

Test staging trước khi nối UI:

1. Event server thành công sau kích hoạt mở đúng mục; event lỗi, chưa hoàn tất, request giả hoặc trước thời điểm kích hoạt không mở.
2. Mở/refresh nhiều lần không tạo bản ghi trùng hoặc thay đổi `discovered_at`/nguồn ban đầu.
3. User A không thể đọc dữ liệu B; client không DML catalog/player table; helper không executable bởi client.
4. Gọi RPC không phát thưởng và không thay đổi `s.collections`, wallet, inventory hay farm state.
5. Variant/catalog thiếu hoặc tên action response thay đổi phải được báo lỗi kiểm tra trước rollout thay vì âm thầm đánh dấu sai.

Preflight/postflight chỉ đọc: xác nhận hai bảng/function mới chưa tồn tại trước khi áp dụng; sau đó RLS bật, không có client table writes, chỉ `get_my_collection_v2()` có EXECUTE cho authenticated. Rollback dark-launch: thu hồi EXECUTE và dừng gọi từ UI; giữ các phát hiện đã ghi, không xóa/nhập ngược vào `s.collections`. Chưa chạy hoặc kiểm thử.

## Migration 012 — sửa thứ tự khóa claim nhiệm vụ ngày (draft, chưa chạy)

Migration 002 đã được chạy trên staging theo kết quả bạn gửi. Rà soát tổng hợp cho thấy hàm cũ khóa hàng quest trước ví, trong khi action RPC khóa ví rồi mới cập nhật quest. Hai luồng đồng thời có thể deadlock; PostgreSQL sẽ rollback một giao dịch, nhưng đây là điều nên sửa trước khi tăng tải.

Migration 012 dùng `CREATE OR REPLACE` cho `claim_daily_quest_v2`, giữ nguyên chữ ký/quyền và chính sách thưởng, nhưng đồng nhất thứ tự khóa `request -> wallet -> quest`. Payload hash không chứa ngày do server tự chọn để retry cùng UUID qua nửa đêm vẫn trả đúng kết quả ban đầu. Nếu quest đã claim bằng request UUID khác, trả `already_claimed` mà không cộng lần hai.

Test staging sau phê duyệt: claim song song với plant/harvest/feed; hai thiết bị claim cùng quest; cùng request retry qua ngày đổi; request UUID dùng lại cho quest khác; thiếu wallet/progress chưa đủ; kiểm tra toàn bộ trường kinh tế, quest, request và reward ledger sau commit/rollback. Migration draft; chưa chạy và chưa kiểm thử.

## Rollout tổng hợp đã soạn cục bộ

Theo kết quả bạn đã gửi, staging hiện có migrations 001-003 và đã bật các RPC/table đó; không có kết quả behavior test. Migration 004-012 đều là draft cục bộ, chưa chạy. Chúng được tách transaction để có thể chẩn đoán/rollback feature gate, nhưng không nên dán chạy thành một lần trước khi test prerequisites:

1. Kiểm thử hành vi 001-003 trên tài khoản staging chuyên dụng.
2. Áp dụng 012 để sửa RPC quest đã triển khai trước khi tăng số action RPC; kiểm tra quyền và retry.
3. Xét 004-006 (tưới/thu hoạch, mua hạt/thức ăn, mua/cho ăn/thu vật nuôi), từng migration cùng behavior tests.
4. Sau khi action RPC đạt, xét 007-011 (điểm danh, orders, weekly, achievements, collection) theo nhóm phụ thuộc và kiểm thử cạnh tranh/retry.
5. Chỉ sau khi staging đạt mới lên lịch nối web/Android; hiện client và production chưa được sửa/xác minh.

Các bước trên là hàng rào vận hành, không phải xác nhận chạy migration. Không có migration nào trong 004-012 được chạy bởi Codex.
