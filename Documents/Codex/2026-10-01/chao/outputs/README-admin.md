# Trang quản trị chung Vườn Nhỏ

## Thiết lập Supabase một lần

1. Mở **Supabase → SQL Editor** và chạy toàn bộ `supabase-admin-config.sql`. Nếu đã cài bản admin cũ, chạy lại toàn bộ file này để thêm cấu hình riêng từng loại.
2. Đăng ký/đăng nhập trong game bằng email sẽ làm quản trị viên.
3. Trong SQL Editor chạy câu lệnh bootstrap ở cuối `supabase-admin-config.sql`, thay email mẫu bằng email tài khoản quản trị của bạn.
4. Đưa các thay đổi lên GitHub/Vercel. Trang sẽ có tại `/admin.html`; trong game, mục **Quản trị** chỉ hiện sau khi xác thực quyền admin.

Cấu hình được lưu ở bảng riêng, không ghi vào save của người chơi. Khách và tài khoản đều tải cấu hình chung khi mở game; phiên đang chơi làm mới định kỳ khoảng mỗi phút. Chỉ RPC có kiểm tra `game_admins` mới có quyền ghi. Không đặt service-role key trong HTML.

## Các thiết lập hiện có

- Hệ số thời gian phát triển cây.
- Hệ số thời gian tạo sản phẩm vật nuôi.
- Thời gian thu hoạch riêng cho từng cây và từng khu vật nuôi.
- Giá bán riêng cho từng loại cây và sản phẩm vật nuôi.
- Hệ số giá bán chung, được nhân thêm sau giá riêng.
- Hệ số XP.
- Giá thức ăn.
- Thông báo chung trong game.


Câu lệnh cấp quyền admin (chạy trong SQL Editor sau khi đăng ký tài khoản):

```sql
insert into public.game_admins (user_id)
select id from auth.users where lower(email) = lower('email-cua-ban@example.com')
on conflict (user_id) do nothing;
```
