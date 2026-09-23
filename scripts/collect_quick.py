#!/usr/bin/env python3
"""Collect a fast, privacy-safe capability report for mlx-omarchy.

The report answers the questions a maintainer asks first: which Apple
Silicon machine, which kernel, which Mesa/Honeykrisp Vulkan stack, is the
ANE visible, and which mlx-omarchy wheel is installed. It also records
the CPU topology (present cores versus online), the boot-chain firmware
identity from the devicetree /chosen node, the redacted kernel command
line, whether the booted devicetree carries an ANE node, and the full
driver-port devicetree capture (ane node, DARTs, PMGR domains, AIC)
for porting omarchy-ane to a new SoC. It finishes
in seconds, downloads nothing, and never touches the network.

On macOS, it records native Mac, OS, and Metal facts instead of Linux
driver and devicetree diagnostics. Native MLX is optional.

Personal data never reaches the output: every captured command output and
every free-text field passes through the shared Redactor, and the script
never reads serial numbers, machine IDs, or network configuration at all.

Usage:
  python3 scripts/collect_quick.py            # JSON on stdout
  python3 scripts/collect_quick.py --out f.json

Section shape (schema_version 1): every section carries "available"; a
missing tool or an import failure is recorded data, not an error. The
script exits 0 when the report was produced, 1 on an internal failure.
"""

import argparse
import json
import os
import platform
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import collect_macos
from collect_common import (SCHEMA_VERSION, Redactor, build_payload,
                            dump_json, json_bytes, run_tool)

DT_BASE = "/sys/firmware/devicetree/base"


def probe_host(redactor):
    if platform.system() == "Darwin":
        return collect_macos.probe_host(redactor)
    out = {"available": True}
    info = os.uname()
    out["arch"] = info.machine
    out["kernel_release"] = info.release
    try:
        out["cpu_online"] = len(os.sched_getaffinity(0))
    except AttributeError:
        out["cpu_online"] = os.cpu_count()
    try:
        out["page_size_bytes"] = os.sysconf("SC_PAGESIZE")
    except (ValueError, OSError):
        out["page_size_bytes"] = None
    mem = _mem_total()
    out["memory_total_mib"] = mem
    out["devicetree"] = _devicetree(redactor)
    out["cpu"] = _cpu_topology()
    out["boot"] = _boot_chain(redactor)
    out["cmdline"] = _kernel_cmdline(redactor)
    out["core_shortfall"] = _core_shortfall(out["cpu"],
                                            out["cmdline"] or "")
    return out


def _mem_total():
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return None


def _devicetree(redactor):
    """Machine model and chip compatible strings; never the serial."""
    out = {"model": None, "compatible": None}
    model = _read_dt_file("model")
    if model:
        out["model"] = redactor.apply(model.strip("\x00\n"))
    compat = _read_dt_file("compatible")
    if compat:
        parts = [p for p in compat.split("\x00") if p]
        out["compatible"] = parts
    return out


def _read_dt_file(name, base=DT_BASE):
    try:
        with open(os.path.join(base, name), "rb") as fh:
            return fh.read().decode("utf-8", errors="replace")
    except OSError:
        return None


CPU_SYSFS = "/sys/devices/system/cpu"


