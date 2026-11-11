FROM python:3.11-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1

COPY server/requirements.txt /app/server/requirements.txt
RUN python -m pip install --no-cache-dir -r /app/server/requirements.txt

COPY server/__init__.py server/app.py /app/server/
COPY polar_h10_receiver/udp_acc_receiver.py /app/polar_h10_receiver/
COPY saved_models_cnn_lstm/final_model.keras \
     saved_models_cnn_lstm/scaler.pkl \
     saved_models_cnn_lstm/metadata.pkl \
     /app/saved_models_cnn_lstm/

EXPOSE 8000

CMD ["python", "-m", "uvicorn", "server.app:app", "--host", "0.0.0.0", "--port", "8000"]
