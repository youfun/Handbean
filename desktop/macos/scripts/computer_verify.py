#!/usr/bin/env python3
"""Manual native transport client. Never grants TCC or clicks approvals.

Usage: computer_verify.py DIR list|select|observe|click|type|key|scroll|stop
  --window ID --receipt ID --x PIXELS --y PIXELS --text TEXT --key KEY
  --deadline-ms 60000 --disconnect-after 1 --session verification-run-1
"""
import argparse
import base64
import json
import pathlib
import socket
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=pathlib.Path)
parser.add_argument("action", choices=["list", "select", "observe", "click", "type", "key", "scroll", "stop"])
parser.add_argument("--window", type=int)
parser.add_argument("--receipt")
parser.add_argument("--x", type=float)
parser.add_argument("--y", type=float)
parser.add_argument("--text")
parser.add_argument("--key")
parser.add_argument("--delta-y", type=int)
parser.add_argument("--deadline-ms", type=int, default=60000)
parser.add_argument("--disconnect-after", type=float)
parser.add_argument("--session", default="verification-run-1")
parser.add_argument("--pointer-probe", action="store_true", help="Fixture-only receive-and-suppress pointer diagnostic; no control action")
args = parser.parse_args()
if args.pointer_probe and args.action not in ("click", "scroll"):
    parser.error("--pointer-probe is only valid with click/scroll")
credentials = json.loads((args.directory / "bridge.json").read_text())
input_data = {"action": args.action}
if args.pointer_probe:
    input_data["pointer_probe"] = True
if args.action == "select":
    input_data["app_id"] = "com.youfun.computerfixture"
for key, value in {"window_id": args.window, "observation_id": args.receipt,
                   "x": args.x, "y": args.y, "text": args.text, "key": args.key, "delta_y": args.delta_y}.items():
    if value is not None:
        input_data[key] = value
request = {"id": str(uuid.uuid4()), "session": args.session,
           "token": credentials["HANDBEAN_COMPUTER_TOKEN"],
           "deadline_ms": int(time.time() * 1000) + args.deadline_ms,
           "input": input_data}
with socket.create_connection(("127.0.0.1", int(credentials["HANDBEAN_COMPUTER_PORT"])), timeout=65) as client:
    client.sendall(json.dumps(request).encode() + b"\n")
    if args.disconnect_after is not None:
        time.sleep(args.disconnect_after)
        print("Disconnected pending request; native consent must close and old input must not execute.")
    else:
        line = client.makefile("rb").readline(7_100_001)
        if not line:
            raise SystemExit("Native request closed/expired; outcome unknown. Observe, do not retry input.")
        reply = json.loads(line)
        assert reply["id"] == request["id"], "request correlation failed"
        result = reply["result"]
        image = result.pop("image", None)
        if image:
            path = args.directory / ("observation-" + request["id"] + ".png")
            path.write_bytes(base64.b64decode(image, validate=True))
            path.chmod(0o600)
            result["saved_image"] = str(path)
        (args.directory / "last-result.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result, indent=2))
