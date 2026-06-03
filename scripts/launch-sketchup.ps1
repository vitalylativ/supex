param(
    [Parameter(Position = 0)]
    [string]$ModelPath,
    [switch]$Detach,
    [switch]$Restart,
    [switch]$NoWaitReady,
    [switch]$UseInstalledExtension
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SupexRoot = Split-Path -Parent $ScriptDir
$RuntimeDir = Join-Path $SupexRoot "runtime"
$Injector = Join-Path $RuntimeDir "src\injector.rb"

. (Join-Path $ScriptDir "windows-process.ps1")

function Resolve-SketchUpExe {
    if ($env:SUPEX_SKETCHUP_EXE) {
        if (Test-Path $env:SUPEX_SKETCHUP_EXE -PathType Leaf) {
            return (Resolve-Path $env:SUPEX_SKETCHUP_EXE).Path
        }
        throw "SUPEX_SKETCHUP_EXE is set but does not exist: $env:SUPEX_SKETCHUP_EXE"
    }

    $Candidates = @()
    foreach ($Year in @("2026", "2025", "2024")) {
        if ($env:ProgramFiles) {
            $Candidates += (Join-Path $env:ProgramFiles "SketchUp\SketchUp $Year\SketchUp\SketchUp.exe")
            $Candidates += (Join-Path $env:ProgramFiles "SketchUp\SketchUp $Year\SketchUp.exe")
        }
        if (${env:ProgramFiles(x86)}) {
            $Candidates += (Join-Path ${env:ProgramFiles(x86)} "SketchUp\SketchUp $Year\SketchUp\SketchUp.exe")
            $Candidates += (Join-Path ${env:ProgramFiles(x86)} "SketchUp\SketchUp $Year\SketchUp.exe")
        }
    }

    foreach ($Candidate in $Candidates) {
        if (Test-Path $Candidate -PathType Leaf) {
            return (Resolve-Path $Candidate).Path
        }
    }

    throw "Could not find SketchUp.exe. Set SUPEX_SKETCHUP_EXE to the full path."
}

function Stop-SketchUp {
    $Processes = @(Get-Process -Name "SketchUp" -ErrorAction SilentlyContinue)
    if ($Processes.Count -eq 0) {
        Write-Host "No existing SketchUp process to restart"
        return
    }

    Write-Host "Requesting SketchUp shutdown..."
    foreach ($Process in $Processes) {
        if ($Process.MainWindowHandle -ne 0) {
            [void]$Process.CloseMainWindow()
        }
    }

    $Deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $Deadline) {
        if (-not (Get-Process -Name "SketchUp" -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Seconds 1
    }

    Write-Warning "SketchUp did not exit cleanly; forcing shutdown"
    Get-Process -Name "SketchUp" -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Wait-SupexRuntime {
    $Timeout = if ($env:SUPEX_LAUNCH_READY_TIMEOUT) { [int]$env:SUPEX_LAUNCH_READY_TIMEOUT } else { 60 }
    $Deadline = (Get-Date).AddSeconds($Timeout)
    $DriverProject = Join-Path $SupexRoot "driver"

    $OldAgent = $env:SUPEX_AGENT
    $OldPlain = $env:SUPEX_PLAIN
    try {
        $env:SUPEX_AGENT = "launcher"
        $env:SUPEX_PLAIN = "1"

        Write-Host "Waiting for Supex runtime to accept CLI connections..."
        while ((Get-Date) -lt $Deadline) {
            & uv run --project $DriverProject supex status *> $null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Supex runtime is ready"
                return
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        if ($null -eq $OldAgent) { Remove-Item Env:\SUPEX_AGENT -ErrorAction SilentlyContinue } else { $env:SUPEX_AGENT = $OldAgent }
        if ($null -eq $OldPlain) { Remove-Item Env:\SUPEX_PLAIN -ErrorAction SilentlyContinue } else { $env:SUPEX_PLAIN = $OldPlain }
    }

    throw "Supex runtime did not become ready within ${Timeout}s. Check logs in $env:SUPEX_LOG_DIR"
}

if (-not (Test-Path $Injector -PathType Leaf)) {
    throw "Injector script not found: $Injector"
}

if (-not $env:SUPEX_WORKSPACE) {
    $env:SUPEX_WORKSPACE = (Get-Location).Path
}

if (-not $env:SUPEX_LOG_DIR) {
    $env:SUPEX_LOG_DIR = Join-Path $env:SUPEX_WORKSPACE ".tmp\logs"
}
New-Item -ItemType Directory -Force -Path $env:SUPEX_LOG_DIR | Out-Null

$SketchUpExe = Resolve-SketchUpExe
$LaunchArgs = @()

if ($ModelPath) {
    if (-not (Test-Path $ModelPath -PathType Leaf)) {
        throw "Model file not found: $ModelPath"
    }
    $LaunchArgs += (Resolve-Path $ModelPath).Path
}

if (-not $UseInstalledExtension) {
    $LaunchArgs += @("-RubyStartup", $Injector)
}

if ($Restart) {
    Stop-SketchUp
} elseif (Get-Process -Name "SketchUp" -ErrorAction SilentlyContinue) {
    Write-Warning "SketchUp is already running; it may ignore new -RubyStartup arguments. Use -Restart if Supex is not ready."
}

Write-Host "Launching SketchUp: $SketchUpExe"
Write-Host "Workspace: $env:SUPEX_WORKSPACE"
Write-Host "Logs: $env:SUPEX_LOG_DIR"
if ($UseInstalledExtension) {
    Write-Host "Runtime load: installed SketchUp extension"
} else {
    Write-Host "Runtime load: -RubyStartup $Injector"
}

$StartProcessArgs = @{
    FilePath = $SketchUpExe
    PassThru = $true
}
$JoinedLaunchArgs = Join-SupexProcessArguments -Arguments $LaunchArgs
if ($JoinedLaunchArgs) {
    $StartProcessArgs.ArgumentList = $JoinedLaunchArgs
}

[void](Start-Process @StartProcessArgs)

if (-not $NoWaitReady) {
    Wait-SupexRuntime
} else {
    Write-Warning "Skipping Supex runtime readiness check"
}

if ($Detach) {
    Write-Host "Detached launch complete; SketchUp remains running"
    exit 0
}

Write-Host "Waiting for SketchUp to exit. Press Ctrl+C to stop waiting."
while (Get-Process -Name "SketchUp" -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 1
}
