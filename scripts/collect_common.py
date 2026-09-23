#!/usr/bin/env python3
"""Shared helpers for the mlx-omarchy contributor collectors.

`collect_quick.py` and `collect_deep.py` import this module. It owns the
three things both collectors must agree on:

- PII redaction (`Redactor`): usernames, hostnames, home paths, IP
  addresses, MAC addresses, serial numbers, UUIDs, and credential-shaped
  strings never reach an output. Every embedded command output passes
  through it, and its per-kind counts go into the manifest so a reader can
  see what was removed.
- bounded external commands (`run_tool`, `run_python_probe`): a missing or
  hanging tool is recorded data, never a crash, never an unbounded wait.
- deterministic packaging (`build_manifest`, `archive_bytes`): sorted
  members, fixed mtime and owner, gzip mtime 0, so the previewed manifest
  and the written archive agree byte for byte.

Nothing in this module talks to the network. The collectors never upload.
"""

import gzip
import hashlib
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import getpass

SCHEMA_VERSION = 1

MAX_STREAM_LINES = 400
MAX_STREAM_CHARS = 200_000


class Redactor:
    """Replace personally identifying strings with typed placeholders."""

    def __init__(self, hostname=None, username=None, home=None):
        self.hostname = hostname or socket.gethostname()
        try:
            self.username = username or getpass.getuser()
        except Exception:
            self.username = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
        self.home = home or os.path.expanduser("~")
        self.counts = {}
        self._rules = self._build_rules()

    def _note(self, kind):
        self.counts[kind] = self.counts.get(kind, 0) + 1

    def _replace(self, kind, repl):
        def fn(_match):
            self._note(kind)
            return repl
        return fn

    # A dotted quad is not always an address: Vulkan reports
    # `conformanceVersion = 1.4.0.0`, and Apple reports boot firmware
    # versions like `iBoot-20712.1.2.0.0`, whose trailing quad is a
    # continuation of a dotted version chain. Keep the quad when the
    # text right before it is a version assignment or more dotted
    # octets; redact every other dotted quad.
    _VERSION_CONTEXT = re.compile(r"(?i)(?:version\s*[:=]\s*|\d+\.)$")

    def _ipv4_sub(self, match, field=None):
        if (isinstance(field, str) and field.lower().endswith("version")
                and not match.string[:match.start()].strip()):
            return match.group(0)
        line_start = match.string.rfind("\n", 0, match.start()) + 1
        prefix = match.string[line_start:match.start()]
        if self._VERSION_CONTEXT.search(prefix):
            return match.group(0)
        self._note("ipv4")
        return "[redacted-ip4]"

    def _build_rules(self):
        rules = []

        def rx(pattern, kind, repl, flags=0):
            rules.append((re.compile(pattern, flags), self._replace(kind, repl)))

        # Cred-shaped assignments first, so a value that also matches a
        # later rule is already gone. Name=NAME VALUE=VALUE keeps the name.
        rx(
            r"(?i)\b([A-Za-z0-9_]*(?:token|secret|passwd|password|api_?key|"
            r"private_?key)[A-Za-z0-9_]*)\s*([:=])\s*(\"[^\"]*\"|\S+)",
            "credential",
            r"\1\2 [redacted]",
        )
        # Known credential shapes without a key name.
        rx(r"\bgh[pousr]_[A-Za-z0-9]{16,}\b", "credential", "[redacted]")
        rx(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b", "credential", "[redacted]")
        rx(r"\bAKIA[0-9A-Z]{16}\b", "credential", "[redacted]")
        rx(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b", "credential", "[redacted]")
        rx(r"\bsk-[A-Za-z0-9_-]{20,}\b", "credential", "[redacted]")
        rx(r"\bBearer\s+\S+", "credential", "Bearer [redacted]")
        rx(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\b",
           "credential", "[redacted]")
        # Hardware identity.
        rx(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b", "mac", "[redacted-mac]")
        rx(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
           r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "uuid", "[redacted-uuid]")
        rx(r"(?i)(\"serial(?:[-_]?number)?\"\s*:\s*\")[^\"]*(\")",
           "serial", r"\1[redacted]\2")
        rx(r"(?i)\b(serial[-_]?number)\s*([=:])\s*(\S+)",
           "serial", r"\1\2 [redacted]")
        # ioreg/macOS hardware identity: "IOPlatformSerialNumber" = "C02…"
        rx(r"(?i)\"?(IOPlatformSerialNumber|IOPlatformUUID|BoardID|"
           r"board-id|serial-number)\"?\s*=\s*\"[^\"]*\"",
           "serial", r"\1 = [redacted]")
        # Bare Apple platform serial shape (e.g. C02XY9876543): a value
        # that lost its key must still not survive. Requires letter +
        # two digits + at least eight more alphanumerics, so model and
        # version tokens like H11ANEIn or t6000 never match.
        rx(r"\b[A-Z][0-9]{2}[A-Z0-9]{8,10}\b", "serial", "[redacted]")
        # Network identity. IPv6 before IPv4 so embedded v4-in-v6 is gone.
        rx(r"\b(?:fe80|fd[0-9a-f]{2}|fc[0-9a-f]{2})(?::[0-9a-fA-F]{0,4}){1,7}"
           r"(?:%\w+)?\b", "ipv6", "[redacted-ip6]", re.IGNORECASE)
        rx(r"\b(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}\b",
           "ipv6", "[redacted-ip6]")
        rules.append((
            re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,3})?\b"),
            self._ipv4_sub,
        ))
        # Home paths: this user's home first, then any user's.
        if self.home and self.home != "/" and self.home != "":
            rules.append((
                re.compile(re.escape(self.home)),
                self._replace("home_path", "[home]"),
            ))
        rx(r"(?<![\w.-])/(?:home|Users)/[^/\s:\"'@]+", "home_path", "[home]")
        # Live host and user names, last, so path placeholders above win.
        if self.hostname and len(self.hostname) >= 2:
            rules.append((
                re.compile(r"(?<![\w.-])" + re.escape(self.hostname) +
                           r"(?![\w.-])", re.IGNORECASE),
                self._replace("hostname", "[host]"),
            ))
        if self.username and len(self.username) >= 2:
            rules.append((
                re.compile(r"(?<![\w.-])" + re.escape(self.username) +
                           r"(?![\w.-])", re.IGNORECASE),
                self._replace("username", "[user]"),
            ))
        return rules

    def apply_value(self, value, field=None):
        """Redact structured observations without changing their types."""
        if isinstance(value, str):
            return self.apply(value, field=field)
        if isinstance(value, dict):
            return {key: self.apply_value(item, field=key)
                    for key, item in value.items()}
        if isinstance(value, list):
            return [self.apply_value(item) for item in value]
        return value

    def apply(self, text, *, field=None):
        if not isinstance(text, str):
            text = str(text)
        for pattern, repl in self._rules:
            if repl == self._ipv4_sub:
                text = pattern.sub(lambda match: self._ipv4_sub(match, field), text)
            else:
                text = pattern.sub(repl, text)
        return text


def cap_stream(text):
    """Cap one captured output stream so archives stay small."""
    if text is None:
        return ""
    lines = text.splitlines()
    total = len(lines)
    kept = lines[:MAX_STREAM_LINES]
    out = "\n".join(kept)[:MAX_STREAM_CHARS]
    if total > MAX_STREAM_LINES or len(text) > MAX_STREAM_CHARS:
        out += f"\n[truncated: {total} lines, {len(text)} chars captured]"
    return out


def redact_argv(argv, redactor):
    """Record the command shape without values that could carry secrets."""
    return [redactor.apply(str(a)) for a in argv]


def run_tool(argv, redactor, label=None, timeout=30, cwd=None, env=None):
    """Run one external command; record absence, timeout, and output.

    Returns a dict. Never raises for a missing binary or a timeout.
    """
    record = {
        "label": label or argv[0],
        "argv": redact_argv(argv, redactor),
        "available": True,
        "exit_code": None,
        "error": None,
        "duration_ms": None,
        "stdout": "",
        "stderr": "",
    }
    if shutil.which(argv[0]) is None:
        record["available"] = False
        record["error"] = "not-found"
        return record
    started = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            cwd=cwd,
            env=env,
        )
        record["exit_code"] = proc.returncode
        record["stdout"] = redactor.apply(cap_stream(proc.stdout or ""))
        record["stderr"] = redactor.apply(cap_stream(proc.stderr or ""))
    except subprocess.TimeoutExpired:
        record["error"] = f"timeout after {timeout}s"
    except OSError as exc:
        record["available"] = False
        record["error"] = f"os-error: {exc}"
    record["duration_ms"] = int((time.monotonic() - started) * 1000)
    return record


