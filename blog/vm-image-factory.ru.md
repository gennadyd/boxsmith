# Фабрика VM-образов: как мы построили конвейер Packer + Vagrant + KVM для внутренней инфраструктуры

> **Платформы:** Habr / Medium
> **Теги:** devops, packer, vagrant, kvm, libvirt, infrastructure-as-code, ci-cd

---

## Предыстория: «а давай поднимем виртуалку»

Представьте типичную ситуацию в средней и крупной компании. Несколько команд DevOps,
десятки разработчиков, два «официальных» дистрибутива — Ubuntu 24.04 и RHEL 9.6 —
и ворох вопросов:

* Откуда берётся «золотой» образ с корпоративным CA, прокси, NTP и нужными агентами?
* Кто его обновляет, когда выходит новое ядро или секьюрити-патч?
* Как разработчик получает свежую чистую среду без часового ожидания установки пакетов?
* И, самое главное — если что-то сломалось в базовом образе, как быстро откатиться?

Стандартный ответ «управляем вручную» перестаёт работать ровно тогда, когда команда
перестаёт помещаться за одним столом. Именно это привело к идее — сделать _полностью
автоматизированную_ фабрику VM-образов с понятным жизненным циклом.

---

## Что такое «слоёный» образ и зачем это нужно

Ключевая идея — разбить монолитный образ на **три независимых слоя**. Каждый строится
поверх предыдущего, у каждого — своя зона ответственности и свой владелец.

```
  Владелец           Слой                    Содержимое                          Артефакт
  ──────────────────────────────────────────────────────────────────────────────────────────

  👩‍💻 Команды     ┌─────────────────────────────────────────────────────────┐
  разработки     │  ③  org-golden                                          │  ──►  .box
                 │     Docker, kubectl, compilers, Python venv,            │
                 │     IDE helpers, team-specific SDK                      │
                 └───────────────────────┬─────────────────────────────────┘
                                         │  packer build (vagrant provisioner)
                                         │  Ansible: playbook/golden.yml
                                         ▼
  🏗️ Инфра       ┌─────────────────────────────────────────────────────────┐
  команда        │  ②  org-base                                            │  ──►  .box
                 │     Corp CA, internal DNS/NTP, proxy settings,         │
                 │     monitoring agent, inventory agent,                  │
                 │     internal apt/yum repos                              │
                 └───────────────────────┬─────────────────────────────────┘
                                         │  packer build (vagrant provisioner)
                                         │  Ansible: playbook/base.yml + shell scripts
                                         ▼
  🔒 Безопас-    ┌─────────────────────────────────────────────────────────┐
  ность          │  ①  vendor-base                                         │  ──►  .box
                 │     Pristine OS from official ISO                       │
                 │     Kickstart / Cloud-Init                              │
                 │     BIOS legacy  ──or──  UEFI + efivars.fd             │
                 │     NO corp config, NO internal repos                   │
                 └─────────────────────────────────────────────────────────┘
                                         ▲
                                         │  packer build (QEMU/KVM)
                                    [ ISO файл ]
```

**vendor-base** — нетронутая ОС, собранная из официального ISO.
Здесь нет ничего корпоративного: никаких внутренних repo, никаких агентов.
Ответственность — у команды безопасности. Обновляется при выходе нового
минорного релиза ОС или критического CVE.

**org-base** — первый корпоративный слой. Прописывает внутренние DNS, NTP, прокси,
добавляет корпоративный CA, ставит агентов мониторинга и инвентаризации.
Провизионируется через Ansible.

**org-golden** — образ для конечных пользователей. Содержит предустановленные
инструменты: компиляторы, Docker, kubectl, Python-окружения, IDE-хелперы.
Формируется под конкретную команду или роль.

---

## Стек технологий

| Инструмент | Роль |
|---|---|
| **HashiCorp Packer** | сборка образов: описывает builder + provisioner + post-processor |
| **QEMU/KVM + libvirt** | гипервизор на хост-машине |
| **Vagrant (libvirt provider)** | удобная обёртка для box-файлов и их тестирования |
| **Ansible** | провизионинг org-base и org-golden слоёв |
| **Docker** | изоляция среды сборки (Packer + Vagrant запускаются внутри контейнера) |
| **Artifactory / S3** | хранение и версионирование готовых `.box`-файлов |
| **GitHub Actions** | CI/CD: автосборка, валидация шаблонов, публикация |
| **Python 3** | вспомогательные скрипты (upload, test, add-new-os) |

---

## Как это работает: жизнь одного образа

### Шаг 1. Сборка vendor-base из ISO

Всё начинается с чистого ISO. Packer поднимает QEMU-машину, монтирует ISO,
передаёт `cloud-init` / `kickstart`-конфиг через встроенный HTTP-сервер
и ждёт завершения установки. Поддерживаются два режима загрузки:

* **legacy BIOS** — для старого железа и совместимости
* **UEFI (SecureBoot-ready)** — для современных хостов; требует `efivars.fd`

По окончании — диск упаковывается в `.box`-файл формата libvirt и загружается
в Artifactory. Имя файла несёт всю мета-информацию:

