<#
.SYNOPSIS
  Grows a Dataram / AMD Radeon RAMDisk (RAMDiskVE 4.x) "version 2" image file and the NTFS
  volume inside it, then updates the RAMDisk size in the registry. Fail-safe: the original image
  is never modified.

.DESCRIPTION
  Image layout (as read by RAMDiskVE.sys 4.4.0.36):
    [0 .. D)        raw disk, D = SizeIn4kPages * 4096 (MBR + one NTFS partition)
    [D .. D+0x30)   header: +00 magic GUID 8746ddf4-b44d-4af9-942c-752f92fb3da9
                            +10 u64 footer length (0x30 + bitmap bytes)
                            +18 u32 write sequence   +1C u32 flags (bit0 = dirty)
                            +20 instance GUID
    [D+0x30 .. end) UsedMap: 1 bit per 4 KiB page, ceil(pages/64)*8 bytes.
                    Pages with a 0 bit are NOT loaded (assumed zero).
  The driver rejects the file unless its length == D + footer length, with D taken from the
  registry, so the image and SizeIn4kPages must change together. A rejected image is left
  untouched by the driver; a MISSING image is re-created empty, so the image path must never
  be missing.

  How the resize stays safe:
    * The original stays locked (read-only share) for the whole run and is never written.
    * All work happens on <image>.resize-work.vhd, a hash-verified copy.
    * The copy is mounted with a random temporary disk signature, so Windows can never map it
      to the RAMDisk's drive letter. The live run and the tests take the same steps.
    * The file system is scanned before and after growing, and every file's SHA-256 must be
      unchanged.
    * The original is replaced only after all checks pass, in one ReplaceFile call that keeps it
      as <image>.pre-resize.bak. The registry is changed last, read back, and restored on failure.
    * Any failure undoes everything. -Rollback undoes a completed run.
    * Progress is journaled to <image>.resize-state.json, and the console is logged to .\logs\.

.PARAMETER ImagePath
  Image to resize. Defaults to the configured LoadImageFile.
.PARAMETER NewSizeGB
  New disk size in GiB (must be larger than the current size).
.PARAMETER VerifyOnly
  Read-only check of an image: footer, UsedMap coverage, partition/NTFS sizes.
.PARAMETER Rollback
  Undo a resize: put <image>.pre-resize.bak back and restore SizeIn4kPages. The RAMDisk must be stopped.
.PARAMETER PostCheck
  After starting the RAMDisk on the resized image: check the registry, the driver's event log, the
  drive size, and that the drive's contents match the manifest saved by the resize.
.PARAMETER Force
  Proceed even if a NON-configured image (e.g. a test or VSS copy) is marked dirty. The configured
  (live) image is always refused when dirty.
.PARAMETER ConfigKey
  Registry key holding the RAMDisk parameters. Defaults to the real driver key. Tests point it at a
  scratch key under HKCU, which exercises the full live path (registry included) on a copy.
.PARAMETER FailAt
  Testing only: throw an injected failure right after the named phase completes.

.EXAMPLE
  .\Resize-RamDiskImage.ps1 -VerifyOnly -ImagePath G:\RAMDisk.img
.EXAMPLE
  .\Resize-RamDiskImage.ps1 -NewSizeGB 8          # after stopping the RAMDisk
.EXAMPLE
  .\Resize-RamDiskImage.ps1 -PostCheck             # right after starting it again
.EXAMPLE
  .\Resize-RamDiskImage.ps1 -Rollback              # if anything is wrong (RAMDisk stopped)
#>
[CmdletBinding(DefaultParameterSetName = 'Resize')]
param(
    [string]$ImagePath,
    [Parameter(ParameterSetName = 'Resize')][int]$NewSizeGB,
    [Parameter(ParameterSetName = 'Verify', Mandatory)][switch]$VerifyOnly,
    [Parameter(ParameterSetName = 'Rollback', Mandatory)][switch]$Rollback,
    [Parameter(ParameterSetName = 'PostCheck', Mandatory)][switch]$PostCheck,
    [Parameter(ParameterSetName = 'Resize')][switch]$Force,
    [string]$ConfigKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\RAMDiskVE\Parameters',
    [Parameter(ParameterSetName = 'Resize')]
    [ValidateSet('Copy', 'Prepare', 'Mount', 'CheckBefore', 'Grow', 'CheckAfter', 'Dismount', 'Finalize', 'Verify', 'Swap', 'Registry')]
    [string]$FailAt
)

$ErrorActionPreference = 'Stop'
$Mode = $PSCmdlet.ParameterSetName
$ActiveKey = "$ConfigKey\Active"
$GuiProcesses = 'AMD_RAMDisk', 'RAMDisk', 'rdc', 'rdcq'
$DriverErrors = 'Incorrect image|cannot load|Unable to open file for disk image load|Demand load from disk failed|data may be lost|marked dirty|Failed to read UsedMap'

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
public static class RdResize {
    public static readonly byte[] Magic = new Guid("8746ddf4-b44d-4af9-942c-752f92fb3da9").ToByteArray();
    public const int HeaderLen = 0x30;

    public static long BitmapBytes(long pages) { return ((pages + 63) >> 6) << 3; }

    public static byte[] ReadAt(FileStream fs, long off, int len) {
        byte[] b = new byte[len]; fs.Seek(off, SeekOrigin.Begin);
        int got = 0;
        while (got < len) { int n = fs.Read(b, got, len - got); if (n <= 0) throw new IOException("short read"); got += n; }
        return b;
    }
    public static void WriteAt(FileStream fs, long off, byte[] b) {
        fs.Seek(off, SeekOrigin.Begin); fs.Write(b, 0, b.Length);
    }

