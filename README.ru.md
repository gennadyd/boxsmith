# Сборщик Vagrant-образов

Автоматизированный конвейер для сборки, тестирования и распространения Vagrant-боксов
с помощью Packer + QEMU/KVM + libvirt.  
Все инструменты запускаются внутри Docker — локальная установка Packer, Vagrant и QEMU не требуется.

**Языки:** [English](README.md) | Русский | [עברית](README.he.md)

---

## Конвейер

```
ISO / Vagrant Cloud / удалённый бокс
          │
          ▼
    vendor-base        ← установка ОС, базовые пакеты, пользователь vagrant
          │
          ▼
     org-base          ← корпоративные репо, драйверы, внутренний тулинг
          │
          ▼
    org-golden         ← финальное закрепление, политики, метаданные релиза
          │
          ▼
   upload (Artifactory / S3)
```

**Поддерживаемые ОС:**

| ОС | Версии | UEFI |
|----|--------|------|
| Ubuntu | 24.04 | ✓ |
| RHEL   | 9.6   | ✓ |

---

## Требования

### 1. Docker

Вся инструментальная цепочка (Packer/Vagrant/QEMU) работает внутри Docker:

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

Требуется на хосте для управления сетями и пулами хранилищ VM:

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

Проверка доступности KVM:

```bash
kvm-ok             # Ubuntu (пакет cpu-checker)
virt-host-validate
```

Проверьте доступность `/dev/kvm` из Docker:

```bash
ls -l /dev/kvm
docker run --rm --device /dev/kvm alpine ls /dev/kvm
```

### 3. Группы пользователя

Добавьте пользователя в группы `libvirt` и `kvm`, затем перелогиньтесь:

```bash
sudo usermod -aG libvirt,kvm $USER
newgrp libvirt   # применить без перелогина (только текущий shell)
```

### 4. Python 3.10+

Используется вспомогательными скриптами (`make show-boxes`, `make add-new-os` и др.):

```bash
# Ubuntu/Debian
sudo apt-get install -y python3 python3-pip

# RHEL/CentOS
sudo dnf install -y python3 python3-pip
```

Проверка версии:

```bash
python3 --version   # должно быть >= 3.10
```

### 5. AWS CLI v2 _(опционально — для `STORAGE=s3`)_

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp/aws-install
sudo /tmp/aws-install/aws/install
aws --version
```

### 6. JFrog CLI _(опционально — для `STORAGE=artifactory`)_

```bash
curl -fsSL https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/[RELEASE]/jfrog-cli-linux-amd64/jf \
  -o /usr/local/bin/jf && chmod +x /usr/local/bin/jf
jf --version
```

### 7. OVMF _(для UEFI-сборок)_

```bash
# Ubuntu/Debian
sudo apt-get install -y ovmf

# RHEL/CentOS
sudo dnf install -y edk2-ovmf
```

---

## Быстрый старт

```bash
cp config.example.env config.env
# отредактируй config.env: PACKER_IMAGE, ARTIFACTORY_*, S3_BUCKET и др.

make docker-build   # собрать Docker-образ packer-vagrant (один раз)

# Полный конвейер для Ubuntu 24.04 (окружение staging)
make build TYPE=vendor-base OS=ubuntu VERSION=24.04
make build TYPE=org-base    OS=ubuntu VERSION=24.04
make build TYPE=org-golden  OS=ubuntu VERSION=24.04

