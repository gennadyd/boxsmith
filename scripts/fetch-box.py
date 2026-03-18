#!/usr/bin/env python3
"""
Resolve and download a remote box to a local cache file.
Prints the local path to stdout (other output goes to stderr).

Env:
  TYPE     — vendor-base | org-base | org-golden  (required unless BOX= given)
  OS       — ubuntu | rhel                         (required unless BOX= given)
  VERSION  — 24.04 | 9.6                           (required unless BOX= given)
  BOX      — full filename, overrides TYPE/OS/VERSION lookup (optional)
  UEFI     — true | false                          (default: false)
  STORAGE  — artifactory | s3                      (required)
  +  storage credentials from env (AWS_* or ARTIFACTORY_*)

BOX= + STORAGE= behaviour:
  - If BOX exists locally (builds/ or builds/remote/):
      fetch remote SHA and compare.
      SHA match   → use local file (no download)
      SHA mismatch → ERROR: local differs from remote
  - If BOX not found locally → download to builds/remote/
"""

import hashlib
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

from common import (
    artifactory_config,
    artifactory_aql,
    aws_run,
    aws_check_output,
    env,
    parse_box_filename,
    s3_config,
)

# ── Inputs ─────────────────────────────────────────────────────────────────────

box_hint = env('BOX',     default='')          # explicit filename, skip resolution
storage  = env('STORAGE', required=True)
env_name = env('ENV',     default='staging')
uefi     = env('UEFI',    default='false').lower() == 'true'
boot_mode = 'uefi' if uefi else 'legacy'

# TYPE/OS/VERSION required only when BOX= not given
if box_hint:
    _meta = parse_box_filename(box_hint)
    if not _meta:
        print(f"ERROR: cannot parse TYPE/OS/VERSION from BOX='{box_hint}'", file=sys.stderr)
        sys.exit(1)
    box_type  = _meta.box_type
    os_name   = _meta.os
    version   = _meta.version
    env_name  = _meta.env
    boot_mode = _meta.boot
else:
    box_type = env('TYPE',    required=True)
    os_name  = env('OS',      required=True)
    version  = env('VERSION', required=True)

BUILDS_DIR = Path(env('BUILDS_DIR', default=str(Path(__file__).parent.parent / 'builds')))
CACHE_DIR  = BUILDS_DIR / 'remote'


# ── SHA helpers ────────────────────────────────────────────────────────────────

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _remote_name(boxname: str) -> str:
    """Convert local .box name to remote .libvirt.box name."""
    if boxname.endswith('.libvirt.box'):
        return boxname
    return boxname[:-4] + '.libvirt.box'  # strip .box, add .libvirt.box


def remote_sha_s3(boxname: str) -> str:
    """Get sha256 from S3 object metadata."""
    s3  = s3_config(required=True)
    key = s3.box_key(box_type, os_name, _remote_name(boxname))
    try:
        out = aws_check_output(['s3api', 'head-object', '--bucket', s3.bucket, '--key', key], s3)
        head = json.loads(out)
        return head.get('Metadata', {}).get('sha256', '')
    except Exception as e:
        print(f"WARNING: could not fetch S3 metadata: {e}", file=sys.stderr)
        return ''


def remote_sha_artifactory(boxname: str) -> str:
    """Get sha256 from Artifactory box_description property."""
    cfg = artifactory_config(required=True)
    rname = _remote_name(boxname)
    results = artifactory_aql(cfg, cfg.aql_find(rname))
    for r in results:
        for p in r.get('properties', []):
            if p['key'] == 'box_description':
                return p['value'].replace('sha:', '')
    return ''


# ── Box resolution ─────────────────────────────────────────────────────────────

