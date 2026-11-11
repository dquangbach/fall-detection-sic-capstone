# Polar Fall App

Ứng dụng Flutter chạy trên **iPhone**, đọc gia tốc ACC trực tiếp từ cảm biến
Polar qua Bluetooth Low Energy (BLE), chia dữ liệu thành cửa sổ 200 mẫu rồi gửi
đến FastAPI trên Mac để suy luận bằng model CNN-LSTM.

App đọc **ACC XYZ** để thử nghiệm dự đoán té ngã và có chế độ **ECG riêng** để
hiển thị tín hiệu, lưu CSV trên iPhone. Chưa có phân loại AF trực tiếp trong app;
model AF thử nghiệm và quy trình xử lý nằm trong [ECG README](../../ecg/README.md).
Màn hình dự đoán té ngã là kết quả thử nghiệm của model,
không phải cảnh báo té ngã đã được kiểm định để dùng trong tình huống khẩn cấp.

## Luồng dữ liệu

```text
Polar H10
  │ BLE: ACC XYZ, timestamp
  ▼
Polar BLE SDK (Swift, iPhone)
  │ PolarBridge.swift
  │ Flutter MethodChannel / EventChannel
  ▼
Flutter (Dart)
  │ nhận mẫu → WindowBuffer: 200 mẫu, bước 100
  │ POST /predict, X-API-Key
  ▼
FastAPI trên Mac
  │ kiểm tra 200 mẫu và nhịp thời gian 100 Hz
  │ Polar milli-g → (Y, -X, -Z) g → scaler đã lưu
  ▼
final_model.keras → xác suất / ngưỡng → JSON về app
```

Polar SDK chỉ được gọi từ Swift trên iPhone. App không gọi UDP sender trong
Polar SDK: Swift bridge đưa ACC sang Dart, sau đó Dart gửi HTTP đến server.
Server dùng lại phần tiền xử lý và model của receiver hiện có. Xem thêm
[README server](../../server/README.md) và
[README receiver UDP](../../polar_h10_receiver/README.md).

## Các phần trong app

| File | Vai trò |
| --- | --- |
| `lib/main.dart` | Giao diện, trạng thái BLE, nhận event và điều phối dự đoán |
| `lib/window_buffer.dart` | Mẫu ACC và cửa sổ 200 mẫu, bước trượt 100 mẫu |
| `lib/fall_api.dart` | Tạo HTTP `POST /predict`, gửi API key và đọc kết quả |
| `ios/Runner/PolarBridge.swift` | Swift bridge: quét/kết nối Polar, bắt đầu/dừng ACC hoặc ECG, phát event sang Flutter và lưu ECG thô thành CSV |
| `ios/Runner/AppDelegate.swift` | Đăng ký native bridge với Flutter engine |
| `ios/Runner/Info.plist` | Quyền Bluetooth, quyền mạng nội bộ và background mode |
| `local_config.json` | Cấu hình URL/key truyền vào app khi chạy; file này bị Git bỏ qua |

## Điều kiện cần có

- Mac có Flutter và Xcode/Command Line Tools phù hợp với bản Flutter đang cài.
- iPhone thật, iOS 15 trở lên; simulator không đọc được cảm biến Polar BLE.
- Polar SDK nằm cạnh repository capstone theo cấu trúc sau:

  ```text
  AI Projects/
  ├── polar-ble-sdk/
  └── fall-detection-sic-capstone/
      └── apps/polar_fall_app/
  ```

- Xcode project tham chiếu local Swift package `../../../../polar-ble-sdk`.
  Checkout SDK hiện tại là `3d15da61dd0c63e6be2582d03fd80f6c7ba02e11`. Các chỉnh
  sửa UDP trong thư mục `examples/` của SDK là ví dụ riêng; app này gọi trực
  tiếp `PolarBleSdk` từ native bridge.
- Lần build iOS đầu tiên, Swift Package Manager cần tải các dependency Swift
  như `swift-protobuf` và `Zip` từ GitHub. Nếu đang ở mạng chậm/4G, bước resolve
  package có thể lâu hoặc thất bại; khi tải xong, mở lại workspace và build lại.

## Chạy toàn bộ pipeline

### 1. Khởi động server trên Mac

Mở Terminal thứ nhất, đứng ở gốc `fall-detection-sic-capstone`:

