# Walking the user manual on a machine

The end-user manual ships inside the package, so it makes claims a person can check by doing what it says. This checklist is that walk: one row per claim the manual makes about what happens on the screen, in the folder or in the report, with the manual's own words in the **Expected** column so that a mismatch is a finding rather than an impression.

It asks two questions at once:

1. **Is it true?** Does the machine do what the sentence says, in the words the sentence uses?
2. **Is it usable?** Could the person do what the section told them to do without asking anybody? The last part of this document collects that; a manual can be true and still leave somebody stuck.

**What this walk is not.** It is not the tool's acceptance — that is [`package-acceptance-checklist.md`](package-acceptance-checklist.md), and it was run for 1.2.3 on two machines. For 1.2.4 each script differs from 1.2.3 by one line, its version string, so the tool's behaviour is not what is being measured here; the documents are.

---

## The machine and the package

| | |
|---|---|
| Machine | `win11-enUS` (record the facts with `tests\environment_probe.ps1` and keep its output) |
| Manual | `en-US\NetworkHealthCheck_User_Manual_en-US.html` — read the HTML page, because that is the one a person opens |
| Package | The **released** asset, downloaded **with the browser of this machine** from the releases page, so that the Mark of the Web is real and steps 2 and 3 of the manual mean something. A ZIP copied from the host carries no mark, so the Unblock box of W1 and the security prompt of W5 cannot appear and both are recorded as *not produced*; every other row, the ZIP-window trap of W3 and W4 included, is unaffected |
| Digest | Check the ZIP against the digest in the release notes before extracting anything |

**The automated floor first.** Before walking, prove the package is intact, so that a surprise during the walk is a document defect and not a broken download:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-PackageAcceptance.ps1 -Zip "%USERPROFILE%\Downloads\NetworkHealthCheck-1.2.4.zip" -ExpectedSha256 <digest from the release notes> -Label win11-enUS-1.2.4-manual-walk
```

That checks the digest, extracts, verifies the package against its own `SHA256SUMS.txt` and the CRLF rule, records the machine, and runs the chain steps that need Windows PowerShell alone. Then extract a **second, clean copy** the way section 2 of the manual says to, and walk that one — the walk has to follow the manual's own instructions, not the runner's.

**Two things already known, so they are not new findings.** The row that says the window closes over a console-mode fallback is [backlog #34](../docs/backlog.md); the manual routes around it. *Everything passed* being printed whenever every required check passed is [backlog #35](../docs/backlog.md); section 4 already tells the reader to read the Information rows. Record them as *known* if you meet them.

---

## Section 2 · Before you start

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W1 | Right-click the downloaded ZIP → **Properties** | An **Unblock** box at the bottom. ("If there is no Unblock box, there is nothing to unblock" — record which case this was) | | screenshot |
| W2 | Right-click the ZIP → **Extract All…** | Windows proposes a folder named after the ZIP | | screenshot |
| W3 | Double-click the ZIP (do **not** extract), double-click `Start-English.cmd` inside the ZIP window | The black window says `ERROR: en-US package is missing` and waits for a key | | the window's text |
| W4 | In the same ZIP window, open `en-US\` and double-click `Start-NetworkCheck.cmd` | The black window says `The program file NetworkHealthCheck.ps1 is missing`, and names `LauncherError.txt` | | the window's text, the file |

---

## Section 3 · Running the check

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W5 | From the properly extracted folder, double-click `Start-English.cmd` | If the ZIP was not unblocked: **Open File - Security Warning** → **Run**. Record whether the question appeared | | screenshot |
| W6 | Watch what opens first | A black text window opens first and stays in the background | | |
| W7 | Read the window's title bar | **Network Health Check Tool 1.2.4** — the version in the title is this release's | | screenshot |
| W8 | Time the start | The window **starts by itself within a second** — no button is pressed | | |
| W9 | While it runs, read the four things the manual's table names | **Result: Test in progress**; the line above the progress bar names the step; **the log shows one line per step and per finding, in the order they happen**; **Start Test** greyed out; **Open Report**, **Open Report Folder**, **Open JSON** switched off; **Close** does nothing | | screenshot |
| W10 | Watch the last few seconds | The line reads *Sampling TCP retransmissions, approximately N second(s) remaining* and the number falls | | screenshot |
| W11 | Time the whole run on a working network | "About ten seconds… with the settings as shipped" — write the measured time | | |
| W12 | When it finishes, read four places | The line reads **Test Complete**; the Result line shows the verdict in colour; the last log line reads *Report generated: …*; the same path appears under the buttons as *Report: …*; **Start Test** now reads **Run Again** | | screenshot |
| W13 | Click **Open Report** | The report opens in the browser, as a file on this computer (a `file:///…` address, not a web page) | | screenshot of the address bar |
| W14 | Click **Run Again**, let it finish | A new check runs in the same window; a new set of report files appears with its own time in the name; the earlier ones are still there | | the folder listing |

