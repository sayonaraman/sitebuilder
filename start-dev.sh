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
REGISTRY_PATH="$(dirname "$SCRIPT_DIR")/.port-registry.json"
REGISTRY_LOCK="$REGISTRY_PATH.lock"

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

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] jq is not installed. Please install jq for JSON processing." >&2
  exit 1
fi

# Registry management functions
acquire_registry_lock() {
  local timeout=10
  local count=0
  while [[ -f "$REGISTRY_LOCK" ]] && [[ $count -lt $timeout ]]; do
    sleep 0.5
    count=$((count + 1))
  done
  
  if [[ $count -ge $timeout ]]; then
    echo "[WARNING] Registry lock timeout, proceeding anyway..."
    rm -f "$REGISTRY_LOCK"
  fi
  
  echo $$ > "$REGISTRY_LOCK"
}

release_registry_lock() {
  rm -f "$REGISTRY_LOCK"
}

# Cleanup lock on exit
cleanup_lock() {
  release_registry_lock
}
trap cleanup_lock EXIT

read_registry() {
  if [[ ! -f "$REGISTRY_PATH" ]]; then
    echo "{}"
    return
  fi
  cat "$REGISTRY_PATH"
}

write_registry() {
  local registry_data="$1"
  echo "$registry_data" > "$REGISTRY_PATH.tmp"
  mv "$REGISTRY_PATH.tmp" "$REGISTRY_PATH"
}

is_process_running() {
  local pid="$1"
  [[ -n "$pid" ]] && [[ "$pid" != "null" ]] && kill -0 "$pid" 2>/dev/null
}

is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -i TCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  else
    # Fallback to ss
    ss -ltn | awk '{print $4}' | grep -E "(:|\])${port}$" >/dev/null 2>&1
  fi
}

get_used_ports_from_registry() {
  local registry_data="$1"
  echo "$registry_data" | jq -r '.[] | select(.frontend_port != null and .backend_port != null) | "\(.frontend_port)\n\(.backend_port)"' 2>/dev/null || true
}

find_free_port() {
  local start_port="$1"
  local registry_data="$2"
  local used_ports
  used_ports=$(get_used_ports_from_registry "$registry_data")
  
  local port="$start_port"
  while true; do
    # Check if port is in use by system
    if is_port_in_use "$port"; then
      port=$((port + 1))
      continue
    fi
    
    # Check if port is reserved in registry
    if echo "$used_ports" | grep -q "^$port$"; then
      port=$((port + 1))
      continue
    fi
    
    echo "$port"
    return
  done
}

cleanup_dead_processes() {
  local registry_data="$1"
  local updated_registry="$registry_data"
  
  # Get all project names
  local projects
  projects=$(echo "$registry_data" | jq -r 'keys[]' 2>/dev/null || echo "")
  
  for project in $projects; do
    local frontend_pid backend_pid
    frontend_pid=$(echo "$registry_data" | jq -r ".[\"$project\"].pid_frontend // \"null\"")
    backend_pid=$(echo "$registry_data" | jq -r ".[\"$project\"].pid_backend // \"null\"")
    
    # Check if processes are still running
    local frontend_running=false
    local backend_running=false
    
    if is_process_running "$frontend_pid"; then
      frontend_running=true
    fi
    
    if is_process_running "$backend_pid"; then
      backend_running=true
    fi
    
    # If both processes are dead, mark PIDs as null
    if [[ "$frontend_running" == false ]] && [[ "$backend_running" == false ]]; then
      echo "[INFO] Cleaning up dead processes for project: $project"
      updated_registry=$(echo "$updated_registry" | jq ".[\"$project\"].pid_frontend = null | .[\"$project\"].pid_backend = null")
    fi
  done
  
  echo "$updated_registry"
}

# Port management with registry
acquire_registry_lock

echo "Reading port registry..."
registry_data=$(read_registry)

echo "Cleaning up dead processes..."
registry_data=$(cleanup_dead_processes "$registry_data")

