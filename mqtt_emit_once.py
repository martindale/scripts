#!/usr/bin/env python3
"""
Single MQTT publish (one message) — usable as a CLI or imported.

Environment (same defaults as mqtt_battery_broadcaster.py):
  MQTT_BROKER, MQTT_PORT, MQTT_TOPIC, MQTT_USERNAME, MQTT_PASSWORD
  MQTT_QOS (0|1|2, default 1), MQTT_RETAIN (0|1, default 0)

CLI examples:
  python3 mqtt_emit_once.py '{"ping":true}'
  python3 mqtt_emit_once.py --topic sensors/demo --message hello
  echo '{"x":1}' | python3 mqtt_emit_once.py

Python:
  from mqtt_emit_once import emit_once
  emit_once('{"ping":true}')
"""
from __future__ import annotations

import argparse
import errno
import json
import logging
import os
import sys
import threading
from typing import List, Optional, Tuple

import paho.mqtt.client as mqtt

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

MQTT_BROKER = os.getenv("MQTT_BROKER", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "home/battery/status")
MQTT_USERNAME = os.getenv("MQTT_USERNAME", None)
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", None)
MQTT_QOS = int(os.getenv("MQTT_QOS", "1"))
MQTT_RETAIN = os.getenv("MQTT_RETAIN", "0").strip() in ("1", "true", "yes")


def _make_mqtt_client() -> Tuple[mqtt.Client, str]:
    try:
        from paho.mqtt.enums import CallbackAPIVersion

        return mqtt.Client(callback_api_version=CallbackAPIVersion.VERSION2), "v2"
    except (ImportError, AttributeError, TypeError):
        return mqtt.Client(), "v1"


def emit_once(
    payload: str | bytes,
    *,
    topic: Optional[str] = None,
    broker: Optional[str] = None,
    port: Optional[int] = None,
    qos: Optional[int] = None,
    retain: Optional[bool] = None,
    username: Optional[str] = None,
    password: Optional[str] = None,
    connect_timeout: float = 10.0,
    publish_timeout: float = 15.0,
) -> None:
    """
    Connect, publish one message, wait for broker flow to finish, disconnect.

    Raises on connection or publish failure.
    """
    topic = topic or MQTT_TOPIC
    broker = broker or MQTT_BROKER
    port = int(port if port is not None else MQTT_PORT)
    if qos is None:
        qos = MQTT_QOS
    if retain is None:
        retain = MQTT_RETAIN
    user = username if username is not None else MQTT_USERNAME
    pwd = password if password is not None else MQTT_PASSWORD

    if isinstance(payload, str):
        payload_bytes = payload.encode("utf-8")
    else:
        payload_bytes = payload

    connected = threading.Event()
    failed_reason: List[object] = []

    client, api = _make_mqtt_client()

    def on_connect_v2(client, userdata, connect_flags, reason_code, properties):
        if reason_code == 0:
            connected.set()
        else:
            failed_reason.append(reason_code)

    def on_connect_v1(client, userdata, flags, rc):
        if rc == 0:
            connected.set()
        else:
            failed_reason.append(rc)

    if api == "v2":
        client.on_connect = on_connect_v2
    else:
        client.on_connect = on_connect_v1

    if user and pwd:
        client.username_pw_set(user, pwd)

    try:
        logger.info("Connecting to %s:%s …", broker, port)
        client.connect(broker, port, keepalive=60)
        client.loop_start()
        if not connected.wait(timeout=connect_timeout):
            raise TimeoutError(
                f"No CONNACK from broker at {broker}:{port} within {connect_timeout}s"
            )
        if failed_reason:
            raise RuntimeError(f"Connection failed: {failed_reason[0]!r}")

        logger.info("Publishing to %s (qos=%s retain=%s)", topic, qos, retain)
        msg = client.publish(topic, payload_bytes, qos=qos, retain=retain)
        if msg.rc != mqtt.MQTT_ERR_SUCCESS:
            raise RuntimeError(f"publish() rejected: rc={msg.rc}")
        msg.wait_for_publish(timeout=publish_timeout)
        logger.info("Publish complete.")
    except ConnectionRefusedError:
        logger.error(
            "Connection refused to %s:%s — is Mosquitto (or another broker) listening?",
            broker,
            port,
        )
        raise
    except OSError as e:
        if e.errno == errno.ECONNREFUSED:
            logger.error("Connection refused to %s:%s", broker, port)
        raise
    finally:
        client.loop_stop()
        try:
            client.disconnect()
        except Exception:
            pass


def main(argv: Optional[List[str]] = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    p = argparse.ArgumentParser(description="Publish a single MQTT message.")
    p.add_argument(
        "payload",
        nargs="?",
        default=None,
        metavar="PAYLOAD",
        help="Message body (string). Topic defaults from MQTT_TOPIC unless --topic is set.",
    )
    p.add_argument("-m", "--message", help="Message body (alternative to positional).")
    p.add_argument("--topic", default=None, help=f"Topic (default env MQTT_TOPIC={MQTT_TOPIC!r})")
    p.add_argument("--broker", default=None, help=f"Host (default {MQTT_BROKER!r})")
    p.add_argument("--port", type=int, default=None, help=f"Port (default {MQTT_PORT})")
    p.add_argument("--qos", type=int, default=None, choices=(0, 1, 2), help="QoS level")
    p.add_argument(
        "--retain",
        action="store_true",
        help="Set MQTT retain flag",
    )
    p.add_argument(
        "--json",
        type=json.loads,
        metavar="OBJECT",
        help="Publish JSON object (serialized)",
    )
    ns = p.parse_args(argv)

    if ns.json is not None:
        raw = json.dumps(ns.json)
    elif ns.message is not None:
        raw = ns.message
    elif ns.payload is not None:
        raw = ns.payload
    elif not sys.stdin.isatty():
        raw = sys.stdin.read()
    else:
        print(
            "No payload: pass PAYLOAD, use -m/--message, --json, or pipe stdin.",
            file=sys.stderr,
        )
        p.print_help()
        return 2

    try:
        emit_once(
            raw,
            topic=ns.topic,
            broker=ns.broker,
            port=ns.port,
            qos=ns.qos,
            retain=True if ns.retain else None,
        )
    except Exception as e:
        logger.error("%s", e)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
