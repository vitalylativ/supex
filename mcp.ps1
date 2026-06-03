param()

$ErrorActionPreference = "Stop"

$SupexRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $env:SUPEX_WORKSPACE) {
    $env:SUPEX_WORKSPACE = (Get-Location).Path
}

$LogDir = if ($env:SUPEX_LOG_DIR) { $env:SUPEX_LOG_DIR } else { Join-Path $env:SUPEX_WORKSPACE ".tmp\logs" }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$ProtocolLog = Join-Path $LogDir "mcp-protocol.jsonl"
$StderrLog = Join-Path $LogDir "mcp-stderr.log"

. (Join-Path $SupexRoot "scripts\windows-process.ps1")

$Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
try {
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
} catch {
    # Encoding setters may be unavailable when hosted without a console.
}

$ProtocolWriter = New-Object System.IO.StreamWriter -ArgumentList $ProtocolLog, $true, $Utf8NoBom
$StderrWriter = New-Object System.IO.StreamWriter -ArgumentList $StderrLog, $true, $Utf8NoBom
$ProtocolLock = New-Object object

function Write-ProtocolLine {
    param([string]$Line)

    [System.Threading.Monitor]::Enter($ProtocolLock)
    try {
        $ProtocolWriter.WriteLine($Line)
        $ProtocolWriter.Flush()
    } finally {
        [System.Threading.Monitor]::Exit($ProtocolLock)
    }
}

$DriverProject = Join-Path $SupexRoot "driver"
$Process = New-Object System.Diagnostics.Process
$Process.StartInfo.FileName = "uv"
$Process.StartInfo.Arguments = Join-SupexProcessArguments -Arguments @("run", "--project", $DriverProject, "supex-mcp")
$Process.StartInfo.UseShellExecute = $false
$Process.StartInfo.RedirectStandardInput = $true
$Process.StartInfo.RedirectStandardOutput = $true
$Process.StartInfo.RedirectStandardError = $true
if ($Process.StartInfo.GetType().GetProperty("StandardInputEncoding")) {
    $Process.StartInfo.StandardInputEncoding = $Utf8NoBom
}
if ($Process.StartInfo.GetType().GetProperty("StandardOutputEncoding")) {
    $Process.StartInfo.StandardOutputEncoding = $Utf8NoBom
}
if ($Process.StartInfo.GetType().GetProperty("StandardErrorEncoding")) {
    $Process.StartInfo.StandardErrorEncoding = $Utf8NoBom
}

$Process.add_OutputDataReceived({
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
        Write-ProtocolLine $eventArgs.Data
        [Console]::Out.WriteLine($eventArgs.Data)
    }
})
$Process.add_ErrorDataReceived({
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
        $StderrWriter.WriteLine($eventArgs.Data)
        $StderrWriter.Flush()
        [Console]::Error.WriteLine($eventArgs.Data)
    }
})

try {
    [void]$Process.Start()
    $Process.BeginOutputReadLine()
    $Process.BeginErrorReadLine()

    while ($null -ne ($Line = [Console]::In.ReadLine())) {
        Write-ProtocolLine $Line
        if ($Process.HasExited) {
            break
        }
        $Process.StandardInput.WriteLine($Line)
        $Process.StandardInput.Flush()
    }

    if (-not $Process.HasExited) {
        $Process.StandardInput.Close()
    }
    $Process.WaitForExit()
    exit $Process.ExitCode
} finally {
    $ProtocolWriter.Dispose()
    $StderrWriter.Dispose()
    $Process.Dispose()
}
