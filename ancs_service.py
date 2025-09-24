"""
ANCS Mirror (Python)

A minimal Bluetooth LE ANCS (Apple Notification Center Service) client for Linux/Raspberry Pi
using the Bleak library. It connects to a paired iPhone, subscribes to notification streams,
and prints readable summaries (title/message) for new notifications.

Prerequisites
- Python 3.9+
- Linux with BlueZ (e.g., Raspberry Pi OS). Ensure BLE is enabled.
- Bleak:    pip install bleak
- Pairing:  Put iPhone near the Pi. The Pi (as BLE central) will connect and iOS should prompt to pair.
            Accept the pairing request. If you don’t see notifications, unpair/retry.
- Permissions: On some systems you may need to run with sudo or grant BLE capabilities.

Usage
- Scan and auto-connect to the first device advertising ANCS:
    python ancs_mirror.py

- Connect to a specific device by Bluetooth MAC address:
    python ancs_mirror.py --address XX:XX:XX:XX:XX:XX

Notes
- This script focuses on printing concise summaries to stdout. Integrate your own display logic
  (e.g., driving an e-paper or HDMI display) where indicated below.
- iOS exposes ANCS when bonded. Make sure the device remains paired.

References
- ANCS UUIDs and packet formats are based on Apple’s public ANCS specification.
"""

import asyncio
import argparse
import sys
from dataclasses import dataclass
from typing import Dict, Optional

from bleak import BleakScanner, BleakClient

import os
import json

# Simple config file to remember the iPhone MAC address
CONFIG_FILE = os.path.expanduser("~/.ancs_mirror.json")

def load_saved_address() -> Optional[str]:
    try:
        with open(CONFIG_FILE, "r") as f:
            data = json.load(f)
        addr = data.get("address")
        if isinstance(addr, str) and addr:
            return addr
    except Exception:
        pass
    return None


def save_address(address: str) -> None:
    try:
        with open(CONFIG_FILE, "w") as f:
            json.dump({"address": address}, f)
        print(f"[cfg] Saved address to {CONFIG_FILE}")
    except Exception as e:
        print(f"[cfg] Failed to save address: {e}")


def clear_saved_address() -> None:
    try:
        if os.path.exists(CONFIG_FILE):
            os.remove(CONFIG_FILE)
            print(f"[cfg] Cleared saved address at {CONFIG_FILE}")
    except Exception as e:
        print(f"[cfg] Failed to clear saved address: {e}")

# ANCS UUIDs
ANCS_SERVICE_UUID = "7905F431-B5CE-4E99-A40F-4B1E122D00D0"
NS_CHAR_UUID = "9FBF120D-6301-42D9-8C58-25E699A21DBD"   # Notification Source (notify)
CP_CHAR_UUID = "69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9"   # Control Point (write)
DS_CHAR_UUID = "22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB"   # Data Source (notify)

# Event IDs
EVENT_ADDED = 0
EVENT_MODIFIED = 1
EVENT_REMOVED = 2

# Category IDs (subset)
CATEGORIES = {
    0: "Other",
    1: "IncomingCall",
    2: "MissedCall",
    3: "Voicemail",
    4: "Social",
    5: "Schedule",
    6: "Email",
    7: "News",
    8: "Health",
    9: "Business",
    10: "Location",
    11: "Entertainment",
}

# Control Point Command IDs
CP_GET_NOTIFICATION_ATTRIBUTES = 0
CP_GET_APP_ATTRIBUTES = 1

# Notification Attribute IDs
NA_APP_IDENTIFIER = 0
NA_TITLE = 1           # requires max length (u16)
NA_SUBTITLE = 2        # requires max length (u16)
NA_MESSAGE = 3         # requires max length (u16)
NA_MESSAGE_SIZE = 4
NA_DATE = 5
NA_POSITIVE_ACTION_LABEL = 6
NA_NEGATIVE_ACTION_LABEL = 7

