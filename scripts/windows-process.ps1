function Join-SupexProcessArguments {
    param([string[]]$Arguments)

    ($Arguments | ForEach-Object {
        if ($null -eq $_) {
            '""'
        } elseif ($_ -eq "") {
            '""'
        } elseif ($_ -notmatch '[\s"]') {
            $_
        } else {
            $quoted = '"'
            $backslashes = 0

            foreach ($char in $_.ToCharArray()) {
                if ($char -eq '\') {
                    $backslashes += 1
                } elseif ($char -eq '"') {
                    $quoted += '\' * (($backslashes * 2) + 1)
                    $quoted += '"'
                    $backslashes = 0
                } else {
                    if ($backslashes -gt 0) {
                        $quoted += '\' * $backslashes
                        $backslashes = 0
                    }
                    $quoted += $char
                }
            }

            if ($backslashes -gt 0) {
                $quoted += '\' * ($backslashes * 2)
            }
            $quoted += '"'
            $quoted
        }
    }) -join " "
}

function Invoke-SupexLoggedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$StdoutLog,
        [Parameter(Mandatory = $true)][string]$StderrLog
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    try {
        [Console]::InputEncoding = $utf8NoBom
        [Console]::OutputEncoding = $utf8NoBom
    } catch {
        # Encoding setters may be unavailable when hosted without a console.
    }

    $stdoutWriter = New-Object System.IO.StreamWriter -ArgumentList $StdoutLog, $true, $utf8NoBom
    $stderrWriter = New-Object System.IO.StreamWriter -ArgumentList $StderrLog, $true, $utf8NoBom

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = Join-SupexProcessArguments -Arguments $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    if ($process.StartInfo.GetType().GetProperty("StandardOutputEncoding")) {
        $process.StartInfo.StandardOutputEncoding = $utf8NoBom
    }
    if ($process.StartInfo.GetType().GetProperty("StandardErrorEncoding")) {
        $process.StartInfo.StandardErrorEncoding = $utf8NoBom
    }

    $process.add_OutputDataReceived({
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) {
            [Console]::Out.WriteLine($eventArgs.Data)
            $stdoutWriter.WriteLine($eventArgs.Data)
            $stdoutWriter.Flush()
        }
    })
    $process.add_ErrorDataReceived({
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) {
            [Console]::Error.WriteLine($eventArgs.Data)
            $stderrWriter.WriteLine($eventArgs.Data)
            $stderrWriter.Flush()
        }
    })

    try {
        [void]$process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        $stdoutWriter.Dispose()
        $stderrWriter.Dispose()
        $process.Dispose()
    }
}