# Check if project already has assigned ports
existing_frontend=$(echo "$registry_data" | jq -r ".[\"$PROJECT_NAME\"].frontend_port // \"null\"")
existing_backend=$(echo "$registry_data" | jq -r ".[\"$PROJECT_NAME\"].backend_port // \"null\"")
existing_frontend_pid=$(echo "$registry_data" | jq -r ".[\"$PROJECT_NAME\"].pid_frontend // \"null\"")
existing_backend_pid=$(echo "$registry_data" | jq -r ".[\"$PROJECT_NAME\"].pid_backend // \"null\"")

FRONTEND_PORT=""
BACKEND_PORT=""

# Check if existing ports are still available
if [[ "$existing_frontend" != "null" ]] && [[ "$existing_backend" != "null" ]]; then
  # Check if processes are running
  frontend_running=false
  backend_running=false
  
  if is_process_running "$existing_frontend_pid"; then
    frontend_running=true
  fi
  
  if is_process_running "$existing_backend_pid"; then
    backend_running=true
  fi
  
  # If both processes are running, we can't use these ports
  if [[ "$frontend_running" == true ]] && [[ "$backend_running" == true ]]; then
    echo "[ERROR] Project $PROJECT_NAME is already running on ports $existing_frontend (frontend) and $existing_backend (backend)"
    echo "PIDs: frontend=$existing_frontend_pid, backend=$existing_backend_pid"
    release_registry_lock
    exit 1
  fi
  
  # If ports are not in use by other processes, reuse them
  if ! is_port_in_use "$existing_frontend" && ! is_port_in_use "$existing_backend"; then
    FRONTEND_PORT="$existing_frontend"
    BACKEND_PORT="$existing_backend"
    echo "Reusing existing ports for $PROJECT_NAME: frontend=$FRONTEND_PORT, backend=$BACKEND_PORT"
  fi
fi

# If we don't have ports yet, find new ones
if [[ -z "$FRONTEND_PORT" ]] || [[ -z "$BACKEND_PORT" ]]; then
  echo "Finding new free ports..."
  FRONTEND_PORT="${FRONTEND_START_PORT:-$(find_free_port 3000 "$registry_data")}"
  BACKEND_PORT="${BACKEND_START_PORT:-$(find_free_port 8000 "$registry_data")}"
  
  # Make sure backend port doesn't conflict with frontend
  if [[ "$BACKEND_PORT" == "$FRONTEND_PORT" ]]; then
    BACKEND_PORT=$(find_free_port $((BACKEND_PORT + 1)) "$registry_data")
  fi
  
  echo "Allocated new ports for $PROJECT_NAME: frontend=$FRONTEND_PORT, backend=$BACKEND_PORT"
fi

echo "Using FRONTEND_PORT=${FRONTEND_PORT} and BACKEND_PORT=${BACKEND_PORT}"

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

# Update registry with current project info
echo "Updating port registry..."
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
registry_data=$(echo "$registry_data" | jq \
  --arg project "$PROJECT_NAME" \
  --argjson frontend_port "$FRONTEND_PORT" \
  --argjson backend_port "$BACKEND_PORT" \
  --arg last_used "$current_time" \
  --argjson pid_frontend "$FRONT_PID" \
  --argjson pid_backend "$BACK_PID" \
  '.[$project] = {
    "frontend_port": $frontend_port,
    "backend_port": $backend_port,
    "last_used": $last_used,
    "pid_frontend": $pid_frontend,
    "pid_backend": $pid_backend
  }')

write_registry "$registry_data"
release_registry_lock

echo "Servers are starting in background."
echo "Backend:  http://localhost:${BACKEND_PORT}  (pid: ${BACK_PID})"
echo "Frontend: http://localhost:${FRONTEND_PORT}  (pid: ${FRONT_PID})"
echo "Logs: backend.log, frontend.log"

# Stop both on exit and clean registry
cleanup() {
  echo "Stopping servers..."
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
  
  # Clean up PIDs from registry
  echo "Cleaning up registry..."
  acquire_registry_lock
  local current_registry
  current_registry=$(read_registry)
  current_registry=$(echo "$current_registry" | jq \
    --arg project "$PROJECT_NAME" \
    '.[$project].pid_frontend = null | .[$project].pid_backend = null')
  write_registry "$current_registry"
  release_registry_lock
}
trap cleanup EXIT

# Keep script running to keep trap active
wait
