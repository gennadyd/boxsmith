# בונה קופסאות Vagrant

צינור אוטומטי לבניה, בדיקה והפצה של קופסאות Vagrant
עם Packer + QEMU/KVM + libvirt.  
כל הכלים רצים בתוך Docker — אין צורך להתקין Packer, Vagrant או QEMU באופן מקומי.

**שפות:** [English](README.md) | [Русский](README.ru.md) | עברית

---

## צינור הבנייה

```
ISO / Vagrant Cloud / קופסה מרחוק
          │
          ▼
    vendor-base        ← התקנת ה-OS, חבילות בסיס, משתמש vagrant
          │
          ▼
     org-base          ← ריפו ארגוניים, דרייברים, כלי פנים
          │
          ▼
    org-golden         ← הקשחה סופית, מדיניות ארגונית, מטאדאטה
          │
          ▼
   upload (Artifactory / S3)
```

**מערכות הפעלה נתמכות:**

| מערכת הפעלה | גרסאות | UEFI |
|-------------|--------|------|
| Ubuntu | 24.04 | ✓ |
| RHEL   | 9.6   | ✓ |

---

## דרישות מקדימות

- Docker עם גישה ל-`/dev/kvm`
- libvirt + KVM על המארח
- משתמש בקבוצות `libvirt` ו-`kvm`
- Python 3.10+
- AWS CLI v2 — נדרש עבור `STORAGE=s3`
- JFrog CLI — נדרש עבור `STORAGE=artifactory`

```bash
sudo usermod -aG libvirt,kvm $USER
```

לבניות UEFI, יש להתקין OVMF על המארח:

```bash
# Ubuntu/Debian
sudo apt-get install -y ovmf

# RHEL/CentOS
sudo dnf install -y edk2-ovmf
```

---

## התחלה מהירה

```bash
cp config.example.env config.env
# ערוך config.env — הגדר PACKER_IMAGE, ARTIFACTORY_*, S3_BUCKET וכו'

make docker-build   # בנה את תמונת Docker של packer-vagrant (פעם אחת)

# צינור מלא עבור Ubuntu 24.04 (סביבת staging)
make build TYPE=vendor-base OS=ubuntu VERSION=24.04
make build TYPE=org-base    OS=ubuntu VERSION=24.04
make build TYPE=org-golden  OS=ubuntu VERSION=24.04

# בדיקה ו-SSH לתוצאה
make test TYPE=org-golden OS=ubuntu VERSION=24.04
make ssh  TYPE=org-golden OS=ubuntu VERSION=24.04
```

---

## קונפיגורציה

העתק וערוך את `config.env` (לא לקומיט):

```bash
cp config.example.env config.env
```

| משתנה | תיאור |
|-------|-------|
| `PACKER_IMAGE` | תמונת Docker עם Packer + Vagrant + פלאגינים לlibvirt |
| `ARTIFACTORY_URL` | כתובת בסיס של Artifactory |
| `ARTIFACTORY_VAGRANT_REPO` | שם הריפו להעלאת קופסאות |
| `ARTIFACTORY_API_KEY` | אישורי Artifactory |
| `S3_BUCKET` | שם ה-S3 bucket לאחסון קופסאות |
| `S3_PREFIX` | קידומת מפתח S3 (ברירת מחדל: `vagrant`) |
| `DNS_SERVERS` | DNS שמוזרק ל-VM הנבנה |
| `NFS_SERVER` | שרת NFS שמוזרק ל-VM הנבנה |

---

## פרמטרים

| פרמטר | ברירת מחדל | ערכים | תיאור |
|-------|-----------|-------|-------|
| `TYPE` | `org-golden` | `vendor-base` \| `org-base` \| `org-golden` | סוג הקופסה לבנייה |
| `OS` | `ubuntu` | `ubuntu` \| `rhel` | משפחת ה-OS האורח |
| `VERSION` | `24.04` | `24.04` \| `9.6` | גרסת ה-OS |
| `ENV` | `staging` | מזהה בלועזית כלשהו | תגית הסביבה המוטמעת בשם הקופסה |
| `UEFI` | `false` | `true` \| `false` | אתחול UEFI |
| `FROM` | `iso` | ראה להלן | מקור עבור vendor-base |
| `SOURCE` | `local` | `local` \| `remote` | מאיפה לקחת את קופסת הבסיס |
| `STORAGE` | — | `artifactory` \| `s3` | אחסון מרוחק |

### `FROM=` — מקורות vendor-base

