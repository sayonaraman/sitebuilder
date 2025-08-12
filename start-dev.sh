#!/usr/bin/env bash
set -euo pipefail

echo "================================"
echo "Starting Dev Environment (Linux)"
echo "================================"

# Move to project root (directory of this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Define project name and registry path
PROJECT_NAME="$(basename "$SCRIPT_DIR")"
REGISTRY_PATH="$(dirname "$SCRIPT_DIR")/port-registry.json"

echo "Project: $PROJECT_NAME"
echo "Registry: $REGISTRY_PATH"

# Pre-flight checks
if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 is not installed or not in PATH. Please install Python 3.10+." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[ERROR] Node.js is not installed or not in PATH. Please install Node.js 18+." >&2
  exit 1
fi

# Check if jq is available (optional)
HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=true
  echo "jq is available - will use registry"
else
  echo "jq not found - will use simple port allocation"
fi

# Simple port functions without complex registry logic
is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -i TCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  else
    ss -ltn | awk '{print $4}' | grep -E "(:|\])${port}$" >/dev/null 2>&1
  fi
}

find_free_port() {
  local start_port="$1"
  local port="$start_port"
  while is_port_in_use "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

# Simple registry functions
read_simple_registry() {
  if [[ -f "$REGISTRY_PATH" ]] && [[ "$HAS_JQ" == true ]]; then
    cat "$REGISTRY_PATH" 2>/dev/null || echo "{}"
  else
    echo "{}"
  fi
}

write_simple_registry() {
  local data="$1"
  if [[ "$HAS_JQ" == true ]]; then
    echo "$data" > "$REGISTRY_PATH" || echo "Warning: Could not write registry"
  fi
}

# Get ports - simple logic
echo "Determining ports..."

# Check existing registry if available
FRONTEND_PORT=""
BACKEND_PORT=""

if [[ "$HAS_JQ" == true ]] && [[ -f "$REGISTRY_PATH" ]]; then
  echo "Reading existing registry..."
  existing_frontend=$(cat "$REGISTRY_PATH" 2>/dev/null | jq -r ".[\"$PROJECT_NAME\"].frontend_port // \"null\"" 2>/dev/null || echo "null")
  existing_backend=$(cat "$REGISTRY_PATH" 2>/dev/null | jq -r ".[\"$PROJECT_NAME\"].backend_port // \"null\"" 2>/dev/null || echo "null")
  
  if [[ "$existing_frontend" != "null" ]] && [[ "$existing_backend" != "null" ]]; then
    # Check if ports are available
    if ! is_port_in_use "$existing_frontend" && ! is_port_in_use "$existing_backend"; then
      FRONTEND_PORT="$existing_frontend"
      BACKEND_PORT="$existing_backend"
      echo "Reusing existing ports: frontend=$FRONTEND_PORT, backend=$BACKEND_PORT"
    fi
  fi
fi

# If no existing ports, find new ones
if [[ -z "$FRONTEND_PORT" ]] || [[ -z "$BACKEND_PORT" ]]; then
  FRONTEND_PORT="${FRONTEND_START_PORT:-$(find_free_port 3000)}"
  BACKEND_PORT="${BACKEND_START_PORT:-$(find_free_port 8000)}"
  
  # Make sure backend port doesn't conflict with frontend
  if [[ "$BACKEND_PORT" == "$FRONTEND_PORT" ]]; then
    BACKEND_PORT=$(find_free_port $((BACKEND_PORT + 1)))
  fi
  
  echo "Using new ports: frontend=$FRONTEND_PORT, backend=$BACKEND_PORT"
fi

echo "Final ports: FRONTEND_PORT=${FRONTEND_PORT}, BACKEND_PORT=${BACKEND_PORT}"

# Create root-level venv if missing
if [[ ! -f "venv/bin/python" ]]; then
  echo "Creating virtual environment in $PWD/venv ..."
  python3 -m venv venv
fi

echo "Upgrading pip..."
venv/bin/python -m pip install --upgrade pip

echo "Installing backend dependencies..."
venv/bin/python -m pip install -r backend/requirements.txt

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

# Ensure frontend .env exists with backend URL
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

# Branding updates in public HTML
INDEX_PATH="frontend/public/index.html"
if [[ -f "${INDEX_PATH}" ]]; then
  sed -i 's#<title>[^<]*</title>#<title>'"${SITE_TITLE}"'</title>#' "${INDEX_PATH}" || true
  sed -i "s#Made with Emergent#${BUTTON_TEXT}#g" "${INDEX_PATH}" || true
  sed -i "/id=\"emergent-badge\"/,/<\/a>/{ s#https\?://app\\.emergent\\.sh[^'\"]*#${BUTTON_HREF}#g }" "${INDEX_PATH}" || true
  sed -i "/id=\"emergent-badge\"/,/<\/a>/{ s#Emergent#${BUTTON_TEXT}#g }" "${INDEX_PATH}" || true
  sed -i -E "s#(<meta[^>]*name=[\"']description[\"'][^>]*content=[\"'][^\"']*)emergent\\.sh([^\"']*[\"'])#\1${BUTTON_TEXT}\2#I" "${INDEX_PATH}" || true
  
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

# Ensure CORS aligns with selected ports
export CORS_ORIGINS="${CORS_ORIGINS:-http://${SERVER_HOST}:${FRONTEND_PORT},http://localhost:${FRONTEND_PORT}}"

# Start backend
venv/bin/python -m uvicorn backend.server:app --reload --host 0.0.0.0 --port "${BACKEND_PORT}" > backend.log 2>&1 &
BACK_PID=$!

# Start frontend
pushd frontend >/dev/null
if [[ "${PKG}" == "yarn" ]]; then
  PORT="${FRONTEND_PORT}" REACT_APP_BACKEND_URL="http://${SERVER_HOST}:${BACKEND_PORT}" yarn start > ../frontend.log 2>&1 &
else
  PORT="${FRONTEND_PORT}" REACT_APP_BACKEND_URL="http://${SERVER_HOST}:${BACKEND_PORT}" npm start > ../frontend.log 2>&1 &
fi
FRONT_PID=$!
popd >/dev/null

# Update registry (simple version)
if [[ "$HAS_JQ" == true ]]; then
  echo "Updating port registry..."
  current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Create registry data
  registry_entry="{
  \"$PROJECT_NAME\": {
    \"frontend_port\": $FRONTEND_PORT,
    \"backend_port\": $BACKEND_PORT,
    \"last_used\": \"$current_time\",
    \"pid_frontend\": $FRONT_PID,
    \"pid_backend\": $BACK_PID
  }
}"
  
  # Read existing registry and merge
  if [[ -f "$REGISTRY_PATH" ]]; then
    existing_registry=$(cat "$REGISTRY_PATH" 2>/dev/null || echo "{}")
    # Use jq to merge
    merged_registry=$(echo "$existing_registry" | jq --argjson new "$registry_entry" '. * $new' 2>/dev/null || echo "$registry_entry")
    echo "$merged_registry" > "$REGISTRY_PATH"
  else
    # Create new registry
    echo "$registry_entry" > "$REGISTRY_PATH"
  fi
  
  echo "Registry updated: $REGISTRY_PATH"
else
  echo "Registry not available (jq not installed)"
fi

echo "Servers are starting in background."
echo "Backend:  http://localhost:${BACKEND_PORT}  (pid: ${BACK_PID})"
echo "Frontend: http://localhost:${FRONTEND_PORT}  (pid: ${FRONT_PID})"
echo "Logs: backend.log, frontend.log"

# Cleanup function
cleanup() {
  echo "Stopping servers..."
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
  
  # Clean up PIDs from registry
  if [[ "$HAS_JQ" == true ]] && [[ -f "$REGISTRY_PATH" ]]; then
    echo "Cleaning up registry..."
    updated_registry=$(cat "$REGISTRY_PATH" 2>/dev/null | jq ".[\"$PROJECT_NAME\"].pid_frontend = null | .[\"$PROJECT_NAME\"].pid_backend = null" 2>/dev/null || cat "$REGISTRY_PATH")
    echo "$updated_registry" > "$REGISTRY_PATH" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Keep script running
wait
