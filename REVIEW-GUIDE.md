# RAMDisk resize: independent review & test guide (v2, fail-safe design)

**Audience:** a Claude instance running in an *elevated* Windows PowerShell on the same machine.
**Goal:** independently check the analysis and `Resize-RamDiskImage.ps1`, run the test suite on
**copies only**, verify the result, and give a **confidence vote** on whether it is safe to use against
the live image. Write your findings to `D:\Claude\ramdisk\REVIEW-RESULTS.md`.

Don't take anything below on trust. Each claim comes with a way to re-check it. Disagreement is useful.
Background on why v2 exists: `D:\Claude\ramdisk\plan.md` (gaps G1â€“G14 in v1 and how each is addressed).

---

## 0. Hard rules (the live system must not be disturbed)

The user's RAMDisk is **R:**. The user's `%TEMP%` (`R:\Temp`) and browser caches live on it, and
stopping it at the wrong moment has caused serious problems before.

- **Do NOT** stop, start, restart, or reconfigure the RAMDisk, the `RAMDiskVE` driver/device, or the AMD RAMDisk GUI.
- **Do NOT** open, copy or touch `G:\RAMDisk.img` (the live image), except through VSS (Â§3.4) if the user agrees.
- **Do NOT** write to `HKLM\SYSTEM\CurrentControlSet\Services\RAMDiskVE\*`. Reading is fine. Tests use
  `-ConfigKey HKCU:\Software\RamDiskResizeTest\Parameters` instead.
- **Do NOT** run a resize without both `-ImagePath <copy under D:\Claude\ramdisk\testrun>` and a test `-ConfigKey`.
  (The test suite runs one deliberate guard test without them: it must refuse because R: exists, before opening anything.)
- **Never manually mount a copy whose MBR disk signature is the live one** (`0xF1A80B7D` = registry `DiskAdminSig`
  4054322045). Re-sign copies first (the test suite does: `0x44332211`). The tool itself always mounts with a random
  temporary signature.
- Leave `D:\Claude\ramdisk\RAMDisk-Backup.img` unmodified. Free space on D: is ample; delete test copies when done.

Running scripts: `powershell -NoProfile -ExecutionPolicy Bypass -File <script> ...`. Every run of the tool writes
a full transcript to `D:\Claude\ramdisk\logs\`; the suite also keeps per-run output in `testrun\out\`.

---

## 1. Background

- Software: AMD Radeon RAMDisk = Dataram RAMDisk **4.4.0.36**, driver `RAMDiskVE.sys`, PnP root device
  `ROOT\DATARAM_RAMDISK_DEVICES\0000`. It loads the image at every boot (`AutoStart=1`; System log, provider
  RAMDiskVE: "RamDiskLoadImage: Version 2 image file found" on each boot, no load errors on record).
- Config: `HKLM\SYSTEM\CurrentControlSet\Services\RAMDiskVE\Parameters` (+ `\Active`, which the **driver** writes from
  `Parameters` at start). `SizeIn4kPages = 1572864` (6 GiB, DWORD), `LoadImageFile = SaveImageFile = \??\G:\RAMDisk.img`,
  `LoadImageOnStart = 2`, `BackgroundUpdate = 1`, `SaveImageOnExit = 0`, `NoSparseImage = 0`, `NoBackupFile = 1`, `DiskDrive = R:\`.
- The GUI keeps no size of its own (`%LOCALAPPDATA%\Dataram_Corporation\*\user.config` has only UI flags), so the registry is the only place the size is stored.
- The GUI has no resize, only "new disk of size X", which discards contents. The user wants 6 â†’ 8 GiB while keeping contents.
- Live image: not sparse, 6,442,647,600 bytes. G: is an NVMe SSD with ~700 GB free. RAM is 64 GB.
- `D:\Claude\ramdisk\RAMDisk-Backup.img` (6,442,647,600 bytes, June 2025) is an old copy of the image.

## 2. Claims to verify

### 2.1 Image file format ("version 2")

```
[0, D)              raw disk, D = SizeIn4kPages * 4096 (MBR, one NTFS partition type 0x07 at LBA 32)
[D, D+0x30)         header
    +0x00  16 bytes  magic GUID 8746ddf4-b44d-4af9-942c-752f92fb3da9  (bytes f4 dd 46 87 4d b4 f9 4a 94 2c 75 2f 92 fb 3d a9)
    +0x10  u64       footer length = 0x30 + bitmap bytes
    +0x18  u32       write sequence counter
    +0x1C  u32       flags, bit0 = dirty
    +0x20  16 bytes  instance GUID (ExUuidCreate)
