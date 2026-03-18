# Boxsmith

Packer + QEMU/KVM + libvirt pipeline for crafting, testing, and distributing Vagrant boxes.  
Everything runs inside Docker — no local Packer, Vagrant, or QEMU required.

**Languages:** English | [Русский](README.ru.md) | [עברית](README.he.md)

---

## Pipeline

```
ISO / Vagrant Cloud / remote box
          │
          ▼
    vendor-base        ← OS installed, base packages, vagrant user
          │
          ▼
     org-base          ← company repos, drivers, internal tooling
          │
          ▼
    org-golden         ← final hardening, org policies, box-release metadata
          │
          ▼
   upload (Artifactory / S3)
```

**Included out of the box** (any OS/distro can be added via `make add-new-os`):

| OS | Versions | UEFI |
|----|----------|------|
| Ubuntu | 24.04 | ✓ |
| RHEL   | 9.6   | ✓ |

---

## Requirements

### 1. Docker

All Packer/Vagrant/QEMU tooling runs inside Docker. Install Docker Engine:

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

```bash
# RHEL/CentOS
sudo dnf install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### 2. libvirt + KVM

Required on the host to manage VM networks and storage pools:

```bash
# Ubuntu/Debian
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst
sudo systemctl enable --now libvirtd
```

```bash
# RHEL/CentOS
sudo dnf install -y qemu-kvm libvirt libvirt-client virt-install
sudo systemctl enable --now libvirtd
```

Verify KVM acceleration is available:

```bash
kvm-ok          # Ubuntu (cpu-checker package)
virt-host-validate
```

Verify `/dev/kvm` is accessible from Docker:

```bash
ls -l /dev/kvm          # must exist
docker run --rm --device /dev/kvm alpine ls /dev/kvm
```

### 3. User groups

Add your user to `libvirt` and `kvm` groups, then re-login:

```bash
sudo usermod -aG libvirt,kvm $USER
newgrp libvirt   # apply without re-login (current shell only)
```

### 4. Python 3.10+

Used by helper scripts (`make show-boxes`, `make add-new-os`, etc.):

```bash
# Ubuntu/Debian
sudo apt-get install -y python3 python3-pip

# RHEL/CentOS
sudo dnf install -y python3 python3-pip
```

Verify:

```bash
python3 --version   # must be >= 3.10
```

### 5. AWS CLI v2 _(optional — required for `STORAGE=s3`)_

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp/aws-install
sudo /tmp/aws-install/aws/install
aws --version
```

### 6. JFrog CLI _(optional — required for `STORAGE=artifactory`)_

```bash
curl -fsSL https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/[RELEASE]/jfrog-cli-linux-amd64/jf \
  -o /usr/local/bin/jf && chmod +x /usr/local/bin/jf
jf --version
```

### 7. OVMF _(required for UEFI builds)_

```bash
# Ubuntu/Debian
sudo apt-get install -y ovmf

# RHEL/CentOS
sudo dnf install -y edk2-ovmf
```

---

## Quick Start

```bash
cp config.example.env config.env
# edit config.env — set PACKER_IMAGE, ARTIFACTORY_*, S3_BUCKET, etc.

make docker-build   # build the packer-vagrant Docker image (once)

# Full pipeline for Ubuntu 24.04 (staging)
make build TYPE=vendor-base OS=ubuntu VERSION=24.04
make build TYPE=org-base    OS=ubuntu VERSION=24.04
make build TYPE=org-golden  OS=ubuntu VERSION=24.04

# Or run the full pipeline in one command
make build-chain OS=ubuntu VERSION=24.04

# Test and SSH into the result
make test TYPE=org-golden OS=ubuntu VERSION=24.04
make ssh  TYPE=org-golden OS=ubuntu VERSION=24.04
```

---

## Docker Image

The `PACKER_IMAGE` variable controls the image name. Set it in `config.env`
to include the full registry path so the same image name is used for building,
pushing, and running:

```bash
# config.env
PACKER_IMAGE=registry.example.com/devops/packer-vagrant:latest
```

**Build** the image (runs locally, tags with `PACKER_IMAGE`):

```bash
make docker-build

# custom tool versions
make docker-build PACKER_VER=1.11.1 QEMU_PLUGIN_VER=1.1.0 TIMEZONE=UTC
```

**Push** to the registry (requires Docker login):

```bash
docker login registry.example.com
make docker-push
# or: docker push "$PACKER_IMAGE"
```

After pushing, any host that has `config.env` with the same `PACKER_IMAGE`
value can run builds without rebuilding the image locally.

---

## Configuration

Copy and edit `config.env` (never commit it):

```bash
cp config.example.env config.env
```

