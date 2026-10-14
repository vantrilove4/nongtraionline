# Bảng xếp hạng Vườn Nhỏ

Game đọc bảng xếp hạng từ các save đã đồng bộ trong `public.game_saves`.
Người chơi đặt tên vườn trong game; người chưa đặt tên sẽ có tên “Nhà vườn” ẩn danh.
RPC chỉ trả tên hiển thị và chỉ số công khai, không trả email, ID tài khoản hay
nội dung save riêng.

## Cài đặt Supabase

1. Mở Supabase Dashboard → **SQL Editor**.
2. Chạy `supabase-leaderboard.sql` sau khi đã tạo bảng `game_saves` bằng
   `supabase-game-saves.sql`.
3. Deploy lại game. Game gọi RPC có phiên bản mới `get_game_leaderboard_v2`, vì vậy
   hãy chạy lại file SQL sau bản cập nhật này trước khi deploy giao diện.

Hai bảng có chỉ số tách biệt:

- **Cấp**: điểm chính là Cấp, xếp theo cấp rồi XP. Dòng phụ chỉ hiện XP.
- **Vàng**: điểm chính là xu, xếp theo số xu. Dòng phụ hiện Cấp.

Bảng hiển thị 20 hạng đầu và thêm hạng của người đang đăng nhập nếu họ nằm ngoài
top 20. Tên vườn được lưu trong save nên đồng bộ cùng tài khoản giữa các thiết bị.

Save hiện được gửi từ trình duyệt nên các thứ hạng chưa có khả năng chống gian
lận; muốn xếp hạng cạnh tranh cần chuyển việc xác thực tiến độ sang máy chủ.
