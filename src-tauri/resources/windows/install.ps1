# 1. Объявление параметров
param(
    [string]$rustdesk_pw = $args[0],
    [string]$rustdesk_cfg = $args[1]
)

# Вычисляем директорию скрипта независимо от способа вызова
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $SCRIPT_DIR) { 
    $SCRIPT_DIR = $PSScriptRoot 
}
if (-not $SCRIPT_DIR) { 
    $SCRIPT_DIR = Get-Location 
}

$LOG_FILE = Join-Path -Path $SCRIPT_DIR -ChildPath "install_rustdesk.log"

# Функция логирования
function Write-Log {
    param([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessage = "$TimeStamp - $Message"
    Write-Output $FormattedMessage
    Add-Content -Path $LOG_FILE -Value $FormattedMessage -ErrorAction SilentlyContinue
}

Write-Log "=== Запуск процесса установки RustDesk (Windows) ==="

# Проверка параметров
if ([string]::IsNullOrWhitespace($rustdesk_pw) -or [string]::IsNullOrWhitespace($rustdesk_cfg)) {
    Write-Log "Ошибка: Не переданы необходимые аргументы (пароль и/или конфиг)."
    exit 1
}

# 2. Проверка и эскалация прав Администратора (UAC)
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isElevated) {
    Write-Log "Запрос прав администратора (UAC)..."
    try {
        # Экранируем двойные кавычки для безопасной передачи параметров через командную строку
        $escPw = $rustdesk_pw.Replace('"', '\"')
        $escCfg = $rustdesk_cfg.Replace('"', '\"')
        
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" `"$escPw`" `"$escCfg`""
        
        # Запускаем от имени админа, ждём завершения и пробрасываем ExitCode обратно в Tauri
        $process = Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait -PassThru
        
        Write-Log "Процесс установки завершен с кодом: $($process.ExitCode)"
        exit $process.ExitCode
    } catch {
        Write-Log "Ошибка: Пользователь отклонил запрос UAC или произошел сбой."
        exit 1
    }
}

# ==================== ВЫПОЛНЯЕТСЯ С ПРАВАМИ АДМИНИСТРАТОРА ====================

Write-Log "Права администратора получены."

# 3. Поиск EXE файла установки рядом со скриптом
$installerFile = Get-ChildItem -Path $SCRIPT_DIR -Filter "*.exe" | Where-Object { 
    $_.Name -like "*rustdesk*" -or $_.Name -like "*setup*" -or $_.Name -like "*x86_64*" 
} | Select-Object -First 1

if (-not $installerFile) {
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
    
    if ($rustdesk_id) { 
        $rustdesk_id = $rustdesk_id.Trim() 
    }

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
    
    Write-Log "=== Установка успешно завершена ==="
    exit 0

} else {
    Write-Log "Ошибка: Исполняемый файл RustDesk не найден после установки."
    exit 1
}