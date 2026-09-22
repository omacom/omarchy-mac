"""Authenticate and freeze private Mac VM inputs before any privileged operation."""
from __future__ import annotations

import argparse
import hashlib
import fcntl
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import zipfile

CHUNK = 1024 * 1024
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        while chunk := stream.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def strict_json(data):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, f"duplicate JSON key: {key}")
            value[key] = item
        return value
    return json.loads(data, object_pairs_hook=unique)


def regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    require(stat.S_ISREG(os.fstat(fd).st_mode), f"not a regular file: {path}")
    return os.fdopen(fd, "rb")


def copy_pinned(source, target, expected, size=None):
    require(DIGEST.fullmatch(expected), "invalid expected digest")
    h = hashlib.sha256()
    total = 0
    with regular(source) as incoming, target.open("xb") as outgoing:
        while chunk := incoming.read(CHUNK):
            h.update(chunk)
            total += len(chunk)
            outgoing.write(chunk)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    require(h.hexdigest() == expected, f"checksum mismatch: {source}")
    require(size is None or total == size, f"size mismatch: {source}")
    target.chmod(0o400)


def descriptor(path, expected):
    require(DIGEST.fullmatch(expected), "--inputs-sha256 must be supplied independently")
    with regular(path) as stream:
        data = stream.read(1024 * 1024 + 1)
    require(len(data) <= 1024 * 1024, "oversized descriptor")
    require(hashlib.sha256(data).hexdigest() == expected, "VM descriptor checksum mismatch")
    value = strict_json(data)
    required = {"schema", "kind", "builder_revision", "runtime_revision", "trust_policy_sha256",
                "trust_public_sha256", "candidate_receipt_sha256", "dependency_manifest_sha256",
                "image_verification_sha256", "product_sha256", "generic_kernel"}
    require(isinstance(value, dict) and set(value) == required, "VM descriptor fields differ")
    require(value["schema"] == 1 and value["kind"] == "quattro-private-vm-inputs", "wrong VM descriptor kind")
    for key in ("builder_revision", "runtime_revision"):
        require(isinstance(value[key], str) and REVISION.fullmatch(value[key]), f"invalid {key}")
    for key in required - {"schema", "kind", "builder_revision", "runtime_revision", "generic_kernel"}:
        require(isinstance(value[key], str) and DIGEST.fullmatch(value[key]), f"invalid {key}")
    kernel = value["generic_kernel"]
    require(isinstance(kernel, dict) and set(kernel) == {"filename", "sha256", "signature_sha256", "size_bytes", "version"}, "wrong generic kernel fields")
    require(re.fullmatch(r"linux-aarch64-[A-Za-z0-9.+_-]+-aarch64\.pkg\.tar\.(xz|zst)", kernel["filename"]), "wrong generic kernel filename")
    require(DIGEST.fullmatch(kernel["sha256"]) and DIGEST.fullmatch(kernel["signature_sha256"]), "invalid kernel digest")
    require(type(kernel["size_bytes"]) is int and 0 < kernel["size_bytes"] < 1024**3, "invalid generic kernel size")
    require(re.fullmatch(r"[A-Za-z0-9.+_-]+", kernel["version"]), "invalid generic kernel version")
    return value, data


def freeze_builder(repository, revision, target):
    """Use committed blobs, never executable files from a possibly dirty checkout."""
    git = ["git", "-c", f"safe.directory={repository.resolve()}", "-C", str(repository)]
    actual = subprocess.check_output([*git, "rev-parse", "HEAD"], text=True).strip()
    require(actual == revision, "builder HEAD differs from caller-pinned revision")
    listing = subprocess.check_output([*git, "ls-tree", "-r", "-z", revision, "--", "builder"])
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        rel = PurePosixPath(raw_path.decode())
        require(mode in {"100644", "100755"} and kind == "blob" and rel.parts[0] == "builder" and ".." not in rel.parts, "unsafe builder tree")
        output = target / rel
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(subprocess.check_output([*git, "cat-file", "blob", oid]))
        output.chmod(0o500 if mode == "100755" else 0o400)
    for filename in ("quattro-candidate.py", "quattro-dependencies.py", "verify-asahi-os-package.py"):
        require((target / "builder" / filename).is_file(), f"builder lacks {filename}")


def clone_member(source_root, rel, output, entry):
    """Clone a verified export without allocating a second image's data blocks."""
    require(source_root.is_dir() and not source_root.is_symlink(), "unsafe exported member root")
    source = source_root
    for component in rel.parts:
        source /= component
        require(not source.is_symlink(), "linked exported image member")
    with regular(source) as incoming, output.open("xb") as outgoing:
        # Linux FICLONE: refuse cross-filesystem/non-CoW fallback, which could fill the host.
        fcntl.ioctl(outgoing.fileno(), 0x40049409, incoming.fileno())
        outgoing.flush()
        os.fsync(outgoing.fileno())
    require(output.stat().st_size == entry["size_bytes"] and digest_file(output) == entry["sha256"],
            "exported image member checksum or size differs")


