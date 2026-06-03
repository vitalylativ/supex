param(
    [string]$Year = $env:SUPEX_SKETCHUP_YEAR,
    [string]$PluginsDir = $env:SUPEX_SKETCHUP_PLUGINS_DIR,
    [switch]$SkipUvInstall,
    [switch]$Wait,
    [int]$WaitTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SupexRoot = Split-Path -Parent $ScriptDir
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = "powershell.exe"
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Host ""
    Write-Host "== $Name =="
}

function Add-PathForCurrentProcess {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ((Test-Path $Path -PathType Container) -and
        -not ($env:PATH.Split([IO.Path]::PathSeparator) -contains $Path)) {
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Ensure-Uv {
    $Uv = Get-Command "uv" -CommandType Application -ErrorAction SilentlyContinue
    if ($Uv) {
        & $Uv.Source --version
        return
    }

    if ($SkipUvInstall) {
        throw "uv is not installed. Install uv or rerun without -SkipUvInstall."
    }

    Write-Host "uv not found; installing with the official Astral standalone installer..."
    & $PowerShellExe -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
    if ($LASTEXITCODE -ne 0) {
        throw "uv installer failed with exit code $LASTEXITCODE"
    }

    Add-PathForCurrentProcess -Path (Join-Path $env:USERPROFILE ".local\bin")

    $Uv = Get-Command "uv" -CommandType Application -ErrorAction SilentlyContinue
    if (-not $Uv) {
        throw "uv installed, but uv.exe is not on PATH yet. Open a new PowerShell window and rerun this script."
    }

    & $Uv.Source --version
}

function Invoke-DriverCheck {
    $DriverProject = Join-Path $SupexRoot "driver"
    & cmd.exe /c "uv run --project `"$DriverProject`" supex --help >NUL 2>NUL"
    if ($LASTEXITCODE -ne 0) {
        throw "Supex driver check failed with exit code $LASTEXITCODE"
    }
}

function Install-DevLoader {
    $Args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ScriptDir "install-dev-extension.ps1"))
    if ($Year) {
        $Args += @("-Year", $Year)
    }
    if ($PluginsDir) {
        $Args += @("-PluginsDir", $PluginsDir)
    }

    & $PowerShellExe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Dev extension loader installation failed with exit code $LASTEXITCODE"
    }
}

function Wait-ForSketchUpRuntime {
    $Deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    $StatusArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $SupexRoot "supex.ps1"),
        "status"
    )

    Write-Host "Launch SketchUp manually now, then open or create a model."
    Write-Host "Waiting up to ${WaitTimeoutSeconds}s for Supex to become ready..."

    while ((Get-Date) -lt $Deadline) {
        & $PowerShellExe @StatusArgs *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Supex runtime is ready."
            return
        }
        Start-Sleep -Seconds 5
    }

    throw "Timed out waiting for SketchUp with the Supex runtime. Launch SketchUp manually and run .\scripts\windows-smoke.ps1 -SkipLaunch."
}

Write-Host "Supex Windows setup"
Write-Host "Repository: $SupexRoot"

if (-not $env:SUPEX_WORKSPACE) {
    $env:SUPEX_WORKSPACE = $SupexRoot
}
if (-not $env:SUPEX_LOG_DIR) {
    $env:SUPEX_LOG_DIR = Join-Path $env:SUPEX_WORKSPACE ".tmp\logs"
}
New-Item -ItemType Directory -Force -Path $env:SUPEX_LOG_DIR | Out-Null

Write-Step "Check uv"
Ensure-Uv

Write-Step "Check Supex driver"
Invoke-DriverCheck

Write-Step "Install SketchUp dev loader"
Install-DevLoader

Write-Step "MCP command"
Write-Host "Use this command in Codex, Claude Code, or another MCP client:"
Write-Host "$PowerShellExe -ExecutionPolicy Bypass -File `"$SupexRoot\mcp.ps1`""

if ($Wait) {
    Write-Step "Wait for manual SketchUp launch"
    Wait-ForSketchUpRuntime

    Write-Step "Smoke test"
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "windows-smoke.ps1") -SkipLaunch
    if ($LASTEXITCODE -ne 0) {
        throw "Windows smoke test failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Step "Next step"
    Write-Host "Launch SketchUp manually, open or create a model, then verify with:"
    Write-Host ".\scripts\windows-smoke.ps1 -SkipLaunch"
}

Write-Host ""
Write-Host "Windows setup complete"
