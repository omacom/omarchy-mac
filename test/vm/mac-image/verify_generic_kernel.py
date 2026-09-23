"""Verify the admitted generic kernel using a short, disposable public-key home."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import admit


def verify(keyring, archive, signature, evidence):
    home = None
    record = {'kind': 'private-vm-generic-kernel-keyring-lifecycle', 'result': 'failed'}
    try:
        with tempfile.TemporaryDirectory(prefix='omarchy-vm-gpg-', dir='/tmp') as temporary:
            home = Path(temporary)
            home.chmod(0o700)
            socket_bytes = len(str(home / 'S.gpg-agent.browser').encode())
            admit.require(socket_bytes < 108, 'GPG socket path exceeds the Linux limit')
            record.update(home=str(home), maximum_socket_path_bytes=socket_bytes, mode='0700')
            try:
                with (evidence / 'kernel-keyring.log').open('x') as log:
                    subprocess.run(['gpg', '--batch', '--homedir', str(home), '--import', str(keyring)],
                                   stdout=log, stderr=subprocess.STDOUT, check=True)
                with (evidence / 'kernel-signature.log').open('x') as log:
                    subprocess.run(['gpg', '--batch', '--no-auto-key-retrieve', '--homedir', str(home),
                                    '--status-fd', '1', '--verify', str(signature), str(archive)],
                                   stdout=log, stderr=subprocess.STDOUT, check=True)
                record['signature_verified'] = True
            finally:
                with (evidence / 'kernel-keyring-cleanup.log').open('x') as log:
                    subprocess.run(['gpgconf', '--homedir', str(home), '--kill', 'gpg-agent'],
                                   stdout=log, stderr=subprocess.STDOUT, check=True)
                record['owned_agent_stopped'] = True
        record['result'] = 'passed'
    finally:
        record['owned_home_removed'] = home is not None and not home.exists()
        with (evidence / 'kernel-keyring-home.json').open('x') as log:
            json.dump(record, log, indent=2, sort_keys=True)
            log.write('\n')
    admit.require(record['owned_home_removed'], 'temporary GPG home was retained')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('keyring', 'archive', 'signature', 'evidence'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    verify(args.keyring, args.archive, args.signature, args.evidence)


if __name__ == '__main__':
    main()