| Variable | Description |
|----------|-------------|
| `PACKER_IMAGE` | Docker image with Packer + Vagrant + libvirt plugins |
| `ARTIFACTORY_URL` | Artifactory base URL |
| `ARTIFACTORY_VAGRANT_REPO` | Repo name for vagrant box uploads |
| `ARTIFACTORY_API_KEY` | Artifactory credentials |
| `S3_BUCKET` | S3 bucket name for box uploads |
| `S3_PREFIX` | S3 key prefix (default: `vagrant`) |
| `DNS_SERVERS` | DNS injected into the built VM |
| `NFS_SERVER` | NFS server injected into the built VM |

---

## Parameters

### Build target

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TYPE` | `org-golden` | What to build: `vendor-base` · `org-base` · `org-golden` |
| `OS` | `ubuntu` | Guest OS family: `ubuntu` · `rhel` |
| `VERSION` | `24.04` | OS version: `24.04` · `9.6` |
| `ENV` | `staging` | Environment tag embedded in the box name (any lowercase string) |
| `UEFI` | `false` | Enable UEFI boot: `true` · `false` |

### Source

| Parameter | Default | Description |
|-----------|---------|-------------|
| `FROM` | `iso` | vendor-base source — see table below |
| `SOURCE` | `local` | Where to pull the base box for org-base/org-golden: `local` · `remote` |
| `STORAGE` | — | Remote backend (**required** when `SOURCE=remote` or uploading): `artifactory` · `s3` |

### Workflow

| Parameter | Default | Description |
|-----------|---------|-------------|
| `UPLOAD` | `false` | Auto-upload to `STORAGE` after a successful build: `true` · `false` |
| `BOX` | — | Override box filename for `test` / `ssh` / `upload` |
| `FORMAT` | `short` | Output format for `show-*-boxes`: `short` · `json` |

### `FROM=` — vendor-base source

| Value | Builder | Time |
|-------|---------|------|
| `iso` | iso-legacy / iso-uefi | ~30 min — auto-download ISO by OS defaults |
| `/path/to/file.iso` | iso-legacy / iso-uefi | ~30 min — use local ISO file |
| `https://…/file.iso` | iso-legacy / iso-uefi | ~30 min — download ISO from URL |
| `artifactory` | box-legacy / box-uefi | ~3 min — latest vendor-base from Artifactory |
| `s3` | box-legacy / box-uefi | ~3 min — latest vendor-base from S3 |
| `almalinux/9` | box-legacy / box-uefi | ~3 min — pull from Vagrant Cloud by slug |

---

## Build Examples

```bash
# vendor-base: from ISO (default, Ubuntu auto-downloads)
make build TYPE=vendor-base OS=ubuntu VERSION=24.04

# tag the box as production
make build TYPE=vendor-base OS=ubuntu VERSION=24.04 ENV=production

# vendor-base: RHEL from local DVD image
make build TYPE=vendor-base OS=rhel VERSION=9.6 FROM=/mnt/rhel-9.6-x86_64-dvd.iso

# vendor-base: from Vagrant Cloud (fast, needs libvirt provider)
make build TYPE=vendor-base OS=rhel VERSION=9.6 FROM=almalinux/9

# vendor-base: re-apply scripts on existing box from Artifactory
make build TYPE=vendor-base OS=rhel VERSION=9.6 FROM=artifactory

# org-base / org-golden: pick up newest local vendor-base automatically
make build TYPE=org-base   OS=ubuntu VERSION=24.04
make build TYPE=org-golden OS=ubuntu VERSION=24.04

# org-golden: pull base box from S3, then build
make build TYPE=org-golden OS=rhel VERSION=9.6 SOURCE=remote STORAGE=s3

# UEFI build
make build TYPE=vendor-base OS=ubuntu VERSION=24.04 UEFI=true
make build TYPE=org-golden  OS=ubuntu VERSION=24.04 UEFI=true ENV=production
make build TYPE=vendor-base OS=rhel   VERSION=9.6  UEFI=true
make build TYPE=org-golden  OS=rhel   VERSION=9.6  UEFI=true ENV=production
```

---

## Test and SSH

```bash
# auto-pick newest local box
make test TYPE=org-golden OS=ubuntu VERSION=24.04
make ssh  TYPE=org-golden OS=ubuntu VERSION=24.04

# filter by environment
make test TYPE=org-golden OS=ubuntu VERSION=24.04 ENV=production

# explicit box file
make test BOX=ubuntu-24.04-production-org-golden-20260315.1230.box

# fetch from remote and test
make test TYPE=org-golden OS=rhel VERSION=9.6 SOURCE=remote STORAGE=artifactory
```

The smoke test:
1. Validates box structure (`metadata.json`, `box.img`)
2. Boots the VM with vagrant-libvirt
3. Checks SSH access + kernel / systemd health
4. Destroys the VM and removes the box registration

VM resources for the test are configurable:

