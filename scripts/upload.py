#!/usr/bin/env python3
"""
Upload a box to Artifactory, S3, or both.

Env:
  BOX_FILE    — path to the .box file  (required)
  STORAGE     — artifactory | s3  (required)
  OS, VERSION, TYPE, UEFI  — auto-parsed from filename when not set

  Artifactory: ARTIFACTORY_URL, ARTIFACTORY_VAGRANT_REPO, JFROG_CLI_VER
  S3:          S3_BUCKET, S3_PREFIX (default: vagrant),
               AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION,
               S3_ENDPOINT (optional)
"""

import hashlib
import subprocess
import sys
from pathlib import Path

from common import (
    artifactory_config,
    aws_run,
    box_remote_filename,
    env,
    parse_box_filename,
    s3_config,
)

# ── Inputs ─────────────────────────────────────────────────────────────────────

box_path = Path(env('BOX_FILE', required=True))
if not box_path.exists():
    print(f"ERROR: {box_path} not found", file=sys.stderr)
    sys.exit(1)

storage = env('STORAGE', required=True)

# Parse metadata from filename — filename is always the authoritative source.
# Makefile defaults (OS=ubuntu, TYPE=org-golden) must not override a parseable name.
_meta = parse_box_filename(box_path.name)
if _meta:
    os_name  = _meta.os
    version  = _meta.version
    env_name = _meta.env
    box_type = _meta.box_type
    uefi     = _meta.boot == 'uefi'
    ts       = _meta.timestamp
else:
    # Fallback: require explicit env vars
    os_name  = env('OS',      required=True)
    version  = env('VERSION', required=True)
    env_name = env('ENV',     default='staging')
    box_type = env('TYPE',    required=True)
    uefi     = env('UEFI',    default='false').lower() == 'true'
    import datetime
    ts       = datetime.datetime.now().strftime('%Y%m%d.%H%M')

# BASED_ON: provenance chain (set by Makefile from FROM= or previous box name)
based_on = env('BASED_ON', default='')

uefi_suffix  = '-uefi' if uefi else ''
os_ver_label = f"{os_name}-{version}-{env_name}{uefi_suffix}"

# SHA-256
sha = hashlib.sha256(box_path.read_bytes()).hexdigest()

box_name    = box_path.name
remote_name = box_remote_filename(os_name, version, env_name, box_type, ts, uefi)

print(f"==> Upload: {box_path}")
print(f"    Remote  : {remote_name}")
print(f"    Storage : {storage}")
print(f"    SHA-256 : {sha}")



# ── Sidecar .meta.json ────────────────────────────────────────────────────────────────────────

def _update_meta_sidecar(box_path: Path, uploaded_ref: str) -> None:
    import json as _json
    meta_path = box_path.with_suffix('.meta.json')
    if meta_path.exists():
        data = _json.loads(meta_path.read_text())
    else:
        data = {
            'name':        box_path.name,
            'env':         env_name,
            'type':        box_type,
            'os':          os_name,
            'version':     version,
            'timestamp':   ts,
            'based-on':    based_on,
            'uploaded-to': [],
        }
    if uploaded_ref not in data.get('uploaded-to', []):
        data.setdefault('uploaded-to', []).append(uploaded_ref)
    meta_path.write_text(_json.dumps(data, indent=2))
    print(f"==> Meta: {meta_path}")

# ── Artifactory ────────────────────────────────────────────────────────────────

def upload_artifactory():
    cfg   = artifactory_config(required=True)
    dest  = f"{cfg.repo}/{box_type}/{os_name}/{remote_name}"
    _props = {
        'box_name':        f"{os_ver_label}-{box_type}",
        'box_provider':    'libvirt',
        'box_version':     ts,
        'box_os':          os_name,
        'box_os_version':  version,
        'box_env':         env_name,
        'box_type':        box_type,
        'box_uefi':        str(uefi).lower(),
        'box_based_on':    based_on or 'not provided',
        'box_description': f'sha:{sha}',
    }
    props = ';'.join(f"{k}={v}" for k, v in _props.items())
    jfrog = env('JFROG_CLI_VER', default='jfrog')

    print(f"==> [Artifactory] -> {cfg.url}/{dest}")
    result = subprocess.run(
        [jfrog, 'rt', 'u',
         f'--url={cfg.url}',
         f'--access-token={cfg.token}',
         '--props', props,
         str(box_path), dest]
    )
    if result.returncode != 0:
        print("ERROR: [Artifactory] upload failed", file=sys.stderr)
        sys.exit(result.returncode)
    print("==> [Artifactory] Upload OK")
    _update_meta_sidecar(box_path, f"artifactory:{cfg.repo}/{box_type}/{os_name}/{remote_name}")


# ── S3 ─────────────────────────────────────────────────────────────────────────

def upload_s3():
    s3  = s3_config(required=True)
    key = s3.box_key(box_type, os_name, remote_name)
    uri = s3.s3_uri(key)

    _meta = {
        'box_os':          os_name,
        'box_os_version':  version,
        'box_env':         env_name,
        'box_type':        box_type,
        'box_version':     ts,
        'box_uefi':        str(uefi).lower(),
        'box_provider':    'libvirt',
        'box_based_on':    based_on or 'not provided',
        'sha256':          sha,
    }
    metadata = ','.join(f"{k}={v}" for k, v in _meta.items())

    print(f"==> [S3] -> {uri}")
    result = aws_run(
        ['s3', 'cp', str(box_path), uri,
         '--metadata', metadata,
         '--no-progress'],
        s3
    )
    if result.returncode != 0:
        print("ERROR: [S3] upload failed", file=sys.stderr)
        sys.exit(result.returncode)
    print("==> [S3] Upload OK")
    _update_meta_sidecar(box_path, f"s3:{uri}")


# ── main ───────────────────────────────────────────────────────────────────────

if storage == 'artifactory':
    upload_artifactory()
elif storage == 's3':
    upload_s3()
else:
    print(f"ERROR: unknown STORAGE='{storage}' (use: artifactory|s3)", file=sys.stderr)
    sys.exit(1)
