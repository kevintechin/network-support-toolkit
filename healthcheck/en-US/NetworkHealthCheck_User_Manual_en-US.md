# Network Health Check 1.2.4 — User Manual

**For the person who runs the check.** One double-click, a window that runs by itself, and a report you send to IT.

This manual covers the English package (the `en-US` folder). The Traditional Chinese package in the `zh-TW` folder is the same tool with its own copy of this manual. IT staff will find the configuration notes in `README_en-US.txt` and the design, decision rules and validation record in the technical guide.

---

## 1 · What the tool is

Network Health Check looks at the network from this computer's point of view and writes down what it finds: which network adapters are connected, what addresses they have, whether the router (the *default gateway*) answers, whether names can be looked up, whether a few known services can be reached, and whether the connection is losing packets or retransmitting data. The result is a report with a one-line verdict and a short section called **What to tell IT**.

**It changes nothing.** The tool reads network information and runs connection tests — a few pings, a name lookup, a TCP connection and one HTTPS request. It does not modify your IP address, DNS, routes, firewall, proxy or adapter settings, and it installs nothing. Administrator rights are normally not required.

**It uploads nothing.** With the settings as shipped, the report is written to a folder on this computer and goes nowhere until you send it yourself; IT may have pointed the report folder elsewhere, and the report's *Computer and Run Information* section shows where it went. What the tests do send is traffic to the test targets — section 9 names the shipped ones — through this computer's own DNS servers, proxy and route.

**How long it takes.** About ten seconds on a working network. When things do not answer it takes longer — up to a minute or so — because every test waits for its time limit before giving up.

---

## 2 · Before you start

1. **Save the ZIP** IT sent you (or the one you downloaded from the link they gave) to your computer. Do not open it straight from the browser's download bar.
2. **Unblock it, if you can.** Right-click the ZIP → **Properties** → tick **Unblock** at the bottom → **OK**. Windows marks files downloaded from the internet and asks a security question before running them; unblocking the ZIP before extracting removes that question. If there is no Unblock box, there is nothing to unblock — carry on.
3. **Extract the whole ZIP.** Right-click it → **Extract All…** → **Extract**. Windows proposes a folder named after the ZIP; that is fine. Any local folder works — the Desktop or Documents, for example.
4. **Keep the folder together.** The launcher needs the program and its configuration file beside it. Move or copy the whole folder, never a single file.

> **Do not run it from inside the ZIP window.** Double-clicking the ZIP shows its contents as if it were a folder, but it is not one: Windows extracts only the file you double-click into a temporary place. The launcher then finds nothing beside it and stops: `Start-English.cmd` says *ERROR: en-US package is missing*, and `Start-NetworkCheck.cmd` inside the `en-US` folder says *The program file NetworkHealthCheck.ps1 is missing*. Extract first.

---

## 3 · Running the check

1. Open the extracted folder and double-click **`Start-English.cmd`**. (Opening the `en-US` folder and double-clicking `Start-NetworkCheck.cmd` does the same thing.)
2. If Windows shows **Open File - Security Warning**, choose **Run**. That is the download mark from step 2 above; the tool is the same either way.
3. A black text window opens first and stays in the background until the check finishes. Leave it alone.
4. The window **Network Health Check Tool 1.2.4** opens and **starts by itself** within a second. You will see:

   | On screen | What it means |
   |---|---|
   | **Result: Test in progress** | The check is running |
   | The progress bar and the line above it | The step currently running — for a few seconds near the end it reads *Sampling TCP retransmissions, approximately N second(s) remaining* |
   | The log | One line per step and per finding, in the order they happen |
   | The buttons | **Start Test** is greyed out while the check runs; **Open Report**, **Open Report Folder** and **Open JSON** switch on when it is done; **Close** does nothing until then |

