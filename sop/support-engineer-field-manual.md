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
- **Nobody can run it at all** — no interactive session of any kind, or no one at the machine who can download and extract a file. A headless host or a remote shell is *not* an exclusion: `Start-NetworkCheck-Console.cmd` (or `-ConsoleOnly`) runs there, and the GUI falls back to console mode by itself when it cannot start.
- The fault is **already isolated**. The tool is for cutting the search space, not for decorating a conclusion.

**Cost:** about two minutes of the user's time, plus 40–120 seconds of run time depending on the options.

---

## 2 · Station 0 in practice — getting it run

The SOP's Station 0 decides *how* you delegate. Same tool, two scripts.

| | IT professional | General user |
|---|---|---|
| **What you send** | The Releases link and the switch line | The ZIP, or the link with the three steps below |
| **Which launcher** | `Start-NetworkCheck-IT.cmd` | `Start-NetworkCheck.cmd` |
| **What you ask back** | "Send me whatever the run wrote — the JSON and the HTML when they are there" | "Send me the file **Open Report** opens" |
| **Pace** | One message | One step, confirm, next step |

**The general-user script** — say it in this order, and wait after each step:

1. "Download the ZIP I sent. **Right-click it → Properties → Unblock**, then extract the whole folder to your Desktop." *(Skip Unblock only if they downloaded it from an internal share.)*
2. "Open the folder, open **`en-US`** *(or `zh-TW`)*, and double-click **`Start-NetworkCheck.cmd`**."
3. "A window opens and runs by itself. When it finishes, click **Open Report** and send me the file it opens. It is usually a web page; if a plain text file opens instead, that is the report too — send that."

zh-TW equivalents, if that is the user's language:

1. 「把 ZIP 下載下來，**在檔案上按右鍵 → 內容 → 解除封鎖**，再整包解壓縮到桌面。」
2. 「打開資料夾，進入 **`zh-TW`**，雙擊 **`Start-NetworkCheck.cmd`**。」
3. 「視窗會自己跑完，按 **開啟報告**，把它打開的那個檔案傳給我。通常是網頁；如果打開的是純文字檔，那也是報告，一樣傳給我。」

**Three things to say before they click** — they pre-empt the three questions you would otherwise be asked mid-run:

- **It changes nothing.** No install, no admin rights. It reads network information and runs connection tests; it does not modify IP, DNS, routes, firewall or adapter settings.
- **Windows may warn** about a file from the internet. That is the Mark of the Web on a downloaded ZIP; Unblock before extracting and the warning does not appear.
- **Extract first.** Do not run it from inside the ZIP preview window — Windows opens that in a temporary folder it later deletes, taking the reports with it. The tool warns when it detects this, but the launcher usually stops first.

**Which launcher, when**

| Situation | Launcher | Behaviour |
|---|---|---|
| A user running it for you | `Start-NetworkCheck.cmd` | Starts and runs everything by itself |
| You (or IT) at the machine | `Start-NetworkCheck-IT.cmd` | Opens a run-options panel — extra ping/TCP targets, sample length, optional checks — and **nothing runs until Start is clicked**; the HTML opens with the IT diagnostics expanded |
| No GUI, or the window will not open | `Start-NetworkCheck-Console.cmd` | Same checks in text mode. **The launcher forwards no arguments** — it always runs the script with `-ConsoleOnly` alone, so options given to the `.cmd` are silently ignored. To set targets or sample length in console mode, run the script directly, the form the package README shows: `powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly -PingTarget 10.0.0.1 -SampleSeconds 20` |