def run_python_probe(code, redactor, label, timeout=120, env=None):
    """Run a python snippet in a child interpreter, bounded."""
    return run_tool(
        [sys.executable, "-c", code],
        redactor,
        label=label,
        timeout=timeout,
        env=env,
    )


def dump_json(obj):
    """Deterministic JSON text: sorted keys, fixed indent, trailing newline."""
    return json.dumps(obj, indent=2, sort_keys=True) + "\n"


def json_bytes(obj):
    return dump_json(obj).encode("utf-8")


def archive_bytes(files):
    """Deterministic gzip tarball from {member name: bytes}.

    Sorted members, mtime 0, root owner, empty uname/gname, gzip mtime 0.
    Same files in, same bytes out.
    """
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name in sorted(files):
            data = files[name]
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = 0
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.type = tarfile.REGTYPE
            tf.addfile(info, io.BytesIO(data))
    return gzip.compress(buf.getvalue(), compresslevel=9, mtime=0)


def build_manifest(archive_name, files, extra=None):
    """Manifest describing every member except itself.

    `files` must not contain "manifest.json"; the caller adds it to the
    archive after hashing the manifest bytes themselves.
    """
    entries = []
    for name in sorted(files):
        data = files[name]
        entries.append({
            "path": name,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "manifest_version": 1,
        "tool": "mlx-omarchy collect-deep",
        "archive": archive_name,
        "files": entries,
        "no_network": True,
        "upload": "only after explicit --submit or SUBMIT confirmation",
    }
    if extra:
        manifest.update(extra)
    return manifest


def is_native_macos(host, manifest):
    """True when a report came from native macOS MLX rather than Linux."""
    return (host.get("system") or manifest.get("system")) == "Darwin"


def _cap_port_detail(port, redactor, max_bytes=64 * 1024):
    """Bounded `ane_port_detail` blob for the quick PAYLOAD.

    Carries the devicetree (and the runtime block if it fits) at enough
    fidelity to author the omarchy-ane overlay off-machine. The flat
    `ane_port` summary string is kept for back-compat with rows that
    were already stored before the detail object existed.

    Bounding rules, in order — each one marks `truncated` with the
    reason so a reader knows the shape of what was dropped:

      * ane_nodes / darts / phandles: hard cap of MAX_PORT_DETAIL_NODES
        each; a node beyond the cap is dropped, not truncated in place.
      * pmgr_domains: hard cap of 64 (matches the source collector).
      * total serialized bytes: hard cap of `max_bytes`. Drop order is
        by porting value: the runtime block first, then the phandle map
        (`iommus_resolved` already did that arithmetic for the reader),
        then the AIC block, then DARTs; the ane nodes — the whole point
        of the capture — are dropped last.
      * a macOS report carries `macos` instead of `devicetree` and is
        bounded at the source; if it somehow exceeds the budget the
        whole block is dropped.

    `redactor` is the shared one from the collector: every string value
    already passed it once during probe_ane_port; passing it again here
    is a belt-and-braces pass in case a probe missed a string-shaped
    value. Numeric and bool fields stay numeric and bool.
    """
    if not isinstance(port, dict):
        return None

    MAX_NODES = 8  # hard cap on ane_nodes / darts / phandles entries
    truncated = []

    src_devicetree = port.get("devicetree")
    src_runtime = port.get("runtime")
    src_macos = port.get("macos")

    def _walk(node):
        """Re-redact every string leaf; keep numeric/bool/list shape."""
        if isinstance(node, dict):
            return {k: _walk(v) for k, v in node.items()}
        if isinstance(node, list):
            return [_walk(v) for v in node]
        if isinstance(node, str):
            return redactor.apply(node) if redactor else node
        return node

    def _size(node):
        return len(json.dumps(node, separators=(",", ":")))

    # macOS: the probe bounds its own output; carry it through and
    # re-redact. The legacy Linux devicetree keys do not apply.
    if src_macos is not None:
        out = {"macos": _walk(src_macos)}
        if truncated or _size(out) > max_bytes:
            out["truncated"] = (truncated or [])[:15] + \
                ["macos:over_budget"]
            if _size(out) > max_bytes:
                return None
        return out

    src_devicetree = src_devicetree or {}
    def _bounded_dict(d, cap, name):
        if not isinstance(d, dict):
            return {}
        keys = sorted(d.keys())
        kept = {k: _walk(d[k]) for k in keys[:cap]}
        if len(keys) > cap:
            truncated.append(f"{name}:{len(keys) - cap}")
        return kept

    bounded = {
        "ane_node_present": bool(src_devicetree.get("ane_node_present")),
        "ane_nodes": _bounded_dict(src_devicetree.get("ane_nodes") or {},
                                   MAX_NODES, "ane_nodes"),
        "darts": _bounded_dict(src_devicetree.get("darts") or {},
                               MAX_NODES, "darts"),
        "pmgr_domains": _walk(src_devicetree.get("pmgr_domains") or [])[:64]
            if len(src_devicetree.get("pmgr_domains") or []) > 64
            else _walk(src_devicetree.get("pmgr_domains") or []),
        "aic": _walk(src_devicetree.get("aic"))
            if src_devicetree.get("aic") else None,
        "phandles": _bounded_dict(src_devicetree.get("phandles") or {},
                                  MAX_NODES, "phandles"),
    }
    if len(src_devicetree.get("pmgr_domains") or []) > 64:
        truncated.append(f"pmgr_domains:"
                         f"{len(src_devicetree['pmgr_domains']) - 64}")

    out = {"devicetree": bounded}

    if isinstance(src_runtime, dict):
        bounded_runtime = _walk(src_runtime)
        # Total budget check: include runtime only if it fits. We try
        # with runtime first, then drop it if it pushes us over the cap.
        candidate = dict(out)
        candidate["runtime"] = bounded_runtime
        if _size(candidate) <= max_bytes:
            out = candidate
        else:
            truncated.append("runtime:over_budget")

    # Still over budget: drop by porting value. The phandle map goes
    # first (iommus_resolved already did that arithmetic for the
    # reader), then the AIC block, then DARTs; the ane nodes go last.
    if _size(out) > max_bytes:
        trimmed = out
        for field, blank in (("phandles", {}), ("aic", None),
                             ("darts", {}), ("ane_nodes", {})):
            if _size(trimmed) <= max_bytes:
                break
            dt = dict(trimmed["devicetree"])
            dt[field] = blank
            trimmed = {"devicetree": dt}
            if "runtime" in out:
                trimmed["runtime"] = out["runtime"]
            truncated.append(f"{field}:over_budget")
        if _size(trimmed) > max_bytes:
            truncated.append("devicetree:over_budget")
            return None
        out = trimmed

    if truncated:
        out["truncated"] = truncated[:16]
    return out


def build_payload(kind, quick, manifest, generated_at=None, benchmark=None,
                  redactor=None):
    """Build the strict-schema JSON summary sent with the upload.

    Must match schema/payload-v1.schema.json in services/community-data:
    fixed key set, schema_version pinned, every identity field nullable.
    All values come from already-redacted data. `redactor` is the
    collector's shared Redactor; it is used to belt-and-braces re-redact
    the ane_port_detail blob in case a probe missed a string-shaped
    value. New callers should pass it; existing tests that do not are
    tolerated (re-redaction becomes a no-op).
    """
    host = quick.get("host") or {}
    dt = host.get("devicetree") or {}
    gpu = (quick.get("mesa") or {}).get("gpu") or {}
    mlx = quick.get("mlx") or {}
    distributions = mlx.get("distributions") or {}
    compatible = dt.get("compatible") or []
    # Group by SoC, not by board: an M1 MacBook Pro reports
    # ["apple,j293", "apple,t8103", "apple,arm-platform"], and only
    # apple,t8103 identifies the chip that every other M1 machine shares.
    soc = next((c for c in compatible
                if re.match(r"^apple,t\d{4}", c)), None)
    host_cpu = host.get("cpu_online")
    cpu = host.get("cpu") or {}
    boot = host.get("boot") or {}
    cmdline = host.get("cmdline")
    ane_dt = (quick.get("ane") or {}).get("devicetree") or {}
    ane_compatible = ane_dt.get("compatible")
    ane_compat_blob = " ".join(str(t) for t in ane_compatible) \
        if isinstance(ane_compatible, list) else None
    boot_chain = " ".join(
        f"{key}={boot[key]}" for key in sorted(boot)
        if isinstance(boot.get(key), str) and boot[key])
    present = cpu.get("present")
    shortfall = host.get("core_shortfall")
    # Plain wire fact: true when the report recorded an unexplained
    # shortfall, false when present/online are known and equal enough,
    # null when the counts needed to judge are missing.
    if isinstance(shortfall, dict):
        shortfall_flag = True
    elif isinstance(present, int) and isinstance(host_cpu, int):
        shortfall_flag = False
    else:
        shortfall_flag = None
    # The benchmark numbers must ride in the summary, not only inside the
    # archive: the read API serves summaries, so cross-machine comparison
    # is impossible unless the numbers travel with them.
    rows = []
    for row in (benchmark or [])[:16]:
        if not isinstance(row, dict) or not isinstance(row.get("n"), int):
            continue
        rows.append({
            "n": row["n"],
            "tflops": row.get("tflops"),
            "median_ms": row.get("median_ms"),
        })
    native = is_native_macos(host, manifest)
    # Bounded driver-port summary: enough for fleet queries (does this
    # SoC expose the ane node, how many DARTs and PMGR domains, which
    # AIC) without shipping the full devicetree dump in every payload.
    src_port = quick.get("ane_port") or {}
    macos_port = src_port.get("macos")
    if isinstance(macos_port, dict):
        cores = sorted({i.get("cores") for i in
                        (macos_port.get("instances") or [])
                        if isinstance(i.get("cores"), int)})
        ane_port = (
            "native_macos=1 instances=%d cores=%s dart_ane=%d "
            "firmware=%s" % (
                len(macos_port.get("instances") or []),
                "+".join(str(c) for c in cores) or "?",
                len(macos_port.get("dart_nodes") or []),
                "loaded" if any(i.get("firmware_loaded")
                                for i in macos_port.get("instances") or [])
                else "unknown"))[:1024]
    else:
        port = src_port.get("devicetree") or {}
        port_parts = [
            "present=" + str(bool(port.get("ane_node_present"))).lower()]
        for name, props in sorted((port.get("ane_nodes") or {}).items()):
            regs = props.get("reg") if isinstance(props, dict) else None
            port_parts.append(f"{name}={regs[0] if regs else 'no-reg'}")
        port_parts.append(f"darts={len(port.get('darts') or {})}")
        port_parts.append(
            f"pmgr_domains={len(port.get('pmgr_domains') or [])}")
        aic_compat = (port.get("aic") or {}).get("compatible") or []
        if aic_compat:
            port_parts.append(f"aic={aic_compat[0]}")
        ane_port = (" ".join(port_parts)[:1024]
                    if quick.get("ane_port") else None)
    # Bounded full-structure port detail. Capped per-section, total
    # bytes hard-bounded; truncation is recorded explicitly so a reader
    # can tell which corner the cap clipped. Re-redacts every string
    # leaf against the shared Redactor in case a probe missed one.
    ane_port_detail = _cap_port_detail(quick.get("ane_port"), redactor) \
        if quick.get("ane_port") else None
    kernel = host.get("kernel_release")
    if native:
        shortfall_flag = None
        kernel = f"Darwin {kernel or 'unknown'} ({host.get('os') or 'macOS'})"
    device = mlx.get("default_device")
    if native and mlx.get("metal_available"):
        device = f"Metal GPU (native macOS MLX, {device})"
    return {
        "schema_version": SCHEMA_VERSION,
        "kind": kind,
        "generated_at": generated_at or time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "arch": host.get("arch"),
        "model": host.get("model") if native else dt.get("model"),
        "chip": host.get("chip") if native else
            soc or (compatible[0] if compatible else None),
        "kernel": kernel,
        "mesa_driver": gpu.get("driverName"),
        "mesa_device": gpu.get("deviceName"),
        "mlx_version": distributions.get("mlx-omarchy")
            or mlx.get("mlx_version"),
        "mlx_device": device,
        "source_commit": manifest.get("source_commit"),
        "repo_dirty": manifest.get("repo_dirty"),
        "cpu_present": present if isinstance(present, int) else None,
        "hotplug_control": cpu.get("hotplug_control")
            if isinstance(cpu.get("hotplug_control"), bool) else None,
        "ane_dt_node": ane_dt.get("node")
            if isinstance(ane_dt.get("node"), bool) else None,
        "ane_port": ane_port or None,
        "ane_port_detail": ane_port_detail,
        "ane_dt_compatible": ane_compat_blob[:512] if ane_compat_blob
        else None,
        "boot_chain": boot_chain[:512] or None,
        "cmdline": cmdline[:1024] if isinstance(cmdline, str) else None,
        "core_shortfall": shortfall_flag,
        "cpu_online": host_cpu if isinstance(host_cpu, int) else None,
        "benchmark": rows,
        "redaction_summary": dict(
            manifest.get("redaction_summary") or {}),
        "files": [
            {key: entry[key] for key in ("path", "bytes", "sha256")}
            for entry in manifest.get("files", [])
        ],
    }


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None
