# Network Health Check 1.2.4 — IT Deployment Manual

**For the IT department that hands the tool out.** What the package needs, how to configure it for your site, how to deploy it, what security policy does to it, how to verify what you received, and what to do with the reports that come back.

This manual covers the English package (the `en-US` folder). The Traditional Chinese package in the `zh-TW` folder is the same tool with its own copy of this manual and its own configuration file. The person who runs the check has the user manual beside this file (`NetworkHealthCheck_User_Manual_en-US.html`); the design, the decision rules and the known limitations are in the technical guide (`NetworkHealthCheck_Technical_Guide_en-US.md`). This manual does not repeat them: it says what IT has to decide and do.

---

## 1 · What you are deploying

**A folder, not an installer.** Network Health Check is a Windows PowerShell script with a batch launcher, a JSON configuration file and its documents. It installs no service, driver or packet-capture component and registers nothing; what it writes is its reports (section 3.1) and, when a run cannot start or finish, an error file beside the program or in the user's temporary folder (sections 3.6 and 8). It is read-only with respect to the system: it does not change IP, DNS, routes, firewall, proxy or adapter settings. Its active behaviour is a few pings, a name lookup, TCP connections and HTTP/HTTPS GET requests to the targets in the configuration file.

**What a machine needs.**

| Requirement | Detail |
|---|---|
| Windows 10 or Windows 11 (or a compatible Windows Server) | Another platform, or a PowerShell older than 5, gets a *Fail* row after the configuration rows, and the run stops there |
| Windows PowerShell 5.1 | Part of Windows. The launchers start `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`; when that file is missing they look for `pwsh.exe` (PowerShell 7) on the PATH, and stop with *PowerShell was not found on this computer* when neither exists |
| .NET Framework with Windows Forms | Part of Windows; needed for the window only. When the window cannot be created, the tool runs the same checks in text mode by itself and says so in a warning row |
| A standard user account | Administrator rights are not required. What a standard user cannot read becomes an *Unable to Check* row, and the check continues |
| A folder the user can write to | The reports go beside the program by default (section 3.1). When that folder is not writable the tool falls back to the user's temporary folder |

**Three ways in.** Each language folder holds three launchers; the two at the package root open the user entry of their language.

| Launcher | What it starts | Who uses it |
|---|---|---|
| `Start-NetworkCheck.cmd` (root: `Start-English.cmd`) | The window, which starts the check by itself | The person with the problem |
| `Start-NetworkCheck-IT.cmd` | The window with a **Run options (IT)** panel; nothing runs until Start is clicked; the HTML report opens with every detail expanded | IT at the machine |
| `Start-NetworkCheck-Console.cmd` | Text mode (`-ConsoleOnly`), pausing at the end with the report paths on screen | A machine where the window cannot open, or a remote session |

Every launcher runs PowerShell with `-NoProfile -ExecutionPolicy Bypass` and its own fixed switches, and forwards nothing typed after the `.cmd`. Section 4 says how to pass options.

**What it contacts, as shipped.** The default gateway of the machine (ping), `1.1.1.1` (ping, a TCP connection to port 443, and the first three hops of a traceroute toward it), `www.microsoft.com` (a name lookup through the operating system's resolver and one HTTPS request through the proxy Windows is set to use, following redirects). Section 3.3 says how to replace them. Nothing is uploaded: the reports are files in the report folder.

---

## 2 · Before you hand it out

1. **Verify what you downloaded** (section 6): the ZIP's SHA-256 against the release notes, then the manifest inside the package.
2. **Decide the test targets** (section 3.3). Replace the public addresses with the services your users actually need, and decide whether outbound internet is something the check should require.
3. **Set the company standards** (section 3.2) if you want the report to say whether an address, gateway, DNS server or DHCP mode is *right*. As shipped, the tool displays the current settings and says that no standard has been defined.
4. **Calibrate the thresholds** (section 3.5) against your own baselines — Wi-Fi, VPN, WAN and data-centre links do not share one set of numbers.
5. **Decide where the reports go and how they are handled** (sections 3.1 and 7). A report carries computer and user names, addresses, the Wi-Fi network, the proxy and the first-hop routers; the user manual (section 5, *What the report contains*) keeps the inventory. Decide the handling rule before the tool is in anyone's hands.
6. **Run it once on a representative machine** with `Start-NetworkCheck-IT.cmd`, read the report's first rows (section 3.6), and keep that report as a baseline. Repeat for each kind of connection you support (wired, Wi-Fi, VPN, restricted internet).
7. **Configure both language folders** if you ship both. `en-US\NetworkHealthCheck.config.json` and `zh-TW\NetworkHealthCheck.config.json` are separate files; as shipped they differ only in the display names of the default targets.

---

## 3 · The configuration file

`NetworkHealthCheck.config.json` sits beside the program. The tool reads it at every start, merges it over its built-in defaults and never writes to it — run options (section 4) change a run, not the file.

**How it is read.** A key you leave out keeps its built-in default; a key you set replaces it. Objects merge key by key, so you can give `Expected` two rules and omit the rest. Lists replace as a whole: a `PingTargets` list in the file *is* the list, and the shipped entries you do not repeat are gone. Keys the tool does not know are ignored.

**When it cannot be read.** A missing file, or one that is not valid JSON, does not stop the run: the tool uses its built-in defaults, and the report's first row — **Configuration File** — is *Unable to Check* with the reason (*Configuration file not found: …* or *The configuration file is invalid.* with the parser's message). That row alone makes the verdict **Test Incomplete**, so a broken configuration is visible in every report. A file that parses is then checked value by value (section 3.6).

