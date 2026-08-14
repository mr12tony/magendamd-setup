#!/bin/bash

# 1. Определяем директорию скрипта и путь к лог-файлу
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="$SCRIPT_DIR/install_rustdesk.log"

# Функция для логирования одновременно в консоль и в файл
log() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$message"
    echo "$message" >> "$LOG_FILE"
}

# Начинаем лог
log "=== Запуск процесса установки RustDesk ==="

# 2. Считываем параметры из аргументов Tauri
rustdesk_pw="$1"
rustdesk_cfg="$2"

if [ -z "$rustdesk_pw" ] || [ -z "$rustdesk_cfg" ]; then
    log "Ошибка: Не переданы необходимые аргументы (пароль и/или конфиг)."
    exit 1
fi

# 3. Эскалация прав через osascript (с сохранением записи в лог)
if [ "$EUID" -ne 0 ]; then
    log "Запрос прав администратора через macOS GUI..."
    PROMPT_MSG="Для установки RustDesk требуются права администратора."
    
    # Перезапускаем этот же скрипт через osascript с правами administrator
    exec osascript -e "do shell script \"'$0' '$rustdesk_pw' '$rustdesk_cfg'\" with administrator privileges with prompt \"$PROMPT_MSG\""
    exit $?
fi

# ==================== ВЫПОЛНЯЕТСЯ С ПРАВАМИ ROOT ====================

log "Права администратора получены."
mount_point="/Volumes/RustDesk"

# 4. Поиск локального DMG файла рядом со скриптом
ARCH=$(arch)
log "Определена архитектура системы: $ARCH"

if [[ "$ARCH" == "arm64" ]]; then
    dmg_file=$(find "$SCRIPT_DIR" -maxdepth 1 -name "*aarch64.dmg" | head -n 1)
else
    dmg_file=$(find "$SCRIPT_DIR" -maxdepth 1 -name "*x86_64.dmg" | head -n 1)
fi

# Если архитектурный файл не найден, ищем любой *.dmg в этой папке
if [ -z "$dmg_file" ] || [ ! -f "$dmg_file" ]; then
    dmg_file=$(find "$SCRIPT_DIR" -maxdepth 1 -name "*.dmg" | head -n 1)
fi

if [ -z "$dmg_file" ] || [ ! -f "$dmg_file" ]; then
    log "Ошибка: DMG-файл RustDesk не найден в директории $SCRIPT_DIR"
    exit 1
fi

log "Найден и используется файл: $dmg_file"

# 5. Монтирование DMG и копирование приложения
log "Монтирование DMG образа в $mount_point..."
hdiutil attach "$dmg_file" -mountpoint "$mount_point" &> /dev/null

if [ $? -eq 0 ]; then
    if [ -d "/Applications/RustDesk.app" ]; then
        log "Удаление предыдущей версии RustDesk.app из /Applications..."
        rm -rf "/Applications/RustDesk.app"
    fi

    log "Копирование RustDesk.app в /Applications..."
    cp -R "$mount_point/RustDesk.app" "/Applications/" &> /dev/null
    
    log "Размонтирование DMG образа..."
    hdiutil detach "$mount_point" &> /dev/null
else
    log "Ошибка: Не удалось смонтировать DMG образ."
    exit 1
fi

# 6. Получение RustDesk ID
log "Запрос RustDesk ID..."
cd /Applications/RustDesk.app/Contents/MacOS/
rustdesk_id=$(./RustDesk --get-id 2>/dev/null)

# 7. Применение пароля и конфига
log "Применение конфигурационных параметров..."
./RustDesk --server &
/Applications/RustDesk.app/Contents/MacOS/RustDesk --password "$rustdesk_pw" &> /dev/null
/Applications/RustDesk.app/Contents/MacOS/RustDesk --config "$rustdesk_cfg" &> /dev/null

# 8. Завершение временных процессов RustDesk
rdpid=$(pgrep RustDesk)
if [ -n "$rdpid" ]; then
    log "Остановка временных процессов (PID: $rdpid)..."
    kill $rdpid &> /dev/null
fi

# 9. Финальный вывод и логирование результатов
log "-----------------------------------------------"
if [ -n "$rustdesk_id" ]; then
    log "Успешно получен RustDesk ID: $rustdesk_id"
else
    log "Ошибка: Не удалось получить RustDesk ID."
fi
log "Пароль установлен."
log "-----------------------------------------------"

# 10. Запуск приложения
log "Запуск приложения RustDesk..."
open -n /Applications/RustDesk.app

log "=== Установка успешно завершена ==="