#!/usr/bin/env python3
"""Run a conformance-suite test plan over the suite's REST API and report each module's result.

    run-plan.py <suite-base-url> <plan-name> <config.json> [--variant k=v ...] [--only glob ...]
                [--on-log-marker TEXT --hook CMD] [--save-logs DIR]

For a suite you run yourself in dev mode, which needs no login. The hosted suite at
certification.openid.net needs a signed-in browser session instead, and the run that counts for a
certification is made there, by a person; this is for getting to green before that.

Exit status is 0 only if every module that ran finished PASSED, WARNING, REVIEW or SKIPPED - the
results a certification run tolerates. It prints each FAILURE's condition and message, because "FAILED"
alone sends you to a web UI to find out what you could have been told.

--expected FILE names failures that are known and explained, as a JSON list of
{"module": ..., "condition": ..., "level": "FAILURE" | "WARNING", "why": ...}. A module that FAILED is
tolerated only when every FAILURE and WARNING in its log is one of those - its module and the condition
that raised it. An expectation that no module raised is reported, and is fatal with
--strict-expectations: a fix nobody wrote down is as much a surprise as a new failure.

Some modules wait for the transmitter's operator to do something - the CAEP Interop module logs
"Please trigger these events on the transmitter now" and gives sixty seconds. --on-log-marker TEXT
--hook CMD watches the running module's log for TEXT and runs CMD (a shell command) once when it
appears, with EXPECTED_CAEP_EVENT_TYPES in its environment when the log entry names them.

--save-logs DIR keeps each module's full log, as the suite's /api/log/<id> returns it, in DIR/<plan id>/<module>.json,
and DIR/<plan id>/plan.json holds the plan, its variant, each module's result and log id, and when it ran. The
directories are made mode 700: a log holds what the suite sent and PingFederate answered - tokens, client assertions,
the suite's configuration - so a CI job scrubs it (tools/ci/licensed-scrub.py --tokens) before it keeps it.
tools/suite-log-ids.py reads what was saved. Without the option nothing is written, as before.

--pause SECONDS waits between modules. PingFederate's attestation challenge endpoint allows one caller 60 challenges a
minute (challengeRateLimitPerWindow), and the challenges it puts on use_attestation_challenge refusals count too; the
client_attestation plan, run back to back from the suite's one address, went past it (X-E09).
"""
import argparse
import datetime
import fnmatch
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# The suite you run yourself serves a self-signed certificate on localhost.
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TOLERATED = {"PASSED", "WARNING", "REVIEW", "SKIPPED"}


def call(method, url, params=None, body=None):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method=method, data=body.encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=120) as resp:
            text = resp.read().decode()
            return resp.status, json.loads(text) if text else None
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:600]}


def wait_for(base, module_id, states, timeout, marker=None, hook=None):
    deadline = time.time() + timeout
    fired = False
    while time.time() < deadline:
        _, info = call("GET", f"{base}/api/info/{module_id}")
        if info and info.get("status") in states | {"INTERRUPTED"}:
            return info
        if marker and hook and not fired:
            fired = fire_hook_on_marker(base, module_id, marker, hook)
        time.sleep(1.5)
    return info or {}


def fire_hook_on_marker(base, module_id, marker, hook):
    """Run the hook once the module's log carries the marker. True once it has run (or was tried)."""
    _, log = call("GET", f"{base}/api/log/{module_id}")
    for entry in log or []:
        if marker in (entry.get("msg") or ""):
            env = dict(os.environ)
            expected = entry.get("expected_caep_event_types")
            if expected:
                env["EXPECTED_CAEP_EVENT_TYPES"] = ",".join(expected) if isinstance(expected, list) else str(expected)
            print(f"            hook: {hook}")
            rc = subprocess.call(hook, shell=True, env=env)
            print(f"            hook exit {rc}")
            return True
    return False


def fetch_log(base, module_id):
    """The module's log entries, or [] when the suite has none for it."""
    _, log = call("GET", f"{base}/api/log/{module_id}")
    return log if isinstance(log, list) else []


