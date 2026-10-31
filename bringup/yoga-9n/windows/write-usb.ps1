<#
.SYNOPSIS
  Write the Yoga 9n installer disk image to one exact USB stick and verify it.

.DESCRIPTION
  Refuses unless the disk number, serial number and size all match, the disk
  is on USB and is neither the boot nor the system disk, and the image matches
  its SHA-256. It then removes every partition on that stick, writes the image
  raw, and reads the written bytes back to compare their SHA-256. Everything
  else on the stick is lost.

  Run from an elevated PowerShell:
    powershell -ExecutionPolicy Bypass -File .\write-usb.ps1 -DiskNumber 2 `
      -SerialNumber AA00000000000489 -DiskBytes 60472426496 `
      -Image <path>\yoga9n-installer.img -ImageSha256 <sha256 from the .json>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$DiskNumber,
    [Parameter(Mandatory)][string]$SerialNumber,
    [Parameter(Mandatory)][long]$DiskBytes,
    [Parameter(Mandatory)][string]$Image,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ImageSha256,
    [string]$Log,
    # Only read the stick back and compare it with the image; write nothing.
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
if ($Log) { Start-Transcript -LiteralPath $Log -Force | Out-Null }
function Stop-Write([string]$message) {
    Write-Host "STOP: $message" -ForegroundColor Red
    if ($Log) { Stop-Transcript | Out-Null }
    exit 1
}

# Keep the machine awake (not the display) while this process runs; the request
# ends with the process, so no power setting is changed.
Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
'@
$ES_CONTINUOUS = [uint32]2147483648; $ES_SYSTEM_REQUIRED = [uint32]1
if (-not [Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)) {
    Stop-Write 'could not ask Windows to stay awake'
}
Write-Host 'Sleep is blocked until this script ends.'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Stop-Write 'run this from an elevated PowerShell' }

$disk = Get-Disk -Number $DiskNumber
if ($disk.SerialNumber.Trim() -ne $SerialNumber) { Stop-Write "disk $DiskNumber has serial $($disk.SerialNumber), not $SerialNumber" }
if ($disk.Size -ne $DiskBytes) { Stop-Write "disk $DiskNumber is $($disk.Size) bytes, not $DiskBytes" }
if ($disk.BusType -ne 'USB') { Stop-Write "disk $DiskNumber is on $($disk.BusType), not USB" }
if ($disk.IsBoot -or $disk.IsSystem) { Stop-Write "disk $DiskNumber is a boot or system disk" }

$imageFile = Get-Item -LiteralPath $Image
if ($imageFile.Length -gt $disk.Size) { Stop-Write 'the image is larger than the stick' }
if ($imageFile.Length % 1048576) { Stop-Write 'the image is not a whole number of MiB' }
Write-Host "Checking $($imageFile.FullName) ($([math]::Round($imageFile.Length / 1GB, 2)) GB)"
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $imageFile.FullName).Hash.ToLower()
if ($actual -ne $ImageSha256) { Stop-Write "image SHA-256 is $actual" }

$chunk = 4MB
$buffer = New-Object byte[] $chunk
$device = "\\.\PhysicalDrive$DiskNumber"
if ($VerifyOnly) {
    Write-Host "Target: disk $DiskNumber $($disk.FriendlyName), serial $SerialNumber, $DiskBytes bytes. Verifying only."
} else {
Write-Host "Target: disk $DiskNumber $($disk.FriendlyName), serial $SerialNumber, $DiskBytes bytes. Removing its partitions."
if ($disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false }
Set-Disk -Number $DiskNumber -IsReadOnly $false

$source = [IO.File]::OpenRead($imageFile.FullName)
$target = New-Object IO.FileStream($device, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite, $chunk, [IO.FileOptions]::WriteThrough)
try {
    $written = 0L
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (($read = $source.Read($buffer, 0, $chunk)) -gt 0) {
        $target.Write($buffer, 0, $read)
        $written += $read
        if ($watch.Elapsed.TotalSeconds -ge 5) {
            Write-Host ("  written {0:N1} of {1:N1} GB" -f ($written / 1GB), ($imageFile.Length / 1GB))
            $watch.Restart()
        }
    }
    $target.Flush($true)
} finally {
    $source.Dispose()
    $target.Dispose()
}
}

Write-Host 'Reading the stick back'
$sha = [Security.Cryptography.SHA256]::Create()
$reader = New-Object IO.FileStream($device, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, $chunk)
try {
    $remaining = $imageFile.Length
    while ($remaining -gt 0) {
        $want = [int][math]::Min([long]$chunk, [long]$remaining)
        $got = $reader.Read($buffer, 0, $want)
        if ($got -le 0) { Stop-Write 'short read from the stick' }
        [void]$sha.TransformBlock($buffer, 0, $got, $null, 0)
        $remaining -= $got
    }
    [void]$sha.TransformFinalBlock($buffer, 0, 0)
} finally {
    $reader.Dispose()
}
$readback = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
Update-Disk -Number $DiskNumber
if ($readback -ne $ImageSha256) { Stop-Write "read-back SHA-256 is $readback" }
Write-Host "Done: the stick holds the image (SHA-256 $readback). Eject it before removing." -ForegroundColor Green
[void][Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS)
if ($Log) { Stop-Transcript | Out-Null }
