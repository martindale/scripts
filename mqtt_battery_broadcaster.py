import json
import logging
import os
import platform
import re
import signal
import subprocess
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import paho.mqtt.client as mqtt
import psutil

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# MQTT Configuration
MQTT_BROKER = os.getenv("MQTT_BROKER", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", 1883))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "home/battery/status")
MQTT_USERNAME = os.getenv("MQTT_USERNAME", None)
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", None)
BROADCAST_INTERVAL = int(os.getenv("BROADCAST_INTERVAL", 60))

# Global flag for graceful shutdown
running = True


def signal_handler(sig, frame):
    global running
    logger.info("Shutdown signal received, stopping...")
    running = False


def _parse_pmset_batt(output: str) -> Optional[Dict[str, Any]]:
    """
    Parse `pmset -g batt` output (macOS). Matches psutil semantics: is_charging mirrors
    power_plugged (AC adapter connected), not whether the cell is actively accepting charge.
    """
    lines = [ln.strip() for ln in output.strip().splitlines() if ln.strip()]
    if not lines:
        return None

    ac_line = lines[0]
    batt_line = next(
        (ln for ln in lines if "InternalBattery" in ln or re.search(r"\d+%", ln)),
        None,
    )
    if not batt_line:
        return None

    m_pct = re.search(r"(\d+)%", batt_line)
    if not m_pct:
        return None
    percent = int(m_pct.group(1))

    # psutil.sensors_battery().power_plugged: AC power line connected
    power_plugged = "AC Power" in ac_line
    status = "charging" if power_plugged else "discharging"

    time_left = "N/A"
    m_rem = re.search(r"(\d+:\d+)\s+remaining", batt_line, re.IGNORECASE)
    m_full = re.search(r"(\d+:\d+)\s+until full", batt_line, re.IGNORECASE)
    if m_rem:
        time_left = m_rem.group(1)
    elif m_full:
        time_left = m_full.group(1)

    return {
        "percent": percent,
        "is_charging": power_plugged,
        "time_left": time_left,
        "status": status,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def _battery_from_macos_pmset() -> Optional[Dict[str, Any]]:
    try:
        completed = subprocess.run(
            ["pmset", "-g", "batt"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (FileNotFoundError, OSError) as e:
        logger.debug("pmset not available: %s", e)
        return None

    if completed.returncode != 0:
        logger.warning(
            "pmset -g batt failed (code %s): %s",
            completed.returncode,
            (completed.stderr or "").strip() or completed.stdout,
        )
        return None

    return _parse_pmset_batt(completed.stdout or "")


def get_battery_status() -> Optional[Dict[str, Any]]:
    """
    Get detailed battery status information.
    Returns a dictionary with battery metrics or None if unavailable.
    """
    try:
        battery = psutil.sensors_battery()
        if battery is not None:
            return {
                "percent": int(battery.percent),
                "is_charging": battery.power_plugged,
                "time_left": (
                    str(battery.secsleft)
                    if battery.secsleft != psutil.POWER_TIME_UNLIMITED
                    else "N/A"
                ),
                "status": "charging" if battery.power_plugged else "discharging",
                "timestamp": datetime.now(timezone.utc)
                .isoformat()
                .replace("+00:00", "Z"),
            }
    except Exception as e:
        logger.error("Error retrieving battery status via psutil: %s", e)

    if platform.system() == "Darwin":
        pmset_status = _battery_from_macos_pmset()
        if pmset_status is not None:
            return pmset_status
        logger.warning(
            "Battery information not available (psutil returned None and pmset parse failed)"
        )
        return None

    logger.warning("Battery information not available on this system")
    return None


def on_connect(client, userdata, flags, rc):
    """Callback when MQTT client connects."""
    if rc == 0:
        logger.info("Connected to MQTT broker at %s:%s", MQTT_BROKER, MQTT_PORT)
    else:
        logger.error("Failed to connect to MQTT broker, return code %s", rc)


def on_disconnect(client, userdata, rc):
    """Callback when MQTT client disconnects."""
    if rc != 0:
        logger.warning("Unexpected disconnection from MQTT broker (code %s)", rc)


def on_publish(client, userdata, mid):
    """Callback when message is published."""
    logger.debug("Message published with id: %s", mid)


def _make_mqtt_client():
    """Construct a paho client compatible with v1 and v2 APIs."""
    try:
        from paho.mqtt.enums import CallbackAPIVersion

        return mqtt.Client(callback_api_version=CallbackAPIVersion.VERSION1)
    except (ImportError, AttributeError, TypeError):
        return mqtt.Client()


def main():
    """Main function to publish battery status to MQTT."""
    global running

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    client = _make_mqtt_client()
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_publish = on_publish

    if MQTT_USERNAME and MQTT_PASSWORD:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)

    try:
        logger.info("Connecting to MQTT broker at %s:%s", MQTT_BROKER, MQTT_PORT)
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()

        logger.info("Starting battery status broadcast to topic: %s", MQTT_TOPIC)
        logger.info("Broadcast interval: %s seconds", BROADCAST_INTERVAL)

        while running:
            status = get_battery_status()
            if status is not None:
                payload = json.dumps(status)
                result = client.publish(MQTT_TOPIC, payload, qos=1)
                if result.rc == mqtt.MQTT_ERR_SUCCESS:
                    logger.info(
                        "Published battery status: %s%% - %s",
                        status["percent"],
                        status["status"],
                    )
                else:
                    logger.warning("Failed to publish message, return code: %s", result.rc)
            time.sleep(BROADCAST_INTERVAL)

    except Exception as e:
        logger.error("Error in main loop: %s", e)

    finally:
        logger.info("Shutting down...")
        client.loop_stop()
        client.disconnect()
        logger.info("Disconnected from MQTT broker")


if __name__ == "__main__":
    main()