**JSON rules.** Strings in double quotes; a comma between items and none after the last; `true`, `false` and `null` without quotes; no comments. The shipped file is UTF-8 with a byte-order mark and Windows line endings, which Notepad preserves; the tool reads the file with or without the mark and with either line ending, but the release validator (section 6) expects the shipped form.

**Testing a change without replacing the file.** The script accepts `-ConfigPath <file>`, so a candidate configuration can be tried from a console before it goes into the folder:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly -ConfigPath C:\Temp\candidate.config.json
```

The report's *Configuration File* row names the file that was loaded, and the *Computer and Run Information* section repeats it.

### 3.1 · Identity and the report folder

| Key | Default | What it does |
|---|---|---|
| `OrganizationName` | `""` | Printed in the HTML report's header; an empty value prints *Organization Not Specified*. The text and JSON reports do not carry it |
| `ReportFolderName` | `"Reports"` | A relative name is created beside the program (`en-US\Reports`); a rooted path — a drive letter or a UNC path — is taken as given. The folder is created when missing. When it cannot be written, the reports go to `%TEMP%\NetworkHealthCheck\Reports` and the report carries a **Startup Notice** warning row saying so, which on its own turns the verdict to Attention Required |

Each run writes three files, `NetworkHealthCheck_<yyyyMMdd>_<HHmmss>_<COMPUTERNAME>.html`, `.txt` and `.json`, UTF-8 with a byte-order mark. Names are unique for one copy of the tool at a time; nothing is deleted, so the folder grows by three files per run until someone clears it.

A rooted `ReportFolderName` on a share is the one setting that moves reports off the machine without anyone sending them: every report of every user then lands there directly, and the person is told in the report — the *Report Directory* line — but not asked. Use it deliberately, with the handling rule of section 7 in place, and make sure every user can write to it: a user who cannot gets the temporary-folder fallback instead.

### 3.2 · Company standards (`Expected`)

As shipped every rule is empty, and the report says so in an Information row: *No company standard has been defined in the configuration file. The current settings can be displayed, but compliance cannot be determined.* Fill in the rules that describe your site; leave the others empty. The comparison runs as soon as one rule is set.

```json
"Expected": {
  "AllowedIPv4Addresses": [],
  "AllowedIPv4Cidrs": ["192.168.10.0/24"],
  "AllowedPrefixLengths": [24],
  "AllowedDefaultGateways": ["192.168.10.1"],
  "RequiredDnsServers": ["192.168.10.5"],
  "DhcpEnabled": true
}
```

| Rule | Passes when | Row when it does not |
|---|---|---|
| `AllowedIPv4Addresses`, `AllowedIPv4Cidrs` (one rule) | Any IPv4 address of a primary adapter equals a listed address or falls inside a listed subnet | **IPv4 Address/Subnet** — Fail |
| `AllowedPrefixLengths` | Any current prefix length of a primary adapter is in the list | **Subnet Prefix** — Fail |
| `AllowedDefaultGateways` | Any current gateway of a primary adapter is in the list | **Default Gateway** — Fail |
| `RequiredDnsServers` | *Every* listed server appears among the DNS servers of the primary adapters (IPv6 addresses are accepted) | **DNS Servers** — Fail, naming the missing ones |
| `DhcpEnabled` (`true` / `false` / `null`) | Every primary adapter whose DHCP state is known matches the value; `null` skips the rule | **DHCP Mode** — Fail; *Unable to Check* when no adapter reports its DHCP state |

*Primary adapters* are the connected adapters that have an IPv4 address and a default gateway; when none has a gateway, every connected adapter with an IPv4 address. The values of all primary adapters are pooled before the rules run, so on a machine with a VPN or a second connection one adapter can satisfy a rule that another breaks; the technical guide (section 4.3) discusses the limit. With rules set and no usable adapter at all, the comparison is one Fail row.

### 3.3 · Test targets (`Tests`)

Four lists and one list of group names. Every target takes a display `Name` (the row's title) and a `Required` flag; TCP and HTTP targets may also carry a `Group`.

```json
"Tests": {
  "PingTargets": [
    { "Name": "Default Gateway", "Address": "AUTO_GATEWAY", "Required": true },
    { "Name": "File server", "Address": "10.0.0.20", "Required": false }
  ],
  "DnsNames": [
    { "Name": "DNS Name Resolution", "Host": "intranet.company.local", "Required": true }
  ],
  "TcpTargets": [
    { "Name": "ERP System", "Host": "erp.company.local", "Port": 443, "Required": true, "Group": "Company" }
  ],
  "HttpTargets": [
    { "Name": "Company portal", "Url": "https://portal.company.local/", "Required": false, "Group": "Company" }
  ],
  "RequiredConnectivityGroups": ["Company"]
}
```

| List | Fields | `Required` when omitted | Notes |
|---|---|---|---|
| `PingTargets` | `Name`, `Address`, `Required` | `false` | `AUTO_GATEWAY` stands for the IPv4 default gateways of the primary adapters, `AUTO_DNS` for their DNS servers — one row per address they resolve to. When a placeholder resolves to nothing, the row is Fail if required, Warning otherwise |
| `DnsNames` | `Name`, `Host`, `Required` | **`true`** | A bare string in the list is accepted and treated as required. The lookup goes through the operating system's resolver; it does not query each configured server |
| `TcpTargets` | `Name`, `Host`, `Port`, `Required`, `Group` | `false` | A TCP connection to the port, closed once it is established; the tool sends no data on it |
| `HttpTargets` | `Name`, `Url`, `Required`, `Group` | `false` | One GET through the system proxy, TLS 1.2 offered, redirects followed; a 4xx or 5xx answer still counts as reachable and keeps its status code. Use side-effect-free URLs: the target's logs will show the request |
| `RequiredConnectivityGroups` | names | — | The groups the verdict depends on |

**What a failed target does to the verdict.** The rule is the same one the run options use (section 4), and the reader of the report needs to know it:

| Target | Required | Optional |
|---|---|---|
| Ping, no reply at all | Fail | Information (ICMP may simply be blocked) |
| Ping, replies but loss or latency over a threshold | Fail at the critical threshold, Warning at the warning threshold | Warning |
| DNS name that does not resolve | Fail | **Warning** |
| TCP or HTTP target that cannot connect | Fail | Information |

An Information row never moves the verdict, so an optional TCP or HTTP target can fail in a report that reads **Overall Healthy** with *Everything passed* above it; the user manual tells the person to read those rows. Groups are how optional targets are made to count together: a group's row passes when **at least one** member succeeded, and when every member failed it is Fail for a group named in `RequiredConnectivityGroups` and Warning for any other group. A required group with no member at all — the name is listed but no target carries it — is an *Unable to Check* row (*This group has no executable test items.*), which on its own makes the verdict Test Incomplete.

**Timeouts and counts** (whole numbers; a decimal, a word or a value of zero or less is reported in the *Configuration Thresholds* row and replaced):

| Key | Default | Floor | Notes |
|---|---|---|---|
| `PingCount` | 4 | 1 | Echo requests per ping target. With four probes and the shipped 20 % critical-loss threshold, one lost reply is 25 % and severe; raise the count or the threshold if that is too sensitive |
| `PingTimeoutMs` | 1200 | 250 | Per echo request |
| `DnsTimeoutMs` | 4000 | 500 | Per name |
| `TcpTimeoutMs` | 4000 | 500 | Per connection |
| `HttpTimeoutMs` | 6000 | 500 | Per request, connect and read alike |
| `RetransmissionSampleSeconds` | 8 | 1 | The TCP counters are sampled at the start and again once this many seconds have passed, so this is the run's minimum length; the tests run inside the window and, when targets do not answer, their timeouts add up on top of it |

**A site without outbound internet.** Remove the public ping, TCP and HTTP targets, replace the `www.microsoft.com` name lookup with an internal name your resolver answers (the shipped `DnsNames` entry is required, and a name that does not resolve fails the run), replace the `Internet` group with your internal services — or remove `Internet` from `RequiredConnectivityGroups`, otherwise the group row is *Unable to Check* for want of members — and set `Checks.Traceroute` to `false`: the traceroute probes toward the first ping target that is not a placeholder, and when there is none it probes toward `1.1.1.1` regardless.

### 3.4 · Optional checks (`Checks`)

The IT diagnostics — IT-scoped rows in the collapsed section at the bottom of the report, Information when the collection succeeded and *Unable to Check* when it did not (the wireless data, the route table, the neighbour table or the traceroute could not be read), never counted in the verdict either way — can each be switched off, here or for one run in the IT panel.

| Key | Default | Collects |
|---|---|---|
| `WifiRf` | `true` | The wireless interface's SSID, BSSID, band, channel, rates and signal, parsed from `netsh wlan show interfaces` |
| `RouteTable` | `true` | The IPv4 default routes in the order Windows uses them |
| `GatewayNeighbor` | `true` | The gateway's hardware address from the neighbour (ARP) table |
| `ProxySettings` | `true` | The user's proxy settings, the WinHTTP proxy, and which proxy Windows would use for the first HTTP target (`https://www.microsoft.com/` when there is none) — the resolver is asked, no request is made |
| `Traceroute` | `true` | The first hops toward the first ping target that is not a placeholder, one second per hop |
| `TracerouteHops` | 3 | 1 to 10; anything else falls back to 3 with a warning. Three hops show where packets stop; they rarely reach a public target |
| `DriverInfo` | `true` | Driver version, date and maker of every connected physical adapter |

