<#
.SYNOPSIS
  Read-only hardware capture for porting archlinuxarm-proart-p16 to the
  Lenovo Yoga 9n 2-in-1 16N1X11 (MT 83N7, model 83N7000UUS).

.DESCRIPTION
  Collects DMI identity, PnP devices with hardware IDs and ACPI paths, driver
  packages, the ACPI tables Windows exposes, panel EDIDs, Lenovo WMI classes,
  sleep states and audio driver firmware. Nothing on the machine is changed.

  Output goes to .\yoga9n-capture-<timestamp>\ and a zip next to it. The
  private\ subfolder holds firmware tables and OEM driver firmware: keep it off
  any public repository or issue tracker.

  Windows can return only the first SSDT through GetSystemFirmwareTable, so
  the UEFI Shell dump in HANDOFF.md stays the authoritative ACPI source.

.NOTES
  Run from an elevated Windows PowerShell 5.1 or PowerShell 7 prompt:
    Set-ExecutionPolicy -Scope Process Bypass
    .\capture.ps1
  Written without a Windows machine to test on; fix and rerun if a section fails.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $OutputRoot "yoga9n-capture-$stamp"
$private = Join-Path $out 'private'
New-Item -ItemType Directory -Force -Path $out, $private, (Join-Path $private 'acpi'), (Join-Path $private 'audio-firmware') | Out-Null
$log = Join-Path $out 'capture.log'

function Log([string]$message) {
    $line = "$(Get-Date -Format s) $message"
    Write-Host $line
    Add-Content -Path $log -Value $line
}

# Each section runs on its own so one failure does not stop the capture.
function Section([string]$name, [scriptblock]$body) {
    Log "BEGIN $name"
    try { & $body; Log "OK    $name" }
    catch { Log "FAIL  $name : $($_.Exception.Message)" }
}

function Save-Json($object, [string]$name) {
    $object | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path (Join-Path $out $name)
}

function Save-Text([string]$name, [scriptblock]$body) {
    & $body 2>&1 | Out-String -Width 4096 | Set-Content -Encoding UTF8 -Path (Join-Path $out $name)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Log "Elevated: $isAdmin"
if (-not $isAdmin) { Log 'WARNING: not elevated; Secure Boot, BitLocker and some driver data will be missing' }

Section 'system identity' {
    # Linux DMI mapping: sys_vendor=Manufacturer, product_name=Model,
    # product_version=Version, board_vendor/board_name=BaseBoard,
    # bios_version=SMBIOSBIOSVersion, bios_date=ReleaseDate.
    $cs = Get-CimInstance Win32_ComputerSystem
    $csp = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $board = Get-CimInstance Win32_BaseBoard
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $secureBoot = $null
    if ($isAdmin) { try { $secureBoot = Confirm-SecureBootUEFI } catch { $secureBoot = "error: $($_.Exception.Message)" } }
    Save-Json ([ordered]@{
        captured = (Get-Date).ToString('o')
        dmi_equivalent = [ordered]@{
            sys_vendor = $cs.Manufacturer
            product_name = $cs.Model
            product_version = $csp.Version
            product_sku = $cs.SystemSKUNumber
            product_family = $cs.SystemFamily
            board_vendor = $board.Manufacturer
            board_name = $board.Product
            board_version = $board.Version
            bios_vendor = $bios.Manufacturer
            bios_version = $bios.SMBIOSBIOSVersion
            bios_release = "$($bios.SystemBiosMajorVersion).$($bios.SystemBiosMinorVersion)"
            bios_date = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('MM/dd/yyyy') } else { $null }
            ec_firmware = "$($bios.EmbeddedControllerMajorVersion).$($bios.EmbeddedControllerMinorVersion)"
        }
        os = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; arch = $os.OSArchitecture }
        cpu = @($cpu | ForEach-Object { [ordered]@{ name = $_.Name; cores = $_.NumberOfCores; threads = $_.NumberOfLogicalProcessors } })
        memory_bytes = $cs.TotalPhysicalMemory
        secure_boot = $secureBoot
    }) 'system.json'
    if ($isAdmin) { Save-Text 'bitlocker.txt' { manage-bde -status } }
}

