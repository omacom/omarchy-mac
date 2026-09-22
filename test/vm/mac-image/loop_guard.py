"""Require exact owned loop identity and host desktop exclusion before mounting."""
from pathlib import Path
import re
import time

TAG = "limine-private-20260922"


def check(device, backing, *, sys_root=Path('/sys'), udev_root=Path('/run/udev'), mountinfo=Path('/host-mountinfo')):
    name = Path(device).name
    match = re.fullmatch(r'(loop[0-9]+)(p[0-9]+)?', name)
    if match is None or str(device) != '/dev/' + name:
        raise ValueError('not an explicitly tracked loop disk')
    parent = sys_root / 'block' / match.group(1)
    node = parent / name if match.group(2) else parent
    actual = (parent / 'loop/backing_file').read_text().strip()
    if actual != str(backing):
        raise ValueError(f'loop backing identity differs: {device}: {actual}')
    major_minor = (node / 'dev').read_text().strip()
    properties = (udev_root / 'data' / ('b' + major_minor)).read_text().splitlines()
    if 'E:UDISKS_IGNORE=1' not in properties or 'E:OMARCHY_PRIVATE_LOOP=' + TAG not in properties:
        raise ValueError(f'host udev exclusion missing for {device}')
    for line in mountinfo.read_text().splitlines():
        fields = line.split()
        if len(fields) > 5 and fields[2] == major_minor:
            raise ValueError(f'owned loop is unexpectedly mounted in host namespace: {line}')
    return {'device': str(device), 'backing_file': actual, 'major_minor': major_minor,
            'host_udisks_ignore': True, 'host_private_tag': TAG, 'host_mount_absent': True}


def wait(device, backing):
    # New kernel loop events are processed by the host udev daemon asynchronously.
    deadline = time.monotonic() + 10
    while True:
        try:
            return check(device, backing)
        except (OSError, ValueError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def wait_released(device, backing, *, sys_block=Path('/sys/block')):
    path = sys_block / Path(device).name / 'loop/backing_file'
    deadline = time.monotonic() + 10
    while path.exists() and path.read_text().strip() == str(backing):
        if time.monotonic() >= deadline:
            raise ValueError(f'owned loop still held after detach: {device}')
        time.sleep(0.1)
    return {'device': device, 'owned_backing_released': True}


if __name__ == '__main__':
    import json
    import sys
    if sys.argv[1] == '--released':
        print(json.dumps(wait_released(*sys.argv[2:4]), sort_keys=True))
        raise SystemExit(0)
    device, backing = sys.argv[1:3]
    records = [wait(device, backing)]
    for child in sorted((Path('/sys/block') / Path(device).name).glob(Path(device).name + 'p*')):
        if (child / 'partition').exists():
            records.append(wait('/dev/' + child.name, backing))
    print(json.dumps(records, sort_keys=True))
