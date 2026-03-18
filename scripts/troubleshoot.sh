#!/usr/bin/env bash
# troubleshoot.sh — diagnose and fix common build environment issues
#
# Usage:
#   ./scripts/troubleshoot.sh            # status overview
#   ./scripts/troubleshoot.sh --clean    # show stale resources + offer to remove
#   ./scripts/troubleshoot.sh --vnc      # open noVNC console to active build
#
# Problems addressed:
#   - Stale libvirt domains (output-*, smoke-*, sshtest-*) blocking new builds
#   - Leftover libvirt volumes eating disk space
#   - Stale vagrant boxes in ~/.vagrant.d/boxes/
#   - Disk pressure (/home at high %)
#   - VNC access to debug stuck packer/QEMU builds

set -euo pipefail

NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_WEB="/usr/share/novnc"
VAGRANT_DOT="${HOME}/.vagrant.d"
MODE="${1:-}"

RED='\e[31m'; YEL='\e[33m'; GRN='\e[32m'; CYA='\e[1;36m'; RST='\e[0m'; DIM='\e[90m'

hr()  { printf "${DIM}%s${RST}\n" "────────────────────────────────────────────────"; }
hdr() { echo; printf "${CYA}▶ %s${RST}\n" "$*"; hr; }
ok()  { printf "  ${GRN}✓${RST} %s\n" "$*"; }
warn(){ printf "  ${YEL}⚠${RST}  %s\n" "$*"; }
err() { printf "  ${RED}✗${RST} %s\n" "$*"; }

# ─────────────────────────── helpers ─────────────────────────────────────────

stale_domains() {
    sudo virsh list --all --name 2>/dev/null \
        | grep -E '^(output-(iso|box|vagrant)|smoke-|sshtest-)' || true
}

stale_volumes() {
    sudo virsh vol-list default 2>/dev/null \
        | awk 'NR>2 && NF{print $1}' \
        | grep -E '^(smoke-|sshtest-|output-|packer-)' || true
}

stale_boxes() {
    ls "${VAGRANT_DOT}/boxes/" 2>/dev/null \
        | grep -E '^(smoke-|sshtest-)' || true
}

vagrant_tmp_size() {
    du -sh "${VAGRANT_DOT}/tmp/" 2>/dev/null | awk '{print $1}'
}

vagrant_tmp_count() {
    ls "${VAGRANT_DOT}/tmp/" 2>/dev/null | wc -l | tr -d ' '
}

disk_pct() {
    df --output=pcent "$1" 2>/dev/null | tail -1 | tr -d ' %'
}

# ─────────────────────────── status ──────────────────────────────────────────

