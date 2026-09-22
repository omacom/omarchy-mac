#!/usr/bin/env python3
"""Upload path for the mlx-omarchy contributor diagnostics archive.

The only network code in the collectors lives here. `collect_quick.py`
never imports this module; `collect_deep.py` imports it lazily, only
after the user has seen the preview and asked to submit explicitly.

Wire protocol (the Cloudflare Worker in services/community-data/):

  POST <base>/v1/submit
       body: {"schema_version", "kind", "content_sha256", "payload",
              "archive": {"total_bytes", "chunk_bytes", "chunk_count",
                          "chunk_sha256": [<hex>...]} | null,
              "pow": {"nonce", "difficulty"}}
       200 -> {"status": "awaiting_chunks"|"stored"|"duplicate",
               "content_sha256", "missing_chunks": [...], "receipt_url"}
  POST <base>/v1/submit/<sha>/chunk/<idx>   body: one raw chunk
       200 -> {"status": "stored"|"duplicate", "idx",
               "missing_chunks": [...]}
  POST <base>/v1/submit/<sha>/complete
       200 -> {"status": "stored"|"duplicate", "receipt_url"}
       409 -> {"error": "incomplete", "missing_chunks": [...]}
  GET  <base>/v1/submit/<sha>               dedup probe
       200 -> {"status": "duplicate"}; 404 -> not present

Only the already-redacted payload and archive are sent. Uploads are
resumable: a re-run repeats the initiate call and uploads only the
chunks the server reports as missing. The proof-of-work nonce is bound
to the archive hash, so a token cannot be reused for other content.

A custom User-Agent is required: workers.dev fronting 403s the default
Python-urllib user agent.

Every failure raises SubmitError. The caller keeps the local archive
and prints the error; a failed submit never destroys local output.
"""

import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_TIMEOUT = 60

# Must mirror services/community-data/src/caps.ts.
CHUNK_BYTES = 768 * 1024
MAX_ARCHIVE_BYTES = 8 * 1024 * 1024
MAX_PAYLOAD_BYTES = 256 * 1024
POW_DIFFICULTY = 18

USER_AGENT = "mlx-omarchy-collector/1"


class SubmitError(RuntimeError):
    pass


def _request(urlopen, req, timeout):
    try:
        with urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            return resp.status, body
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        raise SubmitError(f"endpoint unreachable: {exc}") from exc


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def leading_zero_bits(hex_digest):
    bits = 0
    for ch in hex_digest:
        nibble = int(ch, 16)
        if nibble == 0:
            bits += 4
            continue
        if nibble < 2:
            bits += 3
        elif nibble < 4:
            bits += 2
        elif nibble < 8:
            bits += 1
        break
    return bits


def solve_pow(content_sha256, difficulty=POW_DIFFICULTY):
    """Find a nonce so sha256("<sha>:<nonce>") has >= difficulty zero bits."""
    nonce = 0
    while True:
        digest = hashlib.sha256(f"{content_sha256}:{nonce}".encode()).hexdigest()
        if leading_zero_bits(digest) >= difficulty:
            return str(nonce)
        nonce += 1


def chunk_archive(data, chunk_bytes=CHUNK_BYTES):
    """Deterministic split; returns [(idx, bytes, sha256), ...]."""
    chunks = []
    for idx, off in enumerate(range(0, len(data), chunk_bytes)):
        piece = data[off:off + chunk_bytes]
        chunks.append((idx, piece, sha256_hex(piece)))
    return chunks


def _decode(body):
    try:
        return json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}


def _headers(token, extra=None):
    headers = {
        "User-Agent": USER_AGENT,
        "Authorization": f"Bearer {token}",
    } if token else {"User-Agent": USER_AGENT}
    if extra:
        headers.update(extra)
    return headers