    static string Hex(byte[] h) { return BitConverter.ToString(h).Replace("-", ""); }

    // Copies src (from offset 0) to a new file dst, flushes it to disk, returns SHA-256 of what was read.
    public static string CopyHash(FileStream src, string dst) {
        byte[] buf = new byte[16 << 20];
        using (SHA256 sha = SHA256.Create())
        using (FileStream o = new FileStream(dst, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 20)) {
            src.Seek(0, SeekOrigin.Begin);
            int n;
            while ((n = src.Read(buf, 0, buf.Length)) > 0) { sha.TransformBlock(buf, 0, n, null, 0); o.Write(buf, 0, n); }
            sha.TransformFinalBlock(buf, 0, 0);
            o.Flush(true);
            return Hex(sha.Hash);
        }
    }
    public static string HashFile(string path) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.SequentialScan))
        using (SHA256 sha = SHA256.Create()) return Hex(sha.ComputeHash(f));
    }

    // Walks every 4 KiB page of the raw disk. For each non-zero page whose bit is clear:
    // counts it, and sets the bit if setBits. Returns the number of such pages.
    public static long ScanPages(FileStream fs, long diskBytes, byte[] bitmap, bool setBits) {
        const int Chunk = 4 << 20;
        byte[] buf = new byte[Chunk]; ulong[] w = new ulong[Chunk / 8];
        long missing = 0;
        fs.Seek(0, SeekOrigin.Begin);
        for (long pos = 0; pos < diskBytes; pos += Chunk) {
            int len = (int)Math.Min(Chunk, diskBytes - pos), got = 0;
            while (got < len) { int n = fs.Read(buf, got, len - got); if (n <= 0) throw new IOException("short read"); got += n; }
            Buffer.BlockCopy(buf, 0, w, 0, len);
            for (int p = 0; p < len / 4096; p++) {
                bool nz = false;
                for (int i = p * 512, e = i + 512; i < e; i++) if (w[i] != 0) { nz = true; break; }
                if (!nz) continue;
                long page = (pos >> 12) + p;
                int idx = (int)(page >> 3), bit = 1 << (int)(page & 7);
                if ((bitmap[idx] & bit) == 0) { missing++; if (setBits) bitmap[idx] |= (byte)bit; }
            }
        }
        return missing;
    }

    // 512-byte fixed-VHD footer (all fields big-endian).
    public static byte[] VhdFooter(long size) {
        byte[] f = new byte[512];
        Action<int, ulong, int> be = (o, v, n) => { for (int i = 0; i < n; i++) f[o + i] = (byte)(v >> (8 * (n - 1 - i))); };
        System.Text.Encoding.ASCII.GetBytes("conectix").CopyTo(f, 0);
        be(8, 2, 4); be(12, 0x00010000, 4); be(16, ulong.MaxValue, 8);
        be(24, (ulong)(DateTime.UtcNow - new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds, 4);
        System.Text.Encoding.ASCII.GetBytes("rdrs").CopyTo(f, 28); be(32, 0x00010000, 4);
        System.Text.Encoding.ASCII.GetBytes("Wi2k").CopyTo(f, 36);
        be(40, (ulong)size, 8); be(48, (ulong)size, 8);
        long ts = Math.Min(size / 512, 65535L * 16 * 255); long spt, heads, cth;
        if (ts >= 65535L * 16 * 63) { spt = 255; heads = 16; cth = ts / spt; }
        else {
            spt = 17; cth = ts / spt; heads = Math.Max(4, (cth + 1023) / 1024);
            if (cth >= heads * 1024 || heads > 16) { spt = 31; heads = 16; cth = ts / spt; }
            if (cth >= heads * 1024) { spt = 63; heads = 16; cth = ts / spt; }
        }
        be(56, (ulong)(cth / heads), 2); f[58] = (byte)heads; f[59] = (byte)spt;
        be(60, 2, 4);
        Guid.NewGuid().ToByteArray().CopyTo(f, 68);
        uint sum = 0; foreach (byte b in f) sum += b;
        be(64, ~sum, 4);
        return f;
    }

    // Content manifest of a volume: one sorted line per entry, "type<TAB>size<TAB>sha256<TAB>relative path".
    // type D = directory, F = file, R = reparse point (not followed), E = unreadable directory.
    // Top-level names in skipTop (e.g. "System Volume Information") are left out.
    public static List<string> Manifest(string root, string[] skipTop) {
        List<string> outp = new List<string>();
        using (SHA256 sha = SHA256.Create()) Walk(root, root, skipTop, outp, sha);
        outp.Sort(StringComparer.Ordinal);
        return outp;
    }
    static void Walk(string root, string dir, string[] skipTop, List<string> outp, SHA256 sha) {
        List<string> entries;
        try { entries = new List<string>(Directory.EnumerateFileSystemEntries(dir)); }
        catch (Exception e) { outp.Add("E\t\t" + e.GetType().Name + "\t" + dir.Substring(root.Length)); return; }
        foreach (string p in entries) {
            string rel = p.Substring(root.Length);
            if (dir == root) {
                bool skip = false;
                foreach (string s in skipTop) if (string.Equals(s, rel, StringComparison.OrdinalIgnoreCase)) skip = true;
                if (skip) continue;
            }
            FileAttributes a = File.GetAttributes(p);
            if ((a & FileAttributes.ReparsePoint) != 0) { outp.Add("R\t\t\t" + rel); continue; }
            if ((a & FileAttributes.Directory) != 0) { outp.Add("D\t\t\t" + rel); Walk(root, p, skipTop, outp, sha); continue; }
            long len = new FileInfo(p).Length; string h;
            try {
                using (FileStream fs = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20, FileOptions.SequentialScan))
                    h = Hex(sha.ComputeHash(fs));
            } catch (Exception e) { h = "UNREADABLE:" + e.GetType().Name; }
            outp.Add("F\t" + len + "\t" + h + "\t" + rel);
        }
    }
}
'@

