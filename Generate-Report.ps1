# Generate-Report.ps1
# Reads ALL historical .blg files, builds a full-history HTML report with
# Chart.js line graphs (CPU %, RAM used %, Disk %), live snapshot, top 30
# processes, and quick wins.
#
# Runs daily at 07:00 via scheduled task.
# Run manually:  PowerShell -ExecutionPolicy Bypass -File Generate-Report.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force dot-decimal for all number-to-string conversions (prevents locale commas breaking JS)
[System.Threading.Thread]::CurrentThread.CurrentCulture   = [cultureinfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [cultureinfo]::InvariantCulture

# ---------- Configuration ---------------------------------------------------
$CollectorName  = 'Laptop_Perf_Monitor'
$LogDir         = 'C:\PerfLogs\Laptop'
$TempCsv        = "$env:TEMP\lm_export_temp.csv"
$ReportDir      = 'C:\LaptopMonitor'
$ReportFile     = "$ReportDir\index.html"
$TaskPath       = '\LaptopMonitor\'
$TaskName       = 'Generate Morning Report'
$ScriptFullPath = $MyInvocation.MyCommand.Path
$SampleMinutes  = 30   # downsample to 1 point per N minutes

# ---------- Helpers ---------------------------------------------------------
function Write-Step ([string]$Msg) { Write-Host ""; Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-OK   ([string]$Msg) { Write-Host "    OK  $Msg" -ForegroundColor Green }
function Write-Warn ([string]$Msg) { Write-Host "    !!  $Msg" -ForegroundColor Yellow }

function Get-ColorBar ([double]$Pct) {
    $c = if ($Pct -ge 80) { '#f85149' } elseif ($Pct -ge 60) { '#d29922' } else { '#3fb950' }
    $w = [Math]::Min([Math]::Round($Pct), 100)
    return '<div class="bar-wrap"><div class="bar" style="width:{0}%;background:{1}"></div></div>' -f $w, $c
}
function Get-PctColor ([double]$Pct) {
    if ($Pct -ge 80) { return '#f85149' }
    if ($Pct -ge 60) { return '#d29922' }
    return '#3fb950'
}
function Get-RamColor ([double]$MB) {
    if ($MB -ge 2048) { return '#f85149' }
    if ($MB -ge 1024) { return '#d29922' }
    return '#c9d1d9'
}

# Emit a JS array literal from a list of [timestamp, value] pairs
function ConvertTo-JsPoints ([System.Collections.Generic.List[object]]$Points) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('[')
    $first = $true
    foreach ($pt in $Points) {
        if (-not $first) { [void]$sb.Append(',') }
        # pt[0] = ISO datetime string, pt[1] = double value
        [void]$sb.Append(('{{"x":"{0}","y":{1}}}' -f $pt[0], $pt[1]))
        $first = $false
    }
    [void]$sb.Append(']')
    return $sb.ToString()
}

# ============================================================================
# (a) ROTATE the currently-active .blg so it is closed and readable
# ============================================================================
Write-Step "Rotating active .blg"

logman stop $CollectorName 2>&1 | Out-Null
Start-Sleep -Seconds 2

$blgFiles = Get-ChildItem -Path $LogDir -Filter '*.blg' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

if ($blgFiles) {
    $newest = $blgFiles[0]
    if ($newest.Name -match '%datetime%') {
        $stamp   = Get-Date -Format 'yyyyMMdd_HHmm'
        $newName = "Laptop_Perf_$stamp.blg"
        try {
            Rename-Item -Path $newest.FullName -NewName $newName -ErrorAction Stop
            Write-OK "Renamed '$($newest.Name)' to '$newName'"
        } catch {
            Write-Warn "Could not rename active .blg (needs admin / file still open) -- skipping rotation, existing files will still be parsed."
        }
    } else {
        Write-OK "Active file: $($newest.Name)"
    }
} else {
    Write-Warn "No .blg files found in $LogDir"
}

logman start $CollectorName 2>&1 | Out-Null
Write-OK "Collector restarted."

# ============================================================================
# (b) PARSE ALL .blg files -- full history
# ============================================================================
Write-Step "Parsing all .blg files for full history"

# Accumulators -- keyed by 30-min bucket (rounded timestamp string)
$buckets = [System.Collections.Generic.SortedDictionary[string, object]]::new()

$allBlg = Get-ChildItem -Path $LogDir -Filter '*.blg' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime

$totalRamMBForPct = $null   # filled from CIM below, used to convert avail MB to used %

foreach ($blg in $allBlg) {
    Write-Host "    Processing: $($blg.Name)" -ForegroundColor DarkGray

    # Export this .blg to temp CSV
    if (Test-Path $TempCsv) { Remove-Item $TempCsv -Force }
    & relog $blg.FullName -f CSV -o $TempCsv -y 2>&1 | Out-Null

    if (-not (Test-Path $TempCsv)) {
        Write-Warn "relog produced no output for $($blg.Name) -- skipping."
        continue
    }

    try {
        $raw = Import-Csv -Path $TempCsv
        if ($raw.Count -eq 0) { continue }

        $cols     = $raw[0].PSObject.Properties.Name
        $tsCol    = $cols[0]
        $cpuCol   = $cols | Where-Object { $_ -match 'Processor\(_Total\)\\% Processor Time' }   | Select-Object -First 1
        $ramCol   = $cols | Where-Object { $_ -match 'Memory\\Available MBytes' }                 | Select-Object -First 1
        $diskCol  = $cols | Where-Object { $_ -match 'PhysicalDisk\(_Total\)\\% Disk Time' }      | Select-Object -First 1

        foreach ($row in $raw) {
            $ts = [datetime]::MinValue
            if (-not [datetime]::TryParse($row.$tsCol, [ref]$ts)) { continue }

            # Round down to nearest $SampleMinutes bucket
            $bucketMins  = [Math]::Floor($ts.TimeOfDay.TotalMinutes / $SampleMinutes) * $SampleMinutes
            $bucketTime  = [datetime]::new($ts.Year, $ts.Month, $ts.Day, 0, 0, 0).AddMinutes($bucketMins)
            $bucketKey   = $bucketTime.ToString('yyyy-MM-ddTHH:mm:ss')

            $parseD = {
                param([string]$v)
                $d = 0.0
                if ([double]::TryParse($v.Trim(),
                        [System.Globalization.NumberStyles]::Any,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [ref]$d)) { $d } else { [double]::NaN }
            }

            $cpuV  = & $parseD ($row.$cpuCol)
            $ramV  = & $parseD ($row.$ramCol)    # Available MBytes
            $diskV = & $parseD ($row.$diskCol)

            if (-not $buckets.ContainsKey($bucketKey)) {
                $buckets[$bucketKey] = [PSCustomObject]@{
                    CpuSum   = 0.0; CpuN   = 0
                    RamSum   = 0.0; RamN   = 0
                    DiskSum  = 0.0; DiskN  = 0
                }
            }
            $b = $buckets[$bucketKey]
            if (-not [double]::IsNaN($cpuV))  { $b.CpuSum  += $cpuV;  $b.CpuN++  }
            if (-not [double]::IsNaN($ramV))  { $b.RamSum  += $ramV;  $b.RamN++  }
            if (-not [double]::IsNaN($diskV)) { $b.DiskSum += $diskV; $b.DiskN++ }
        }
    } catch {
        Write-Warn "Parse error in $($blg.Name): $_"
    }
}

Write-OK "Buckets collected: $($buckets.Count)"

# ============================================================================
# (c) LIVE SNAPSHOT
# ============================================================================
Write-Step "Live snapshot"

$os  = Get-CimInstance -ClassName Win32_OperatingSystem
$cs  = Get-CimInstance -ClassName Win32_ComputerSystem
$cpu = Get-CimInstance -ClassName Win32_Processor

$uptimeHours  = [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
$cpuLoadPct   = [Math]::Round(($cpu | Measure-Object -Property LoadPercentage -Average).Average, 1)
$totalRamMB   = [Math]::Round($cs.TotalPhysicalMemory / 1MB, 0)
$freeRamMB    = [Math]::Round($os.FreePhysicalMemory / 1KB, 0)
$usedRamMB    = $totalRamMB - $freeRamMB
$ramPct       = [Math]::Round(($usedRamMB / $totalRamMB) * 100, 1)
$totalRamMBForPct = $totalRamMB

$disk       = Get-PSDrive -Name C
$diskUsedGB = [Math]::Round($disk.Used / 1GB, 1)
$diskFreeGB = [Math]::Round($disk.Free / 1GB, 1)
$diskTotGB  = $diskUsedGB + $diskFreeGB
$diskPct    = [Math]::Round(($diskUsedGB / $diskTotGB) * 100, 1)

Write-OK ("CPU {0}% | RAM {1}/{2} MB ({3}%) | Disk {4}/{5} GB ({6}%)" -f
          $cpuLoadPct, $usedRamMB, $totalRamMB, $ramPct, $diskUsedGB, $diskTotGB, $diskPct)

# Top 10 processes
$procRows = Get-Process |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First 10 |
    ForEach-Object {
        $company = ''
        try { $company = $_.Company } catch {}
        if (-not $company) { try { $company = (Get-Item $_.Path -ErrorAction SilentlyContinue).VersionInfo.CompanyName } catch {} }
        if (-not $company) { $company = '-' }
        [PSCustomObject]@{
            Name    = $_.ProcessName
            RamMB   = [Math]::Round($_.WorkingSet64 / 1MB, 1)
            CpuSec  = $(try { [Math]::Round($_.TotalProcessorTime.TotalSeconds, 1) } catch { 0 })
            Threads = $_.Threads.Count
            Company = $company
        }
    }

# ============================================================================
# (d) BUILD CHART DATA (JS arrays)
# ============================================================================
Write-Step "Building chart data"

$cpuPoints  = [System.Collections.Generic.List[object]]::new()
$ramPoints  = [System.Collections.Generic.List[object]]::new()
$diskPoints = [System.Collections.Generic.List[object]]::new()

foreach ($key in $buckets.Keys) {
    $b = $buckets[$key]

    if ($b.CpuN -gt 0) {
        $cpuPoints.Add(@($key, [Math]::Round($b.CpuSum / $b.CpuN, 1)))
    }
    if ($b.RamN -gt 0 -and $totalRamMBForPct -gt 0) {
        $availMB = $b.RamSum / $b.RamN
        $usedPct = [Math]::Round((($totalRamMBForPct - $availMB) / $totalRamMBForPct) * 100, 1)
        $ramPoints.Add(@($key, $usedPct))
    }
    if ($b.DiskN -gt 0) {
        $diskPoints.Add(@($key, [Math]::Round($b.DiskSum / $b.DiskN, 1)))
    }
}

$jsCpu  = ConvertTo-JsPoints $cpuPoints
$jsRam  = ConvertTo-JsPoints $ramPoints
$jsDisk = ConvertTo-JsPoints $diskPoints

Write-OK ("Chart points -- CPU: {0} | RAM: {1} | Disk: {2}" -f $cpuPoints.Count, $ramPoints.Count, $diskPoints.Count)

# ============================================================================
# (e) BUILD HTML
# ============================================================================
Write-Step "Writing HTML report"

if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
}

$hostname  = $env:COMPUTERNAME
$reportTs  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$nextRun   = (Get-Date -Hour 7 -Minute 0 -Second 0).AddDays(1).ToString('yyyy-MM-dd 07:00')
$cpuName   = ($cpu | Select-Object -First 1).Name.Trim()
$dayCount  = if ($buckets.Count -gt 0) {
    $keys     = @($buckets.Keys)
    $first    = [datetime]::Parse($keys[0])
    $last     = [datetime]::Parse($keys[-1])
    [Math]::Round(($last - $first).TotalDays, 1)
} else { 0 }

$cpuBar  = Get-ColorBar $cpuLoadPct
$ramBar  = Get-ColorBar $ramPct
$diskBar = Get-ColorBar $diskPct

$cpuBarColor  = Get-PctColor $cpuLoadPct
$ramBarColor  = Get-PctColor $ramPct
$diskBarColor = Get-PctColor $diskPct

$procHtml = ($procRows | ForEach-Object {
    $rc = Get-RamColor $_.RamMB
    "<tr><td>$($_.Name)</td><td style='color:$rc'>$($_.RamMB) MB</td><td>$($_.CpuSec)</td><td>$($_.Threads)</td><td class='pub'>$($_.Company)</td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LaptopMonitor -- $hostname</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg:      #0d1117;
    --surface: #161b22;
    --border:  #30363d;
    --text:    #c9d1d9;
    --muted:   #8b949e;
    --green:   #3fb950;
    --amber:   #d29922;
    --red:     #f85149;
    --blue:    #58a6ff;
  }
  body {
    background: var(--bg); color: var(--text);
    font-family: 'Inter', system-ui, sans-serif;
    font-size: 14px; line-height: 1.6;
    padding: 24px; max-width: 1300px; margin: 0 auto;
  }
  h1 { font-size: 22px; font-weight: 600; color: #fff; margin-bottom: 4px; }
  h2 { font-size: 15px; font-weight: 600; color: #fff; margin: 0 0 14px; }
  .subtitle { color: var(--muted); font-size: 13px; margin-bottom: 28px; }
  .cards {
    display: grid; grid-template-columns: repeat(3,1fr);
    gap: 16px; margin-bottom: 28px;
  }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 18px;
  }
  .card-label {
    font-size: 11px; text-transform: uppercase;
    letter-spacing: .08em; color: var(--muted); margin-bottom: 6px;
  }
  .card-value {
    font-family: 'JetBrains Mono', monospace;
    font-size: 34px; font-weight: 600; line-height: 1; margin-bottom: 10px;
  }
  .bar-wrap { height: 5px; background: var(--border); border-radius: 3px; overflow: hidden; margin-top: 6px; }
  .bar { height: 100%; border-radius: 3px; }
  .section {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 20px; margin-bottom: 24px;
  }
  .chart-grid {
    display: grid; grid-template-columns: 1fr;
    gap: 24px;
  }
  .chart-wrap { position: relative; height: 220px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  thead th {
    text-align: left; color: var(--muted); font-size: 11px;
    text-transform: uppercase; letter-spacing: .06em;
    padding: 6px 8px; border-bottom: 1px solid var(--border); font-weight: 500;
  }
  tbody tr:hover { background: rgba(255,255,255,.03); }
  tbody td {
    padding: 5px 8px; border-bottom: 1px solid #21262d;
    font-family: 'JetBrains Mono', monospace; vertical-align: middle;
  }
  tbody td.pub { font-family: 'Inter', sans-serif; color: var(--muted); }
  .tiles { display: grid; grid-template-columns: repeat(3,1fr); gap: 12px; }
  .tile {
    background: var(--bg); border: 1px solid var(--border);
    border-radius: 6px; padding: 14px;
  }
  .tile-title { font-weight: 600; font-size: 13px; color: #fff; margin-bottom: 4px; }
  .tile-body { font-size: 12px; color: var(--muted); line-height: 1.5; }
  .tile-cmd {
    font-family: 'JetBrains Mono', monospace; font-size: 11px;
    background: var(--border); color: var(--blue);
    padding: 2px 6px; border-radius: 3px;
    display: inline-block; margin-top: 6px;
  }
  .meta-pill {
    display: inline-block; font-size: 11px; font-family: 'JetBrains Mono', monospace;
    background: var(--border); color: var(--muted);
    padding: 2px 8px; border-radius: 12px; margin-right: 6px;
  }
  .section-header {
    display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px;
  }
  .section-header h2 { margin: 0; }
  .filter-bar { display: flex; gap: 4px; }
  .filter-btn {
    font-family: 'JetBrains Mono', monospace; font-size: 11px;
    background: transparent; border: 1px solid var(--border);
    color: var(--muted); padding: 3px 10px; border-radius: 4px;
    cursor: pointer; transition: all .15s;
  }
  .filter-btn:hover { border-color: var(--blue); color: var(--blue); }
  .filter-btn.active { background: var(--blue); border-color: var(--blue); color: #0d1117; font-weight: 600; }
  footer {
    margin-top: 28px; padding-top: 14px; border-top: 1px solid var(--border);
    color: var(--muted); font-size: 12px;
    display: flex; justify-content: space-between; flex-wrap: wrap; gap: 8px;
  }
</style>
</head>
<body>

<h1>LaptopMonitor</h1>
<p class="subtitle">
  <strong>$hostname</strong> &nbsp;|&nbsp; $cpuName &nbsp;|&nbsp; Uptime: ${uptimeHours}h
  &nbsp;|&nbsp;
  <span class="meta-pill">History: ${dayCount} days</span>
  <span class="meta-pill">Samples: $($buckets.Count) x 30min</span>
</p>

<!-- Live stat cards -->
<div class="cards">
  <div class="card">
    <div class="card-label">CPU Load (now)</div>
    <div class="card-value" style="color:$cpuBarColor">${cpuLoadPct}%</div>
    $cpuBar
  </div>
  <div class="card">
    <div class="card-label">Memory Used (now)</div>
    <div class="card-value" style="color:$ramBarColor">${ramPct}%</div>
    $ramBar
    <div style="margin-top:6px;color:var(--muted);font-size:12px">${usedRamMB} MB / ${totalRamMB} MB</div>
  </div>
  <div class="card">
    <div class="card-label">Disk C: Used (now)</div>
    <div class="card-value" style="color:$diskBarColor">${diskPct}%</div>
    $diskBar
    <div style="margin-top:6px;color:var(--muted);font-size:12px">${diskUsedGB} GB / ${diskTotGB} GB</div>
  </div>
</div>

<!-- Continuous performance graphs -->
<div class="section">
  <div class="section-header">
    <h2 id="history-title">Performance History — last 7 days</h2>
    <div class="filter-bar">
      <button class="filter-btn"        data-days="1"   onclick="applyFilter(1)">1D</button>
      <button class="filter-btn active" data-days="7"   onclick="applyFilter(7)">7D</button>
      <button class="filter-btn"        data-days="30"  onclick="applyFilter(30)">30D</button>
      <button class="filter-btn"        data-days="90"  onclick="applyFilter(90)">90D</button>
      <button class="filter-btn"        data-days="365" onclick="applyFilter(365)">1Y</button>
      <button class="filter-btn"        data-days="0"   onclick="applyFilter(0)">All</button>
    </div>
  </div>
  <div class="chart-grid">

    <div>
      <div style="font-size:12px;color:var(--muted);margin-bottom:6px;font-family:'JetBrains Mono',monospace">CPU Usage %</div>
      <div class="chart-wrap"><canvas id="chartCpu"></canvas></div>
    </div>

    <div>
      <div style="font-size:12px;color:var(--muted);margin-bottom:6px;font-family:'JetBrains Mono',monospace">RAM Used %</div>
      <div class="chart-wrap"><canvas id="chartRam"></canvas></div>
    </div>

    <div>
      <div style="font-size:12px;color:var(--muted);margin-bottom:6px;font-family:'JetBrains Mono',monospace">Disk Activity %</div>
      <div class="chart-wrap"><canvas id="chartDisk"></canvas></div>
    </div>

  </div>
</div>

<!-- Top 30 processes -->
<div class="section">
  <h2>Top 10 Processes by RAM (snapshot at report time)</h2>
  <table>
    <thead><tr><th>Name</th><th>RAM</th><th>CPU Seconds</th><th>Threads</th><th>Publisher</th></tr></thead>
    <tbody>$procHtml</tbody>
  </table>
</div>

<!-- Quick wins -->
<div class="section">
  <h2>Quick Wins</h2>
  <div class="tiles">
    <div class="tile">
      <div class="tile-title">Disable Startup Bloat</div>
      <div class="tile-body">Task Manager Startup tab -- disable Teams, OneDrive, Spotify, Discord, Adobe updaters.
        <div class="tile-cmd">taskmgr</div>
      </div>
    </div>
    <div class="tile">
      <div class="tile-title">Audit Running Services</div>
      <div class="tile-body">Set non-essential services to Manual: Fax, Print Spooler, Xbox services.
        <div class="tile-cmd">services.msc</div>
      </div>
    </div>
    <div class="tile">
      <div class="tile-title">Reduce Visual Effects</div>
      <div class="tile-body">Adjust for best performance -- disables animations and frees CPU cycles.
        <div class="tile-cmd">sysdm.cpl</div>
      </div>
    </div>
    <div class="tile">
      <div class="tile-title">Set High Performance Plan</div>
      <div class="tile-body">Prevents CPU throttling. Switch from Balanced to High Performance.
        <div class="tile-cmd">powercfg.cpl</div>
      </div>
    </div>
    <div class="tile">
      <div class="tile-title">Schedule AV Scans Off-Hours</div>
      <div class="tile-body">Reschedule Defender full scans to 02:00-04:00 to avoid work-hour hits.
        <div class="tile-cmd">Windows Security</div>
      </div>
    </div>
    <div class="tile">
      <div class="tile-title">Control Windows Update</div>
      <div class="tile-body">Set Active Hours so update activity stays away from your work time.
        <div class="tile-cmd">Settings - Windows Update</div>
      </div>
    </div>
  </div>
</div>

<footer>
  <span>$hostname -- Report generated: $reportTs</span>
  <span>Next scheduled run: $nextRun</span>
</footer>

<script>
const GRID   = '#30363d';
const MUTED  = '#8b949e';
const GREEN  = '#3fb950';
const AMBER  = '#d29922';
const RED    = '#f85149';
const BLUE   = '#58a6ff';
const PURPLE = '#bc8cff';

function colorForValue(v, warn, crit) {
  if (v >= crit) return RED;
  if (v >= warn) return AMBER;
  return GREEN;
}

// Raw 30-min samples from PowerShell
const allData = {
  chartCpu:  $jsCpu,
  chartRam:  $jsRam,
  chartDisk: $jsDisk
};

const chartMeta = {
  chartCpu:  { label: 'CPU',  color: BLUE,   warn: 60, crit: 80 },
  chartRam:  { label: 'RAM',  color: PURPLE, warn: 70, crit: 85 },
  chartDisk: { label: 'Disk', color: AMBER,  warn: 60, crit: 80 }
};

// Period config: days window (0=all), bucket size in ms, tooltip format, x display unit
const PERIODS = {
  1:   { bucketMs: 3600000,       tooltipFmt: 'HH:mm',        unit: 'hour',  label: '24 hours'    },
  7:   { bucketMs: 86400000,      tooltipFmt: 'MMM d',        unit: 'day',   label: 'last 7 days' },
  30:  { bucketMs: 86400000,      tooltipFmt: 'MMM d',        unit: 'day',   label: 'last 30 days'},
  90:  { bucketMs: 7 * 86400000,  tooltipFmt: 'MMM d',        unit: 'week',  label: 'last 90 days'},
  365: { bucketMs: 7 * 86400000,  tooltipFmt: 'MMM d',        unit: 'week',  label: 'last year'   },
  0:   { bucketMs: 30 * 86400000, tooltipFmt: 'MMM yyyy',     unit: 'month', label: 'all time'    }
};

// Slice to window then average into buckets of bucketMs
function aggregateData(raw, days, bucketMs) {
  const cutoff = days ? Date.now() - days * 86400000 : 0;
  const inWindow = raw.filter(p => new Date(p.x).getTime() >= cutoff);

  if (!inWindow.length) return [];

  // Group by bucket floor
  const map = new Map();
  inWindow.forEach(p => {
    const t   = new Date(p.x).getTime();
    const key = Math.floor(t / bucketMs) * bucketMs;
    if (!map.has(key)) map.set(key, { sum: 0, n: 0 });
    const b = map.get(key);
    b.sum += p.y;
    b.n++;
  });

  return Array.from(map.entries())
    .sort((a, b) => a[0] - b[0])
    .map(([ts, b]) => ({ x: new Date(ts).toISOString(), y: Math.round(b.sum / b.n * 10) / 10 }));
}

const charts = {};

function makeChart(id, days) {
  const m    = chartMeta[id];
  const cfg  = PERIODS[days];
  const d    = aggregateData(allData[id], days, cfg.bucketMs);
  const ctx  = document.getElementById(id).getContext('2d');

  charts[id] = new Chart(ctx, {
    type: 'line',
    data: {
      datasets: [{
        label: m.label,
        data: d,
        borderColor: m.color,
        backgroundColor: m.color + '18',
        borderWidth: 1.5,
        pointRadius: d.length > 60 ? 0 : 3,
        pointHoverRadius: 5,
        pointBackgroundColor: d.map(p => colorForValue(p.y, m.warn, m.crit)),
        fill: true,
        tension: 0.3
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: '#161b22',
          borderColor: '#30363d',
          borderWidth: 1,
          titleColor: '#c9d1d9',
          bodyColor: '#8b949e',
          callbacks: {
            label: c => m.label + ': ' + c.parsed.y.toFixed(1) + '%'
          }
        }
      },
      scales: {
        x: {
          type: 'time',
          time: {
            unit: cfg.unit,
            tooltipFormat: cfg.tooltipFmt,
            displayFormats: {
              hour:  'HH:mm',
              day:   'MMM d',
              week:  'MMM d',
              month: 'MMM yyyy'
            }
          },
          grid:  { color: GRID },
          ticks: { color: MUTED, maxTicksLimit: 12, font: { family: 'JetBrains Mono', size: 10 } }
        },
        y: {
          min: 0, max: 100,
          grid:  { color: GRID },
          ticks: { color: MUTED, font: { family: 'JetBrains Mono', size: 10 }, callback: v => v + '%' }
        }
      }
    }
  });
}

function applyFilter(days) {
  const cfg = PERIODS[days];
  document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
  document.querySelector('.filter-btn[data-days="' + days + '"]').classList.add('active');
  document.getElementById('history-title').textContent = 'Performance History — ' + cfg.label;

  Object.keys(charts).forEach(id => {
    const m  = chartMeta[id];
    const d  = aggregateData(allData[id], days, cfg.bucketMs);
    const ds = charts[id].data.datasets[0];
    ds.data                 = d;
    ds.pointBackgroundColor = d.map(p => colorForValue(p.y, m.warn, m.crit));
    ds.pointRadius          = d.length > 60 ? 0 : 3;
    charts[id].options.scales.x.time.unit         = cfg.unit;
    charts[id].options.scales.x.time.tooltipFormat = cfg.tooltipFmt;
    charts[id].update('none');
  });
}

// Default: last 7 days — minimum meaningful window
makeChart('chartCpu',  7);
makeChart('chartRam',  7);
makeChart('chartDisk', 7);
</script>

</body>
</html>
"@

[System.IO.File]::WriteAllText($ReportFile, $html, [System.Text.UTF8Encoding]::new($false))
Write-OK "Report written: $ReportFile"
try { Start-Process $ReportFile } catch {}

# ---------- Publish to GitHub Pages -----------------------------------------
Write-Step "Publishing to GitHub Pages"
$publishScript = Join-Path $PSScriptRoot 'Publish-Report.ps1'
if (-not $publishScript -or -not (Test-Path $publishScript)) {
    $publishScript = 'C:\Projects\LaptopMonitor\Publish-Report.ps1'
}
if (Test-Path $publishScript) {
    & powershell.exe -ExecutionPolicy Bypass -File $publishScript
} else {
    Write-Warn "Publish-Report.ps1 not found -- skipping GitHub push."
}

# ---------- Telegram report -------------------------------------------------
Write-Step "Sending Telegram report"
$telegramScript = Join-Path $PSScriptRoot 'Send-TelegramReport.py'
if (-not (Test-Path $telegramScript)) { $telegramScript = 'C:\Projects\LaptopMonitor\Send-TelegramReport.py' }
if (Test-Path $telegramScript) {
    python $telegramScript --report $ReportFile
} else {
    Write-Warn "Send-TelegramReport.py not found -- skipping Telegram."
}

# ---------- Summary ---------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Magenta
Write-Host " Done." -ForegroundColor Magenta
Write-Host "================================================" -ForegroundColor Magenta
Write-Host " Report : $ReportFile"
Write-Host " History: $dayCount days / $($buckets.Count) 30-min buckets"
Write-Host ""
