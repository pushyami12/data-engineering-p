FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY orders_cstobq_etl ./orders_cstobq_etl

WORKDIR /app/orders_cstobq_etl

ENTRYPOINT ["python", "main.py"]
