import Flutter
import Foundation
import PolarBleSdk

// Uses the same native SDK/API as examples/example-ios in the local Polar checkout.
// All bridge state and Flutter events are serialized on the main actor.
@MainActor
final class PolarBridge: NSObject, FlutterStreamHandler, PolarBleApiObserver,
    PolarBleApiPowerStateObserver, PolarBleApiDeviceFeaturesObserver {
    private var api: PolarBleApi?
    private var sink: FlutterEventSink?
    private var scanTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var activeStream: String?
    private var ecgFile: FileHandle?
    private var ecgFileName: String?
    private var ecgRate = 0
    private var deviceID: String?
    private var ready = false
    private var bluetoothOn = false
    private var generation = 0
    private let methods: FlutterMethodChannel
    private let events: FlutterEventChannel

    init(messenger: FlutterBinaryMessenger) {
        methods = FlutterMethodChannel(name: "polar_fall/methods", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "polar_fall/events", binaryMessenger: messenger)
        super.init()
        events.setStreamHandler(self)
        methods.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(FlutterError(code: "unavailable", message: "Bridge unavailable", details: nil)); return }
            self.handle(call, result: result)
        }
    }

    private func emit(_ type: String, _ values: [String: Any] = [:]) {
        sink?(values.merging(["type": type]) { _, new in new })
    }

    private func initialize() {
        guard api == nil else { return }
        var sdk = PolarBleApiDefaultImpl.polarImplementation(.main, features: [.feature_polar_online_streaming])
        sdk.observer = self
        sdk.powerStateObserver = self
        sdk.deviceFeaturesObserver = self
        api = sdk
        bluetoothOn = sdk.isBlePowered
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        initialize()
        guard let api else { return }
        do {
            switch call.method {
            case "scan":
                guard bluetoothOn, deviceID == nil else {
                    result(FlutterError(code: "state", message: "Bật Bluetooth và ngắt thiết bị hiện tại trước khi quét.", details: nil)); return
                }
                scanTask?.cancel()
                scanTask = Task { [weak self] in
                    do {
                        for try await device in api.searchForDevice() {
                            try Task.checkCancellation()
                            self?.emit("device", ["id": device.deviceId, "name": device.name,
                                                  "rssi": device.rssi, "connectable": device.connectable])
                        }
                    } catch {
                        if !Task.isCancelled { self?.emit("error", ["message": String(describing: error)]) }
                    }
                }
                result(nil)
            case "stopScan":
                scanTask?.cancel(); scanTask = nil; result(nil)
            case "connect":
                guard deviceID == nil, let args = call.arguments as? [String: Any],
                      let id = args["id"] as? String, !id.isEmpty else {
                    result(FlutterError(code: "state", message: "Thiết bị không hợp lệ hoặc đang kết nối.", details: nil)); return
                }
                scanTask?.cancel(); scanTask = nil
                try api.connectToDevice(id)
                deviceID = id
                emit("connection", ["state": "connecting", "id": id])
                result(nil)
            case "disconnect":
                let task = streamTask
                cancelStream()
                Task { [weak self] in
                    await task?.value
                    do {
                        if let id = self?.deviceID { try api.disconnectFromDevice(id) }
                        self?.deviceID = nil; self?.ready = false
                        self?.emit("connection", ["state": "disconnected"])
                        result(nil)
                    } catch {
                        result(FlutterError(code: "polar", message: error.localizedDescription, details: nil))
                    }
                }
            case "startAcc":
                guard let id = deviceID, ready, streamTask == nil else {
                    result(FlutterError(code: "state", message: "Chờ tính năng ACC sẵn sàng, hoặc dừng phiên hiện tại.", details: nil)); return
                }
                generation += 1
                let token = generation
                activeStream = "acc"
                streamTask = Task { [weak self] in
                    do {
                        let types = try await api.getAvailableOnlineStreamDataTypes(id)
                        guard types.contains(.acc) else {
                            throw NSError(domain: "Polar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Thiết bị không hỗ trợ ACC."])
                        }
                        let available = try await api.requestStreamSettings(id, feature: .acc)
                        // Use a supported rate; report it explicitly. Model resampling comes later.
                        var selected = available.settings.compactMapValues { $0.max() }
                        if let rates = available.settings[.sampleRate], rates.contains(100) { selected[.sampleRate] = 100 }
                        let settings = try PolarSensorSetting(selected)
                        try Task.checkCancellation()
                        self?.emit("stream", ["state": "started", "kind": "acc", "sampleRate": selected[.sampleRate] ?? 0])
                        for try await batch in api.startAccStreaming(id, settings: settings) {
                            try Task.checkCancellation()
                            self?.emit("acc", ["samples": batch.map {
                                ["timestamp": String($0.timeStamp), "x": $0.x, "y": $0.y, "z": $0.z] as [String: Any]
                            }])
                        }
                    } catch {
                        if !Task.isCancelled { self?.emit("error", ["message": error.localizedDescription]) }
                    }
                    if self?.generation == token {
                        self?.streamTask = nil
                        self?.activeStream = nil
                        self?.emit("stream", ["state": "stopped", "kind": "acc"])
                    }
                }
                result(nil)
            case "startEcg":
                guard let id = deviceID, ready, streamTask == nil else {
                    result(FlutterError(code: "state", message: "Chờ ECG sẵn sàng, hoặc dừng phiên hiện tại.", details: nil)); return
                }
                generation += 1
                let token = generation
                activeStream = "ecg"
                ecgFileName = nil
                streamTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let types = try await api.getAvailableOnlineStreamDataTypes(id)
                        guard types.contains(.ecg) else {
                            throw NSError(domain: "Polar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Thiết bị không hỗ trợ ECG."])
                        }
                        let available = try await api.requestStreamSettings(id, feature: .ecg)
                        let selected = available.settings.compactMapValues { $0.max() }
                        let settings = try PolarSensorSetting(selected)
                        try Task.checkCancellation()
                        guard let rate = selected[.sampleRate], rate > 0 else {
                            throw NSError(domain: "Polar", code: 4, userInfo: [NSLocalizedDescriptionKey: "SDK không trả về tần số ECG."])
                        }
                        try self.openEcgFile(sampleRate: Int(rate))
                        self.emit("stream", ["state": "started", "kind": "ecg",
                                             "sampleRate": Int(rate),
                                             "fileName": self.ecgFileName ?? ""])
                        for try await batch in api.startEcgStreaming(id, settings: settings) {
                            try Task.checkCancellation()
                            try self.writeEcgBatch(batch)
                            self.emit("ecg", ["samples": batch.map {
                                ["timestamp": String($0.timeStamp), "voltageUv": $0.voltage] as [String: Any]
                            }])
                        }
                    } catch {
                        if !Task.isCancelled { self.emit("error", ["message": error.localizedDescription]) }
                    }
                    self.closeEcgFile()
                    if self.generation == token {
                        self.streamTask = nil
                        self.activeStream = nil
                        self.emit("stream", ["state": "stopped", "kind": "ecg",
                                             "fileName": self.ecgFileName ?? ""])
                    }
                }
                result(nil)
            case "stopAcc":
                // Wait for this consumer to exit before allowing another start.
                // Device-side stop is handled asynchronously by the Polar SDK.
                let task = streamTask
                guard activeStream == "acc" else {
                    result(FlutterError(code: "state", message: "ACC chưa chạy.", details: nil)); return
                }
                task?.cancel()
                Task { await task?.value; result(nil) }
            case "stopEcg":
                let task = streamTask
                guard activeStream == "ecg" else {
                    result(FlutterError(code: "state", message: "ECG chưa chạy.", details: nil)); return
                }
                task?.cancel()
                Task { await task?.value; result(nil) }
            default: result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(code: "polar", message: error.localizedDescription, details: nil))
        }
    }

    private func cancelStream() {
        // Keep the task registered until its cancellation handler closes the
        // ECG file and the SDK ends the device stream.
        streamTask?.cancel()
    }

    private func openEcgFile(sampleRate: Int) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "polar_ecg_\(UUID().uuidString).csv"
        let url = documents.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "Polar", code: 3, userInfo: [NSLocalizedDescriptionKey: "Không tạo được file ECG."])
        }
        ecgFile = try FileHandle(forWritingTo: url)
        ecgFileName = name
        ecgRate = sampleRate
        try ecgFile?.write(contentsOf: Data("device_timestamp_ns,voltage_uv,sample_rate_hz,phone_received_at_utc\n".utf8))
    }

    private func writeEcgBatch(_ batch: PolarEcgData) throws {
        let received = ISO8601DateFormatter().string(from: Date())
        let lines = batch.map { "\($0.timeStamp),\($0.voltage),\(ecgRate),\(received)\n" }.joined()
        try ecgFile?.write(contentsOf: Data(lines.utf8))
    }

    private func closeEcgFile() {
        try? ecgFile?.close()
        ecgFile = nil
        ecgRate = 0
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        initialize()
        emit("bluetooth", ["enabled": bluetoothOn])
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        scanTask?.cancel(); scanTask = nil
        let task = streamTask
        let id = deviceID
        cancelStream()
        deviceID = nil; ready = false; sink = nil
        Task { [weak self] in
            await task?.value
            if let id {
                do { try self?.api?.disconnectFromDevice(id) }
                catch { NSLog("Polar disconnect: %@", error.localizedDescription) }
            }
        }
        return nil
    }

    nonisolated func blePowerOn() {
        Task { @MainActor in self.bluetoothOn = true; self.emit("bluetooth", ["enabled": true]) }
    }
    nonisolated func blePowerOff() {
        Task { @MainActor in
            self.bluetoothOn = false; self.ready = false
            self.scanTask?.cancel(); self.scanTask = nil
            self.cancelStream()
            self.emit("bluetooth", ["enabled": false])
        }
    }
    nonisolated func deviceConnecting(_ device: PolarDeviceInfo) {
        Task { @MainActor in
            guard self.deviceID == device.deviceId else { return }
            self.emit("connection", ["state": "connecting", "id": device.deviceId])
        }
    }
    nonisolated func deviceConnected(_ device: PolarDeviceInfo) {
        Task { @MainActor in
            guard self.deviceID == device.deviceId else { return }
            self.emit("connection", ["state": "connected", "id": device.deviceId])
        }
    }
    nonisolated func deviceDisconnected(_ device: PolarDeviceInfo, pairingError: Bool) {
        Task { @MainActor in
            guard self.deviceID == device.deviceId else { return }
            self.ready = false; self.cancelStream()
            self.emit("connection", ["state": "reconnecting", "id": device.deviceId])
            if pairingError { self.emit("error", ["message": "Lỗi ghép đôi: kiểm tra Bluetooth trong Cài đặt iPhone."]) }
        }
    }
    nonisolated func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        Task { @MainActor in
            guard self.deviceID == identifier, feature == .feature_polar_online_streaming else { return }
            self.ready = true
            self.emit("ready")
        }
    }
    nonisolated func bleSdkFeaturesReadiness(_ identifier: String, ready: [PolarBleSdkFeature], unavailable: [PolarBleSdkFeature]) {
        if ready.contains(.feature_polar_online_streaming) {
            bleSdkFeatureReady(identifier, feature: .feature_polar_online_streaming)
        } else {
            Task { @MainActor in
                guard self.deviceID == identifier else { return }
                self.emit("error", ["message": "Online streaming chưa sẵn sàng hoặc không được hỗ trợ."])
            }
        }
    }
}
