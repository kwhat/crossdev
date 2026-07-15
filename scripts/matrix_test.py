#!/usr/bin/env python3

import concurrent.futures
import hashlib
import os
import re
import shlex
import subprocess
import sys
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = f"{ROOT}/logs"
WORKFLOW = f"{ROOT}/.github/workflows/crossdev.yml"
CONTAINER_TEST = f"{ROOT}/scripts/container_test.sh"
JOBS = os.cpu_count() or 1
CONTAINER_ENV = [
    f"MAKEOPTS=-j{JOBS} -l{JOBS}",
    f"EMERGE_DEFAULT_OPTS=--jobs={JOBS} --load-average={JOBS}",
    "FEATURES=-ipc-sandbox -network-sandbox -pid-sandbox parallel-fetch parallel-install",
]


def capture(cmd, path, env=None):
    with open(path, "wb") as f:
        return subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env).returncode


def get_matrix():
    matrix = yaml.safe_load(open(WORKFLOW))["jobs"]["crossdev"]["strategy"]["matrix"]
    plan = []
    for target in matrix["target"]:
        args = shlex.split(target.get("args") or "")
        for stage3 in matrix["stage3"]:
            is_llvm = stage3 == "llvm"
            if not target.get("llvm" if is_llvm else "gcc"):
                continue
            cmd = [CONTAINER_TEST, "--tag", stage3, "--target", target["target"]]
            if is_llvm:
                cmd.append("--llvm")
            cmd += args
            for e in CONTAINER_ENV:
                cmd += ["--container-env", e]
            plan.append((stage3, target["target"], cmd))
    return plan


def get_slug(args):
    # Slug built from --env value so all targets get distinct containers and logs
    vals = [args[i + 1] for i, a in enumerate(args) if a == "--env" and i + 1 < len(args)]
    return re.sub(r"[^A-Za-z0-9]+", "-", "-".join(vals)).strip("-").lower()


def run(entry):
    stage3, target, cmd = entry
    logdir = f"{LOGDIR}/{stage3}"
    os.makedirs(logdir, exist_ok=True)

    slug = get_slug(cmd)
    label = f"{target}-{slug}" if slug else target
    name = f"{stage3}/{label}"

    digest = hashlib.sha1(label.encode()).hexdigest()[:12]
    env = {**os.environ, "CONTAINER_NAME": f"crossdev-{stage3}-{digest}"}

    print(f"Starting {name}...", flush=True)
    rc = capture(cmd, f"{logdir}/{label}.log", env)
    tag = "[ OK ]" if rc == 0 else f"[ FAIL {rc} ]"
    print(f"Completed {name} {tag}", flush=True)
    return rc


def main():
    plan = get_matrix()

    pool = concurrent.futures.ThreadPoolExecutor(max_workers=JOBS)
    futures = [pool.submit(run, e) for e in plan]
    try:
        for f in concurrent.futures.as_completed(futures):
            f.result()
    except KeyboardInterrupt:
        pool.shutdown(wait=False, cancel_futures=True)
        # Containers are orphaned, remove them
        ids = subprocess.run(
            ["docker", "ps", "-aq", "--filter", "name=crossdev-"],
            capture_output=True,
            text=True,
        ).stdout.split()

        if ids:
            subprocess.run(["docker", "rm", "-f", *ids])
        sys.exit(130)
    pool.shutdown()


if __name__ == "__main__":
    main()
