# Polar Fall App — iOS

Flutter UI + Swift bridge to Polar BLE SDK. Scan/connect/disconnect, stream
ACC XYZ, assemble windows of 200 samples with step 100, and send them to the
FastAPI server on the laptop for inference. See `../../server/README.md` for
the server and `local_config.json` setup. No persistent recording yet.

## SDK dependency

The iOS target uses Swift Package Manager to link the existing local SDK:

```text
AI Projects/
├── polar-ble-sdk/
└── fall-detection-sic-capstone/
    └── apps/polar_fall_app/
```

Package path: `../../../../polar-ble-sdk` relative to `ios/`.
On another machine clone Polar alongside the capstone repo and check out
commit `3d15da61dd0c63e6be2582d03fd80f6c7ba02e11` in that NEW clone.
The bridge follows that checkout's Swift Concurrency API and the example at
`examples/example-ios/polar-sensor-data-collector/PSDC/PolarBleSdkManager.swift`.
The original sample (including its local UDP changes) remains separate.
License: `polar-ble-sdk/Polar_SDK_License.txt`.
Only iOS is implemented; Android needs a separate native bridge.

## Preview in VS Code

Open this app directory in VS Code, open `lib/main.dart`, then open the
**Flutter Widget Preview** sidebar. Two `@Preview` entries show the device list
and ACC streaming screen at 390 × 844. Save Dart changes to refresh the preview.
Preview buttons simulate scan/connect/start/stop/disconnect without native BLE
or HTTP.
The ACC preview uses 400 synthetic samples (3 windows), not live sensor data.
Normal `main()` still starts the real iOS app with Bluetooth.
If the sidebar is unavailable, run `flutter widget-preview start` from this folder.

## Run on iPhone
 
From this directory:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/Users/bach/flutter/bin/flutter pub get
/Users/bach/flutter/bin/flutter devices
/Users/bach/flutter/bin/flutter run -d <iphone-device-id>
```

Use your own Flutter path on another computer. Target: iOS 15 or later.
Open `ios/Runner.xcworkspace` in Xcode to select your Team under
Runner → Signing & Capabilities, then choose a real iPhone.
Enable Developer Mode on iPhone if requested. Allow Bluetooth permission.
Tap **Quét Polar**, select the device, wait for readiness, then **Bắt đầu ACC**.
Close the other Polar sample app if it occupies the device connection.

Xcode is installed, but this Mac's command-line selection currently points to
CommandLineTools. `DEVELOPER_DIR` above selects Xcode for this terminal only.
For VS Code F5, select Xcode in Xcode → Settings → Locations → Command Line Tools,
or launch VS Code from a terminal with that environment variable.

## Data

- Source: Polar sensor, not the iPhone accelerometer.
- Raw XYZ: integer milli-g, includes gravity. No normalization applied.
- Timestamp: nanoseconds since 2000-01-01, passed to Dart as a string.
- Settings queried from device: prefer 100 Hz if supported, otherwise maximum
  advertised rate. Selected rate is shown on screen.
- First window after 200 samples, then every 100 samples.
- Buffer resets on stop/disconnect/start to avoid mixing sessions.
- Completed windows are counted, not saved; only current overlap is retained.
- Background BLE mode declared; continuous capture while locked/backgrounded
  needs real-device testing. Start testing with the app foregrounded.
- Before trusting the prediction, confirm sample rate, units, axes, sensor
  placement, and training scaler on real Polar recordings.
- The FastAPI server reuses the existing receiver's axis mapping and scaler.
- The app sends only 100 Hz windows and displays the latest server probability.

UI: `lib/main.dart`. Windowing: `lib/window_buffer.dart`.
HTTP client: `lib/fall_api.dart`.
Native SDK owner: `ios/Runner/PolarBridge.swift`.
Channels: `polar_fall/methods` and `polar_fall/events`.

## Checks

```sh
flutter analyze
flutter test
flutter build ios --debug --no-codesign
```

Unsigned build checks compilation only. BLE reception requires a real Polar
sensor and iPhone; simulator cannot validate that pipeline.
