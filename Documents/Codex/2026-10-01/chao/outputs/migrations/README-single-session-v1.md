# Một phiên đăng nhập cho mỗi tài khoản

1. Mở Supabase Dashboard → SQL Editor và chạy toàn bộ `20261019_015_single_active_session_v1.sql` đúng một lần.
2. Chờ kết quả `Success`. Migration chỉ thêm bảng phiên hoạt động, quyền đọc có điều kiện và trigger kiểm tra phiên; không sửa hoặc xóa save hiện có.
3. Đưa `outputs/index.html` lên Vercel. Không cần đóng gói lại APK cho thay đổi web này.
4. Đăng nhập cùng tài khoản trên hai trình duyệt/thiết bị. Thiết bị đăng nhập trước sẽ tự thoát tài khoản trong tối đa khoảng 10 giây khi đang mở; khi mở lại tab sau thời gian nền, kiểm tra diễn ra ngay.

Phiên mới nhất được xác định từ `auth.sessions` của Supabase, không dùng đồng hồ thiết bị. Trạng thái phiên áp dụng cho tất cả người dùng đang có tài khoản trong dự án Supabase này. Nếu migration chưa chạy, bản web mới sẽ báo lỗi xác minh phiên và không đồng bộ tài khoản.

Rollback cần thiết kế và chạy riêng sau khi đánh giá trạng thái người chơi. Không xóa bảng phiên hoặc trigger trong lúc người chơi đang online; các thao tác này sẽ gỡ bảo vệ phiên đơn.