# Reasonable max sizes to avoid huge payloads
MAX_TITLE_LEN = 64
MAX_MESSAGE_LEN = 256

@dataclass
class PendingRequest:
    uid: int
    expecting: str  # "notification_attributes" or other


class ANCSMirror:
    def __init__(self, address: Optional[str] = None, remember: bool = False):
        self.address = address
        self.remember = remember
        self.client: Optional[BleakClient] = None
        self.pending: Dict[int, PendingRequest] = {}

    async def scan_and_pick(self) -> Optional[str]:
        print("[scan] Scanning for devices advertising ANCS service...")
        devices = await BleakScanner.discover(service_uuids=[ANCS_SERVICE_UUID])
        for d in devices:
            # iPhones often advertise random names; we rely on ANCS service filter above
            print(f"[scan] Found: {d.name or 'Unknown'} @ {d.address}")
        if not devices:
            print("[scan] No devices found advertising ANCS. Ensure iPhone is nearby and unlocked.")
            return None
        chosen = devices[0].address
        print(f"[scan] Choosing {devices[0].name or 'Unknown'} @ {chosen}")
        return chosen

    async def connect(self):
        addr = self.address or await self.scan_and_pick()
        if not addr:
            raise RuntimeError("No suitable device found to connect.")

        print(f"[ble] Connecting to {addr} ...")
        self.client = BleakClient(addr)
        await self.client.connect()
        if not self.client.is_connected:
            raise RuntimeError("Failed to connect to device.")
        print("[ble] Connected.")

        # Optionally remember the address for future runs
        if self.remember:
            save_address(addr)

        # Ensure service is present
        services = await self.client.get_services()
        if ANCS_SERVICE_UUID.lower() not in {s.uuid.lower() for s in services}:
            print("[warn] ANCS service not present; pairing/bonding may be required.")

        # Subscribe to Notification Source and Data Source
        await self.client.start_notify(NS_CHAR_UUID, self._on_notification_source)
        await self.client.start_notify(DS_CHAR_UUID, self._on_data_source)
        print("[ble] Subscribed to Notification and Data sources.")

    async def run(self):
        try:
            await self.connect()
            print("[ancs] Waiting for notifications. Press Ctrl+C to exit.")
            while True:
                await asyncio.sleep(1)
        except KeyboardInterrupt:
            print("\n[ancs] Exiting on user request.")
        finally:
            if self.client and self.client.is_connected:
                try:
                    await self.client.stop_notify(NS_CHAR_UUID)
                    await self.client.stop_notify(DS_CHAR_UUID)
                except Exception:
                    pass
                await self.client.disconnect()
                print("[ble] Disconnected.")

    # --- Handlers ---

    def _on_notification_source(self, _handle: int, data: bytearray):
        # Packet format (little-endian):
        # 0: EventID (1B)
        # 1: EventFlags (1B bitfield)
        # 2: CategoryID (1B)
        # 3: CategoryCount (1B)
        # 4-7: NotificationUID (4B LE)
        if len(data) < 8:
            print(f"[ns] Short packet: {data.hex()}")
            return
        event_id = data[0]
        event_flags = data[1]
        category_id = data[2]
        category_count = data[3]
        uid = int.from_bytes(data[4:8], byteorder="little")

        category = CATEGORIES.get(category_id, f"Unknown({category_id})")
        event_name = {0: "Added", 1: "Modified", 2: "Removed"}.get(event_id, f"Unknown({event_id})")

        print(f"[ns] {event_name}: uid={uid} category={category} (count={category_count}) flags=0b{event_flags:08b}")

        if event_id == EVENT_ADDED:
            # Request notification attributes for title + message
            asyncio.create_task(self._request_notification_attributes(uid))
        elif event_id == EVENT_REMOVED:
            # Clean up any pending state
            self.pending.pop(uid, None)

    def _parse_tlv_attributes(self, data: bytes) -> Dict[int, bytes]:
        # TLV: attr_id (1B), len (2B LE), value (len bytes)
        out: Dict[int, bytes] = {}
        i = 0
        while i + 3 <= len(data):
            attr_id = data[i]
            length = int.from_bytes(data[i+1:i+3], byteorder="little")
            i += 3
            if i + length > len(data):
                break
            value = data[i:i+length]
            out[attr_id] = value
            i += length
        return out

    def _on_data_source(self, _handle: int, data: bytearray):
        # Response packets depend on the last CP command. For Get Notification Attributes,
        # the response starts with the NotificationUID (4B), followed by TLV attributes.
        if len(data) < 4:
            print(f"[ds] Short packet: {data.hex()}")
            return
        uid = int.from_bytes(data[0:4], byteorder="little")
        payload = bytes(data[4:])
        attrs = self._parse_tlv_attributes(payload)

        title = attrs.get(NA_TITLE, b"").decode(errors="ignore")
        message = attrs.get(NA_MESSAGE, b"").decode(errors="ignore")
        app_id = attrs.get(NA_APP_IDENTIFIER, b"").decode(errors="ignore")

        # Trim/clean
        title = title.strip("\x00\n\r ")
        message = message.strip("\x00\n\r ")
        app_id = app_id.strip("\x00\n\r ")

        # Display summary
        # Integrate your own display logic here (e.g., draw to screen, send to another service, etc.)
        print("[ds] Notification Attributes:")
        if app_id:
            print(f"     App: {app_id}")
        if title:
            print(f"   Title: {title}")
        if message:
            preview = message if len(message) <= 200 else message[:200] + "…"
            print(f" Message: {preview}")
        if not (app_id or title or message):
            print(f"   (no attributes) raw={payload.hex()}")

        # Done with this UID; clear pending
        self.pending.pop(uid, None)

    async def _request_notification_attributes(self, uid: int):
        if not self.client:
            return
        # Build CP command:
        # [CmdID=0][UID(4B)][AttrID=AppIdentifier]
        # [AttrID=Title][MaxLen(2B LE)]
        # [AttrID=Message][MaxLen(2B LE)]
        cmd = bytearray()
        cmd.append(CP_GET_NOTIFICATION_ATTRIBUTES)
        cmd += uid.to_bytes(4, byteorder="little")

        cmd.append(NA_APP_IDENTIFIER)

        cmd.append(NA_TITLE)
        cmd += MAX_TITLE_LEN.to_bytes(2, byteorder="little")

        cmd.append(NA_MESSAGE)
        cmd += MAX_MESSAGE_LEN.to_bytes(2, byteorder="little")

        try:
            self.pending[uid] = PendingRequest(uid=uid, expecting="notification_attributes")
            await self.client.write_gatt_char(CP_CHAR_UUID, bytes(cmd), response=True)
            print(f"[cp] Requested attributes for uid={uid}")
        except Exception as e:
            print(f"[cp] Write failed: {e}")
            self.pending.pop(uid, None)


async def main():
    parser = argparse.ArgumentParser(description="ANCS Mirror (Bleak)")
    parser.add_argument("--address", help="Bluetooth MAC address of the iPhone (optional)")
    parser.add_argument("--remember-address", action="store_true", help="Save the connected device address for future runs")
    parser.add_argument("--forget-address", action="store_true", help="Clear any saved address before connecting")
    args = parser.parse_args()

    # Handle config: forget if requested, otherwise try to use saved address
    if args.forget_address:
        clear_saved_address()

    saved_addr = load_saved_address()
    effective_address = args.address or saved_addr
    if saved_addr and not args.address:
        print(f"[cfg] Using saved address {saved_addr}")

    mirror = ANCSMirror(address=effective_address, remember=args.remember_address)
    await mirror.run()


if __name__ == "__main__":
    if sys.platform not in ("linux", "linux2"):
        print("[warn] This script is intended for Linux/BlueZ (e.g., Raspberry Pi). Bleak on macOS/Windows cannot act as a BLE central for ANCS to an iPhone.")
    asyncio.run(main())

