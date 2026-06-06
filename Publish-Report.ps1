# Publish-Report.ps1
# Commits the latest index.html from C:\LaptopMonitor to the gh-pages branch
# and pushes to GitHub so GitHub Pages serves the updated report.
#
# Called automatically by Generate-Report.ps1 after writing the HTML.
# Can also be run manually:
#   PowerShell -ExecutionPolicy Bypass -File C:\Projects\LaptopMonitor\Publish-Report.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # git writes harmless warnings to stderr; don't treat them as fatal

$ReportDir = 'C:\LaptopMonitor'
$ReportFile = "$ReportDir\index.html"

function Write-Step ([string]$Msg) { Write-Host ""; Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-OK   ([string]$Msg) { Write-Host "    OK  $Msg" -ForegroundColor Green }
function Write-Warn ([string]$Msg) { Write-Host "    !!  $Msg" -ForegroundColor Yellow }

# ---------- Verify report exists --------------------------------------------
if (-not (Test-Path $ReportFile)) {
    Write-Host "ERROR: $ReportFile not found. Run Generate-Report.ps1 first." -ForegroundColor Red
    exit 1
}

# ---------- Commit and push -------------------------------------------------
Write-Step "Publishing report to GitHub Pages"

Push-Location $ReportDir
try {
    # Stage only index.html (ignore any other files in the folder)
    git add index.html

    # Check if there is anything new to commit
    $status = git status --porcelain
    if (-not $status) {
        Write-Warn "No changes detected in index.html -- skipping commit."
    } else {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        git commit -m "report: $stamp" --quiet
        Write-OK "Committed: report: $stamp"
    }

    # Push to gh-pages
    git push origin gh-pages --quiet
    Write-OK "Pushed to origin/gh-pages"

    Write-Host ""
    Write-Host "    Live at: https://flomaticauto.github.io/laptop-monitor/" -ForegroundColor Green
    Write-Host "    (GitHub Pages may take 1-2 minutes to update)" -ForegroundColor DarkGray

} catch {
    Write-Host ""
    Write-Host "ERROR during git push: $_" -ForegroundColor Red
    exit 1
} finally {
    Pop-Location
}
