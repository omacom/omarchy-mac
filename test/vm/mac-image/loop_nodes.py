"""Materialize only guarded loop partitions in a container-private /dev."""
import argparse
import json
import os
from pathlib import Path
import re
import stat

import admit
import loop_guard


class Nodes:
    lstat = staticmethod(os.lstat)
    create = staticmethod(os.mknod)
    unlink = staticmethod(os.unlink)


def private_dev(namespace=Path('/proc/self/mountinfo'), host=Path('/host-mountinfo')):
    def entries(path):
        result = []
        for line in path.read_text().splitlines():
            fields = line.split()
            if len(fields) > 6 and fields[4] == '/dev':
                separator = fields.index('-')
                result.append({'device': fields[2], 'root': fields[3], 'filesystem': fields[separator + 1]})
        return result
    local, original = entries(namespace), entries(host)
    admit.require(len(local) == 1 and len(original) == 1, 'missing or ambiguous container/host /dev mount visibility')
    admit.require(local[0]['filesystem'] == 'tmpfs' and local[0]['root'] == '/' and local[0]['device'] != original[0]['device'],
                  'refusing device nodes outside a container-private /dev tmpfs')
    return local[0]


def discovered(device, backing, count, *, sys_root=Path('/sys'), check=loop_guard.check):
    match = re.fullmatch(r'/dev/(loop[0-9]+)', device)
    admit.require(match is not None, 'not an exact owned loop device')
    admit.require(type(count) is int and 0 <= count <= 16, 'invalid expected partition count')
    name = match.group(1)
    parent = sys_root / 'block' / name
    check(device, backing)
    admit.require((parent / 'loop/backing_file').read_text().strip() == backing, 'loop backing changed')
    result = []
    numbers = []
    for child in sorted(parent.glob(name + 'p*')):
        suffix = re.fullmatch(re.escape(name) + r'p([1-9][0-9]*)', child.name)
        admit.require(suffix is not None and child.parent == parent, 'unexpected loop child path')
        number = int(suffix.group(1))
        admit.require((child / 'partition').read_text().strip() == str(number), 'loop partition identity differs')
        major_minor = (child / 'dev').read_text().strip()
        admit.require(re.fullmatch(r'[0-9]+:[0-9]+', major_minor), 'invalid partition major/minor')
        guarded = check('/dev/' + child.name, backing)
        admit.require(guarded['major_minor'] == major_minor, 'guarded partition device changed')
        numbers.append(number)
        result.append({'path': '/dev/' + child.name, 'major_minor': major_minor})
    admit.require(sorted(numbers) == list(range(1, count + 1)), 'owned loop partition inventory differs')
    return result


def node_identity(info):
    return {'filesystem_device': info.st_dev, 'inode': info.st_ino, 'rdev': info.st_rdev,
            'mode': stat.S_IMODE(info.st_mode)}


def ensure(records, created, *, dev_root=Path('/dev'), nodes=Nodes):
    for record in records:
        path = dev_root / Path(record['path']).name
        major, minor = map(int, record['major_minor'].split(':'))
        expected = os.makedev(major, minor)
        try:
            info = nodes.lstat(path)
        except FileNotFoundError:
            nodes.create(path, stat.S_IFBLK | 0o600, expected)
            info = nodes.lstat(path)
            created.append({'path': record['path'], **node_identity(info)})
        admit.require(stat.S_ISBLK(info.st_mode) and info.st_rdev == expected, 'existing partition node is linked, non-block or has wrong major/minor')
        if any(item['path'] == record['path'] for item in created):
            admit.require(stat.S_IMODE(info.st_mode) == 0o600, 'created node mode differs')


def remove_created(created, *, dev_root=Path('/dev'), nodes=Nodes):
    for item in reversed(created):
        admit.require(re.fullmatch(r'/dev/loop[0-9]+p[1-9][0-9]*', item['path']), 'unsafe created-node cleanup path')
        path = dev_root / Path(item['path']).name
        try:
            info = nodes.lstat(path)
        except FileNotFoundError:
            continue
        admit.require(stat.S_ISBLK(info.st_mode) and node_identity(info) == {key: item[key] for key in node_identity(info)},
                      'created partition node identity changed; refuse unlink')
        nodes.unlink(path)


def create(device, backing, count, receipt):
    visibility = private_dev()
    records = discovered(device, backing, count)
    data = {'schema': 1, 'kind': 'private-container-loop-nodes', 'device': device, 'backing': backing,
            'partition_count': count, 'private_dev': visibility, 'created': [], 'result': 'failed'}
    # Exclusive receipt is opened before any mknod, and records partial setup on failure.
    with receipt.open('x') as output:
        try:
            ensure(records, data['created'])
            admit.require(discovered(device, backing, count) == records, 'loop children changed during node creation')
            data['result'] = 'passed'
        finally:
            json.dump(data, output, indent=2, sort_keys=True)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
    return data


def cleanup(receipt):
    visibility = private_dev()
    data = admit.strict_json(receipt.read_bytes())
    admit.require(data['schema'] == 1 and data['kind'] == 'private-container-loop-nodes' and data['private_dev'] == visibility,
                  'node receipt belongs to a different container /dev')
    admit.require(re.fullmatch(r'/dev/loop[0-9]+', data['device']), 'unsafe receipt loop path')
    admit.require(all(re.fullmatch(re.escape(data['device']) + r'p[1-9][0-9]*', item['path']) for item in data['created']),
                  'created node belongs to a different loop')
    loop_guard.wait_released(data['device'], data['backing'])
    remove_created(data['created'])
    return {'device': data['device'], 'backing': data['backing'], 'created_nodes_removed': len(data['created'])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('create', 'cleanup'))
    parser.add_argument('--device')
    parser.add_argument('--backing')
    parser.add_argument('--partition-count', type=int, default=0)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    result = create(args.device, args.backing, args.partition_count, args.receipt) if args.action == 'create' else cleanup(args.receipt)
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