```sh
export FALL_API_KEY='tao-mot-key-rieng-it-nhat-16-ky-tu'
../.venv/bin/python -m uvicorn server.app:app --host 0.0.0.0 --port 8000
```

Giữ Terminal này mở. Server nạp `final_model.keras`, `scaler.pkl` và
`metadata.pkl` từ `saved_models_cnn_lstm/` lúc khởi động. Key trên server phải
trùng với key được truyền vào app.

Kiểm tra trên Mac:

```sh
curl http://127.0.0.1:8000/health
```

Kiểm tra trên iPhone Safari bằng địa chỉ LAN của Mac:

```text
http://<IP-cua-Mac>:8000/health
```

Hai thiết bị phải liên lạc được qua cùng mạng nội bộ hoặc Personal Hotspot.
Nếu IP Mac hiện tại vẫn là `172.20.10.3`, URL server dùng cho app là
`http://172.20.10.3:8000`. IP có thể đổi khi chuyển mạng; tìm IP đang hoạt động
trên Mac bằng `ipconfig getifaddr en0` hoặc trong System Settings → Wi-Fi.
Không dùng `localhost` trong app vì `localhost` trên iPhone trỏ về iPhone.

### 2. Cấu hình app trỏ về server

Mở Terminal thứ hai:

```sh
cd apps/polar_fall_app
cp local_config.example.json local_config.json
```

Sửa `local_config.json`:

```json
{
  "FALL_API_URL": "http://172.20.10.3:8000",
  "FALL_API_KEY": "cung-key-da-export-tren-server"
}
```

Thay IP bằng IP LAN hiện tại của Mac và thay giá trị key bằng đúng key đã
export ở Terminal server. `local_config.json` bị ignore; không commit key thật.
App đọc hai giá trị này lúc build/run qua `--dart-define-from-file`, nên sau khi
đổi cấu hình cần khởi động lại app.

### 3. Build và chạy trên iPhone

Trong `apps/polar_fall_app`:

```sh
flutter pub get
flutter devices
flutter run -d <iphone-device-id> --dart-define-from-file=local_config.json
```

Nếu `flutter` chưa nằm trong `PATH`, dùng đường dẫn cài Flutter trên Mac; ví dụ
trên máy phát triển này là `/Users/bach/flutter/bin/flutter` thay cho `flutter`.
Trong VS Code, mở đúng thư mục `apps/polar_fall_app`, chọn thiết bị iPhone và
launch configuration **Polar iPhone + FastAPI** rồi nhấn F5. Cấu hình đó đã
truyền `local_config.json` cho Flutter.

Nếu Xcode chọn nhầm Command Line Tools thay vì Xcode, có thể chọn Xcode trong
Xcode → Settings → Locations → Command Line Tools, hoặc chạy lệnh trong cùng
Terminal trước khi gọi Flutter:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Nếu cần chỉnh signing, mở `ios/Runner.xcworkspace` trong Xcode, chọn Team ở
Runner → Signing & Capabilities, rồi chọn iPhone thật. Mở khóa iPhone, bật
Developer Mode nếu iOS yêu cầu, và cho phép quyền Bluetooth/Local Network khi
app hỏi.

## Thao tác trên app

1. Đeo/bật Polar H10, bật Bluetooth iPhone và đặt cảm biến gần điện thoại.
2. Nhấn **Quét Polar**, chọn thiết bị trong danh sách.
3. Đợi trạng thái **Sẵn sàng đọc ACC/ECG**. Kết nối BLE xong chưa đồng nghĩa SDK đã
   sẵn sàng streaming; app chờ feature online streaming báo ready.
4. Nhấn **Bắt đầu ACC**. App yêu cầu SDK xác nhận cảm biến hỗ trợ ACC, đọc các
   sample setting được hỗ trợ, ưu tiên 100 Hz nếu có, rồi bắt đầu stream.
5. Kiểm tra XYZ, tần số và số cửa sổ trên màn hình. Ở 100 Hz, cửa sổ đầu tiên
   có sau khoảng 2 giây; sau đó có cửa sổ mới mỗi 1 giây.
6. Khi server trả kết quả, app hiển thị nhãn `fall`/`normal`, xác suất và ngưỡng
   lấy từ metadata model. Nhấn **Dừng ACC** để dừng stream; **Ngắt kết nối** để
   đóng phiên BLE.

