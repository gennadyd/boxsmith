# =============================================================================
# Vagrant image builder
# =============================================================================
#
#  Pipeline:  vendor-base -> org-base -> org-golden
#  OS:        ubuntu-24.04   rhel-9.6
#
#  Quick start:
#    make build        TYPE=vendor-base OS=ubuntu VERSION=24.04
#    make build        TYPE=org-base    OS=ubuntu VERSION=24.04
#    make build        TYPE=org-golden  OS=ubuntu VERSION=24.04
#    make build-chain  OS=ubuntu VERSION=24.04 ENV=staging
#    make test         TYPE=org-golden  OS=ubuntu VERSION=24.04
#    make upload       TYPE=org-golden  OS=ubuntu VERSION=24.04 STORAGE=artifactory
# =============================================================================

-include config.env
export

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

# =============================================================================
# ── Parameters ───────────────────────────────────────────────────────────────
# =============================================================================

OS          ?= ubuntu       # ubuntu | rhel
VERSION     ?= 24.04        # 24.04  | 9.6
TYPE        ?= org-golden   # vendor-base | org-base | org-golden
ENV         ?= staging      # staging | production | testing
UEFI        ?= false        # true | false
SOURCE      ?= local        # local | remote
STORAGE     ?=              # artifactory | s3  (required when SOURCE=remote or uploading)
BOX         ?=              # override box filename for test/ssh/upload
UPLOAD      ?= false        # auto-upload after build
FROM        ?= iso          # iso | /path.iso | https://… | artifactory | s3 | vagrant-cloud-slug
FORMAT      ?= short        # short | json  (for show-*-boxes)

PACKER_IMAGE         ?= packer-vagrant
PACKER_VER           ?= 1.11.1
QEMU_PLUGIN_VER      ?= 1.1.0
VAGRANT_PLUGIN_VER   ?= 1.1.5
TIMEZONE             ?= Asia/Jerusalem
TEST_MEM             ?= 2048
TEST_CPUS            ?= 2
TEST_BOOT_TIMEOUT    ?= 600

# =============================================================================
# ── Derived variables ────────────────────────────────────────────────────────
# =============================================================================

BUILDS_DIR    = $(CURDIR)/builds
LOGS_DIR      = $(CURDIR)/logs
ISO_CACHE_DIR = $(CURDIR)/.packer-cache

UEFI_SUFFIX  = $(if $(filter true,$(UEFI)),-uefi,)
OS_VERSION   = $(OS)-$(VERSION)-$(ENV)$(UEFI_SUFFIX)
BUILD_TS    := $(shell date +"%Y%m%d.%H%M")
BOX_FILE     = $(BUILDS_DIR)/$(OS_VERSION)-$(TYPE)-$(BUILD_TS).box
IMAGE_FILE   = templates/$(TYPE)/$(OS)-$(VERSION).json

# Log files
_VENDOR_LOG    = $(LOGS_DIR)/$(OS_VERSION)-vendor-base-$(BUILD_TS).log
_VENDOR_SERIAL = $(LOGS_DIR)/$(OS_VERSION)-vendor-base-$(BUILD_TS).serial.log
_BUILD_LOG     = $(LOGS_DIR)/$(OS_VERSION)-$(TYPE)-$(BUILD_TS).log

# FROM= handling for vendor-base
_VENDOR_SOURCE    = $(FROM)
_FROM_IS_ISO_SRC  = $(or $(filter /%,$(FROM)),$(filter http%,$(FROM)))
_IS_ISO           = $(or $(filter iso,$(FROM)),$(_FROM_IS_ISO_SRC))
_ISO_MIRROR       = $(patsubst %/,%,$(dir $(FROM)))
_ISO_NAME         = $(notdir $(FROM))
_ISO_CUSTOM_VARS  = -var mirror=$(_ISO_MIRROR) -var iso_name=$(_ISO_NAME) -var mirror_directory= -var iso_checksum=none
_VENDOR_BUILDER   = $(if $(_IS_ISO),iso,box)-$(if $(filter true,$(UEFI)),uefi,legacy)
_VENDOR_EXTRA_VARS = \
	$(if $(_IS_ISO),,-var source_path=$(_VENDOR_SOURCE)) \
	$(if $(_FROM_IS_ISO_SRC),$(_ISO_CUSTOM_VARS)) \
	$(if $(filter-out iso artifactory s3,$(FROM)),$(if $(_FROM_IS_ISO_SRC),,-var box_src_name=$(FROM))) \
	-var serial_log=$(or $(SERIAL_LOG),$(_VENDOR_SERIAL))

