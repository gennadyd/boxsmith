#!/usr/bin/env python3
"""
Scaffold templates for a new OS/version, copying from an existing family template.

Usage (via make):
  make add-new-os  OS=rhel   VERSION=9.8  FROM=rhel-9.6
  make add-new-os  OS=ubuntu VERSION=26.04 FROM=ubuntu-24.04
  make remove-os   OS=rhel   VERSION=9.8

Env vars:
  OS          -- new OS name (e.g. rhel, ubuntu, almalinux)
  VERSION     -- new version (e.g. 9.8, 26.04)
  FROM        -- existing template to copy from: <os>-<version>  (e.g. rhel-9.6)
  ANSIBLE_NAME -- override ansible vars prefix (default: same as OS)
                  e.g. ANSIBLE_NAME=redhat when OS=rhel
  DRY_RUN     -- if set, just print what would be done, don't write
"""

import os
import sys
import shutil
import json
from pathlib import Path

from common import env

TEMPLATES = Path(__file__).parent.parent / "templates"
ANSIBLE_ROLES = TEMPLATES / "ansible/roles/company.example"

def main():
    os_name    = env("OS",      required=True)
    version    = env("VERSION", required=True)
    from_spec  = env("FROM",    required=True)
    ansible_name = env("ANSIBLE_NAME", default=os_name)
    dry_run    = bool(env("DRY_RUN"))

    new_slug = f"{os_name}-{version}"  # e.g. rhel-9.8

    if "-" not in from_spec:
        print(f"ERROR: FROM must be <os>-<version>, got: {from_spec}", file=sys.stderr)
        sys.exit(1)
    from_os, from_version = from_spec.split("-", 1)  # e.g. rhel, 9.6
    from_slug = from_spec  # e.g. rhel-9.6

    print(f"==> add-new-os: scaffolding {new_slug}  (from {from_slug})")

    created = []
    skipped = []

    def write(path: Path, content: str):
        if dry_run:
            print(f"  [dry-run] would write: {path.relative_to(TEMPLATES.parent)}")
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        created.append(str(path.relative_to(TEMPLATES.parent)))
        print(f"  created: {path.relative_to(TEMPLATES.parent)}")

    def copy_dir(src: Path, dst: Path, old_slug: str, new_slug: str):
        """Copy a directory tree, replacing old_slug with new_slug in text file contents."""
        SKIP_DIRS  = {".vagrant", "output-box-legacy", "output-box-uefi",
                      "output-iso-legacy", "output-iso-uefi", "__pycache__"}
        SKIP_FILES = {"efivars.fd"}
        for item in sorted(src.rglob("*")):
            if any(p in SKIP_DIRS for p in item.parts):
                continue
            if item.name in SKIP_FILES:
                continue
            rel = item.relative_to(src)
            target = dst / rel
            if item.is_dir():
                continue
            if dry_run:
                print(f"  [dry-run] would copy: {target.relative_to(TEMPLATES.parent)}")
                continue
            if target.exists():
                skipped.append(str(target.relative_to(TEMPLATES.parent)))
                print(f"  skip (exists): {target.relative_to(TEMPLATES.parent)}")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            # Try text substitution; fall back to binary copy
            try:
                text = item.read_text(encoding="utf-8")
                text = text.replace(old_slug, new_slug) \
                            .replace(from_os,  os_name) \
                            .replace(from_version, version)
                target.write_text(text, encoding="utf-8")
            except (UnicodeDecodeError, ValueError):
                shutil.copy2(item, target)
            created.append(str(target.relative_to(TEMPLATES.parent)))
            print(f"  created: {target.relative_to(TEMPLATES.parent)}")

    # ── 1. vendor-base ──────────────────────────────────────────────────────
    src_vendor = TEMPLATES / "vendor-base" / from_slug
    dst_vendor = TEMPLATES / "vendor-base" / new_slug
    if not src_vendor.exists():
        print(f"ERROR: source vendor-base template not found: {src_vendor}", file=sys.stderr)
        sys.exit(1)
    if dst_vendor.exists():
        print(f"  NOTE: vendor-base/{new_slug}/ already exists — skipping (use remove-os first)")
        skipped.append(f"templates/vendor-base/{new_slug}/")
    else:
        copy_dir(src_vendor, dst_vendor, from_slug, new_slug)

    # ── 2. org-base / org-golden var-files ──────────────────────────────────
    # Determine box_os: use FROM's box_os value as base
    from_org_base = TEMPLATES / "org-base" / f"{from_slug}.json"
    if from_org_base.exists():
        box_os = json.loads(from_org_base.read_text()).get("box_os", from_os)
    else:
        box_os = os_name

    for stage in ("org-base", "org-golden"):
        target = TEMPLATES / stage / f"{new_slug}.json"
        if target.exists():
            skipped.append(str(target.relative_to(TEMPLATES.parent)))
            print(f"  skip (exists): {target.relative_to(TEMPLATES.parent)}")
        else:
            write(target, json.dumps({"box_os": box_os}, indent=4) + "\n")

    # ── 3. ansible vars ──────────────────────────────────────────────────────
    # Copy ansible vars files from the FROM family, using ansible_name prefix
    from_ansible_name = env("FROM_ANSIBLE_NAME", default=from_os)
    ansible_var_dirs = sorted(ANSIBLE_ROLES.glob("*/vars"))
    for var_dir in ansible_var_dirs:
        # look for a source file matching from_ansible_name-from_version or from_slug
        src_candidates = [
            var_dir / f"{from_ansible_name}-{from_version}.yml",
            var_dir / f"{from_slug}.yml",
        ]
        src_file = next((f for f in src_candidates if f.exists()), None)
        if src_file is None:
            continue
        dst_file = var_dir / f"{ansible_name}-{version}.yml"
        if dst_file.exists():
            skipped.append(str(dst_file.relative_to(TEMPLATES.parent)))
            print(f"  skip (exists): {dst_file.relative_to(TEMPLATES.parent)}")
            continue
        if dry_run:
            print(f"  [dry-run] would copy ansible vars: {dst_file.relative_to(TEMPLATES.parent)}")
            continue
        text = src_file.read_text()
        # Replace version references (be conservative, only exact version strings)
        text = text.replace(from_version, version)
        dst_file.write_text(text)
        created.append(str(dst_file.relative_to(TEMPLATES.parent)))
        print(f"  created: {dst_file.relative_to(TEMPLATES.parent)}")

    # ── Summary ──────────────────────────────────────────────────────────────
    print()
    if dry_run:
        print("==> [dry-run] done — nothing written")
    else:
        print(f"==> Done: {len(created)} files created, {len(skipped)} skipped")
        print()
        print("Next steps:")
        print(f"  1. Review templates/vendor-base/{new_slug}/packer.json")
        print(f"     — adjust ISO urls, checksums, kickstart/cloud-init for new version")
        print(f"  2. Review ansible vars files and update kernel_name / packages")
        print(f"  3. make build TYPE=vendor-base OS={os_name} VERSION={version}")

if __name__ == "__main__":
    main()
