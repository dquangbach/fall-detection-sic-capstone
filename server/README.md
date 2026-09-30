# FastAPI inference on the laptop

This server loads the existing trusted `saved_models_cnn_lstm/final_model.keras`,
`scaler.pkl` and `metadata.pkl` once at startup. The same `FallPredictor` and
`parse_sample` functions used by the UDP receiver perform preprocessing:

```text
Polar raw milli-g XYZ + ns timestamps, 100 Hz, 200 samples
  → (Y, -X, -Z) in g → saved StandardScaler
  → Keras tensor (1, 200, 3) → fall probability, threshold from metadata
```

The axis mapping came from the existing receiver; verify sensor placement and
orientation on real Polar data. The server rejects windows with timestamp gaps
or rates outside ±20% of 100 Hz. iPhone sends windows every 100 new samples.

## 1. Start on the Mac

Run from `fall-detection-sic-capstone` (repository root):

```sh
../.venv/bin/python -m pip install -r server/requirements.txt
export FALL_API_KEY='choose-a-random-key-at-least-16-characters'
../.venv/bin/python -m uvicorn server.app:app --host 0.0.0.0 --port 8000
```

The existing `../.venv` was used for model training/receiver on this Mac.
`0.0.0.0` makes the server accessible on the local Wi-Fi; leave the Terminal open.
The key is required; do not commit your real key to Git.

Find the Mac's Wi-Fi address with `ipconfig getifaddr en0` (or check System
Settings → Wi-Fi → Details). On the Mac:

```sh
curl http://127.0.0.1:8000/health
```

Expected: `status=ready`, `window_size=200`, `window_step=100`, `sample_rate_hz=100`.
On iPhone Safari, open `http://<mac-wifi-ip>:8000/health` to verify LAN access.
Both devices must use the same Wi-Fi; allow incoming connections in the Mac
firewall if prompted.

## 2. Configure and run the iPhone app

From `apps/polar_fall_app`:

```sh
cp local_config.example.json local_config.json
```

Edit `local_config.json`: set `FALL_API_URL` to the Mac address such as
`http://192.168.1.20:8000`; set `FALL_API_KEY` to the **same** value exported on
the Mac. `local_config.json` is ignored by Git. Do not use `localhost` in the app.

Open this Flutter app folder in VS Code, select the iPhone, choose launch
configuration **Polar iPhone + FastAPI**, then press F5. Flutter passes the
config file via `--dart-define-from-file`. For Terminal:

```sh
flutter run -d <iphone-id> --dart-define-from-file=local_config.json
```

When iOS asks for Local Network permission, allow it. Scan/connect Polar and
start ACC. The screen shows the selected rate, XYZ, number of completed windows,
and the latest `fall` / `normal` probability returned by the laptop.
If Polar cannot provide 100 Hz, the app displays a rate mismatch and does not
send windows to this 100 Hz model.

HTTP on the LAN and a shared key are suitable for this local demo. The key is
sent in clear text over HTTP; do not forward port 8000 to the Internet. Use
HTTPS plus proper authentication for a remote deployment. The screen's result
is a model prediction, not a validated emergency alert.

## 3. API contract

`POST /predict` with `Content-Type: application/json` and `X-API-Key`:

```json
{
  "samples": [
    {"timestamp": "0", "x": 100, "y": -200, "z": 980}
  ]
}
```

The request must contain **exactly 200** samples with increasing 10 ms Polar
timestamps; the one-sample example above only illustrates the fields.
Response:

```json
{
  "label": "normal",
  "probability": 0.12,
  "threshold": 0.5,
  "inference_ms": 7.3,
  "last_timestamp": "1990000000"
}
```

Numbers above are illustrative. `401` means the key differs; `422` means the
data shape, order or cadence is invalid. Test locally:

```sh
../.venv/bin/python -m unittest server.test_app -v
```
