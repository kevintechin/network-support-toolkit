# Support Engineer's Field Manual

**Running the SOP with NetworkHealthCheck — from the first call to the hand-off**

Version 1.0 · Kevin (Te-Chin) Lin · September 2026

Companion to the [Network Troubleshooting SOP v1.1](network-troubleshooting-sop.md). Written against NetworkHealthCheck **1.2.3**; behaviour that is version-specific is marked as such.

---

## What this manual is

The SOP is the map. NetworkHealthCheck is one instrument, and an unusual one: you can put it in the hands of a person you cannot see, on a machine you cannot touch, and get back evidence you can attach to a ticket. This manual is how that instrument is used inside the map — when it earns its place, how to get it run by whoever answered the phone, how to read what comes back in about a minute, which station the reading sends you to, and what travels with the hand-off.

It is not the tool's user manual and not its technical guide; both of those ship inside the package and describe the tool. This describes the work.

**One sentence to keep in mind throughout:** the tool measures *one Windows endpoint's view of the network at one moment*. That is station 1 of the SOP, plus a probe up the ladder. It never reads a switch, an AP, or the firewall.

---

## 1 · When the tool earns its place

**Send it when**

- The report is about **one user or one machine**, and you need station 1's state without being able to stand there.
- The reporter **cannot run commands** — the tool replaces a click-by-click `ipconfig` dictation with one double-click.
- You will need **evidence in the ticket** later: the reports drop straight into the escalation package, timestamped and machine-identified.
- You want the ladder **corroborated** rather than a single ping: it tests ICMP, TCP and HTTP, which is Rule 3's second witness built into one run.

**Do not send it when**

- The blast radius is already **many users, a whole VLAN, or the site**. The endpoint's view will only confirm what you know; go to stations 4–8 and read the devices you can reach directly.
- You **have access to the devices in the path**. The switch's MAC table and port counters are better evidence than an endpoint's opinion of them.
- There is **no Windows desktop session** to run it in, or the user cannot download and extract a file.
- The fault is **already isolated**. The tool is for cutting the search space, not for decorating a conclusion.

**Cost:** about two minutes of the user's time, plus 40–120 seconds of run time depending on the options.

---

## 2 · Station 0 in practice — getting it run

The SOP's Station 0 decides *how* you delegate. Same tool, two scripts.

| | IT professional | General user |
|---|---|---|
| **What you send** | The Releases link and the switch line | The ZIP, or the link with the three steps below |
| **Which launcher** | `Start-NetworkCheck-IT.cmd` | `Start-NetworkCheck.cmd` |
| **What you ask back** | "Send me the JSON and the HTML" | "Send me the file that opens in your browser" |
| **Pace** | One message | One step, confirm, next step |

**The general-user script** — say it in this order, and wait after each step:

1. "Download the ZIP I sent. **Right-click it → Properties → Unblock**, then extract the whole folder to your Desktop." *(Skip Unblock only if they downloaded it from an internal share.)*
2. "Open the folder, open **`en-US`** *(or `zh-TW`)*, and double-click **`Start-NetworkCheck.cmd`**."
3. "A window opens and runs by itself. When it finishes, click **Open Report** — it opens in your browser. Send me that file."

zh-TW equivalents, if that is the user's language:

1. 「把 ZIP 下載下來，**在檔案上按右鍵 → 內容 → 解除封鎖**，再整包解壓縮到桌面。」
2. 「打開資料夾，進入 **`zh-TW`**，雙擊 **`Start-NetworkCheck.cmd`**。」
3. 「視窗會自己跑完，按 **開啟報告**，然後把那個檔案傳給我。」

**Three things to say before they click** — they pre-empt the three questions you would otherwise be asked mid-run:

- **It changes nothing.** No install, no admin rights. It reads network information and runs connection tests; it does not modify IP, DNS, routes, firewall or adapter settings.
- **Windows may warn** about a file from the internet. That is the Mark of the Web on a downloaded ZIP; Unblock before extracting and the warning does not appear.
- **Extract first.** Do not run it from inside the ZIP preview window — Windows opens that in a temporary folder it later deletes, taking the reports with it. The tool warns when it detects this, but the launcher usually stops first.

