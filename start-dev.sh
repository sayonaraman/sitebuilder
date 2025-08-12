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

# Simple port checking
is_port_in_use() {
  local port="$1"
  ss -ltn | grep -q ":${port} " 2>/dev/null
}

# Get used ports from registry
get_used_ports() {
  if [[ -f "$REGISTRY_PATH" ]]; then
    jq -r '.[] | "\(.frontend_port)\n\(.backend_port)"' "$REGISTRY_PATH" 2>/dev/null | grep -v null || true
  fi
}

# Find next free port
find_free_port() {
  local start_port="$1"
  local used_ports
  used_ports=$(get_used_ports)
  
  local port="$start_port"
  while true; do
    # Check if port is in system use
    if is_port_in_use "$port"; then
      port=$((port + 1))
      continue
    fi
    
    # Check if port is in registry
    if echo "$used_ports" | grep -q "^$port$"; then
      port=$((port + 1))
      continue
    fi
    
    echo "$port"
    return
  done
}

# Get or assign ports
if [[ -f "$REGISTRY_PATH" ]] && jq -e ".[\"$PROJECT_NAME\"]" "$REGISTRY_PATH" >/dev/null 2>&1; then
  # Project exists in registry - reuse ports
  FRONTEND_PORT=$(jq -r ".[\"$PROJECT_NAME\"].frontend_port" "$REGISTRY_PATH")
  BACKEND_PORT=$(jq -r ".[\"$PROJECT_NAME\"].backend_port" "$REGISTRY_PATH")
  echo "Reusing existing ports: frontend=$FRONTEND_PORT, backend=$BACKEND_PORT"
else
  # New project - find free ports
  FRONTEND_PORT=$(find_free_port 3000)
  BACKEND_PORT=$(find_free_port 8000)
  
  # Make sure backend doesn't conflict with frontend
  if [[ "$BACKEND_PORT" == "$FRONTEND_PORT" ]]; then
    BACKEND_PORT=$(find_free_port $((FRONTEND_PORT + 1000)))
  fi
  
  echo "New project - allocated ports: frontend=$FRONTEND_PORT, backend=$BACKEND_PORT"
fi

echo "Using ports: frontend=$FRONTEND_PORT, backend=$BACKEND_PORT"

# Create venv if missing
if [[ ! -f "venv/bin/python" ]]; then
  echo "Creating virtual environment..."
  python3 -m venv venv
fi

echo "Upgrading pip..."
venv/bin/python -m pip install --upgrade pip

echo "Installing backend dependencies..."
venv/bin/python -m pip install -r backend/requirements.txt

# Environment setup
SITE_TITLE="${SITE_TITLE:-test-pixbit.pro}"
BUTTON_TEXT="${BUTTON_TEXT:-pixbit.pro}"
BUTTON_HREF="${BUTTON_HREF:-https://pixbit.pro}"
FAVICON_URL="${FAVICON_URL:-}"

# Backend .env
if [[ ! -f backend/.env ]]; then
  echo "Creating backend/.env..."
  cat > backend/.env << EOF
MONGO_URL=${MONGO_URL:-mongodb://localhost:27017}
DB_NAME=${DB_NAME:-advocat}
CORS_ORIGINS=${CORS_ORIGINS:-http://localhost:${FRONTEND_PORT}}
EOF
fi

# Frontend .env
SERVER_HOST_DEFAULT=$(hostname -I 2>/dev/null | awk '{print $1}') || true
SERVER_HOST="${SERVER_HOST:-${SERVER_HOST_DEFAULT:-localhost}}"
cat > frontend/.env << EOF
REACT_APP_BACKEND_URL=http://${SERVER_HOST}:${BACKEND_PORT}
EOF

# Choose package manager
PKG="npm"
if command -v yarn >/dev/null 2>&1; then
  PKG="yarn"
fi

echo "Installing frontend dependencies with $PKG..."
pushd frontend >/dev/null
if [[ "$PKG" == "yarn" ]]; then
  yarn install
else
  npm install
fi
popd >/dev/null

# HTML branding updates
INDEX_PATH="frontend/public/index.html"
if [[ -f "$INDEX_PATH" ]]; then
  sed -i "s#<title>[^<]*</title>#<title>$SITE_TITLE</title>#" "$INDEX_PATH" || true
  sed -i "s#Made with Emergent#$BUTTON_TEXT#g" "$INDEX_PATH" || true
  sed -i "s#https://app.emergent.sh#$BUTTON_HREF#g" "$INDEX_PATH" || true
  
  if [[ -n "$FAVICON_URL" ]]; then
    if ! grep -q 'rel="icon"' "$INDEX_PATH"; then
      sed -i "s#</head>#  <link rel=\"icon\" href=\"$FAVICON_URL\"/>\n</head>#" "$INDEX_PATH" || true
    fi
  fi
fi

# Update registry BEFORE starting services
echo "Updating registry..."
if [[ -f "$REGISTRY_PATH" ]]; then
  # Update existing registry
  jq --arg project "$PROJECT_NAME" \
     --argjson frontend "$FRONTEND_PORT" \
     --argjson backend "$BACKEND_PORT" \
     '.[$project] = {"frontend_port": $frontend, "backend_port": $backend}' \
     "$REGISTRY_PATH" > "$REGISTRY_PATH.tmp" && mv "$REGISTRY_PATH.tmp" "$REGISTRY_PATH"
else
  # Create new registry
  jq -n --arg project "$PROJECT_NAME" \
        --argjson frontend "$FRONTEND_PORT" \
        --argjson backend "$BACKEND_PORT" \
        '{($project): {"frontend_port": $frontend, "backend_port": $backend}}' \
        > "$REGISTRY_PATH"
fi

echo "Registry updated successfully"

# Start services
echo "Starting servers..."
export CORS_ORIGINS="http://$SERVER_HOST:$FRONTEND_PORT,http://localhost:$FRONTEND_PORT"

# Start backend
venv/bin/python -m uvicorn backend.server:app --reload --host 0.0.0.0 --port "$BACKEND_PORT" > backend.log 2>&1 &
BACK_PID=$!

# Start frontend  
pushd frontend >/dev/null
if [[ "$PKG" == "yarn" ]]; then
  PORT="$FRONTEND_PORT" yarn start > ../frontend.log 2>&1 &
else
  PORT="$FRONTEND_PORT" npm start > ../frontend.log 2>&1 &
fi
FRONT_PID=$!
popd >/dev/null

echo "Servers starting..."
echo "Backend:  http://localhost:$BACKEND_PORT  (pid: $BACK_PID)"
echo "Frontend: http://localhost:$FRONTEND_PORT  (pid: $FRONT_PID)"
echo "Logs: backend.log, frontend.log"

# Simple cleanup on exit
cleanup() {
  echo "Stopping servers..."
  kill "$BACK_PID" "$FRONT_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Keep running
wait