Section 'pnp devices' {
    $keys = @(
        'DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_CompatibleIds', 'DEVPKEY_Device_BiosDeviceName',
        'DEVPKEY_Device_LocationPaths', 'DEVPKEY_Device_Parent', 'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_DriverProvider', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_Service'
    )
    $rows = foreach ($device in Get-PnpDevice -PresentOnly) {
        $props = @{}
        foreach ($p in (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName $keys -ErrorAction SilentlyContinue)) {
            $props[$p.KeyName -replace '^DEVPKEY_Device_', ''] = $p.Data
        }
        [ordered]@{
            name = $device.FriendlyName
            class = $device.Class
            status = "$($device.Status)"
            instance_id = $device.InstanceId
            hardware_ids = $props['HardwareIds']
            compatible_ids = $props['CompatibleIds']
            acpi_path = $props['BiosDeviceName']
            location_paths = $props['LocationPaths']
            parent = $props['Parent']
            service = $props['Service']
            inf = $props['DriverInfPath']
            provider = $props['DriverProvider']
            driver_version = $props['DriverVersion']
        }
    }
    Save-Json @($rows) 'pnp-devices.json'
    $rows | ForEach-Object { [pscustomobject]@{
        Class = $_.class; Name = $_.name; Status = $_.status; AcpiPath = $_.acpi_path
        HardwareId = @($_.hardware_ids)[0]; Service = $_.service; Inf = $_.inf } } |
        Sort-Object Class, Name | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $out 'pnp-devices.csv')
    Save-Text 'pnputil-devices.txt' { pnputil /enum-devices /connected /ids /relations /drivers }
    Save-Text 'pnputil-drivers.txt' { pnputil /enum-drivers }
}