A flag that is not `true` or `false` disables that check and is reported.

### 3.5 · Thresholds

The defaults are generic starting points. What the rows do with them, read off the code:

| Key | Default | Rule |
|---|---|---|
| `PacketLossWarningPercent`, `PacketLossCriticalPercent` | 5, 20 | Per ping target, in this order: no reply at all → Fail if required, Information otherwise; loss ≥ critical → Fail if required, Warning otherwise; loss ≥ warning → Warning; then the latency rules |
| `LatencyWarningMs`, `LatencyCriticalMs` | 100, 250 | On the average of the replies that came back: ≥ critical → Fail if required, Warning otherwise; ≥ warning → Warning |
| `TcpRetransmissionWarningPercent`, `TcpRetransmissionCriticalPercent` | 2, 5 | Retransmitted ÷ sent segments over the sample, computer-wide, for TCPv4 and TCPv6 separately: rate ≥ critical → Fail; rate ≥ warning → Warning |
| `TcpRetransmissionCriticalCount` | 50 | Retransmitted segments in the sample: at or above it, Warning — and Fail when the rate is also at or above the warning percentage |
| `MinimumTcpSegmentsForRate` | 50 | Below this many sent segments the rate is not judged: any retransmission is a Warning, none is Information. No traffic at all is Information |
| `AdapterErrorWarningDelta`, `AdapterErrorCriticalDelta` | 1, 10 | Receive plus send errors added during the sample, per adapter: ≥ critical → Fail, ≥ warning → Warning. A virtual adapter is Information whatever its counters, and so is a physical one that carried no traffic and no errors during the sample; a counter that went backwards is a Warning |
| `AdapterDiscardWarningDelta`, `AdapterDiscardCriticalDelta` | 1, 100 | The same for discarded packets |

