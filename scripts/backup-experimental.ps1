<#
.SYNOPSIS
    Интерактивный бэкап стека мониторинга на базе Графини (Grafinya Monitoring Stack).
.DESCRIPTION
    Этап 1: Копирование конфигов проекта (docker-compose.yml, .env*, nginx.conf, monitoring/)
    Этап 2: Архивация томов: grafinya_mongo-data, grafinya_security-log-data, victoriametrics-data
    
    Скрипт ищет проект в текущей директории (или в $env:GRAFINYA_PROJECT_ROOT, если задана).
    Бэкапы сохраняются в $env:GRAFINYA_BACKUP_ROOT (по умолчанию: ./backups).
.EXAMPLE
    .\backup-experimental.ps1
.EXAMPLE
    $env:GRAFINYA_PROJECT_ROOT = "C:\my-grafinya"
    $env:GRAFINYA_BACKUP_ROOT  = "D:\backups\grafinya"
    .\backup-experimental.ps1
#>

# =============================================================================
# НАСТРОЙКИ (адаптивные, не hardcoded)
# =============================================================================

# Корень проекта: либо переменная окружения, либо папка, где лежит этот скрипт
$ProjectRoot = $env:GRAFINYA_PROJECT_ROOT
if (-not $ProjectRoot) {
    # Скрипт в scripts/, проект на уровень выше
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

# Корень бэкапов: либо переменная окружения, либо ./backups рядом с проектом
$BackupRoot = $env:GRAFINYA_BACKUP_ROOT
if (-not $BackupRoot) {
    $BackupRoot = Join-Path $ProjectRoot "backups"
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$BackupFolder = Join-Path $BackupRoot "Backup_$Timestamp"
$LogFile = Join-Path $BackupFolder "backup.log"
$ExcludeDirs = @(".git", "node_modules", "temp", "backups")

# Префикс проекта (из name: в docker-compose.yml)
$ProjectName = "grafinya-monitoring-stack"

# Тома для архивации (имена из docker-compose.yml + префикс проекта)
$TargetVolumes = @(
    @{ Name = "${ProjectName}_grafinya_mongo-data";        Service = "MongoDB" }
    @{ Name = "${ProjectName}_grafinya_security-log-data"; Service = "Security Log" }
    @{ Name = "${ProjectName}_victoriametrics-data";       Service = "VictoriaMetrics" }
)

# =============================================================================
# ЛОГИРОВАНИЕ И ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    $color = switch ($Level) {
        "INFO"    { "White" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }
    Write-Host $logEntry -ForegroundColor $color
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -gt 1GB) { return "$([math]::Round($Bytes/1GB, 2)) GB" }
    if ($Bytes -gt 1MB) { return "$([math]::Round($Bytes/1MB, 2)) MB" }
    if ($Bytes -gt 1KB) { return "$([math]::Round($Bytes/1KB, 2)) KB" }
    return "$Bytes B"
}

function Get-VolumeSize {
    param([string]$VolumeName)
    try {
        $sizeOutput = docker run --rm -v "${VolumeName}:/data" alpine du -sb /data 2>$null
        $bytes = ($sizeOutput -split '\s+')[0]
        if ([long]::TryParse($bytes, [ref]$null)) {
            return [long]$bytes
        }
    } catch {}
    return 0
}

function Test-GzipIntegrity {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $false }
    $parent = Split-Path $FilePath -Parent
    $name = Split-Path $FilePath -Leaf
    $process = Start-Process -FilePath "docker" -ArgumentList "run", "--rm", "-v", "${parent}:/backup", "alpine", "gzip", "-t", "/backup/$name" -NoNewWindow -Wait -PassThru
    return ($process.ExitCode -eq 0)
}

function Ask-YesNo {
    param([string]$Question, [string]$Default = "Y")
    $prompt = if ($Default -eq "Y") { "(Y/N)" } else { "(y/N)" }
    $response = Read-Host "$Question $prompt"
    if ([string]::IsNullOrWhiteSpace($response)) { $response = $Default }
    return ($response -eq 'Y' -or $response -eq 'y')
}

