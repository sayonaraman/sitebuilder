#!/usr/bin/env bash
set -euo pipefail

echo "================================"
echo "Starting Dev Environment (Linux)"
echo "================================"

# Move to project root (directory of this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pre-flight checks
if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 is not installed or not in PATH. Please install Python 3.10+." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[ERROR] Node.js is not installed or not in PATH. Please install Node.js 18+." >&2
  exit 1
fi

# Create root-level venv if missing
if [[ ! -f "venv/bin/python" ]]; then
  echo "Creating virtual environment in $PWD/venv ..."
  python3 -m venv venv
fi

echo "Upgrading pip..."
venv/bin/python -m pip install --upgrade pip

echo "Installing backend dependencies..."
venv/bin/python -m pip install -r backend/requirements.txt

# Find free ports utilities
is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -i TCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  else
    # Fallback to ss
    ss -ltn | awk '{print $4}' | grep -E "(:|\])${port}$" >/dev/null 2>&1
  fi
}

find_free_port() {
  local port="$1"
  while is_port_in_use "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

FRONTEND_PORT="${FRONTEND_START_PORT:-$(find_free_port 3000)}"
BACKEND_PORT="${BACKEND_START_PORT:-$(find_free_port 8000)}"
echo "Using FRONTEND_PORT=${FRONTEND_PORT} and BACKEND_PORT=${BACKEND_PORT}"

# Prepared, constant site title (change here if needed)
SITE_TITLE="${SITE_TITLE:-test-pixbit.pro}"
BUTTON_TEXT="${BUTTON_TEXT:-pixbit.pro}"
BUTTON_HREF="${BUTTON_HREF:-https://pixbit.pro}"
FAVICON_URL="${FAVICON_URL:-}"

# Ensure backend .env exists with sensible defaults
if [[ ! -f backend/.env ]]; then
  echo "Creating backend/.env with defaults..."
  {
    echo "MONGO_URL=${MONGO_URL:-mongodb://localhost:27017}"
    echo "DB_NAME=${DB_NAME:-advocat}"
    echo "CORS_ORIGINS=${CORS_ORIGINS:-http://localhost:${FRONTEND_PORT}}"
  } > backend/.env
fi

# Ensure frontend .env exists with backend URL (use server IP if available)
SERVER_HOST_DEFAULT=$(hostname -I 2>/dev/null | awk '{print $1}') || true
SERVER_HOST="${SERVER_HOST:-${SERVER_HOST_DEFAULT:-localhost}}"
if [[ ! -f frontend/.env ]]; then
  echo "Creating frontend/.env with defaults..."
  echo "REACT_APP_BACKEND_URL=http://${SERVER_HOST}:${BACKEND_PORT}" > frontend/.env
fi

# Choose package manager for frontend (prefer yarn if available)
PKG="npm"
if command -v yarn >/dev/null 2>&1; then
  PKG="yarn"
fi
echo "Using ${PKG} for frontend..."

echo "Installing frontend dependencies..."
pushd frontend >/dev/null
if [[ "${PKG}" == "yarn" ]]; then
  yarn install --frozen-lockfile || yarn install
else
  npm ci || npm install
fi
popd >/dev/null

# Branding updates in public HTML: adjust title; keep JS and structure intact
INDEX_PATH="frontend/public/index.html"
if [[ -f "${INDEX_PATH}" ]]; then
  # 1) Title
  sed -i 's#<title>[^<]*</title>#<title>'"${SITE_TITLE}"'</title>#' "${INDEX_PATH}" || true
  # 2) Badge text and href; keep JS intact
  sed -i "s#Made with Emergent#${BUTTON_TEXT}#g" "${INDEX_PATH}" || true
  sed -i "/id=\"emergent-badge\"/,/<\/a>/{ s#https\?://app\\.emergent\\.sh[^'\"]*#${BUTTON_HREF}#g }" "${INDEX_PATH}" || true
  sed -i "/id=\"emergent-badge\"/,/<\/a>/{ s#Emergent#${BUTTON_TEXT}#g }" "${INDEX_PATH}" || true
  # 3) Meta description line only, if contains emergent.sh
  sed -i -E "s#(<meta[^>]*name=[\"']description[\"'][^>]*content=[\"'][^\"']*)emergent\\.sh([^\"']*[\"'])#\1${BUTTON_TEXT}\2#I" "${INDEX_PATH}" || true
  # 4) Favicon (if provided)
  if [[ -n "${FAVICON_URL}" ]]; then
    if grep -qi '<link[^>]*rel=["\'']icon' "${INDEX_PATH}"; then
      sed -i -E "s#<link[^>]*rel=[\"']icon[\"'][^>]*>#<link rel=\"icon\" href=\"${FAVICON_URL}\"/>#Ig" "${INDEX_PATH}" || true
    else
      sed -i "s#</head>#  <link rel=\"icon\" href=\"${FAVICON_URL}\"/>\n</head>#" "${INDEX_PATH}" || true
    fi
  fi
fi

# Start backend and frontend
echo "Starting servers..."

# Ensure CORS aligns with selected frontend port and server host
export CORS_ORIGINS="${CORS_ORIGINS:-http://${SERVER_HOST}:${FRONTEND_PORT},http://localhost:${FRONTEND_PORT}}"

venv/bin/python -m uvicorn backend.server:app --reload --host 0.0.0.0 --port "${BACKEND_PORT}" > backend.log 2>&1 &
BACK_PID=$!

pushd frontend >/dev/null
if [[ "${PKG}" == "yarn" ]]; then
  PORT="${FRONTEND_PORT}" REACT_APP_BACKEND_URL="http://${SERVER_HOST}:${BACKEND_PORT}" yarn start > ../frontend.log 2>&1 &
else
  PORT="${FRONTEND_PORT}" REACT_APP_BACKEND_URL="http://${SERVER_HOST}:${BACKEND_PORT}" npm start > ../frontend.log 2>&1 &
fi
FRONT_PID=$!
popd >/dev/null

echo "Servers are starting in background."
echo "Backend:  http://localhost:${BACKEND_PORT}  (pid: ${BACK_PID})"
echo "Frontend: http://localhost:${FRONTEND_PORT}  (pid: ${FRONT_PID})"
echo "Logs: backend.log, frontend.log"

# Stop both on exit
cleanup() {
  echo "Stopping servers..."
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Keep script running to keep trap active
wait