**What to ask for.** The run writes three files named `NetworkHealthCheck_<yyyyMMdd>_<HHmmss>_<COMPUTER>`. **By default** they land in a `Reports\` folder beside the script — but the config file can name another folder (an absolute path is taken as given), and if the preferred folder cannot be written the tool falls back to `%TEMP%\NetworkHealthCheck\Reports`. So do not send a user hunting through folders: have them click **Open Folder** in the tool's window, or read the path the run itself prints. And a run can finish having written only **some** of the three — if at least one format was saved the run counts as successful, a warning names the ones that failed, and **Open Report** opens the first that exists. Ask for whatever was written rather than for a format by name.

| File | Ask for it when |
|---|---|
| `.html` | Whenever it was written — the readable one, and what **Open Report** opens |
| `.json` | Whenever it was written and the case may escalate, or you want to compare two runs (schema 2: run options, fingerprint, every result) |
| `.txt` | When the user can only paste text into a chat window — and as the fallback when the HTML is one of the formats that failed |

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

3. **Every highlighted row — FAIL, ERROR and WARN.** An `Attention Required` report has no failed rows at all; its evidence is entirely in the warnings, and reading only failures would skip the thing that produced the verdict. Most rows carry a **Method** line (how it was measured) and a **Manual check** line (the command that reproduces it by hand) — if you are going to disagree with a row, run that command first. Not every row has one: the connectivity group is derived from its members, and some IT rows only state what they read.

4. **The IT diagnostics**, collapsed by default: Wi-Fi radio, routes, gateway ARP, proxy, traceroute, drivers. **These never change the verdict** — the tool computes the verdict from the user-scope rows alone. They are evidence, not judgement, and that is deliberate: an IT-only observation should never turn a user's report red.

**If you asked for a target, read its row whatever the verdict says.** Everything you add through the IT panel or the switches is *optional*, and what an optional target does to the verdict depends on **how** it fails:

| An optional target that… | Row | Verdict |
|---|---|---|
| gets **no ping reply at all**, or cannot connect over **TCP or HTTP** | `INFO` | **unmoved** — the run can still be `Overall Healthy` |
| replies but is **degraded** (loss or latency over a threshold) | `WARN` | **moved** — `Attention Required` |
| is a **DNS name that will not resolve** | `WARN` | **moved** — `Attention Required` |

So a run in which the service you were asked about was completely unreachable can come back **Overall Healthy**, with that failure sitting in an `INFO` row the four moves above would skip — while an added DNS name that fails turns the whole report amber. Measured on a real run: three added targets, all unreachable (100 % loss, no TCP connection, no HTTPS response), all `INFO`, verdict `Attention Required` for an unrelated 50 % loss on a configured target.

**Exit codes**, if you are scripting around it, hold for **console runs only** (`-ConsoleOnly`, which is what the console launcher starts): there `0` means the run finished and wrote its reports — *whatever the verdict was* — and anything else means **no normal report** — which is usually not the same as no evidence: exit 3 **attempts** `NetworkHealthCheck_ENVIRONMENT_*.txt` (the script's folder first, then `%TEMP%`) and a run that could not write a single format **attempts** `NetworkHealthCheck_FATAL_*.txt`. Both are best effort — each can come back with nothing, which is likeliest when the output folder is precisely what is broken. **Collect the path only if the process printed one**; when it printed none, the text on screen is all the evidence there is (§6). **A GUI run always exits 0.** The entry point sets it after the window closes, so an IT window closed before Start was ever clicked, and a run whose report writing failed, both exit 0 as well. Never read a GUI exit code as evidence; look for the report.

---

## 4 · The join — from fingerprint to station

The fingerprint is the tool's answer to the SOP's third front-door question, computed from the rows rather than guessed. Nine values, chosen by an **ordered chain — the first rule that matches wins**, which is why a fingerprint tells you as much by what it rules out as by what it names. Read the rule, not just the title: two of them cover more than one situation.

| Fingerprint · title | Chosen when | SOP lane | Go to | Ask for next |
|---|---|---|---|---|
| `local` · Local link problem | The `adapters` row failed **or** the `gateway-config` row failed | **Three faults wear this name** | **2**, or **1 → 3 → 5**, or **1** | Which of the two rows failed decides — see *Reading `local`* below |
| `gateway-unreachable` · Gateway does not answer | A `ping-gateway` row failed and none passed — decided **before** the TCP, HTTP and group rows are considered, so a gateway that forwards traffic but drops ICMP to its own address lands here with the rest of the network working | **IP, gateway unreachable** — local L1/L2, *once the ping is corroborated*. This is SOP Rule 3 in its purest form: a failed ping is a suspect, not a conviction | **2** (wireless) or **3** (wired) — but read the `tcp`, `http`, `connectivity-group` and `gateway-neighbor` rows first | If those passed **and at least one of them was off-subnet by a route through the gateway in the row you are reading** — the targets are configured independently, so an on-subnet host, a VPN or a proxy can succeed without ever touching it, and on a multihomed machine `AUTO_GATEWAY` produces **one row per gateway** while the fingerprint asks only that none passed, so a witness routed through gateway A says nothing about failed gateway B — the path works and that gateway is merely silent to ICMP: stay at station 1 and look at the config rather than walking to the switch. Work through any other failed gateway row on its own terms. If they failed too: port error-counter delta, two samples; MAC learned on the expected port and VLAN; for Wi-Fi, the AP client table — the report's own RSSI is the client's view, weaker evidence |
| `gateway-up-internet-dead` · Gateway answers, internet does not | A gateway ping passed, a `connectivity-group` failed and none passed. **The rule does not read the group's name** — a site that replaced the Internet group with an internal one (the package README tells IT how) lands here for a failed internal service — and it pairs **any** passing gateway row with **any** failed group without checking that they share a route: on a multihomed machine gateway A can answer while the failed group's traffic leaves through the unavailable gateway B | **Gateway OK, internet dead** — *only when the failed group is the Internet one, and only when the gateway that answered is the one its members route through.* Read which group failed, what its members target, and which gateway that traffic uses, before walking outward | **5 → 6 → 8** for an Internet group whose route uses the gateway that answered; where a different gateway carries it, the fault is local routing or that second link — stay at **1**, then **3** | Default route present at the gateway; NAT translation and policy hit counters; WAN status. The report's traceroute row traces the **first configured ping target, not the group member that failed**, and only three hops by default — so unless those two are the same destination it says nothing about this failure. Ask for an uncapped `tracert -d <the address that failed>`; the row's own Manual-check line carries both the wrong target and the three-hop cap |
| `dns` · Name resolution fails | A `dns` row failed or warned, none passed, **and something else worked** (a connectivity group or a TCP row passed) — but that success may itself have used a host name, so the rule does not prove the differential its title claims | **IP works, names fail** — *only once you have confirmed it* | **7**, after the check below | Compare the targets: find a success that needed **no** lookup (an IP-addressed ping or TCP row). Then which servers the client actually points at (the report's DNS rows say), and the failure type — timeout vs SERVFAIL vs NXDOMAIN |
| `quality` · Connected, but quality is poor | A quality row (`ping-target`, `ping-gateway`, `tcp-retransmissions`, `adapter-errors`) warned or failed and **no other row warned or failed**. Only WARN and FAIL exclude it: an unrelated **ERROR** row does not, and this rule is evaluated before the ERROR one — so a `Test Incomplete` verdict can arrive carrying a `quality` fingerprint | **Intermittent** — front door Q4 | **2 → 3** | Counter deltas at the port; RF numbers from the AP; a second run **while the problem is happening**. If the verdict is `Test Incomplete`, deal with the ERROR rows as well (§6) — the fingerprint did not consider them |
| `mixed` · A required check failed | Overall FAIL that none of the rules above matched — **one unclassified required failure is enough**, and a single `expected-standard` row lands here | The lane is not named for you | Read the failed rows | Reproduce each failed row with its Manual-check line; there may be only one. If it is `expected-standard`, check the config's expectations against this site before treating it as a fault |
| `attention` · Warnings to review | Overall WARN that the quality rule did not match | No lane is lit | Judgement | Whether the warned thresholds match this site's baseline; the defaults are generic starting values |
| `incomplete` · Some checks could not run | Overall ERROR — something could not be measured | No lane is lit | §6, then judgement | What blocked the measurement — the details name it; a restricted or locked-down machine is itself a finding |
| `healthy` · Everything passed | Nothing above matched and every required check passed | None | Application or server side, or intermittent | A run **during** the failure; if the user reports a problem and this comes back clean, the endpoint's view is not where the fault is |

**A healthy report does not clear the network.** It clears *this endpoint's view, at that moment*. Say that in the ticket rather than "the tool says it's fine". And because the fingerprint is computed from the verdict-bearing rows alone, **`healthy` with a dead optional ping, TCP or HTTP target is a normal outcome**, not a contradiction — though an optional target that degrades, or an added DNS name that will not resolve, does move the verdict (§3).

### Reading `local` — three faults under one name

One fingerprint, two failing rows, three different first moves. **Read which row failed before you choose a station.**

| The `adapters` row failed, and the machine is **wireless** | The `adapters` row failed, and the machine is **wired** | The `gateway-config` row failed |
|---|---|---|
| A radio that is off, or an association that failed, leaves an interface that is down or unaddressed — which the collector omits, so this looks exactly like a machine with no NIC | No working adapter, and no lease: the **No IP** / DHCP lane | An address with **no default gateway at all** — a client-side configuration fault, which a static address can produce with DHCP nowhere in the picture |
| **Station 2 first**, before anything else: SSID visible, associated *and* authenticated, RSSI and SNR at the AP | **1 → 3 → 5** | **Depends on the address** — the three branches below |
| The `wifi` row is the client's own view and weaker evidence than the AP's client table | Port link state and PVID; the DHCP scope's utilization | — |

**When `gateway-config` failed, the address names the lane.** Read the *per-adapter* rows, not only the aggregate `Usable Network Adapters` one — that aggregate passes whenever a physical adapter is connected, and the APIPA detection lives on the individual adapter's row:

| What the adapter rows show | What it means | Go to |
|---|---|---|
| **169.254.x.x**, with the adapter's details showing **DHCP enabled** | DHCP did not answer — the SOP's own first fingerprint, and nothing to do with client configuration | **1 → 3 → 5**: port VLAN, uplink, relay, scope |
| **169.254.x.x**, but the details say **DHCP disabled / static** | Someone configured a link-local address by hand. The tool's row says this "usually means DHCP did not provide an address" — it reads the address alone and does not check the mode, so read the mode yourself | **1** — client configuration |
| **169.254.x.x**, and the details say **DHCP: Unknown** | The tool could not read the mode at all — `Get-NetIPInterface` was unavailable or answered neither way, and the CIM path can carry the same gap. `Unknown` is the field's default, not a measurement, and the APIPA message does not settle it either | **Ask before you walk**: have the user read the `DHCP Enabled` line of `ipconfig /all` for that adapter, then take one of the two rows above. Choosing a lane on an unknown mode is a coin toss between a DHCP outage and a client misconfiguration |
| A real address **from DHCP**, but no gateway | The scope handed out no router option, or it was removed | **5** for the scope's options, with **1** to confirm what the client received |
| A **static** address and no gateway | Client-side configuration, DHCP nowhere in the picture | **1** |

**What `gateway-config` does and does not judge.** It fails only when **no** IPv4 gateway is configured on any adapter. A gateway that is present but **wrong** passes it, and no fingerprint names that case:

- nothing answers → `gateway-unreachable`
- it answers but nothing beyond it works → `gateway-up-internet-dead`
- it answers and everything else works → `mixed` **if** the site configured `AllowedDefaultGateways`, because the `expected-standard` row for **Default Gateway** then fails; without that setting there is **no gateway-specific diagnosis at all** — the chain falls through to its default, `healthy` / "Everything passed", unless something unrelated selects another key

That `expected-standard` row is the only place the tool judges a gateway's *value*.

**The one thing the report cannot tell you on this lane.** It says whether the address came from DHCP or is static, but **not which server answered** — so for the rogue-DHCP question (SOP station 1) you still need `ipconfig /all`'s `DHCP Server` line from the user.

---

## 5 · What each row testifies to

Grouped by the SOP's three families of state. **Main** rows shape the verdict; **IT** rows are evidence only.

**Tables — the network's memory**

| Row | Scope | Testifies to | Limit |
|---|---|---|---|
| `adapters`, `adapter` | Main | The **connected and addressed** adapters — status Up *and* holding an IPv4 or IPv6 address — physical vs virtual, with their addresses | **Not an inventory of the hardware.** A disabled, down or unaddressed NIC never reaches the report, so "the report shows one adapter" does not mean the machine has one. And on the **CIM fallback path** — taken when `Get-NetIPConfiguration` is unavailable — the rows say `Up` because the fallback hard-codes that status over IP-enabled configurations: a disconnected adapter still holding a static address appears there as connected. Each adapter row's details carry a **`Data source:`** field, and that is the reliable indicator: the separate `data-source` WARN row appears only where `Get-NetIPConfiguration` actually threw — when it is unavailable, or returns nothing, the tool falls back silently. Read that field before clearing the local link on this evidence. Virtual adapters are classified by their flags first, description second; a VM's NIC can be described like a physical one |
| `gateway-config`, `dns-config` | Main | What the client is *configured* with, and where it came from (DHCP vs static) | Config, not state — the SOP's own warning applies |
| `routes` | IT | The IPv4 default route as the machine sees it | Since 1.2.3 a machine with no default route reads `INFO — No IPv4 default route exists.` rather than an error |
| `gateway-neighbor` | IT | The gateway's MAC **as the neighbour cache holds it**, with the entry's state | A cache read, not a probe: `Get-NetNeighbor` / `arp -a` report an entry that may be stale, so presence alone proves nothing about the link *now*. A `Reachable` entry is Rule 3's second witness for a failed gateway ping; a stale one is history — corroborate it with the TCP or HTTP rows before convicting or clearing the link |
| `proxy`, `drivers`, `wifi` | IT | Proxy configuration, adapter driver versions, the client's own view of the radio | `wifi` is the client side: SSID, band, channel, RSSI, rate. The AP's client table is the stronger witness (SOP station 2). **`drivers` is empty on the CIM fallback path** — the fallback leaves the version, date and provider blank by construction, and the row still appears showing `(none)`; check the adapter's `Data source:` field, and read `Get-NetAdapter \| Format-List Name, DriverVersion, DriverDate` instead of that row |

**Counters — always deltas**

| Row | Scope | Testifies to | Limit |
|---|---|---|---|
| `adapter-errors` | Main | Errors and discards accumulating **during the sample**, not since boot | A zero-traffic adapter reports zero errors, which clears nothing — the tool annotates that case |
| `tcp-retransmissions` | Main | Approximate retransmission ratio over the sample, TCPv4 and TCPv6 | It measures **whatever the machine was doing at the time**. A machine that was busy over a weak Wi-Fi during the sample will look bad; this was measured in the tool's own validation. A single high reading is a suspect, not a conviction |

**Probes — differential tests**

| Row | Scope | Testifies to | Limit |
|---|---|---|---|
| `ping-gateway`, `ping-target` | Main | The ladder's rungs, with loss and latency | ICMP may be filtered; that is why the next two rows exist. **The status depends on whether the target is *required*, and the tests are an ordered chain — the first condition that matches decides.** No reply at all → FAIL when required, `INFO` when not. Then loss ≥ critical → FAIL / WARN. Then loss ≥ warning → WARN. Then latency ≥ critical → FAIL / WARN. Then latency ≥ warning → WARN. Because loss is tested before latency, **a required target with warning-level loss and critical latency is WARN, not FAIL** — the chain stops at the first match, it does not pick the worst. Everything added at run time is optional |
| `tcp`, `http` | Main | A real connection to a real port, and an HTTP response | Rule 3's corroboration — but only between probes that name the **same destination**. The ping, TCP and HTTP targets are configured separately and the IT panel can add more, so read the targets in the rows first: "ping fails, TCP succeeds" is a filtering finding when both went to the same host, and nothing at all when they did not |
| `connectivity-group` | Main | Whether a group's targets are reachable at all | **A group is required only if the config lists it in `RequiredConnectivityGroups`.** A group outside that list still gets a row, and its failure is a **WARN**, not a FAIL — check which kind you are reading before treating the row as authoritative. Derived from its members; it carries no Manual-check line of its own |
| `traceroute` | IT | The first hops toward **the first configured non-`AUTO` ping target** (`1.1.1.1` unless the site changed it) — each with its address, status and time, silent hops as `*`, and whether the destination was reached. **It does not trace whatever failed**, so compare its target with the failed row before reading anything into it | **It samples the first hops only — three by default** (`TracerouteHops`), which is what the row's name says. **Neither outcome gives you a boundary.** A trace that reached its destination shows no break at all — its last hop *is* the destination. One that did not stops at the last hop that answered, which under a three-hop cap is simply the last hop sampled. Locating a boundary takes a trace toward the address that actually failed, run far enough to show where the replies stop, and even then a silent hop wants corroboration — routers commonly drop TTL-expired replies while forwarding normally. The row's own Manual-check line carries the same cap (`tracert -d -h 3 <target>`), so ask for an uncapped **`tracert -d <the address that failed>`** |
| `expected-standard` | Main | Measured values against this organization's configured expectations | Only as good as the config file — the defaults are generic. On a site with its own baseline, set them (`NetworkHealthCheck.config.json`) before believing a WARN |

Since 1.2.3, a network error carries a **`Cause:`** line in the report's language above the operating system's own message, classified by error code; the tool's own DNS and TCP timeouts appear as `[ToolTimeout]` — nothing answered and nothing refused within the tool's limit, the shape of a firewall dropping packets or an unreachable host.

---

## 6 · When it does not run

What the user sees, what it means, what you do.

| What comes back | Meaning | Your move |
|---|---|---|
| `LauncherError.txt` | The launcher stopped before or after the program. Since 1.2.3 it carries **`Suggested action:`** matched to the reason, and the same line is on screen | Read the suggested action first; it is reason-specific, not boilerplate. The file is written beside the script, or — when that folder cannot be written, which is exactly what a read-only share or a protected folder produces — as `%TEMP%\NetworkHealthCheck_LauncherError.txt`. The launcher checks the first write and **not** the second, so it prints that `%TEMP%` path whether or not the file arrived: ask for the file, not just the path, and if it is not there ask for what the window said |
| "…ended with **exit code 3**" plus `NetworkHealthCheck_ENVIRONMENT_<time>.txt` | Application control (WDAC/AppLocker) restricted PowerShell to a limited language mode; **no check ran** | Ask for the environment report — it names the machine, the mode and what IT can do. This is an IT conversation, not a network one. It is also a finding: the machine cannot run this class of script at all |
| "The program file NetworkHealthCheck.ps1 is missing" — or, from the root launcher, "ERROR: en-US package is missing" (`Start-English.cmd` stops before the language launcher, so no `LauncherError.txt`) | Only one file was extracted — usually a double-click inside the ZIP preview window | Have them extract the whole folder and run it again |
| A startup warning row in an otherwise normal report | **Read the message — the row has four sources.** The tool ran from inside a compressed-folder view; the report directory was not writable, so reports went to the fallback; the graphical interface could not start and console mode was used; or an extra TCP target was ignored as malformed | Only the compressed-folder message calls for a re-run from a proper folder. The report-directory one tells you where the reports actually are; the GUI one is about that machine, not the network; the target one means a run option was dropped, so check what was actually measured |
| `NetworkHealthCheck_FATAL_<time>.txt` | The run collapsed before it could produce a report. Written on a best-effort basis — if the output folder is what broke, there may be no file and no path printed | Send it with the ticket where it exists; it is the only evidence of that attempt. Where it does not, ask for what the window said |
| Nothing at all, black window closed instantly | Usually PowerShell blocked by policy before the script's own guard could speak | Ask for a photo of the window, or have them run the console launcher from an open `cmd` window so the text stays |

The launcher exits `1` on every failure path and names the program's own exit code in its text, so "exit code 1" in the launcher and "exit code 3" in the message are the same event seen from two places.

---

## 7 · Into the escalation package

The SOP's package asks for eight things. **The report fully covers none of them.** It contributes to two — the raw-output item and the exclusions — and the other six are yours to bring. Know which, so the rest is not forgotten.

| SOP package item | Covered by the report? |
|---|---|
| Topology sketch of the affected path | **No** — draw it |
| Blast radius, timeline, what changed | **No** — your notes |
| What you excluded, with the evidence | **Partly** — the passing rows are the exclusions; say in words what they exclude |
| Raw outputs — `ipconfig` / `ping` / `tracert`, **and the relevant switch and AP status pages** | **Partly** — the reports carry *measured values*, not command output: selected fields and synthesized summaries, with Method and Manual-check lines naming the command that would reproduce each. Where the escalation asks for raw output, run those commands and attach what they print. The **switch and AP status pages are not covered at all** — the tool never reads a device; they are yours to capture |
| Device logs covering the failure window | **No** — switch / AP / firewall |
| Config exports of the devices in the path | **No** |
| Reproduction steps and the workaround | **No** |
| Business impact and severity | **No** |

Attach whichever of the three formats the run actually wrote — the **HTML** where it exists (readable by anyone) and the **JSON** (machine-readable, schema 2, carries the run options and the fingerprint). A run that wrote only TXT and JSON is a supported outcome, not a failed run. Name in the ticket, in this order: the machine, the time of the run, the verdict, the fingerprint, and one sentence saying what the run excluded. The [support report template](support-report-template.md) beside this manual carries those five facts and the rest of the package in one skeleton — the hand-off and the delivery report are the same document with two fill patterns.

**Personal data.** The package's own privacy list (the user manual, §5 "Sending the report to IT", *What the report contains*) is the list to go by, and it is longer than the four fields the report's summary names: computer name, user name, **adapter / MAC / IP / gateway / DNS data**, the Wi-Fi network name **and the access-point BSSID**, **the test targets**, and **exception details**. The package's instruction is unconditional — handle them according to company policy — so apply that policy **before a report is stored or shared at all**, and let the policy, not this manual, decide whether an internal ticket is treated differently from an external one.

---

## 8 · Traps

- **"Healthy" is a scope, not a verdict on the network.** It means the endpoint's view was fine during that run.
- **Intermittent faults need a run during the fault.** One clean run proves nothing about a problem that comes and goes; two runs — one clean, one during — are worth more than either alone.
- **The quality rows measure the machine's own traffic.** A big download, a backup, or a busy remote session during the sample will move the retransmission ratio. Ask what the machine was doing.
- **A machine with no wireless adapter still produces a `wifi` row** — an INFO row saying no connected Wi-Fi interface was found (wired, radio off, or no adapter), with the interface count beneath it. Even a machine without `netsh.exe` gets a row saying that. In a run that reached the IT diagnostics at all, the *absence* of any `wifi` row means one thing: the optional `WifiRf` check is switched off in the config. A report that stopped before them — an unsupported Windows version, or PowerShell below 5, each of which writes a normal report and returns early — carries no `wifi` row either, so read the environment rows before concluding anything. Never read a disabled or unreached diagnostic as evidence about the hardware.
- **Thresholds are generic until someone sets them.** A WARN against defaults on a high-latency WAN link is a statement about the defaults.
- **A report is about one machine at one moment.** Check the computer name and the timestamp before you reason from it — reports get forwarded, renamed and re-sent.
- **Do not let the tool replace the front door.** The four isolation questions cost nothing and cut more search space than any single endpoint reading.

---

## Related documents

- [Network Troubleshooting SOP](network-troubleshooting-sop.md) — the map this manual walks
- [Support report template](support-report-template.md) — one skeleton, two fill patterns: the hand-off to L3 and the delivery report
- The package's own user manual (`NetworkHealthCheck_User_Manual_<lang>.md` / `.html`, what the person at the machine is told) and technical guide — what the tool does and how it decides