def submit(endpoint, data, payload, timeout=DEFAULT_TIMEOUT, urlopen=None,
           token=None):
    """Submit one archive; returns {"url", "deduplicated", "status"}.

    `urlopen` is injectable for tests. Resumable: re-invoking after a
    mid-upload failure re-initiates and sends only the missing chunks.
    """
    if len(data) > MAX_ARCHIVE_BYTES:
        raise SubmitError(
            f"archive too large for the public endpoint: {len(data)} > "
            f"{MAX_ARCHIVE_BYTES} bytes; it stays local")
    if urlopen is None:
        opener = urllib.request.build_opener()
        urlopen = opener.open
    base = endpoint.rstrip("/")
    digest = sha256_hex(data)
    chunks = chunk_archive(data)

    status, body = _request(
        urlopen,
        urllib.request.Request(
            f"{base}/v1/submit/{digest}", headers=_headers(token)),
        timeout)
    if status == 200:
        return _receipt(_decode(body), deduplicated=True, status=status)
    if status != 404:
        raise SubmitError(f"dedup probe failed with HTTP {status}")

    difficulty = POW_DIFFICULTY
    for attempt in range(2):
        initiate = {
            "schema_version": payload.get("schema_version", 1),
            "kind": payload.get("kind", "deep"),
            "content_sha256": digest,
            "payload": payload,
            "archive": {
                "total_bytes": len(data),
                "chunk_bytes": CHUNK_BYTES,
                "chunk_count": len(chunks),
                "chunk_sha256": [c[2] for c in chunks],
            },
            "pow": {
                "nonce": solve_pow(digest, difficulty),
                "difficulty": difficulty,
            },
        }
        status, body = _request(
            urlopen,
            urllib.request.Request(
                f"{base}/v1/submit",
                data=json.dumps(initiate).encode("utf-8"),
                headers=_headers(token, {"Content-Type": "application/json"}),
                method="POST"),
            timeout)
        decoded = _decode(body)
        if status == 403 and decoded.get("error") == "pow_invalid":
            wanted = (decoded.get("detail") or {}).get("min_difficulty")
            if isinstance(wanted, int) and wanted > difficulty:
                difficulty = wanted
                continue
        break

    if status != 200:
        raise SubmitError(
            f"initiate failed with HTTP {status}: {decoded.get('error')}")

    if decoded.get("status") == "duplicate":
        return _receipt(decoded, deduplicated=True, status=status)
    if decoded.get("status") == "stored":
        return _receipt(decoded, deduplicated=False, status=status)

    for idx in decoded.get("missing_chunks", []):
        piece = chunks[idx][1]
        cstatus, cbody = _request(
            urlopen,
            urllib.request.Request(
                f"{base}/v1/submit/{digest}/chunk/{idx}",
                data=piece,
                headers=_headers(token,
                                 {"Content-Type": "application/octet-stream"}),
                method="POST"),
            timeout)
        cdecoded = _decode(cbody)
        if cstatus != 200:
            raise SubmitError(
                f"chunk {idx} failed with HTTP {cstatus}: "
                f"{cdecoded.get('error')}; re-run to resume")

    fstatus, fbody = _request(
        urlopen,
        urllib.request.Request(
            f"{base}/v1/submit/{digest}/complete",
            data=b"",
            headers=_headers(token),
            method="POST"),
        timeout)
    fdecoded = _decode(fbody)
    if fstatus == 409 and fdecoded.get("error") == "incomplete":
        raise SubmitError(
            f"server still misses chunks {fdecoded.get('missing_chunks')}; "
            f"re-run to resume")
    if fstatus != 200:
        raise SubmitError(
            f"complete failed with HTTP {fstatus}: {fdecoded.get('error')}")
    return _receipt(fdecoded, deduplicated=False, status=fstatus)


def submit_payload(endpoint, payload, timeout=DEFAULT_TIMEOUT, urlopen=None,
                   token=None):
    """Publish a payload-only report: no archive, one round trip.

    The quick report is small and self-describing, so the endpoint takes
    `archive: null` and publishes at initiate. Content is addressed by
    the sha256 of the canonical payload bytes, so re-running an unchanged
    machine deduplicates instead of adding a row.
    """
    if urlopen is None:
        opener = urllib.request.build_opener()
        urlopen = opener.open
    base = endpoint.rstrip("/")
    body = json.dumps(payload, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")
    if len(body) > MAX_PAYLOAD_BYTES:
        raise SubmitError(
            f"report too large for the public endpoint: {len(body)} > "
            f"{MAX_PAYLOAD_BYTES} bytes; it stays local")
    digest = sha256_hex(body)

    status, raw = _request(
        urlopen,
        urllib.request.Request(
            f"{base}/v1/submit/{digest}", headers=_headers(token)),
        timeout)
    if status == 200:
        return _receipt(_decode(raw), deduplicated=True, status=status)
    if status != 404:
        raise SubmitError(f"dedup probe failed with HTTP {status}")

    difficulty = POW_DIFFICULTY
    decoded = {}
    for _attempt in range(2):
        initiate = {
            "schema_version": payload.get("schema_version", 1),
            "kind": payload.get("kind", "quick"),
            "content_sha256": digest,
            "payload": payload,
            "archive": None,
            "pow": {
                "nonce": solve_pow(digest, difficulty),
                "difficulty": difficulty,
            },
        }
        status, raw = _request(
            urlopen,
            urllib.request.Request(
                f"{base}/v1/submit",
                data=json.dumps(initiate).encode("utf-8"),
                headers=_headers(token, {"Content-Type": "application/json"}),
                method="POST"),
            timeout)
        decoded = _decode(raw)
        if status == 403 and decoded.get("error") == "pow_invalid":
            wanted = (decoded.get("detail") or {}).get("min_difficulty")
            if isinstance(wanted, int) and wanted > difficulty:
                difficulty = wanted
                continue
        break

    if status != 200:
        raise SubmitError(
            f"submit failed with HTTP {status}: {decoded.get('error')}")
    return _receipt(decoded,
                    deduplicated=decoded.get("status") == "duplicate",
                    status=status)


def _receipt(body, deduplicated, status):
    url = body.get("receipt_url")
    if not url:
        raise SubmitError("endpoint returned no receipt URL")
    return {"url": url, "deduplicated": deduplicated, "status": status}


DEFAULT_ENDPOINT = "https://mlx-omarchy-community-data.joshua-s-warren.workers.dev"


def endpoint_from_args(args):
    """Resolve the endpoint: --submit flag first, then the environment."""
    if getattr(args, "submit", None):
        return args.submit
    return os.environ.get("MLX_OMARCHY_SUBMIT_URL") or None


def token_from_env():
    return os.environ.get("MLX_OMARCHY_SUBMIT_TOKEN") or None


def sys_stdin_isatty():
    return os.environ.get("MLX_OMARCHY_ASSUME_YES") != "1" and \
        sys.stdin.isatty()


def confirm_interactive(endpoint, archive_name, digest):
    """Ask for the exact word SUBMIT on a terminal; anything else declines."""
    if not sys_stdin_isatty():
        return False
    print(f"[submit] endpoint: {endpoint}")
    print(f"[submit] archive: {archive_name} sha256={digest}")
    print("[submit] only redacted report data and any attached archive are sent. "
          "Type SUBMIT to upload, anything else to keep it local:")
    try:
        answer = input().strip()
    except (EOFError, KeyboardInterrupt):
        return False
    return answer == "SUBMIT"