def _read_cpu_list(path):
    """(ids, raw) from a sysfs cpu list like "0-3,8"; (None, None) absent."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read().strip()
    except OSError:
        return None, None
    ids = []
    for part in raw.split(","):
        lo, sep, hi = part.partition("-")
        try:
            first = int(lo)
            last = int(hi) if sep else first
        except ValueError:
            return [], raw
        if last < first or last - first > 65535:
            return [], raw
        ids.extend(range(first, last + 1))
    return ids, raw


def _cpu_topology(base=CPU_SYSFS):
    """Core counts from sysfs: the machine's real size, not the taskset.

    host.cpu_online is scheduler affinity, so a contributor pinned to one
    core of eight looked identical to a one-core machine. `present` says
    how many cores the machine has. `hotplug_control` records whether
    cpuN/online switches exist; their absence is what spin-table bringup
    looks like on Apple Silicon.
    """
    out = {"present": None, "possible": None, "online": None,
           "offline": None, "present_list": None, "possible_list": None,
           "online_list": None, "offline_list": None,
           "hotplug_control": None}
    for key in ("present", "possible", "online", "offline"):
        ids, raw = _read_cpu_list(os.path.join(base, key))
        if raw is not None:
            out[f"{key}_list"] = raw or None
            out[key] = len(ids)
    try:
        entries = os.listdir(base)
    except OSError:
        return out
    out["hotplug_control"] = any(
        re.fullmatch(r"cpu([1-9]\d*)", name)
        and os.path.exists(os.path.join(base, name, "online"))
        for name in entries)
    return out


CHOSEN_PROPERTIES = (
    # (property under chosen, report key): boot firmware identity, never
    # personal. A bootloader devicetree override (GRUB's `devicetree`
    # command) REPLACES the m1n1-patched tree with a frozen snapshot, so
    # these strings describe whatever tree actually booted -- the
    # 2026-09-03 one-core incident came from exactly that override.
    ("asahi,m1n1-stage1-version", "m1n1_stage1"),
    ("asahi,m1n1-stage2-version", "m1n1_stage2"),
    ("asahi,iboot1-version", "iboot1"),
    ("asahi,iboot2-version", "iboot2"),
    ("asahi,system-fw-version", "system_fw"),
    ("asahi,os-fw-version", "os_fw"),
)


def _boot_chain(redactor, base=DT_BASE):
    """Boot firmware identity from the live /chosen node."""
    out = {}
    for prop, key in CHOSEN_PROPERTIES:
        raw = _read_dt_file(os.path.join("chosen", prop), base)
        out[key] = redactor.apply(raw.strip("\x00\n")) if raw else None
    return out


def _kernel_cmdline(redactor, path="/proc/cmdline"):
    """The live kernel command line, redacted.

    Carries root=UUID=... (the UUID rule replaces it) and reveals
    maxcpus/nosmp clamps or a custom-devicetree boot.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return None
    return redactor.apply(raw.strip()) or None


def _core_shortfall(cpu, cmdline):
    """Plain fact: fewer cores running than present, unexplained.

    Recorded only when the command line carries no maxcpus=/nosmp clamp;
    a clamp is a deliberate choice, not a failure. Numbers, not alarms.
    """
    present = cpu.get("present")
    online = cpu.get("online")
    if not isinstance(present, int) or not isinstance(online, int):
        return None
    if present <= online:
        return None
    if cmdline and re.search(r"\bmaxcpus=\d+\b|\bnosmp\b", cmdline):
        return None
    return {"present": present, "online": online}


def _ane_devicetree(base=DT_BASE):
    """ANE node visibility in the booted devicetree, unlike /dev/ane.

    Packaged t8103 dtbs ship no ane node; a node appears only when the
    bootloader overrides the tree. This answers whether the running
    kernel was even offered an ANE by its boot chain.
    """
    out = {"node": False, "compatible": None}
    matches = []
    for dirpath, _dirs, _files in os.walk(base):
        named = bool(re.search(r"(?:^|/)ane(?:@[0-9a-f]+)?$", dirpath))
        tokens = [t for t in (_read_dt_file("compatible", dirpath) or "")
                  .split("\x00") if t]
        hit = [t for t in tokens if t == "apple,ane" or t.endswith("-ane")]
        if named or hit:
            matches.extend(hit or tokens or [os.path.basename(dirpath)])
    if matches:
        out["node"] = True
        out["compatible"] = sorted(set(matches))[:8]
    return out

def _read_dt_raw(name, base=DT_BASE):
    """Raw property bytes; None when absent."""
    try:
        with open(os.path.join(base, name), "rb") as fh:
            return fh.read()
    except OSError:
        return None


def _dt_strings(raw):
    """Null-terminated string list from a devicetree property blob."""
    parts = [p for p in raw.split(b"\x00") if p]
    try:
        texts = [p.decode("utf-8") for p in parts]
    except UnicodeDecodeError:
        return None
    if any(not t.isprintable() for t in texts):
        return None
    return texts


def _dt_u32s(raw):
    """Big-endian u32 cell list from a devicetree property blob."""
    if len(raw) % 4 or not raw:
        return None
    return [int.from_bytes(raw[i:i + 4], "big")
            for i in range(0, len(raw), 4)]