| Variable | Default | Description |
|----------|---------|-------------|
| `TEST_MEM` | `2048` | RAM in MB |
| `TEST_CPUS` | `2` | CPU count |
| `TEST_BOOT_TIMEOUT` | `600` | Boot timeout in seconds |

```bash
make test TYPE=org-golden OS=ubuntu VERSION=24.04 TEST_MEM=4096 TEST_BOOT_TIMEOUT=900
```

---

## Upload

```bash
make upload TYPE=org-golden OS=ubuntu VERSION=24.04 STORAGE=artifactory
make upload TYPE=org-golden OS=rhel   VERSION=9.6   STORAGE=s3

# upload a specific box file
make upload BOX=ubuntu-24.04-production-org-golden-20260315.1230.box STORAGE=artifactory

# upload all three tiers in one command
make upload-chain OS=ubuntu VERSION=24.04 STORAGE=artifactory

# auto-upload immediately after build
make build TYPE=org-golden OS=ubuntu VERSION=24.04 STORAGE=artifactory UPLOAD=true
```

After upload, a `.meta.json` sidecar is written next to the `.box` file:

```json
{
  "based-on":    "ubuntu-24.04-production-vendor-base-20260315.1230.box",
  "uploaded-to": "artifactory::myrepo/ubuntu-24.04-production-org-golden-20260315.1400.box"
}
```

This records the exact ancestor box and the upload destination for traceability.

---

## Show Boxes

```bash
make show-local-boxes
make show-local-boxes OS=rhel
make show-local-boxes ENV=production

make show-remote-boxes STORAGE=artifactory
make show-remote-boxes STORAGE=s3 OS=ubuntu
make show-remote-boxes STORAGE=artifactory FORMAT=json ENV=staging
```

---

## Cleanup

```bash
# Remove stale libvirt domains/volumes, vagrant box registrations, ~/.vagrant.d/tmp
make clean-env

# clean-env + delete built .box/.meta.json files and logs
make clean-builds

# clean-builds + fully wipe .vagrant.d/
make clean
```

> **Tip:** `~/.vagrant.d/tmp` can accumulate GBs of interrupted `vagrant box add`
> temp files. `make clean-env` clears it automatically.

---

## Troubleshoot

```bash
# Show host status: disk, memory, QEMU processes, libvirt domains/volumes,
# vagrant boxes, ~/.vagrant.d/tmp size
./scripts/troubleshoot.sh

# Interactively remove stale libvirt domains, volumes, vagrant boxes, tmp files
./scripts/troubleshoot.sh --clean

# Open noVNC browser console to the active packer/QEMU build process
./scripts/troubleshoot.sh --vnc
```

---

## Adding / Removing a Supported OS

### Adding a new OS

`make add-new-os` scaffolds all required files by copying an existing (donor) OS
template and substituting the OS name / version strings throughout.

> **Important:** use a donor from the **same family** — cloud-init and kickstart templates are not interchangeable.

```bash
# Debian/Ubuntu family (cloud-init) — donor must be another cloud-init OS
make add-new-os OS=debian VERSION=12 FROM=ubuntu-24.04

# RHEL family (kickstart) — donor must be another kickstart OS
make add-new-os OS=almalinux VERSION=9 FROM=rhel-9.6 ANSIBLE_NAME=redhat

# Dry-run: print what would be created without writing anything
make add-new-os OS=debian VERSION=12 FROM=ubuntu-24.04 DRY_RUN=1
```

Files created by `add-new-os`:

| File | Purpose |
|------|---------|
| `templates/vendor-base/{os}-{ver}/packer.json` | Packer template (ISO URL, checksums, boot_command, disk size) |
| `templates/vendor-base/{os}-{ver}/http/ks.cfg` or `user-data` | Kickstart / cloud-init autoinstall config |
| `templates/vendor-base/{os}-{ver}/scripts/` | Post-install provisioner scripts |
| `templates/org-base/{os}-{ver}.json` | Packer var-file for org-base stage |
| `templates/org-golden/{os}-{ver}.json` | Packer var-file for org-golden stage |
| `templates/ansible/roles/*/vars/{os}-{ver}.yml` | Per-OS ansible variable overrides (packages, kernel modules, etc.) |

#### After scaffolding — mandatory edits

**1. `templates/vendor-base/{os}-{ver}/packer.json`**

Adjust these fields for the new OS:

```jsonc
"iso_url":      "https://releases.example.com/debian-12-amd64.iso",
"iso_checksum": "sha256:abc123...",
"disk_size":    "32768",

// boot_command differs by bootloader:
//   BIOS isolinux (RHEL <= 9, CentOS, Debian):
"boot_command": ["<tab> inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/ks.cfg inst.text<enter>"],
//   BIOS GRUB2 (RHEL 10, Fedora):
"boot_command": ["<wait10>e<down><end> inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/ks.cfg inst.text<leftCtrlOn>x<leftCtrlOff>"],
//   Ubuntu subiquity (20.04+):
"boot_command": ["<wait><enter><wait10>..."]
```

