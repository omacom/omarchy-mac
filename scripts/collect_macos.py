#!/usr/bin/env python3
"""Native macOS facts for the community collectors. No MLX install required."""

import json
import platform

try:
    import bench_matrix
except ModuleNotFoundError:  # vendored without the mlx-omarchy bench harness
    bench_matrix = None
from collect_common import run_tool, run_python_probe


def not_applicable():
    return {"available": False, "error": "not applicable to native macOS MLX"}


# Runs via run_python_probe on the Mac. Read-only: ioreg queries and one
# best-effort powermetrics sample. Structured so every string that
# reaches the report has passed the Redactor back in the parent.
ANE_PROBE_CODE = r"""
import json, plistlib, re, subprocess

out = {"available": False, "instances": [], "ane_nodes": [],
       "dart_nodes": [],
       "coreml": {"available": False, "compute_units": None, "error": None},
       "powermetrics": {"available": False, "power_mw": None,
                        "error": None},
       "truncated": []}


def _text(value):
    if isinstance(value, bytes):
        value = value.split(b"\x00")[0].decode("utf-8", "replace")
    return str(value)[:128] if value is not None else None


def _compatible(node):
    raw = node.get("compatible")
    if isinstance(raw, bytes):
        texts = [t.decode("utf-8", "replace") for t in raw.split(b"\x00")
                 if t]
        return texts[:8]
    return None


def _reg(node):
    raw = node.get("reg") or node.get("IODeviceMemory")
    if isinstance(raw, bytes):
        if len(raw) > 64:
            out["truncated"].append("reg_bytes:%s" % _text(
                node.get("name")))
            raw = raw[:64]
        return raw.hex()
    return None


def _keep(node):
    # Keys the payload schema whitelists; AAPL,phandle is carried as
    # `phandle` below.
    keys = ("name", "compatible", "reg", "IODeviceMemory",
            "IOInterruptControllers", "IOInterruptSpecifiers", "IOClass")
    return {k: node[k] for k in keys
            if node.get(k) is not None and k != "IODeviceMemory"}


try:
    raw = subprocess.run(["ioreg", "-a", "-rc", "H11ANEIn", "-l"],
                         capture_output=True, timeout=30).stdout
    for node in plistlib.loads(raw):
        dp = node.get("DeviceProperties") or {}
        out["instances"].append({
            "name": _text(node.get("IONameMatched")),
            "matched": _text(node.get("IONameMatched")),
            "firmware_loaded": node.get("FirmwareLoaded") is True,
            "cores": dp.get("ANEDevicePropertyNumANECores"),
            "version": dp.get("ANEDevicePropertyANEVersion"),
            "hw_board_type": dp.get("ANEDevicePropertyANEHWBoardType"),
            "arch": _text(dp.get(
                "ANEDevicePropertyTypeANEArchitectureTypeStr")),
        })
    out["available"] = bool(out["instances"])
    out["instances"] = out["instances"][:8]
except Exception as exc:
    out["truncated"].append("ioreg_instances:%s" % type(exc).__name__)

try:
    raw = subprocess.run(["ioreg", "-a", "-p", "IOService", "-l"],
                         capture_output=True, timeout=120).stdout
    tree = plistlib.loads(raw)
    ane_re = re.compile(r"^(ane\d*|dart-ane\d*|mapper-ane\d*)$")
    stack = list(tree) if isinstance(tree, list) else [tree]
    while stack:
        node = stack.pop()
        if not isinstance(node, dict):
            continue
        name = _text(node.get("name"))
        if name and ane_re.match(name):
            entry = _keep(node)
            entry["name"] = name
            entry["compatible"] = _compatible(node)
            entry["reg"] = _reg(node)
            for key in ("IOInterruptControllers",
                        "IOInterruptSpecifiers", "IOClass"):
                if key in entry:
                    entry[key] = _text(entry[key])
            ph = node.get("AAPL,phandle")
            if isinstance(ph, bytes) and len(ph) == 4:
                ph = int.from_bytes(ph, "big")
            entry["phandle"] = ph
            (out["dart_nodes"] if name.startswith(
                ("dart-", "mapper-")) else out["ane_nodes"]).append(entry)
        children = node.get("IORegistryEntryChildren")
        if isinstance(children, list):
            stack.extend(children)
    out["ane_nodes"] = out["ane_nodes"][:8]
    out["dart_nodes"] = out["dart_nodes"][:8]
    if len(out["ane_nodes"]) == 8 or len(out["dart_nodes"]) == 8:
        out["truncated"].append("devicetree:node_cap")
except Exception as exc:
    out["truncated"].append("ioreg_tree:%s" % type(exc).__name__)

# CoreML compute-unit availability when pyobjc is present; otherwise a
# recorded miss, never a crash.
try:
    import CoreML  # type: ignore
    from CoreML import MLComputeUnits  # type: ignore
    out["coreml"] = {"available": True,
                     "compute_units": str(MLComputeUnits.all)[:64],
                     "error": None}
except Exception as exc:
    out["coreml"] = {"available": False, "compute_units": None,
                     "error": type(exc).__name__[:64]}

# ANE power/utilization needs root; record the miss cleanly without it.
try:
    proc = subprocess.run(
        ["powermetrics", "--samplers", "ane_power", "-n", "1", "-i", "100"],
        capture_output=True, timeout=30, text=True)
    if proc.returncode != 0:
        out["powermetrics"]["error"] = proc.stderr.strip()[:128] \
            or "exit %d" % proc.returncode
    else:
        watts = [float(m) for m in
                 re.findall(r"ANE Power: ([0-9.]+) mW", proc.stdout)]
        out["powermetrics"] = {"available": True,
                               "power_mw": watts[0] if watts else None,
                               "error": None}
except Exception as exc:
    out["powermetrics"]["error"] = type(exc).__name__[:64]

def _plain(value):
    if isinstance(value, bytes):
        return _text(value)
    if isinstance(value, list):
        return [_plain(v) for v in value]
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    return value


print(json.dumps(_plain(out))[:120000])
"""