| ערך | בונה | תיאור |
|-----|------|-------|
| `iso` | iso-legacy/uefi | בנייה מ-ISO — הורדה אוטומטית (~30 דקות) |
| `/path/to/file.iso` | iso-legacy/uefi | בנייה מקובץ ISO מקומי |
| `https://…/file.iso` | iso-legacy/uefi | בנייה מ-ISO לפי URL |
| `artifactory` | box-legacy/uefi | הורדת ה-vendor-base האחרון מ-Artifactory (~3 דקות) |
| `s3` | box-legacy/uefi | הורדת ה-vendor-base האחרון מ-S3 (~3 דקות) |
| `almalinux/9` | box-legacy/uefi | הורדה מ-Vagrant Cloud לפי slug (~3 דקות) |

---

## דוגמאות בנייה

```bash
# vendor-base: מ-ISO (ברירת מחדל)
make build TYPE=vendor-base OS=ubuntu VERSION=24.04

# תיוג הקופסה כ-production
make build TYPE=vendor-base OS=ubuntu VERSION=24.04 ENV=production

# vendor-base: RHEL מ-DVD מקומי
make build TYPE=vendor-base OS=rhel VERSION=9.6 FROM=/mnt/rhel-9.6-x86_64-dvd.iso

# org-golden: משיכת קופסת בסיס מ-S3 ובנייה
make build TYPE=org-golden OS=rhel VERSION=9.6 SOURCE=remote STORAGE=s3

# בניית UEFI
make build TYPE=vendor-base OS=ubuntu VERSION=24.04 UEFI=true
make build TYPE=org-golden  OS=ubuntu VERSION=24.04 UEFI=true ENV=production
make build TYPE=vendor-base OS=rhel   VERSION=9.6  UEFI=true
make build TYPE=org-golden  OS=rhel   VERSION=9.6  UEFI=true ENV=production
```

---

## בדיקה ו-SSH

```bash
# בחירה אוטומטית של הקופסה המקומית האחרונה
make test TYPE=org-golden OS=ubuntu VERSION=24.04
make ssh  TYPE=org-golden OS=ubuntu VERSION=24.04

# סינון לפי סביבה
make test TYPE=org-golden OS=ubuntu VERSION=24.04 ENV=production

# קובץ קופסה ספציפי
make test BOX=ubuntu-24.04-production-org-golden-20260315.1230.box

# הורדה מאחסון מרוחק ובדיקה
make test TYPE=org-golden OS=rhel VERSION=9.6 SOURCE=remote STORAGE=artifactory
```

בדיקת עשן:
1. בדיקת מבנה הקופסה (`metadata.json`, `box.img`)
2. הפעלת VM עם vagrant-libvirt (2 GB RAM, 2 CPU)
3. בדיקת גישת SSH + תקינות ה-kernel/systemd
4. הרס ה-VM והסרת רישום הקופסה

---

## העלאה (upload)

```bash
make upload TYPE=org-golden OS=ubuntu VERSION=24.04 STORAGE=artifactory
make upload TYPE=org-golden OS=rhel   VERSION=9.6   STORAGE=s3

# העלאת קובץ קופסה ספציפי
make upload BOX=ubuntu-24.04-production-org-golden-20260315.1230.box STORAGE=artifactory
```

לאחר ההעלאה נוצר קובץ `.meta.json` לצד קובץ ה-`.box`:

```json
{
  "based-on":    "ubuntu-24.04-production-vendor-base-20260315.1230.box",
  "uploaded-to": "artifactory::myrepo/ubuntu-24.04-production-org-golden-20260315.1400.box"
}
```

הקובץ שומר את קופסת האב המדויקת וכתובת היעד לצורכי מעקב.

---

## הצגת קופסאות

```bash
make show-local-boxes
make show-local-boxes OS=rhel
make show-local-boxes ENV=production

make show-remote-boxes STORAGE=artifactory
make show-remote-boxes STORAGE=s3 OS=ubuntu
make show-remote-boxes STORAGE=artifactory FORMAT=json ENV=staging
```

---

## ניקוי

```bash
make clean-builds   # מחיקת builds/*.box ו-logs/*.log
make clean-env      # הרס דומיינים וvolumes תקועים ב-libvirt מבניות כושלות
make clean          # שניהם + איפוס .vagrant.d/
```

---

## הוספה / הסרת מערכת הפעלה

### הוספת מערכת הפעלה חדשה

`make add-new-os` יוצר את כל הקבצים הנדרשים על ידי העתקת תבנית OS קיים (תורם)
והחלפת שם/גרסת ה-OS לאורך כל העץ:

```bash
# יצירת תבניות על בסיס תבנית קיימת (למשל rhel-9.6 כתורם)
make add-new-os OS=debian VERSION=12 FROM=rhel-9.6

# dry-run קודם — הדפסת מה שייווצר ללא כתיבה
make add-new-os OS=debian VERSION=12 FROM=rhel-9.6 DRY_RUN=1

# אם ל-OS החדש יש קידומת שונה ב-ansible vars
make add-new-os OS=almalinux VERSION=9 FROM=rhel-9.6 ANSIBLE_NAME=redhat
```