# =============================================================================
# ЭТАП 1: КОНФИГИ ПРОЕКТА
# =============================================================================
function Backup-ProjectConfigs {
    Write-Log "=== ЭТАП 1: КОНФИГИ ПРОЕКТА ===" "INFO"
    Write-Host "`n--- ЭТАП 1: Копирование конфигурационных файлов проекта ---" -ForegroundColor Cyan

    if (-not (Test-Path $ProjectRoot)) {
        Write-Log "Папка проекта не найдена: $ProjectRoot" "ERROR"
        Write-Log "Задайте $env:GRAFINYA_PROJECT_ROOT или запустите скрипт из папки проекта" "INFO"
        return $false
    }

    $allFiles = Get-ChildItem $ProjectRoot -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        $exclude = $false
        foreach ($ex in $ExcludeDirs) {
            if ($_.FullName -like "*\$ex\*" -or $_.FullName -like "*\$ex") {
                $exclude = $true; break
            }
        }
        -not $exclude -and -not $_.PSIsContainer
    }
    $totalFiles = $allFiles.Count
    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum

    Write-Host "Источник: $ProjectRoot" -ForegroundColor White
    Write-Host "Файлов: $totalFiles, размер: $(Format-Size $totalSize)" -ForegroundColor White

    $destFolder = Join-Path $BackupFolder "ProjectConfigs"
    New-Item -ItemType Directory -Force -Path $destFolder | Out-Null

    $robocopyArgs = @($ProjectRoot, $destFolder, "/E", "/Z", "/R:3", "/W:5", "/XD") + $ExcludeDirs
    Write-Log "Запуск robocopy..." "INFO"
    $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -lt 8) {
        Write-Log "Конфиги проекта скопированы (код: $($process.ExitCode))" "SUCCESS"
        return $true
    } else {
        Write-Log "Robocopy завершился с кодом: $($process.ExitCode)" "ERROR"
        return $false
    }
}

# =============================================================================
# ЭТАП 2: АРХИВАЦИЯ ВСЕХ ТОМОВ
# =============================================================================
function Backup-VolumeTar {
    param($Vol, $DestFolder)
    $safeName = $Vol.Name -replace ':', '-'
    $tarFile = Join-Path $DestFolder "$safeName.tar.gz"

    Write-Log "Архивация тома $($Vol.Name) ($($Vol.Service))" "INFO"
    Write-Host "  Архивация $($Vol.Service)..." -ForegroundColor Cyan

    $args = @("run", "--rm", "-v", "$($Vol.Name):/source", "-v", "${DestFolder}:/backup", "alpine", "tar", "czf", "/backup/$safeName.tar.gz", "-C", "/source", ".")
    $process = Start-Process -FilePath "docker" -ArgumentList $args -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Log "Ошибка архивации тома $($Vol.Name)" "ERROR"
        Write-Log "Возможно, том не существует. Запустите 'docker volume ls' для проверки" "INFO"
        return $false
    }

    if (Test-Path $tarFile) {
        if (Test-GzipIntegrity -FilePath $tarFile) {
            $size = (Get-Item $tarFile).Length
            Write-Log "Том $($Vol.Name) заархивирован: $(Format-Size $size)" "SUCCESS"
            return $true
        } else {
            Write-Log "Архив тома $($Vol.Name) повреждён" "ERROR"
            Remove-Item $tarFile -Force -ErrorAction SilentlyContinue
            return $false
        }
    } else {
        Write-Log "Архив не создан для тома $($Vol.Name)" "ERROR"
        return $false
    }
}

function Backup-AllVolumes {
    param($DestFolder)
    Write-Log "Архивация всех томов..." "INFO"
    $success = $true
    foreach ($vol in $TargetVolumes) {
        $ok = Backup-VolumeTar -Vol $vol -DestFolder $DestFolder
        if (-not $ok) { $success = $false }
    }
    return $success
}

# =============================================================================
# ГЛАВНОЕ МЕНЮ
# =============================================================================
New-Item -ItemType Directory -Force -Path $BackupFolder | Out-Null
Write-Log "=== ЗАПУСК БЭКАПА STECKA GRAFINYA ===" "INFO"
Write-Log "Project root: $ProjectRoot" "INFO"
Write-Log "Backup root: $BackupRoot" "INFO"