Percentages and milliseconds may be decimals; the counts and deltas must be whole numbers. A value that is not a number is replaced by its default and reported. A warning level above its critical level is reported and used as written for loss, latency and the retransmission percentages; for the adapter deltas the critical level is silently raised to the warning level, and a warning level below 1 becomes 1.

### 3.6 · What the report says about the configuration

A report begins with the configuration rows — Configuration File, any Startup Notice, then Configuration Validation and Thresholds — so a mistake is visible where the person cannot miss it; the Standard Configuration row sits further down, with the comparison:

| Row | Status | Meaning |
|---|---|---|
| **Configuration File** | Pass — *Loaded: <path>* | The file was read; the path is the one in use |
| **Configuration File** | Unable to Check | Missing or not valid JSON; the built-in defaults ran. Verdict Test Incomplete |
| **Configuration Validation** | Unable to Check | An invalid value: an IPv4 address, subnet, prefix, gateway or DNS server under `Expected` that does not parse, a `DhcpEnabled` that is not `true`, `false` or `null`, a TCP target without a host or with a port outside 1–65535, an HTTP target whose URL is not an absolute `http` or `https` address, a DNS entry with a blank host. The count and the offending values are in the row's details. The values are not removed: a TCP target with an invalid host or port, or a blank URL, becomes its own *Unable to Check* row when required and is skipped when optional; a DNS entry with a blank host is skipped; a malformed URL is still attempted and fails like an unreachable one; an invalid value under `Expected` never matches anything |
| **Configuration Validation** | Pass — *Configuration value format validation passed.* | Nothing to report at all. When only the thresholds row below has something to say, this row is absent |
| **Configuration Thresholds** | Warning | Present only when a count, a timeout, a threshold or a check flag had the wrong type or was out of range, or a warning level sits above its critical level; the details name each one and, for a value that was replaced, say what was used instead — an ordering warning only states the pair, because those values are used as written (section 3.5) |
| **Standard Configuration** | Information | No rule under `Expected`; the comparison rows appear once one is set |
| **Startup Notice** | Warning | A run-time condition: the report folder fell back to the temporary folder, the tool is running from inside a compressed-folder view, the window could not open and text mode was used, or an extra TCP target from the run options was ignored |