5. **Wait for it to finish.** The line above the progress bar reads **Test Complete**, the Result line shows the verdict in colour, and the last log line names the report: *Report generated: …*. The same path appears under the buttons as *Report: …*, and **Start Test** now reads **Run Again**.
6. Click **Open Report**. The report opens in your web browser. It is a file on this computer, not a web page on the internet.

**Run it while the problem is happening.** The tool measures one moment on one computer. If the trouble comes and goes, a run made while everything works proves little; a run made during the trouble is the evidence IT needs. Keep using the network the way you normally do while it runs — for a few seconds it measures the computer's own traffic, and a computer doing nothing gives it nothing to measure.

**Running it again.** **Run Again** starts a new check in the same window. Every run writes a new set of report files with its own time in the name; earlier reports are not overwritten. Two reports — one from a good moment and one from a bad one — are worth more to IT than either alone.

---

## 4 · Reading the result

### The verdict

The Result line in the window and the coloured box at the top of the report show one of four verdicts:

| Verdict | The tool's description | What it means for you |
|---|---|---|
| **Overall Healthy** | All required checks that could be executed passed. | Everything the check can see is fine at this moment. If your problem continues, it is probably somewhere the check does not reach — the application, a server — or it comes and goes: run again while it is happening. |
| **Attention Required** | No required check failed, but warnings or quality issues were detected. | You are connected, but something is off — packet loss, high latency, retransmissions, adapter errors, or another warning. Send the report. |
| **Problem Detected** | At least one required check failed. | Something the check requires is broken. The report says which check and what it saw. Send the report. |
| **Test Incomplete** | Some checks could not be completed because of permissions, system components, or execution errors. | The tool could not measure something on this computer. That is not proof of a network fault, and it is not something you did wrong. Send the report as it is. |

### What to tell IT

Under the verdict, the report has a section called **What to tell IT**: a title and two to four lines. **Read this first** — it is the tool's own reading of where the fault is, written for you, and its last line always reminds you which file to send and what it contains.

| Title | What it says |
|---|---|
| **Everything passed** | All checks passed during this run. If the problem persists, it is likely on the application or server side, or it comes and goes; run the tool again while it is happening. |
| **Local link problem** | No working network adapter or no default gateway was found. The fault is on this computer or its link: cable, Wi-Fi association, adapter disabled, or DHCP not answering. Try another device on the same network to see whether only this computer is affected. |
| **Gateway does not answer** | The default gateway is configured but does not answer pings. The fault is between this computer and the router: link, Wi-Fi, switch, or the router itself. Check the link light or Wi-Fi signal and whether other devices reach the router. |
| **Gateway answers, internet does not** | The router answers, but connections beyond it fail. The fault is at or beyond the router: WAN link, ISP, or an upstream firewall. Check the router's WAN status and whether other devices lose the internet too. |
| **Name resolution fails** | Direct connections by IP address work, but host names do not resolve. The fault is DNS: the configured DNS servers, a filtering service, or the name itself. Compare the DNS servers in this report with the expected company settings. |
| **Connected, but quality is poor** | Connectivity works, but packet loss, latency, retransmissions, or adapter errors were above the thresholds. Typical causes: weak Wi-Fi, a congested link, or a faulty cable or port. Run the tool again while the problem is occurring and compare the numbers. |
| **A required check failed** | At least one required check failed; see the failed rows. Send the report to IT as it is. |
| **Some checks could not run** | No failure was found, but some steps could not be completed on this computer. Send the report as it is; the reasons are recorded in the details. |
| **Warnings to review** | No required check failed, but some checks raised warnings; see the highlighted rows. Send the report as it is. |

The first three problem titles name things you can check yourself before calling — a cable, the Wi-Fi signal, whether another device on the same network has the same trouble. The rest is for IT.

### The rest of the report

