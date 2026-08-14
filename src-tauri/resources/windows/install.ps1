# 1. Приём параметров из Tauri ($args[0] = password, $args[1] = config)
param(
    [string]$rustdesk_pw = $args[0],
    [string]$rustdesk_cfg = $args[1]
)

# Определяем директорию скрипта и путь к лог-файлу
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $SCRIPT_DIR) { $SCRIPT_DIR = Get-Location }
$LOG_FILE = Join-Path -Path $SCRIPT_DIR -ChildPath "install_rustdesk.log"

# Функция для логирования в консоль и файл
function Write-Log {
    param([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessage = "$TimeStamp - $Message"
    Write-Output $FormattedMessage
    Add-Content -Path $LOG_FILE -Value $FormattedMessage -ErrorAction SilentlyContinue
}

Write-Log "=== Запуск процесса установки RustDesk (Windows) ==="

# Проверка наличия аргументов
if ([string]::IsNullOrWhitespace($rustdesk_pw) -or [string]::IsNullOrWhitespace($rustdesk_cfg)) {
    Write-Log "Ошибка: Не переданы необходимые аргументы (пароль и/или конфиг)."
    exit 1
}

# 2. Проверка и эскалация прав Администратора (UAC)
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isElevated) {
    Write-Log "Запрос прав администратора (UAC)..."
    try {
        # Перезапуск скрипта с флагом RunAs
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" `"$rustdesk_pw`" `"$rustdesk_cfg`""
        Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
        exit 0
    } catch {
        Write-Log "Ошибка: Пользователь отклонил запрос прав администратора."
        exit 1
    }
}

# ==================== ВЫПОЛНЯЕТСЯ С ПРАВАМИ АДМИНИСТРАТОРА ====================

Write-Log "Права администратора получены."

# 3. Поиск EXE файла установки рядом со скриптом
$installerFile = Get-ChildItem -Path $SCRIPT_DIR -Filter "*.exe" | Where-Object { $_.Name -like "*rustdesk*" -or $_.Name -like "*setup*" -or $_.Name -like "*x86_64*" } | Select-Object -First 1

if (-not $installerFile) {
    # Если не нашли по маске, берем любой .exe файл в этой папке (кроме текущего процесса, если скомпилирован)
    $installerFile = Get-ChildItem -Path $SCRIPT_DIR -Filter "*.exe" | Select-Object -First 1
}

if (-not $installerFile) {
    Write-Log "Ошибка: Установочный .exe файл RustDesk не найден в $SCRIPT_DIR"
    exit 1
}

Write-Log "Найден установочный файл: $($installerFile.FullName)"

# 4. Запуск тихой установки
Write-Log "Запуск тихой установки RustDesk..."
$installProcess = Start-Process -FilePath $installerFile.FullName -ArgumentList "--silent-install" -PassThru -Wait

Write-Log "Ожидание завершения установки и запуска службы..."
Start-Sleep -Seconds 10

# 5. Проверка и запуск службы RustDesk
$ServiceName = "Rustdesk"
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Log "Служба не найдена, пробуем установить вручную..."
    $exePath = "$env:ProgramFiles\RustDesk\rustdesk.exe"
    if (Test-Path $exePath) {
        Start-Process -FilePath $exePath -ArgumentList "--install-service" -Wait
        Start-Sleep -Seconds 5
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }
}

if ($service -and $service.Status -ne 'Running') {
    Write-Log "Запуск службы RustDesk..."
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# 6. Настройка RustDesk и извлечение ID
$installedExe = "$env:ProgramFiles\RustDesk\rustdesk.exe"

if (-not (Test-Path $installedExe)) {
    # Альтернативный путь (Program Files x86)
    $installedExe = "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe"
}

if (Test-Path $installedExe) {
    Write-Log "Применение конфигурации и пароля..."
    
    # Применяем конфиг и пароль
    Start-Process -FilePath $installedExe -ArgumentList "--config `"$rustdesk_cfg`"" -Wait
    Start-Process -FilePath $installedExe -ArgumentList "--password `"$rustdesk_pw`"" -Wait

    # Получаем ID
    Write-Log "Запрос RustDesk ID..."
    $rustdesk_id = & $installedExe --get-id 2>$null
    
    # Удаляем лишние пробелы/переносы
    if ($rustdesk_id) { $rustdesk_id = $rustdesk_id.Trim() }

    Write-Log "-----------------------------------------------"
    if ($rustdesk_id) {
        Write-Log "Успешно получен RustDesk ID: $rustdesk_id"
    } else {
        Write-Log "Предупреждение: Не удалось считать RustDesk ID."
    }
    Write-Log "Пароль успешно установлен."
    Write-Log "-----------------------------------------------"

    # Запускаем GUI приложения
    Write-Log "Запуск RustDesk GUI..."
    Start-Process -FilePath $installedExe

} else {
    Write-Log "Ошибка: Исполняемый файл RustDesk не найден после установки."
    exit 1
}

Write-Log "=== Установка успешно завершена ==="