# Source box for org-base / org-golden
_PREV_TYPE  = $(if $(filter org-golden,$(TYPE)),org-base,vendor-base)
_LOCAL_BOX  = $(lastword $(sort $(wildcard $(BUILDS_DIR)/$(OS_VERSION)-$(_PREV_TYPE)-*.box)))

LIBVIRT_GID = $(shell getent group libvirt | cut -d: -f3)

# =============================================================================
# ── Docker run wrapper ───────────────────────────────────────────────────────
# =============================================================================

VAGRANT_RUN = docker run -ti --rm --privileged --network host \
	-u 0 \
	-e USER_UID=0 \
	-e USER_GID=0 \
	--device /dev/kvm \
	--group-add $(LIBVIRT_GID) \
	-v /var/lib/libvirt:/var/lib/libvirt:rw \
	-v /var/run/libvirt:/var/run/libvirt:rw \
	-v /etc/localtime:/etc/localtime:ro \
	-v $(BUILDS_DIR):$(BUILDS_DIR):ro \
	-v $(CURDIR)/templates:$(CURDIR)/templates:ro \
	-v ~/.vagrant.d:/.vagrant.d \
	-e IGNORE_MISSING_LIBVIRT_SOCK=1 \
	-e IGNORE_RUN_AS_ROOT=1 \
	$(PACKER_IMAGE)

# =============================================================================
# ── Guard macros ─────────────────────────────────────────────────────────────
# =============================================================================

# $(call require,VAR,hint)
define require
	@[ -n "$($(1))" ] || { echo "ERROR: $(1) not set -- $(2)"; exit 1; }
endef

# $(call require-file,PATH)
define require-file
	@[ -f "$(1)" ] || { echo "ERROR: $(1) not found"; exit 1; }
endef

# $(call require-one-of,VAR,val1|val2|...)
define require-one-of
	@echo "$($(1))" | grep -qwE "$(2)" || { echo "ERROR: $(1)=$($(1)) is not one of: $(2)"; exit 1; }
endef

# =============================================================================
# ── Virsh cleanup macros ─────────────────────────────────────────────────────
# =============================================================================

# $(call virsh-clean-domains,GREP_PATTERN)
define virsh-clean-domains
	@for dom in $$(sudo virsh list --all --name 2>/dev/null | grep -E '$(1)' || true); do \
		echo "  [virsh] destroy: $$dom"; \
		sudo virsh destroy  "$$dom" 2>/dev/null || true; \
		sudo virsh undefine "$$dom" --remove-all-storage 2>/dev/null \
			|| sudo virsh undefine "$$dom" --nvram 2>/dev/null \
			|| sudo virsh undefine "$$dom" 2>/dev/null || true; \
	done
endef

# $(call virsh-clean-volumes,GREP_PATTERN)
define virsh-clean-volumes
	@sudo virsh vol-list default 2>/dev/null \
		| awk 'NR>2 && NF>=2 && $$1 ~ /$(1)/{print $$1}' \
		| xargs -I{} sudo virsh vol-delete {} default 2>/dev/null || true
endef

# =============================================================================
# ── .PHONY ───────────────────────────────────────────────────────────────────
# =============================================================================

.PHONY: help
.PHONY: build _build _build-vendor-base build-chain
.PHONY: upload upload-chain remove-chain
.PHONY: test ssh
.PHONY: clean clean-builds clean-env
.PHONY: show-local-boxes show-remote-boxes
.PHONY: show-local-boxes-ubuntu show-local-boxes-rhel show-local-boxes-json
.PHONY: show-remote-boxes-ubuntu show-remote-boxes-rhel show-remote-boxes-s3 show-remote-boxes-json
.PHONY: add-new-os remove-os docker-build docker-push

# =============================================================================
# ── help ─────────────────────────────────────────────────────────────────────
# =============================================================================