def resolve_boxname() -> str:
    """Find the latest matching box name via show-remote-boxes.py."""
    scripts_dir = Path(__file__).parent
    try:
        raw = subprocess.check_output(
            [sys.executable, str(scripts_dir / 'show-boxes.py')],
            env={**__import__('os').environ, 'SOURCE': 'remote', 'STORAGE': storage, 'FORMAT': 'json'},
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError as e:
        print(f"ERROR: show-remote-boxes failed: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        print("ERROR: show-remote-boxes returned invalid JSON", file=sys.stderr)
        sys.exit(1)

    matches = [
        b for b in data
        if b.get('type')    == box_type
        and b.get('os')      == os_name
        and b.get('version') == version
        and b.get('env',     'staging') == env_name
        and b.get('boot')    == boot_mode
    ]
    if not matches:
        print(
            f"ERROR: no remote box found for TYPE={box_type} OS={os_name} "
            f"VERSION={version} UEFI={str(uefi).lower()}",
            file=sys.stderr,
        )
        sys.exit(1)

    latest = sorted(matches, key=lambda b: b.get('timestamp', ''))[-1]
    return latest['name']


# ── Download ───────────────────────────────────────────────────────────────────

def download_s3(boxname: str, dest: Path):
    s3  = s3_config(required=True)
    key = s3.box_key(box_type, os_name, _remote_name(boxname))
    uri = s3.s3_uri(key)

    print(f"==> [fetch-box] s3 cp {uri} -> {dest}", file=sys.stderr)
    result = aws_run(['s3', 'cp', uri, str(dest), '--no-progress'], s3)
    if result.returncode != 0:
        print("ERROR: [S3] download failed", file=sys.stderr)
        sys.exit(result.returncode)


def download_artifactory(boxname: str, dest: Path):
    cfg = artifactory_config(required=True)
    url = cfg.file_url(f"{box_type}/{os_name}/{_remote_name(boxname)}")

    print(f"==> [fetch-box] curl {url} -> {dest}", file=sys.stderr)
    req = urllib.request.Request(url, headers=cfg.auth_headers)
    try:
        with urllib.request.urlopen(req) as resp, dest.open('wb') as f:
            total = int(resp.headers.get('Content-Length', 0))
            downloaded = 0
            chunk = 1024 * 1024  # 1 MB
            while True:
                data = resp.read(chunk)
                if not data:
                    break
                f.write(data)
                downloaded += len(data)
                if total:
                    pct = downloaded * 100 // total
                    print(f"\r    {pct}% {downloaded//(1024*1024)}MB / {total//(1024*1024)}MB",
                          end='', file=sys.stderr, flush=True)
        print('', file=sys.stderr)
    except urllib.error.URLError as e:
        print(f"ERROR: Artifactory download failed: {e}", file=sys.stderr)
        dest.unlink(missing_ok=True)
        sys.exit(1)


# ── main ───────────────────────────────────────────────────────────────────────

boxname = box_hint if box_hint else resolve_boxname()
CACHE_DIR.mkdir(parents=True, exist_ok=True)

def _fetch_remote_sha(bname: str) -> str:
    if storage == 's3':
        return remote_sha_s3(bname)
    elif storage == 'artifactory':
        return remote_sha_artifactory(bname)
    return ''

def _download(bname: str, dest: Path):
    print(f"==> [fetch-box] Downloading {bname} from {storage}...", file=sys.stderr)
    if storage == 's3':
        download_s3(bname, dest)
    elif storage == 'artifactory':
        download_artifactory(bname, dest)
    else:
        print(f"ERROR: unknown STORAGE='{storage}' (use: artifactory|s3)", file=sys.stderr)
        sys.exit(1)
    print(f"==> [fetch-box] Saved to {dest}", file=sys.stderr)


# When BOX= is explicitly given, search for a local copy and verify SHA.
if box_hint:
    local_candidates = [BUILDS_DIR / boxname, CACHE_DIR / boxname]
    found_local: Path | None = next((p for p in local_candidates if p.exists()), None)

    if found_local:
        print(f"==> [fetch-box] Found local copy: {found_local}", file=sys.stderr)
        print(f"==> [fetch-box] Fetching remote SHA to verify...", file=sys.stderr)
        rsha = _fetch_remote_sha(boxname)
        if rsha:
            lsha = sha256_file(found_local)
            if lsha == rsha:
                print(f"==> [fetch-box] SHA OK — using local copy", file=sys.stderr)
                print(found_local)
                sys.exit(0)
            else:
                print(f"ERROR: local file differs from remote!", file=sys.stderr)
                print(f"  local  SHA256: {lsha}", file=sys.stderr)
                print(f"  remote SHA256: {rsha}", file=sys.stderr)
                print(f"  path: {found_local}", file=sys.stderr)
                sys.exit(1)
        else:
            print(f"WARNING: remote SHA unavailable — using local copy without verification", file=sys.stderr)
            print(found_local)
            sys.exit(0)
    # No local copy found — fall through to download below.
else:
    # No BOX= hint: check the cache dir only (original behaviour).
    dest = CACHE_DIR / boxname
    if dest.exists():
        print(f"==> [fetch-box] Using cached: {dest}", file=sys.stderr)
        print(dest)
        sys.exit(0)

dest = CACHE_DIR / boxname
_download(boxname, dest)
print(dest)
