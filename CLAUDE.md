# LaptopMonitor — Project Memory

## Purpose

A lightweight, dependency-free Windows 10 laptop performance monitoring system
built on native Windows tooling (logman, relog, Task Scheduler, CIM/WMI).

It runs silently in the background 24/7, collecting binary performance counters,
and generates a self-contained dark-theme HTML report every morning at 07:00
that opens in any browser without needing a web server.

---

## File Map

| File | Role |
|------|------|
| `Setup-Collector.ps1` | **One-time setup** (run as Admin). Creates the `Laptop_Perf_Monitor` logman data collector set and registers the boot-time startup task. |
| `Generate-Report.ps1` | **Daily report generator**. Rotates the active .blg, parses 24h metrics, snapshots live state, and writes `C:\LaptopMonitor\index.html`. Also self-registers its own 07:00 scheduled task on first run. |
| `CLAUDE.md` | This file — project documentation and design rationale. |

### Output paths

| Path | Contents |
|------|----------|
| `C:\PerfLogs\Laptop\` | `.blg` binary performance log files written by logman |
| `C:\PerfLogs\Laptop\export_temp.csv` | Transient CSV exported by relog (overwritten each run) |
| `C:\LaptopMonitor\index.html` | The generated HTML report (overwritten each run) |

---

## Key Design Decisions

### Why relog for CSV export instead of PDH COM or TypePerf?

`relog` ships with every Windows version and requires no PowerShell modules,
COM interop, or elevation beyond what the report script already needs.
The PDH COM object (`New-Object -ComObject 'PDH.Query'`) is faster but breaks
on non-English locales and throws undiagnosable `0x80070057` errors when column
names don't match the system's counter name language.  `relog` always outputs
invariant-culture CSV regardless of locale — predictable and portable.

### Why `((Get-Date) - $os.LastBootUpTime).TotalHours` for uptime?

The common pattern `(Get-Date) - (Get-Date $os.LastBootUpTime)` can silently
fail on locales where the WMI datetime string (`20240523120000.000000+060`)
isn't automatically coerced by PowerShell's date parser.  TimeSpan subtraction
(`(Get-Date) - $os.LastBootUpTime`) works because `LastBootUpTime` is already a
`[datetime]` object returned by CIM — no string parsing involved.

### Why separate collector (Setup) vs generator (Generate)?

- **Reliability**: The collector runs as SYSTEM at startup and never stops even
  if the report generator crashes, errors, or is manually aborted.
- **Data integrity**: Stopping the collector only during the brief rotation
  window (≈2 seconds) means at most one 30-second sample is lost per day.
- **Least privilege**: The generator runs as the current user (Interactive
  logon) — it doesn't need SYSTEM rights to read CSVs or write HTML.
- **Debuggability**: You can re-run the generator at any time without touching
  the collector.

### Why binary .blg format instead of CSV directly from logman?

`.blg` (BLG = Binary Log) is circular, compact, and survives logman restarts
without file-handle conflicts.  Direct CSV from logman cannot be rotated
without stopping the collector and the file grows unbounded.  The relog
conversion step is the intentional bridge.

### Why `New-ScheduledTaskTrigger -Daily -At '07:00'` as a string?

Passing a `[datetime]` object to `-At` can cause locale-dependent serialisation
issues in the XML that Task Scheduler stores.  The string `'07:00'` is parsed
by Task Scheduler's own XML engine which is always locale-independent.

---

## Common Gotchas

### 1. The `%datetime%` literal in logman filenames

When you create a collector with `-o "C:\PerfLogs\Laptop\Laptop_Perf_%datetime%.blg"`,
logman does **not** expand `%datetime%` at creation time.  The actual file on
disk will literally contain the string `%datetime%` in its filename until
logman decides to roll it over (when the file hits `-max` size).

`Generate-Report.ps1` detects this at rotation time:
```powershell
if ($newest.Name -match '%datetime%') {
    Rename-Item -Path $newest.FullName -NewName "Laptop_Perf_$(Get-Date -Format 'yyyyMMdd_HHmm').blg"
}
```

Do **not** try to predict the filename — always inspect `Get-ChildItem` output.

### 2. Locale datetime parsing in relog CSV output

`relog` exports timestamps in the system locale's short date format on some
Windows builds.  The CSV parser uses `[datetime]::TryParse()` which respects
`CurrentCulture`.  If you see all trend rows blank, verify the timestamp format
with:
```powershell
Import-Csv C:\PerfLogs\Laptop\export_temp.csv | Select-Object -First 3
```
If the first column shows e.g. `23/05/2024 12:00:00` you may need to pass
`[System.Globalization.CultureInfo]::CurrentCulture` as the third argument to
`[datetime]::TryParse()`.

### 3. `Get-Date` arithmetic vs string parsing

**Safe** (no string involved):
```powershell
$uptime = ((Get-Date) - $os.LastBootUpTime).TotalHours
```

**Unsafe** (locale-sensitive):
```powershell
$uptime = ((Get-Date) - (Get-Date $os.LastBootUpTime)).TotalHours  # can fail
```

### 4. Task trigger string vs DateTime object

**Safe** (Task Scheduler parses the time string independently):
```powershell
New-ScheduledTaskTrigger -Daily -At '07:00'
```

**Risky** (DateTime serialised differently across cultures):
```powershell
New-ScheduledTaskTrigger -Daily -At ([datetime]'07:00')
```

### 5. `logman` exit codes

`logman` returns non-zero for expected conditions (already running, already
stopped).  Wrap logman calls with `2>&1 | Out-Null` and check `$LASTEXITCODE`
only when you actually care about the state transition.

### 6. relog and open file handles

`relog` cannot export a `.blg` that logman currently has open for writing.
Always `logman stop` → `Start-Sleep 2` → `relog` → `logman start`.
The 2-second sleep allows the OS to flush and close the file handle.

---

## Routine Commands

### Manually trigger the report (any time)
```powershell
PowerShell -ExecutionPolicy Bypass -File C:\Projects\LaptopMonitor\Generate-Report.ps1
```

### Stop / start the collector
```powershell
logman stop  Laptop_Perf_Monitor
logman start Laptop_Perf_Monitor
```

### Query collector status
```powershell
logman query Laptop_Perf_Monitor
```
Look for `Status: Running` in the output.

### Convert a specific .blg to CSV by hand
```powershell
relog "C:\PerfLogs\Laptop\Laptop_Perf_20240523_0700.blg" -f CSV -o "C:\Temp\out.csv" -y
```

### Open the latest report
```powershell
Start-Process C:\LaptopMonitor\index.html
```

### List all LaptopMonitor scheduled tasks
```powershell
Get-ScheduledTask -TaskPath '\LaptopMonitor\' | Format-Table TaskName, State
Get-ScheduledTask -TaskPath '\LaptopMonitor\' | Get-ScheduledTaskInfo
```

### Uninstall everything
```powershell
# 1. Stop and delete collector
logman stop   Laptop_Perf_Monitor
logman delete Laptop_Perf_Monitor

