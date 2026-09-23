"""Validate and release one explicitly disposable tmpfs ZIP after admission."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time

import admit

PREFIX = re.compile(r'quattro-limine-vm-payload-20260922\.[A-Za-z0-9_-]{6,64}\Z')
GIB = 1024**3


def identity(info):
    return {'device': info.st_dev, 'inode': info.st_ino, 'uid': info.st_uid,
            'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)}


def filesystem(path):
    return subprocess.check_output(['findmnt', '--first-only', '--noheadings', '--output', 'FSTYPE', '--target', str(path)], text=True).strip()


def available_memory():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'):
            return int(line.split()[1]) * 1024
    raise ValueError('MemAvailable is unavailable')


def scope(path):
    admit.require(path.is_absolute() and path.parent.parent == Path('/tmp') and PREFIX.fullmatch(path.parent.name),
                  'disposable ZIP must be in a new private /tmp/quattro-limine-vm-payload-20260922.* directory')
    admit.require(path.resolve() == path and not path.is_symlink() and not path.parent.is_symlink(), 'linked disposable ZIP path')
    admit.require(filesystem(path.parent) == 'tmpfs', 'disposable ZIP must use tmpfs')
    admit.require(sorted(item.name for item in path.parent.iterdir()) == [path.name], 'disposable directory must contain only its ZIP')


def inspect(path, package, inputs_sha256, owner):
    scope(path)
    directory = path.parent.stat()
    admit.require(directory.st_uid == owner and stat.S_IMODE(directory.st_mode) == 0o700, 'disposable directory ownership or mode differs')
    with admit.regular(path) as stream:
        info = os.fstat(stream.fileno())
        admit.require(info.st_uid == owner and stat.S_IMODE(info.st_mode) == 0o400 and info.st_nlink == 1,
                      'disposable ZIP must be owned, mode 0400 and singly linked')
        admit.require(path.name == package['filename'] and info.st_size == package['size_bytes'], 'disposable ZIP name or size differs')
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    admit.require(checksum == package['sha256'], 'disposable ZIP checksum differs')
    return {'schema': 1, 'path': str(path), 'directory': identity(directory), 'file': identity(info),
            'size_bytes': info.st_size, 'sha256': checksum, 'inputs_sha256': inputs_sha256}


def require_memory(candidate, dependencies):
    needed = sum(path.stat().st_size for root in (candidate, dependencies)
                 for path in root.iterdir() if path.is_file() and not path.is_symlink())
    admit.require(available_memory() > needed + GIB, 'insufficient available memory for verifier tmpfs plus 1 GiB margin')
    return needed


def mount_unescape(value):
    return re.sub(r'\\([0-7]{3})', lambda match: chr(int(match.group(1), 8)), value)


def reject_file_mounts(path, mountinfo=Path('/proc/self/mountinfo')):
    for line in mountinfo.read_text().splitlines():
        fields = line.split()
        admit.require(len(fields) >= 6, 'invalid mount visibility')
        mounted = mount_unescape(fields[4])
        admit.require(mounted != str(path) and not mounted.startswith(str(path.parent) + '/'),
                      'disposable inode is retained by a file or child bind mount')


def free_bytes(path):
    value = os.statvfs(path)
    return value.f_bfree * value.f_frsize


def release(receipt, admitted):
    admit.require(isinstance(receipt, dict) and set(receipt) == {'schema', 'path', 'directory', 'file', 'size_bytes', 'sha256', 'inputs_sha256'}
                  and receipt['schema'] == 1, 'invalid disposable ZIP receipt')
    path = Path(receipt['path'])
    completion = admit.strict_json((admitted / 'admission.json').read_bytes())
    pin, _ = admit.descriptor(admitted / 'inputs.json', receipt['inputs_sha256'])
    admit.require(completion['inputs_sha256'] == receipt['inputs_sha256'] and completion['payload_sha256'] == receipt['sha256'],
                  'disposable ZIP is not bound to successful admission')
    admit.require(admit.digest_file(admitted / 'verification.json') == pin['image_verification_sha256'], 'admitted image report changed')
    package = admit.strict_json((admitted / 'verification.json').read_bytes())['package']
    admit.require({key: package[key] for key in ('size_bytes', 'sha256')} == {key: receipt[key] for key in ('size_bytes', 'sha256')}
                  and package['filename'] == path.name, 'disposable ZIP differs from pinned image report')
    scope(path)
    reject_file_mounts(path)
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = None
    old_handler = signal.getsignal(signal.SIGIO)
    def lease_broken(_signal, _frame):
        raise ValueError('disposable ZIP lease was contested; refusing guest execution')
    try:
        admit.require(identity(os.fstat(directory_fd)) == receipt['directory'] and receipt['directory']['mode'] == 0o700,
                      'disposable directory identity changed')
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
        info = os.fstat(fd)
        admit.require(stat.S_ISREG(info.st_mode) and identity(info) == receipt['file'] and info.st_size == receipt['size_bytes']
                      and info.st_nlink == 1 and receipt['file']['mode'] == 0o400 and info.st_uid == receipt['directory']['uid'],
                      'disposable ZIP identity, ownership or link count changed')
        signal.signal(signal.SIGIO, lease_broken)
        # A write lease fails if any other file description holds this inode.
        # Keep it until close so a competing open cannot retain the deleted ZIP.
        fcntl.fcntl(fd, fcntl.F_SETLEASE, fcntl.F_WRLCK)
        with os.fdopen(os.dup(fd), 'rb') as stream:
            checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
        admit.require(checksum == receipt['sha256'], 'disposable ZIP changed after admission')
        admit.require(fcntl.fcntl(fd, fcntl.F_GETLEASE) == fcntl.F_WRLCK, 'disposable ZIP lease lost')
        admit.require(identity(os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)) == receipt['file'], 'disposable ZIP path substituted')
        reject_file_mounts(path)
        before = free_bytes(path.parent)
        allocated = info.st_blocks * 512
        os.unlink(path.name, dir_fd=directory_fd)
        admit.require(os.fstat(fd).st_nlink == 0, 'disposable ZIP inode remains linked')
        os.close(fd)
        fd = None
        deadline = time.monotonic() + 2
        while free_bytes(path.parent) < before + allocated and time.monotonic() < deadline:
            time.sleep(0.05)
        admit.require(free_bytes(path.parent) >= before + allocated, 'disposable ZIP allocation retained after close; refusing guest execution')
        admit.require(not list(path.parent.iterdir()), 'disposable directory changed during release')
        return {'kind': 'private-vm-disposable-payload-release', 'result': 'passed', 'path': str(path),
                'sha256': receipt['sha256'], 'size_bytes': receipt['size_bytes'], 'allocated_bytes_released': allocated,
                'inputs_sha256': receipt['inputs_sha256'], 'write_lease_checked': True, 'directory_empty': True}
    finally:
        if fd is not None:
            os.close(fd)
        signal.signal(signal.SIGIO, old_handler)
        os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--admitted', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(release(admit.strict_json(args.receipt), args.admitted), sort_keys=True))


if __name__ == '__main__':
    main()
