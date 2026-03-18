#!/bin/bash
# Показывает консоль текущей packer/QEMU сборки через браузер (noVNC)
# Использование: ./scripts/vnc-console.sh [display_number]
#   display_number — номер дисплея (0,1,2...), по умолчанию последний запущенный

set -euo pipefail

NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_WEB="/usr/share/novnc"

# Найти все VNC дисплеи запущенных QEMU-процессов
mapfile -t DISPLAYS < <(ps aux | grep qemu | grep -v grep | grep -o 'vnc 127.0.0.1:[0-9]*' | awk -F: '{print $2}' | sort -n)

if [[ ${#DISPLAYS[@]} -eq 0 ]]; then
    echo "Нет запущенных QEMU-процессов с VNC"
    exit 1
fi

echo "Активные VNC дисплеи:"
for i in "${!DISPLAYS[@]}"; do
    D="${DISPLAYS[$i]}"
    PORT=$((5900 + D))
    # Попробуем найти имя процесса
    NAME=$(ps aux | grep qemu | grep "vnc 127.0.0.1:${D}" | grep -oP '(?<=box_basename=)[^ ]+' 2>/dev/null || echo "build-${D}")
    echo "  [$i] display :${D}  port ${PORT}  (${NAME})"
done

# Выбор дисплея
if [[ -n "${1:-}" ]]; then
    SEL="$1"
elif [[ ${#DISPLAYS[@]} -eq 1 ]]; then
    SEL="${DISPLAYS[0]}"
else
    read -rp "Выбери номер дисплея: " SEL
fi

VNC_PORT=$((5900 + SEL))

# Проверить noVNC
if [[ ! -d "$NOVNC_WEB" ]]; then
    echo "noVNC не найден в $NOVNC_WEB — устанавливаем..."
    sudo apt-get install -y novnc websockify 2>/dev/null || {
        echo "Ставим через pip/git..."
        sudo pip3 install websockify 2>/dev/null
        if [[ ! -d /usr/share/novnc ]]; then
            sudo git clone --depth=1 https://github.com/novnc/noVNC /usr/share/novnc
        fi
    }
fi

# Завершить предыдущий websockify если был
pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
sleep 0.5

echo ""
echo "VNC дисплей :${SEL}  (порт ${VNC_PORT})"
echo "Запускаем noVNC на порту ${NOVNC_PORT}..."
websockify --web "$NOVNC_WEB" "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
WPID=$!
sleep 1

if kill -0 $WPID 2>/dev/null; then
    echo ""
    echo "  Открой в браузере:"
    # noVNC < 1.3: vnc.html  |  noVNC >= 1.3: vnc.html заменён на /vnc.html через app
    if [[ -f "$NOVNC_WEB/vnc.html" ]]; then
        echo "  http://127.0.0.1:${NOVNC_PORT}/vnc.html?host=127.0.0.1&port=${NOVNC_PORT}&autoconnect=1"
    else
        echo "  http://127.0.0.1:${NOVNC_PORT}/vnc.html?host=127.0.0.1&port=${NOVNC_PORT}&autoconnect=1"
        echo "  (если не открылось — попробуй: http://127.0.0.1:${NOVNC_PORT}/)"
    fi
    echo ""
    echo "Ctrl+C — остановить"
    wait $WPID
else
    echo "websockify не запустился (порт ${NOVNC_PORT} занят?)"
    exit 1
fi