קבצים שנוצרים על ידי `add-new-os`:

| קובץ | מטרה |
|------|-------|
| `templates/vendor-base/{os}-{ver}/packer.json` | תבנית Packer (כתובת ISO, סכום בדיקה, boot_command, גודל דיסק) |
| `templates/vendor-base/{os}-{ver}/http/ks.cfg` או `user-data` | Kickstart / cloud-init autoinstall |
| `templates/vendor-base/{os}-{ver}/scripts/` | סקריפטי provisioner לאחר התקנה |
| `templates/org-base/{os}-{ver}.json` | קובץ var של Packer לשלב org-base |
| `templates/org-golden/{os}-{ver}.json` | קובץ var של Packer לשלב org-golden |
| `templates/ansible/roles/*/vars/{os}-{ver}.yml` | עקיפות משתנה Ansible ספציפיות ל-OS |

#### לאחר יצירת התבניות — עריכות חובה

**1. `templates/vendor-base/{os}-{ver}/packer.json`**

לתקן עבור ה-OS החדש:

```jsonc
"iso_url":      "https://releases.example.com/debian-12-amd64.iso",
"iso_checksum": "sha256:abc123...",
"disk_size":    "32768",

// boot_command תלוי ב-bootloader:
//   BIOS isolinux (RHEL <= 9, CentOS, Debian):
"boot_command": ["<tab> inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/ks.cfg inst.text<enter>"],
//   BIOS GRUB2 (RHEL 10, Fedora):
"boot_command": ["<wait10>e<down><end> inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/ks.cfg inst.text<leftCtrlOn>x<leftCtrlOff>"],
//   Ubuntu subiquity (20.04+):
"boot_command": ["<wait><enter><wait10>..."]
```

**2. `templates/vendor-base/{os}-{ver}/http/ks.cfg` (משפחת RHEL) או `user-data` (Ubuntu)**

| משפחת OS | מתקין | קובץ קונפיגורציה |
|---------|-------|----------------|
| RHEL / AlmaLinux / Rocky | Anaconda kickstart | `http/ks.cfg` |
| Ubuntu 20.04+ | Subiquity cloud-init | `http/user-data` + `http/meta-data` |
| Debian | preseed | `http/preseed.cfg` |

**3. `templates/ansible/roles/*/vars/{os}-{ver}.yml`**

לעדכן ערכים ספציפיים ל-OS:
```yaml
kernel_name: "kernel"          # שם חבילת rpm; "linux-image-amd64" עבור Debian
kernel_modules_extra:
  - virtio_blk
  - virtio_net
os_packages:
  - curl
  - git
```

#### צינור מלא לאחר העריכות

```bash
# 1. בנייה מ-ISO — ~30 דקות
make build TYPE=vendor-base OS=debian VERSION=12

# 2. ווידוא שהקופסה עולה ו-SSH עובד
make test TYPE=vendor-base OS=debian VERSION=12

# 3. בניית שכבות org
make build TYPE=org-base   OS=debian VERSION=12
make build TYPE=org-golden OS=debian VERSION=12

# 4. תיוג כ-production והעלאה
make build TYPE=org-golden OS=debian VERSION=12 ENV=production
make upload TYPE=org-golden OS=debian VERSION=12 ENV=production STORAGE=artifactory
```

---

### הסרת OS

```bash
make remove-os OS=debian VERSION=12
```

מוחק:
- `templates/vendor-base/debian-12/`
- `templates/org-base/debian-12.json`
- `templates/org-golden/debian-12.json`
- `templates/ansible/roles/*/vars/debian-12.yml` (כל הקבצים התואמים)

> **הערה:** קבצי `.box` שנבנו ב-`builds/` **אינם** מוסרים. למחיקה ידנית:
> ```bash
> rm -f builds/debian-12-*.box builds/debian-12-*.meta.json
> ```

---
---


## תמונת Docker

```bash
make docker-build

# גרסאות מותאמות אישית
make docker-build PACKER_VER=1.11.1 QEMU_PLUGIN_VER=1.1.0 TIMEZONE=UTC
```

---

## פלט

קופסאות שנבנו מגיעות ל-`builds/`:

```
builds/ubuntu-24.04-staging-vendor-base-20260315.1230.box
builds/ubuntu-24.04-staging-org-base-20260315.1400.box
builds/ubuntu-24.04-staging-org-golden-20260315.1530.box
builds/ubuntu-24.04-staging-uefi-org-golden-20260315.1600.box
builds/rhel-9.6-production-vendor-base-20260315.1700.box
```

**פורמט שם הקופסה:** `{os}-{גרסה}-{env}[-uefi]-{סוג}-{timestamp}.box`

לצד כל קופסה שנבנית נוצר `.meta.json` עם נתוני מקור.

קופסאות שהורדו מרחוק מאוחסנות ב-`builds/remote/`.
