#!/usr/bin/env python3
"""
Show boxes – local builds and/or remote (Artifactory / S3).

Both `show-local-boxes` and `show-remote-boxes` Makefile targets delegate here.

Env:
  SOURCE       local | remote | both  (default: remote)
  STORAGE      artifactory | s3  (required when SOURCE=remote)
  FORMAT       short | json            (default: short)
  FILTER_OS    ubuntu | rhel | ''    filter by OS family
  FILTER_ENV   staging | production | ''  filter by environment tag

  BUILDS_DIR   local builds directory  (default: builds/)

  Artifactory: ARTIFACTORY_URL, ARTIFACTORY_TOKEN/ARTIFACTORY_API_KEY,
               ARTIFACTORY_VAGRANT_REPO
  S3:          S3_BUCKET, S3_PREFIX, S3_ENDPOINT,
               AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
"""

import hashlib
import json
import sys
from collections import defaultdict
from pathlib import Path

from common import (
    artifactory_aql,
    artifactory_config,
    aws_check_output,
    env,
    parse_box_filename,
    s3_config,
    VALID_BOX_TYPES,
)

SOURCE     = env('SOURCE',     default='remote')
STORAGE    = env('STORAGE',    default='')
FMT        = env('FORMAT',     default='short')
FILTER_OS  = env('FILTER_OS',  default='')
FILTER_ENV = env('FILTER_ENV', default='')
BUILDS_DIR = Path(env('BUILDS_DIR', default=str(Path(__file__).parent.parent / 'builds')))

BOLD  = '\033[1m'; UL = '\033[4m'; GREEN = '\033[32m'; DIM = '\033[2m'; RST = '\033[0m'


# ── Latest marker ──────────────────────────────────────────────────────────────

def mark_latest(boxes: list[dict]) -> list[dict]:
    """Set latest=True on the highest-timestamp box per (type, os, version, boot) group."""
    groups: dict = defaultdict(list)
    for b in boxes:
        groups[(b['type'], b['os'], b['version'], b.get('env',''), b['boot'])].append(b)
    for group in groups.values():
        group.sort(key=lambda x: x['timestamp'])
        for b in group:
            b['latest'] = False
        group[-1]['latest'] = True
    return boxes


# ── Rendering ──────────────────────────────────────────────────────────────────

def print_tree(boxes: list[dict]) -> None:
    tree: dict = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for b in boxes:
        key_os = f"{b['os']}-{b['version']}"
        tree[b['type']][key_os][b['boot']].append(b)

    for typ in sorted(VALID_BOX_TYPES, key=lambda t: ['vendor-base','org-base','org-golden'].index(t)):
        if typ not in tree:
            continue
        print(f"\n{BOLD}{UL}{typ.upper()}{RST}")
        for os_ver in sorted(tree[typ]):
            print(f"  {BOLD}{os_ver}{RST}")
            for boot in ['legacy', 'uefi']:
                blist = sorted(tree[typ][os_ver].get(boot, []), key=lambda x: x['timestamp'])
                if blist:
                    print(f"    {boot}")
                    for b in blist:
                        name       = b.get('name') or Path(b.get('local_path', '')).name
                        size_tag   = f"  {b['size']}" if b.get('size') else ''
                        latest_tag = f"  {GREEN}(latest){RST}" if b.get('latest') else ''
                        src_tag    = f"  [{DIM}{b['source']}{RST}]" if SOURCE == 'both' else ''
                        print(f"      {name}{size_tag}{latest_tag}{src_tag}")
                else:
                    dim_msg = '(builds from ISO)' if typ == 'vendor-base' else '(not built)'
                    print(f"    {boot}: {DIM}{dim_msg}{RST}")
    print()


# ── Local ──────────────────────────────────────────────────────────────────────

def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _human_size(nbytes: int) -> str:
    for unit in ('B', 'K', 'M', 'G', 'T'):
        if nbytes < 1024:
            return f"{nbytes:.1f}{unit}" if unit != 'B' else f"{nbytes}B"
        nbytes //= 1024
    return f"{nbytes}P"