---

## 4 · Run options — the IT entry and the command line

Run options change one run and never the file. They come from two places.

**The IT panel.** `Start-NetworkCheck-IT.cmd` opens the window with **Run options (IT)** at the top and waits: *Ready - adjust the options, then select Start Test.* The fields are **Extra ping**, **Extra DNS**, **Extra TCP (host:port)**, **Extra URL**, **Ping count** and **Sample seconds**; the boxes **Wi-Fi RF**, **Traceroute** with **Traceroute hops**, **Routes**, **Gateway ARP**, **Proxy** and **Drivers** switch the optional checks for this run; **Expand details in HTML** is ticked; **Reset to config** puts every field back to the file's values. The spinners cover 1–20 pings and 1–120 seconds; a configured value above those limits widens the range so the file's value is what an untouched Start runs with.

**The switches.** The same options as parameters of the script, for a console run or a scripted one:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly -PingTarget 10.0.0.1 -TcpTarget fileserver:445 -SampleSeconds 20 -ExpandDetails
```

| Switch | Effect |
|---|---|
| `-ConsoleOnly` | Text mode; the process exits 0 when a report was written, 1 when none could be |
| `-Interactive` | The window with the IT panel, not started automatically (what the IT launcher passes) |
| `-ExpandDetails` | Every *Show Details* open in the HTML; also marks the run as an IT-entry run |
| `-PingTarget`, `-DnsName`, `-TcpTarget` (host:port) | Extra targets. Several values as one comma-separated list — `-PingTarget 10.0.0.1,10.0.0.2` — which works from cmd.exe (`powershell -File …`) and at a PowerShell prompt alike; inside a quoted value they may also be separated by spaces or semicolons (`-PingTarget "10.0.0.1 10.0.0.2"`). See the note below the table |
| `-HttpUrl` | Extra URLs. Several as one quoted, space-separated value — `-HttpUrl "https://a.company.local/ https://b.company.local/"` — which works from both shells. The script splits URLs on spaces only, because commas and semicolons are legal inside a URL, so `u1,u2` from cmd.exe is one invalid URL; at a PowerShell prompt a comma makes an array and works. See the note below the table |
| `-PingCount`, `-SampleSeconds`, `-TracerouteHops` | Override the file's values for this run; hops outside 1–10 fall back to 3 |
| `-NoTraceroute`, `-NoWifi` | Skip those two diagnostics |
| `-ConfigPath <file>` | Load another configuration file (section 3) |
| `-STA` (PowerShell's own switch) | What the window launchers add; not needed for `-ConsoleOnly` |

**Two forms to avoid.** A second value after a bare space — `-PingTarget a b`, `-HttpUrl u1 u2` — is not a second target: PowerShell binds it to the script's first positional parameter, `-ConfigPath`, so the run loads no configuration (*Configuration file not found: b*, an *Unable to Check* row, built-in defaults, verdict Test Incomplete) and tests the first value only; measured from cmd.exe and from a PowerShell prompt. And at a PowerShell prompt an unquoted semicolon ends the statement — `-PingTarget a;b` tests `a` and then tries to run `b` as a command — while cmd.exe passes it through. The comma-separated and the quoted forms above avoid both.

**What an extra target counts for.** Extra targets are optional and belong to no group: an extra ping that gets no reply, and an extra TCP or HTTP target that cannot connect, are Information rows and leave the verdict alone; a degraded ping and an extra DNS name that does not resolve are Warning rows. An extra TCP target that is not `host:port` is dropped with a Startup Notice warning (*Ignored extra TCP target '…': expected host:port.*). The rows are titled *Extra ping*, *Extra DNS*, *Extra TCP* and *Extra URL*.

**Where a run's options are recorded.** In the report header's *Run profile* line — `IT entry | extra targets: ping 10.0.0.1, tcp fileserver:445 | ping count 4 | sample 20 s | traceroute 3 hops`, with `disabled: …` for switched-off checks — and in the JSON under `RunOptions`: `EntryPoint`, `ExpandDetails`, `ExtraTargets` (the values accepted), `RawTargets` (as typed), `PingCount`, `SampleSeconds`, `TracerouteHops`, `ChecksEnabled`.

---

## 5 · Deploying

**Ship the whole folder.** Every language launcher looks for `NetworkHealthCheck.ps1` beside itself and stops when it is missing; the script looks for its configuration beside itself and runs on defaults when it is missing. A language folder — `en-US` or `zh-TW` — is complete on its own: launchers, program, configuration, this manual, the user manual and the technical guide. The two root launchers (`Start-English.cmd`, `Start-Traditional-Chinese.cmd`) only call into a folder of that exact name, so keep the folder names when you ship them, and leave them out when you ship one language.

**Do not rename the program or the configuration file.** The launchers and the script find them by name.

**Two ways it arrives, and what the person sees.**

- *A ZIP downloaded with a browser* carries the Mark of the Web; the files Windows Explorer extracts from it carry the same mark, and a double-click on a launcher shows **Open File - Security Warning**, after which the tool runs. Unblocking the ZIP before extracting (right-click → Properties → Unblock, or `Unblock-File` in PowerShell) leaves the extracted files without the mark. Both were measured on two virtual machines (the validation record, `VALIDATION.md`, *Acceptance on a second machine*).
- *A package that arrives without a browser* — pushed by a distribution tool, or copied in, as the campaign's copy from its host was — carried no mark on the machines measured, and no prompt appears.

Whichever way it arrives, the person must extract the whole ZIP: a launcher double-clicked inside Explorer's ZIP view finds nothing beside itself and stops (the user manual, sections 2 and 6).

**Where to put it.** Any local folder the user can write to — the Desktop or Documents are what the user manual suggests, and where the acceptance runs were made. The folder must stay writable if the reports are to land beside the program; otherwise set `ReportFolderName` (section 3.1) or expect the temporary-folder fallback.

**Upgrading.** Replace the folder with the new version and carry your configuration file over. The file's version does not matter to the tool: a key the new version added takes its default when your file does not have it. Compare the shipped file with yours after an upgrade and run one check (section 3.6) before the new folder goes out. Keep your edited configuration under version control; the package cannot tell your edits from the shipped file except by their hash (section 6).

**The program file.** Configure; do not edit the script. An edited script no longer matches the manifest, and the two language versions are checked against each other by the validator (section 6), so a change in one folder alone fails it. If a change is really needed, keep the original, re-run the validator knowing which checks you expect to fail, and record your own digests. The scripts are not digitally signed (section 8, *Signing*).

---

## 6 · Verifying the package

**The download.** The release notes on the project's Releases page give the SHA-256 of `NetworkHealthCheck-<version>.zip`. Compare before extracting:

```text
certutil -hashfile NetworkHealthCheck-1.2.4.zip SHA256
```

or in PowerShell `Get-FileHash NetworkHealthCheck-1.2.4.zip`. The asset is built from the repository's tracked files only, so it contains no report and no other output of a run.

**The manifest.** `SHA256SUMS.txt` at the package root lists the digest of every shipped file except itself, `VALIDATION.md` and `validation-matrix.html` — one line per file, `<sha256>  <relative path>` with two spaces. Check one file by hand with `Get-FileHash <file>`, or all of them with the validator.

**The validator.** `tools\validate_release.py` needs Python 3 and nothing else. Run it against the package root:

```text
python tools\validate_release.py .
```

It prints one `[PASS]` or `[FAIL]` line per check and ends with `Summary: N passed, M failed`, exit code 1 when anything failed. What it checks: the required files exist; both configuration files parse; the scripts and configurations are UTF-8 with a byte-order mark and Windows line endings; the six language launchers reference the program; the English and Chinese scripts are the same program apart from their text (the same functions, the same executable skeleton); the English files carry no Chinese text; the version string in both scripts and in every document that names one; the packaged validation record has this version's entry; and every manifest line. It runs no network check and does not need Windows.

**After you have edited the configuration** the manifest line for that file fails, in the validator and in a hand check, and nothing else changes as long as the file is still valid JSON in the shipped form (section 3). That one failure is the expected signature of a configured package; a failure on any other line means a file was altered or damaged in transit.

**The record.** `VALIDATION.md` is the validation record of every release — what was run, on which machines, what was found and what was deferred — and `validation-matrix.html` an earlier release's fault-scenario matrix. The validation chain itself, including the acceptance runner for a machine with nothing but Windows PowerShell, is in the repository's `tests` folder.

---

## 7 · The reports

**Where they land and what they are named** — section 3.1. **What they contain** — the user manual, section 5, keeps the inventory: identity and versions, every connected adapter's addresses and hardware addresses, the Wi-Fi network and access point, routes, the gateway's hardware address, the proxy settings, your configured standards and targets, every result with its timings, and the paths of the configuration file and the report folder (which can include the user's profile folder). The JSON alone also carries the technical details of any error the tool met, naming the program's folder.

**Decide the handling rule before rollout** — where a report may be sent, how long it is kept, who reads it — and tell the person in the same message that sends them the tool; the user manual says only that the person should handle it as the company's rules say. Reports are ordinary files: retention is whatever you apply to the report folder (or to the share, section 3.1).

**For your tools.** The JSON report is schema 2: `SchemaVersion`, `ToolVersion`, `RunOptions` (section 4), `Fingerprint` (`Key`, `Title`, `Lines` — the *What to tell IT* section), `Overall` (`Code`, `Text`, `Description`), `Counts`, `System`, `StartedAt`, `FinishedAt`, and `Results`, one object per row with `Time`, `Category`, `Check`, `Status` (`PASS`, `WARN`, `FAIL`, `INFO`, `ERROR`), `Message`, `Details`, `Diagnostics`, `Tag` and `Scope` (`Main` or `IT`). `Tag` is the language-neutral name of the check (`ping-gateway`, `dns`, `connectivity-group`, `tcp-retransmissions`, `expected-standard`, …); the technical guide (section 4.10) lists them, and the `Scope` tells you which rows the verdict ignores.

**Reading them.** The user manual explains the verdicts, the *What to tell IT* titles and the badges; the technical guide explains each rule. The repository's `sop` folder holds a support engineer's field manual and a report template for turning a report into a hand-off.

---

## 8 · Security policy: what blocks it, and what the person sees

The launchers set the execution policy for their own process (`-ExecutionPolicy Bypass`), which is enough on a machine without policy. Where there is policy, this is what happens — each line measured on the project's virtual machines and recorded in `VALIDATION.md`, unless marked otherwise:

| Mechanism | What happens | What reaches IT |
|---|---|---|
| **Mark of the Web** on a downloaded ZIP | *Open File - Security Warning* on the launcher; the tool runs after *Run* | Nothing — unless the person cancels |
| **Execution policy set by Group Policy** (`MachinePolicy` / `UserPolicy`, e.g. *AllSigned*) | Overrides the launcher's process-scope Bypass: the script does not start. PowerShell prints *…NetworkHealthCheck.ps1 is not digitally signed. You cannot run this script on the current system…*, the launcher reports the non-zero exit code and pauses, `LauncherError.txt` says to read the message above and ask IT to allow the program | `LauncherError.txt` and the console text. No environment report: the script never ran |
| **PowerShell restricted to a limited language mode** — what an enforced application-control policy (WDAC) does to a script it does not allow, and what `__PSLockdownPolicy` does to every script | The script's first lines detect a mode other than *FullLanguage* and stop before any check: exit code 3, the reason on the console, and `NetworkHealthCheck_ENVIRONMENT_<time>.txt` beside the program (or in `%TEMP%`, when that folder cannot be written or is a compressed-folder view) naming the reason, the mode, the tool version, the computer, the user, the program's folder, the PowerShell version, the culture and the operating system, and two lines under *What IT can do*: allow `NetworkHealthCheck.ps1` in the application-control policy (WDAC / AppLocker), or run the check on a computer that is not restricted in this way. The launcher explains exit code 3 and points at that file. Measured with `__PSLockdownPolicy` on both machines; no WDAC-enforced machine has been measured | The environment report and `LauncherError.txt` |
| **AppLocker script rules** | Not measured to take effect: the one machine that reported an enforcing policy denying the script ran it unrestricted (backlog #31 in `VALIDATION.md`). Whether an enforced rule refuses the script or runs it in the restricted mode above has not been observed | Whichever of the two files above the outcome produces |
| **EDR or antivirus** blocking `powershell.exe` or the script | Not measured: no machine with such a product was part of the acceptance runs. The launcher reports whatever exit code it gets and writes `LauncherError.txt` | `LauncherError.txt` and the product's own record |

**What to ask the person for** is in the user manual's section 6, row by row; the environment report and `LauncherError.txt` are written for exactly this hand-off. `LauncherError.txt` sits beside the launcher, or — when that folder cannot be written — in `%TEMP%` as `NetworkHealthCheck_LauncherError.txt` with fewer fields.

**Allowing the tool.** The two scripts are unsigned, so a policy that allows by publisher has nothing to match; what an IT department has today is the hash: `SHA256SUMS.txt` gives the digest of each `NetworkHealthCheck.ps1`, and a WDAC or AppLocker rule can allow that hash. A new version means a new hash. Which Windows builds and editions enforce AppLocker, and what has and has not been observed, changes faster than this package: the repository keeps a page on it, at the version this manual belongs to — <https://github.com/kevintechin/network-support-toolkit/blob/v1.2.4/docs/application-control.md> — and its current version on the `main` branch.

**Signing.** An Authenticode signature from your own certificate authority would satisfy an *AllSigned* policy and let a rule allow by publisher. Signing appends a signature block to the script, so the signed file no longer matches `SHA256SUMS.txt`; record the signed files' digests yourself.

---

## 9 · The files in the package

| File or folder | What it is |
|---|---|
| `Start-English.cmd`, `Start-Traditional-Chinese.cmd` | Root launchers: the user entry of each language |
| `README_BILINGUAL.md` | The package's front page |
| `SHA256SUMS.txt`, `tools\validate_release.py` | The manifest and the validator (section 6) |
| `VALIDATION.md`, `validation-matrix.html` | The validation record, and an earlier release's scenario matrix |
| `docs\` | The technical guide in both languages |
| `en-US\`, `zh-TW\` | One complete package per language: |
| `…\Start-NetworkCheck.cmd`, `-IT.cmd`, `-Console.cmd` | The three launchers (section 1) |
| `…\NetworkHealthCheck.ps1` | The program |
| `…\NetworkHealthCheck.config.json` | The configuration (section 3) — the one file you edit |
| `…\NetworkHealthCheck_User_Manual_*.md`, `.html` | The user manual, for the person who runs the check |
| `…\NetworkHealthCheck_IT_Deployment_Manual_*.md`, `.html` | This manual |
| `…\NetworkHealthCheck_Technical_Guide_*.md` | The technical guide, both languages again |
| `…\Reports\` | Created at the first run (section 3.1) |

---

## 10 · Related documents

- **User manual** — `NetworkHealthCheck_User_Manual_en-US.html` (or `.md`): what the person sees, the verdicts and badges, what the report contains, what to do when it does not run.
- **Technical guide** — `NetworkHealthCheck_Technical_Guide_en-US.md`: design, every decision rule, the validation approach, known limitations, the version history.
- **Validation record** — `VALIDATION.md`: every release's evidence, the acceptance runs on other machines, the backlog.
- **The repository** — <https://github.com/kevintechin/network-support-toolkit>: releases, the validation chain (`tests`), the support engineer's field manual and report template (`sop`), and the application-control page named in section 8.

---

*NetworkHealthCheck 1.2.4. This manual describes the tool as shipped and the behaviour measured for this release; the rules quoted here are the code's, and the technical guide states them in full.*
