param(
    [switch]$SkipLaunch,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SupexRoot = Split-Path -Parent $ScriptDir
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = "powershell.exe"
}

if (-not $env:SUPEX_WORKSPACE) {
    $env:SUPEX_WORKSPACE = $SupexRoot
}
if (-not $env:SUPEX_LOG_DIR) {
    $env:SUPEX_LOG_DIR = Join-Path $env:SUPEX_WORKSPACE ".tmp\logs"
}
New-Item -ItemType Directory -Force -Path $env:SUPEX_LOG_DIR | Out-Null

$LogZip = Join-Path $env:SUPEX_LOG_DIR "windows-smoke-logs.zip"

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    Write-Host ""
    Write-Host "== $Name =="
    & $Body
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

try {
    Invoke-Step "Check uv" { & uv --version }
    Invoke-Step "Check driver" { & uv run --project (Join-Path $SupexRoot "driver") supex --help *> $null }

    if (-not $SkipLaunch) {
        $LaunchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ScriptDir "launch-sketchup.ps1"), "-Detach")
        if ($Restart) {
            $LaunchArgs += "-Restart"
        }
        Invoke-Step "Launch SketchUp" { & $PowerShellExe @LaunchArgs }
    }

    Invoke-Step "Supex status" {
        & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $SupexRoot "supex.ps1") status
    }
    Invoke-Step "Ruby eval" {
        & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $SupexRoot "supex.ps1") eval "Sketchup.version"
    }

    Write-Host ""
    Write-Host "Windows smoke test passed"
} finally {
    if (Test-Path $env:SUPEX_LOG_DIR -PathType Container) {
        if (Test-Path $LogZip -PathType Leaf) {
            Remove-Item $LogZip -Force
        }
        $LogItems = @(Get-ChildItem -Path $env:SUPEX_LOG_DIR -Force -ErrorAction SilentlyContinue)
        if ($LogItems.Count -gt 0) {
            Compress-Archive -Path (Join-Path $env:SUPEX_LOG_DIR "*") -DestinationPath $LogZip -Force
            Write-Host "Logs archived to $LogZip"
        }
    }
}
