"""HTTP API for the exported K-Fall CNN-LSTM bundle.

Run from the repository root: python -m uvicorn server.app:app --host 0.0.0.0 --port 8000
"""

from contextlib import asynccontextmanager
import os
from pathlib import Path
from threading import Lock
from time import perf_counter

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
import numpy as np

from polar_h10_receiver.udp_acc_receiver import FallPredictor, MODEL_SAMPLE_RATE, parse_sample


MODEL_DIR = Path(__file__).resolve().parents[1] / "saved_models_cnn_lstm"
TIMESTAMP_STEP_NS = int(1_000_000_000 / MODEL_SAMPLE_RATE)


class Sample(BaseModel):
    timestamp: str = Field(pattern=r"^[0-9]+$")
    x: int
    y: int
    z: int


class PredictRequest(BaseModel):
    samples: list[Sample]


def prepare_window(samples: list[Sample], expected_size: int) -> np.ndarray:
    """Validate one 100 Hz raw Polar window and reuse the UDP receiver mapping."""
    if len(samples) != expected_size:
        raise ValueError(f"Expected {expected_size} samples, received {len(samples)}")
    timestamps = []
    rows = []
    for sample in samples:
        timestamp, mapped = parse_sample(
            f"{sample.timestamp},{sample.x},{sample.y},{sample.z}"
        )
        timestamps.append(timestamp)
        rows.append(mapped)
    for first, second in zip(timestamps, timestamps[1:]):
        delta = second - first
        if not 0.8 * TIMESTAMP_STEP_NS <= delta <= 1.2 * TIMESTAMP_STEP_NS:
            raise ValueError("Samples must have increasing 100 Hz timestamps without gaps")
    return np.asarray(rows, dtype=np.float32)


@asynccontextmanager
async def lifespan(app: FastAPI):
    api_key = os.environ.get("FALL_API_KEY", "")
    if len(api_key) < 16:
        raise RuntimeError("Set FALL_API_KEY to a random string of at least 16 characters")
    predictor = FallPredictor(MODEL_DIR)  # Keras, scaler and metadata load once.
    if predictor.window_size != 200 or predictor.window_step != 100:
        raise RuntimeError("Flutter client expects window=200 and step=100")
    app.state.predictor = predictor
    app.state.api_key = api_key
    app.state.predict_lock = Lock()
    yield


app = FastAPI(title="Polar Fall Detection", lifespan=lifespan)


@app.get("/health")
def health():
    predictor = app.state.predictor
    return {
        "status": "ready",
        "window_size": predictor.window_size,
        "window_step": predictor.window_step,
        "sample_rate_hz": int(MODEL_SAMPLE_RATE),
    }


@app.post("/predict")
def predict(body: PredictRequest, x_api_key: str = Header(default="")):
    if x_api_key != app.state.api_key:
        raise HTTPException(status_code=401, detail="Invalid API key")
    predictor = app.state.predictor
    try:
        window = prepare_window(body.samples, predictor.window_size)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    started = perf_counter()
    with app.state.predict_lock:
        probability = predictor.predict(window)
    return {
        "label": "fall" if probability >= predictor.threshold else "normal",
        "probability": probability,
        "threshold": predictor.threshold,
        "inference_ms": round((perf_counter() - started) * 1000, 2),
        "last_timestamp": body.samples[-1].timestamp,
    }
