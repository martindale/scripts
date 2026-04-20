#!/usr/bin/env bash
# Start Mosquitto on localhost:1883 (Docker). Matches mqtt_battery_broadcaster defaults.
# Usage: ./mqtt/start-local-mqtt.sh   (from repository root)
# Logs: docker compose -f mqtt/docker-compose.yml logs -f
# Stop: docker compose -f mqtt/docker-compose.yml down
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec docker compose -f mqtt/docker-compose.yml up -d "$@"