# ---------------------------------------------------------------- helpers
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" }
function Ok($m)   { Write-Host "    OK   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    WARN $m" -ForegroundColor Yellow }
function Check($cond, $msg) { if (-not $cond) { throw "CHECK FAILED: $msg" }; Ok $msg }
function GiB($b) { '{0:N2} GiB' -f ($b / 1GB) }
function Strip-NtPath($p) { if ($p) { $p -replace '^\\\?\?\\', '' } }
function Full-Path($p) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
function Fail-Point($phase) { if ($FailAt -eq $phase) { throw "INJECTED FAILURE after phase '$phase' (-FailAt)" } }
function Is-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Reads and validates an image from an open stream; returns its layout.
function Read-Image([IO.FileStream]$fs) {
    $len = $fs.Length
    if ($len % 4096 -eq 0) { throw "File length is a multiple of 4096: a version-1 (raw) image, or not a RAMDisk image. Not supported." }
    # Footer length = 0x30 + ceil(pages/64)*8 and disk = pages*4096; solve for pages.
    $pages = [long][Math]::Floor(($len - [RdResize]::HeaderLen) / 4096.125)
    $found = $null
    foreach ($p in ($pages - 2)..($pages + 2)) {
        if ($p -gt 0 -and ($p * 4096 + [RdResize]::HeaderLen + [RdResize]::BitmapBytes($p)) -eq $len) { $found = $p }
    }
    if (-not $found) { throw "File length $len does not match any RAMDisk v2 layout." }
    $disk = $found * 4096
    $hdr = [RdResize]::ReadAt($fs, $disk, [RdResize]::HeaderLen)
    if ([BitConverter]::ToString($hdr, 0, 16) -ne [BitConverter]::ToString([RdResize]::Magic)) { throw "Footer magic GUID not found at offset $disk." }
    $footLen = [BitConverter]::ToUInt64($hdr, 0x10)
    if ($disk + $footLen -ne $len) { throw "Footer length field ($footLen) is inconsistent with file length." }
    $flags = [BitConverter]::ToUInt32($hdr, 0x1C)
    $mbr = [RdResize]::ReadAt($fs, 0, 512)
    if ($mbr[510] -ne 0x55 -or $mbr[511] -ne 0xAA) { throw "No MBR boot signature at sector 0." }
    $pstart = [long][BitConverter]::ToUInt32($mbr, 0x1C6)
    $others = 0; foreach ($i in 1..3) { if ($mbr[0x1C2 + 16 * $i] -ne 0) { $others++ } }
    $boot = [RdResize]::ReadAt($fs, $pstart * 512, 512)
    [pscustomobject]@{
        Length = $len; Pages = $found; DiskBytes = $disk; Header = $hdr
        Bitmap = [RdResize]::ReadAt($fs, $disk + [RdResize]::HeaderLen, [int]([RdResize]::BitmapBytes($found)))
        Sequence = [BitConverter]::ToUInt32($hdr, 0x18); Dirty = [bool]($flags -band 1)
        Instance = [Guid]::new([byte[]]$hdr[0x20..0x2F])
        Mbr = $mbr; Signature = [BitConverter]::ToUInt32($mbr, 0x1B8)
        PartType = $mbr[0x1C2]; PartStart = $pstart; PartSectors = [long][BitConverter]::ToUInt32($mbr, 0x1CA); OtherParts = $others
        IsNtfs = [Text.Encoding]::ASCII.GetString($boot, 3, 4) -eq 'NTFS'; NtfsSectors = [BitConverter]::ToUInt64($boot, 0x28)
    }
}

function Show-Image($img) {
    Info ("Disk size      : {0} ({1} pages), file length {2}" -f (GiB $img.DiskBytes), $img.Pages, $img.Length)
    Info ("Footer         : seq={0} dirty={1} instance={2}" -f $img.Sequence, $img.Dirty, $img.Instance)
    Info ("MBR signature  : 0x{0:X8}" -f $img.Signature)
    Info ("Partition 1    : type 0x{0:X2}, start LBA {1}, {2} ({3} sectors), other partitions: {4}" -f $img.PartType, $img.PartStart, (GiB ($img.PartSectors * 512)), $img.PartSectors, $img.OtherParts)
    Info ("NTFS           : {0}, volume {1} ({2} sectors)" -f $img.IsNtfs, (GiB ($img.NtfsSectors * 512)), $img.NtfsSectors)
}

function Assert-Layout($img) {
    Check ($img.PartType -ne 0xEE) "MBR-partitioned (not GPT)"
    Check ($img.OtherParts -eq 0 -and $img.IsNtfs) "exactly one partition, NTFS"
    Check (($img.PartStart + $img.PartSectors) * 512 -le $img.DiskBytes) "partition fits inside the disk"
}

function Get-RegPages {
    $p = Get-Item -LiteralPath $ConfigKey
    $a = Get-Item -LiteralPath $ActiveKey -ErrorAction SilentlyContinue
    $r = [ordered]@{ Param = $p.GetValue('SizeIn4kPages'); ParamKind = $null; Active = $null; ActiveKind = $null }
    if ($null -ne $r.Param) { $r.ParamKind = "$($p.GetValueKind('SizeIn4kPages'))" }
    if ($a -and $null -ne $a.GetValue('SizeIn4KPages')) { $r.Active = $a.GetValue('SizeIn4KPages'); $r.ActiveKind = "$($a.GetValueKind('SizeIn4KPages'))" }
    [pscustomobject]$r
}