# 2. Remove scheduled tasks
Unregister-ScheduledTask -TaskPath '\LaptopMonitor\' -TaskName 'Start Laptop Perf Monitor'  -Confirm:$false
Unregister-ScheduledTask -TaskPath '\LaptopMonitor\' -TaskName 'Generate Morning Report'     -Confirm:$false

# 3. Remove log and report directories (optional — keeps historical data if omitted)
Remove-Item -Recurse -Force C:\PerfLogs\Laptop
Remove-Item -Recurse -Force C:\LaptopMonitor

# 4. Remove scripts
Remove-Item -Recurse -Force C:\Projects\LaptopMonitor
```

---

## Architecture Diagram

```
  [Boot]
    │
    └─► Task: Start Laptop Perf Monitor (SYSTEM)
              │
              └─► logman start Laptop_Perf_Monitor
                        │
                        └─► Writes C:\PerfLogs\Laptop\Laptop_Perf_%datetime%.blg
                                  (every 30 seconds, circular binary format)

  [07:00 daily]
    │
    └─► Task: Generate Morning Report (current user)
              │
              ├─► logman stop  → rename .blg → logman start
              ├─► relog .blg → export_temp.csv
              ├─► Import-Csv → compute 24h averages
              ├─► Get-CimInstance → live snapshot + top 30 processes
              └─► Write-HTML → C:\LaptopMonitor\index.html
```