def failures(base, module_id, log=None):
    if log is None:
        log = fetch_log(base, module_id)
    out = []
    for entry in log:
        if entry.get("result") in ("FAILURE", "WARNING"):
            out.append((entry["result"], entry.get("src", "?"), (entry.get("msg") or "").replace("\n", " ")[:260]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("plan")
    ap.add_argument("config")
    ap.add_argument("--variant", nargs="*", default=[], metavar="k=v")
    ap.add_argument("--only", nargs="*", default=[], metavar="GLOB", help="run only modules whose name matches")
    ap.add_argument("--timeout", type=int, default=420, help="seconds to allow one module")
    ap.add_argument("--on-log-marker", default=None, metavar="TEXT", help="log text that means the module is waiting for the operator")
    ap.add_argument("--hook", default=None, metavar="CMD", help="shell command to run once when the marker appears")
    ap.add_argument("--expected", default=None, metavar="FILE", help="known, explained failures (JSON list)")
    ap.add_argument("--strict-expectations", action="store_true", help="fail when an expected failure did not happen")
    ap.add_argument("--save-logs", default=None, metavar="DIR", help="keep every module's full log under DIR/<plan id>/")
    ap.add_argument("--pause", type=float, default=0, metavar="SECONDS",
                    help="wait this long before each module after the first, for a server that rate-limits the suite")
    args = ap.parse_args()
    expected = json.load(open(args.expected)) if args.expected else []
    fired = set()
    base = args.base.rstrip("/")
    variant = dict(v.split("=", 1) for v in args.variant)

    status, plan = call("POST", f"{base}/api/plan", {"planName": args.plan, "variant": json.dumps(variant)},
                        open(args.config).read())
    if status != 201:
        sys.exit(f"could not create the plan: HTTP {status} {plan}")
    print(f"plan {plan['id']}  {base}/plan-detail.html?plan={plan['id']}")
    saver = LogSaver(args.save_logs, plan["id"], args.plan, variant) if args.save_logs else None

    results = {}
    for module in plan["modules"]:
        name = module["testModule"]
        if args.only and not any(fnmatch.fnmatch(name, g) for g in args.only):
            continue
        if results and args.pause > 0:
            time.sleep(args.pause)
        params = {"test": name, "plan": plan["id"]}
        if module.get("variant"):
            params["variant"] = json.dumps(module["variant"])
        status, created = call("POST", f"{base}/api/runner", params)
        if status != 201:
            results[name] = "NOT-CREATED"
            print(f"{'NOT-CREATED':<11} {name}  HTTP {status} {created}")
            continue
        info = wait_for(base, created["id"], {"CONFIGURED", "WAITING", "FINISHED"}, 90)
        if info.get("status") == "CONFIGURED":
            call("POST", f"{base}/api/runner/{created['id']}")
        info = wait_for(base, created["id"], {"FINISHED"}, args.timeout, args.on_log_marker, args.hook)
        result = info.get("result") or f"({info.get('status', 'NO-STATUS')})"
        log = fetch_log(base, created["id"]) if saver or result not in ("PASSED", "SKIPPED") else []
        if saver:
            saver.module(name, created["id"], result, log)
        found = failures(base, created["id"], log) if result not in ("PASSED", "SKIPPED") else []
        matched = [explained(expected, name, level, src) for level, src, _ in found]
        fired.update(i for i in matched if i is not None)
        if result not in TOLERATED and found and all(i is not None for i in matched):
            result = "EXPECTED"
        results[name] = result
        print(f"{result:<11} {name}  {base}/log-detail.html?log={created['id']}")
        for (level, src, msg), i in zip(found, matched):
            note = f"  [expected: {expected[i]['why']}]" if i is not None else ""
            print(f"            {level:<8} {src}: {msg}{note}")

    counts = {}
    for r in results.values():
        counts[r] = counts.get(r, 0) + 1
    print("\n" + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())) + f"  (of {len(results)})")
    unfired = [e for i, e in enumerate(expected) if i not in fired and (not args.only or e["module"] in results)]
    for e in unfired:
        print(f"expected, did not happen: {e['module']} {e['condition']} ({e['why']})")
    ok = all(r in TOLERATED | {"EXPECTED"} for r in results.values()) and not (args.strict_expectations and unfired)
    if saver:
        saver.finish(results)
    sys.exit(0 if ok else 1)


class LogSaver:
    """--save-logs: each module's full log beside a plan.json, in a directory only this user can read."""

    def __init__(self, root, plan_id, plan_name, variant):
        self.dir = os.path.join(root, safe(plan_id))
        os.makedirs(root, mode=0o700, exist_ok=True)
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.plan = {"plan_id": plan_id, "plan": plan_name, "variant": variant,
                     "started": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"), "modules": []}

    def module(self, name, log_id, result, log):
        """Writes the module's log as <module>.json (-2, -3 ... when a module runs again under another variant)."""
        stem, n = safe(name), 1
        while os.path.exists(os.path.join(self.dir, (stem if n == 1 else f"{stem}-{n}") + ".json")):
            n += 1
        file = (stem if n == 1 else f"{stem}-{n}") + ".json"
        write_private(os.path.join(self.dir, file), log)
        self.plan["modules"].append({"module": name, "log_id": log_id, "result": result, "file": file, "entries": len(log)})

    def finish(self, results):
        self.plan["finished"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        self.plan["results"] = results
        write_private(os.path.join(self.dir, "plan.json"), self.plan)
        print(f"logs saved: {self.dir} ({len(self.plan['modules'])} module(s))")


def safe(name):
    """A file name from a plan id or module name: nothing that climbs out of the directory."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", str(name)).lstrip(".") or "_"


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=1, ensure_ascii=False)
        f.write("\n")


def explained(expected, module, level, condition):
    """The index of the expectation that explains this log entry, or None."""
    for i, e in enumerate(expected):
        if e["module"] == module and e["condition"] == condition and e.get("level", "FAILURE") == level:
            return i
    return None


if __name__ == "__main__":
    main()
