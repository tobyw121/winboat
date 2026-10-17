# File checksums must also work in Windows PowerShell 5.1 when its legacy CSP
# cannot initialize. SHA256Managed implements the same SHA-256 algorithm without
# that provider dependency; expected hashes and mismatch rejection are unchanged.
function Get-WinBoatFileSha256([string]$LiteralPath) {
    $algorithm = New-Object Security.Cryptography.SHA256Managed
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($LiteralPath)
        return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) {$stream.Dispose()}
        $algorithm.Dispose()
    }
}
