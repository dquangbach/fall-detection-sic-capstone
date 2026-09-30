import unittest
from unittest.mock import patch

import numpy as np
from fastapi.testclient import TestClient

from server.app import Sample, app, prepare_window


class WindowPreparationTests(unittest.TestCase):
    def test_matches_polar_receiver_mapping(self):
        samples = [Sample(timestamp=str(i * 10_000_000), x=1000, y=2000, z=-3000)
                   for i in range(200)]
        window = prepare_window(samples, 200)
        self.assertEqual(window.shape, (200, 3))
        np.testing.assert_allclose(window[0], [2.0, -1.0, 3.0])

    def test_rejects_gaps_and_wrong_length(self):
        samples = [Sample(timestamp=str(i * 10_000_000), x=0, y=0, z=1000)
                   for i in range(200)]
        with self.assertRaisesRegex(ValueError, "Expected 200"):
            prepare_window(samples[:-1], 200)
        samples[100] = Sample(timestamp=str(102 * 10_000_000), x=0, y=0, z=1000)
        with self.assertRaisesRegex(ValueError, "100 Hz"):
            prepare_window(samples, 200)


class ApiIntegrationTests(unittest.TestCase):
    def test_real_model_predicts_and_rejects_bad_requests(self):
        with patch.dict("os.environ", {"FALL_API_KEY": "local-demo-secret-12345"}):
            with TestClient(app) as client:
                self.assertEqual(client.get("/health").json()["window_size"], 200)
                samples = [{"timestamp": str(i * 10_000_000), "x": 0,
                            "y": 0, "z": 1000} for i in range(200)]
                payload = {"samples": samples}
                self.assertEqual(client.post("/predict", json=payload).status_code, 401)
                headers = {"X-API-Key": "local-demo-secret-12345"}
                self.assertEqual(client.post("/predict", json={"samples": samples[:1]},
                                             headers=headers).status_code, 422)
                response = client.post("/predict", json=payload, headers=headers)
                self.assertEqual(response.status_code, 200, response.text)
                result = response.json()
                self.assertIn(result["label"], {"normal", "fall"})
                self.assertGreaterEqual(result["probability"], 0)
                self.assertLessEqual(result["probability"], 1)
                self.assertEqual(result["last_timestamp"], str(199 * 10_000_000))


if __name__ == "__main__":
    unittest.main()