- **Computer and Run Information** — the computer name, the user, the operating system, the tool version, and where the configuration file and the reports are.
- **Test Results** — one row per check: the time, a category, the check's name, a result badge and a description. **Show Details** under a description opens the measurements behind it (the individual ping replies, the adapter's addresses, the command IT could run by hand to repeat the check). **Expand all** / **Collapse all** at the top of the table open and close every one at once. The badges:

  | Badge | Meaning |
  |---|---|
  | **Pass** | The check ran and the result met its rule |
  | **Warning** | The check ran; the result did not fail its rule, but it is worth attention — loss or latency over a threshold, a warning-level counter, a notice about the run itself |
  | **Fail** | The check ran, but the result did not meet its rule |
  | **Unable to Check** | The step could not be completed — permissions, a missing system component, company policy or an execution error. It does not necessarily mean the network is faulty |
  | **Information** | A fact recorded with no verdict attached — the computer's name, a virtual adapter, an optional test target that did not answer, a note that IT has not defined a company standard in the configuration file |

- **IT diagnostics** — collapsed at the bottom: Wi-Fi radio details, routes, the gateway's hardware address, proxy settings, the first hops of a traceroute, adapter drivers. These rows are for IT and never change the verdict. You can leave them closed.
- The six counters under the verdict (**Pass**, **Warning**, **Fail**, **Unable to Check**, **Information**, **Total**) count the rows of the Test Results table.

The **TXT** and **JSON** files written beside the HTML carry the same findings: the text file for reading where no browser is available, the JSON file for IT's tools. **Open JSON** in the window opens it in Notepad.

---

## 5 · Sending the report to IT

**Which file.** The one **Open Report** opens — usually the `.html` file. If IT asks for the JSON as well, **Open JSON** shows it and **Open Report Folder** takes you to all three files. If the HTML could not be written (rare — the window says so), Open Report opens the text or JSON file instead, and that is the report too: send that.

**Where the files are.** Click **Open Report Folder**. By default the reports go into a `Reports` folder next to the program — `en-US\Reports` — and each run writes three files named:

```text
NetworkHealthCheck_<date>_<time>_<COMPUTERNAME>.html
NetworkHealthCheck_<date>_<time>_<COMPUTERNAME>.txt
NetworkHealthCheck_<date>_<time>_<COMPUTERNAME>.json
```

IT may have configured a different folder. And if the usual folder cannot be written to, the tool saves the reports under the Windows temporary folder (`%TEMP%\NetworkHealthCheck\Reports`) and says so in the window and in the report. The path under the buttons is always the one that was actually used.

**Send it as it is.** Do not edit the report. Attach the file to your ticket or e-mail, or copy it to wherever IT asked. Old reports are ordinary files; you can delete them when you no longer need them.

**What the report contains.** The computer name, your user name, the Windows and PowerShell versions, and the organization name IT put in the configuration; every network adapter with its model, MAC and IP addresses, network profile name, gateways, DNS servers, DHCP mode and driver version; the Wi-Fi network name (SSID), the access point's hardware address (BSSID), band, channel and signal; the router's hardware address; the proxy settings Windows is using; the addresses the tests were aimed at, resolved to or landed on, and the routers on the traceroute's first hops; the folder paths of the configuration file and the reports, which can include your user profile folder; and the text of any error the tool met. Handle the file the way your company's rules say to handle that kind of information. The tool never uploads it anywhere; it only writes it to the report folder, which is on this computer unless IT chose a folder elsewhere.

---

## 6 · If something does not work

