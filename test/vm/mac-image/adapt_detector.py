"""Override only the packaged detector inside a disposable guest root."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat

import admit

NAME = 'omarchy-hw-apple-silicon'
TARGET = '/usr/bin/' + NAME
OVERRIDE = b'#!/bin/bash\n# Disposable QEMU qualification override, never shipped.\nexit 0\n'


def adapt(root):
    admit.require(root.is_absolute() and root.is_dir() and root.resolve() == root and not root.is_symlink(), 'unsafe disposable root')
    # This package uses real directories and an absolute compatibility symlink.
    # Reject parent links before opening either leaf from the host namespace.
    for relative in ('usr', 'usr/bin', 'usr/share', 'usr/share/omarchy', 'usr/share/omarchy/bin'):
        directory = root / relative
        admit.require(directory.is_dir() and not directory.is_symlink(), 'linked or missing detector parent: ' + relative)
    link = root / 'usr/share/omarchy/bin' / NAME
    admit.require(link.is_symlink() and os.readlink(link) == TARGET, 'packaged detector symlink target differs')
    target = root / 'usr/bin' / NAME
    info = target.lstat()
    admit.require(stat.S_ISREG(info.st_mode) and info.st_mode & 0o111 and info.st_size <= 64 * 1024,
                  'packaged detector target must be a regular executable')
    fd = os.open(target, os.O_RDWR | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r+b') as stream:
        opened = os.fstat(stream.fileno())
        admit.require((opened.st_dev, opened.st_ino, opened.st_mode) == (info.st_dev, info.st_ino, info.st_mode), 'detector target changed before open')
        before = hashlib.sha256(stream.read()).hexdigest()
        stream.seek(0)
        stream.write(OVERRIDE)
        stream.truncate()
        stream.flush()
        os.fsync(stream.fileno())
        stream.seek(0)
        after = hashlib.sha256(stream.read()).hexdigest()
    admit.require(after == hashlib.sha256(OVERRIDE).hexdigest(), 'disposable detector override differs')
    return {'kind': 'private-vm-detector-override', 'compatibility_link': str(link), 'link_target': TARGET,
            'modified_file': str(target), 'sha256_before': before, 'sha256_after': after,
            'mode_preserved': stat.S_IMODE(info.st_mode)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    print(json.dumps(adapt(parser.parse_args().root), sort_keys=True))
