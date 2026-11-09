# Plan: make the RAMDisk resize fail-safe

**Date:** 2026-10-16
**Goal:** grow R: from 6 GiB to 8 GiB while keeping its contents. No step may destroy data, and
every failure must leave the original image intact or be undone automatically.

## 1. New facts (gathered read-only, 2026-10-16)

| Fact | Evidence | Consequence |
|---|---|---|
| A driver that **rejects** an image (bad size, magic or footer) sets load status 4. Device start then **fails** (`0xe996`: status 4 â†’ `0xc000009a`, teardown). The save path and the background-update thread also do nothing on status 4. | RAMDiskVE.sys RVA `0x6545` (status := 4), `0xe996`, `0x3ecf`, `0x4ed3` (`cmp [ext+0xb20],4`) | A size mismatch means **no R:**, and the image is left untouched. It never means a lost image. |
| If the image file is **missing**, the driver sets status 2 (`0x656d`). Background update then opens the path with FILE_OPEN_IF (`0x4f22`, disposition 3), creating a **new** image there. | disassembly | **The image path must never be missing** at a moment when the driver could start (boot). |
| If an existing image fails the background-update check, the driver truncates it and rewrites it from RAM. | `0x4fe2`â€“`0x503b` | Only safe because RAM holds the loaded data. That holds once the load has succeeded. |
| The driver copies `Parameters` â†’ `Parameters\Active` at start (`0xdf14`â€“`0xe210`, `SizeIn4KPages` at `0xe00b`). | disassembly | `Parameters` is the value that matters. Writing both is harmless and consistent. |
| The GUI stores no size setting (only `user.config` UI flags). The size lives only in the registry. | `%LOCALAPPDATA%\Dataram_Corporation\*\user.config` | The GUI only overwrites the size if it was opened **before** the change and then pushes its form values. It must be closed. |
| The driver loads at every boot from `G:\RAMDisk.img` (226 "Version 2 image file found" events, zero load errors). | System log, provider RAMDiskVE | `AutoStart=1`: a reboot in the middle of the procedure starts the driver. |
| The live image isn't sparse. It's 6,442,647,600 bytes, the same as the backup. G: is an SSD with 712 GB free. RAM is 64 GB. | file attributes, Get-Volume, CIM | The sparse-VHD mount block doesn't apply today. Space and RAM are fine. |
| The disk is a PnP root device `ROOT\DATARAM_RAMDISK_DEVICES\0000`, service RAMDiskVE (Manual, Running). | Get-PnpDevice, Enum key | Stop/start can be done from the GUI. |
| .NET in Windows PowerShell 5.1 can walk `\\?\Volume{GUID}\` paths. | tested on G: | File-level content verification is possible without assigning a drive letter. |

## 2. Gaps and problems in the current tool and guide

| # | Problem | Severity |
|---|---|---|
| G1 | **The tool edits the only live copy in place.** Truncate â†’ extend â†’ rename to `.vhd` â†’ mount â†’ write. A failure or reboot partway leaves the image unloadable or, worse, missing (â†’ the driver creates a new blank image at that path at boot). The backup is a separate copy that nobody verifies. | critical |
| G2 | **The live run mounts with the original disk signature `F1A80B7D`**, which `MountedDevices` maps to R:. The tests re-sign the copies, so the live path is never exercised. Windows could give the mount the letter R:, and processes using `R:\Temp` could write into it. | high |
| G3 | **No content check.** The tool checks the layout, but nothing proves that files are byte-identical after Windows grows NTFS. | high |
| G4 | **No file-system check** before or after the resize (a corrupt FS would be grown silently). | high |
| G5 | The backup copy isn't verified (no hash comparison). | medium |
| G6 | The registry update doesn't confirm the old value first, doesn't read back, and doesn't roll back if one of the two writes fails. The registry path is never exercised in tests. | medium |
| G7 | Image swap and registry aren't journaled. There is no `-Rollback`, so recovery is manual and error-prone. | medium |
| G8 | No check that the GUI is closed. Re-checking that R: is gone happens only once, at the start. Nothing stops the driver from being started mid-run. | medium |
| G9 | `-Force` lets a **dirty** live image through. | medium |
| G10 | No after-start check (event log, R: size, contents). | medium |
| G11 | No failure-injection tests: the cleanup/rollback paths are untested. | medium |
| G12 | Console output (`Write-Host`) isn't logged. | low |
| G13 | Sparse images: mounting a sparse VHD fails. Not true today, but unguarded. | low |
| G14 | Guide: `rdis.py find '"'` breaks in PS 5.1; the note about running it from another folder is wrong; VSS `Copy-Item` from GLOBALROOT fails; there's no execution-policy note. | low |

## 3. New design (rewrite of `Resize-RamDiskImage.ps1`)

**Principle: the original image is never modified.** All work happens on a new file `<image>.resize-work`.
The original is replaced only after every check passes, in one `ReplaceFile` call that keeps the original
as `<image>.pre-resize.bak`. The image path is never left missing. The registry changes last and is
verified. Every step is journaled to `<image>.resize-state.json`.

Phases (`-FailAt <phase>` injects a failure after any of them, for testing):

1. **Preflight**: elevated. Config key readable, old `SizeIn4kPages` == `Active` == image pages (for the configured image).
   Configured drive (R:) absent. The GUI (`AMD_RAMDisk`, `RAMDisk`) and `rdc`/`rdcq` aren't running. The image isn't dirty
   (no override for the configured image). The image isn't sparse/compressed/encrypted. No leftover work/state/bak
   files from a previous run. Free space â‰¥ new size + 1 GiB. Start a transcript to `logs\`.
2. **Lock + copy**: open the original with `FileShare.Read` and **hold it for the whole run**, so no one,
   including the driver, can write to it. Copy to the work file while hashing the source (SHA-256), flush to disk,
   then re-read the work file and compare hashes. Validate the layout, and require the UsedMap to cover every
   non-zero page.
3. **Prepare**: drop the RAMDisk footer from the work file, extend it with zeros, write a **random temporary disk signature**
   (unique among all disks and â‰  original), and append a fixed-VHD footer.
4. **Mount**: mount the work file (`-NoDriveLetter`), wait for the disk, bring it online/RW. Remove any drive letter that gets assigned.
   Locate the partition by offset. Because of the temporary signature, the live run and the tests take **identical** steps (fixes G2).
5. **Check before**: `Repair-Volume -Scan` must report `NoErrorsFound`. Build manifest A: every file and folder
   with size + SHA-256, via the volume GUID path.
6. **Grow**: `Resize-Partition` to `SizeMax`. Confirm the partition and volume reached the expected size.
7. **Check after**: `Repair-Volume -Scan` â†’ `NoErrorsFound`. Build manifest B. **Require A == B** (ignoring
   `System Volume Information`). Save B as `<image>.resize-manifest.tsv`.
8. **Dismount**: dismount and wait until it's detached.
9. **Finalize**: strip the VHD footer and restore the original signature. The MBR must equal the original except for the partition-1 sector count (Windows rewrites the CHS fields; the driver's values are restored).
   Rebuild the UsedMap (old bits + all non-zero pages) and write the header (only the length changes). Flush.
10. **Verify**: re-read and validate the layout. 0 unmarked non-zero pages. Header seq/flags/instance unchanged. Signature
    restored. Partition and NTFS fill the disk.
11. **Swap**: re-check that R: is absent and the GUI isn't running. Release the lock. Confirm the original's length and LastWriteTime didn't change since step 2.
    Run `File.Replace(work, image, bak)`, then confirm the new image and the bak both exist with the expected lengths.
12. **Registry**: re-read the old values, write both, read back. On any failure, restore both values and swap the files back.
13. **Done**: print next steps and the `-PostCheck` command.

New modes:
- `-Rollback`: R: must be absent. Using the state file, puts the `.pre-resize.bak` back in place
  (`File.Replace(bak, image, image.resized-rejected)`; nothing is deleted) and restores `SizeIn4kPages`
  in both keys.
- `-PostCheck`: run after starting the RAMDisk. Checks that Active == Parameters == new size,
  the event log since the run (load succeeded, no "Incorrect imageâ€¦"/"cannot load"), the R: volume size, and that R:
  contents match the manifest.
- `-ConfigKey <path>`: point every registry read/write at a **test** key (e.g. under HKCU). Tests then
  exercise the full "configured image" path, registry included, without touching the real key (fixes G6/G11).
- `-VerifyOnly` stays as it is (read-only).

Removed: `-NoBackup` (the original always survives). `-Force` only applies to images that aren't configured (VSS copies).

## 4. Tests (run on copies only, never the live image)

| Test | What it proves |
|---|---|
| T1 VerifyOnly on the backup | layout parser, UsedMap claim |
| T2 Full run on a copy, through a **test config key** (pretend-live: registry, R:-absent and GUI checks, swap all exercised) | the happy path end to end |
| T3 Independent check: mount the result read-only, chkdsk, compare the manifest | the tool's own checks aren't fooling themselves |
| T4 Failure injection at every phase (`-FailAt`) | after each failure: original byte-identical (hash), no work file left, mounts gone, registry unchanged (or reverted) |
| T5 `-Rollback` after a successful T2 | restores the original bytes and registry |
| T6 Refusals: dirty image, GUI running (simulated), drive letter present, leftover state, bad size | guard rails fire |

## 5. Deliverables

1. `Resize-RamDiskImage.ps1` rewritten as in Â§3.
2. `tools\rdis.py`: add a `strings` mode, and a `refs <hex>` mode for field offsets.
3. `Test-ResizeTool.ps1`: automates T1, T2, T4, T5, T6 on copies and prints PASS/FAIL per case.
4. `REVIEW-GUIDE.md` updated: new facts, new design, fixed commands (VSS copy, rdis, execution policy, transcript),
   the test script, and the real-run runbook (Â§6).
5. Run the test suite here and record the results in `TEST-RESULTS.md`.

## 6. Real-run runbook (for later; the user decides when)

1. Set user `TEMP`/`TMP` to `%LOCALAPPDATA%\Temp`, then sign out/in, so nothing uses R:.
2. Close browsers. Close the AMD RAMDisk GUI after using it to **Stop** the disk.
3. `powershell -ExecutionPolicy Bypass -File D:\Claude\ramdisk\Resize-RamDiskImage.ps1 -VerifyOnly -ImagePath G:\RAMDisk.img`
   â†’ expect "dirty=False", UsedMap OK.
4. `... -File Resize-RamDiskImage.ps1 -NewSizeGB 8`. It either finishes "Done" or leaves everything as it was.
5. Start the RAMDisk (from the GUI, opened **fresh**, without changing any settings), then immediately run `... -PostCheck`.
6. If PostCheck fails: Stop the RAMDisk, run `... -Rollback`, start it again â†’ back to 6 GiB with the original contents.
7. Restore `TEMP`/`TMP` to `R:\Temp`, then sign out/in. Keep `G:\RAMDisk.img.pre-resize.bak` for a few days.

Note: if the machine reboots mid-run, the original image is still at `G:\RAMDisk.img` and the registry is
unchanged, so it boots as before. Delete the leftover `*.resize-work*`/state files, or rerun.

## 7. Status (2026-10-16)

All deliverables in §5 are done. Test suite: **25/25 pass** (`TEST-RESULTS.md`). One bug was found and fixed in testing: Windows rewrites
the partition entry's CHS bytes; Finalize now restores the driver's values. Remaining: an independent review (`REVIEW-GUIDE.md`),
then the real run (§6) when the user chooses.