**Which launcher, when**

| Situation | Launcher | Behaviour |
|---|---|---|
| A user running it for you | `Start-NetworkCheck.cmd` | Starts and runs everything by itself |
| You (or IT) at the machine | `Start-NetworkCheck-IT.cmd` | Opens a run-options panel — extra ping/TCP targets, sample length, optional checks — and **nothing runs until Start is clicked**; the HTML opens with the IT diagnostics expanded |
| No GUI, or the window will not open | `Start-NetworkCheck-Console.cmd` | Same checks in text mode; the same options work as switches |

**What to ask for.** The run writes three files into a `Reports\` folder beside the script, named `NetworkHealthCheck_<yyyyMMdd>_<HHmmss>_<COMPUTER>`:

| File | Ask for it when |
|---|---|
| `.html` | Always — it is the readable one, and the one the user can open |
| `.json` | Whenever the case may escalate, or you want to compare two runs (schema 2: run options, fingerprint, every result) |
| `.txt` | When the user can only paste text into a chat window |

---

## 3 · Reading the report in 60 seconds

Four moves, in this order. Resist reading the rows first.

1. **The verdict**, at the top.

   | Verdict | Code | What it means |
   |---|---|---|
   | **Overall Healthy** | PASS | Every required check that could run, passed |
   | **Attention Required** | WARN | Nothing required failed; warnings or quality issues were raised |
   | **Test Incomplete** | ERROR | Something could not be measured — permissions, missing components, an execution error |
   | **Problem Detected** | FAIL | At least one required check failed |

2. **"What to tell IT"** — the summary block under the verdict. It names the *fingerprint*: the tool's own reading of which lane the fault is in. This is the line that decides your next station (§4).

3. **The failed rows only.** Each row carries a **Method** line (how it was measured) and a **Manual check** line (the command that reproduces it by hand). If you are going to disagree with a row, reproduce it with that command first.

4. **The IT diagnostics**, collapsed by default: Wi-Fi radio, routes, gateway ARP, proxy, traceroute, drivers. **These never change the verdict** — the tool computes the verdict from the user-scope rows alone. They are evidence, not judgement, and that is deliberate: an IT-only observation should never turn a user's report red.

**Exit codes**, if you are scripting around it: `0` means the run finished and wrote its reports — *whatever the verdict was*. Anything else means no report exists; go to §6.

---

## 4 · The join — from fingerprint to station

The fingerprint is the tool's answer to the SOP's third front-door question, computed from the rows rather than guessed. Nine values:

| Fingerprint | Report says | SOP lane | Go to | Ask for next |
|---|---|---|---|---|
| `local` | Local link problem | **No IP** — DHCP path | **1 → 3 → 5** | Port link state and PVID; the DHCP scope's utilization. The report says whether the address came from DHCP or is static, but **not which server answered** — for the rogue-DHCP question you still need `ipconfig /all`'s `DHCP Server` line from the user |
| `gateway-unreachable` | Gateway does not answer | **IP, gateway unreachable** — local L1/L2 | **2** (wireless) or **3** (wired) | Port error-counter delta, two samples; MAC learned on the expected port and VLAN; for Wi-Fi, the AP client table — the report's own RSSI is the client's view, weaker evidence |
| `gateway-up-internet-dead` | Gateway answers, internet does not | **Gateway OK, internet dead** | **5 → 6 → 8** | Default route present at the gateway; NAT translation and policy hit counters; WAN status. The report's traceroute row lists the first hops with their times and shows silent ones as `*` — read the last hop that answered; it names the boundary |
| `dns` | Name resolution fails | **IP works, names fail** | **7** | Which servers the client actually points at (the report's DNS rows say), then the failure type — timeout vs SERVFAIL vs NXDOMAIN |
| `quality` | Connected, but quality is poor | **Intermittent** — front door Q4 | **2 → 3** | Counter deltas at the port; RF numbers from the AP; a second run **while the problem is happening** |
| `mixed` | A required check failed | More than one lane is lit | Read the failed rows | The rows disagree with each other — reproduce the two most severe with their Manual-check lines before choosing a station |
| `attention` | Warnings to review | No lane is lit | Judgement | Whether the warned thresholds match this site's baseline; the defaults are generic starting values |
| `incomplete` | Some checks could not run | No lane is lit | §6, then judgement | What blocked the measurement — the details name it; a restricted or locked-down machine is itself a finding |
| `healthy` | Everything passed | None | Application or server side, or intermittent | A run **during** the failure; if the user reports a problem and this comes back clean, the endpoint's view is not where the fault is |

**A healthy report does not clear the network.** It clears *this endpoint's view, at that moment*. Say that in the ticket rather than "the tool says it's fine".

---

## 5 · What each row testifies to

Grouped by the SOP's three families of state. **Main** rows shape the verdict; **IT** rows are evidence only.

**Tables — the network's memory**

| Row | Scope | Testifies to | Limit |
|---|---|---|---|
| `adapters`, `adapter` | Main | Which adapters exist, up, physical vs virtual, with their addresses | Virtual adapters are classified by their flags first, description second; a VM's NIC can be described like a physical one |
| `gateway-config`, `dns-config` | Main | What the client is *configured* with, and where it came from (DHCP vs static) | Config, not state — the SOP's own warning applies |
| `routes` | IT | The IPv4 default route as the machine sees it | Since 1.2.3 a machine with no default route reads `INFO — No IPv4 default route exists.` rather than an error |
| `gateway-neighbor` | IT | The gateway's MAC in the ARP/neighbour table — L2 proven without ICMP | Rule 3's second witness for a failed gateway ping; read it before convicting the link |
| `proxy`, `drivers`, `wifi` | IT | Proxy configuration, adapter driver versions, the client's own view of the radio | `wifi` is the client side: SSID, band, channel, RSSI, rate. The AP's client table is the stronger witness (SOP station 2) |

**Counters — always deltas**

| Row | Scope | Testifies to | Limit |
|---|---|---|---|
| `adapter-errors` | Main | Errors and discards accumulating **during the sample**, not since boot | A zero-traffic adapter reports zero errors, which clears nothing — the tool annotates that case |
| `tcp-retransmissions` | Main | Approximate retransmission ratio over the sample, TCPv4 and TCPv6 | It measures **whatever the machine was doing at the time**. A machine that was busy over a weak Wi-Fi during the sample will look bad; this was measured in the tool's own validation. A single high reading is a suspect, not a conviction |

**Probes — differential tests**

| Row | Scope | Testifies to | Limit |
|---|---|---|---|
| `ping-gateway`, `ping-target` | Main | The ladder's rungs, with loss and latency | ICMP may be filtered; that is why the next two rows exist |
| `tcp`, `http` | Main | A real connection to a real port, and an HTTP response | Together with the ping rows, this is the corroboration Rule 3 demands — treat "ping fails, TCP succeeds" as a filtering finding, not a network fault |
| `connectivity-group` | Main | Whether a required group (e.g. Internet) is reachable at all | Derived from its members; it carries no Manual-check line of its own |
| `traceroute` | IT | The first hops, each with its address, status and time; silent hops as `*`, and whether the destination was reached | Read the last hop that answered — it names the boundary, and the boundary names the domain, not the culprit |
| `expected-standard` | Main | Measured values against this organization's configured expectations | Only as good as the config file — the defaults are generic. On a site with its own baseline, set them (`NetworkHealthCheck.config.json`) before believing a WARN |

Since 1.2.3, a network error carries a **`Cause:`** line in the report's language above the operating system's own message, classified by error code; the tool's own DNS and TCP timeouts appear as `[ToolTimeout]` — nothing answered and nothing refused within the tool's limit, the shape of a firewall dropping packets or an unreachable host.

---

## 6 · When it does not run

What the user sees, what it means, what you do.

| What comes back | Meaning | Your move |
|---|---|---|
| `LauncherError.txt` beside the script | The launcher stopped before or after the program. Since 1.2.3 it carries **`Suggested action:`** matched to the reason, and the same line is on screen | Read the suggested action first; it is reason-specific, not boilerplate |
| "…ended with **exit code 3**" plus `NetworkHealthCheck_ENVIRONMENT_<time>.txt` | Application control (WDAC/AppLocker) restricted PowerShell to a limited language mode; **no check ran** | Ask for the environment report — it names the machine, the mode and what IT can do. This is an IT conversation, not a network one. It is also a finding: the machine cannot run this class of script at all |
| "The program file NetworkHealthCheck.ps1 is missing" | Only one file was extracted — usually a double-click inside the ZIP preview window | Have them extract the whole folder and run it again |
| A startup warning row in an otherwise normal report | The tool ran from inside a compressed-folder view and knows it | Take the report, but ask for a re-run from a proper folder before quoting the numbers |
| `NetworkHealthCheck_FATAL_<time>.txt` | The run collapsed before it could produce a report | Send it with the ticket; it is the only evidence of that attempt |
| Nothing at all, black window closed instantly | Usually PowerShell blocked by policy before the script's own guard could speak | Ask for a photo of the window, or have them run the console launcher from an open `cmd` window so the text stays |

The launcher exits `1` on every failure path and names the program's own exit code in its text, so "exit code 1" in the launcher and "exit code 3" in the message are the same event seen from two places.

---

## 7 · Into the escalation package

The SOP's package asks for eight things. The report covers three of them and part of a fourth — know which, so the rest is not forgotten.

| SOP package item | Covered by the report? |
|---|---|
| Topology sketch of the affected path | **No** — draw it |
| Blast radius, timeline, what changed | **No** — your notes |
| What you excluded, with the evidence | **Partly** — the passing rows are the exclusions; say in words what they exclude |
| Raw outputs (ipconfig / ping / tracert) | **Yes** — the HTML and the JSON, with Method and Manual-check lines per row |
| Device logs covering the failure window | **No** — switch / AP / firewall |
| Config exports of the devices in the path | **No** |
| Reproduction steps and the workaround | **No** |
| Business impact and severity | **No** |

Attach the **HTML** (readable by anyone) and the **JSON** (machine-readable, schema 2, carries the run options and the fingerprint). Name in the ticket: the machine, the time of the run, the verdict, the fingerprint, and one sentence saying what the run excluded. Use the report templates beside this manual for the wording.

**Personal data.** The reports carry the computer name, the user name, adapter MAC addresses and the Wi-Fi network name — the tool says so in its own summary. That is normally fine inside a support ticket; it matters when the ticket leaves the organization.

---

## 8 · Traps

- **"Healthy" is a scope, not a verdict on the network.** It means the endpoint's view was fine during that run.
- **Intermittent faults need a run during the fault.** One clean run proves nothing about a problem that comes and goes; two runs — one clean, one during — are worth more than either alone.
- **The quality rows measure the machine's own traffic.** A big download, a backup, or a busy remote session during the sample will move the retransmission ratio. Ask what the machine was doing.
- **No wireless adapter means no `wifi` rows at all.** Their absence is not a fault; it is a VM, a desktop, or a disabled radio.
- **Thresholds are generic until someone sets them.** A WARN against defaults on a high-latency WAN link is a statement about the defaults.
- **A report is about one machine at one moment.** Check the computer name and the timestamp before you reason from it — reports get forwarded, renamed and re-sent.
- **Do not let the tool replace the front door.** The four isolation questions cost nothing and cut more search space than any single endpoint reading.

---

## Related documents

- [Network Troubleshooting SOP](network-troubleshooting-sop.md) — the map this manual walks
- Report templates (this folder) — the hand-off and the delivery wording
- The package's own `README_*.txt` and technical guide — what the tool does and how it decides