$stages = @(
    @{ Name = "1"; Description = "Конфиги проекта"; Function = { Backup-ProjectConfigs } },
    @{ Name = "2"; Description = "Архивация всех томов (tar.gz)"; Function = { Backup-AllVolumes -DestFolder $BackupFolder } }
)

$results = @{}

while ($true) {
    Write-Host "`n----------------------------------------" -ForegroundColor DarkGray
    Write-Host " ВЫБЕРИТЕ ЭТАП ДЛЯ ВЫПОЛНЕНИЯ:" -ForegroundColor Yellow
    Write-Host "----------------------------------------" -ForegroundColor DarkGray
    foreach ($s in $stages) {
        Write-Host "  [$($s.Name)] $($s.Description)" -ForegroundColor Cyan
    }
    Write-Host "  [a] Выполнить все этапы последовательно" -ForegroundColor Green
    Write-Host "  [s] Показать итоги и завершить" -ForegroundColor Green
    Write-Host "  [q] Выйти без сохранения" -ForegroundColor Red
    Write-Host ""

    $choice = Read-Host "Введите значение (1-2, a, s, q)"

    if ($choice -eq 'q' -or $choice -eq 'Q') {
        Write-Log "Бэкап отменён пользователем" "WARNING"
        exit 0
    }
    if ($choice -eq 's' -or $choice -eq 'S') {
        break
    }
    if ($choice -eq 'a' -or $choice -eq 'A') {
        Write-Log "Выполнение всех этапов..." "INFO"
        foreach ($s in $stages) {
            Write-Host "`n--- Выполняется этап $($s.Name): $($s.Description) ---" -ForegroundColor Magenta
            $ok = & $s.Function
            $results[$s.Name] = $ok
            if (-not $ok) {
                Write-Log "Этап $($s.Name) завершился с ошибкой" "ERROR"
                if (-not (Ask-YesNo "Продолжить с остальными этапами?")) {
                    break
                }
            }
        }
        continue
    }
    $selected = $stages | Where-Object { $_.Name -eq $choice }
    if ($selected) {
        Write-Host "`n--- Выполняется этап $($choice): $($selected.Description) ---" -ForegroundColor Magenta
        $ok = & $selected.Function
        $results[$choice] = $ok
        if (-not $ok) {
            Write-Log "Этап $choice завершился с ошибкой" "ERROR"
        }
        continue
    } else {
        Write-Log "Неверный выбор" "ERROR"
    }
}

# =============================================================================
# ИТОГИ
# =============================================================================
Write-Host "`n----------------------------------------" -ForegroundColor DarkGray
Write-Host " ИТОГИ БЭКАПА" -ForegroundColor Green
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host "Расположение: $BackupFolder" -ForegroundColor White
Write-Host "Лог: $LogFile" -ForegroundColor Gray
Write-Host ""

$totalSize = 0
foreach ($s in $stages) {
    $ok = $results[$s.Name]
    if ($ok -eq $true) {
        Write-Host "  [OK] $($s.Description)" -ForegroundColor Green
        Write-Log "  Этап $($s.Name): УСПЕШНО" "SUCCESS"
    } elseif ($ok -eq $false) {
        Write-Host "  [ОШИБКА] $($s.Description)" -ForegroundColor Red
        Write-Log "  Этап $($s.Name): ОШИБКА" "ERROR"
    } else {
        Write-Host "  [ПРОПУСК] $($s.Description)" -ForegroundColor Yellow
        Write-Log "  Этап $($s.Name): ПРОПУЩЕН" "WARNING"
    }
}

# Подсчёт общего размера (все файлы в папке бэкапа)
if (Test-Path $BackupFolder) {
    $totalSize = (Get-ChildItem $BackupFolder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
}
Write-Host ""
Write-Host "ОБЩИЙ РАЗМЕР БЭКАПА: $(Format-Size $totalSize)" -ForegroundColor Green
Write-Log "Общий размер бэкапа: $(Format-Size $totalSize)" "SUCCESS"
Write-Log "БЭКАП ЗАВЕРШЁН" "INFO"
Write-Host "`nНажмите любую клавишу для выхода..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")