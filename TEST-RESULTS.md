# Test results: Resize-RamDiskImage.ps1 v2

**Run:** 2026-10-16, elevated Windows PowerShell 5.1, by the Claude session that wrote the tool. **Not independent.**
The reviewer should re-run it (`REVIEW-GUIDE.md` §3.1).
**Source:** `RAMDisk-Backup.img` (June 2025), copied and re-signed to `0x44332211`. Pretend-live through
`HKCU:\Software\RamDiskResizeTest\Parameters` with a fake DiskDrive `Q:\`.
**Result: 25 passed, 0 failed.** Per-run transcripts: `testrun\out\*.txt`. Machine-readable: `test-results.json`.

| Test | Result | Detail |
|---|---|---|
| T1 VerifyOnly on copy | PASS | |
| T6a live image refused while the RAMDisk runs (real config, no -ImagePath) | PASS | refused at "R:\ exists" before opening anything |
| T6b leftover state file refused (and not deleted) | PASS | |
| T6c configured drive present refused | PASS | |
| T6d GUI/console process running refused | PASS | renamed ping.exe as `rdcq.exe` |
| T6e registry/image size mismatch refused | PASS | |
| T6f dirty configured image refused even with -Force | PASS | |
| T6g new size not larger refused | PASS | |
| T4 failure injected after each of Copy, Prepare, Mount, CheckBefore, Grow, CheckAfter, Dismount, Finalize, Verify | PASS ×9 | original SHA-256 unchanged, no leftovers, nothing mounted, registry 1572864/1572864 |
| T4 failure after Swap / after Registry | PASS ×2 | swapped back, registry reverted, resized file kept as `.resized-rejected` |
| T2 resize 6 → 8 GiB | PASS | length 8,590,196,784. Registry 2097152/2097152. Bak == original hash. State "done". Manifest saved. |
| T2 VerifyOnly after resize | PASS | 8.00 GiB, seq/instance kept, signature restored, registry match |
| T2 second run refused while results are pending | PASS | |
| T3 independent read-only mount of the result | PASS | chkdsk exit 0, volume 8.00 GiB, 32,673 files, manifest identical |
| T5 rollback | PASS | original bytes (SHA-256) and registry restored |
| Live config untouched, R: present, source backup unchanged | PASS | |

Key numbers from T2: both file-system scans `NoErrorsFound`. 32,673 files (2.56 GiB) and 2,151 folders, 34,824 manifest
entries identical before and after (names, sizes, SHA-256). 21 extra non-zero pages marked in the UsedMap (new NTFS metadata).

## Bug found and fixed during testing

The first suite run failed the T4 Verify/Swap/Registry cases and T2. The new MBR check found that Windows rewrites the
partition entry's **CHS start** bytes (`01 01 00` → `00 21 00`) from the VHD geometry. That's harmless to LBA-based code, but
it's an unintended change. Finalize now restores the driver's own bytes 0x1B8–0x1C9 (signature + entry except the
sector count), and Verify allows **only** the 4-byte sector count to differ.

That failed run also served as an unplanned test: a real check failed late in the process, and the tool undid everything
(original hash identical, no leftovers, registry unchanged).