| What you see | What it means | What to do |
|---|---|---|
| **Open File - Security Warning** when you double-click the launcher | The file carries Windows' mark for downloads from the internet | Choose **Run**. To avoid the question, unblock the ZIP before extracting (section 2) |
| The black window says **ERROR: en-US package is missing** and waits for a key | `Start-English.cmd` found no `en-US` folder beside it — usually a double-click inside the ZIP window, where Windows extracts only the file you clicked | Extract the whole ZIP into a folder and run the launcher from there |
| The black window says **ERROR: The program file NetworkHealthCheck.ps1 is missing** and names an error report `LauncherError.txt` | Only one file was extracted — a double-click on `Start-NetworkCheck.cmd` inside the ZIP window — or a single file was copied on its own | Extract the whole ZIP into a folder and run the launcher from there |
| The black window says **ERROR: PowerShell was not found on this computer** | The program needs Windows PowerShell, which is part of Windows | Ask IT to look at this computer, or run the check on another one |
| The black window says the program **ended with exit code 3**, and a file **`NetworkHealthCheck_ENVIRONMENT_<time>.txt`** appeared next to the program (or in the Windows temporary folder) | A company security policy restricts what PowerShell may do on this computer. The tool stopped before running any check: no network setting was read and nothing was changed. The file it wrote for IT names the computer, the user, the PowerShell version and the operating system, so that IT can act | There is nothing to fix on your side. Send the environment file to IT with your request — it names the computer, the restriction and what IT can do |
| The black window says the program **ended with exit code** *something else* and that PowerShell or company security policy may have blocked it | Windows PowerShell refused to run the program and printed its reason above the error | Read the lines above the error and send them to IT together with `LauncherError.txt`. If they say the file is *not digitally signed* or *blocked by a policy*, IT has to allow the program |
| The black window names an **error report** (`LauncherError.txt`) | The launcher wrote what happened, with a **Suggested action** line that fits the reason | Follow the suggested action, and send the file with your request. It is next to the launcher, or — when that folder cannot be written — in the Windows temporary folder as `NetworkHealthCheck_LauncherError.txt`; the window prints the path |
| No window appears; the check runs as text in the black window instead, and the black window closes when it is done | The graphical interface could not start on this computer, and the tool switched to text mode by itself. The same checks ran, the reports were written to the usual folder, and the report has a warning row saying so | Open the `Reports` folder (section 5) and send the newest report as usual. To keep the text on screen, run `Start-NetworkCheck-Console.cmd` in the `en-US` folder instead: it runs the same checks in text mode and pauses at the end, with the report paths printed above |
| The report has a **Startup Notice** warning row: *"This copy is running from inside a compressed folder…"* | You ran the tool from the ZIP window. The reports went to a temporary place that disappears when the window closes | Extract the whole ZIP (section 2) and run it again |
| A **Startup Notice** warning row: *"The original report directory is not writable. Reports will be saved to: …"* | The usual `Reports` folder could not be written to, so the reports went to the folder the row names | Nothing to fix. **Open Report Folder** opens the right place |
| A message box **Report generation failed**, naming an emergency error report `NetworkHealthCheck_FATAL_<time>.txt` | The check ran but no report file could be written | Send the FATAL file to IT; it holds everything the check found before the failure |
| A message box saying **N of 3 report formats could not be written** | Some report files could not be saved; the one that was is named in the message | Send that one. **Open Report** opens it |
| A message box **The test could not be completed** naming an error report | The tool met an error it could not recover from and wrote what it knows | Send the file it names |
| The verdict is **Test Incomplete** | Something could not be measured on this computer | Send the report as it is; the reasons are in the rows marked *Unable to Check* |
| The black window flashes and closes; nothing else happens | PowerShell was stopped before the tool could say anything — usually a company policy | Tell IT what you saw. A photo of the window, if you can catch it, helps |

A Startup Notice row is a warning, so on its own it turns the verdict to **Attention Required** — the network may still be fine. Read the row.

---

## 7 · When IT asks you to use the IT entry

`Start-NetworkCheck-IT.cmd` in the `en-US` folder opens the same tool with a **Run options (IT)** panel at the top, and it does **not** start by itself — the line above the progress bar reads *Ready - adjust the options, then select Start Test*. IT may ask you to type an address into **Extra ping**, a host and port into **Extra TCP (host:port)**, a name into **Extra DNS** or a web address into **Extra URL**, perhaps to change **Ping count** or **Sample seconds**, and then to click **Start Test**. When you open the report afterwards, every detail is already expanded. Whatever is typed there applies to that run only; it never changes the configuration file. **Reset to config** puts the panel back to the configured values.

---