help:
	@echo ""
	@echo "  Pipeline:  vendor-base -> org-base -> org-golden"
	@echo ""
	@echo "  Parameters:"
	@echo "    TYPE     vendor-base | org-base | org-golden"
	@echo "    OS       ubuntu | rhel"
	@echo "    VERSION  24.04 | 9.6"
	@echo "    UEFI     true | false                   (default: false)"
	@echo "    ENV      staging | production | testing  (default: staging)"
	@echo "    SOURCE   local | remote                  (default: local)"
	@echo "    STORAGE  artifactory | s3               (required when SOURCE=remote)"
	@echo "    FROM     iso                            vendor-base: build from ISO (default, ~30min)"
	@echo "             /path/to.iso | https://...     vendor-base: local/remote ISO"
	@echo "             artifactory | s3               vendor-base: reuse latest from storage"
	@echo "             <vagrant-cloud-slug>           vendor-base: pull from Vagrant Cloud (~3min)"
	@echo "                                              e.g. FROM=almalinux/9"
	@echo ""
	@echo "  Build:"
	@echo "    make build       TYPE=vendor-base OS=ubuntu VERSION=24.04"
	@echo "    make build       TYPE=vendor-base OS=rhel   VERSION=9.6  FROM=almalinux/9"
	@echo "    make build       TYPE=org-base    OS=ubuntu VERSION=24.04"
	@echo "    make build       TYPE=org-golden  OS=ubuntu VERSION=24.04 ENV=production"
	@echo "    make build-chain OS=ubuntu VERSION=24.04 ENV=staging"
	@echo ""
	@echo "  Test / SSH:"
	@echo "    make test  TYPE=org-golden OS=ubuntu VERSION=24.04"
	@echo "    make test  BOX=ubuntu-24.04-staging-org-golden-20260315.1230.box"
	@echo "    make ssh   TYPE=org-golden OS=rhel VERSION=9.6 SOURCE=remote STORAGE=artifactory"
	@echo ""
	@echo "  Upload:"
	@echo "    make upload       TYPE=org-golden OS=ubuntu VERSION=24.04 STORAGE=artifactory"
	@echo "    make upload-chain OS=ubuntu VERSION=24.04 STORAGE=artifactory"
	@echo ""
	@echo "  Boxes:"
	@echo "    make show-local-boxes  [OS=ubuntu] [ENV=staging] [FORMAT=json]"
	@echo "    make show-remote-boxes STORAGE=artifactory [OS=ubuntu]"
	@echo ""
	@echo "  Maintenance:"
	@echo "    make clean-env     -- remove stale libvirt domains/volumes/vagrant boxes/tmp"
	@echo "    make clean-builds  -- clean-env + delete built .box and .meta.json files"
	@echo "    make clean         -- clean-builds + wipe .vagrant.d"
	@echo "    make remove-chain  OS=ubuntu VERSION=24.04 ENV=staging"
	@echo "    make add-new-os    OS=<os> VERSION=<ver> FROM=<existing-os-ver>"
	@echo "    make remove-os     OS=<os> VERSION=<ver>"
	@echo "    make docker-build"
	@echo ""
	@echo "  Troubleshoot:"
	@echo "    ./scripts/troubleshoot.sh           -- host status"
	@echo "    ./scripts/troubleshoot.sh --clean   -- interactive stale resource cleanup"
	@echo "    ./scripts/troubleshoot.sh --vnc     -- open noVNC to active build"
	@echo ""

# =============================================================================
# ── build ────────────────────────────────────────────────────────────────────
# =============================================================================

build:
	$(call require,TYPE,vendor-base|org-base|org-golden)
	$(call require,OS,ubuntu|rhel)
	$(call require,VERSION,24.04|9.6)
	$(call require-one-of,TYPE,vendor-base|org-base|org-golden)
	@case "$(TYPE)" in \
		vendor-base)         $(MAKE) _build-vendor-base ;; \
		org-base|org-golden) $(MAKE) _build ;; \
	esac

