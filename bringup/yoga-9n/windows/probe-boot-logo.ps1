<#
.SYNOPSIS
  Read-only check for Lenovo custom boot logo support on the Yoga 9n.

.DESCRIPTION
  Lenovo consumer firmware that supports a custom POST logo exposes the
  LBLDESP UEFI variable (logo capability: enable flag, maximum width/height,
  accepted formats) and reads the image from ESP:\EFI\Lenovo\Logo\. This
  script only reads: it dumps LBLDESP and LBLDVC as hex, and lists that ESP
  folder. It writes no variables and no files outside -OutputPath.

  Run elevated (UEFI variable reads need SeSystemEnvironmentPrivilege):
    powershell -ExecutionPolicy Bypass -File .\probe-boot-logo.ps1
#>
[CmdletBinding()]
param([string]$OutputPath = (Join-Path (Get-Location) 'boot-logo-probe.txt'))

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Uefi {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetFirmwareEnvironmentVariableExW(string name, string guid, byte[] buffer, uint size, out uint attributes);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValueW(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("ntdll.dll")]
    static extern int NtEnumerateSystemEnvironmentValuesEx(uint infoClass, byte[] buffer, ref uint length);
    // Returns "GUID NAME" for every UEFI variable (class 1 = names only).
    public static string[] ListVariables() {
        uint length = 0;
        NtEnumerateSystemEnvironmentValuesEx(1, null, ref length);
        if (length == 0) return new string[0];
        var buffer = new byte[length];
        int status = NtEnumerateSystemEnvironmentValuesEx(1, buffer, ref length);
        if (status != 0) return new string[] { string.Format("enumeration failed: NTSTATUS 0x{0:x8}", status) };
        var names = new System.Collections.Generic.List<string>();
        int offset = 0;
        while (offset < length) {
            int next = BitConverter.ToInt32(buffer, offset);
            var raw = new byte[16];
            Array.Copy(buffer, offset + 4, raw, 0, 16);
            var guid = new Guid(raw);
            int end = offset + 20;
            while (end + 1 < buffer.Length && (buffer[end] != 0 || buffer[end + 1] != 0)) end += 2;
            names.Add(guid.ToString().ToUpper() + " " + System.Text.Encoding.Unicode.GetString(buffer, offset + 20, end - offset - 20));
            if (next == 0) break;
            offset += next;
        }
        return names.ToArray();
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TokenPrivileges { public uint Count; public long Luid; public uint Attributes; }
    public static bool EnablePrivilege(string name) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return false;
        var state = new TokenPrivileges { Count = 1, Attributes = 2 };
        if (!LookupPrivilegeValueW(null, name, out state.Luid)) return false;
        return AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero) && Marshal.GetLastWin32Error() == 0;
    }
}
'@

$lines = New-Object System.Collections.Generic.List[string]
function Out-Line([string]$text) { Write-Host $text; $lines.Add($text) }

Out-Line "BIOS: $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)  $(Get-Date -Format s)"
if (-not [Uefi]::EnablePrivilege('SeSystemEnvironmentPrivilege')) {
    Out-Line 'Could not enable SeSystemEnvironmentPrivilege: run from an elevated prompt.'
}

# Names and GUIDs as used by github.com/chnzzh/lenovo-logo-changer (src/lenlogo.rs).
# LBLDESP is 10 bytes: enable flag, max width (u32 LE), max height (u32 LE), format bitmask.
$variables = [ordered]@{
    LBLDESP = '{871455D0-5576-4FB8-9865-AF0824463B9E}'
    LBLDVC  = '{871455D1-5576-4FB8-9865-AF0824463C9F}'
}
foreach ($name in $variables.Keys) {
    $guid = $variables[$name]
    $buffer = New-Object byte[] 4096
    $attributes = [uint32]0
    $size = [Uefi]::GetFirmwareEnvironmentVariableExW($name, $guid, $buffer, $buffer.Length, [ref]$attributes)
    if ($size) {
        $hex = ($buffer[0..($size - 1)] | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
        Out-Line ("{0}: {1} bytes, attributes 0x{2:x}: {3}" -f $name, $size, $attributes, $hex)
    } else {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Out-Line ("{0}: not readable (Win32 error {1}{2})" -f $name, $err, $(if ($err -eq 203) { ': variable absent' } else { '' }))
    }
}

# Every variable name, so a logo setting under another name or GUID is visible.
$all = [Uefi]::ListVariables()
Out-Line "UEFI variables: $($all.Count)"
$all | Sort-Object | ForEach-Object {
    $mark = if ($_ -match 'logo|lbld|splash|boot.?img|bgrt|oem.?img|quiet') { '  <==' } else { '' }
    Out-Line "  $_$mark"
}

# List ESP:\EFI\Lenovo without assigning a drive letter.
$esp = Get-Partition | Where-Object GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' | Select-Object -First 1
if ($esp) {
    $root = $esp.AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1
    Out-Line "ESP: disk $($esp.DiskNumber) partition $($esp.PartitionNumber), $root"
    $lenovo = Join-Path $root 'EFI\Lenovo'
    if (Test-Path -LiteralPath $lenovo) {
        Get-ChildItem -LiteralPath $lenovo -Recurse -Force | ForEach-Object { Out-Line ("  {0}  {1}" -f $_.FullName.Substring($root.Length), $_.Length) }
    } else {
        Out-Line '  no EFI\Lenovo folder'
    }
} else {
    Out-Line 'ESP: not found'
}

$lines | Set-Content -Encoding UTF8 -Path $OutputPath
Out-Line "Wrote $OutputPath"