---

## Section 4 · Reading the result

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W15 | Read the verdict in the window and at the top of the report | One of **Overall Healthy**, **Attention Required**, **Problem Detected**, **Test Incomplete**, and the tool's own description of it matches the manual's *The tool's description* column word for word | | the report |
| W16 | Read **What to tell IT** | A title and **two to four lines**; the title is one of the nine in the manual's table and its text matches; **the last line names the file to send and what it contains** | | the report |
| W17 | Read **Computer and Run Information** | Computer name, user, operating system, tool version, and where the configuration file and the reports are | | the report |
| W18 | Read a **ping result** row of **Test Results** — a row the manual's own example names, so that it has measurements to show | Time, category, the check's name, a badge, a description; **Show Details** opens the measurements behind it (the individual ping replies), and this row carries the method and the command that repeats it by hand. Rows without measurements — the configuration-file row, the computer row — have no **Show Details** control and need not carry either: that is not a finding, and the manual says "where a row carries them" | | the report |
| W19 | Click **Expand all**, then **Collapse all** | Every detail block opens and closes at once | | |
| W20 | Compare the badges you can see with the manual's five | Pass, Warning, Fail, Unable to Check, Information — no badge on screen is missing from the table | | the report |
| W21 | Scroll to **IT diagnostics** | Collapsed at the bottom; Wi-Fi radio, routes, gateway hardware address, proxy, traceroute first hops, drivers; none of these rows changed the verdict | | the report |
| W22 | Add up the six counters under the verdict | Pass + Warning + Fail + Unable to Check + Information = **Total**, and Total is the number of rows in Test Results | | the numbers |
| W23 | Click **Open JSON** | The JSON file opens in Notepad | | |
| W24 | Open **both** the TXT and the JSON beside the HTML and compare them with the report | "The **TXT** and **JSON** files written beside the HTML carry the same findings" — every row of Test Results is in each of the three, with the same result; a finding present in one and missing from another is the defect this row looks for | | the three files |

---

## Section 5 · Sending the report to IT

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W25 | Click **Open Report Folder** | It opens `en-US\Reports`, holding three files per run named `NetworkHealthCheck_<date>_<time>_<COMPUTERNAME>.html` / `.txt` / `.json` | | the folder listing |
| W26 | Compare the path under the buttons with the folder that opened | "The path under the buttons is always the one that was actually used" | | |
| W27 | Read the manual's *What the report contains* paragraph against a real report | Every family it names is in the report, and the report holds no family the paragraph does not name — this is the privacy inventory, and it is the paragraph most worth walking row by row | | the report + the JSON |

---

## Section 6 · If something does not work

Produce at least the first row; the rest are recorded as *produced* or *not produced on this machine*.

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W28 | Rename `en-US\NetworkHealthCheck.ps1` to `NetworkHealthCheck.ps1.bak`, double-click `en-US\Start-NetworkCheck.cmd`, then rename it back | The window says **ERROR: The program file NetworkHealthCheck.ps1 is missing**; `LauncherError.txt` appears beside the launcher with the time, the computer, the user, the reason, and a **Suggested action** line that fits the reason (extract the complete ZIP) | | the file |
| W29 | Open the `LauncherError.txt` from W28 and read it against the manual's description of it | The file holds what the manual says it holds: the time, the computer, the user, the reason, the folder and the program's path (it was written beside the launcher), and a **Suggested action** line that fits the reason. The file does **not** say which file to send — that instruction is the manual's, in the same section-6 row — so check the two separately: the action from the file, the send from the manual | | the file |
| W30 | (Optional) If a console-mode fallback can be produced | The manual sends the person to the `Reports` folder and to `Start-NetworkCheck-Console.cmd` for a run whose text should stay on screen — **known: backlog #34** | | |
| W31 | Run `en-US\Start-NetworkCheck-Console.cmd` | Text-mode run, reports written, the window pauses at the end with the report paths above it | | the window's text |

