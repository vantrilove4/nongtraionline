# Bảng xếp hạng Vườn Nhỏ

RPC `public.get_game_leaderboard_v2` chỉ xếp hạng tiến trình đã được máy chủ xác nhận.
Ví và XP đọc từ `player_wallets`; vật phẩm, hạt giống, thức ăn và đồ trang trí trong túi
đọc từ `player_inventory`; giống vật nuôi đọc từ `player_farm_state` cùng giá trong
`animal_variant_catalog_v2`. `game_saves` chỉ cung cấp tên vườn để hiển thị, không cung
cấp điểm số. Tài khoản chưa có tên vườn hiển thị ẩn danh là “Nhà vườn”.

## Cập nhật Supabase

1. Chạy `migrations/20261112_025_canonical_leaderboard_v3.sql` trong SQL Editor sau khi
   các bảng của migration 001, catalog vật nuôi migration 006 bảng cây ăn trái migration 019 và bảng `game_saves` đã có trên dự án.
2. Đây là migration chỉ thay định nghĩa RPC và quyền `EXECUTE`; không cập nhật/xóa dữ liệu
   người chơi và không sửa `game_saves`.
3. Không chạy file cũ `supabase-leaderboard.sql` song song. File này chỉ là bản sao tiện dụng
   của migration 025.

## Cách tính

- **Cấp**: XP máy chủ được quy đổi thành cấp; xếp theo cấp rồi XP.
- **Tài sản**: xu trong ví cộng giá quy đổi của vật phẩm, hạt giống, thức ăn, vật trang trí
  trong kho và vật nuôi đang sở hữu, cây ăn trái đang trồng và đồ trang trí đã đặt. Giá vật nuôi lấy từ catalog máy chủ; cây và trang trí dùng giá mua của cửa hàng.
- Dòng “xu” trong kết quả RPC giữ nguyên tên cột tương thích với giao diện cũ; khi chọn tab
  tài sản, giá trị đó là tổng tài sản quy đổi, không chỉ số dư xu.
- Hiển thị 20 hạng đầu và thêm hạng của người đang đăng nhập nếu nằm ngoài top 20.

Migration không tự chuyển save lịch sử hoặc trao tài sản theo dữ liệu không xác minh được.
