# Stream a Hermes child process without waiting on descendant-held pipe EOF.
# Dot-sourced by windows.ps1 and the native-Windows behavioral regression.

function Invoke-HermesStep([string]$Exe, [string[]]$HermesArgs, [string]$Tag) {
    # Polling the direct child keeps WinForms pumping during long silent
    # stretches. Drain both streams asynchronously: descendants can inherit
    # redirected handles on Windows, so EOF is not a valid completion signal
    # and stderr must not be allowed to fill while stdout is being read.
    # Full output still lands in the hand-off log and return object.
    $stepTempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $outFile = Join-Path $stepTempDir ("hermes-handoff-{0}-{1}.out" -f $Tag, $PID)
    $errFile = Join-Path $stepTempDir ("hermes-handoff-{0}-{1}.err" -f $Tag, $PID)
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    # System.Diagnostics.Process directly: Start-Process's .ExitCode is
    # unreliably $null under PS 5.1 even with the Handle-touch workaround.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    # .Arguments string (PS 5.1 / .NET Framework has no ArgumentList).
    # Args here are fixed flags + a branch ref; quote each defensively.
    $psi.Arguments = ($HermesArgs | ForEach-Object { '"{0}"' -f ($_ -replace '"', '\"') }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # hermes update prints UTF-8 (checkmarks, arrows, box glyphs). PS 5.1
    # defaults these readers to the OEM codepage, which mangles every
    # multi-byte glyph into mojibake in the log.
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # And ask the child to actually EMIT UTF-8: Python decides its stdio
    # encoding from the console codepage when attached to one.
    $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
    $psi.EnvironmentVariables["PYTHONUTF8"] = "1"
    $psi.CreateNoWindow = $true
    $outWriter = [System.IO.File]::CreateText($outFile)
    $errWriter = [System.IO.File]::CreateText($errFile)
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $started = $false
    $state = $null
    $canDispose = $false
    try {
        $started = $proc.Start()
        if (-not $started) { throw "Could not start $Exe" }
        $state = @{
            OutEof = $false
            ErrEof = $false
            OutTask = $proc.StandardOutput.ReadLineAsync()
            ErrTask = $proc.StandardError.ReadLineAsync()
        }

        # ReadLineAsync avoids PowerShell event callbacks, which run without a
        # reliable runspace under Windows PowerShell 5.1.
        $drainReadyLines = {
            do {
                $madeProgress = $false
                if (-not $state.OutEof -and $state.OutTask.IsCompleted) {
                    try { $ln = $state.OutTask.GetAwaiter().GetResult() }
                    catch { $ln = $null }
                    if ($null -eq $ln) {
                        $state.OutEof = $true
                    } else {
                        $outWriter.WriteLine($ln)
                        if ($ln.Trim()) { Write-HandoffLog ("{0}| {1}" -f $Tag, $ln) }
                        $state.OutTask = $proc.StandardOutput.ReadLineAsync()
                    }
                    $madeProgress = $true
                }
                if (-not $state.ErrEof -and $state.ErrTask.IsCompleted) {
                    try { $ln = $state.ErrTask.GetAwaiter().GetResult() }
                    catch { $ln = $null }
                    if ($null -eq $ln) {
                        $state.ErrEof = $true
                    } else {
                        $errWriter.WriteLine($ln)
                        if ($ln.Trim()) { Write-HandoffLog ("{0}!| {1}" -f $Tag, $ln) }
                        $state.ErrTask = $proc.StandardError.ReadLineAsync()
                    }
                    $madeProgress = $true
                }
            } while ($madeProgress)
        }

        while (-not $proc.HasExited) {
            & $drainReadyLines
            if (-not $proc.HasExited) { $proc.WaitForExit(25) | Out-Null }
            if ($script:Ui) { [System.Windows.Forms.Application]::DoEvents() }
        }
        $code = $proc.ExitCode

        # Direct-child exit is authoritative. A gateway descendant can keep
        # the inherited pipe handles open forever, so accept only a short grace
        # period for reads already in flight; never block waiting for EOF.
        $drainDeadline = (Get-Date).AddMilliseconds(300)
        do {
            & $drainReadyLines
            if ($script:Ui) { [System.Windows.Forms.Application]::DoEvents() }
            if ($state.OutEof -and $state.ErrEof) { break }
            Start-Sleep -Milliseconds 25
        } while ((Get-Date) -lt $drainDeadline)
        & $drainReadyLines
        $canDispose = $state.OutEof -and $state.ErrEof
    } finally {
        $outWriter.Close()
        $errWriter.Close()
        # Closing a stream with ReadLineAsync still pending can itself wait on
        # the descendant-held handle. The pending read dies with this host.
        if (-not $started -or $canDispose) { $proc.Dispose() }
    }

    $errText = ""
    try { $errText = [System.IO.File]::ReadAllText($errFile) } catch {}
    $all = ""
    try { $all = [System.IO.File]::ReadAllText($outFile) } catch {}
    if ($errText) { $all += "`n" + $errText }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return @{ Code = $code; Output = $all }
}
