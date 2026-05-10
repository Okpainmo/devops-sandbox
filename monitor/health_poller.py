#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENVS = ROOT / "envs"
LOGS = ROOT / "logs"
INTERVAL = int(os.environ.get("HEALTH_INTERVAL_SECONDS", "30"))


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def atomic_write_json(path, data):
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def poll(env):
    start = time.perf_counter()
    try:
      with urllib.request.urlopen(env["url"].rstrip("/") + "/health", timeout=5) as res:
          status = res.status
          res.read()
    except urllib.error.HTTPError as exc:
      status = exc.code
    except Exception:
      status = 0
    latency_ms = round((time.perf_counter() - start) * 1000, 2)
    return status, latency_ms


def main():
    LOGS.mkdir(exist_ok=True)
    print(f"{now_iso()} health poller started", flush=True)
    failures = {}
    while True:
        for state_file in sorted(ENVS.glob("*.json")):
            try:
                env = json.loads(state_file.read_text(encoding="utf-8"))
            except Exception as exc:
                print(f"{now_iso()} invalid state file {state_file.name}: {exc}", file=sys.stderr, flush=True)
                continue

            env_id = env.get("id", state_file.stem)
            log_dir = LOGS / env_id
            log_dir.mkdir(parents=True, exist_ok=True)
            status, latency_ms = poll(env)
            ok = 200 <= status < 400
            failures[env_id] = 0 if ok else failures.get(env_id, 0) + 1

            with (log_dir / "health.log").open("a", encoding="utf-8") as fh:
                fh.write(f"{now_iso()} status={status} latency_ms={latency_ms}\n")

            if failures[env_id] >= 3 and env.get("status") != "degraded":
                env["status"] = "degraded"
                atomic_write_json(state_file, env)
                print(f"{now_iso()} WARNING env={env_id} degraded after 3 failures", flush=True)
            elif ok and env.get("status") == "degraded":
                env["status"] = "running"
                atomic_write_json(state_file, env)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
