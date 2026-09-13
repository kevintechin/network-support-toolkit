# Backlog #50 — five minimal batch files for the machine that produced the failure

On `DESKTOP-CO7QIMR` (Windows 10 22H2, zh-TW display) the zh-TW console launcher ended a **successful** run with
`'◆ 代碼:0' is not recognized as an internal or external command` after the completion sentence, from the line
`echo 結束代碼：0`. The reference machine (Windows 11 26200) prints the same bytes correctly. The item's first work
is a measurement, not a change: the failure reproduced with a minimal file, then one variable moved at a time.

| File | The one variable |
|---|---|
| `1-as-shipped.cmd` | The two lines exactly as the launcher ships them, under the same `chcp 65001` |
| `2-last-line-ascii.cmd` | The last line in ASCII (`echo Exit code: 0`), as the en-US launcher has it |
| `3-without-chcp.cmd` | No `chcp` line: the console stays on the machine's own code page |
| `4-with-bom.cmd` | The same as 1 with a UTF-8 byte-order mark at the head of the file |
| `5-halfwidth-colon.cmd` | The full-width colon replaced by an ASCII one (`echo 結束代碼:0`) |

All five are UTF-8 (4 with a BOM), CRLF, and end with `pause`, so a double-clicked window stays open.

**On that machine, both halves:**

1. Copy this folder to the machine (a local folder, not a share) and **double-click each `.cmd`** in turn. For each,
   photograph or screenshot the window before pressing a key: which of the five print the error line, and which print
   the two Chinese lines clean. The screen is the evidence the item was raised on.
2. Run `run-all.cmd`. It runs the five with their output captured into `1-as-shipped.log` … `5-halfwidth-colon.log`
   beside the files and writes the machine's `ver` and code pages (`ACP`, `OEMCP`, the console's own `CodePage` value
   if set) into `machine.txt`. A redirected run may not take the path the console does, which is why step 1 is not
   replaced by this one.
3. Send the folder back — the logs, `machine.txt`, and the five screen captures — and say which console host the
   double-clicked windows opened in (the classic console, or Windows Terminal).

The fix is chosen from what carries the failure; three candidates are in the item's body in `docs/backlog.md`.