function Set-RegPages([long]$pages) {
    Set-ItemProperty -LiteralPath $ConfigKey -Name SizeIn4kPages -Value ([int]$pages) -Type DWord
    Set-ItemProperty -LiteralPath $ActiveKey -Name SizeIn4KPages -Value ([int]$pages) -Type DWord
    $rp = Get-RegPages
    Check ($rp.Param -eq $pages -and $rp.Active -eq $pages -and $rp.ParamKind -eq 'DWord' -and $rp.ActiveKind -eq 'DWord') "registry SizeIn4kPages = $pages in Parameters and Active (read back)"
}

# The RAMDisk must be stopped and its GUI closed. Only meaningful for the configured image.
function Assert-Quiet {
    if (-not $isConfigured) { return }
    $drv = $cfg.DiskDrive
    if ($drv -and (Test-Path -LiteralPath $drv)) { throw "$drv exists: the RAMDisk is running. Stop it first." }
    $gui = @(Get-Process -Name $GuiProcesses -ErrorAction SilentlyContinue)
    if ($gui.Count) { throw "RAMDisk GUI/console is running ($(($gui.Name | Sort-Object -Unique) -join ', ')). Close it first." }
    Ok "RAMDisk stopped ($drv absent) and its GUI/console closed"
}

function Save-State($phase) {
    $state.phase = $phase; $state.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

# Puts the original image back at $ImagePath if a swap happened. Never deletes anything:
# a resized image that was in place is kept as $rejected.
function Restore-Original([long]$origLen) {
    $img = Get-Item -LiteralPath $ImagePath -ErrorAction SilentlyContinue
    if ($img -and $img.Length -eq $origLen) { Ok "original image is in place at $ImagePath"; return }
    if (-not (Test-Path -LiteralPath $bak)) { throw "Original not at $ImagePath and $bak not found: cannot restore automatically." }
    if (-not $img) {
        Move-Item -LiteralPath $bak -Destination $ImagePath
    } else {
        if (Test-Path -LiteralPath $rejected) { throw "$rejected already exists; move it away, then run -Rollback again." }
        [IO.File]::Replace($bak, $ImagePath, $rejected, $true)
        Info "resized image kept as $rejected"
    }
    Check ((Get-Item -LiteralPath $ImagePath).Length -eq $origLen) "original image restored to $ImagePath"
}

function Scan-Volume($vol, $when) {
    $r = $null
    try { $r = $vol | Repair-Volume -Scan -ErrorAction Stop } catch { Warn "Repair-Volume failed ($($_.Exception.Message)); falling back to chkdsk" }
    if ($null -ne $r) { Check ("$r" -eq 'NoErrorsFound') "file system scan ($when): $r"; return }
    & chkdsk.exe $vol.Path.TrimEnd('\') | ForEach-Object { Info $_ }
    Check ($LASTEXITCODE -eq 0) "chkdsk ($when) exit code $LASTEXITCODE"
}

function Get-Manifest($root, $what) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $m = [RdResize]::Manifest($root, [string[]]@('System Volume Information'))
    $files = @($m | Where-Object { $_[0] -eq 'F' }); $bytes = 0L; foreach ($l in $files) { $bytes += [long]($l.Split("`t")[1]) }
    $unread = @($files | Where-Object { $_ -match "`tUNREADABLE:" }); $odd = @($m | Where-Object { $_[0] -eq 'E' -or $_[0] -eq 'R' })
    Info ("manifest {0}: {1} files ({2}), {3} dirs, {4} reparse/unlistable, {5} unreadable, {6:N0}s" -f $what, $files.Count, (GiB $bytes), @($m | Where-Object { $_[0] -eq 'D' }).Count, $odd.Count, $unread.Count, $sw.Elapsed.TotalSeconds)
    foreach ($l in ($unread + $odd | Select-Object -First 10)) { Warn "not hashed: $l" }
    , $m
}

function Compare-Manifest($a, $b, $what) {
    $same = $a.Count -eq $b.Count
    if ($same) { for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -cne $b[$i]) { $same = $false; break } } }
    if (-not $same) {
        $d = @(Compare-Object -CaseSensitive ([string[]]$a) ([string[]]$b))
        Warn "$($d.Count) differing manifest lines (<= only in first, => only in second); first 30:"
        $d | Select-Object -First 30 | ForEach-Object { Info ("{0} {1}" -f $_.SideIndicator, $_.InputObject) }
    }
    Check $same "$what ($($a.Count) entries identical: names, sizes, SHA-256)"
}