[D+0x30, end)       UsedMap: 1 bit per 4 KiB page, LSB-first, size = ceil(pages/64)*8 bytes
```
The backup has D = 0x180000000, footer length 0x30030, seq 2266617, flags 0, instance `cf53531c-7ed1-11ee-9cc1-04421ae7116d`.
**Check:** hex-dump offset 0x180000000 of the backup, or run `-VerifyOnly` (Â§3.1).

### 2.2 Driver behaviour (disassembly of RAMDiskVE.sys 4.4.0.36, RVAs)

| RVA | What | Behaviour |
|---|---|---|
| `0x43c8` | ReadImageFileMetadata | disk bytes from registry. EOF == disk â†’ v1. Reads 0x30 bytes at `disk`, checks the magic (else "Incorrect image file format identifier"). Requires `disk + header.len == EOF` (else **"Incorrect image file size"**). |
| `0x10dc` | bitmap size | `((pages + 0x3f) >> 6) << 3` |
| `0x5f40â€¦0x6578` | RamDiskLoadImage | Status `[ext+0xb20]`: 0x80000000 at start, 0x8000xxxx = progress (`0x647a`), **2 = loaded**, **4 = failed** (`0x6545`). Stores seq/instance/LastWriteTime. Logs "marked dirty" if flag bit0. Loads only pages whose UsedMap bit is set. |
| `0x6559`â€“`0x6572` | open failure | "Unable to open file for disk image load" sets status **2** (not 4!). Background update then opens the path with FILE_OPEN_IF (`0x4f22`) and **creates a new image**. â‡’ the image path must never be missing. |
| `0xe996` | device start | With a load configured, waits for the load. If status == 4, start **fails** (`0xc000009a`) and the device is torn down â‡’ a rejected image gives no R: at all, and the file isn't touched. |
| `0x3ecf`, `0x4ed3` | save / background-update thread | both do nothing when status == 4 (second line of defence). |
| `0x452c`, `0x4fe2`â€“`0x503b` | background verify | If LastWriteTime, instance or seq differ from memory: "Modified image file detectedâ€¦ re-writing image" (truncate + full rewrite from RAM). Safe only after a successful load. |
| `0xdf14`â€“`0xe210` | config | Reads `Parameters`, writes `Active` (incl. `SizeIn4KPages` at `0xe00b`). |

**Consequences:** (1) the image length and `SizeIn4kPages` must change together; a mismatch fails safely (no R:, image untouched).
(2) After growing, every non-zero page must have its UsedMap bit set. (3) Never let the driver start while `G:\RAMDisk.img` is missing.

**How to check:** `tools\rdis.py` (capstone + pefile):
```powershell
python -m venv D:\Claude\ramdisk\tools\venv
D:\Claude\ramdisk\tools\venv\Scripts\pip install capstone pefile
$py = 'D:\Claude\ramdisk\tools\venv\Scripts\python.exe'; $sys = 'C:\Program Files (x86)\Radeon RAMDisk\RAMDiskVE.sys'
& $py D:\Claude\ramdisk\tools\rdis.py $sys strings       # every code reference to a string
& $py D:\Claude\ramdisk\tools\rdis.py $sys refs b20      # every use of the load-status field
& $py D:\Claude\ramdisk\tools\rdis.py $sys 43c8 4523     # ReadImageFileMetadata
& $py D:\Claude\ramdisk\tools\rdis.py $sys 5f40 6590     # RamDiskLoadImage
& $py D:\Claude\ramdisk\tools\rdis.py $sys e960 ea80     # device start: load failure handling
& $py D:\Claude\ramdisk\tools\rdis.py $sys 4e90 5060     # background update thread start
```
Still worth a second look: any other read of the footer fields, any checksum, any dependency on the partition table or
`DiskAdminSig` (referenced at `0x701a`), and the demand-load path (`ext+0x5e0`, callback `0x5d08`).

### 2.3 UsedMap semantics (checked on the backup)
Non-zero pages: 669,308. Non-zero pages with bit **clear**: **0**. Bit set but page all-zero: 47,445. The bitmap is a
superset of the non-zero pages. The tool **refuses** to resize an image where this doesn't hold.

### 2.4 R: is not visible to the Windows storage stack
`Get-Partition -DriveLetter R` fails and `Get-Disk` doesn't list it, so NTFS has to be grown offline inside the image.

## 3. The tool (`Resize-RamDiskImage.ps1`, v2)

Read the whole script. **Principle: the original image is never modified.** Phases (each can be failed on purpose with `-FailAt`):

| Phase | Does | Key checks |
|---|---|---|
| Preflight | | elevated. No leftover work/bak/state/manifest/rejected files. Configured image: Load == Save file, DiskDrive absent, GUI/`rdc`/`rdcq` not running, registry `Parameters` == `Active` == image pages (DWORD). Not dirty (no override for the configured image). UsedMap covers every non-zero page. RAM and free space OK. |
| Copy | holds the original open with share-read for the whole run (nobody, including the driver, can write it) and copies it to `<image>.resize-work.vhd` | SHA-256 of the source while copying == SHA-256 re-read from the work file. Work file not sparse/compressed/encrypted. |
| Prepare | drops the footer, extends with zeros, writes a **random temporary MBR signature** (unique among disks), appends a fixed-VHD footer | |
| Mount | `Mount-DiskImage -NoDriveLetter` | disk has the temporary signature. Any assigned letter is removed. NTFS volume online. |
| CheckBefore | `Repair-Volume -Scan` (chkdsk fallback). Manifest A: every file's size + SHA-256 | `NoErrorsFound` |
| Grow | `Resize-Partition` to `SizeMax` | partition == max, volume â‰ˆ max |
| CheckAfter | scan again. Manifest B, saved as `<image>.resize-manifest.tsv` | `NoErrorsFound`. **A == B** |
| Dismount | | detached |
| Finalize | strips the VHD footer, restores the original signature, UsedMap = old bits OR non-zero pages, header with only the length changed | temporary signature still there (Windows didn't change it) |
| Verify | re-reads the work file | length 8,590,196,784. 0 unmarked pages. Header identical except length. MBR identical except the partition-1 sector count (Finalize restores the driver's CHS bytes, which Windows rewrites). NTFS fills the partition. |
| Swap | re-checks R: absent and GUI closed, releases the lock, confirms the original's length/LastWriteTime didn't change, then `File.Replace(work, image, image.pre-resize.bak)` | new image and bak have the expected lengths. The path is never missing. |
| Registry | (configured image only) | still old size â†’ write both â†’ read back |

Any failure undoes everything: dismount, restore the registry, swap back (the resized file is kept as
`.resized-rejected`), and delete the work file. Progress is journaled in `<image>.resize-state.json`.
Other modes: `-VerifyOnly`, `-Rollback` (puts the bak back, restores the registry, checks SHA-256 against the original),
and `-PostCheck` (after start: registry, driver events, drive size, and R: contents == manifest).

### 3.1 Test suite

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Claude\ramdisk\Test-ResizeTool.ps1
```
It copies the backup to `testrun\base.img`, re-signs it, and creates `HKCU:\Software\RamDiskResizeTest\Parameters` pointing at
`testrun\case.img` with a free fake drive letter. The tool then treats the copy as the configured (live) image, so
the registry, the "drive absent" and "GUI closed" checks, the swap and the rollback are all exercised. Cases:

