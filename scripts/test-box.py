#!/usr/bin/env python3
"""
Smoke-test a Vagrant box: import → boot → read /etc/box-release → destroy.
All output goes to stdout AND logs/test-<boxname>.log.

Env:
  BOX_FILE    — absolute path to .box file  (required)
  BUILDS_DIR  — project builds directory     (required)
  LOGS_DIR    — project logs directory       (required)
  PACKER_IMAGE      — docker image with vagrant    (required)
  LIBVIRT_GID       — host libvirt group id        (required)
  TEST_MEM          — VM RAM in MB                 (default: 2048)
  TEST_CPUS         — VM CPU count                 (default: 2)
  TEST_BOOT_TIMEOUT — vagrant boot_timeout seconds  (default: 600)
"""

import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from common import env

# ── Inputs ─────────────────────────────────────────────────────────────────────

box_file      = Path(env('BOX_FILE',         required=True))
logs_dir      = Path(env('LOGS_DIR',         required=True))
builds_dir    = Path(env('BUILDS_DIR',       required=True))
packer_image  = env('PACKER_IMAGE',          required=True)
libvirt_gid   = env('LIBVIRT_GID',           default='135')
test_mem      = int(env('TEST_MEM',          default='2048'))
test_cpus     = int(env('TEST_CPUS',         default='2'))
boot_timeout  = int(env('TEST_BOOT_TIMEOUT', default='600'))

if not box_file.exists():
    print(f"ERROR: box not found: {box_file}", file=sys.stderr)
    sys.exit(1)

box_name  = box_file.stem.replace('.libvirt', '')   # trim .libvirt if present
vm_name   = f"smoke-{box_name}"
vm_dir    = Path(f"/tmp/vagrant-{vm_name}")
log_file  = logs_dir / f"test-{box_name}.log"
logs_dir.mkdir(parents=True, exist_ok=True)

# ── Logging ────────────────────────────────────────────────────────────────────

_log_fh = open(log_file, 'w')

def log(msg: str = ''):
    ts    = datetime.now().strftime('%H:%M:%S')
    line  = f"[{ts}] {msg}"
    print(line)
    _log_fh.write(line + '\n')
    _log_fh.flush()


def stage(label: str):
    log()
    log(f"STAGE  {label}")


def run(cmd: list[str], **kwargs) -> int:
    """Run command, streaming output to both terminal and log file."""
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        **kwargs,
    )
    for line in proc.stdout:
        line = line.rstrip('\n')
        print(line)
        _log_fh.write(line + '\n')
        _log_fh.flush()
    proc.wait()
    return proc.returncode


def run_or_die(cmd: list[str], label: str = '', **kwargs):
    rc = run(cmd, **kwargs)
    if rc != 0:
        log(f"ERROR: '{label or ' '.join(cmd[:3])}' exit {rc}")
        _log_fh.close()
        sys.exit(rc)


# docker run base args (mirrors $(VAGRANT_RUN) in Makefile)
DOCKER_OPTS = [
    'docker', 'run', '-t', '--rm', '--privileged', '--network', 'host',
    '-u', '0',
    '--device', '/dev/kvm',
    '--group-add', libvirt_gid,
    '-v', '/var/lib/libvirt:/var/lib/libvirt:rw',
    '-v', '/var/run/libvirt:/var/run/libvirt:rw',
    '-v', '/etc/localtime:/etc/localtime:ro',
    '-v', f'{builds_dir}:{builds_dir}:ro',
    '-v', f'{os.path.expanduser("~")}/.vagrant.d:/.vagrant.d',
    '-e', 'USER_UID=0',
    '-e', 'USER_GID=0',
    '-e', 'IGNORE_MISSING_LIBVIRT_SOCK=1',
    '-e', 'IGNORE_RUN_AS_ROOT=1',
]

def docker_run(*extra: str) -> list[str]:
    """Assemble docker-run command; extra flags go BEFORE the image name."""
    return DOCKER_OPTS + list(extra) + [packer_image]


# ── Main ───────────────────────────────────────────────────────────────────────

print(f"==> Test log: {log_file}")
log(f"START  box={box_file}")

# ── 1. Import box ──────────────────────────────────────────────────────────────
stage("vagrant box add")
run_or_die(
    docker_run() + ['vagrant', 'box', 'add', '--force',
                    '--name', vm_name, str(box_file), '--provider', 'libvirt'],
    label='vagrant box add',
)

# ── 2. Boot VM ─────────────────────────────────────────────────────────────────
stage("vagrant up")
if vm_dir.exists():
    # Files inside may be owned by root (created in container) — remove via docker
    subprocess.run(
        ['docker', 'run', '--rm', '-u', '0',
         '-v', f'{vm_dir.parent}:{vm_dir.parent}',
         'busybox', 'rm', '-rf', str(vm_dir)],
        check=True,
    )
vm_dir.mkdir(parents=True, mode=0o777)

vagrantfile_content = (
    f'Vagrant.configure("2") do |config|\n'
    f'  config.vm.box          = "{vm_name}"\n'
    f'  config.vm.boot_timeout = {boot_timeout}\n'
    f'  config.vm.synced_folder ".", "/vagrant", disabled: true\n'
    f'  config.vm.provider(:libvirt) {{ |v| v.memory = {test_mem}; v.cpus = {test_cpus} }}\n'
    f'end\n'
)
(vm_dir / 'Vagrantfile').write_text(vagrantfile_content)
(vm_dir / 'Vagrantfile').chmod(0o666)

run_or_die(
    docker_run('-v', f'{vm_dir}:{vm_dir}', '-w', str(vm_dir))
    + ['vagrant', 'up', '--provider', 'libvirt'],
    label='vagrant up',
)

# ── 3. Read metadata from VM ───────────────────────────────────────────────────
stage("read /etc/box-release")
run_or_die(
    docker_run('-v', f'{vm_dir}:{vm_dir}', '-w', str(vm_dir))
    + ['vagrant', 'ssh', '--', '-t',
       'cat /etc/box-release 2>/dev/null || echo "(no /etc/box-release)"'],
    label='vagrant ssh',
)

# ── 4. Destroy ─────────────────────────────────────────────────────────────────
stage("vagrant destroy")
run(
    docker_run('-v', f'{vm_dir}:{vm_dir}', '-w', str(vm_dir))
    + ['vagrant', 'destroy', '-f'],
)
run(
    docker_run() + ['vagrant', 'box', 'remove', vm_name, '--provider', 'libvirt'],
)

log()
log("DONE")
_log_fh.close()
print(f"==> Smoke-test PASSED: {box_file}")
