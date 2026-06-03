param(
    [Alias("e")][switch]$E2E,
    [Alias("l")][switch]$List,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Suites
)

$ErrorActionPreference = "Stop"

$SupexRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$AllSuites = @(
    [ordered]@{ Slug = "driver"; Display = "Python Driver Tests"; Directory = "driver"; Command = "uv"; Args = @("run", "python", "-m", "pytest", "tests/"); E2E = $false },
    [ordered]@{ Slug = "stdlib"; Display = "Ruby Stdlib Tests"; Directory = "stdlib"; Command = "bundle"; Args = @("exec", "rake", "test"); E2E = $false },
    [ordered]@{ Slug = "runtime"; Display = "Ruby Runtime Tests"; Directory = "runtime"; Command = "bundle"; Args = @("exec", "rake", "test"); E2E = $false },
    [ordered]@{ Slug = "mock"; Display = "Ruby Mock Tests"; Directory = "mock"; Command = "bundle"; Args = @("exec", "rake", "test"); E2E = $false },
    [ordered]@{ Slug = "sidecar"; Display = "VCAD Sidecar Tests"; Directory = "vcad\sidecar"; Command = "cargo"; Args = @("test"); E2E = $false },
    [ordered]@{ Slug = "viewer"; Display = "VCAD Viewer Tests"; Directory = "vcad\viewer"; Command = "npx"; Args = @("vitest", "run"); E2E = $false },
    [ordered]@{ Slug = "radar"; Display = "Radar Tests"; Directory = "devtools\radar"; Command = "uv"; Args = @("run", "python", "-m", "pytest", "tests/"); E2E = $false },
    [ordered]@{ Slug = "e2e"; Display = "E2E Tests"; Directory = "tests"; Command = "uv"; Args = @("run", "python", "-m", "pytest", "e2e/", "-v"); E2E = $true }
)

function Show-Suites {
    Write-Host "Available test suites:"
    Write-Host ""
    foreach ($Suite in $AllSuites) {
        $Suffix = if ($Suite.E2E) { " (requires -E2E)" } else { "" }
        Write-Host ("  {0,-12} {1}{2}" -f $Suite.Slug, $Suite.Display, $Suffix)
    }
}

if ($List) {
    Show-Suites
    exit 0
}

$KnownSuites = @{}
foreach ($Suite in $AllSuites) {
    $KnownSuites[$Suite.Slug] = $Suite
}

foreach ($Slug in $Suites) {
    if (-not $KnownSuites.ContainsKey($Slug)) {
        [Console]::Error.WriteLine("Unknown test suite: $Slug")
        Show-Suites
        exit 1
    }
}

$Selected = @()
foreach ($Suite in $AllSuites) {
    if ($Suites.Count -gt 0) {
        if ($Suites -contains $Suite.Slug) {
            $Selected += $Suite
        }
    } elseif ($E2E) {
        if ($Suite.E2E) {
            $Selected += $Suite
        }
    } elseif (-not $Suite.E2E) {
        $Selected += $Suite
    }
}

$Failed = @()
$Passed = @()

foreach ($Suite in $Selected) {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "Running $($Suite.Display)"
    Write-Host "========================================"
    Write-Host ""

    $SuiteDir = Join-Path $SupexRoot $Suite.Directory
    if (-not (Test-Path $SuiteDir -PathType Container)) {
        [Console]::Error.WriteLine("Directory not found: $SuiteDir")
        $Failed += $Suite.Display
        continue
    }

    Push-Location $SuiteDir
    try {
        & $Suite.Command @($Suite.Args)
        if ($LASTEXITCODE -eq 0) {
            Write-Host "$($Suite.Display) passed"
            $Passed += $Suite.Display
        } else {
            [Console]::Error.WriteLine("$($Suite.Display) failed")
            $Failed += $Suite.Display
        }
    } catch {
        [Console]::Error.WriteLine($_)
        $Failed += $Suite.Display
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "Test Summary"
Write-Host "========================================"
Write-Host ""
Write-Host "Passed ($($Passed.Count)): $($Passed -join ', ')"

if ($Failed.Count -gt 0) {
    Write-Host "Failed ($($Failed.Count)): $($Failed -join ', ')"
    exit 1
}

Write-Host "All selected test suites passed"
exit 0
