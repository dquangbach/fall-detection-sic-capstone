"""Run the exported CNN-LSTM on 100 Hz Polar H10 UDP acceleration.

Packet: timestamp,x_mg,y_mg,z_mg (one sample, or newline-separated samples).
Default mode counts frames at the user-confirmed 100 Hz; timestamp units need
not be known. --timestamp-unit additionally enables sensor-gap/rate checks.
"""

import argparse
from collections import deque
from pathlib import Path
import socket
import time

import joblib
import numpy as np


DEFAULT_MODEL_DIR = Path(__file__).resolve().parents[1] / "saved_models_cnn_lstm"
MODEL_SAMPLE_RATE = 100.0  # K-Fall training CSV: TimeStamp(s) increments by 0.01.
TIMESTAMP_UNITS = {"ns": 1_000_000_000, "us": 1_000_000, "ms": 1_000}


def parse_sample(text):
    """Parse one sensor sample, convert mg to g, and preserve receiver mapping."""
    fields = text.strip().split(",")
    if len(fields) != 4:
        raise ValueError("Expected timestamp,x_mg,y_mg,z_mg")
    timestamp = int(fields[0])
    polar = np.asarray([float(v) for v in fields[1:]], dtype=np.float64) / 1000.0
    if timestamp < 0 or not np.all(np.isfinite(polar)):
        raise ValueError("Timestamp must be nonnegative; acceleration must be finite")
    px, py, pz = polar
    mapped = np.asarray([py, -px, -pz], dtype=np.float32)
    if not np.all(np.isfinite(mapped)):
        raise ValueError("Acceleration exceeds float32 range")
    return timestamp, mapped


class WindowStream:
    """Emit windows at 200, 300, 400... samples using exported window settings."""

    def __init__(self, window_size, window_step, timestamp_unit=None):
        if not 0 < window_step <= window_size:
            raise ValueError("Require 0 < window_step <= window_size")
        self.window_size = window_size
        self.window_step = window_step
        self.ticks_per_second = TIMESTAMP_UNITS.get(timestamp_unit)
        self.reset()

    def reset(self):
        self.buffer = deque(maxlen=self.window_size)
        self.last_timestamp = None
        self.count = 0
        self.notice = None
        self.accepted = False

    def push(self, timestamp, values):
        self.notice = None
        self.accepted = False
        if self.last_timestamp is not None:
            delta = timestamp - self.last_timestamp
            if delta <= 0:
                self.notice = "Dropped duplicate/out-of-order timestamp"
                return None
            if self.ticks_per_second is not None:
                interval = delta / self.ticks_per_second
                # Allow timestamp rounding/jitter, but never silently accept a
                # different sample rate or bridge missing samples.
                if not 0.8 / MODEL_SAMPLE_RATE <= interval <= 1.2 / MODEL_SAMPLE_RATE:
                    self.reset()
                    self.notice = (
                        f"Sample interval {interval:.6f}s differs from 100 Hz: reset window; "
                        "check sender rate / --timestamp-unit / packet loss"
                    )
        self.last_timestamp = timestamp
        self.accepted = True
        self.buffer.append(values)
        self.count += 1
        if self.count >= self.window_size and (self.count - self.window_size) % self.window_step == 0:
            return np.asarray(self.buffer, dtype=np.float32)
        return None


