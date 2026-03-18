#!/usr/bin/env python3
"""
Shared helpers for upload.py, fetch-box.py, show-remote-boxes.py.

Provides:
  - Env-var access with required/default semantics
  - S3 connection args (endpoint, bucket, prefix)
  - Artifactory connection config (url, auth headers, repo)
  - Box filename parsing / key construction
  - aws CLI subprocess wrappers
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Optional


# ── Env helpers ────────────────────────────────────────────────────────────────

def env(key: str, default: Optional[str] = None, required: bool = False) -> str:
    val = os.environ.get(key, default or '')
    if required and not val:
        print(f"ERROR: {key} is not set", file=sys.stderr)
        sys.exit(1)
    return val


# ── S3 ─────────────────────────────────────────────────────────────────────────

@dataclass
class S3Config:
    bucket:   str
    prefix:   str           # e.g. "gennadyd/vagrant"
    endpoint: str = ''      # e.g. "https://nyc3.digitaloceanspaces.com"
    region:   str = 'us-east-1'

    # Returns extra args list for `aws` CLI commands, e.g. ['--endpoint-url', '...']
    @property
    def endpoint_args(self) -> list[str]:
        return ['--endpoint-url', self.endpoint] if self.endpoint else []

    # Public URL for a given S3 key
    def public_url(self, key: str) -> str:
        if self.endpoint:
            return f"{self.endpoint.rstrip('/')}/{self.bucket}/{key}"
        return f"https://{self.bucket}.s3.{self.region}.amazonaws.com/{key}"

    # s3://bucket/key
    def s3_uri(self, key: str) -> str:
        return f"s3://{self.bucket}/{key}"

    # Full S3 key: prefix/type/os/filename
    def box_key(self, box_type: str, box_os: str, filename: str) -> str:
        return f"{self.prefix.rstrip('/')}/{box_type}/{box_os}/{filename}"


def s3_config(required: bool = True) -> S3Config:
    """Build S3Config from environment variables."""
    bucket = env('S3_BUCKET', required=required)
    prefix = env('S3_PREFIX', default='vagrant')
    endpoint = env('S3_ENDPOINT', default='')
    region = env('AWS_DEFAULT_REGION', default='us-east-1')
    return S3Config(bucket=bucket, prefix=prefix, endpoint=endpoint, region=region)


def aws_run(args: list[str], s3: S3Config, **kwargs) -> subprocess.CompletedProcess:
    """Run an `aws` command, injecting endpoint args automatically."""
    cmd = ['aws'] + args + s3.endpoint_args
    return subprocess.run(cmd, **kwargs)


def aws_check_output(args: list[str], s3: S3Config) -> str:
    """Run `aws` and return stdout as string. Raises CalledProcessError on failure."""
    cmd = ['aws'] + args + s3.endpoint_args
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)


# ── Artifactory ────────────────────────────────────────────────────────────────

@dataclass
class ArtifactoryConfig:
    url:    str
    repo:   str
    token:  str = ''
    apikey: str = ''

    @property
    def auth_headers(self) -> dict[str, str]:
        # Prefer access token (Bearer) over legacy API key
        if self.token:
            return {'Authorization': f'Bearer {self.token}'}
        if self.apikey:
            return {'Authorization': f'Bearer {self.apikey}'}
        return {}

    @property
    def repo_name(self) -> str:
        """Repository name only (first path component of self.repo)."""
        return self.repo.split('/')[0]

    @property
    def path_prefix(self) -> str:
        """Path within the repo (everything after the first '/')."""
        parts = self.repo.split('/', 1)
        return parts[1] if len(parts) > 1 else ''

    def aql_url(self) -> str:
        return f"{self.url}/api/search/aql"

    def file_url(self, path_in_repo: str) -> str:
        """Full download URL for a file inside the repo."""
        return f"{self.url}/{self.repo}/{path_in_repo}"

    def aql_find(self, name_filter: str) -> str:
        """AQL query scoped to this repo (and optional path_prefix).

        name_filter supports '*' wildcards (AQL $match).
        Works regardless of ARTIFACTORY_VAGRANT_REPO format:
          devops-generic-dev-local            → search whole repo
          devops-generic-dev-local/users/foo  → search only that sub-path
        """
        path_clause = (
            f',"path":{{"$match":"{self.path_prefix}/*"}}'
            if self.path_prefix else ''
        )
        return (
            f'items.find({{"repo":{{"$eq":"{self.repo_name}"}}{path_clause},'
            f'"name":{{"$match":"{name_filter}"}}}}).include("repo","path","name","size","property")'
        )


def artifactory_config(required: bool = True) -> ArtifactoryConfig:
    """Build ArtifactoryConfig from environment variables."""
    url = env('ARTIFACTORY_URL', required=required).rstrip('/')
    repo = env('ARTIFACTORY_VAGRANT_REPO', default='vagrant-hl-local')
    token = env('ARTIFACTORY_TOKEN') or env('ARTIFACTORY_ACCESS_TOKEN')
    apikey = env('ARTIFACTORY_API_KEY')
    return ArtifactoryConfig(url=url, repo=repo, token=token, apikey=apikey)


def artifactory_aql(cfg: ArtifactoryConfig, aql: str) -> list[dict]:
    """Execute an AQL query and return the results list."""
    req = urllib.request.Request(
        cfg.aql_url(),
        data=aql.encode(),
        headers={'Content-Type': 'text/plain', **cfg.auth_headers}
    )
    try:
        with urllib.request.urlopen(req) as r:
            data = json.loads(r.read().decode())
    except urllib.error.URLError as e:
        print(f"ERROR: Artifactory AQL failed: {e}", file=sys.stderr)
        return []
    except json.JSONDecodeError as e:
        print(f"ERROR: Artifactory returned invalid JSON: {e}", file=sys.stderr)
        return []
    return data.get('results', [])


# ── Box filename helpers ────────────────────────────────────────────────────────

# Pattern: ubuntu-24.04-staging[-uefi]-org-golden-20260316.1324[.libvirt].box
BOX_NAME_RE = re.compile(
    r'^(?P<os>[a-z]+)-(?P<ver>[\d.]+)-(?P<env>[a-z][a-z0-9]*)(?P<uefi>-uefi)?-(?P<type>[a-z-]+)-(?P<ts>\d{8}\.\d{4})(\.libvirt)?\.box$'
)

# Only these types are produced by this project; anything else is junk / old naming
VALID_BOX_TYPES: frozenset[str] = frozenset({'vendor-base', 'org-base', 'org-golden'})


@dataclass
class BoxMeta:
    name:      str
    os:        str
    version:   str
    box_type:  str       # vendor-base | org-base | org-golden
    timestamp: str       # YYYYMMDD.HHMM
    boot:      str       # legacy | uefi
    env:       str = 'staging'  # staging | production | testing
    source:    str = ''  # artifactory | s3
    path:      str = ''  # download URL or local path
    size_bytes: int = 0
    sha256:    str = ''

    # Human-readable label, e.g. "ubuntu-24.04 (uefi)"
    @property
    def label(self) -> str:
        suffix = ' (uefi)' if self.boot == 'uefi' else ''
        return f"{self.os}-{self.version}{suffix}"

    def to_dict(self) -> dict:
        return {
            'source':     self.source,
            'name':       self.name,
            'path':       self.path,
            'size_bytes': self.size_bytes,
            'os':         self.os,
            'version':    self.version,
            'env':        self.env,
            'type':       self.box_type,
            'timestamp':  self.timestamp,
            'boot':       self.boot,
            'sha256':     self.sha256,
        }


def parse_box_filename(name: str) -> Optional['BoxMeta']:
    """Parse a .box filename into BoxMeta. Returns None if not matched."""
    m = BOX_NAME_RE.match(name)
    if not m:
        return None
    if m.group('type') not in VALID_BOX_TYPES:
        return None
    return BoxMeta(
        name=name,
        os=m.group('os'),
        version=m.group('ver'),
        env=m.group('env'),
        box_type=m.group('type'),
        timestamp=m.group('ts'),
        boot='uefi' if m.group('uefi') else 'legacy',
    )


def box_remote_filename(os: str, version: str, env_name: str, box_type: str,
                         timestamp: str, uefi: bool = False) -> str:
    """Canonical remote filename: ubuntu-24.04-staging[-uefi]-vendor-base-TS.libvirt.box"""
    uefi_part = '-uefi' if uefi else ''
    return f"{os}-{version}-{env_name}{uefi_part}-{box_type}-{timestamp}.libvirt.box"