---

## Section 7 · The IT entry

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W32 | Double-click `en-US\Start-NetworkCheck-IT.cmd` | A **Run options (IT)** panel at the top; it does **not** start by itself; the line above the progress bar reads *Ready - adjust the options, then select Start Test* | | screenshot |
| W33 | Type an address into **Extra ping**, click **Start Test**, open the report | The run uses it, and in the report **every detail is already expanded** | | the report |
| W34 | Click **Reset to config** | The panel returns to the configured values | | |
| W35 | Open the configuration file afterwards | It is unchanged — "whatever is typed there applies to that run only" | | |

---

## Section 8 · The files in the package

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W36 | Walk the manual's file table against the extracted folder, row by row | Every file and folder the table names exists | | the folder listing |
| W37 | Walk the folder against the table, the other way — on a **pristine extraction**, not on the copy this walk has been running from | Nothing in the package is missing from the table. **This is where 1.2.4 changes**: the two manuals are listed and present, and `README_en-US.txt` / `README_zh-TW.txt` are named nowhere and present nowhere. What the walk itself created is not part of the package and is not a finding: `en-US\Reports\` and its report files (the table lists the folder), and `en-US\LauncherError.txt` from W28 — which is why this row wants a folder that has not been run from | | the folder listing |

---

## Section 9 · Questions people ask

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W38 | Read *Which addresses does it contact?* against the report's rows | The gateway, `1.1.1.1` (ping, port 443, the first three hops of the traceroute) and `https://www.microsoft.com/` (one page request, following any redirect), plus the name lookup for `www.microsoft.com` — and the report's rows name the targets that were actually configured | | the report |
| W39 | Read *Do I need to be an administrator?* against this run | The run was made without elevation, and anything that needed more rights is an *Unable to Check* row, with the check continuing | | the report |
| W40 | (If a VPN is available) Connect it and run again | Both the physical and the VPN adapter appear, and the VPN one is **normally** marked *Virtual* and listed as information — record how this VPN's adapter was actually classified. The classification is a heuristic (`Test-IsVirtualAdapter` reads the virtual flag, else the hardware flag, else the description), so a VPN adapter that reports itself as hardware can appear as Physical, which is what the manual's "normally" allows; only a classification the manual does not allow is a finding. A disconnected VPN adapter, or one with no address, does not appear at all | | the report |
| W41 | Delete an old report | It deletes like an ordinary file | | |

---

## Was it usable?

The part no assertion can measure. Answer in your own words, and be specific about where you hesitated — a sentence that is true but sends the reader to the wrong place is a defect this walk exists to find.

1. Did you ever have to ask somebody, or guess, to get past a step? Which step?
2. Was anything on the screen that the manual does not explain, and that you wanted explained?
3. Was anything explained at length that you did not need?
4. After the run, did you know **which file to send and where to find it** without re-reading?
5. If the tool had failed, would section 6 have told you what to do?
6. Did any sentence turn out to be true but useless — right about the machine, wrong about the situation?

---

## What to do with a finding

- **The manual is wrong or misleading** — a fix to the four manual files (two languages × markdown and HTML, since every claim lives in all of them), on a branch, through a pull request and the review loop. A shipped document carries the package's version, so a manual fix after this release ships as **1.2.5**.
- **The tool is wrong** — a backlog item in [`docs/backlog.md`](../docs/backlog.md), with an acceptance sentence; the manual is not edited to describe a defect as if it were a design.
- **Neither, but it slowed you down** — say so in *Was it usable?*. That is the half of this walk the automated document checks cannot reach: `tests/doc_facts.ps1` compares identifiers, not reasoning.

**The record.** The walk goes into `healthcheck/VALIDATION.md` as its own entry: the machine, the asset and its digest, which rows were produced and which were not, what matched, what did not, and every finding with what it became.