# ---------------------------------------------------------------- resize
function Invoke-Resize {
    $lock = $null; $fs = $null; $mounted = $false; $swapped = $false; $regChanged = $false; $origLen = 0
    $ownsFiles = $false     # true once this run may have created work/manifest/state files (cleanup only touches those)
    try {
        Step "Preflight"
        Check (Is-Admin) "running elevated"
        if (-not $NewSizeGB) { throw "Specify -NewSizeGB." }
        Check (Test-Path -LiteralPath $ImagePath -PathType Leaf) "image exists: $ImagePath"
        foreach ($p in $work, $bak, $stateFile, $rejected, $manifestFile) {
            if (Test-Path -LiteralPath $p) { throw "Leftover from a previous run: $p. If a run was interrupted, use -Rollback; otherwise inspect and remove it." }
        }
        Ok "no leftovers from a previous run"
        if ($isConfigured) {
            Info "target is the CONFIGURED RAMDisk image (registry: $ConfigKey)"
            Check ($cfgSave -and (Full-Path $cfgSave) -eq $ImagePath) "SaveImageFile is the same file as LoadImageFile"
            Check ([bool]$cfg.DiskDrive) "DiskDrive configured ($($cfg.DiskDrive))"
            Assert-Quiet
        } else {
            Info "target is NOT the configured image: registry will not be changed"
        }
        $orig = Get-Item -LiteralPath $ImagePath -Force
        $origLen = $orig.Length; $origLwt = $orig.LastWriteTimeUtc
        $newPages = [long]$NewSizeGB * 262144; $newDisk = $newPages * 4096
        $newLen = $newDisk + [RdResize]::HeaderLen + [RdResize]::BitmapBytes($newPages)
        $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        Check ($newDisk -le $ram - 8GB) "new size $(GiB $newDisk) leaves at least 8 GiB of RAM ($(GiB $ram) installed)"
        if ($newDisk -gt $ram / 2) { Warn "new size is more than half of installed RAM" }
        $free = (Get-PSDrive ([IO.Path]::GetPathRoot($ImagePath).Substring(0, 1))).Free
        Check ($free -gt $newLen + 1GB) "free space on $([IO.Path]::GetPathRoot($ImagePath)) $(GiB $free) (need $(GiB ($newLen + 1GB)))"

        Step "Locking the original (read-only share) and validating it"
        $lock = [IO.File]::Open($ImagePath, 'Open', 'Read', 'Read')
        $img = Read-Image $lock; Show-Image $img
        Assert-Layout $img
        if ($img.Dirty) {
            if ($isConfigured) { throw "The configured image is marked dirty (unclean save). Not resizing it. Start/stop the RAMDisk cleanly first." }
            if (-not $Force) { throw "Image is marked dirty. Use -Force (non-configured images only)." }
            Warn "image is dirty; continuing because of -Force"
        } else { Ok "image not dirty" }
        Check ($newDisk -gt $img.DiskBytes) "new size $(GiB $newDisk) is larger than current $(GiB $img.DiskBytes)"
        $missing = [RdResize]::ScanPages($lock, $img.DiskBytes, $img.Bitmap, $false)
        Check ($missing -eq 0) "UsedMap of the original covers every non-zero page"
        if ($isConfigured) {
            $rp = Get-RegPages
            Check ($rp.Param -eq $img.Pages -and $rp.Active -eq $img.Pages -and $rp.ParamKind -eq 'DWord' -and $rp.ActiveKind -eq 'DWord') "registry SizeIn4kPages (Parameters=$($rp.Param), Active=$($rp.Active)) matches the image ($($img.Pages)), both DWORD"
        }

        $script:state = [ordered]@{
            image = $ImagePath; work = $work; backup = $bak; configKey = $ConfigKey; configured = [bool]$isConfigured
            oldPages = $img.Pages; newPages = $newPages; originalLength = $origLen; newLength = $newLen
            originalSha256 = $null; startedUtc = (Get-Date).ToUniversalTime().ToString('o'); swappedUtc = $null; phase = $null; updatedUtc = $null
        }
        $ownsFiles = $true
        Save-State 'copying'

        Step "Copying to work file $work"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $h1 = [RdResize]::CopyHash($lock, $work)
        $h2 = [RdResize]::HashFile($work)
        Check ($h1 -eq $h2) ("work copy is byte-identical to the original (SHA-256 {0}, {1:N0}s)" -f $h1, $sw.Elapsed.TotalSeconds)
        $state.originalSha256 = $h1; Save-State 'copied'
        $wa = (Get-Item -LiteralPath $work).Attributes
        Check (-not ($wa -band ([IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted))) "work file is not sparse/compressed/encrypted (mountable): $wa"
        Fail-Point 'Copy'

        Step "Preparing work file: extend to $(GiB $newDisk), temporary disk signature, VHD footer"
        $used = @(Get-Disk | ForEach-Object { [uint32]$_.Signature }) + $img.Signature
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $tmpSig = New-Object byte[] 4
        do { $rng.GetBytes($tmpSig); $tmpSigU = [BitConverter]::ToUInt32($tmpSig, 0) } while ($tmpSigU -eq 0 -or $used -contains $tmpSigU)
        $fs = [IO.File]::Open($work, 'Open', 'ReadWrite', 'None')
        $fs.SetLength($img.DiskBytes)        # drop the RAMDisk footer (kept in memory)
        $fs.SetLength($newDisk)              # new space reads as zeros
        [RdResize]::WriteAt($fs, 0x1B8, $tmpSig)
        [RdResize]::WriteAt($fs, $newDisk, [RdResize]::VhdFooter($newDisk))
        $fs.Flush($true); $fs.Dispose(); $fs = $null
        Info ("temporary signature 0x{0:X8} (original 0x{1:X8})" -f $tmpSigU, $img.Signature)
        Save-State 'prepared'
        Fail-Point 'Prepare'

        Step "Mounting work file"
        $mounted = $true    # set first so cleanup always tries to dismount
        Mount-DiskImage -ImagePath $work -StorageType VHD -NoDriveLetter -Access ReadWrite | Out-Null
        $disk = $null
        for ($i = 0; $i -lt 60 -and -not $disk; $i++) {
            $disk = Get-DiskImage -ImagePath $work | Get-Disk -ErrorAction SilentlyContinue
            if (-not $disk) { Start-Sleep -Milliseconds 500 }
        }
        if (-not $disk) { throw "Mounted VHD did not show up as a disk." }
        if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false }
        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
        $disk = Get-Disk -Number $disk.Number
        Check ([uint32]$disk.Signature -eq $tmpSigU) ("mounted as disk {0} with the temporary signature 0x{1:X8}" -f $disk.Number, [uint32]$disk.Signature)
        $part = $null
        for ($i = 0; $i -lt 60 -and -not $part; $i++) {
            $part = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.Offset -eq $img.PartStart * 512 }
            if (-not $part) { Start-Sleep -Milliseconds 500 }
        }
        if (-not $part) { throw "Could not find the NTFS partition on the mounted VHD." }
        if ([int]$part.DriveLetter -ne 0) {
            Warn "Windows assigned $($part.DriveLetter): despite -NoDriveLetter; removing it"
            Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath "$($part.DriveLetter):\"
        }
        $vol = $null
        for ($i = 0; $i -lt 60 -and -not $vol; $i++) {
            $vol = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystem -eq 'NTFS' }
            if (-not $vol) { Start-Sleep -Milliseconds 500 }
        }
        if (-not $vol) { throw "NTFS volume on the mounted VHD did not come online." }
        Ok "volume $($vol.Path) online, NTFS, $(GiB $vol.Size), no drive letter"
        Save-State 'mounted'
        Fail-Point 'Mount'

        Step "Checking the file system and hashing every file (before growing)"
        Scan-Volume $vol 'before'
        $mA = Get-Manifest $vol.Path 'before'
        Fail-Point 'CheckBefore'

        Step "Growing the partition and NTFS"
        $max = (Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).SizeMax
        Check ($max -gt $part.Size) "partition can grow: $(GiB $part.Size) -> $(GiB $max)"
        Resize-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -Size $max
        $part2 = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
        Check ($part2.Size -eq $max) "partition is now $(GiB $part2.Size)"
        for ($i = 0; $i -lt 20; $i++) {
            $vol2 = $part2 | Get-Volume
            if ($vol2.Size -gt $max - 1MB) { break }
            Start-Sleep -Milliseconds 500
        }
        Check ($vol2.Size -gt $max - 1MB) "NTFS volume is now $(GiB $vol2.Size)"
        Fail-Point 'Grow'

        Step "Checking the file system and hashing every file (after growing)"
        Scan-Volume $vol2 'after'
        $mB = Get-Manifest $vol2.Path 'after'
        Compare-Manifest $mA $mB "every file and folder unchanged by the resize"
        [IO.File]::WriteAllLines($manifestFile, [string[]]$mB)
        Save-State 'checked'
        Fail-Point 'CheckAfter'

        Step "Dismounting"
        Dismount-DiskImage -ImagePath $work | Out-Null
        for ($i = 0; $i -lt 60 -and (Get-DiskImage -ImagePath $work).Attached; $i++) { Start-Sleep -Milliseconds 500 }
        Check (-not (Get-DiskImage -ImagePath $work).Attached) "work file detached"
        $mounted = $false
        Fail-Point 'Dismount'

        Step "Finalizing: strip VHD footer, restore signature, rebuild UsedMap, write RAMDisk footer"
        for ($i = 0; $i -lt 20 -and -not $fs; $i++) {
            try { $fs = [IO.File]::Open($work, 'Open', 'ReadWrite', 'None') } catch { if ($i -eq 19) { throw }; Start-Sleep -Milliseconds 500 }
        }
        $sigNow = [RdResize]::ReadAt($fs, 0x1B8, 4)
        Check ([BitConverter]::ToUInt32($sigNow, 0) -eq $tmpSigU) "Windows left the temporary signature as it was"
        $fs.SetLength($newDisk)
        # Restore the original signature and partition-1 entry except its sector count. Windows rewrites the CHS
        # fields from the VHD geometry; keep the driver's own values so the only MBR change is the size.
        [RdResize]::WriteAt($fs, 0x1B8, [byte[]]$img.Mbr[0x1B8..0x1C9])
        $bitmap = New-Object byte[] ([RdResize]::BitmapBytes($newPages))
        [Array]::Copy($img.Bitmap, $bitmap, $img.Bitmap.Length)
        $added = [RdResize]::ScanPages($fs, $newDisk, $bitmap, $true)
        Info "marked $added additional non-zero pages in the UsedMap"
        $hdr = [byte[]]$img.Header.Clone()
        [BitConverter]::GetBytes([uint64]([RdResize]::HeaderLen + $bitmap.Length)).CopyTo($hdr, 0x10)
        [RdResize]::WriteAt($fs, $newDisk, $hdr)
        [RdResize]::WriteAt($fs, $newDisk + [RdResize]::HeaderLen, $bitmap)
        $fs.Flush($true)
        Save-State 'finalized'
        Fail-Point 'Finalize'

        Step "Verifying the finished work file"
        $res = Read-Image $fs; Show-Image $res
        Assert-Layout $res
        Check ($res.Length -eq $newLen -and $res.Pages -eq $newPages) "length $($res.Length) = expected $newLen ($newPages pages)"
        $missing = [RdResize]::ScanPages($fs, $res.DiskBytes, $res.Bitmap, $false)
        Check ($missing -eq 0) "UsedMap covers every non-zero page"
        $hd = @(0..0x2F | Where-Object { ($_ -lt 0x10 -or $_ -gt 0x17) -and $img.Header[$_] -ne $res.Header[$_] })
        Check ($hd.Count -eq 0) "header identical to the original except footer length (seq, flags, instance kept)"
        $allowed = 0x1CA, 0x1CB, 0x1CC, 0x1CD
        $md = @(0..511 | Where-Object { $img.Mbr[$_] -ne $res.Mbr[$_] -and $allowed -notcontains $_ })
        foreach ($o in $md) { Warn ("MBR byte 0x{0:X3}: 0x{1:X2} -> 0x{2:X2}" -f $o, $img.Mbr[$o], $res.Mbr[$o]) }
        Check ($md.Count -eq 0) "MBR identical to the original except the partition-1 sector count; signature 0x$('{0:X8}' -f $res.Signature) restored"
        Check ($res.PartStart -eq $img.PartStart -and $res.PartType -eq $img.PartType) "partition start and type unchanged"
        Check ($res.PartSectors * 512 -eq $part2.Size) "partition entry matches what Windows reported"
        Check ($res.NtfsSectors -le $res.PartSectors -and $res.NtfsSectors -ge $res.PartSectors - 8) "NTFS fills the partition"
        $fs.Dispose(); $fs = $null
        Fail-Point 'Verify'

        Step "Swapping the work file in (original kept as $bak)"
        Assert-Quiet
        $lock.Dispose(); $lock = $null
        $o = Get-Item -LiteralPath $ImagePath -Force
        Check ($o.Length -eq $origLen -and $o.LastWriteTimeUtc -eq $origLwt) "original unchanged during the run (length and LastWriteTime)"
        Save-State 'swapping'
        $swapped = $true    # from here on, cleanup must consider the swap
        [IO.File]::Replace($work, $ImagePath, $bak, $true)
        Check ((Get-Item -LiteralPath $ImagePath).Length -eq $newLen) "resized image is at $ImagePath"
        Check ((Get-Item -LiteralPath $bak).Length -eq $origLen) "original kept at $bak"
        $state.swappedUtc = (Get-Date).ToUniversalTime().ToString('o'); Save-State 'swapped'
        Fail-Point 'Swap'

        if ($isConfigured) {
            Step "Updating registry SizeIn4kPages: $($img.Pages) -> $newPages"
            $rp = Get-RegPages
            Check ($rp.Param -eq $img.Pages -and $rp.Active -eq $img.Pages) "registry still at the old size"
            $regChanged = $true
            Set-RegPages $newPages
        }
        Save-State 'done'
        Fail-Point 'Registry'

        Write-Host ""
        if ($isConfigured) {
            Write-Host "DONE. Start the RAMDisk (fresh GUI, change nothing), then immediately run:" -ForegroundColor Green
            Write-Host "    $PSCommandPath -PostCheck$(if ($ConfigKey -ne $DefaultKey) { " -ConfigKey '$ConfigKey'" })" -ForegroundColor Green
            Write-Host "If anything is wrong: stop the RAMDisk and run -Rollback. Keep $bak until you're satisfied." -ForegroundColor Green
        } else {
            Write-Host "DONE (not the configured image; registry untouched; it would need SizeIn4kPages = $newPages)." -ForegroundColor Green
        }
    }
    catch {
        $err = $_
        Write-Host "ERROR: $($err.Exception.Message)" -ForegroundColor Red
        Write-Host "Undoing..." -ForegroundColor Yellow
        if ($fs) { try { $fs.Dispose() } catch {} ; $fs = $null }
        if ($mounted) {
            try { Dismount-DiskImage -ImagePath $work | Out-Null; Ok "work file dismounted" } catch { Warn "dismount failed: $($_.Exception.Message)" }
        }
        if ($regChanged) {
            try { Set-RegPages $state.oldPages } catch { Write-Host "COULD NOT RESTORE THE REGISTRY: set SizeIn4kPages back to $($state.oldPages) in $ConfigKey and $ActiveKey by hand." -ForegroundColor Red }
        }
        if ($lock) { $lock.Dispose(); $lock = $null }
        if ($swapped) {
            try { Restore-Original $origLen } catch { Write-Host "COULD NOT RESTORE THE ORIGINAL: $($_.Exception.Message)" -ForegroundColor Red }
        }
        if ($ownsFiles) {
            for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $work); $i++) {
                try { Remove-Item -LiteralPath $work -Force } catch { Start-Sleep -Milliseconds 500 }
            }
            if (Test-Path -LiteralPath $work) { Warn "could not delete $work" } else { Ok "work file removed" }
            if (Test-Path -LiteralPath $manifestFile) { Remove-Item -LiteralPath $manifestFile -Force }
            $o = Get-Item -LiteralPath $ImagePath -Force -ErrorAction SilentlyContinue
            if ($o -and $o.Length -eq $origLen) {
                Ok "original image is in place and unchanged in size: $ImagePath"
                if (-not (Test-Path -LiteralPath $bak) -and -not (Test-Path -LiteralPath $rejected) -and -not (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue }
            } else {
                Write-Host "ATTENTION: $ImagePath is not the original. Run -Rollback (state: $stateFile)." -ForegroundColor Red
            }
        }
        throw $err
    }
    finally {
        if ($fs) { $fs.Dispose() }
        if ($lock) { $lock.Dispose() }
    }
}