_build-vendor-base:
	$(if $(filter artifactory s3,$(FROM)),$(eval _VENDOR_SOURCE := $(shell \
		set -a && source $(CURDIR)/config.env && set +a && \
		TYPE=vendor-base OS=$(OS) VERSION=$(VERSION) UEFI=$(UEFI) STORAGE=$(FROM) \
		python3 $(CURDIR)/scripts/fetch-box.py 2>/dev/null)))
	$(if $(filter artifactory s3,$(FROM)),$(if $(_VENDOR_SOURCE),,$(error ERROR: no vendor-base box found on $(FROM) for $(OS_VERSION))))
	@echo "==> vendor-base: $(OS)-$(VERSION) uefi=$(UEFI) from=$(FROM)"
	@mkdir -p $(ISO_CACHE_DIR) $(LOGS_DIR) $(BUILDS_DIR)
	$(call virsh-clean-domains,output-(iso|box)-(legacy|uefi)_source)
	$(call virsh-clean-volumes,output-(iso|box)-(legacy|uefi)_source)
	@docker rm -f packer-$(OS_VERSION)-kvm 2>/dev/null || true
	@# Fix vagrant box virtual_size if reported in bytes
	@if [ -z '$(_IS_ISO)' ] && [ '$(FROM)' != 'artifactory' ] && [ '$(FROM)' != 's3' ]; then \
		BOX_SLUG=$$(echo '$(FROM)' | sed 's|/|-VAGRANTSLASH-|'); \
		for meta in $$HOME/.vagrant.d/boxes/$$BOX_SLUG/*/libvirt/metadata.json; do \
			[ -f '$$meta' ] || continue; \
			sudo chown '$$USER' '$$meta' 2>/dev/null || true; \
			METAPATH='$$meta' python3 -c \
				"import json,os,pathlib; p=pathlib.Path(os.environ['METAPATH']); \
				d=json.loads(p.read_text()); vs=d.get('virtual_size',0); \
				(d.update({'virtual_size':vs//1073741824}), p.write_text(json.dumps(d)), \
				print('fixed virtual_size: {} -> {} GiB'.format(vs,vs//1073741824))) \
				if vs>1073741824 else print('virtual_size ok: {} GiB'.format(vs))"; \
		done; \
	fi
	@# UEFI: prepare fresh efivars
	@if [ '$(UEFI)' = 'true' ]; then \
		echo '==> Preparing efivars.fd...'; \
		docker run --rm \
			-v ~/.vagrant.d:/.vagrant.d \
			-v $(CURDIR)/templates/vendor-base/$(OS)-$(VERSION):/out \
			-e IGNORE_MISSING_LIBVIRT_SOCK=1 -e IGNORE_RUN_AS_ROOT=1 \
			$(PACKER_IMAGE) bash -c \
				'cp /usr/share/OVMF/OVMF_VARS_4M.fd /out/efivars.fd && chmod 644 /out/efivars.fd'; \
	fi
	docker run --rm --privileged --device /dev/kvm --network host \
		-v ~/.vagrant.d:/.vagrant.d \
		-v /var/lib/libvirt:/var/lib/libvirt:rw \
		-v /var/run/libvirt:/var/run/libvirt:rw \
		--group-add $(LIBVIRT_GID) \
		-v $(CURDIR):$(CURDIR):rw \
		-v $(ISO_CACHE_DIR):/home/vagrant/.cache/packer \
		-e PACKER_PLUGIN_PATH=/usr/local/share/packer/plugins \
		-e PACKER_LOG=1 -e VAGRANT_LOG=debug \
		-e IGNORE_MISSING_LIBVIRT_SOCK=1 -e IGNORE_RUN_AS_ROOT=1 \
		-e USER_UID=0 -e USER_GID=0 \
		-w $(CURDIR)/templates/vendor-base/$(OS)-$(VERSION) \
		--name packer-$(OS_VERSION)-kvm \
		$(PACKER_IMAGE) packer build -timestamp-ui -force -only=$(_VENDOR_BUILDER) \
			-var box_basename=$(OS_VERSION)-vendor-base \
			$(_VENDOR_EXTRA_VARS) \
			packer.json \
		2>&1 | tee $(_VENDOR_LOG)
	@echo "==> Build log: $(_VENDOR_LOG)"
	@DST='$(BUILDS_DIR)/$(OS_VERSION)-vendor-base-$(BUILD_TS).box'; \
	case '$(FROM)' in iso|/*|http*) \
		SRC='$(BUILDS_DIR)/$(OS_VERSION)-vendor-base.libvirt.box' ;; \
	*) \
		SRC='$(CURDIR)/templates/vendor-base/$(OS)-$(VERSION)/box' ;; \
	esac; \
	[ -f '$$SRC' ] || { echo 'ERROR: packer did not produce $$SRC'; exit 1; }; \
	sudo mv '$$SRC' '$$DST'; \
	sudo chown $$(id -u):$$(id -g) '$$DST'; \
	echo '==> Built: '$$DST
	@python3 -c \
		"import json,pathlib; \
		f=pathlib.Path('$(BUILDS_DIR)/$(OS_VERSION)-vendor-base-$(BUILD_TS).box'); \
		p=f.with_suffix('.meta.json'); \
		p.write_text(json.dumps({'name':f.name,'env':'$(ENV)','type':'vendor-base', \
		'os':'$(OS)','version':'$(VERSION)','timestamp':'$(BUILD_TS)', \
		'based-on':'$(FROM)','uploaded-to':[]},indent=2)); \
		print('==> Meta:',p)" 2>/dev/null || true

_build:
	$(call require-file,config.env)
	$(eval _SOURCE_BOX := $(or $(SOURCE_BOX),$(_LOCAL_BOX),$(shell \
		set -a && source $(CURDIR)/config.env && set +a && \
		TYPE=$(_PREV_TYPE) OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) UEFI=$(UEFI) STORAGE=$(STORAGE) \
		python3 $(CURDIR)/scripts/fetch-box.py 2>/dev/null)))
	@[ -n "$(_SOURCE_BOX)" ] || { \
		echo "ERROR: no source box for $(_PREV_TYPE) $(OS_VERSION)"; \
		echo "       run: make build TYPE=$(_PREV_TYPE)  or set SOURCE_BOX="; \
		exit 1; }
	@echo "==> $(TYPE): $(OS_VERSION)"
	@echo "    Source : $(_SOURCE_BOX)"
	$(call virsh-clean-domains,^output-vagrant-)
	$(call virsh-clean-volumes,^output-vagrant-)
	@rm -rf output-vagrant-*
	docker run -t --rm --privileged --network host \
		-v /var/lib/libvirt:/var/lib/libvirt:rw \
		-v /var/run/libvirt:/var/run/libvirt:rw \
		--device /dev/kvm \
		--group-add $(LIBVIRT_GID) \
		-v /etc/localtime:/etc/localtime:ro \
		-v $(CURDIR)/.vagrant.d:/.vagrant.d \
		-v $(CURDIR):$(CURDIR) \
		-w $(CURDIR) \
		--env-file config.env \
		-e PACKER_PLUGIN_PATH=/usr/local/share/packer/plugins \
		$(PACKER_IMAGE) \
		packer build \
			-timestamp-ui -force \
			-only=vagrant-$(TYPE) \
			-var-file=templates/_common/packer.json \
			-var-file=$(IMAGE_FILE) \
			-var box_type=$(TYPE) \
			-var box_os_version=$(VERSION) \
			-var box_version=$(BUILD_TS) \
			-var name=$(OS_VERSION) \
			-var source_path=$(_SOURCE_BOX) \
			templates/packer-template.json \
		2>&1 | tee $(_BUILD_LOG)
	@echo "==> Build log: $(_BUILD_LOG)"
	@[ -f box ] || { echo "ERROR: packer did not produce a box file"; exit 1; }
	@mkdir -p $(BUILDS_DIR)
	mv box $(BOX_FILE)
	@echo "==> Built: $(BOX_FILE)"
	@python3 -c \
		"import json,pathlib; \
		f=pathlib.Path('$(BOX_FILE)'); \
		p=f.with_suffix('.meta.json'); \
		src=pathlib.Path('$(_SOURCE_BOX)').name if '$(_SOURCE_BOX)' else ''; \
		p.write_text(json.dumps({'name':f.name,'env':'$(ENV)','type':'$(TYPE)', \
		'os':'$(OS)','version':'$(VERSION)','timestamp':'$(BUILD_TS)', \
		'based-on':src,'uploaded-to':[]},indent=2)); \
		print('==> Meta:',p)" 
	@if [ "$(UPLOAD)" = "true" ]; then $(MAKE) upload TYPE=$(TYPE) ENV=$(ENV); fi

# =============================================================================
# ── Chain targets ────────────────────────────────────────────────────────────
# =============================================================================

build-chain:
	$(call require,OS,ubuntu|rhel)
	$(call require,VERSION,24.04|9.6)
	@echo "==> build-chain: $(OS)-$(VERSION) env=$(ENV) uefi=$(UEFI) from=$(FROM)"
	$(MAKE) build TYPE=vendor-base OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) UEFI=$(UEFI) FROM=$(FROM)
	$(MAKE) build TYPE=org-base    OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) UEFI=$(UEFI)
	$(MAKE) build TYPE=org-golden  OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) UEFI=$(UEFI)
	@echo "==> build-chain DONE: $(OS)-$(VERSION) env=$(ENV)"

upload-chain:
	$(call require,OS,ubuntu|rhel)
	$(call require,VERSION,24.04|9.6)
	$(call require,STORAGE,artifactory|s3)
	@echo "==> upload-chain: $(OS)-$(VERSION) env=$(ENV) storage=$(STORAGE)"
	$(MAKE) upload TYPE=vendor-base OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) UEFI=$(UEFI) STORAGE=$(STORAGE)
	$(MAKE) upload TYPE=org-base    OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) UEFI=$(UEFI) STORAGE=$(STORAGE)
	$(MAKE) upload TYPE=org-golden  OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) UEFI=$(UEFI) STORAGE=$(STORAGE)
	@echo "==> upload-chain DONE: $(OS)-$(VERSION) storage=$(STORAGE)"

remove-chain:
	$(call require,OS,ubuntu|rhel)
	$(call require,VERSION,24.04|9.6)
	@echo "==> remove-chain: $(OS_VERSION)"
	@rm -fv \
		$(BUILDS_DIR)/$(OS_VERSION)-vendor-base-*.box \
		$(BUILDS_DIR)/$(OS_VERSION)-vendor-base-*.meta.json \
		$(BUILDS_DIR)/$(OS_VERSION)-org-base-*.box \
		$(BUILDS_DIR)/$(OS_VERSION)-org-base-*.meta.json \
		$(BUILDS_DIR)/$(OS_VERSION)-org-golden-*.box \
		$(BUILDS_DIR)/$(OS_VERSION)-org-golden-*.meta.json 2>/dev/null || true
	@echo "==> Done"

# =============================================================================
# ── clean ────────────────────────────────────────────────────────────────────
# =============================================================================

clean-env:
	@echo "==> clean-env: stale libvirt / vagrant / tmp"
	$(call virsh-clean-domains,output-(iso|box|vagrant)-|^(smoke|sshtest)-)
	$(call virsh-clean-volumes,output-(iso|box|vagrant)-|(smoke|sshtest)-)
	@sudo rm -rf output-iso-* output-box-* output-vagrant-*
	@docker run --rm -u 0 \
		-e IGNORE_RUN_AS_ROOT=1 -e IGNORE_MISSING_LIBVIRT_SOCK=1 \
		-v ~/.vagrant.d:/.vagrant.d \
		$(PACKER_IMAGE) \
		bash -c 'vagrant box list 2>/dev/null \
			| awk \'NR==1{next} /^(smoke|sshtest)-/{print $$1}\' \
			| xargs -I{} vagrant box remove {} --provider libvirt 2>/dev/null || true' \
		2>/dev/null || true
	@echo "==> Clearing ~/.vagrant.d/tmp ..."
	@rm -rf ~/.vagrant.d/tmp/* 2>/dev/null || true
	@echo "==> Done"

clean-builds: clean-env
	@rm -rf $(BUILDS_DIR)/*.box
	@rm -rf $(BUILDS_DIR)/*.meta.json
	@rm -rf $(LOGS_DIR)/*.log
	@echo "==> builds/ and logs/ cleared"

clean: clean-builds
	rm -rf .vagrant.d && mkdir -p .vagrant.d/{boxes,data,tmp}
	rm -rf output-iso-* output-box-*
	sudo rm -f box
	@echo "==> full clean done"

# =============================================================================
# ── upload ───────────────────────────────────────────────────────────────────
# =============================================================================

upload:
	$(call require,STORAGE,artifactory|s3)
	$(eval _UPLOAD_BOX := $(if $(BOX),$(BUILDS_DIR)/$(BOX),$(lastword $(sort $(wildcard $(BUILDS_DIR)/$(OS_VERSION)-$(TYPE)-*.box)))))
	@[ -n "$(_UPLOAD_BOX)" ] || { \
		echo "ERROR: no box found for $(OS_VERSION)-$(TYPE) (set BOX= or build first)"; \
		exit 1; }
	$(call require-file,$(_UPLOAD_BOX))
	@mkdir -p $(LOGS_DIR)
	$(eval _UPLOAD_LOG := $(LOGS_DIR)/upload-$(basename $(notdir $(_UPLOAD_BOX)))-$(STORAGE).log)
	@echo "==> Upload: $(_UPLOAD_BOX)"
	@echo "==> Log:    $(_UPLOAD_LOG)"
	@BASED_ON=$$(python3 -c \
			"import json,pathlib; \
			p=pathlib.Path('$(_UPLOAD_BOX)').with_suffix('.meta.json'); \
			d=json.loads(p.read_text()) if p.exists() else {}; \
			print(d.get('based-on',''))" 2>/dev/null) \
		BOX_FILE=$(_UPLOAD_BOX) OS=$(OS) VERSION=$(VERSION) ENV=$(ENV) TYPE=$(TYPE) UEFI=$(UEFI) \
		STORAGE=$(STORAGE) \
		python3 $(CURDIR)/scripts/upload.py 2>&1 | tee $(_UPLOAD_LOG)

# =============================================================================
# ── test / ssh ───────────────────────────────────────────────────────────────
# =============================================================================

# Shared box resolution -- populates _RESOLVED_BOX
define _resolve-box
$(eval _RESOLVED_BOX := $(shell \
	set -a && source $(CURDIR)/config.env 2>/dev/null && set +a && \
	SOURCE=$(SOURCE) BOX=$(BOX) TYPE=$(TYPE) OS=$(OS) VERSION=$(VERSION) \
	UEFI=$(UEFI) STORAGE=$(STORAGE) BUILDS_DIR=$(BUILDS_DIR) ENV=$(ENV) \
	python3 $(CURDIR)/scripts/resolve-box.py 2>/dev/null))
endef

test:
	$(call _resolve-box)
	@[ -n "$(_RESOLVED_BOX)" ] || { echo "ERROR: no box found -- set BOX= or SOURCE=remote STORAGE="; exit 1; }
	$(call require-file,$(_RESOLVED_BOX))
	@BOX_FILE=$(_RESOLVED_BOX) BUILDS_DIR=$(BUILDS_DIR) LOGS_DIR=$(LOGS_DIR) \
		TEST_MEM=$(TEST_MEM) TEST_CPUS=$(TEST_CPUS) TEST_BOOT_TIMEOUT=$(TEST_BOOT_TIMEOUT) \
		PACKER_IMAGE=$(PACKER_IMAGE) LIBVIRT_GID=$(LIBVIRT_GID) \
		python3 $(CURDIR)/scripts/test-box.py

ssh:
	$(call _resolve-box)
	@[ -n "$(_RESOLVED_BOX)" ] || { echo "ERROR: no box found -- set BOX= or SOURCE=remote STORAGE="; exit 1; }
	$(eval _NAME := sshtest-$(basename $(notdir $(_RESOLVED_BOX))))
	@echo "==> SSH into $(_RESOLVED_BOX)  (exit to destroy)"
	$(VAGRANT_RUN) bash -c " \
		vagrant box add --force --name $(_NAME) $(_RESOLVED_BOX) --provider libvirt && \
		mkdir -p /tmp/vm && cd /tmp/vm && \
		sed 's/BOX_NAME/$(_NAME)/' $(CURDIR)/templates/ssh/Vagrantfile.tpl > Vagrantfile && \
		vagrant up --provider libvirt && \
		vagrant ssh; \
		vagrant destroy -f; \
		vagrant box remove $(_NAME) --provider libvirt || true; \
		sudo virsh vol-list default 2>/dev/null \
			| awk 'NR>2 && NF && \$$1 ~ /$(_NAME)/{print \$$1}' \
			| xargs -I{} sudo virsh vol-delete {} default 2>/dev/null || true"

# =============================================================================
# ── show boxes ───────────────────────────────────────────────────────────────
# =============================================================================

_FILTER_OS  = $(if $(filter command line,$(origin OS)),$(OS),)
_FILTER_ENV = $(if $(filter command line,$(origin ENV)),$(ENV),)

show-local-boxes:
	@SOURCE=local FORMAT=$(FORMAT) FILTER_OS="$(_FILTER_OS)" FILTER_ENV="$(_FILTER_ENV)" \
		BUILDS_DIR=$(BUILDS_DIR) python3 $(CURDIR)/scripts/show-boxes.py

show-remote-boxes:
	$(call require,STORAGE,artifactory|s3)
	@SOURCE=remote FORMAT=$(FORMAT) FILTER_OS="$(_FILTER_OS)" FILTER_ENV="$(_FILTER_ENV)" \
		STORAGE=$(STORAGE) python3 $(CURDIR)/scripts/show-boxes.py

# =============================================================================
# ── OS management ────────────────────────────────────────────────────────────
# =============================================================================

add-new-os:
	$(call require,OS,e.g. OS=rhel)
	$(call require,VERSION,e.g. VERSION=9.8)
	$(call require,FROM,e.g. FROM=rhel-9.6)
	@OS=$(OS) VERSION=$(VERSION) FROM=$(FROM) \
		$(if $(ANSIBLE_NAME),ANSIBLE_NAME=$(ANSIBLE_NAME)) \
		$(if $(FROM_ANSIBLE_NAME),FROM_ANSIBLE_NAME=$(FROM_ANSIBLE_NAME)) \
		$(if $(DRY_RUN),DRY_RUN=$(DRY_RUN)) \
		python3 $(CURDIR)/scripts/add-new-os.py

remove-os:
	$(call require,OS,e.g. OS=rhel)
	$(call require,VERSION,e.g. VERSION=9.6)
	@echo "==> remove-os: $(OS)-$(VERSION)"
	rm -rf $(CURDIR)/templates/vendor-base/$(OS)-$(VERSION)
	rm -f  $(CURDIR)/templates/org-base/$(OS)-$(VERSION).json
	rm -f  $(CURDIR)/templates/org-golden/$(OS)-$(VERSION).json
	@find $(CURDIR)/templates/ansible -name "$(OS)-$(VERSION).yml" -delete -print
	@echo "==> Done"

# =============================================================================
# ── docker-build ─────────────────────────────────────────────────────────────
# =============================================================================

docker-build:
	docker build \
		--build-arg PACKER_VER=$(PACKER_VER) \
		--build-arg QEMU_PLUGIN_VER=$(QEMU_PLUGIN_VER) \
		--build-arg VAGRANT_PLUGIN_VER=$(VAGRANT_PLUGIN_VER) \
		--build-arg TIMEZONE=$(TIMEZONE) \
		-t $(PACKER_IMAGE) docker/

docker-push:
	$(call require,PACKER_IMAGE)
	docker push $(PACKER_IMAGE)

# =============================================================================
# ── Shortcuts ────────────────────────────────────────────────────────────────
# =============================================================================

show-local-boxes-ubuntu: ; $(MAKE) show-local-boxes  OS=ubuntu
show-local-boxes-rhel: ; $(MAKE) show-local-boxes  OS=rhel
show-local-boxes-json: ; $(MAKE) show-local-boxes  FORMAT=json
show-remote-boxes-ubuntu: ; $(MAKE) show-remote-boxes OS=ubuntu
show-remote-boxes-rhel: ; $(MAKE) show-remote-boxes OS=rhel
show-remote-boxes-s3: ; $(MAKE) show-remote-boxes STORAGE=s3
show-remote-boxes-json: ; $(MAKE) show-remote-boxes FORMAT=json