def _dt_reg(raw, base):
    """reg as ["0xADDR/0xSIZE", ...] using the node's own cell counts."""
    cells = _dt_u32s(raw)
    if cells is None:
        return None

    def count(name, default):
        raw_n = _read_dt_raw(name, base)
        vals = _dt_u32s(raw_n) if raw_n else None
        return vals[0] if vals else default

    ac = count("#address-cells", 2)
    sc = count("#size-cells", 1)
    width = ac + sc
    out = []
    for i in range(0, len(cells) - width + 1, width):
        addr = 0
        for c in cells[i:i + ac]:
            addr = (addr << 32) | c
        size = 0
        for c in cells[i + ac:i + width]:
            size = (size << 32) | c
        out.append(f"0x{addr:x}/0x{size:x}")
    return out


def _dt_props(node_dir, redactor, cap=16):
    """Every property of one devicetree node, decoded and bounded.

    Strings stay strings, reg gets address/size decoding, everything
    numeric becomes a u32 cell list.
    """
    out = {}
    for name in sorted(os.listdir(node_dir)):
        path = os.path.join(node_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                raw = fh.read(4096)
        except OSError:
            continue
        if name == "reg":
            value = _dt_reg(raw, node_dir)
        else:
            value = _dt_strings(raw)
            if value is not None and len(value) == 1:
                value = value[0]
            elif value is None:
                value = _dt_u32s(raw)
            if value is None:
                value = raw[:64].hex()
        if isinstance(value, list):
            value = value[:cap]
        elif isinstance(value, str):
            value = redactor.apply(value[:512])
        out[name] = value
    return out


def _ane_port_devicetree(redactor, base=DT_BASE):
    """Everything a contributor needs to port omarchy-ane to this SoC.

    Captures the ane node(s) in full (MMIO reg, reg-names, IRQs, iommus,
    power-domains, status, compatible), every DART node, the PMGR
    power-domain children with their labels, and the AIC compatible.
    A tree with NO ane node still dumps DART/PMGR/AIC: that is exactly
    what authoring the overlay requires.
    """
    ane_nodes = {}
    darts = {}
    phandles = {}
    pmgr_domains = []
    aic = None
    for dirpath, dirs, _files in os.walk(base):
        dirs.sort()
        compat = _dt_strings(_read_dt_raw("compatible", dirpath) or b"") \
            or []
        rel = os.path.relpath(dirpath, base)
        ph = _dt_u32s(_read_dt_raw("phandle", dirpath) or b"")
        if ph:
            phandles[ph[0]] = rel
        named = bool(re.search(r"(?:^|/)ane(?:@[0-9a-f]+)?$", dirpath))
        hit = [t for t in compat if t == "apple,ane" or t.endswith("-ane")]
        if named or hit:
            ane_nodes[rel] = _dt_props(dirpath, redactor)
        # Real trees name DART nodes `iommu@<addr>` and tag them
        # `apple,<soc>-dart` (t600x drops the legacy `apple,dart`
        # fallback entirely), so match on the compatible suffix, not the
        # node name alone.
        if any(t == "apple,dart" or t.endswith("-dart") for t in compat) \
                or re.search(r"(?:^|/)dart[0-9a-f@-]", rel):
            darts[rel] = _dt_props(dirpath, redactor)
        if any(t == "apple,pmgr" for t in compat):
            for child in sorted(os.listdir(dirpath)):
                cpath = os.path.join(dirpath, child)
                if not os.path.isdir(cpath):
                    continue
                ccompat = _dt_strings(
                    _read_dt_raw("compatible", cpath) or b"") or []
                label = _dt_strings(_read_dt_raw("label", cpath) or b"")
                pmgr_domains.append({
                    "path": os.path.relpath(cpath, base),
                    "label": (label or [None])[0],
                    "compatible": ccompat[:8],
                })
        # t8103 uses "apple,aic"; t600x/t602x use "apple,<soc>-aic",
        # "apple,aic2".
        if aic is None and any(t in ("apple,aic", "apple,aic2")
                               or t.endswith("-aic") for t in compat):
            aic = {"path": rel, "compatible": compat[:8]}
    # Resolve iommu phandles to DART paths so the contributor does not
    # have to do phandle arithmetic by hand. Each entry is one phandle
    # plus #iommu-cells specifiers from the target DART.
    for props in ane_nodes.values():
        iommus = props.get("iommus")
        if not isinstance(iommus, list):
            continue
        resolved = []
        i = 0
        while i < len(iommus) and len(resolved) < 8:
            cell = iommus[i]
            i += 1
            if not isinstance(cell, int):
                continue
            target = phandles.get(cell, f"phandle:{cell}")
            resolved.append(target)
            dart = darts.get(target) or {}
            ncells = dart.get("#iommu-cells")
            if isinstance(ncells, list) and ncells and \
                    isinstance(ncells[0], int):
                i += ncells[0]
        props["iommus_resolved"] = resolved
    # Ship only the phandles the porting data actually resolves: the
    # iommus / power-domains cells of the ane nodes and DARTs. The full
    # map runs to hundreds of entries on t600x and blew the 64 KiB
    # payload budget before the DARTs it exists to explain did.
    referenced = set()
    for props in list(ane_nodes.values()) + list(darts.values()):
        for key in ("iommus", "power-domains"):
            cells = props.get(key)
            if isinstance(cells, list):
                referenced.update(c for c in cells
                                  if isinstance(c, int) and c in phandles)
    return {
        "ane_node_present": bool(ane_nodes),
        "ane_nodes": ane_nodes,
        "darts": darts,
        "pmgr_domains": pmgr_domains[:64],
        "aic": aic,
        "phandles": {str(k): phandles[k] for k in sorted(referenced)},
    }


def _ane_port_runtime(redactor):
    """Live runtime facts about the ane driver, redacted and bounded."""
    out = {"iomem": None, "module_version": None, "srcversion": None,
           "loaded": None, "dmesg": None}
    try:
        with open("/proc/iomem", "r", encoding="utf-8",
                  errors="replace") as fh:
            lines = [redactor.apply(line.rstrip("\n")[:512])
                     for line in fh
                     if re.search(r"ane|dart", line, re.I)]
        out["iomem"] = lines[:32] or None
    except OSError:
        pass
    for key, name in (("module_version", "version"),
                      ("srcversion", "srcversion")):
        try:
            with open(os.path.join("/sys/module/ane", name),
                      "r", encoding="utf-8") as fh:
                out[key] = redactor.apply(fh.read().strip()[:128]) or None
        except OSError:
            pass
    try:
        with open("/proc/modules", "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("ane "):
                    out["loaded"] = redactor.apply(line.strip()[:256])
                    break
    except OSError:
        pass
    dmesg = run_tool(["sh", "-c",
                      "dmesg 2>/dev/null | grep -iE 'ane|dart|pmgr' "
                      "| tail -n 64"],
                     redactor, label="dmesg ane/dart/pmgr", timeout=15)
    if dmesg["exit_code"] == 0 and dmesg["stdout"].strip():
        out["dmesg"] = [redactor.apply(line[:512])
                        for line in dmesg["stdout"].splitlines()[-64:]]
    return out


def probe_ane_port(redactor):
    """Driver-port capture: devicetree plus live ane driver facts."""
    if platform.system() == "Darwin":
        return collect_macos.probe_ane_port(redactor)
    out = {"available": True}
    out["devicetree"] = _ane_port_devicetree(redactor)
    out["runtime"] = _ane_port_runtime(redactor)
    return out


def _device_blocks(text):
    """Split `vulkaninfo --summary` into one dict per GPUn: block."""
    devices = []
    current = None
    for line in text.splitlines():
        if re.match(r"^GPU\d+:$", line.strip()):
            current = {}
            devices.append(current)
            continue
        if current is None or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key and " " not in key:
            current[key] = value.strip()
    return devices


def _primary_device(devices):
    """The device that actually matters for this project.

    A host with Honeykrisp also enumerates llvmpipe, and llvmpipe is
    listed last. Reporting it would make every submission useless for
    driver work, so prefer the real GPU: Honeykrisp first, then any
    non-CPU device, and only then whatever came first.
    """
    if not devices:
        return {}
    for dev in devices:
        if "HONEYKRISP" in dev.get("driverID", "").upper():
            return dev
    for dev in devices:
        if dev.get("deviceType", "") != "PHYSICAL_DEVICE_TYPE_CPU":
            return dev
    return devices[0]


def probe_mesa(redactor):
    """Vulkan stack identity from `vulkaninfo --summary`.

    `probe` states the probe's own fate so a missing binary is never
    read as an unsupported GPU: "missing" (tool not installed),
    "failed" (tool ran but errored), "ok" (parsed).
    """
    if platform.system() == "Darwin":
        return collect_macos.not_applicable()
    out = {"available": False, "probe": None, "properties": {}, "summary": None}
    rec = run_tool(["vulkaninfo", "--summary"], redactor,
                   label="vulkaninfo --summary", timeout=30)
    out["vulkaninfo"] = rec
    if not rec["available"]:
        out["probe"] = "missing"
        return out
    if rec["exit_code"] != 0:
        out["probe"] = "failed"
        return out
    devices = _device_blocks(rec["stdout"])
    primary = _primary_device(devices)
    out["devices"] = devices
    out["device_count"] = len(devices)
    out["properties"] = primary
    known = ("deviceName", "driverName", "driverVersion", "apiVersion",
             "vendorID", "deviceID", "deviceType", "conformanceVersion",
             "driverID", "driverInfo")
    out["gpu"] = {k: primary[k] for k in known if k in primary}
    out["available"] = bool(out["gpu"])
    out["probe"] = "ok" if out["available"] else "failed"
    return out


def probe_mesa_package(redactor):
    """Mesa package version as a cross-check; distro-specific and optional.

    Each query is gated on its package manager actually existing, so an
    Arch host does not carry a pointless dpkg not-found record.
    """
    if platform.system() == "Darwin":
        return collect_macos.not_applicable()
    out = {}
    if shutil.which("pacman"):
        out["pacman"] = run_tool(["pacman", "-Q", "mesa"], redactor,
                                 label="pacman -Q mesa", timeout=15)
        out["vulkan-asahi"] = run_tool(["pacman", "-Q", "vulkan-asahi"],
                                       redactor, label="pacman -Q vulkan-asahi",
                                       timeout=15)
    if shutil.which("dpkg-query"):
        out["dpkg"] = run_tool(
            ["dpkg-query", "-W", "-f=${Package} ${Version}\\n", "mesa"],
            redactor, label="dpkg-query mesa", timeout=15)
    return out

def probe_ane(redactor):
    """Apple Neural Engine visibility: device node and libane."""
    if platform.system() == "Darwin":
        return collect_macos.not_applicable()
    node = os.path.exists("/dev/ane")
    out = {"available": node, "device_node": node}
    out["devicetree"] = _ane_devicetree()
    lib = run_tool(["sh", "-c", "ldconfig -p 2>/dev/null | grep -i libane"],
                   redactor, label="ldconfig libane", timeout=15)
    out["libane"] = lib["stdout"].strip() if lib["exit_code"] == 0 else None
    out["libane_probe"] = lib
    pkg = run_tool(["pkg-config", "--modversion", "libane"], redactor,
                   label="pkg-config libane", timeout=15)
    out["libane_version"] = pkg["stdout"].strip() \
        if pkg["exit_code"] == 0 else None
    out["pkgconfig"] = pkg
    return out


MLX_PROBE_CODE = r"""
import json
out = {"distributions": {}, "import_ok": False, "import_error": None,
       "info_tool": None, "default_device": None, "mlx_version": None}
import importlib.metadata
for dist in ("mlx-omarchy", "mlx"):
    try:
        out["distributions"][dist] = importlib.metadata.version(dist)
    except Exception:
        pass
import pathlib
try:
    import mlx.core as mx
    out["import_ok"] = True
    import platform
    if platform.system() == "Darwin":
        out["metal_available"] = mx.metal.is_available()
        if out["metal_available"]:
            mx.set_default_device(mx.gpu)
    out["default_device"] = str(mx.default_device())
    out["mlx_version"] = getattr(mx, "__version__", None)
    # mlx is a namespace package (mlx.__file__ is None); anchor on the
    # extension module, which lives beside the shipped bin/ directory.
    cand = pathlib.Path(mx.__file__).resolve().parent / "bin" / "mlx-omarchy-info"
    if cand.exists():
        out["info_tool"] = str(cand)
except Exception as exc:
    out["import_error"] = f"{type(exc).__name__}: {exc}"
print(json.dumps(out))
"""


def probe_mlx(redactor):
    """Installed wheel identity plus the shipped capability tool."""
    rec = run_tool([sys.executable, "-c", MLX_PROBE_CODE], redactor,
                   label="mlx import probe", timeout=90)
    out = {"available": False, "probe": rec, "info": None,
           "capabilities": None}
    if not rec["available"] or rec["exit_code"] != 0:
        return out
    try:
        found = json.loads(rec["stdout"].strip().splitlines()[-1])
    except (ValueError, IndexError):
        return out
    out["available"] = bool(found.get("import_ok"))
    for key in ("distributions", "import_error", "default_device",
                "mlx_version", "info_tool", "metal_available"):
        out[key] = found.get(key)
    tool = found.get("info_tool")
    if tool:
        cap = run_tool([tool, "--json"], redactor,
                       label="mlx-omarchy-info --json", timeout=60)
        out["info"] = cap
        if cap["exit_code"] == 0:
            try:
                out["capabilities"] = json.loads(cap["stdout"])
            except ValueError:
                out["capabilities"] = None
    return out


def _strip_volatile(value):
    """Drop run-to-run noise so equal machine state gives equal output."""
    if isinstance(value, dict):
        return {k: _strip_volatile(v) for k, v in value.items()
                if k != "duration_ms"}
    if isinstance(value, list):
        return [_strip_volatile(v) for v in value]
    return value


DEFAULT_PROBES = {
    "host": probe_host,
    "mesa": probe_mesa,
    "mesa_package": probe_mesa_package,
    "ane": probe_ane,
    "ane_port": probe_ane_port,
    "mlx": probe_mlx,
}


def collect(probes=None):
    """Build the report dict. `probes` overrides sections for tests."""
    active = dict(DEFAULT_PROBES)
    if probes:
        active.update(probes)
    redactor = Redactor()
    report = {
        "report": "mlx-omarchy-quick",
        "schema_version": SCHEMA_VERSION,
    }
    for name in sorted(active):
        try:
            report[name] = redactor.apply_value(active[name](redactor))
        except Exception as exc:
            report[name] = {
                "available": False,
                "error": redactor.apply(f"{type(exc).__name__}: {exc}"),
            }
    return _strip_volatile(report)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", metavar="FILE",
                    help="also write the JSON report to FILE")
    ap.add_argument("--submit", metavar="URL", default=None,
                    help="publish this report to the community endpoint "
                         "after printing it")
    args = ap.parse_args()
    report = collect()
    text = dump_json(report)
    if args.out:
        with open(args.out, "wb") as fh:
            fh.write(json_bytes(report))
        print(f"[receipt] wrote {args.out} ({len(json_bytes(report))} bytes)")
    print(text, end="" if text.endswith("\n") else "\n")
    raise SystemExit(maybe_submit(args, report))


def maybe_submit(args, report):
    """Publish only after the report was shown and consent was given.

    The import is local so that a plain run of this script loads no
    network module at all.
    """
    import collect_submit

    endpoint = collect_submit.endpoint_from_args(args)
    if endpoint is None:
        return 0
    payload = build_payload("quick", report, {}, redactor=Redactor())
    digest = collect_submit.sha256_hex(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode())
    if not args.submit and not collect_submit.confirm_interactive(
            endpoint, "quick report", digest):
        print("[submit] declined; nothing was uploaded")
        return 0
    try:
        receipt = collect_submit.submit_payload(
            endpoint, payload, token=collect_submit.token_from_env())
    except collect_submit.SubmitError as exc:
        print(f"[submit] FAILED: {exc}", file=sys.stderr)
        return 4
    print(f"[receipt] public URL: {receipt['url']} "
          f"(deduplicated={receipt['deduplicated']})")
    return 0


if __name__ == "__main__":
    main()
