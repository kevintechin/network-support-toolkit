# Walking the user manual on a machine

The end-user manual ships inside the package, so it makes claims a person can check by doing what it says. This checklist is that walk: one row per claim the manual makes about what happens on the screen, in the folder or in the report, with the manual's own words in the **Expected** column so that a mismatch is a finding rather than an impression.

It asks two questions at once:

1. **Is it true?** Does the machine do what the sentence says, in the words the sentence uses?
2. **Is it usable?** Could the person do what the section told them to do without asking anybody? The last part of this document collects that; a manual can be true and still leave somebody stuck.

**How the numbering runs.** Rows are numbered in the order they were added to this sheet, not the order they are walked. Walk the sections in order; the numbers are names, so that a finding can cite one and keep citing it.

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

## Section 1 · What the tool is

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W53 | Read section 1's list of what the tool looks at against the report you produced | Every one has its rows: which adapters are connected and their addresses, whether the default gateway answers, whether names can be looked up, whether known services can be reached, and whether the connection loses packets or retransmits | | the report |
| W54 | Before the run, save `ipconfig /all`, `route print`, `netsh winhttp show proxy`, `reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"` (the proxy a user's applications use, which is not the WinHTTP one), `netsh advfirewall show allprofiles` and `Get-NetAdapter | Format-List Name,Status,AdminStatus`; after the run take them again and compare | "**It changes nothing.**" — nothing differs in any of them: no IP address, DNS server, route, either proxy, firewall profile or adapter state. "It installs nothing": no new entry under Programs and Features, and the package folder gained only its `Reports` folder and the report files. Any difference is a finding of the first order | | the two sets of output |
| W55 | Time a run where things do not answer: from the IT entry, add an unreachable **Extra ping** and an unreachable **Extra URL**, then Start Test | "up to a minute or so with those settings" — the run is longer than W11's and within what the manual promises; write the measured time. If IT changed the sample length or the time limits, the manual says it takes correspondingly longer | | |
| W56 | After a run, look at what left the computer | "**It uploads nothing.**" What this walk can check is that the report exists only in the report folder and that the tool sent nothing of its own — the wire itself is out of scope here (a capture would be the proof), so record this row as checked at the file level and say so | | the folder |

---

## Section 2 · Before you start

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W1 | Right-click the downloaded ZIP → **Properties**, and **leave it blocked for now** | An **Unblock** box at the bottom. ("If there is no Unblock box, there is nothing to unblock" — record which case this was) | | screenshot |
| W2 | Right-click the ZIP → **Extract All…** | Windows proposes a folder named after the ZIP | | screenshot |
| W3 | Double-click the ZIP (do **not** extract), double-click `Start-English.cmd` inside the ZIP window | The black window says `ERROR: en-US package is missing` and waits for a key | | the window's text |
| W4 | In the same ZIP window, open `en-US\` and double-click `Start-NetworkCheck.cmd` | The black window says `The program file NetworkHealthCheck.ps1 is missing`, and names `LauncherError.txt` | | the window's text, the file |

---

## Section 3 · Running the check

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W5 | Extract the **still-blocked** ZIP and double-click `Start-English.cmd` from that folder | **Open File - Security Warning** appears — the manual says this is the download mark and the tool is the same either way; choose **Run** | | screenshot |
| W5b | Now tick **Unblock** on the ZIP, extract it again into a new folder, and double-click `Start-English.cmd` there | **No security question at all** — this is the claim of section 2 step 2, "unblocking the ZIP before extracting removes that question", and it is only tested by doing both halves | | screenshot |
| W6 | Watch what opens first | A black text window opens first and stays in the background | | |
| W7 | Read the window's title bar | **Network Health Check Tool 1.2.4** — the version in the title is this release's | | screenshot |
| W8 | Time the start | The window **starts by itself within a second** — no button is pressed | | |
| W9b | When it has finished, count the log lines shaped `[status] Category / Check: message` against the report | They match one for one: the main table's rows plus the *IT diagnostics (N items)* count, because `Add-CheckResult` writes the row and the log line in one call. The only log lines that are not rows are the run's narration — `Starting: …`, the opening line, and the report-writing lines, which cannot be in a report that is already written. **This checks the log's promise in section 3, not the format parity of W24**, and it is only possible while the window is still open | | the window, the report |
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

**Each verdict and each guidance title on its own line.** W15 and W16 check the one this run produced; the other twelve stay unchecked unless they are recorded. Produce what the machine allows — the campaign's scenarios in `package-acceptance-checklist.md` produce several, and its evidence can be cited instead of producing them again — and record the rest as *not produced*, so that a wrong description for a branch nobody reached is visible as untested rather than invisible.

| # | Branch | How it can be produced here | Observed | Evidence |
|---|---|---|---|---|
| W61 | Verdict **Overall Healthy** | the ordinary run of W12 | | |
| W62 | Verdict **Attention Required** | the unwritable report folder of W46, or a run with loss or latency over the thresholds | | |
| W63 | Verdict **Problem Detected** | the campaign's `A4` (adapter disconnected) or `A3` (host-only, no gateway) | | |
| W64 | Verdict **Test Incomplete** | W51, when it happens | | |
| W65 | *Everything passed* | the ordinary run | | |
| W66 | *Local link problem* | `A4`, the adapter disconnected | | |
| W67 | *Gateway does not answer* | a gateway that does not reply to pings — not producible on every network | | |
| W68 | *Gateway answers, internet does not* | `A3`, or a machine whose gateway answers with no route beyond | | |
| W69 | *Name resolution fails* | point the adapter at an unreachable DNS server, run, then restore | | |
| W70 | *Connected, but quality is poor* | packet loss, latency, retransmissions or adapter errors over the thresholds — **an idle machine reaches this branch through loss or latency whenever the link is congested or faulty**, and needs no help to do it. What an idle machine cannot produce is the **retransmission** route: the tool samples system-wide TCP counters for a few seconds and a quiet desktop sends a handful of segments, so the run lands in the small-sample rows instead. For that route only, make traffic during the sampling seconds — a large download or a file copy when the progress line reads *Sampling TCP retransmissions*. Record *not produced* if the link stays clean | | |
| W71 | *A required check failed* | any required check failing, as in `A3` / `A4` | | |
| W72 | *Some checks could not run* | an *Unable to Check* row with no failure — record *not produced* if none appeared | | |
| W73 | *Warnings to review* | a warning with no failure, as in W46 | | |

For each: the title and its lines match the manual's table word for word, and the last line names the file to send.
| W17 | Read **Computer and Run Information** | Computer name, user, operating system, tool version, and where the configuration file and the reports are | | the report |
| W18 | Read a **ping result** row of **Test Results** — a row the manual's own example names, so that it has measurements to show | Time, category, the check's name, a badge, a description; **Show Details** opens the measurements behind it (the individual ping replies), and this row carries the method and the command that repeats it by hand. Rows without measurements — the configuration-file row, the computer row — have no **Show Details** control and need not carry either: that is not a finding, and the manual says "where a row carries them" | | the report |
| W19 | Click **Expand all**, then **Collapse all** | Every detail block opens and closes at once | | |
| W20 | Compare the badges you can see with the manual's five | Pass, Warning, Fail, Unable to Check, Information — no badge on screen is missing from the table | | the report |
| W21 | Scroll to **IT diagnostics** | Collapsed at the bottom; Wi-Fi radio, routes, gateway hardware address, proxy, traceroute first hops, drivers; none of these rows changed the verdict | | the report |
| W22 | Add up the six counters under the verdict | Pass + Warning + Fail + Unable to Check + Information = **Total**, and Total is the number of rows in Test Results | | the numbers |
| W23 | Click **Open JSON** | The JSON file opens in Notepad | | |
| W24 | Open **both** the TXT and the JSON beside the HTML and compare them with the report | "The **TXT** and **JSON** files written beside the HTML carry the same findings" — every row of Test Results is in each of the three, with the same result; a finding present in one and missing from another is the defect this row looks for. **Compare the contents, not the counts** — equal numbers of rows prove nothing if one writer changed a status or a message | | the three files |

---

## Section 5 · Sending the report to IT

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W25 | Click **Open Report Folder** | It opens `en-US\Reports`, holding three files per run named `NetworkHealthCheck_<date>_<time>_<COMPUTERNAME>.html` / `.txt` / `.json` | | the folder listing |
| W26 | Compare the path under the buttons with the folder that opened | "The path under the buttons is always the one that was actually used" | | |
| W27 | Walk the manual's *What the report contains* paragraph against a real report **field by field, in both directions** — list every label in the TXT (the `Label:` lines and the row headings) and every key in the JSON, then match each against the paragraph | Every field the paragraph names is in the report (the BSSID, the driver date and maker, the error counters, the proxy settings, the routes, the profile name, the config and report paths…), **and** every field the report carries is covered by the paragraph. A field the report holds and the paragraph does not name is the finding that matters most here: it is the privacy inventory, and its two previous rebuilds each found fields nobody had listed | | the TXT, the JSON, the list |

---

## Section 6 · If something does not work

Produce at least the first row; the rest are recorded as *produced* or *not produced on this machine*.

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W28 | Rename `en-US\NetworkHealthCheck.ps1` to `NetworkHealthCheck.ps1.bak`, double-click `en-US\Start-NetworkCheck.cmd`, then rename it back | The window says **ERROR: The program file NetworkHealthCheck.ps1 is missing**; `LauncherError.txt` appears beside the launcher with the time, the computer, the user, the reason, and a **Suggested action** line that fits the reason (extract the complete ZIP) | | the file |
| W29 | Open the `LauncherError.txt` from W28 and read it against the manual's description of it | The file holds what the manual says it holds: the time, the computer, the user, the reason, the folder and the program's path (it was written beside the launcher), and a **Suggested action** line that fits the reason. The file does **not** say which file to send — that instruction is the manual's, in the same section-6 row — so check the two separately: the action from the file, the send from the manual | | the file |
| W30 | (Optional) If a console-mode fallback can be produced | The manual sends the person to the `Reports` folder and to `Start-NetworkCheck-Console.cmd` for a run whose text should stay on screen — **known: backlog #34** | | |
| W31 | Run `en-US\Start-NetworkCheck-Console.cmd` | Text-mode run, reports written, the window pauses at the end with the report paths above it | | the window's text |

**The rest of section 6.** Every remaining row of the manual's table gets a line here, so that each is either checked or recorded as *not produced on this machine* — a row nobody looked at is not the same as a row that holds. These carry on the sheet's numbering rather than renumbering the rows above. Where the campaign has already produced a state on this machine (`package-acceptance-checklist.md`, scenarios M7 and M8), cite its evidence instead of producing it again, and revert any machine change the way that checklist says.

| # | How to produce it | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W42 | **PowerShell not found** — not producible on a stock machine without breaking it; record *not produced* unless this machine genuinely lacks Windows PowerShell | `ERROR: PowerShell was not found on this computer`, and the manual sends the person to IT or to another computer | | |
| W43 | **Exit code 3** — the campaign's `M7`: `setx /M __PSLockdownPolicy 4` from an elevated prompt, a **new** session, double-click the launcher, then remove the variable | The window says the program ended with exit code 3, and `NetworkHealthCheck_ENVIRONMENT_<time>.txt` is beside the program or in the temporary folder, naming the computer, the user, the folder, the PowerShell version and language mode, the language settings and the operating system | | the file |
| W44 | **Another exit code** — the campaign's `M8`: a Group Policy execution policy of *Allow only signed scripts*, then revert | The window says the program ended with another exit code and that PowerShell or company security policy may have blocked it; PowerShell's own reason is printed above the error, and `LauncherError.txt` says to send both | | the window's text, the file |
| W45 | **The `%TEMP%` copy of the launcher's file** — in this order, which the launcher forces: rename `NetworkHealthCheck.ps1` away, **delete the `LauncherError.txt` W28 left**, then deny write on the `en-US` folder for this account, then double-click the launcher; restore the permission and the file afterwards. The order matters twice: the rename happens while the folder is still writable, and the launcher writes its file and then asks `if exist` — a stale error report would satisfy that check after the write failed, and the `%TEMP%` copy would never be written | The launcher writes `NetworkHealthCheck_LauncherError.txt` in the Windows temporary folder instead, and **the window prints the path** | | the file |
| W46 | **Report directory not writable** — deny write on `en-US\Reports`, run, then restore | A **Startup Notice** warning row: *"The original report directory is not writable. Reports will be saved to: …"*, the reports are in the folder it names, **Open Report Folder** opens that folder, and the notice contributes a warning — **on its own** it makes the verdict **Attention Required**, but a required check that failed in the same run gives **Problem Detected**, which is not a defect of the manual | | the report |
| W47 | **Running from inside a compressed folder** — needs an archiver that extracts the whole folder into its view; stock Windows stops earlier (W3, W4). Record *not produced* if no such archiver is installed | A **Startup Notice** warning row: *"This copy is running from inside a compressed folder…"*, **and the two claims beside it**: the reports went to a temporary place — find it, then close the archive view and check that it is gone — and the recovery works: extract the whole ZIP and run again, and the row is absent | | the report, the temporary path before and after |
| W48 | **Report generation failed** — do not manufacture it; record *not produced* unless it happens | A message box naming an emergency error report `NetworkHealthCheck_FATAL_<time>.txt`, which the manual says holds everything the check found before the failure; send that file | | |
| W49 | **N of 3 report formats could not be written** — same; *not produced* unless it happens | A message box naming the count, the one that was written is named in it, and **Open Report** opens it | | |
| W50 | **The test could not be completed** — same; *not produced* unless it happens | A message box naming an error report; send the file it names | | |
| W51 | **The verdict is Test Incomplete** — this one can happen on an ordinary run; record it when it does | The manual says to send the report as it is and that the reasons are in the rows marked *Unable to Check* — check that those rows are there and say why | | the report |
| W52 | **The black window flashes and closes** — PowerShell stopped before the tool could say anything. The campaign's `M9` (AppLocker enforced) is the scenario that would produce it, and it has never taken effect on any machine this project has measured ([backlog #31](../docs/backlog.md)), so record *not produced* unless it happens | Nothing is written — no report, no `LauncherError.txt`, no environment file — and the manual's advice is to tell IT what was seen, with a photo of the window if one can be caught. This is the case where the package leaves no evidence at all ([backlog #37](../docs/backlog.md)) | | |

---

## Section 7 · The IT entry

| # | Do this | Expected — the manual's words | Observed | Evidence |
|---|---|---|---|---|
| W32 | Double-click `en-US\Start-NetworkCheck-IT.cmd` | A **Run options (IT)** panel at the top; it does **not** start by itself; the line above the progress bar reads *Ready - adjust the options, then select Start Test* | | screenshot |
| W33 | Give **all six** controls the manual names a recognizable value — **Extra ping**, **Extra TCP (host:port)**, **Extra DNS**, **Extra URL**, **Ping count**, **Sample seconds** — then click **Start Test** and open the report | Every one of the six reached the run: the report's run information names the ping count, the sample length and the typed targets, and there is a row for each extra target. And in the report **every detail is already expanded** | | the report |
| W34 | Click **Reset to config** | **All six** controls return to the configured values, not only the one you changed last | | screenshot |
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
| W38 | Read *Which addresses does it contact?* against the report's rows — the targets **and** the three routing promises in the same answer | The gateway, `1.1.1.1` (ping, port 443, the first three hops of the traceroute) and `https://www.microsoft.com/`, plus the name lookup for `www.microsoft.com`, and the report's rows name the targets that were actually configured. Then the rest of the sentence: the report **names the address the request finally landed on** after any redirect — check that here. The other two halves of the sentence, that the page request goes through the proxy Windows is set to use and that the lookup goes through this computer's DNS servers, are claims about the path taken, and configuration rows do not prove a path: without a capture or a proxy or DNS server log this walk cannot settle them, so compare the configured values and record the two as **not verified at the wire level here**, the way W56 records "uploads nothing" | | the report |
| W39 | Read *Do I need to be an administrator?* against this run | The run was made without elevation, and anything that needed more rights is an *Unable to Check* row, with the check continuing | | the report |
| W40 | (If a VPN is available) Connect it and run again | Both the physical and the VPN adapter appear, and the VPN one is **normally** marked *Virtual* and listed as information — record how this VPN's adapter was actually classified. The classification is a heuristic (`Test-IsVirtualAdapter` reads the virtual flag, else the hardware flag, else the description), so a VPN adapter that reports itself as hardware can appear as Physical, which is what the manual's "normally" allows; only a classification the manual does not allow is a finding. A disconnected VPN adapter, or one with no address, does not appear at all | | the report |
| W41 | Delete an old report | It deletes like an ordinary file | | |
| W57 | Read *Is the report sent anywhere?* against the report's **Computer and Run Information** | "Not by the tool" — the section names the folder the report was actually written to, which is on this computer with the settings as shipped | | the report |
| W58 | Read the two TCP-counter answers against this run's rows | If the retransmission row says *Unable to Check*, the report itself says the counters could not be read and not that there were retransmissions; if the run was made on a quiet machine, the row about too little TCP traffic is information, not a fault. Produce the second by running while the machine is idle; record either as *not produced* if it did not appear | | the report |
| W59 | Run `Start-Traditional-Chinese.cmd` on this machine | "It is the same tool with the interface and the report in Traditional Chinese" — the window and the report are in Chinese, and the same checks appear | | the report |
| W60 | Read *Can I run it on another computer?* | "Yes, on any Windows 10 or Windows 11 computer", and **every report names the computer it was made on** — check the second half here; the first half needs the second machine, so record it as *not produced on this machine* (the zh-TW walk covers it) | | the report |

---

## Was it usable?

The part no assertion can measure. Answer in your own words, and be specific about where you hesitated — a sentence that is true but sends the reader to the wrong place is a defect this walk exists to find. Prose, not ticks: the two findings this section produced on its first outing came out of a sentence somebody wrote themselves, and a matrix would have collected a tick instead. **When a question here asks about a situation, name the situation** — the first version of question 5 asked “if the tool had failed”, which invites “but it didn't”; it was written by the same person who wrote the manual's claims, and it inherited the same blind spot.

1. Did you ever have to ask somebody, or guess, to get past a step? Which step?
2. Was anything on the screen that the manual does not explain, and that you wanted explained?
3. Was anything explained at length that you did not need?
4. After the run, did you know **which file to send and where to find it** without re-reading?
5. For each kind of failure you actually met: could you have put it right yourself, which file would you have sent, and whom would you have told? *Section 6 covers four kinds, and they ask different things of the person — answer for the ones you met and say “did not meet it” for the rest, which is data and not a gap.* **A**: the launcher stops before the tool runs (W28, W42–W44, W52). **B**: the tool runs but the window does not (W30). **C**: the report is written somewhere else, in fewer formats, or not at all — the fallback directory of W46, the surviving format of W49, the FATAL file of W48, the unrecoverable error of W50. **D**: the report is written and something in it could not be measured (W51).
6. Did any sentence turn out to be true but useless — right about the machine, wrong about the situation?

---

## What to do with a finding

- **The manual is wrong or misleading** — a fix to the four manual files (two languages × markdown and HTML, since every claim lives in all of them), on a branch, through a pull request and the review loop. A shipped document carries the package's version, so a manual fix after this release ships as **1.2.5**.
- **The tool is wrong** — a backlog item in [`docs/backlog.md`](../docs/backlog.md), with an acceptance sentence; the manual is not edited to describe a defect as if it were a design.
- **Neither, but it slowed you down** — say so in *Was it usable?*. That is the half of this walk the automated document checks cannot reach: `tests/doc_facts.ps1` compares identifiers, not reasoning.

**The record.** The walk goes into `healthcheck/VALIDATION.md` as its own entry: the machine, the asset and its digest, which rows were produced and which were not, what matched, what did not, and every finding with what it became.
