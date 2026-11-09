<#
.SYNOPSIS
  Test suite for Resize-RamDiskImage.ps1. Works ONLY on copies in .\testrun and a scratch
  registry key under HKCU. Never touches the live image, the live registry key, or R:.
  Run from an elevated Windows PowerShell:
    powershell -NoProfile -ExecutionPolicy Bypass -File D:\Claude\ramdisk\Test-ResizeTool.ps1
.PARAMETER Source
  Image to copy as the test base (default: RAMDisk-Backup.img next to this script).
.PARAMETER Keep
  Don't delete the test files/key at the end.
#>
param(
    [string]$Source = (Join-Path $PSScriptRoot 'RAMDisk-Backup.img'),
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
$tool    = Join-Path $PSScriptRoot 'Resize-RamDiskImage.ps1'
$dir     = Join-Path $PSScriptRoot 'testrun'
$base    = Join-Path $dir 'base.img'
$case    = Join-Path $dir 'case.img'
$logDir  = Join-Path $dir 'out'
$testKey = 'HKCU:\Software\RamDiskResizeTest\Parameters'
$liveKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\RAMDiskVE\Parameters'
$OldPages = 1572864; $NewPages = 2097152; $NewLen = 8590196784
$results = New-Object System.Collections.Generic.List[object]

# Load the tool's C# helpers (RdResize) for hashing, manifests and VHD footers.
$src = Get-Content $tool -Raw
Add-Type -Language CSharp -TypeDefinition ([regex]::Match($src, "(?s)TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value)

function Say($m) { Write-Host $m -ForegroundColor Cyan }
function Record($name, $pass, $detail) {
    $results.Add([pscustomobject]@{ Test = $name; Result = $(if ($pass) { 'PASS' } else { 'FAIL' }); Detail = $detail })
    Write-Host ("[{0}] {1}  {2}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $name, $detail) -ForegroundColor $(if ($pass) { 'Green' } else { 'Red' })
}
function Run-Tool($name, [string[]]$a) {
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool @a 2>&1 | Out-String
    $code = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $logDir "$name.txt") -Value $out -Encoding UTF8
    [pscustomobject]@{ Code = $code; Out = $out }
}
function Set-TestReg($pages, $drive) {
    New-Item -Path "$testKey\Active" -Force | Out-Null
    $nt = "\??\$case"
    foreach ($k in $testKey) {
        Set-ItemProperty $k -Name LoadImageFile -Value $nt -Type String
        Set-ItemProperty $k -Name SaveImageFile -Value $nt -Type String
        Set-ItemProperty $k -Name DiskDrive -Value $drive -Type String
        Set-ItemProperty $k -Name SizeIn4kPages -Value $pages -Type DWord
    }
    Set-ItemProperty "$testKey\Active" -Name SizeIn4KPages -Value $pages -Type DWord
}
function Get-TestReg { "{0}/{1}" -f (Get-ItemProperty $testKey).SizeIn4kPages, (Get-ItemProperty "$testKey\Active").SizeIn4KPages }
function Leftovers { @("$case.resize-work.vhd", "$case.pre-resize.bak", "$case.resize-manifest.tsv", "$case.resize-state.json", "$case.resized-rejected" | Where-Object { Test-Path -LiteralPath $_ }) }
function Attached { @(Get-Disk | Where-Object { $_.Location -like "*$dir*" }).Count }
# After a refused or failed run: original byte-identical, nothing left behind, registry at old size.
function Pristine($name, $extra) {
    $h = [RdResize]::HashFile($case); $left = Leftovers; $reg = Get-TestReg; $att = Attached
    $ok = ($h -eq $script:H) -and ($left.Count -eq 0) -and ($reg -eq "$OldPages/$OldPages") -and ($att -eq 0)
    Record $name ($ok -and $extra) ("hash {0}; leftovers [{1}]; registry {2}; attached {3}" -f $(if ($h -eq $script:H) { 'same' } else { 'CHANGED' }), ($left -join ', '), $reg, $att)
}

# ---------------------------------------------------------------- safety
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run elevated." }
if (-not $testKey.StartsWith('HKCU:\Software\RamDiskResizeTest')) { throw "bad test key" }
$liveBefore = Get-ItemProperty $liveKey
$freeLetter = [char[]](81..90) | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
if (-not $freeLetter) { throw "No free drive letter Q..Z for the test DiskDrive." }
$fakeDrive = "$($freeLetter):\"

# ---------------------------------------------------------------- setup
Say "Setup in $dir (fake DiskDrive $fakeDrive)"
if (Test-Path $dir) { throw "$dir exists from an earlier run; remove it first." }
New-Item -ItemType Directory -Path $dir, $logDir | Out-Null
$srcHash = [RdResize]::HashFile($Source)
Copy-Item -LiteralPath $Source -Destination $base
$fs = [IO.File]::Open($base, 'Open', 'ReadWrite', 'None')
[RdResize]::WriteAt($fs, 0x1B8, [byte[]](0x11, 0x22, 0x33, 0x44)); $fs.Dispose()   # never collide with the live disk signature
Copy-Item -LiteralPath $base -Destination $case
$script:H = [RdResize]::HashFile($case)
Set-TestReg $OldPages $fakeDrive
$cfgArgs = @('-ImagePath', $case, '-ConfigKey', $testKey)

# ---------------------------------------------------------------- T1
Say "T1 VerifyOnly"
$r = Run-Tool 'T1-verify' (@('-VerifyOnly') + $cfgArgs)
Record 'T1 VerifyOnly on copy' ($r.Code -eq 0 -and $r.Out -match '0 non-zero pages NOT marked \(OK\)' -and $r.Out -match 'Parameters=1572864 Active=1572864 -> match') "exit $($r.Code)"

# ---------------------------------------------------------------- T6 refusals
Say "T6 refusals"
$r = Run-Tool 'T6a-live-guard' @('-NewSizeGB', '8')   # real config: must refuse because R: exists, before opening anything
Record 'T6a live image refused while RAMDisk runs' ($r.Code -eq 1 -and $r.Out -match 'exists: the RAMDisk is running') "exit $($r.Code)"

Set-Content -LiteralPath "$case.resize-state.json" -Value '{}'
$r = Run-Tool 'T6b-leftover' (@('-NewSizeGB', '8') + $cfgArgs)
$leftStill = Test-Path -LiteralPath "$case.resize-state.json"
Remove-Item -LiteralPath "$case.resize-state.json"
Pristine 'T6b leftover state file refused (and not deleted)' ($r.Code -eq 1 -and $r.Out -match 'Leftover' -and $leftStill)

Set-TestReg $OldPages 'C:\'
$r = Run-Tool 'T6c-drive-present' (@('-NewSizeGB', '8') + $cfgArgs)
Set-TestReg $OldPages $fakeDrive
Pristine 'T6c configured drive present refused' ($r.Code -eq 1 -and $r.Out -match 'exists: the RAMDisk is running')

$fakeGui = Join-Path $dir 'rdcq.exe'; Copy-Item "$env:SystemRoot\System32\PING.EXE" $fakeGui
$p = Start-Process $fakeGui -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru
$r = Run-Tool 'T6d-gui-running' (@('-NewSizeGB', '8') + $cfgArgs)
Stop-Process -Id $p.Id -Force; $p.WaitForExit(); Remove-Item $fakeGui
Pristine 'T6d GUI/console process running refused' ($r.Code -eq 1 -and $r.Out -match 'GUI/console is running')

Set-TestReg ($OldPages + 1) $fakeDrive; Set-ItemProperty "$testKey\Active" -Name SizeIn4KPages -Value $OldPages -Type DWord
$r = Run-Tool 'T6e-registry-mismatch' (@('-NewSizeGB', '8') + $cfgArgs)
Set-TestReg $OldPages $fakeDrive
Pristine 'T6e registry/image size mismatch refused' ($r.Code -eq 1 -and $r.Out -match 'CHECK FAILED: registry')

$fs = [IO.File]::Open($case, 'Open', 'ReadWrite', 'None'); $flagOff = 6GB + 0x1C
$flag = [RdResize]::ReadAt($fs, $flagOff, 1); [RdResize]::WriteAt($fs, $flagOff, [byte[]]($flag[0] -bor 1)); $fs.Dispose()
$r = Run-Tool 'T6f-dirty' (@('-NewSizeGB', '8', '-Force') + $cfgArgs)
$fs = [IO.File]::Open($case, 'Open', 'ReadWrite', 'None'); [RdResize]::WriteAt($fs, $flagOff, $flag); $fs.Dispose()
Pristine 'T6f dirty configured image refused even with -Force' ($r.Code -eq 1 -and $r.Out -match 'marked dirty')

$r = Run-Tool 'T6g-not-larger' (@('-NewSizeGB', '6') + $cfgArgs)
Pristine 'T6g new size not larger refused' ($r.Code -eq 1 -and $r.Out -match 'is larger than current')

# ---------------------------------------------------------------- T4 failure injection
Say "T4 failure injection"
foreach ($phase in 'Copy', 'Prepare', 'Mount', 'CheckBefore', 'Grow', 'CheckAfter', 'Dismount', 'Finalize', 'Verify', 'Swap', 'Registry') {
    $r = Run-Tool "T4-$phase" (@('-NewSizeGB', '8', '-FailAt', $phase) + $cfgArgs)
    $injected = $r.Code -eq 1 -and $r.Out -match "INJECTED FAILURE after phase '$phase'"
    if ($phase -in 'Swap', 'Registry') {
        # The resized image was in place; it must have been swapped back and kept as .resized-rejected.
        $rej = "$case.resized-rejected"
        $kept = (Test-Path -LiteralPath $rej) -and (Get-Item -LiteralPath $rej).Length -eq $NewLen -and (Test-Path -LiteralPath "$case.resize-state.json")
        Remove-Item -LiteralPath $rej, "$case.resize-state.json" -ErrorAction SilentlyContinue
        Pristine "T4 fail after $phase -> undone (resized kept as .resized-rejected)" ($injected -and $kept)
    } else {
        Pristine "T4 fail after $phase -> undone" $injected
    }
}

# ---------------------------------------------------------------- T2 happy path
Say "T2 full run (pretend-live via test key)"
$r = Run-Tool 'T2-resize' (@('-NewSizeGB', '8') + $cfgArgs)
$st = Get-Content "$case.resize-state.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
$ok = $r.Code -eq 0 -and (Get-Item $case).Length -eq $NewLen -and (Get-TestReg) -eq "$NewPages/$NewPages" -and $st.phase -eq 'done' -and
      (Test-Path "$case.resize-manifest.tsv") -and -not (Test-Path "$case.resize-work.vhd") -and (Test-Path "$case.pre-resize.bak") -and ([RdResize]::HashFile("$case.pre-resize.bak") -eq $script:H) -and (Attached) -eq 0
Record 'T2 resize 6->8 GiB: image, registry, backup, state, manifest' $ok ("exit {0}; length {1}; registry {2}; phase {3}" -f $r.Code, (Get-Item $case).Length, (Get-TestReg), $st.phase)
$r2 = Run-Tool 'T2-verify-after' (@('-VerifyOnly') + $cfgArgs)
Record 'T2 VerifyOnly after resize' ($r2.Code -eq 0 -and $r2.Out -match '8\.00 GiB \(2097152 pages\)' -and $r2.Out -match 'Parameters=2097152 Active=2097152 -> match' -and $r2.Out -match 'MBR signature  : 0x44332211' -and $r2.Out -match 'seq=2266617 dirty=False instance=cf53531c') "exit $($r2.Code)"
$r3 = Run-Tool 'T2-rerun-refused' (@('-NewSizeGB', '9') + $cfgArgs)
Record 'T2 second run refused while results are pending' ($r3.Code -eq 1 -and $r3.Out -match 'Leftover') "exit $($r3.Code)"

# ---------------------------------------------------------------- T3 independent check
Say "T3 independent mount of the result"
$t3 = Join-Path $dir 't3.vhd'
Copy-Item -LiteralPath $case -Destination $t3
$fs = [IO.File]::Open($t3, 'Open', 'ReadWrite', 'None'); $fs.SetLength(8GB); [RdResize]::WriteAt($fs, 8GB, [RdResize]::VhdFooter(8GB)); $fs.Dispose()
try {
    Mount-DiskImage -ImagePath $t3 -Access ReadOnly -NoDriveLetter | Out-Null
    $d = $null; for ($i = 0; $i -lt 60 -and -not $d; $i++) { $d = Get-DiskImage -ImagePath $t3 | Get-Disk -ErrorAction SilentlyContinue; if (-not $d) { Start-Sleep -Milliseconds 500 } }
    $v = $null; for ($i = 0; $i -lt 60 -and -not $v; $i++) { $v = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue | Where-Object FileSystem -eq 'NTFS'; if (-not $v) { Start-Sleep -Milliseconds 500 } }
    $chk = & chkdsk.exe $v.Path.TrimEnd('\') 2>&1 | Out-String; $chkCode = $LASTEXITCODE
    Set-Content (Join-Path $logDir 'T3-chkdsk.txt') $chk
    $m = [RdResize]::Manifest($v.Path, [string[]]@('System Volume Information'))
    $saved = [IO.File]::ReadAllLines("$case.resize-manifest.tsv")
    $same = $m.Count -eq $saved.Count; if ($same) { for ($i = 0; $i -lt $m.Count; $i++) { if ($m[$i] -cne $saved[$i]) { $same = $false; break } } }
    $orig = @($saved | Where-Object { $_[0] -eq 'F' }).Count
    Record 'T3 result mounts read-only, chkdsk clean, contents = manifest' ($chkCode -eq 0 -and $same -and $v.Size -gt 8GB - 64MB) ("chkdsk exit {0}; volume {1:N2} GiB; {2} files; manifest match {3}" -f $chkCode, ($v.Size / 1GB), $orig, $same)
} catch {
    Record 'T3 result mounts read-only, chkdsk clean, contents = manifest' $false $_.Exception.Message
} finally {
    Dismount-DiskImage -ImagePath $t3 -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $t3 -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- T5 rollback
Say "T5 rollback"
$r = Run-Tool 'T5-rollback' (@('-Rollback') + $cfgArgs)
$rej = "$case.resized-rejected"
$kept = (Test-Path $rej) -and (Get-Item $rej).Length -eq $NewLen
$st = Get-Content "$case.resize-state.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
$phaseOk = $st.phase -eq 'rolled-back'
Remove-Item -LiteralPath $rej, "$case.resize-state.json" -ErrorAction SilentlyContinue
Pristine 'T5 rollback restores original bytes and registry' ($r.Code -eq 0 -and $kept -and $phaseOk -and $r.Out -match 'byte-identical to the original')

# ---------------------------------------------------------------- live untouched
$liveAfter = Get-ItemProperty $liveKey
$liveSame = $liveAfter.SizeIn4kPages -eq $liveBefore.SizeIn4kPages -and $liveAfter.LoadImageFile -eq $liveBefore.LoadImageFile -and (Test-Path 'R:\') -and ([RdResize]::HashFile($Source) -eq $srcHash)
Record 'Live config untouched, R: still present, source backup unchanged' $liveSame ("live SizeIn4kPages {0}; R: {1}" -f $liveAfter.SizeIn4kPages, (Test-Path 'R:\'))

# ---------------------------------------------------------------- summary
$results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$results | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'test-results.json') -Encoding UTF8
$fail = @($results | Where-Object Result -ne 'PASS').Count
if (-not $Keep) {
    Remove-Item -Path (Join-Path $dir '*.img'), (Join-Path $dir '*.vhd'), (Join-Path $dir '*.bak'), (Join-Path $dir '*.json'), (Join-Path $dir '*.tsv'), (Join-Path $dir '*rejected') -ErrorAction SilentlyContinue
    Remove-Item -Path 'HKCU:\Software\RamDiskResizeTest' -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("{0} passed, {1} failed. Per-run output in {2}" -f ($results.Count - $fail), $fail, $logDir) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $fail