def fetch_local() -> list[dict]:
    art_url  = env('ARTIFACTORY_URL', default='').rstrip('/')
    art_repo = env('ARTIFACTORY_VAGRANT_REPO', default='vagrant-hl-local')

    boxes = []
    for path in sorted(BUILDS_DIR.glob('*.box')):
        meta = parse_box_filename(path.name)
        if not meta:
            continue
        if FILTER_OS and meta.os != FILTER_OS:
            continue
        if FILTER_ENV and meta.env != FILTER_ENV:
            continue

        size_bytes  = path.stat().st_size
        sha         = _sha256(path) if FMT == 'json' else ''
        remote_name = path.stem + '.libvirt.box'   # foo.box → foo.libvirt.box
        remote_path = (
            f"{art_url}/{art_repo}/{meta.box_type}/{meta.os}/{remote_name}"
            if art_url else ''
        )

        meta_file = path.with_suffix('.meta.json')
        file_meta: dict = {}
        if meta_file.exists():
            try:
                file_meta = json.loads(meta_file.read_text())
            except Exception:
                pass

        boxes.append({
            'source':      'local',
            'name':        path.name,
            'path':        remote_path,
            'size_bytes':  size_bytes,
            'os':          meta.os,
            'version':     meta.version,
            'env':         meta.env,
            'type':        meta.box_type,
            'timestamp':   meta.timestamp,
            'boot':        meta.boot,
            'sha256':      sha,
            'based-on':    file_meta.get('based-on', ''),
            'uploaded-to': file_meta.get('uploaded-to', []),
        })
    return boxes


# ── Remote: Artifactory ────────────────────────────────────────────────────────

def fetch_artifactory() -> list[dict]:
    cfg = artifactory_config(required=True)
    if not cfg.url:
        return []

    aql = cfg.aql_find('*.box')
    results = artifactory_aql(cfg, aql)

    def prop(props, key):
        return next((p['value'] for p in props if p['key'] == key), '')

    boxes = []
    for r in results:
        props  = r.get('properties', [])
        box_os  = prop(props, 'box_os')
        box_env = prop(props, 'box_env') or 'staging'
        if FILTER_OS  and box_os  != FILTER_OS:
            continue
        if FILTER_ENV and box_env != FILTER_ENV:
            continue
        boxes.append({
            'source':     'artifactory',
            'name':       r.get('name', ''),
            'path':       cfg.file_url(f"{r.get('path','')}/{r.get('name','')}"),
            'size_bytes': r.get('size', 0),
            'os':         box_os,
            'version':    prop(props, 'box_os_version'),
            'env':        box_env,
            'type':       prop(props, 'box_type'),
            'timestamp':  prop(props, 'box_version'),
            'boot':       'uefi' if prop(props, 'box_uefi') == 'true' else 'legacy',
            'sha256':     prop(props, 'box_description').replace('sha:', ''),
        })
    return boxes


# ── Remote: S3 ─────────────────────────────────────────────────────────────────

def fetch_s3() -> list[dict]:
    s3 = s3_config(required=True)
    if not s3.bucket:
        return []

    try:
        out = aws_check_output(
            ['s3', 'ls', f's3://{s3.bucket}/{s3.prefix}/', '--recursive'], s3
        )
    except Exception as e:
        print(f"ERROR: aws s3 ls failed: {e}", file=sys.stderr)
        return []

    boxes = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        key  = parts[3]
        name = key.split('/')[-1]
        if not name.endswith('.box'):
            continue

        meta = parse_box_filename(name)
        if not meta:
            continue
        if FILTER_OS  and meta.os  != FILTER_OS:
            continue
        if FILTER_ENV and meta.env != FILTER_ENV:
            continue

        sha = ''
        if FMT == 'json':
            try:
                head = json.loads(aws_check_output(
                    ['s3api', 'head-object', '--bucket', s3.bucket, '--key', key], s3
                ))
                sha = head.get('Metadata', {}).get('sha256', '')
            except Exception:
                pass

        meta.source     = 's3'
        meta.path       = s3.public_url(key)
        meta.size_bytes = int(parts[2])
        meta.sha256     = sha
        boxes.append(meta.to_dict())

    return boxes


# ── main ───────────────────────────────────────────────────────────────────────

boxes: list[dict] = []

if SOURCE in ('local', 'both'):
    boxes += fetch_local()
if SOURCE in ('remote', 'both'):
    if not STORAGE:
        print("ERROR: STORAGE is required for remote source (use: artifactory|s3)", file=sys.stderr)
        sys.exit(1)
    if STORAGE == 'artifactory':
        boxes += fetch_artifactory()
    elif STORAGE == 's3':
        boxes += fetch_s3()
    else:
        print(f"ERROR: unknown STORAGE='{STORAGE}' (use: artifactory|s3)", file=sys.stderr)
        sys.exit(1)

mark_latest(boxes)

if FMT == 'json':
    json_boxes = [{k: v for k, v in b.items() if k != 'latest'} for b in boxes]
    print(json.dumps(json_boxes, indent=2))
else:
    print_tree(boxes)