# ---------------------------------------------------------------- rollback
function Invoke-Rollback {
    Step "Rollback"
    Check (Is-Admin) "running elevated"
    Check (Test-Path -LiteralPath $stateFile) "state file found: $stateFile"
    $script:state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Info "state: phase=$($state.phase) oldPages=$($state.oldPages) newPages=$($state.newPages) started=$($state.startedUtc)"
    Assert-Quiet
    if ((Test-Path -LiteralPath $work) -and (Get-DiskImage -ImagePath $work -ErrorAction SilentlyContinue).Attached) {
        Dismount-DiskImage -ImagePath $work | Out-Null; Ok "work file dismounted"
    }
    Restore-Original ([long]$state.originalLength)
    if ($isConfigured) {
        $rp = Get-RegPages
        Check (@($state.oldPages, $state.newPages) -contains $rp.Param) "registry holds a size from this run ($($rp.Param))"
        Set-RegPages ([long]$state.oldPages)
    }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Force; Ok "work file removed" }
    if (Test-Path -LiteralPath $manifestFile) { Remove-Item -LiteralPath $manifestFile -Force }
    $fs = [IO.File]::Open($ImagePath, 'Open', 'Read', 'Read')
    try { $img = Read-Image $fs; Check ($img.Pages -eq $state.oldPages) "restored image has $($img.Pages) pages" } finally { $fs.Dispose() }
    if ($state.originalSha256) { Check ([RdResize]::HashFile($ImagePath) -eq $state.originalSha256) "restored image is byte-identical to the original (SHA-256)" }
    $state.phase = 'rolled-back'; $state.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
    Write-Host "`nROLLED BACK. Start the RAMDisk; it will load the original $(GiB ($state.oldPages * 4096)) image." -ForegroundColor Green
    Write-Host "Leftovers to delete when satisfied: $stateFile$(if (Test-Path -LiteralPath $rejected) { ", $rejected" })" -ForegroundColor Green
}

