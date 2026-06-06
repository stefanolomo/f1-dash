#!/usr/bin/env bash
# dev.sh — Starts realtime, api and dashboard in parallel
# Usage: ./dev.sh [--simulator]
# With --simulator, it also starts the F1 simulator and points realtime to it

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS=()

# Colors to distinguish the output of each service
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

USE_SIMULATOR=false
for arg in "$@"; do
  [[ "$arg" == "--simulator" ]] && USE_SIMULATOR=true
done

# ── Prefixes each line of stdout/stderr from a process with its colored label
prefix_output() {
  local label="$1" color="$2"
  while IFS= read -r line; do
    echo -e "${color}${BOLD}[${label}]${RESET} ${line}"
  done
}

# ── Cleanup on exit (Ctrl+C or error)
cleanup() {
  echo -e "\n${YELLOW}${BOLD}[dev]${RESET} Stopping services..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo -e "${YELLOW}${BOLD}[dev]${RESET} Done."
}
trap cleanup EXIT INT TERM

# ── Kills processes already using the ports and clears Next.js locks
free_ports() {
  local ports=(4000 4001 3000)
  $USE_SIMULATOR && ports+=(8000)

  # fuser handles IPv4 and IPv6 correctly; lsof as a fallback
  for port in "${ports[@]}"; do
    if command -v fuser &>/dev/null; then
      fuser -k "${port}/tcp" 2>/dev/null || true
    else
      local pid
      pid=$(lsof -ti "tcp:${port}" 2>/dev/null || true)
      [[ -n "$pid" ]] && kill $pid 2>/dev/null || true
    fi
  done

  # Next.js maintains its own internal lock — we clear it to avoid
  # the "Another next dev server is already running" error
  rm -rf "$ROOT/dashboard/.next/dev" 2>/dev/null || true

  # Kill by name any binaries that might have been orphaned
  pkill -f "target/debug/realtime" 2>/dev/null || true
  pkill -f "target/debug/api"      2>/dev/null || true
  pkill -f "target/debug/simulator" 2>/dev/null || true

  sleep 0.5
}
free_ports

# ── Compiles Rust binaries if they do not exist or are outdated
echo -e "${BOLD}[dev]${RESET} Compiling Rust services..."
CARGO_PACKAGES=(-p realtime -p api)
$USE_SIMULATOR && CARGO_PACKAGES+=(-p simulator)
cargo build "${CARGO_PACKAGES[@]}" --quiet 2>&1 \
  | prefix_output "cargo" "$MAGENTA"

# ── Starts the simulator (optional)
if $USE_SIMULATOR; then
  echo -e "${MAGENTA}${BOLD}[dev]${RESET} Starting simulator on :8000"
  (
    set -a; source "$ROOT/simulator/.env" 2>/dev/null || true; set +a
    exec "$ROOT/target/debug/simulator"
  ) 2>&1 | prefix_output "simulator" "$MAGENTA" &
  PIDS+=($!)
  sleep 1 # give the simulator time to start
fi

# ── Starts realtime
echo -e "${CYAN}${BOLD}[dev]${RESET} Starting realtime on :4000"
(
  set -a
  source "$ROOT/realtime/.env"
  # If the simulator is used, point to it
  $USE_SIMULATOR && export F1_DEV_URL="ws://127.0.0.1:8000/ws"
  set +a
  exec "$ROOT/target/debug/realtime"
) 2>&1 | prefix_output "realtime" "$CYAN" &
PIDS+=($!)

# ── Starts api
echo -e "${GREEN}${BOLD}[dev]${RESET} Starting api on :4001"
(
  set -a; source "$ROOT/api/.env"; set +a
  exec "$ROOT/target/debug/api"
) 2>&1 | prefix_output "api" "$GREEN" &
PIDS+=($!)

# ── Starts the Next.js dashboard
echo -e "${YELLOW}${BOLD}[dev]${RESET} Starting dashboard on :3000"
(
  cd "$ROOT/dashboard"
  exec npm run dev 2>&1
) | prefix_output "dashboard" "$YELLOW" &
PIDS+=($!)

echo -e "\n${BOLD}Services running:${RESET}"
echo -e "  ${CYAN}● realtime${RESET}   http://localhost:4000/api/health"
echo -e "  ${GREEN}● api${RESET}        http://localhost:4001"
echo -e "  ${YELLOW}● dashboard${RESET}  http://localhost:3000"
$USE_SIMULATOR && echo -e "  ${MAGENTA}● simulator${RESET}  ws://localhost:8000/ws"
echo -e "\n${BOLD}Ctrl+C to stop all services.${RESET}\n"

# Waits for any child process to exit (indicates an error)
wait -n "${PIDS[@]}" 2>/dev/null || true
echo -e "\n${RED}${BOLD}[dev]${RESET} A service terminated unexpectedly. Stopping the rest..."
