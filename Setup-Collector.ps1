# Setup-Collector.ps1
# Self-elevates via UAC if not already running as Administrator.
# Just run:  PowerShell -ExecutionPolicy Bypass -File Setup-Collector.ps1

# ---------- Self-elevation --------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p  = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not elevated -- relaunching as Administrator via UAC..." -ForegroundColor Yellow
    $args2 = '-ExecutionPolicy Bypass -File "{0}"' -f $MyInvocation.MyCommand.Path
    Start-Process powershell.exe -ArgumentList $args2 -Verb RunAs
    exit
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- Configuration ---------------------------------------------------
$CollectorName = 'Laptop_Perf_Monitor'
$LogDir        = 'C:\PerfLogs\Laptop'
$FilePattern   = 'Laptop_Perf_%datetime%.blg'
$SampleSec     = 30
$TaskPath      = '\LaptopMonitor\'
$TaskName      = 'Start Laptop Perf Monitor'

$Counters = @(
    '\Processor(_Total)\% Processor Time'
    '\Processor(_Total)\% User Time'
    '\Processor(_Total)\% Privileged Time'
    '\Memory\Available MBytes'
    '\Memory\% Committed Bytes In Use'
    '\Memory\Pages/sec'
    '\PhysicalDisk(_Total)\% Disk Time'
    '\PhysicalDisk(_Total)\Avg. Disk Queue Length'
    '\PhysicalDisk(_Total)\Disk Read Bytes/sec'
    '\PhysicalDisk(_Total)\Disk Write Bytes/sec'
    '\Network Interface(*)\Bytes Total/sec'
    '\Process(*)\% Processor Time'
    '\Process(*)\Working Set'
)

# ---------- Helpers ---------------------------------------------------------
function Write-Step ([string]$Msg) { Write-Host ""; Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-OK   ([string]$Msg) { Write-Host "    OK  $Msg" -ForegroundColor Green }
function Write-Warn ([string]$Msg) { Write-Host "    !!  $Msg" -ForegroundColor Yellow }

# ---------- 1. Log directory ------------------------------------------------
Write-Step "Creating log directory: $LogDir"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Write-OK "Done: $LogDir"

# ---------- 2. Remove existing collector ------------------------------------
Write-Step "Checking for existing collector '$CollectorName'"
logman query $CollectorName 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Warn "Found -- stopping and deleting."
    logman stop   $CollectorName 2>&1 | Out-Null
    logman delete $CollectorName 2>&1 | Out-Null
    Write-OK "Removed."
} else {
    Write-OK "None found."
}

# ---------- 3. Counter file (ANSI, no BOM) ----------------------------------
Write-Step "Writing counter list"
$counterFile = "$env:TEMP\lm_counters.txt"
[System.IO.File]::WriteAllLines(
    $counterFile,
    $Counters,
    [System.Text.Encoding]::Default   # ANSI -- logman requires this
)
Write-OK "Counter file: $counterFile"

# ---------- 4. Create collector set -----------------------------------------
Write-Step "Creating data collector set"

# Run via cmd so we capture the real logman error text
$logmanCmd = "logman create counter $CollectorName -cf `"$counterFile`" -si $SampleSec -f bincirc -o `"$LogDir\$FilePattern`" -v mmddhhmm -max 512 -y"
Write-Host "    CMD: $logmanCmd"
$out = cmd /c "$logmanCmd 2>&1"
Write-Host "    Exit: $LASTEXITCODE"
$out | ForEach-Object { Write-Host "    $_" }

if ($LASTEXITCODE -ne 0) {
    # Try without -v and -max flags (some older builds reject them)
    Write-Warn "Retrying without optional flags..."
    $logmanCmd2 = "logman create counter $CollectorName -cf `"$counterFile`" -si $SampleSec -f bincirc -o `"$LogDir\$FilePattern`" -y"
    $out2 = cmd /c "$logmanCmd2 2>&1"
    Write-Host "    Exit: $LASTEXITCODE"
    $out2 | ForEach-Object { Write-Host "    $_" }

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "ERROR: logman could not create the collector set." -ForegroundColor Red
        Write-Host "Full output above. Common causes:" -ForegroundColor Red
        Write-Host "  - Counter names not valid on this locale/OS (run: typeperf -q > C:\Temp\counters_valid.txt)" -ForegroundColor Yellow
        Write-Host "  - Output path not writable" -ForegroundColor Yellow
        Write-Host "  - Still not running as Administrator" -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Remove-Item $counterFile -Force -ErrorAction SilentlyContinue
Write-OK "Collector set created."

# ---------- 5. Start collector ----------------------------------------------
Write-Step "Starting collector"
$startOut = cmd /c "logman start $CollectorName 2>&1"
Write-Host "    Exit: $LASTEXITCODE"
$startOut | ForEach-Object { Write-Host "    $_" }
if ($LASTEXITCODE -eq 0) { Write-OK "Running." } else { Write-Warn "logman start returned non-zero (may already be running)." }

# ---------- 6. Scheduled task (boot, SYSTEM) --------------------------------
Write-Step "Registering scheduled task '$TaskName'"

$stale = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($stale) {
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
    Write-Warn "Removed stale task."
}

$action    = New-ScheduledTaskAction -Execute 'logman.exe' -Argument "start $CollectorName"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask `
    -TaskPath  $TaskPath `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   $trigger `
    -Settings  $settings `
    -Principal $principal `
    -Force | Out-Null

Write-OK "Task: $TaskPath$TaskName"

# ---------- 7. Verify -------------------------------------------------------
Write-Step "Verification"
cmd /c "logman query $CollectorName 2>&1" | ForEach-Object { Write-Host "    $_" }

# ---------- 8. Summary ------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Magenta
Write-Host " Setup complete." -ForegroundColor Magenta
Write-Host "================================================" -ForegroundColor Magenta
Write-Host " Collector : $CollectorName"
Write-Host " Log dir   : $LogDir"
Write-Host " Interval  : $SampleSec s"
Write-Host " Task      : $TaskPath$TaskName"
Write-Host ""
Write-Host " Next: run Generate-Report.ps1 to create index.html"
Write-Host ""
Read-Host "Press Enter to close"
