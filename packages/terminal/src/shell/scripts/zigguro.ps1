# zigguro shell integration for PowerShell (pwsh 7 and Windows PowerShell
# 5.1), version 1.
# Copyright the zigguro authors. Licensed under the Apache License 2.0.
# Protocol: docs/shell-integration.md (OSC 133 A/B/C/D, OSC 633 E/P, OSC 7, OSC 9;9).
#
# zigguro starts PowerShell with `-NoExit -Command ". '<this file>'"`
# after the user's profile has run. The prompt returns a string and
# never writes to the host.

if ($Global:__zgInstalled) { return }
$Global:__zgInstalled = $true

$Global:__zgNonce = $env:ZIGGURO_NONCE
Remove-Item Env:ZIGGURO_NONCE -ErrorAction SilentlyContinue
$Global:__zgEsc = [char]27
$Global:__zgBel = [char]7
$Global:__zgLastHistory = -1
$Global:__zgProps = $true
$Global:__zgOrigPrompt = $function:prompt

function Global:__zgEscape([string]$s) {
    $b = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '\') { [void]$b.Append('\\') }
        elseif ($c -eq ';') { [void]$b.Append('\x3b') }
        elseif ([int]$c -lt 32) { [void]$b.Append(('\x{0:x2}' -f [int]$c)) }
        else { [void]$b.Append($c) }
    }
    $b.ToString()
}

function Global:__zgOsc([string]$body) {
    "$Global:__zgEsc]$body$Global:__zgBel"
}

function Global:prompt {
    # The exit code first, before anything else changes it.
    $ok = $?
    $native = $Global:LASTEXITCODE
    $out = ''
    if ($Global:__zgProps) {
        $Global:__zgProps = $false
        $out += (__zgOsc '633;P;Shell=pwsh') + (__zgOsc '633;P;IntegrationVersion=1')
    }
    $last = Get-History -Count 1
    if ($last -and $last.Id -ne $Global:__zgLastHistory -and $Global:__zgLastHistory -ne -1) {
        $code = if ($ok) { 0 } elseif ($native -is [int] -and $native -ne 0) { $native } else { 1 }
        $out += __zgOsc "133;D;$code"
    }
    $Global:__zgLastHistory = if ($last) { $last.Id } else { 0 }
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($loc.Provider.Name -eq 'FileSystem') {
        $p = $loc.ProviderPath
        $out += __zgOsc "9;9;`"$p`""
        $uri = ([System.Uri]$p).AbsoluteUri
        $out += __zgOsc "7;$uri"
    }
    $out += __zgOsc '133;A'
    $orig = & $Global:__zgOrigPrompt
    $out += [string]::Concat($orig)
    $out += __zgOsc '133;B'
    $Global:LASTEXITCODE = $native
    $out
}

# With PSReadLine, the line is known once Enter is pressed.
if (Get-Module PSReadLine) {
    $Global:__zgOrigReadLine = $function:PSConsoleHostReadLine
    function Global:PSConsoleHostReadLine {
        $line = & $Global:__zgOrigReadLine
        $e = __zgEscape $line
        [Console]::Write((__zgOsc "633;E;$e;$Global:__zgNonce") + (__zgOsc '133;C'))
        $line
    }
}
