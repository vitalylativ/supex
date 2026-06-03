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
$UvCommand = Get-Command "uv" -CommandType Application -ErrorAction Stop

$Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
try {
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
} catch {
    # Encoding setters may be unavailable when hosted without a console.
}

$Process = New-Object System.Diagnostics.Process
$Process.StartInfo.FileName = $UvCommand.Source
$Process.StartInfo.Arguments = Join-SupexProcessArguments -Arguments (@("run", "--project", $DriverProject, "supex") + $SupexArgs)
$Process.StartInfo.UseShellExecute = $false
$Process.StartInfo.RedirectStandardOutput = $true
$Process.StartInfo.RedirectStandardError = $true
if ($Process.StartInfo.GetType().GetProperty("StandardOutputEncoding")) {
    $Process.StartInfo.StandardOutputEncoding = $Utf8NoBom
}
if ($Process.StartInfo.GetType().GetProperty("StandardErrorEncoding")) {
    $Process.StartInfo.StandardErrorEncoding = $Utf8NoBom
}

try {
    [void]$Process.Start()
    $Stdout = $Process.StandardOutput.ReadToEnd()
    $Stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()

    if ($Stdout) {
        [Console]::Out.Write($Stdout)
        [System.IO.File]::AppendAllText($StdoutLog, $Stdout, $Utf8NoBom)
    }
    if ($Stderr) {
        [Console]::Error.Write($Stderr)
        [System.IO.File]::AppendAllText($StderrLog, $Stderr, $Utf8NoBom)
    }

    exit $Process.ExitCode
} finally {
    $Process.Dispose()
}
