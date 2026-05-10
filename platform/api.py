#!/usr/bin/env python3
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field


ROOT = Path(__file__).resolve().parents[1]
ENVS = ROOT / "envs"
LOGS = ROOT / "logs"
PLATFORM = ROOT / "platform"

app = FastAPI(title="devops-sandbox API", version="1.0.0")
ENV_ID_RE = re.compile(r"^env-[a-f0-9]{12}$")


class EnvCreate(BaseModel):
    name: str = Field(default="sandbox", min_length=1)
    ttl: str | int | None = None
    ttl_seconds: str | int | None = None


class OutageRequest(BaseModel):
    mode: str


def run_script(*args):
    completed = subprocess.run(
        [str(PLATFORM / args[0]), *args[1:]],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=(completed.stderr or completed.stdout or "command failed").strip(),
        )
    return completed.stdout


def require_env_id(env_id: str) -> None:
    if not ENV_ID_RE.fullmatch(env_id):
        raise HTTPException(status_code=400, detail="invalid environment id")


def read_state(path):
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    remaining = max(0, int(data["created_at"]) + int(data["ttl"]) - int(time.time()))
    data["ttl_remaining"] = remaining
    return data


def tail(path, lines):
    if not path.exists():
        return ""
    with path.open("rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        block = 4096
        data = b""
        while size > 0 and data.count(b"\n") <= lines:
            read_size = min(block, size)
            size -= read_size
            fh.seek(size)
            data = fh.read(read_size) + data
    return b"\n".join(data.splitlines()[-lines:]).decode("utf-8", errors="replace")


@app.post("/envs", status_code=201)
def create_env(payload: EnvCreate) -> dict[str, Any]:
    ttl = str(payload.ttl or payload.ttl_seconds or os.environ.get("DEFAULT_TTL_SECONDS", "1800"))
    output = run_script("create_env.sh", payload.name, ttl)
    env_id = next((line.split(":", 1)[1].strip() for line in output.splitlines() if line.startswith("environment:")), None)
    return read_state(ENVS / f"{env_id}.json") if env_id else {"output": output}


@app.get("/envs")
def list_envs() -> list[dict[str, Any]]:
    return [read_state(path) for path in sorted(ENVS.glob("*.json"))]


@app.delete("/envs/{env_id}")
def destroy_env(env_id: str) -> dict[str, str]:
    require_env_id(env_id)
    output = run_script("destroy_env.sh", env_id)
    return {"message": output.strip()}


@app.get("/envs/{env_id}/logs", response_class=PlainTextResponse)
def env_logs(env_id: str) -> str:
    require_env_id(env_id)
    return tail(LOGS / env_id / "app.log", 100)


@app.get("/envs/{env_id}/health", response_class=PlainTextResponse)
def env_health(env_id: str) -> str:
    require_env_id(env_id)
    return tail(LOGS / env_id / "health.log", 10)


@app.post("/envs/{env_id}/outage")
def outage(env_id: str, payload: OutageRequest) -> dict[str, str]:
    require_env_id(env_id)
    output = run_script("simulate_outage.sh", "--env", env_id, "--mode", payload.mode)
    return {"message": output.strip()}


if __name__ == "__main__":
    port = int(os.environ.get("SANDBOX_API_PORT", "5000"))
    uvicorn.run("api:app", host="0.0.0.0", port=port, app_dir=str(PLATFORM))