- **T1** `-VerifyOnly`.
- **T6aâ€“g** refusals: the real config while R: runs, a leftover state file, the drive present, the GUI running (a
  renamed `ping.exe` named `rdcq.exe`), a registry mismatch, a dirty image with `-Force`, and a size that isn't larger.
- **T4** failure injected after each of the 11 phases. After each one: the original is byte-identical, nothing is left behind, nothing is mounted, and the registry is at the old size.
- **T2** full run, then `-VerifyOnly`, then a second run (must refuse while the results are pending).
- **T3** independent: mount the result read-only, chkdsk, and compare a fresh manifest with the saved one.
- **T5** `-Rollback`: original bytes and registry restored.
- Final check that the live registry and R: are untouched and the source backup is unchanged.

Results: console, `test-results.json`, `testrun\out\*.txt`. My run: see `TEST-RESULTS.md`. **Re-run it yourself**
and compare. Don't trust my results file.

### 3.2 Things to try beyond the suite (encouraged)
- Read the script looking for a path where a failure leaves the original modified or missing. Then try to trigger it (kill the
  process mid-copy or mid-mount with Task Manager, then run `-Rollback` with the test key and check the hash).
- Confirm that `File.Replace` keeps the original under the backup name on this NTFS volume (the T4 Swap case covers it).
- Check how the temporary signature affects `HKLM\SYSTEM\MountedDevices` (it adds an entry for the temporary disk, which is harmless).