**2. `templates/vendor-base/{os}-{ver}/http/ks.cfg` (RHEL family) or `user-data` (Ubuntu)**

Each OS family has its own syntax:

| OS family | Installer | Config file |
|-----------|----------|-------------|
| RHEL / AlmaLinux / Rocky | Anaconda kickstart | `http/ks.cfg` |
| Ubuntu 20.04+ | Subiquity cloud-init | `http/user-data` + `http/meta-data` |
| Debian | preseed | `http/preseed.cfg` |

Key kickstart options to review:
```kickstart
# package set — keep minimal, add what you actually need
%packages --ignoremissing
@^minimal-environment
openssh-server
...

# bootloader — remove console= args that cause issues in QEMU
bootloader --location=mbr --append="net.ifnames=0 crashkernel=no"

# partitioning — adjust to disk size
clearpart --all --initlabel
autopart --type=lvm
```

**3. `templates/ansible/roles/*/vars/{os}-{ver}.yml`**

Update OS-specific values in each role's vars file:
```yaml
# example: kernel role
kernel_name: "kernel"          # rpm package name; "linux-image-amd64" for Debian
kernel_modules_extra:
  - virtio_blk
  - virtio_net

# example: common role
os_packages:
  - curl
  - git
```

#### Full pipeline after editing

```bash
# 1. Build from ISO — ~30 min
make build TYPE=vendor-base OS=debian VERSION=12

# 2. Verify the box boots and SSH works
make test TYPE=vendor-base OS=debian VERSION=12

# 3. Build org layers
make build TYPE=org-base   OS=debian VERSION=12
make build TYPE=org-golden OS=debian VERSION=12

# 4. Tag as production and upload
make build TYPE=org-golden OS=debian VERSION=12 ENV=production
make upload TYPE=org-golden OS=debian VERSION=12 ENV=production STORAGE=artifactory
```

---

### Removing an OS

```bash
make remove-os OS=debian VERSION=12
```

This deletes:
- `templates/vendor-base/debian-12/`
- `templates/org-base/debian-12.json`
- `templates/org-golden/debian-12.json`
- `templates/ansible/roles/*/vars/debian-12.yml` (all matching files)

> **Note:** Built `.box` files in `builds/` are **not** removed. Delete them manually if needed:
> ```bash
> rm -f builds/debian-12-*.box builds/debian-12-*.meta.json
> ```

---
---


## Output

Built boxes land in `builds/`:

```
builds/ubuntu-24.04-staging-vendor-base-20260315.1230.box
builds/ubuntu-24.04-staging-org-base-20260315.1400.box
builds/ubuntu-24.04-staging-org-golden-20260315.1530.box
builds/ubuntu-24.04-staging-uefi-org-golden-20260315.1600.box
builds/rhel-9.6-production-vendor-base-20260315.1700.box
```

**Box naming format:** `{os}-{version}-{env}[-uefi]-{type}-{timestamp}.box`

A `.meta.json` sidecar is created alongside each built box recording provenance.

Remote-fetched boxes are cached in `builds/remote/`.

---

## Project Structure

```
.
├── Makefile                          # All build/test/upload logic
├── config.example.env                # Configuration template
├── docker/
│   └── Dockerfile                    # packer-vagrant image
├── scripts/
│   ├── common.py                     # Shared helpers (box naming, storage config)
│   ├── add-new-os.py                 # Scaffold templates for a new OS/version
│   ├── fetch-box.py                  # Download latest box from remote storage
│   ├── resolve-box.py                # Resolve local/remote box for test/ssh
│   ├── show-boxes.py                 # List local or remote boxes
│   ├── test-box.py                   # Smoke test a box
│   ├── upload.py                     # Upload box to Artifactory / S3
│   ├── troubleshoot.sh               # Host status / cleanup / VNC console
│   └── vnc-console.sh                # noVNC helper (used by troubleshoot.sh)
└── templates/
    ├── _common/                      # Shared provisioner scripts (sshd, vagrant, etc.)
    ├── vendor-base/
    │   ├── ubuntu-24.04/packer.json  # Packer template: ISO/box → vendor-base
    │   └── rhel-9.6/packer.json
    ├── org-base/
    │   ├── ubuntu-24.04.json         # Packer var-file for org-base
    │   └── rhel-9.6.json
    ├── org-golden/
    │   ├── ubuntu-24.04.json         # Packer var-file for org-golden
    │   └── rhel-9.6.json
    ├── packer-template.json          # Main Packer template (org-base / org-golden)
    ├── ansible/                      # Ansible roles used in org-base / org-golden
    └── ssh/
        └── Vagrantfile.tpl           # Vagrantfile template for make ssh
```
