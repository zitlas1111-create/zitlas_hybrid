# ZITLAS FastAPI Backend — Python 3.14.3 slim
# Dockerfile for Railway deployment of the hybrid monorepo's FastAPI service.
# See railway.json for deployment configuration.

FROM python:3.14.3-slim

WORKDIR /app

# Copy the entire repository (all three clients: backend, frontend, mobile).
# Only the backend is used at runtime; frontend and mobile are needed for reference.
COPY . .

# Install Python dependencies from the backend requirements file.
RUN pip install --no-cache-dir -r backend/requirements.txt

# Expose the port Railway will assign (via $PORT env var at runtime).
EXPOSE 8000

# Start the FastAPI backend.
# The backend/main.py app object is served by uvicorn on 0.0.0.0:$PORT.
CMD ["sh", "-c", "cd backend && uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