## 8 · The files in the package

| File or folder | What it is |
|---|---|
| `Start-English.cmd`, `Start-Traditional-Chinese.cmd` | The launchers at the top of the package: each opens the check in its language |
| `en-US\`, `zh-TW\` | The English and the Traditional Chinese package — the same tool twice, each with its own launchers, configuration, manual and guides |
| `en-US\Start-NetworkCheck.cmd` | The launcher you use |
| `en-US\Start-NetworkCheck-IT.cmd` | The IT entry (section 7) |
| `en-US\Start-NetworkCheck-Console.cmd` | Text mode, for a computer where the window cannot open |
| `en-US\NetworkHealthCheck.ps1` | The program. Do not edit it |
| `en-US\NetworkHealthCheck.config.json` | The settings — company standards, test targets, thresholds. IT edits it; you do not |
| `en-US\NetworkHealthCheck_User_Manual_en-US.md`, `.html` | This manual, as text and as a web page |
| `en-US\README_en-US.txt` | Configuration notes for IT |
| `en-US\NetworkHealthCheck_Technical_Guide_*.md`, `docs\` | The technical guide, in both languages: design, decision rules, limitations |
| `en-US\Reports\` | Created when the tool first starts; holds the reports |
| `README_BILINGUAL.md` | The package's front page, in both languages |
| `SHA256SUMS.txt`, `tools\` | Integrity checks for IT |
| `VALIDATION.md`, `validation-matrix.html` | The validation record of this release, for IT |

---

## 9 · Questions people ask

**Does it change anything on my computer?** No. It reads network information and runs connection tests. It does not touch IP, DNS, routes, firewall, proxy or adapter settings, and it installs nothing.

**Do I need to be an administrator?** Normally not. If the tool cannot read something without more rights, the row says *Unable to Check* and the check continues.

**Is the report sent anywhere?** Not by the tool. With the settings as shipped it is written to a folder on this computer and goes nowhere until you send it; if IT pointed the report folder at a network location, that is where it is written, and the report says so under *Computer and Run Information*.

**Which addresses does it contact?** With the settings as shipped: your own default gateway, the public address `1.1.1.1` (a ping, a connection to port 443, and the first three hops toward it for the traceroute) and `https://www.microsoft.com/` (one page request through the proxy Windows is set to use, following any redirect it is given), plus the name lookup for `www.microsoft.com` through this computer's DNS servers. IT may have replaced these with the company's own services — the report's rows name the targets that were configured and, for a page request, the address it finally landed on.

**A row says "Unable to Check" for the TCP retransmissions.** The counters could not be read — a permission, a policy or a broken performance counter. It does not mean there were retransmissions; the report says so itself. Send it as it is.

**A row says there was not enough TCP traffic during the sample.** The computer was quiet while the tool measured. That row is information, not a fault. If the problem is slowness, run the tool again while you are using the network — during the video call, the download or the thing that is slow.

**I use a VPN.** The report shows both the physical adapter and the VPN adapter; the VPN one is normally marked *Virtual* and listed as information. Tell IT whether the VPN was connected when you ran the check.

**It says Overall Healthy, but my problem is still there.** The check saw one moment on this computer. Run it again while the problem is happening, note the time, and tell IT what you were doing at that moment — the application, the server, whether other people had the same trouble.

**Can I run it on another computer?** Yes, on any Windows 10 or Windows 11 computer. Copy the whole folder. Every report names the computer it was made on.

**Can I use the Chinese package instead?** Yes — `Start-Traditional-Chinese.cmd`, or the `zh-TW` folder. It is the same tool with the interface and the report in Traditional Chinese. IT can read a report in either language.

**Can I delete old reports?** Yes. They are ordinary files in the `Reports` folder.

---

*NetworkHealthCheck 1.2.4. This manual describes the tool as shipped; what your IT department changed in the configuration file — targets, thresholds, the report folder — shows up in the report's rows and in its Computer and Run Information section.*