# Тест и SSH в результат
make test TYPE=org-golden OS=ubuntu VERSION=24.04
make ssh  TYPE=org-golden OS=ubuntu VERSION=24.04
```

---

## Конфигурация

Скопируй и отредактируй `config.env` (не коммить его):

```bash
cp config.example.env config.env
```

| Переменная | Описание |
|------------|----------|
| `PACKER_IMAGE` | Docker-образ с Packer + Vagrant + libvirt-плагинами |
| `ARTIFACTORY_URL` | Базовый URL Artifactory |
| `ARTIFACTORY_VAGRANT_REPO` | Имя репозитория для загрузки боксов |
| `ARTIFACTORY_API_KEY` | Учётные данные Artifactory |
| `S3_BUCKET` | Имя S3-бакета для хранения боксов |
| `S3_PREFIX` | Префикс ключей S3 (по умолчанию: `vagrant`) |
| `DNS_SERVERS` | DNS, внедряемый в собираемую VM |
| `NFS_SERVER` | NFS-сервер, внедряемый в собираемую VM |

---

## Параметры

| Параметр | По умолчанию | Значения | Описание |
|----------|-------------|----------|----------|
| `TYPE` | `org-golden` | `vendor-base` \| `org-base` \| `org-golden` | Тип собираемого бокса |
| `OS` | `ubuntu` | `ubuntu` \| `rhel` | Семейство гостевой ОС |
| `VERSION` | `24.04` | `24.04` \| `9.6` | Версия ОС |
| `ENV` | `staging` | любой строчный идентификатор | Метка окружения, встроенная в имя бокса |
| `UEFI` | `false` | `true` \| `false` | Загрузка через UEFI |
| `FROM` | `iso` | см. ниже | Источник для vendor-base |
| `SOURCE` | `local` | `local` \| `remote` | Откуда брать базовый бокс для org-base/org-golden |
| `STORAGE` | — | `artifactory` \| `s3` | Удалённое хранилище (обязательно при `SOURCE=remote` или upload) |

### `FROM=` — источник для vendor-base

| Значение | Сборщик | Описание |
|----------|---------|----------|
| `iso` | iso-legacy/uefi | Сборка из ISO — автоскачивание по умолчанию (~30 мин) |
| `/путь/к/файлу.iso` | iso-legacy/uefi | Сборка из локального ISO |
| `https://…/file.iso` | iso-legacy/uefi | Сборка из ISO по URL |
| `artifactory` | box-legacy/uefi | Скачать последний vendor-base из Artifactory (~3 мин) |
| `s3` | box-legacy/uefi | Скачать последний vendor-base из S3 (~3 мин) |
| `almalinux/9` | box-legacy/uefi | Скачать из Vagrant Cloud по slug (~3 мин) |

---

## Примеры сборки

```bash
# vendor-base: из ISO (по умолчанию, Ubuntu скачивается автоматически)
make build TYPE=vendor-base OS=ubuntu VERSION=24.04

# пометить бокс как production
make build TYPE=vendor-base OS=ubuntu VERSION=24.04 ENV=production

# vendor-base: RHEL из локального DVD-образа
make build TYPE=vendor-base OS=rhel VERSION=9.6 FROM=/mnt/rhel-9.6-x86_64-dvd.iso

# vendor-base: из Vagrant Cloud (быстро)
make build TYPE=vendor-base OS=rhel VERSION=9.6 FROM=almalinux/9

# org-golden: взять базовый бокс из S3 и собрать
make build TYPE=org-golden OS=rhel VERSION=9.6 SOURCE=remote STORAGE=s3

# UEFI-сборка
make build TYPE=vendor-base OS=ubuntu VERSION=24.04 UEFI=true
make build TYPE=org-golden  OS=ubuntu VERSION=24.04 UEFI=true ENV=production
make build TYPE=vendor-base OS=rhel   VERSION=9.6  UEFI=true
make build TYPE=org-golden  OS=rhel   VERSION=9.6  UEFI=true ENV=production
```

---

## Тест и SSH

```bash
# автовыбор последнего локального бокса
make test TYPE=org-golden OS=ubuntu VERSION=24.04
make ssh  TYPE=org-golden OS=ubuntu VERSION=24.04

# фильтр по окружению
make test TYPE=org-golden OS=ubuntu VERSION=24.04 ENV=production

# указать конкретный файл бокса
make test BOX=ubuntu-24.04-production-org-golden-20260315.1230.box

# скачать из удалённого хранилища и протестировать
make test TYPE=org-golden OS=rhel VERSION=9.6 SOURCE=remote STORAGE=artifactory
```