def extract_verified(payload, record, destination, source_members=None):
    """Validate every member while extracting sparse disk images into a new directory."""
    require(record.get("schema_version") == 1 and record.get("verification_kind") == "asahi-full-os-package", "wrong image verification kind")
    require(record.get("checks", {}).get("boot_backend") == "asahi-limine", "VM requires verified Limine image")
    package = record["package"]
    require(payload.name == package["filename"], "payload filename differs")
    members = record["members"]
    require({"root.img", "boot.img", "esp/EFI/BOOT/BOOTAA64.EFI", "esp/m1n1/boot.bin"} <= set(members), "missing verified image members")
    destination.mkdir(mode=0o700)
    with regular(payload) as source:
        h = hashlib.sha256()
        total = 0
        while chunk := source.read(CHUNK):
            h.update(chunk)
            total += len(chunk)
        require(total == package["size_bytes"] and h.hexdigest() == package["sha256"], "payload checksum or size mismatch")
        source.seek(0)
        with zipfile.ZipFile(source) as archive:
            found = set()
            for info in archive.infolist():
                name = info.filename
                rel = PurePosixPath(name)
                file_type = (info.external_attr >> 16) & 0o170000
                require(name and "\\" not in name and not rel.is_absolute() and ".." not in rel.parts
                        and str(rel) == name.rstrip("/"), f"unsafe image member: {name}")
                if info.is_dir():
                    require(file_type in {0, stat.S_IFDIR}, "unsafe directory member type")
                    continue
                require(file_type in {0, stat.S_IFREG}, "unsafe image member type")
                require(name not in found and name in members, f"unexpected or duplicate image member: {name}")
                found.add(name)
                entry = members[name]
                require(info.file_size == entry["size_bytes"], f"image member size differs: {name}")
                output = destination / rel
                output.parent.mkdir(parents=True, exist_ok=True)
                if source_members is not None:
                    clone_member(source_members, rel, output, entry)
                    output.chmod(0o400)
                    continue
                h = hashlib.sha256()
                total = 0
                with archive.open(info) as incoming, output.open("xb") as outgoing:
                    while chunk := incoming.read(CHUNK):
                        h.update(chunk)
                        total += len(chunk)
                        if chunk.count(0) == len(chunk):
                            outgoing.seek(len(chunk), os.SEEK_CUR)
                        else:
                            outgoing.write(chunk)
                    outgoing.truncate(total)
                    outgoing.flush()
                    os.fsync(outgoing.fileno())
                require(total == entry["size_bytes"] and h.hexdigest() == entry["sha256"], f"image member checksum differs: {name}")
                output.chmod(0o400)
            require(found == set(members), "verified image member missing")


def admit(args):
    pin, descriptor_bytes = descriptor(args.inputs, args.inputs_sha256)
    args.output.mkdir(mode=0o700)  # Failed runs cannot be reused.
    output = args.output.resolve()
    (output / "inputs.json").write_bytes(descriptor_bytes)
    freeze_builder(args.builder, pin["builder_revision"], output / "source")
    builder = output / "source/builder"
    for rel, expected in (("policy.json", pin["trust_policy_sha256"]), ("public.gpg", pin["trust_public_sha256"])):
        require(digest_file(builder / "quattro-trust" / rel) == expected, "pinned builder trust differs")
    subprocess.run([sys.executable, str(builder / "quattro-candidate.py"), "--input", str(args.candidate_root),
                    "--output", str(output / "candidate"), "--receipt-sha256", pin["candidate_receipt_sha256"],
                    "--source-revision", pin["runtime_revision"]], check=True)
    subprocess.run([sys.executable, str(builder / "quattro-dependencies.py"), "--input", str(args.dependency_root),
                    "--output", str(output / "dependencies"), "--manifest-sha256", pin["dependency_manifest_sha256"],
                    "--candidate-schema", "4"], check=True)
    manifest = strict_json((output / "candidate/manifest.json").read_bytes())
    require(manifest["schema"] == 4, "VM requires candidate schema 4")
    copy_pinned(args.product, output / "product.json", pin["product_sha256"])
    copy_pinned(args.verification, output / "verification.json", pin["image_verification_sha256"])
    record = strict_json((output / "verification.json").read_bytes())
    product = strict_json((output / "product.json").read_bytes())
    require(record["product_id"] == product["product_id"] and product["boot_backend"] == "asahi-limine", "product verification differs")
    require(record["package"]["filename"] == product["package_filename"], "product package differs")
    for kind in ("boot", "root"):
        require(record["members"][f"{kind}.img"]["size_bytes"] == product[f"{kind}_size_bytes"], "product image size differs")
    kernel = pin["generic_kernel"]
    copy_pinned(args.generic_kernel, output / kernel["filename"], kernel["sha256"], kernel["size_bytes"])
    copy_pinned(args.generic_kernel_signature, output / (kernel["filename"] + ".sig"), kernel["signature_sha256"])
    extract_verified(args.payload, record, output / "payload", args.members_source)
    # Completion is written only after all snapshots and every image byte are admitted.
    (output / "admission.json").write_text(json.dumps({"schema": 1, "inputs_sha256": args.inputs_sha256,
        "builder_revision": pin["builder_revision"], "runtime_revision": pin["runtime_revision"],
        "payload_sha256": record["package"]["sha256"], "scope": "generic-kernel VM; not Apple firmware qualification"}, indent=2) + "\n")
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("inputs", "builder", "candidate-root", "dependency-root", "payload", "product", "verification", "generic-kernel", "generic-kernel-signature", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--inputs-sha256", required=True)
    parser.add_argument("--members-source", type=Path, help="optional already exported image members; verified FICLONE only")
    args = parser.parse_args()
    try:
        admit(args)
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f"admission refused: {error}\n")


if __name__ == "__main__":
    main()
