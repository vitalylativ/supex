param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SidecarArgs
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SupexRoot = Split-Path -Parent $ScriptDir
$SidecarDir = Join-Path $SupexRoot "vcad\sidecar"
$Binary = Join-Path $SidecarDir "target\release\supex-vcad-sidecar.exe"

if (-not (Test-Path $Binary -PathType Leaf)) {
    Write-Host "Building VCAD sidecar..."
    & cargo build --release --manifest-path (Join-Path $SidecarDir "Cargo.toml")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

& $Binary @SidecarArgs
exit $LASTEXITCODE