### 3.3 (Optional) test on a current snapshot of the live image via VSS
Read-only toward G:. It doesn't stop the RAMDisk. **Only if the user agrees.** `Copy-Item` can't read GLOBALROOT paths, so use .NET:
```powershell
$r  = Get-CimClass Win32_ShadowCopy | Invoke-CimMethod -MethodName Create -Arguments @{Volume='G:\'; Context='ClientAccessible'}
$sc = Get-CimInstance Win32_ShadowCopy | Where-Object ID -eq $r.ShadowID
New-Item -ItemType Directory D:\Claude\ramdisk\testrun -Force | Out-Null
[IO.File]::Copy($sc.DeviceObject + '\RAMDisk.img', 'D:\Claude\ramdisk\testrun\vss.img')
$sc | Remove-CimInstance                                    # delete the shadow copy
Get-CimInstance Win32_ShadowCopy | Where-Object ID -eq $r.ShadowID   # expect nothing
```
The snapshot is crash-consistent at best and is probably marked dirty. Re-sign it (write 4 bytes at 0x1B8), then use it as
the source of the suite: `Test-ResizeTool.ps1 -Source D:\Claude\ramdisk\testrun\vss.img` won't work as-is (T6f and T2
expect a clean backup), so run the tool directly instead:
`Resize-RamDiskImage.ps1 -ImagePath ...\vss.img -NewSizeGB 8 -Force` (not configured â†’ registry untouched).
It contains current browser data: delete it afterwards.

## 4. Known risks / open questions to weigh in the vote

1. **Unknown driver checks.** Only the paths in Â§2.2 were reviewed. A second look at the load path is the most valuable item.
   A mismatch fails safely (see `0xe996`), so the remaining risk is a check that *accepts* the image but treats it wrongly.
2. **Zero-bit pages in RAM** are assumed to read as zero (memory from `MmAllocatePagesForMdlEx`). This already applies to
   every never-written page today, so it's existing behaviour, not a new one.
3. **Stopping the RAMDisk cleanly** (user's step, via the GUI). The tool refuses a dirty image, which catches an unclean stop.
4. **GUI opened before the change.** It could push 6 GiB back on Start. The tool refuses to run while the GUI is open. The runbook says to
   open it fresh afterwards. A mismatch would fail safely anyway (no R:, image untouched â†’ `-Rollback` or fix the registry).
5. **Reboot mid-run:** the original is still at `G:\RAMDisk.img` and the registry is unchanged until the last two steps, so it boots as before.
   A reboot between the swap and the registry write â†’ mismatch â†’ fails safely. Run `-Rollback`, or finish by setting the registry.
6. `Repair-Volume -Scan` and mounting may write NTFS metadata/`System Volume Information` into the **work copy**. That's harmless and excluded from the manifest.

## 5. Real-run runbook (the user's decision, not part of this review)

1. Set user `TEMP`/`TMP` to `%LOCALAPPDATA%\Temp`, then sign out/in. Close browsers.
2. AMD RAMDisk GUI â†’ **Stop** â†’ close the GUI.
3. `powershell -NoProfile -ExecutionPolicy Bypass -File D:\Claude\ramdisk\Resize-RamDiskImage.ps1 -VerifyOnly` â†’ `dirty=False`, UsedMap OK, registry match.
4. `... Resize-RamDiskImage.ps1 -NewSizeGB 8`. It ends "DONE", or it fails and reports that everything was undone.
5. Open the GUI fresh â†’ **Start** (change nothing) â†’ right away run `... Resize-RamDiskImage.ps1 -PostCheck`.
6. If PostCheck fails: GUI â†’ Stop, close it, run `... -Rollback`, then Start â†’ original 6 GiB disk.
7. Restore `TEMP`/`TMP` to `R:\Temp`, then sign out/in. Later, delete `G:\RAMDisk.img.pre-resize.bak`, `.resize-state.json` and `.resize-manifest.tsv`.

## 6. Deliverable: `D:\Claude\ramdisk\REVIEW-RESULTS.md`

- For each claim in Â§2: **confirmed / contradicted / not checked**, with evidence (command + key output).
- Your test-suite run (paste the summary table) and anything you tried from Â§3.2/Â§3.3.
- Anything in the scripts you consider a bug or risk, with line references.
- **Confidence vote** (0â€“10) that the runbook in Â§5 produces an 8 GiB R: with contents intact, *and* separately that a failure
  at any point leaves the user able to get back to the original 6 GiB disk. Name the single biggest remaining risk.
- Cleanup: the suite deletes its copies and test key unless `-Keep`. Also delete `tools\venv` and any `vss.img`, or say what's left.
