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
                cancelStream()
                if let id = deviceID { try api.disconnectFromDevice(id) }
                deviceID = nil; ready = false
                emit("connection", ["state": "disconnected"])
                result(nil)
            case "startAcc":
                guard let id = deviceID, ready, streamTask == nil else {
                    result(FlutterError(code: "state", message: "Chờ tính năng ACC sẵn sàng, hoặc dừng phiên hiện tại.", details: nil)); return
                }
                generation += 1
                let token = generation
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
                        self?.emit("stream", ["state": "started", "sampleRate": selected[.sampleRate] ?? 0])
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
                        self?.emit("stream", ["state": "stopped"])
                    }
                }
                result(nil)
            case "stopAcc":
                // Wait for this consumer to exit before allowing another start.
                // Device-side stop is handled asynchronously by the Polar SDK.
                let task = streamTask
                task?.cancel()
                Task { await task?.value; result(nil) }
            default: result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(code: "polar", message: error.localizedDescription, details: nil))
        }
    }

    private func cancelStream() {
        generation += 1
        streamTask?.cancel(); streamTask = nil
        emit("stream", ["state": "stopped"])
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        initialize()
        emit("bluetooth", ["enabled": bluetoothOn])
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        scanTask?.cancel(); scanTask = nil
        cancelStream()
        if let id = deviceID {
            do { try api?.disconnectFromDevice(id) }
            catch { NSLog("Polar disconnect: %@", error.localizedDescription) }
        }
        deviceID = nil; ready = false; sink = nil
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
