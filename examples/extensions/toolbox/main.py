#!/usr/bin/env python3
"""A small TapDone v1 adapter. Extend operations here without changing the app."""
import json
import platform
import sys


def main():
    try:
        request = json.load(sys.stdin)
        if request.get("protocolVersion") != 1:
            raise ValueError("Unsupported protocolVersion")
        payload = request.get("input", {})
        if not isinstance(payload, dict):
            raise ValueError("input must be an object for this extension")
        operation = payload.get("operation", "system-info")
        print("TapDone toolbox: " + operation, file=sys.stderr, flush=True)
        if operation == "system-info":
            data = {"system": platform.system(), "architecture": platform.machine()}
            message = "已读取系统信息"
        elif operation == "uppercase":
            data = {"text": str(payload.get("text", "")).upper()}
            message = "已转换文本"
        else:
            raise ValueError("Unknown operation: " + str(operation))
        result = {"protocolVersion": 1, "ok": True, "message": message, "data": data}
        code = 0
    except Exception as error:
        print(str(error), file=sys.stderr, flush=True)
        result = {"protocolVersion": 1, "ok": False, "message": str(error)}
        code = 1
    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
