#!/bin/sh -eux
# Per-OS sudoers setup is done in vendor-base/*/scripts/sudoers.sh.
# org-base adds: Defaults !secure_path in rhel.sh (via sed).
# Nothing to do here at the _common level.
