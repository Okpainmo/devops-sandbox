#!/usr/bin/env python3
import json
import time
from pathlib import Path


for path in sorted(Path("envs").glob("*.json")):
    data = json.loads(path.read_text(encoding="utf-8"))
    remaining = max(0, int(data["created_at"]) + int(data["ttl"]) - int(time.time()))
    health_path = Path("logs") / data["id"] / "health.log"
    if health_path.exists():
        lines = health_path.read_text(encoding="utf-8").splitlines()
        last = lines[-1] if lines else "no health checks yet"
    else:
        last = "no health checks yet"
    print(f'{data["id"]}\t{data["status"]}\tttl_remaining={remaining}s\t{last}\t{data["url"]}')
