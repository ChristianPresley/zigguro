# hello_ps1: a ZEP extension in PowerShell (5.1 or 7+). It implements
# Content-Length framing on raw stdin/stdout streams and answers
# initialize, command/execute (hello-ps1.say), shutdown and exit.

$ErrorActionPreference = 'Stop'
$stdin = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-Line {
    $bytes = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $stdin.ReadByte()
        if ($b -lt 0) { return $null }
        if ($b -eq 10) { break }
        if ($b -ne 13) { $bytes.Add([byte]$b) }
    }
    return $utf8.GetString($bytes.ToArray())
}

function Read-Message {
    $len = -1
    while ($true) {
        $line = Read-Line
        if ($null -eq $line) { return $null }
        if ($line -eq '') { break }
        if ($line -match '^Content-Length:\s*(\d+)$') { $len = [int]$Matches[1] }
    }
    if ($len -lt 0) { return $null }
    $buf = New-Object byte[] $len
    $off = 0
    while ($off -lt $len) {
        $n = $stdin.Read($buf, $off, $len - $off)
        if ($n -le 0) { return $null }
        $off += $n
    }
    return ($utf8.GetString($buf) | ConvertFrom-Json)
}

function Send-Message($obj) {
    $body = $utf8.GetBytes(($obj | ConvertTo-Json -Depth 20 -Compress))
    $head = $utf8.GetBytes("Content-Length: $($body.Length)`r`n`r`n")
    $stdout.Write($head, 0, $head.Length)
    $stdout.Write($body, 0, $body.Length)
    $stdout.Flush()
}

function Send-Result($id, $result) { Send-Message @{ jsonrpc = '2.0'; id = $id; result = $result } }
function Send-Error($id, $code, $msg) { Send-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = $code; message = $msg } } }

while ($true) {
    $msg = Read-Message
    if ($null -eq $msg) { exit 0 }
    $hasId = $msg.PSObject.Properties.Name -contains 'id'
    switch ($msg.method) {
        'initialize' { Send-Result $msg.id @{ protocolVersion = '2026-10'; capabilities = @{} } }
        'command/execute' {
            if ($msg.params.id -eq 'hello-ps1.say') { Send-Result $msg.id 'Hello from PowerShell' }
            else { Send-Error $msg.id -32601 'unknown command' }
        }
        'shutdown' { Send-Result $msg.id $null }
        'exit' { exit 0 }
        default { if ($hasId) { Send-Error $msg.id -32601 'method not found' } }
    }
}
