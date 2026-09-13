# Backlog #50 — five minimal batch files, and what they measured

On `DESKTOP-CO7QIMR` (Windows 10 22H2, zh-TW display) the zh-TW console launcher ended a **successful** run with
`'◆ 代碼:0' is not recognized as an internal or external command` after the completion sentence, from the line
`echo 結束代碼：0`. The item's first work is a measurement, not a change: the failure reproduced with a minimal
file, then one variable moved at a time.

**It reproduced on the reference machine**, which the item had recorded as printing the same bytes correctly — see
the results below. That sentence was true of the failing line *by itself*; it is false of the file that also carries
the line above it, and this folder is what established the difference.

| File | The one variable |
|---|---|
| `1-as-shipped.cmd` | The two lines exactly as the launcher ships them, under the same `chcp 65001` |
| `2-last-line-ascii.cmd` | The last line in ASCII (`echo Exit code: 0`), as the en-US launcher has it |
| `3-without-chcp.cmd` | No `chcp` line: the console stays on the machine's own code page |
| `4-with-bom.cmd` | The same as 1 with a UTF-8 byte-order mark at the head of the file |
| `5-halfwidth-colon.cmd` | The full-width colon replaced by an ASCII one (`echo 結束代碼:0`) |

All five are UTF-8 (4 with a BOM), CRLF, and end with `pause`, so a window stays open until a key is pressed.

## Running it on that machine

1. Copy this folder to the machine, into a local folder — not a network share, not the compressed-folder view of a
   ZIP, and not a folder a cloud client syncs. If the machine's Desktop is one (Windows 11 backs it up to OneDrive
   by default) the script refuses rather than uploading the pictures, and `-OutDir C:\NHC-50` puts the results
   somewhere else without moving the probe.
2. Log in at the machine's desktop, or connect the RDP session and leave it connected, and leave the screen unlocked.
   The script photographs windows, and refuses a session whose pictures would come out black.
3. Open a PowerShell window in the folder and run:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File .\run-all.ps1
   ```

   Leave the keyboard and the mouse alone while the five windows open and close; it took 18 s on the reference
   machine.
4. Send the whole folder back, `results_<computer>_<stamp>\` included.

## What `run-all.ps1` does, and why each run gets a console of its own

Every variant is run twice, each time in a new console:

- **As a double-click.** The `.cmd` is handed to the shell with its folder as the working directory, which is what
  Explorer does and yields the same command line (`cmd.exe /c ""<file>" "`, recorded in `run-all.txt` as it was
  actually run). The window is left at its `pause`, photographed — its own rectangle where the started process owns
  a window, the terminal window where another process hosts it, the whole primary screen failing both — and only
  then closed. The picture is
  the evidence the item was raised on; the bytes below say what the picture was made of. A double-click by hand of
  `1-as-shipped.cmd`, compared against `1-as-shipped.png`, is how anyone checks that the two are the same run.
- **Redirected.** `cmd.exe /c` in a new console, standard output and standard error into `<variant>.log` and
  `<variant>-stderr.log` (the latter kept only when something was printed there), an empty standard input so that
  `pause` ends by itself. The bytes are kept as written, with a hex dump and two readings — as UTF-8 and as the
  machine's OEM code page — in the manifest, because the variants print under different code pages and one decoding
  would hide what is measured.

`chcp` changes the console, not the process. The runner this one replaces ran the five through `call` in one window,
so variants 2 to 5 inherited the `chcp 65001` of variant 1: variant 3 never saw the machine's own code page, and 2,
4 and 5 never made the change that 1 makes. Measured on the reference machine on 2026-09-13: after a `call` of a
file with `chcp 65001`, a `call`ed file without one reports 65001, a child `cmd /c` reports 65001, and only a new
console reports the machine's 950.

`machine.txt` records the build (`ver` and the registry), the file versions of `cmd.exe` and `conhost.exe`, `ACP` and
`OEMCP`, the console's own `CodePage` value if one is set (`HKCU\Console` and any per-title key), **the code page a
new console actually starts at** — measured by running `cmd /c chcp` in one, because `HKCU\Console\CodePage` or a
per-title key can put it somewhere other than `OEMCP`, and that number is what the `3-without-chcp` variant prints
under — the default console host on builds that can delegate one (`HKCU\Console\%%Startup`), the locales and the
screen. The host that actually
opened each window is in the manifest, read from the window's class: `ConsoleWindowClass` is the classic console,
`CASCADIA_HOSTING_WINDOW_CLASS` is Windows Terminal.

## What the reference machine measured, 2026-09-13

`LULALAT14`, Windows 11 build 26200.9445, `ACP` and `OEMCP` both 950, the double-clicks hosted by Windows Terminal.
Each variant is the same on the screen and in the redirected stream.

| Variant | Result |
|---|---|
| `1-as-shipped` | **fails** — `'<U+FFFD>代碼：0' is not recognized…`, the message the item was raised on |
| `2-last-line-ascii` | clean |
| `3-without-chcp` | **fails**, and the completion sentence comes out as mojibake as well |
| `4-with-bom` | **fails worse** — the byte-order mark and `@echo` go to cmd as one command name, so the file runs with echo on |
| `5-halfwidth-colon` | **fails** — `'束代碼:0'`, so the full-width colon is not the carrier |

It is deterministic, not intermittent: 25 runs each, the shipped bytes failed 25 and the ASCII last line failed 0.

**What carries it is the line above, not the line named in the item.** The failing line alone is clean. It fails
only when a line with non-ASCII characters stands immediately above it — a `rem` comment does it too, so this is
about reading the file and not about executing the line — and an ASCII line or a blank line between the two clears
it. Not length: `echo 網路健康檢查已完成。` and `echo 網網網網網網網網網網` are both 35 bytes and both 10 characters,
and the first fails while the second is clean. Of ten line-final characters tried, three carry it — `。` U+3002,
`、` U+3001, `」` U+300D — and `，` `！` `？` `：` `）`, a plain han character and an ASCII full stop do not. The
three that carry it are the three whose UTF-8 second byte is `0x80`, which is not a lead byte in code page 950
(`GetCPInfoEx` reports one range on this machine, `0x81`-`0xFE`).
The line that follows matters too: all ten were clean when it was `echo Exit code: 0`.

**The shipped launcher prints six such lines, not one.** Measured by running
`healthcheck/zh-TW/Start-NetworkCheck-Console.cmd` itself with both streams captured: a successful run put 775
bytes on standard error, six `is not recognized` pairs, from lines 26, 27, 41, 63, 65 and 103 of the 188. Five
are Chinese `rem` comments in the first third of the file and have scrolled off by the time the run ends, which is
why the walk recorded the sixth and only the sixth. A copy with its last line in ASCII loses the sixth message
and keeps the five.

The fix is chosen from what carries the failure; the candidates and the two changes measured clean are in the
item's body in `docs/backlog.md`. **The trip to `DESKTOP-CO7QIMR` is still worth making**, with a changed question:
whether that machine also prints six on a successful run, and whether the chosen change is clean there as well as
here. The code page (950 on both) and the console host have not been varied, and no machine whose `ACP` is not 950
has been measured.
