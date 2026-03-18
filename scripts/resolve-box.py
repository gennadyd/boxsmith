#!/usr/bin/env python3
"""
Resolve a box to an absolute local file path.  Prints the path to stdout.

Used by Makefile test: and ssh: targets to avoid duplicating resolution logic.

Env:
  SOURCE    local | remote          (default: local)
  BOX       explicit filename — normalised to builds/<name>.box
  TYPE      vendor-base | org-base | org-golden
  OS        ubuntu | rhel
  VERSION   24.04 | 9.6
  UEFI      true | false            (default: false)
  STORAGE   artifactory | s3        (required when SOURCE=remote)
  BUILDS_DIR                        (default: ../builds relative to this script)

Exit 0  — path printed to stdout
Exit 1  — error message printed to stderr, nothing on stdout
"""

import os
import subprocess
import sys
from pathlib import Path

BUILDS_DIR = Path(os.environ.get('BUILDS_DIR',
                  str(Path(__file__).parent.parent / 'builds')))

SOURCE  = os.environ.get('SOURCE', 'local')
BOX     = os.environ.get('BOX', '')
TYPE    = os.environ.get('TYPE', '')
OS_NAME = os.environ.get('OS', '')
VERSION = os.environ.get('VERSION', '')
ENV     = os.environ.get('ENV', 'staging')
UEFI    = os.environ.get('UEFI', 'false').lower() == 'true'

# ── remote: delegate entirely to fetch-box.py ─────────────────────────────────
if SOURCE == 'remote':
    result = subprocess.run(
        [sys.executable, str(Path(__file__).parent / 'fetch-box.py')],
    )
    sys.exit(result.returncode)

# ── explicit BOX name ─────────────────────────────────────────────────────────
if BOX:
    b = BOX
    if b.endswith('.libvirt.box'):
        b = b[:-len('.libvirt.box')] + '.box'
    elif not b.endswith('.box'):
        b += '.box'
    print(str(BUILDS_DIR / b))
    sys.exit(0)

# ── auto-detect latest matching box ──────────────────────────────────────────
uefi_suffix = '-uefi' if UEFI else ''

if OS_NAME and VERSION and TYPE:
    pattern = f'{OS_NAME}-{VERSION}-{ENV}{uefi_suffix}-{TYPE}-*.box'
else:
    pattern = '*.box'

matches = sorted(BUILDS_DIR.glob(pattern), key=lambda p: p.stat().st_mtime)
if not matches:
    print(f"ERROR: no box matching {BUILDS_DIR}/{pattern}", file=sys.stderr)
    sys.exit(1)

print(str(matches[-1]))