Дымовой тест:
1. Проверяет структуру бокса (`metadata.json`, `box.img`)
2. Поднимает VM через vagrant-libvirt (2 ГБ ОЗУ, 2 CPU)
3. Проверяет SSH-доступ и состояние ядра / systemd
4. Уничтожает VM и удаляет регистрацию бокса

---

## Загрузка (upload)

```bash
make upload TYPE=org-golden OS=ubuntu VERSION=24.04 STORAGE=artifactory
make upload TYPE=org-golden OS=rhel   VERSION=9.6   STORAGE=s3

# загрузить конкретный файл бокса
make upload BOX=ubuntu-24.04-production-org-golden-20260315.1230.box STORAGE=artifactory
```

После загрузки рядом с файлом `.box` создаётся `.meta.json`:

```json
{
  "based-on":    "ubuntu-24.04-production-vendor-base-20260315.1230.box",
  "uploaded-to": "artifactory::myrepo/ubuntu-24.04-production-org-golden-20260315.1400.box"
}
```

Файл фиксирует исходный бокс-предок и место назначения для отслеживания происхождения.

---

## Просмотр боксов

```bash
make show-local-boxes
make show-local-boxes OS=rhel
make show-local-boxes ENV=production

make show-remote-boxes STORAGE=artifactory
make show-remote-boxes STORAGE=s3 OS=ubuntu
make show-remote-boxes STORAGE=artifactory FORMAT=json ENV=staging
```

---

## Очистка

```bash
make clean-builds   # удалить builds/*.box и logs/*.log
make clean-env      # уничтожить зависшие домены и тома libvirt после неудачных сборок
make clean          # оба пункта выше + сброс .vagrant.d/
```

---

## Добавление / удаление ОС

### Добавление новой ОС

`make add-new-os` создаёт все необходимые файлы, копируя шаблон существующей (донорской) ОС
и заменяя имя/версию ОС по всему дереву:

```bash
# Создать шаблоны на основе существующего (например, rhel-9.6 как донор)
make add-new-os OS=debian VERSION=12 FROM=rhel-9.6

# Сначала запустить dry-run — показать, что будет создано, без записи
make add-new-os OS=debian VERSION=12 FROM=rhel-9.6 DRY_RUN=1

# Если у новой ОС другой префикс в ansible vars
make add-new-os OS=almalinux VERSION=9 FROM=rhel-9.6 ANSIBLE_NAME=redhat
```

Файлы, создаваемые командой `add-new-os`:

| Файл | Назначение |
|------|-----------|
| `templates/vendor-base/{os}-{ver}/packer.json` | Шаблон Packer (URL ISO, контрольная сумма, boot_command, размер диска) |
| `templates/vendor-base/{os}-{ver}/http/ks.cfg` или `user-data` | Kickstart / cloud-init autoinstall |
| `templates/vendor-base/{os}-{ver}/scripts/` | Post-install скрипты провайдера |
| `templates/org-base/{os}-{ver}.json` | Var-файл Packer для стадии org-base |
| `templates/org-golden/{os}-{ver}.json` | Var-файл Packer для стадии org-golden |
| `templates/ansible/roles/*/vars/{os}-{ver}.yml` | Переменные Ansible для конкретной ОС |

#### После создания шаблонов — обязательные правки

**1. `templates/vendor-base/{os}-{ver}/packer.json`**

Исправить для новой ОС:

```jsonc
"iso_url":      "https://releases.example.com/debian-12-amd64.iso",
"iso_checksum": "sha256:abc123...",
"disk_size":    "32768",

// boot_command зависит от загрузчика:
//   BIOS isolinux (RHEL <= 9, CentOS, Debian):
"boot_command": ["<tab> inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/ks.cfg inst.text<enter>"],
//   BIOS GRUB2 (RHEL 10, Fedora):
"boot_command": ["<wait10>e<down><end> inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/ks.cfg inst.text<leftCtrlOn>x<leftCtrlOff>"],
//   Ubuntu subiquity (20.04+):
"boot_command": ["<wait><enter><wait10>..."]
```