```
ubuntu-24.04-production-uefi-vendor-base-20260316.2212.box
^^^^^^^  ^^^^^  ^^^^^^^^^^  ^^^^  ^^^^^^^^^^^  ^^^^^^^^^^^^
  OS   version     env      boot     layer       timestamp
```

### Шаг 2. org-base поверх vendor-base

Packer скачивает `vendor-base` box из Artifactory, запускает его через
`vagrant up`, прогоняет Ansible playbook и Shell-скрипты, затем пакует
результат в новый `.box`.

Ansible-роль содержит `vars/` по каждой ОС и версии:
`ubuntu-24.04.yml`, `rhel-9.6.yml` — всё параметризовано, переменные
покрывают имена пакетов, пути к конфигам и ядро.

### Шаг 3. org-golden поверх org-base

Аналогично шагу 2, только playbook другой — ставятся разработческие
инструменты. Можно иметь несколько вариантов golden-образа под
разные команды (ML, backend, infra).

### Запуск полного конвейера

Вся сборка управляется через `make` — никаких голых bash-скриптов в руках
пользователя. Каждый тип образа — отдельный target:

```bash
# Собрать один слой
make build TYPE=vendor-base OS=ubuntu VERSION=24.04 ENV=staging
make build TYPE=org-base    OS=ubuntu VERSION=24.04 ENV=staging
make build TYPE=org-golden  OS=ubuntu VERSION=24.04 ENV=staging

# Собрать всю цепочку (все три слоя, legacy + UEFI)
make build-chain OS=ubuntu VERSION=24.04 ENV=staging

# Только RHEL 9.6 production, только legacy BIOS
make build-chain OS=rhel VERSION=9.6 ENV=production UEFI=false
```

`make build-chain` — полноценный Makefile-target, который последовательно
вызывает `vendor-base` → `org-base` → `org-golden`, останавливаясь при
первой ошибке. Логи пишутся автоматически с тайм-штампом в `logs/`.

Полный набор chain-операций симметричен:

```bash
make build-chain  OS=ubuntu VERSION=24.04 ENV=staging   # собрать все три слоя
make upload-chain OS=ubuntu VERSION=24.04 ENV=staging STORAGE=artifactory  # залить все три
make remove-chain OS=ubuntu VERSION=24.04 ENV=staging   # удалить локально все три
```

Вспомогательные targets для повседневной работы:

```bash
make show-local-boxes          # список собранных .box в builds/
make show-remote-boxes         # список образов в Artifactory / S3
make fetch   TYPE=org-golden   # скачать последний образ
make upload  TYPE=org-golden   # загрузить в хранилище
make test    TYPE=org-golden   # smoke-тест
make ssh     TYPE=org-golden   # зайти внутрь box по SSH (для отладки)
```

Три уровня очистки:

```bash
make clean-env     # убить stale libvirt-домены и vagrant-tmp
make clean-builds  # clean-env + удалить builds/ и logs/
make clean         # полная очистка включая .vagrant.d
```

---

## Среда сборки: Docker + Packer + Vagrant + Ansible

Один из нетривиальных выборов — Packer и Vagrant запускаются _внутри Docker-контейнера_,
который монтирует KVM-устройство и libvirt-сокет.

Это решает две проблемы:

1. **Воспроизводимость**: версии Packer, Vagrant и Ansible прибиты в `Dockerfile`,
   результат не зависит от того, что установлено на машине разработчика.
2. **CI/CD-совместимость**: GitHub Actions runner с вложенной виртуализацией (KVM)
   запускает тот же контейнер — ноль расхождений с локальной средой.

```bash
docker run --privileged --device /dev/kvm \
  -v /var/lib/libvirt:/var/lib/libvirt:rw \
  -v /var/run/libvirt:/var/run/libvirt:rw \
  packer-image make build TYPE=vendor-base OS=ubuntu VERSION=24.04
```

**Место Ansible в этой схеме.** Ansible используется **только для `org-golden`**.
Packer поднимает гостевую VM через Vagrant, а затем запускает стандартный
`ansible` provisioner: Packer сам устанавливает SSH-соединение к гостю
и выполняет playbook **с хоста** — никакого `ansible-local`, никакого
ручного inventory.

`org-base` провизионируется иначе — набором **shell-скриптов** (OS-специфичный
скрипт + общие: `sudoers.sh`, `fix_time.sh`, `sshd.sh`, `system.sh`, `setup.sh`).
Это намеренно: shell-скрипты проще отлаживать на этом уровне, а Ansible
подключается уже поверх готовой корпоративной базы в `org-golden`.

Роль `company.example` покрывает только `org-golden`, vars-файлы
параметризованы по ОС и версии: `ubuntu-24.04.yml`, `rhel-9.6.yml`.

---

## Smoke-тест: проверяем образ перед публикацией

Перед загрузкой в Artifactory каждый `.box` проходит автоматический smoke-тест:

1. Импортировать box в libvirt
2. Поднять VM через `vagrant up`
3. Зайти по SSH, прочитать `/etc/box-release` — файл с метаданными образа
4. Убедиться, что версия ОС, слой и тайм-штамп совпадают с ожидаемыми
5. Уничтожить VM

Если тест не прошёл — образ не публикуется.

---

## Именование и версионирование: имя файла — источник правды

Имя файла несёт всю мета-информацию, в том числе определяющую тип образа:

```
ubuntu-24.04-production-uefi-org-golden-20260316.2144.box
```

Python-парсер в `common.py` разбирает имя на поля:

```python
meta = parse_box_filename(box_path.name)
# → BoxMeta(os='ubuntu', version='24.04', env='production',
#           boot='uefi', box_type='org-golden', timestamp='20260316.2144')
```

Timestamp формата `YYYYMMDD.HHMM` позволяет:
* Сортировать файлы хронологически без дополнительной базы
* Легко искать образы за конкретную дату
* Чётко понимать, что «старее» при откате

---

## Добавление и удаление ОС

Самый частый запрос: «нам нужен AlmaLinux 9.8» или «добавьте Ubuntu 26.04».

```bash
# Добавить новую ОС на основе существующего шаблона
make add-new-os OS=rhel VERSION=9.8 FROM=rhel-9.6

# Посмотреть что будет создано, ничего не трогая
DRY_RUN=1 make add-new-os OS=rhel VERSION=9.8 FROM=rhel-9.6

# Удалить ОС из шаблонов
make remove-os OS=rhel VERSION=9.8
```

`make add-new-os` под капотом:
1. Копируется `templates/vendor-base/rhel-9.6/` → `rhel-9.8/`
2. Все вхождения `9.6` в текстовых файлах заменяются на `9.8`
3. Создаются `templates/org-base/rhel-9.8.json` и `templates/org-golden/rhel-9.8.json`
4. Копируются Ansible vars-файлы `roles/*/vars/rhel-9.6.yml` → `rhel-9.8.yml`
5. Печатаются следующие шаги: обновить URL ISO, checksum, kickstart

`make remove-os` — симметричная операция: удаляет все три группы файлов
(`vendor-base/`, `org-base/*.json`, `org-golden/*.json`, ansible vars)
без риска случайно задеть другие версии.

Оба инструмента идемпотентны: повторный запуск не перезапишет файлы,
которые уже были изменены вручную.

---

## Загрузка в хранилище: Artifactory или S3

`scripts/upload.py` поддерживает два бэкенда:

```bash
# загрузить в Artifactory
STORAGE=artifactory BOX_FILE=builds/ubuntu-24.04-staging-org-golden-*.box make upload

# загрузить в S3
STORAGE=s3 S3_BUCKET=my-boxes BOX_FILE=... make upload
```

После загрузки рядом с `.box` создаётся `.meta.json` — sidecar-файл с SHA-256,
именем источника (`based_on`), тайм-штампом и URL. Это позволяет скриптам
`resolve-box.py` и `fetch-box.py` находить и скачивать нужный образ без
перебора файлов вручную.

---

## CI/CD через GitHub Actions

Два workflow:

**`validate.yml`** — запускается на каждый PR:
* Проверяет синтаксис Packer-шаблонов (`packer validate`)
* Запускает линтер Ansible
* Прогоняет unit-тесты Python-скриптов

**`build.yml`** — запускается при мерже в `main` или по расписанию (ночью):
* Собирает полный конвейер для всех поддерживаемых ОС
* Публикует образы в Artifactory
* Уведомляет при ошибке

---

## Что получилось в итоге

За несколько месяцев использования:

* **Воспроизводимые образы**: один и тот же `make build` даёт одинаковый результат
  на любой машине с KVM
* **Быстрый онбординг**: новый разработчик поднимает полностью настроенную VM
  за `vagrant up` — 3–5 минут вместо нескольких часов ручной настройки
* **Безопасный rollback**: поменять тайм-штамп в имени box — и вы на предыдущей версии
* **Ясная ответственность**: vendor-base = безопасность, org-base = инфраструктура,
  org-golden = разработчики
* **Простое добавление ОС**: одна команда, ревью двух файлов, один PR

---

## Что можно улучшить

* Переехать с JSON-шаблонов Packer на **HCL2** — более читабельно и поддерживает модули
* Добавить **SBOM** (Software Bill of Materials) для каждого образа
* Реализовать **diff между версиями** — что изменилось в списке пакетов между двумя тайм-штампами
* Поддержка **Windows Server** — тот же трёхслойный подход, но с `unattend.xml`
* Кеширование ISO в Artifactory, чтобы не ходить за ним каждый раз во внешний репозиторий

---

## Итог

Фабрика VM-образов — это не rocket science. Это дисциплина: чёткое разделение
ответственности между слоями, воспроизводимая среда сборки и автоматическая
проверка перед публикацией. Именно эта комбинация превращает «у меня работает»
в «у нас работает».

---

_Если делаете что-то похожее или столкнулись с другим подходом — пишите в комментарии.
Особенно интересен опыт с Bottlerocket/Flatcar как vendor-base и с использованием
image-builder от Kubernetes SIG._