class FallPredictor:
    def __init__(self, model_dir=DEFAULT_MODEL_DIR, threshold=None):
        import tensorflow as tf

        model_dir = Path(model_dir)
        # Load the trusted, locally exported model/scaler/metadata bundle.
        self.metadata = joblib.load(model_dir / "metadata.pkl")
        self.scaler = joblib.load(model_dir / "scaler.pkl")
        self.features = self.metadata["feature_cols"]
        if len(self.features) != 3 or set(self.features) != {"AccX", "AccY", "AccZ"}:
            raise ValueError(f"Polar ACC receiver requires AccX/AccY/AccZ, got {self.features}")
        self.feature_indices = [["AccX", "AccY", "AccZ"].index(f) for f in self.features]
        self.window_size = int(self.metadata["window_size"])
        self.window_step = int(self.metadata["window_step"])
        if not 0 < self.window_step <= self.window_size:
            raise ValueError("Invalid window_size/window_step in metadata")
        self.threshold = float(self.metadata["decision_threshold"] if threshold is None else threshold)
        if not np.isfinite(self.threshold) or not 0 <= self.threshold <= 1:
            raise ValueError("Decision threshold must be between 0 and 1")
        if self.scaler.n_features_in_ != len(self.features):
            raise ValueError("Scaler feature count does not match metadata")
        self.model = tf.keras.models.load_model(model_dir / "final_model.keras", compile=False)
        expected = (None, self.window_size, len(self.features))
        if tuple(self.model.input_shape) != expected or tuple(self.model.output_shape) != (None, 1):
            raise ValueError(f"Model shape mismatch: {self.model.input_shape} -> {self.model.output_shape}")
        self._infer = tf.function(
            lambda batch: self.model(batch, training=False),
            input_signature=[tf.TensorSpec((1, self.window_size, len(self.features)), tf.float32)],
        )
        # Warm up before opening the socket; model tracing can take a few seconds.
        self._infer(tf.zeros((1, self.window_size, len(self.features)), dtype=tf.float32))

    def predict(self, window):
        window = np.asarray(window, dtype=np.float32)
        if window.shape != (self.window_size, 3) or not np.all(np.isfinite(window)):
            raise ValueError("Invalid input window")
        # Transform with the exported scaler: no fit, no inference augmentation.
        scaled = self.scaler.transform(window[:, self.feature_indices]).astype(np.float32)
        probability = float(self._infer(scaled[None, ...]).numpy()[0, 0])
        if not np.isfinite(probability) or not 0 <= probability <= 1:
            raise ValueError("Model returned an invalid probability")
        return probability


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5005)
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
    parser.add_argument("--timestamp-unit", choices=TIMESTAMP_UNITS, default=None,
                        help="Optional sensor timestamp unit for 100 Hz cadence/gap checks")
    parser.add_argument("--timeout", type=float, default=2.0,
                        help="Reset after this many seconds without a valid sample (default: 2)")
    parser.add_argument("--threshold", type=float, default=None,
                        help="Default: exported metadata threshold")
    parser.add_argument("--show-acc", action="store_true", help="Also print each mapped sample in g")
    parser.add_argument("--check-model", action="store_true", help="Load/warm up artifacts, then exit")
    args = parser.parse_args(argv)
    if not np.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    predictor = FallPredictor(args.model_dir, args.threshold)
    stream = WindowStream(predictor.window_size, predictor.window_step, args.timestamp_unit)
    print(f"Model: {args.model_dir / 'final_model.keras'}", flush=True)
    print(f"Features: {predictor.features} | window={predictor.window_size} "
          f"step={predictor.window_step} | 100 Hz | threshold={predictor.threshold:.2f}")
    print("Polar mg -> g; K-Fall (X,Y,Z) = (Polar Y, -Polar X, -Polar Z).")
    print("Mapping retained from receiver; verify sensor orientation/placement experimentally.")
    print(f"Window ~{predictor.window_size / MODEL_SAMPLE_RATE:.2f}s; "
          f"prediction every {predictor.window_step / MODEL_SAMPLE_RATE:.2f}s.", flush=True)
    if args.timestamp_unit is None:
        print("Frame-count mode: assumes 100 Hz; timestamp units unknown, short gaps cannot be measured.")
    else:
        print(f"Timestamp unit: {args.timestamp_unit}; checking 100 Hz sensor cadence.")
    if args.check_model:
        print("Model/scaler/metadata loaded; inference warm-up OK.")
        return

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        sock.bind((args.host, args.port))
        sock.settimeout(min(args.timeout, 0.5))
        source = None
        last_valid = time.monotonic()
        print(f"Listening UDP on {args.host}:{args.port}; waiting for {predictor.window_size} samples...",
              flush=True)
        try:
            while True:
                if source is not None and time.monotonic() - last_valid > args.timeout:
                    stream.reset()
                    source = None
                    print("No valid samples: reset window; waiting for Polar...", flush=True)
                try:
                    data, addr = sock.recvfrom(65535)
                except socket.timeout:
                    continue
                if source is not None and addr != source:
                    continue  # Keep samples from different senders out of this stream.
                try:
                    records = data.decode("utf-8").strip().splitlines()
                except UnicodeDecodeError as exc:
                    print(f"Invalid UDP encoding from {addr}: {exc}", flush=True)
                    continue
                for record in records:
                    try:
                        timestamp, values = parse_sample(record)
                    except (ValueError, OverflowError) as exc:
                        print(f"Invalid sample: {record[:120]!r}: {exc}", flush=True)
                        continue
                    if source is None:
                        source = addr
                        print(f"Receiving from {source}", flush=True)
                    window = stream.push(timestamp, values)
                    if stream.notice:
                        print(stream.notice, flush=True)
                    if not stream.accepted:
                        continue
                    last_valid = time.monotonic()
                    if args.show_acc:
                        print(f"t={timestamp} Acc[g]={values} |A|={np.linalg.norm(values):.3f}")
                    if window is not None:
                        started = time.perf_counter()
                        probability = predictor.predict(window)
                        elapsed_ms = (time.perf_counter() - started) * 1000
                        label = "FALL / NGA" if probability >= predictor.threshold else "NORMAL"
                        print(f"t={timestamp} | {label} | P(fall)={probability:.4f} "
                              f"| inference={elapsed_ms:.1f}ms", flush=True)
        except KeyboardInterrupt:
            print("\nStopped Polar receiver.")


if __name__ == "__main__":
    main()