**2. `templates/vendor-base/{os}-{ver}/http/ks.cfg` (RHEL-семейство) или `user-data` (Ubuntu)**

| Семейство ОС | Установщик | Файл конфигурации |
|-------------|-----------|------------------|
| RHEL / AlmaLinux / Rocky | Anaconda kickstart | `http/ks.cfg` |
| Ubuntu 20.04+ | Subiquity cloud-init | `http/user-data` + `http/meta-data` |
| Debian | preseed | `http/preseed.cfg` |

Ключевые параметры kickstart для проверки:
```kickstart
%packages --ignoremissing
@^minimal-environment
openssh-server
...

# bootloader — убрать console= аргументы (вызывают проблемы в QEMU)
bootloader --location=mbr --append="net.ifnames=0 crashkernel=no"

clearpart --all --initlabel
autopart --type=lvm
```

**3. `templates/ansible/roles/*/vars/{os}-{ver}.yml`**

Обновить специфичные для ОС значения:
```yaml
# пример: роль kernel
kernel_name: "kernel"          # имя rpm-пакета; "linux-image-amd64" для Debian
kernel_modules_extra:
  - virtio_blk
  - virtio_net

# пример: роль common
os_packages:
  - curl
  - git
```

#### Полный конвейер после правок

```bash
# 1. Сборка из ISO — ~30 мин
make build TYPE=vendor-base OS=debian VERSION=12

# 2. Проверить, что бокс загружается и SSH работает
make test TYPE=vendor-base OS=debian VERSION=12

# 3. Собрать org-слои
make build TYPE=org-base   OS=debian VERSION=12
make build TYPE=org-golden OS=debian VERSION=12

# 4. Пометить как production и загрузить
make build TYPE=org-golden OS=debian VERSION=12 ENV=production
make upload TYPE=org-golden OS=debian VERSION=12 ENV=production STORAGE=artifactory
```

---

### Удаление ОС

```bash
make remove-os OS=debian VERSION=12
```

Удаляет:
- `templates/vendor-base/debian-12/`
- `templates/org-base/debian-12.json`
- `templates/org-golden/debian-12.json`
- `templates/ansible/roles/*/vars/debian-12.yml` (все совпадающие файлы)

> **Примечание:** Собранные файлы `.box` в `builds/` **не удаляются**. При необходимости удалить вручную:
> ```bash
> rm -f builds/debian-12-*.box builds/debian-12-*.meta.json
> ```

---
---


## Docker-образ

Переменная `PACKER_IMAGE` задаёт имя образа. Пропишите её в `config.env`
с полным путём до реестра — тогда одно и то же имя используется при сборке,
публикации и запуске:

```bash
# config.env
PACKER_IMAGE=registry.example.com/devops/packer-vagrant:latest
```

**Сборка** образа (локально, тегируется именем `PACKER_IMAGE`):

```bash
make docker-build

# пользовательские версии инструментов
make docker-build PACKER_VER=1.11.1 QEMU_PLUGIN_VER=1.1.0 TIMEZONE=UTC
```

**Публикация** в реестр (требуется предварительный `docker login`):

```bash
docker login registry.example.com
make docker-push
# или: docker push "$PACKER_IMAGE"
```

После публикации любой хост с `config.env`, указывающим на этот `PACKER_IMAGE`,
может запускать сборки без локальной пересборки образа.

---

## Результат

Собранные боксы попадают в `builds/`:

```
builds/ubuntu-24.04-staging-vendor-base-20260315.1230.box
builds/ubuntu-24.04-staging-org-base-20260315.1400.box
builds/ubuntu-24.04-staging-org-golden-20260315.1530.box
builds/ubuntu-24.04-staging-uefi-org-golden-20260315.1600.box
builds/rhel-9.6-production-vendor-base-20260315.1700.box
```

**Формат имени бокса:** `{os}-{версия}-{env}[-uefi]-{тип}-{timestamp}.box`

Рядом с каждым собранным боксом создаётся `.meta.json` с данными о происхождении.

Удалённо скачанные боксы кэшируются в `builds/remote/`.
