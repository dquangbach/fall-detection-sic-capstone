"""Run: ../.venv/bin/python -m unittest discover -s polar_h10_receiver -v"""

import unittest

import numpy as np

from udp_acc_receiver import DEFAULT_MODEL_DIR, FallPredictor, WindowStream, parse_sample


class StreamTests(unittest.TestCase):
    def test_units_and_axis_mapping(self):
        timestamp, sample = parse_sample("123456789,1000,2000,-500")
        self.assertEqual(timestamp, 123456789)
        np.testing.assert_array_equal(sample, [2.0, -1.0, 0.5])

    def test_malformed_and_nonfinite_input(self):
        for record in ("1,2,3", "not-a-time,1,2,3", "1,nan,2,3", "1,2,inf,3", "-1,0,0,0"):
            with self.subTest(record=record), self.assertRaises(ValueError):
                parse_sample(record)

    def test_window_contents_and_stride(self):
        stream = WindowStream(200, 100)
        windows = []
        for i in range(400):
            window = stream.push(i, np.full(3, i, dtype=np.float32))
            if window is not None:
                windows.append(window)
        self.assertEqual(len(windows), 3)
        for n, window in enumerate(windows):
            np.testing.assert_array_equal(window[:, 0], np.arange(n * 100, n * 100 + 200))

    def test_duplicate_and_reordered_samples_are_not_counted(self):
        stream = WindowStream(200, 100)
        for timestamp in (10, 10, 9, 11):
            stream.push(timestamp, np.zeros(3))
        self.assertEqual(stream.count, 2)

    def test_gap_resets_without_joining_recordings(self):
        stream = WindowStream(200, 100, timestamp_unit="ns")
        origin = 800_000_000_000_000_000
        for i in range(199):
            self.assertIsNone(stream.push(origin + i * 10_000_000, np.zeros(3)))
        self.assertIsNone(stream.push(origin + 250 * 10_000_000, np.ones(3)))
        self.assertIn("reset", stream.notice)
        self.assertEqual(stream.count, 1)
        for i in range(251, 450):
            window = stream.push(origin + i * 10_000_000, np.ones(3))
        np.testing.assert_array_equal(window, np.ones((200, 3)))

    def test_wrong_rate_never_fills_window_in_timestamp_mode(self):
        stream = WindowStream(200, 100, timestamp_unit="ms")
        for i in range(300):
            self.assertIsNone(stream.push(i * 20, np.zeros(3)))
        self.assertEqual(stream.count, 1)

    def test_manual_reset_allows_sensor_timestamp_restart(self):
        stream = WindowStream(200, 100)
        stream.push(1000, np.ones(3))
        stream.reset()
        stream.push(0, np.ones(3))
        self.assertTrue(stream.accepted)
        self.assertEqual(stream.count, 1)


@unittest.skipUnless((DEFAULT_MODEL_DIR / "final_model.keras").exists(), "Local model artifacts required")
class ModelIntegrationTests(unittest.TestCase):
    def test_exported_bundle_matches_direct_inference(self):
        predictor = FallPredictor()
        stream = WindowStream(predictor.window_size, predictor.window_step)
        # Feed synthetic raw Polar packets through the same live parser/buffer.
        for i in range(predictor.window_size):
            timestamp, sample = parse_sample(f"{i},1000,{i % 10},-20")
            window = stream.push(timestamp, sample)
        mean_before = predictor.scaler.mean_.copy()
        actual = predictor.predict(window)
        expected_input = predictor.scaler.transform(window[:, predictor.feature_indices]).astype(np.float32)
        expected = float(predictor.model(expected_input[None, ...], training=False).numpy()[0, 0])
        self.assertAlmostEqual(actual, expected, places=5)
        self.assertTrue(0 <= actual <= 1)
        np.testing.assert_array_equal(predictor.scaler.mean_, mean_before)
        with self.assertRaises(ValueError):
            predictor.predict(window[:-1])
        print(f"\nReal model smoke test: P(fall)={actual:.6f}, input={expected_input.shape}")


if __name__ == "__main__":
    unittest.main()
