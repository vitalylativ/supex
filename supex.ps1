param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SupexArgs
)

$ErrorActionPreference = "Stop"

$SupexRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $env:SUPEX_WORKSPACE) {
    $env:SUPEX_WORKSPACE = (Get-Location).Path
}

$LogDir = if ($env:SUPEX_LOG_DIR) { $env:SUPEX_LOG_DIR } else { Join-Path $env:SUPEX_WORKSPACE ".tmp\logs" }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$StdoutLog = Join-Path $LogDir "cli-stdout.log"
$StderrLog = Join-Path $LogDir "cli-stderr.log"

. (Join-Path $SupexRoot "scripts\windows-process.ps1")

$DriverProject = Join-Path $SupexRoot "driver"
$ExitCode = Invoke-SupexLoggedProcess `
    -FilePath "uv" `
    -Arguments (@("run", "--project", $DriverProject, "supex") + $SupexArgs) `
    -StdoutLog $StdoutLog `
    -StderrLog $StderrLog
exit $ExitCode
