# Chợ người chơi

Chợ giao dịch dùng chung giữa các tài khoản đã đăng nhập và đồng bộ với Supabase. Người chơi có thể đăng bán nông sản, sản phẩm vật nuôi và món chế biến; người bán chọn số lượng và giá từng món. Người mua trả bằng xu trong game. Gỡ tin đang bán sẽ hoàn vật phẩm về túi.

## Bật chợ trên Supabase

1. Mở Supabase Dashboard của dự án game.
2. Vào **SQL Editor**.
3. Mở `supabase-marketplace.sql`, dán toàn bộ nội dung vào một truy vấn mới và nhấn **Run**.
4. Tải lại game. Người chơi cần đăng nhập và đồng bộ save cloud để giao dịch.

Các RPC kiểm tra tài khoản, tồn kho, số xu và trạng thái tin bán ở máy chủ. Việc trừ xu, chuyển vật phẩm và trả xu cho người bán nằm trong cùng giao dịch cơ sở dữ liệu.