# ---------------------------------------------------------------- post-check
function Invoke-PostCheck {
    Step "Post-start check"
    Check (Test-Path -LiteralPath $stateFile) "state file found: $stateFile"
    $st = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Check ($st.phase -eq 'done') "resize completed (phase=$($st.phase))"
    Check $isConfigured "image is the configured RAMDisk image"
    $rp = Get-RegPages
    Check ($rp.Param -eq $st.newPages) "Parameters\SizeIn4kPages = $($rp.Param)"
    Check ($rp.Active -eq $st.newPages) "Active\SizeIn4KPages = $($rp.Active) (the driver copies this at start)"
    $since = [datetime]::Parse($st.swappedUtc).ToLocalTime()
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'RAMDiskVE'; StartTime = $since } -ErrorAction SilentlyContinue)
    foreach ($e in $ev) { Info ("event {0:yyyy-MM-dd HH:mm:ss}  {1}" -f $e.TimeCreated, ($e.Message -replace '\s+', ' ')) }
    $bad = @($ev | Where-Object { $_.Message -match $DriverErrors })
    Check ($bad.Count -eq 0) "no driver load errors since the swap"
    Check (@($ev | Where-Object { $_.Message -match 'Version 2 image file found' }).Count -gt 0) "driver loaded a version-2 image since the swap"
    $drv = $cfg.DiskDrive
    Check (Test-Path -LiteralPath $drv) "$drv is present"
    $di = [IO.DriveInfo]::new($drv)
    Check ($di.DriveFormat -eq 'NTFS' -and $di.TotalSize -gt ($st.newPages * 4096) - 64MB) "$drv is NTFS, $(GiB $di.TotalSize)"
    $saved = [IO.File]::ReadAllLines($manifestFile)
    $now = Get-Manifest $drv 'now'
    Compare-Manifest $saved $now "$drv contents match the resized image"
    Write-Host "`nPOST-CHECK PASSED. When satisfied, delete $bak, $stateFile and $manifestFile." -ForegroundColor Green
}

