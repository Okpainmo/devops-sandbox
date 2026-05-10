FROM python:3.12-alpine

WORKDIR /app
COPY app.py /app/app.py

ENV PORT=8000
EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:8000/health || exit 1

CMD ["python", "/app/app.py"]