Section 'acpi tables' {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Fw {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint EnumSystemFirmwareTables(uint provider, byte[] buffer, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetSystemFirmwareTable(uint provider, uint id, byte[] buffer, uint size);
}
'@
    $acpi = [BitConverter]::ToUInt32([Text.Encoding]::ASCII.GetBytes('IPCA'), 0)  # 'ACPI' provider, byte-swapped
    $size = [Fw]::EnumSystemFirmwareTables($acpi, $null, 0)
    $buffer = New-Object byte[] $size
    [void][Fw]::EnumSystemFirmwareTables($acpi, $buffer, $size)
    $ids = @(for ($i = 0; $i -lt $size; $i += 4) { [BitConverter]::ToUInt32($buffer, $i) })
    # EnumSystemFirmwareTables omits the DSDT and XSDT; they are served when asked for by name.
    $listed = @{}
    foreach ($id in $ids) { $listed[$id] = 1 + [int]$listed[$id] }
    foreach ($extra in 'DSDT', 'XSDT') {
        $id = [BitConverter]::ToUInt32([Text.Encoding]::ASCII.GetBytes($extra), 0)
        if (-not $listed.ContainsKey($id)) { $listed[$id] = 0 }
    }
    function Describe-Table([byte[]]$data, [string]$file, [hashtable]$extra) {
        $row = [ordered]@{
            signature = [Text.Encoding]::ASCII.GetString($data, 0, 4)
            bytes = $data.Length
            header_length = [BitConverter]::ToUInt32($data, 4)
            oem_id = [Text.Encoding]::ASCII.GetString($data, 10, 6)
            oem_table_id = [Text.Encoding]::ASCII.GetString($data, 16, 8)
            oem_revision = [BitConverter]::ToUInt32($data, 24)
            file = $file.Substring($private.Length + 1)
            sha256 = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
        }
        foreach ($k in $extra.Keys) { $row[$k] = $extra[$k] }
        $row
    }
    $listing = foreach ($id in $listed.Keys) {
        $signature = [Text.Encoding]::ASCII.GetString([BitConverter]::GetBytes([uint32]$id))
        $length = [Fw]::GetSystemFirmwareTable($acpi, $id, $null, 0)
        if (-not $length) { continue }
        $data = New-Object byte[] $length
        [void][Fw]::GetSystemFirmwareTable($acpi, $id, $data, $length)
        $file = Join-Path $private "acpi\$signature.bin"
        [IO.File]::WriteAllBytes($file, $data)
        Describe-Table $data $file @{ source = 'GetSystemFirmwareTable'; listed = $listed[$id] }
    }
    # The ACPI driver keeps every loaded DSDT and SSDT under HKLM\HARDWARE\ACPI
    # (SSDT, SSD1, SSD2, ...), so the SSDTs the firmware API hides are here.
    New-Item -ItemType Directory -Force -Path (Join-Path $private 'acpi-registry') | Out-Null
    $registry = foreach ($key in Get-ChildItem -Recurse 'HKLM:\HARDWARE\ACPI' -ErrorAction Stop) {
        foreach ($name in $key.GetValueNames()) {
            $data = $key.GetValue($name)
            if ($data -isnot [byte[]] -or $data.Length -lt 36) { continue }
            $parts = $key.Name -split '\\'
            $file = Join-Path $private ("acpi-registry\" + (($parts[3..($parts.Length - 1)] -join '-') -replace '[^\w\.-]', '_') + '.bin')
            [IO.File]::WriteAllBytes($file, $data)
            Describe-Table $data $file @{ source = 'registry'; key = $key.Name; value = $name }
        }
    }
    Save-Json @(@($listing) + @($registry)) 'acpi-tables.json'

    # Facts the port needs from the DSDT before any disassembly.
    $facts = [ordered]@{}
    $tables = @(Get-Item (Join-Path $private 'acpi\DSDT.bin') -ErrorAction SilentlyContinue) +
              @(Get-ChildItem (Join-Path $private 'acpi-registry') -Filter 'SS*.bin' -ErrorAction SilentlyContinue)
    foreach ($table in $tables) {
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($table.FullName))
        $facts[$table.Name] = [ordered]@{
            nvda8400_present = $text.Contains('NVDA8400')
            sspm_name_present = $text.Contains('SSPM')
            osi_windows_2022_offsets = @([regex]::Matches($text, [regex]::Escape("_OSI$([char]0x0d)Windows 2022$([char]0)")) | ForEach-Object { '0x{0:x}' -f $_.Index })
            osi_strings = @([regex]::Matches($text, "_OSI$([char]0x0d)([ -~]{3,40})$([char]0)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            hids = @([regex]::Matches($text, '(?:NVDA|MTK|MSHW|LEN|LNV|IDEA|VPC|PNP|ACPI|CSC|RTK|TIAS|ELAN|WACF|WCOM|GXTP|SYNA|INT|MSFT|PRP|QCOM|PIXA|CIRR|AWDZ)[0-9A-F]{4}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        }
    }
    if ($facts.Count) { Save-Json $facts 'dsdt-facts.json' }
}

Section 'panel edid' {
    $edids = foreach ($key in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY' -ErrorAction Stop) {
        foreach ($instance in Get-ChildItem $key.PSPath) {
            $params = Join-Path $instance.PSPath 'Device Parameters'
            $edid = (Get-ItemProperty -Path $params -Name EDID -ErrorAction SilentlyContinue).EDID
            if ($edid) {
                $name = "edid-$($key.PSChildName)-$($instance.PSChildName).bin" -replace '[^\w\.-]', '_'
                [IO.File]::WriteAllBytes((Join-Path $out $name), $edid)
                [ordered]@{ monitor = $key.PSChildName; instance = $instance.PSChildName; file = $name; bytes = $edid.Length }
            }
        }
    }
    Save-Json @($edids) 'edid.json'
    Save-Text 'video-controllers.txt' { Get-CimInstance Win32_VideoController | Format-List Name, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate, PNPDeviceID }
}

Section 'lenovo wmi' {
    Save-Text 'wmi-classes.txt' {
        Get-CimClass -Namespace root\WMI | Where-Object { $_.CimClassName -match 'LENOVO|Lenovo|LNV|GameZone|Ideapad|Yoga' } |
            Sort-Object CimClassName | Format-Table -AutoSize CimClassName, CimClassMethods
    }
    Save-Text 'wmi-lenovo-instances.txt' {
        Get-CimClass -Namespace root\WMI | Where-Object { $_.CimClassName -match 'LENOVO|Lenovo' -and -not $_.CimClassMethods.Count } |
            ForEach-Object { "== $($_.CimClassName)"; Get-CimInstance -Namespace root\WMI -ClassName $_.CimClassName -ErrorAction SilentlyContinue | Format-List * }
    }
}

Section 'power' {
    Save-Text 'powercfg-sleepstates.txt' { powercfg /a }
    powercfg /batteryreport /output (Join-Path $out 'battery-report.html') | Out-Null
    Save-Text 'thermal-zones.txt' { Get-CimInstance -Namespace root\WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Format-List InstanceName, CurrentTemperature, CriticalTripPoint }
}

Section 'audio' {
    Save-Text 'audio-endpoints.txt' {
        Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in 'MEDIA', 'AudioEndpoint', 'AudioProcessingObject', 'SoftwareComponent', 'Extension' -or
            $_.InstanceId -match '^(SWD\\MMDEVAPI|SDW|SWD\\DRIVERENUM|ACPI\\(NVDA|MTK|CSC|RTK|TIAS))' } |
            Sort-Object Class, FriendlyName | Format-Table -AutoSize Class, Status, FriendlyName, InstanceId
    }
    # Speaker amplifier tuning is the one thing Linux cannot get elsewhere.
    # Copy firmware-like files from audio-looking driver packages; never publish them.
    $repository = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    # Cirrus ships amp firmware and per-SSID tuning as xucsmeext_<ssid>_fdl.inf (fw\ and tn\ trees).
    $pattern = 'xucsme|_fdl\.inf|cs35l|cs42l|cs40l|cirrus|rt\d{3,4}|realtek|tas\d{4}|tas25|aw8|awinic|sdw|soundwire|audio|sound|smartamp|mtk|mediatek|nvaudio'
    $packages = Get-ChildItem -Directory $repository | Where-Object { $_.Name -match $pattern }
    $inventory = foreach ($package in $packages) {
        foreach ($file in Get-ChildItem -File -Recurse $package.FullName) {
            $row = [ordered]@{
                package = $package.Name
                file = $file.FullName.Substring($package.FullName.Length + 1)
                bytes = $file.Length
                sha256 = (Get-FileHash -Algorithm SHA256 -Path $file.FullName).Hash.ToLower()
            }
            if ($file.Extension -match '^\.(wmfw|bin|fw|dat|cfg|tlv|ini|json|xml)$' -and $file.Length -lt 16MB) {
                $target = Join-Path $private "audio-firmware\$($package.Name)\$($row.file)"
                New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target
                $row.copied = $true
            }
            if ($file.Extension -eq '.inf') {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $private "audio-firmware\$($package.Name)-$($file.Name)") -ErrorAction SilentlyContinue
            }
            $row
        }
    }
    Save-Json @($inventory) 'audio-driver-files.json'
}

Section 'inputs and sensors' {
    Save-Text 'inputs.txt' {
        Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in 'HIDClass', 'Keyboard', 'Mouse', 'Sensor', 'Biometric', 'Camera', 'Image', 'Bluetooth', 'Net' } |
            Sort-Object Class, FriendlyName | Format-Table -AutoSize Class, Status, FriendlyName, InstanceId
    }
}

Section 'zip' {
    $zip = "$out.zip"
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force
    Log "Wrote $zip ($((Get-Item $zip).Length) bytes)"
}

Log "Done. Review capture.log for FAIL lines."