# ---------------------------------------------------------------- verify only
function Invoke-Verify {
    Step "Verifying $ImagePath (read-only)"
    Info "attributes: $((Get-Item -LiteralPath $ImagePath -Force).Attributes)"
    $fs = [IO.File]::Open($ImagePath, 'Open', 'Read', 'Read')
    try {
        $img = Read-Image $fs; Show-Image $img
        $missing = [RdResize]::ScanPages($fs, $img.DiskBytes, $img.Bitmap, $false)
        Info ("UsedMap        : {0} non-zero pages NOT marked {1}" -f $missing, $(if ($missing) { '<-- PROBLEM: data would be lost on load' } else { '(OK)' }))
        Info ("Partition fits : {0}" -f (($img.PartStart + $img.PartSectors) * 512 -le $img.DiskBytes))
        Info ("NTFS fills part: {0}" -f ($img.NtfsSectors -le $img.PartSectors -and $img.NtfsSectors -ge $img.PartSectors - 8))
        if ($isConfigured) {
            $rp = Get-RegPages
            Info ("Registry pages : Parameters={0} Active={1} -> {2}" -f $rp.Param, $rp.Active, $(if ($rp.Param -eq $img.Pages -and $rp.Active -eq $img.Pages) { 'match' } else { 'MISMATCH, driver will reject image' }))
        }
        if ($missing) { throw "UsedMap is missing $missing non-zero pages." }
    } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------- main
$DefaultKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\RAMDiskVE\Parameters'
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $Mode)
try { Start-Transcript -LiteralPath $logFile | Out-Null; $transcript = $true } catch { $transcript = $false; Write-Warning "Could not start transcript: $($_.Exception.Message)" }

$exitCode = 0
try {
    $cfg = Get-ItemProperty -LiteralPath $ConfigKey -ErrorAction SilentlyContinue
    $cfgImage = Strip-NtPath $cfg.LoadImageFile
    $cfgSave = Strip-NtPath $cfg.SaveImageFile
    if (-not $ImagePath) { $ImagePath = $cfgImage }
    if (-not $ImagePath) { throw "No -ImagePath given and no LoadImageFile in $ConfigKey." }
    $ImagePath = Full-Path $ImagePath
    $isConfigured = [bool]($cfgImage -and (Full-Path $cfgImage) -eq $ImagePath)
    $work = "$ImagePath.resize-work.vhd"; $bak = "$ImagePath.pre-resize.bak"; $rejected = "$ImagePath.resized-rejected"
    $stateFile = "$ImagePath.resize-state.json"; $manifestFile = "$ImagePath.resize-manifest.tsv"
    $state = $null
    Info "mode=$Mode image=$ImagePath configured=$isConfigured configKey=$ConfigKey log=$logFile"
    switch ($Mode) {
        'Resize'    { Invoke-Resize }
        'Rollback'  { Invoke-Rollback }
        'PostCheck' { Invoke-PostCheck }
        'Verify'    { Invoke-Verify }
    }
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    if ($transcript) { Stop-Transcript | Out-Null }
}
exit $exitCode