def probe_ane_port(redactor):
    """ANE porting facts from the working macOS installation.

    The macOS equivalents of the Linux devicetree capture: the driver
    instances (core count, hardware generation, firmware state), the
    DT-shaped ANE provider and ANE DART/mapper nodes with their MMIO
    ranges and interrupt specifiers, CoreML compute-unit availability,
    and a root-gated powermetrics sample. Everything is read-only; only
    powermetrics wants root, and its absence is recorded, not fatal.
    """
    rec = run_python_probe(ANE_PROBE_CODE, redactor,
                           label="ane-port macos", timeout=180)
    if rec["exit_code"] != 0 or not rec["stdout"].strip():
        return {"available": False, "macos": None,
                "error": rec["error"] or rec["stderr"][:256] or
                "ane probe exit %s" % rec["exit_code"]}
    try:
        detail = json.loads(rec["stdout"])
    except ValueError:
        return {"available": False, "macos": None, "error": "bad-probe-json"}
    detail = {key: detail[key] for key in
              ("available", "instances", "ane_nodes", "dart_nodes",
               "coreml", "powermetrics", "truncated")
              if key in detail}
    return {"available": bool(detail.get("available")),
            "macos": redactor.apply_value(detail)}



def _text(record):
    return record["stdout"].strip() if record["exit_code"] == 0 else None


def _int(value):
    return int(value) if value and str(value).isdigit() else None


def probe_host(redactor):
    if bench_matrix is None:
        return {"available": False,
                "error": "bench_matrix not vendored with this collector"}
    facts = bench_matrix.host_facts()
    model = run_tool(["sysctl", "-n", "hw.model"], redactor, timeout=10)
    active = run_tool(["sysctl", "-n", "hw.activecpu"], redactor, timeout=10)
    memory = facts.get("memsize_bytes")
    return {
        "available": True,
        "system": "Darwin",
        "arch": facts.get("machine"),
        "kernel_release": platform.release(),
        "os": facts.get("os"),
        "model": _text(model),
        "chip": facts.get("chip"),
        "cpu_online": _int(_text(active)),
        "cpu": {"present": _int(facts.get("cores")), "hotplug_control": None},
        "memory_total_mib": memory // (1024 * 1024) if memory else None,
        "gpu": facts.get("gpu"),
    }


def measurement_context():
    if bench_matrix is None:
        return {"power": None, "model_processes": None}
    power = bench_matrix.power_state()
    processes = bench_matrix.clean_check()
    return {
        "power": {key: power.get(key) for key in ("source", "percent", "charging")}
        if power else None,
        "model_processes": {
            "status": processes["status"],
            "scanned": processes["scanned"],
            "matched_count": len(processes["matched"]),
        },
        "limits": "Process scan covers known model tools only. Other GPU activity "
                  "and temperature are not measured. Timings are observations, "
                  "not a controlled performance comparison.",
    }