Khi dừng, mất kết nối hoặc bắt đầu phiên mới, bộ đệm ACC được reset để cửa sổ
không trộn mẫu từ hai phiên. ACC chỉ nằm tạm trong bộ nhớ. ECG chạy riêng,
hiển thị sóng ngắn và ghi CSV trong Files → On My iPhone → Polar Fall App;
app chưa gửi ECG tới server. Dừng luồng ECG trước khi tháo cảm biến.

Để **chỉ thu ECG**, không cần khởi động FastAPI hay cấu hình API key: kết nối
Polar H10, đợi SDK báo sẵn sàng, nhấn **Bắt đầu ECG & lưu CSV**, rồi nhấn
**Dừng ECG** khi thu xong. File CSV có `device_timestamp_ns`, `voltage_uv`,
`sample_rate_hz`, `phone_received_at_utc`. Timestamp là thời gian do thiết bị
ghi cho từng mẫu; thời điểm nhận trên iPhone được ghi theo từng batch.

## Cửa sổ và giao tiếp với server

- Mỗi mẫu gồm `timestamp`, `x`, `y`, `z`. XYZ là số nguyên milli-g từ Polar,
  gồm cả trọng lực; timestamp SDK được giữ dạng chuỗi nanosecond kể từ
  `2000-01-01`.
- Cửa sổ đầu là mẫu 1–200, cửa sổ kế là 101–300, rồi 201–400. Vì vậy mỗi cửa
  sổ dài 2 giây và có 1 giây chồng lấp khi cảm biến chạy 100 Hz.
- App gửi `POST <FALL_API_URL>/predict`, JSON có đúng 200 mẫu và header
  `X-API-Key`. HTTP timeout là 5 giây.
- Server kiểm tra cadence quanh 100 Hz, đổi Polar milli-g sang g và dùng phép
  đổi trục hiện tại `(Polar Y, -Polar X, -Polar Z)` trước scaler/model.
  Phép đổi trục kế thừa từ receiver hiện có; cần kiểm chứng hướng đeo và trục
  cảm biến bằng dữ liệu Polar thật.
- Model yêu cầu 100 Hz. Nếu SDK chỉ cung cấp tần số khác, app hiện **không
  resample**; app báo sai tần số và không gửi cửa sổ để dự đoán.
- Nếu mạng/model xử lý chậm hơn luồng mẫu, app giữ cửa sổ mới nhất đang chờ
  thay vì xếp hàng mọi cửa sổ cũ.

## Preview, kiểm tra và giới hạn

Widget Preview và test giao diện dùng thiết bị/mẫu ACC giả lập; chúng không bật
Bluetooth và không gọi server. Chỉ chạy trên iPhone thật mới kiểm tra được BLE,
Polar SDK và quyền hệ điều hành.

Từ thư mục app, chạy:

```sh
flutter analyze
flutter test
flutter build ios --debug --no-codesign
```

Hai lệnh đầu kiểm tra Dart và test cục bộ. Build không ký kiểm tra compile iOS,
nhưng không chứng minh kết nối Polar hoặc API hoạt động. Để xác minh toàn bộ
pipeline, cần server báo `/health` sẵn sàng, iPhone truy cập được IP Mac, app
kết nối cảm biến thật và nhận được phản hồi `/predict`.

Nếu app báo lỗi:

- **Không thấy Polar:** kiểm tra pin/cảm biến, khoảng cách, Bluetooth và quyền
  trên iPhone; đóng app Polar khác nếu app đó đang giữ kết nối.
- **Không ready hoặc ACC không hỗ trợ:** chờ trạng thái SDK; ngắt kết nối rồi
  thử lại. Kiểm tra cảm biến có online ACC không.
- **Network error/timeout:** mở `/health` trên Safari iPhone, kiểm tra IP, cùng
  mạng, firewall Mac và trạng thái Terminal server.
- **HTTP 401:** key app và `FALL_API_KEY` server không trùng nhau.
- **HTTP 422:** payload không đủ 200 mẫu hoặc timestamp không đúng cadence.
- **Swift Package/Xcode build error:** mở `ios/Runner.xcworkspace`, resolve
  Swift packages khi có mạng, kiểm tra local SDK path và signing iPhone.