show_status() {
    hdr "Disk"
    df -h --output=source,size,used,avail,pcent,target \
        | grep -v '^tmpfs\|^devtmpfs\|^efivarfs\|^/dev/loop' \
        | column -t
    HOME_PCT=$(disk_pct /home)
    if [[ "${HOME_PCT:-0}" -ge 85 ]]; then
        echo
        warn "/home is at ${HOME_PCT}% — run --clean to free space"
    fi

    hdr "Memory & Load"
    free -h
    echo
    uptime

    hdr "Active build containers"
    CTRS=$(docker ps --format "  {{.ID}}  {{.Status}}  {{.Names}}  ({{.RunningFor}})" 2>/dev/null \
           | grep -i 'packer\|vagrant' || true)
    [[ -n "$CTRS" ]] && echo "$CTRS" || ok "none"

    hdr "QEMU processes"
    mapfile -t QLINES < <(ps aux | grep '[q]emu-system' || true)
    if [[ ${#QLINES[@]} -eq 0 ]]; then
        ok "none"
    else
        for line in "${QLINES[@]}"; do
            PID=$(awk '{print $2}' <<<"$line")
            CPU=$(awk '{print $3}' <<<"$line")
            MEM=$(awk '{print $4}' <<<"$line")
            NAME=$(grep -oP '\-name \K[^ ]+' <<<"$line" 2>/dev/null \
                   || grep -oP 'output-[a-z0-9_-]+' <<<"$line" 2>/dev/null \
                   || echo "?")
            VNC=$(grep -oP 'vnc 127\.0\.0\.1:\K[0-9]+' <<<"$line" 2>/dev/null || echo "-")
            printf "  PID=%-7s CPU=%-5s MEM=%-5s VNC=:%-3s %s\n" \
                   "$PID" "$CPU" "$MEM" "$VNC" "$NAME"
        done
    fi

    hdr "Virsh domains"
    sudo virsh list --all 2>/dev/null | grep -v '^$' | sed 's/^/  /' || ok "none"

    hdr "Virsh storage pool: default"
    sudo virsh pool-info default 2>/dev/null \
        | grep -E 'State|Capacity|Allocation|Available' | sed 's/^/  /'
    echo
    SVOLS=$(stale_volumes)
    if [[ -n "$SVOLS" ]]; then
        warn "Stale volumes (smoke/sshtest/output) — run --clean to remove:"
        while IFS= read -r v; do
            SZ=$(sudo virsh vol-info --pool default "$v" 2>/dev/null \
                 | awk '/Capacity/{print $2$3}')
            printf "    %-70s %s\n" "$v" "$SZ"
        done <<<"$SVOLS"
    else
        ok "No stale volumes"
    fi

    hdr "Stale libvirt domains"
    SDOMS=$(stale_domains)
    [[ -n "$SDOMS" ]] && { warn "Found:"; echo "$SDOMS" | sed 's/^/    /'; } || ok "none"

    hdr "Stale vagrant boxes (~/.vagrant.d/boxes)"
    SBOXES=$(stale_boxes)
    if [[ -n "$SBOXES" ]]; then
        warn "Found:"
        while IFS= read -r b; do
            SZ=$(du -sh "${VAGRANT_DOT}/boxes/${b}" 2>/dev/null | awk '{print $1}')
            printf "    %-60s %s\n" "$b" "$SZ"
        done <<<"$SBOXES"
    else
        ok "none"
    fi

    hdr "Vagrant tmp (~/.vagrant.d/tmp)"
    TMP_COUNT=$(vagrant_tmp_count)
    TMP_SIZE=$(vagrant_tmp_size)
    if [[ "${TMP_COUNT}" -gt 0 ]]; then
        warn "${TMP_COUNT} leftover file(s) from interrupted box downloads — ${TMP_SIZE}"
        echo "  (run --clean to remove)"
    else
        ok "empty"
    fi

    hdr "Active VNC displays"
    mapfile -t DISPLAYS < <(ps aux | grep '[q]emu' \
        | grep -oP 'vnc 127\.0\.0\.1:\K[0-9]+' | sort -n || true)
    if [[ ${#DISPLAYS[@]} -eq 0 ]]; then
        ok "none (no build in progress)"
    else
        for D in "${DISPLAYS[@]}"; do
            PORT=$((5900 + D))
            NAME=$(ps aux | grep '[q]emu' | grep "vnc 127.0.0.1:${D}" \
                   | grep -oP '\-name \K[^ ]+' 2>/dev/null || echo "build-${D}")
            printf "  :%-3s  port %-5s  %s\n" "$D" "$PORT" "$NAME"
        done
        echo
        printf "  ${GRN}Tip:${RST} run  %s --vnc  to open browser console\n" "$0"
    fi

    LOG_DIR="$(cd "$(dirname "$0")/.." && pwd)/logs"
    if [[ -d "$LOG_DIR" ]]; then
        hdr "Recent logs"
        ls -lt "$LOG_DIR"/*.log 2>/dev/null | head -5 \
            | awk '{printf "  %s %s  %s\n", $6, $7, $9}' || ok "none"
    fi
}

# ─────────────────────────── clean ───────────────────────────────────────────

do_clean() {
    hdr "Stale resource cleanup"

    SDOMS=$(stale_domains)
    SVOLS=$(stale_volumes)
    SBOXES=$(stale_boxes)

    TMP_COUNT=$(vagrant_tmp_count)
    if [[ -z "$SDOMS" && -z "$SVOLS" && -z "$SBOXES" && "${TMP_COUNT}" -eq 0 ]]; then
        ok "Nothing stale found — environment is clean"
        return
    fi

    # ── Domains ──────────────────────────────────────────────────────────────
    if [[ -n "$SDOMS" ]]; then
        echo
        warn "Stale libvirt domains (will be destroyed + undefined):"
        echo "$SDOMS" | sed 's/^/    /'
        read -rp "  Remove? [y/N] " ans
        if [[ "${ans,,}" == y ]]; then
            while IFS= read -r dom; do
                sudo virsh destroy  "$dom" 2>/dev/null || true
                sudo virsh undefine "$dom" --remove-all-storage 2>/dev/null || true
                ok "Removed domain: $dom"
            done <<<"$SDOMS"
        fi
    fi

    # ── Volumes ──────────────────────────────────────────────────────────────
    if [[ -n "$SVOLS" ]]; then
        echo
        warn "Stale libvirt volumes:"
        while IFS= read -r v; do
            SZ=$(sudo virsh vol-info --pool default "$v" 2>/dev/null \
                 | awk '/Capacity/{print $2$3}')
            printf "    %-70s %s\n" "$v" "$SZ"
        done <<<"$SVOLS"
        read -rp "  Remove? [y/N] " ans
        if [[ "${ans,,}" == y ]]; then
            while IFS= read -r vol; do
                sudo virsh vol-delete --pool default "$vol" 2>/dev/null \
                    && ok "Deleted: $vol" \
                    || err "Failed: $vol"
            done <<<"$SVOLS"
        fi
    fi

    # ── Vagrant boxes ─────────────────────────────────────────────────────────
    if [[ -n "$SBOXES" ]]; then
        echo
        warn "Stale vagrant boxes:"
        while IFS= read -r b; do
            SZ=$(du -sh "${VAGRANT_DOT}/boxes/${b}" 2>/dev/null | awk '{print $1}')
            printf "    %-60s %s\n" "$b" "$SZ"
        done <<<"$SBOXES"
        read -rp "  Remove? [y/N] " ans
        if [[ "${ans,,}" == y ]]; then
            while IFS= read -r box; do
                BOX_NAME=$(python3 -c \
                    "import urllib.parse; print(urllib.parse.unquote('${box}'))" \
                    2>/dev/null || echo "$box")
                docker run --rm -u 0 \
                    -e IGNORE_RUN_AS_ROOT=1 -e IGNORE_MISSING_LIBVIRT_SOCK=1 \
                    -v "${VAGRANT_DOT}:/.vagrant.d" \
                    packer-vagrant \
                    vagrant box remove "${BOX_NAME}" --provider libvirt --all \
                    2>/dev/null \
                    && ok "Removed box: ${BOX_NAME}" \
                    || { warn "vagrant remove failed — force deleting directory"
                         rm -rf "${VAGRANT_DOT}/boxes/${box}"
                         ok "Deleted: ${VAGRANT_DOT}/boxes/${box}"; }
            done <<<"$SBOXES"
        fi
    fi

    # ── Vagrant tmp ───────────────────────────────────────────────────────────
    if [[ "${TMP_COUNT}" -gt 0 ]]; then
        echo
        warn "Vagrant tmp: ${TMP_COUNT} file(s), ${TMP_SIZE}"
        read -rp "  Remove? [y/N] " ans
        if [[ "${ans,,}" == y ]]; then
            rm -rf "${VAGRANT_DOT}/tmp/"*
            ok "Cleared ~/.vagrant.d/tmp/"
        fi
    fi

    echo
    hdr "Disk after cleanup"
    df -h --output=source,size,used,avail,pcent,target \
        | grep -v '^tmpfs\|^devtmpfs\|^efivarfs\|^/dev/loop' | column -t
}

# ─────────────────────────── vnc ─────────────────────────────────────────────

do_vnc() {
    hdr "VNC console"
    mapfile -t DISPLAYS < <(ps aux | grep '[q]emu' \
        | grep -oP 'vnc 127\.0\.0\.1:\K[0-9]+' | sort -n || true)

    if [[ ${#DISPLAYS[@]} -eq 0 ]]; then
        err "No active VNC displays — is a build running?"
        exit 1
    fi

    if [[ ${#DISPLAYS[@]} -eq 1 ]]; then
        SEL="${DISPLAYS[0]}"
    else
        for i in "${!DISPLAYS[@]}"; do
            D="${DISPLAYS[$i]}"
            NAME=$(ps aux | grep '[q]emu' | grep "vnc 127.0.0.1:${D}" \
                   | grep -oP '\-name \K[^ ]+' 2>/dev/null || echo "build-${D}")
            printf "  [%s] :%-3s  %s\n" "$i" "$D" "$NAME"
        done
        read -rp "Select [0]: " IDX; IDX="${IDX:-0}"
        SEL="${DISPLAYS[$IDX]}"
    fi

    VNC_PORT=$((5900 + SEL))

    if [[ ! -d "$NOVNC_WEB" ]]; then
        warn "noVNC not found — installing..."
        sudo apt-get install -y novnc websockify 2>/dev/null || {
            sudo pip3 install websockify 2>/dev/null
            sudo git clone --depth=1 https://github.com/novnc/noVNC "$NOVNC_WEB"
        }
    fi

    pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
    sleep 0.3

    echo "Starting noVNC on :${NOVNC_PORT} → VNC :${SEL} (localhost:${VNC_PORT})..."
    websockify --web "$NOVNC_WEB" "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
    WPID=$!
    sleep 1

    if kill -0 $WPID 2>/dev/null; then
        echo
        printf "  ${GRN}Open in browser:${RST}\n"
        echo "  http://127.0.0.1:${NOVNC_PORT}/vnc.html?host=127.0.0.1&port=${NOVNC_PORT}&autoconnect=1"
        echo
        echo "Ctrl+C to stop"
        wait $WPID
    else
        err "websockify failed (port ${NOVNC_PORT} busy?)"
        exit 1
    fi
}

# ─────────────────────────── main ────────────────────────────────────────────

case "$MODE" in
    --clean) show_status; do_clean ;;
    --vnc)   do_vnc ;;
    "")      show_status ;;
    *)
        echo "Usage: $0 [--clean | --vnc]"
        echo "  (no args)  status overview"
        echo "  --clean    find and remove stale domains, volumes, vagrant boxes"
        echo "  --vnc      open noVNC console to active packer build"
        exit 1 ;;
esac
