#!/usr/bin/env python3
import json
import sys

open(sys.argv[0] + ".argv", "w").write("\n".join(sys.argv[1:]))
log = open(sys.argv[0] + ".stdin", "a")
prompt_id = None

for line in sys.stdin:
    log.write(line)
    log.flush()
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue

    method = msg.get("method")
    result = msg.get("result") or {}
    outcome = result.get("outcome") or {}

    if method == "initialize":
        reply = {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1}}
    elif method == "session/new":
        reply = {"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "grok-sess"}}
    elif method == "session/prompt":
        prompt_id = msg["id"]
        reply = {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "session/request_permission",
            "params": {
                "title": "Run",
                "options": [{"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"}],
            },
        }
    elif outcome.get("optionId") == "allow_once":
        print(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": "ok"},
                        }
                    },
                }
            ),
            flush=True,
        )
        reply = {"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "end_turn"}}
    else:
        continue

    print(json.dumps(reply), flush=True)
