import paho.mqtt.client as mqtt
import psutil
import os
import time
import logging
import signal
import json
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# MQTT Configuration
MQTT_BROKER = os.getenv('MQTT_BROKER', 'localhost')
MQTT_PORT = int(os.getenv('MQTT_PORT', 1883))
MQTT_TOPIC = os.getenv('MQTT_TOPIC', 'home/battery/status')
MQTT_USERNAME = os.getenv('MQTT_USERNAME', None)
MQTT_PASSWORD = os.getenv('MQTT_PASSWORD', None)
BROADCAST_INTERVAL = int(os.getenv('BROADCAST_INTERVAL', 60))

# Global flag for graceful shutdown
running = True

def signal_handler(sig, frame):
    global running
    logger.info("Shutdown signal received, stopping...")
    running = False

def get_battery_status():
    """
    Get detailed battery status information.
    Returns a dictionary with battery metrics or None if unavailable.
    """
    try:
        battery = psutil.sensors_battery()
        if battery is None:
            logger.warning("Battery information not available on this system")
            return None
        
        return {
            'percent': int(battery.percent),
            'is_charging': battery.power_plugged,
            'time_left': str(battery.secsleft) if battery.secsleft != psutil.POWER_TIME_UNLIMITED else 'N/A',
            'status': 'charging' if battery.power_plugged else 'discharging',
            'timestamp': datetime.utcnow().isoformat() + 'Z'
        }
    except Exception as e:
        logger.error(f"Error retrieving battery status: {e}")
        return None

def on_connect(client, userdata, flags, rc):
    """Callback when MQTT client connects."""
    if rc == 0:
        logger.info(f"Connected to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
    else:
        logger.error(f"Failed to connect to MQTT broker, return code {rc}")

def on_disconnect(client, userdata, rc):
    """Callback when MQTT client disconnects."""
    if rc != 0:
        logger.warning(f"Unexpected disconnection from MQTT broker (code {rc})")

def on_publish(client, userdata, mid):
    """Callback when message is published."""
    logger.debug(f"Message published with id: {mid}")

def main():
    """Main function to publish battery status to MQTT."""
    global running
    
    # Setup signal handlers for graceful shutdown
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Create MQTT client
    client = mqtt.Client()
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_publish = on_publish
    
    # Set credentials if provided
    if MQTT_USERNAME and MQTT_PASSWORD:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    
    try:
        logger.info(f"Connecting to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()
        
        logger.info(f"Starting battery status broadcast to topic: {MQTT_TOPIC}")
        logger.info(f"Broadcast interval: {BROADCAST_INTERVAL} seconds")
        
        while running:
            status = get_battery_status()
            if status is not None:
                payload = json.dumps(status)
                result = client.publish(MQTT_TOPIC, payload, qos=1)
                if result.rc == mqtt.MQTT_ERR_SUCCESS:
                    logger.info(f"Published battery status: {status['percent']}% - {status['status']}")
                else:
                    logger.warning(f"Failed to publish message, return code: {result.rc}")
            time.sleep(BROADCAST_INTERVAL)
    
    except Exception as e:
        logger.error(f"Error in main loop: {e}")
    
    finally:
        logger.info("Shutting down...")
        client.loop_stop()
        client.disconnect()
        logger.info("Disconnected from MQTT broker")

if __name__ == '__main__':
    main()