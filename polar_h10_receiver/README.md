# Polar H10 → CNN-LSTM trực tiếp

Chạy từ thư mục `fall-detection-sic-capstone`, bằng môi trường Python đã dùng train:

```sh
../.venv/bin/python polar_h10_receiver/udp_acc_receiver.py
```

Sender gửi UDP đến IP máy tính, port **5005**, mỗi mẫu theo định dạng
`timestamp,x_mg,y_mg,z_mg`. Một datagram có thể chứa nhiều dòng mẫu.
Timestamp phải tăng theo từng mẫu cảm biến; không dùng chung timestamp của một
batch cho tất cả mẫu. Sender nên giữ cùng socket/cổng nguồn trong phiên streaming.

Receiver mặc định dùng **100 frame/giây** theo cấu hình Polar được xác nhận.
Nó tự đọc `final_model.keras`, `scaler.pkl`, `metadata.pkl` trong
`saved_models_cnn_lstm/` (đường dẫn tính từ file script, không phụ thuộc cwd).
Các thư viện cần có trong môi trường: TensorFlow, NumPy, scikit-learn, joblib.

Pipeline: đổi mg → g → đổi trục `(X,Y,Z) = (Polar Y,-Polar X,-Polar Z)` →
gom 200 mẫu → transform bằng scaler đã xuất → tensor `(1,200,3)` → model.
Không fit lại scaler và không augmentation khi dự đoán. `window_size`, `window_step`,
thứ tự feature và threshold lấy từ metadata; hiện là **200 / 100 / 0.50**.
Lần đầu cần khoảng 2 giây dữ liệu, sau đó dự đoán mỗi giây.

Ví dụ định dạng kết quả (số minh họa):

```text
t=123456789 | FALL / NGA | P(fall)=0.8732 | inference=4.5ms
```

Các tùy chọn:

```sh
# Kiểm tra bộ artifact và warm-up inference, không mở UDP
../.venv/bin/python polar_h10_receiver/udp_acc_receiver.py --check-model

# In thêm gia tốc từng mẫu
../.venv/bin/python polar_h10_receiver/udp_acc_receiver.py --show-acc

# Khi đã xác nhận timestamp đơn vị ns (hoặc ms/us), bật kiểm tra gap/cadence
../.venv/bin/python polar_h10_receiver/udp_acc_receiver.py --timestamp-unit ns

# Ghi lại stdout của phiên thử nghiệm
../.venv/bin/python -u polar_h10_receiver/udp_acc_receiver.py | tee polar_session.log
```

Nhấn Ctrl+C để dừng. Mẫu lỗi, timestamp trùng hoặc đảo thứ tự bị bỏ qua. Sau 2 giây
không có mẫu hợp lệ, buffer và sender được reset. Mặc định chưa biết đơn vị timestamp
nên không phát hiện được mọi khoảng mất gói ngắn; dùng `--timestamp-unit` khi đã xác
nhận để reset nếu khoảng cách mẫu lệch quá 20% so với 0.01 giây. Code không resample;
sender phải thực sự chạy 100 Hz. `--timeout` cho phép đổi thời gian reset.

Phép đổi trục được giữ từ receiver cũ, trong đó dấu trục Z còn cần kiểm chứng thực
nghiệm. Vị trí đeo H10 và hướng trục so với cảm biến K-Fall có thể ảnh hưởng kết quả;
metrics LOSO K-Fall không phải kết quả kiểm chứng trên Polar trực tiếp.

Kiểm tra parser, cửa sổ, gap và inference với model thật:

```sh
../.venv/bin/python -m unittest discover -s polar_h10_receiver -v
```
