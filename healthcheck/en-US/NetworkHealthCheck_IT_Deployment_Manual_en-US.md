# Network Health Check 1.2.14 — IT Deployment Manual

**For the IT department that hands the tool out.** What the package needs, how to configure it for your site, how to deploy it, what security policy does to it, how to verify what you received, and what to do with the reports that come back.

This manual covers the English package (the `en-US` folder). The Traditional Chinese package in the `zh-TW` folder is the same tool with its own copy of this manual and its own configuration file. The person who runs the check has the user manual beside this file (`NetworkHealthCheck_User_Manual_en-US.html`); the design, the decision rules and the known limitations are in the technical guide (`NetworkHealthCheck_Technical_Guide_en-US.md`). This manual does not repeat them: it says what IT has to decide and do.

---

## 1 · What you are deploying

**A folder, not an installer.** Network Health Check is a Windows PowerShell script with a batch launcher, a JSON configuration file and its documents. It installs no service, driver or packet-capture component and registers nothing; what it writes is its reports (section 3.1) and, when a run cannot start or finish, an error file beside the program or in the user's temporary folder (sections 3.6 and 8). It is read-only with respect to the system: it does not change IP, DNS, routes, firewall, proxy or adapter settings. Its active behaviour is a few pings, a name lookup, TCP connections and HTTP/HTTPS GET requests to the targets in the configuration file. The one thing it compiles is a few lines of P/Invoke for the wireless retry counters (section 3.4), built in memory at run time and leaving nothing on disk.

**What a machine needs.**

| Requirement | Detail |
|---|---|
| Windows 10 or Windows 11 (or a compatible Windows Server) | Another platform, or a PowerShell older than 5, gets a *Fail* row after the configuration rows, and the run stops there |
| Windows PowerShell 5.1 | Part of Windows. The launchers start `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`; when that file is missing they look for `pwsh.exe` (PowerShell 7) on the PATH, and stop with *PowerShell was not found on this computer* when neither exists |
| .NET Framework with Windows Forms | Part of Windows; needed for the window only. When the window cannot be created, the tool runs the same checks in text mode by itself, says so in a warning row and, started from a window launcher, keeps that window open until a key is pressed so that the report paths can be read (1.2.14) |
| A standard user account | Administrator rights are not required. What a standard user cannot read becomes an *Unable to Check* row, and the check continues |
| A folder the user can write to | The reports go beside the program by default (section 3.1). When that folder is not writable the tool falls back to the user's temporary folder |

**Three ways in.** Each language folder holds three launchers; the two at the package root open the user entry of their language.

| Launcher | What it starts | Who uses it |
|---|---|---|
| `Start-NetworkCheck.cmd` (root: `Start-English.cmd`) | The window, which starts the check by itself | The person with the problem |
| `Start-NetworkCheck-IT.cmd` | The window with a **Run options (IT)** panel; nothing runs until Start is clicked; the HTML report opens with every detail expanded | IT at the machine |
| `Start-NetworkCheck-Console.cmd` | Text mode (`-ConsoleOnly`), pausing at the end with the report paths on screen | A machine where the window cannot open, or a remote session |

Every launcher runs PowerShell with `-NoProfile -ExecutionPolicy Bypass` and its own fixed switches, and forwards nothing typed after the `.cmd`. Section 4 says how to pass options.

**What it contacts, as shipped.** The default gateway of the machine (ping), `1.1.1.1` (ping, `PingCount` TCP connections to port 443 — four as shipped, one in earlier versions — and the first three hops of a traceroute toward it), `www.microsoft.com` (a name lookup through the operating system's resolver and one HTTPS request through the proxy Windows is set to use, following redirects). Section 3.3 says how to replace them. No near-end host as shipped: `NearEndTarget` is empty until you name one (section 3.3). Nothing is uploaded: the reports are files in the report folder.

---

## 2 · Before you hand it out

1. **Verify what you downloaded** (section 6): the ZIP's SHA-256 against the release notes, then the manifest inside the package.
2. **Decide the test targets** (section 3.3). Replace the public addresses with the services your users actually need, and decide whether outbound internet is something the check should require. If the users' subnet has a stable host that answers ping - a printer, a file server on the same floor - name it as the near-end host, so that the report can tell the local path from the gateway.
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

Each run writes up to three files, `NetworkHealthCheck_<yyyyMMdd>_<HHmmss>_<COMPUTERNAME>.html`, `.txt` and `.json`, UTF-8 with a byte-order mark. Each format is written on its own: one that cannot be written is reported — the window says *N of 3 report formats could not be written*, the console lists it as *(not written)* — and the others stay usable; only when all three fail does the tool write an emergency `NetworkHealthCheck_FATAL_<time>.txt` instead. Names are unique for one copy of the tool at a time; nothing is deleted, so the folder grows by up to three files per run until someone clears it.

A rooted `ReportFolderName` on a share is the one setting that moves reports off the machine without anyone sending them: every report of every user then lands there directly, and the person is told in the report — the *Report Directory* line — but not asked. Use it deliberately, with the handling rule of section 7 in place, and make sure every user can write to it: a user who cannot gets the temporary-folder fallback instead. It is the one *setting* that does this: a report folder that merely happens to sit inside a cloud-synced folder does the same thing without anyone choosing it, which is what section 5, *Where to put it*, is about.

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

Four lists, one near-end host and one list of group names. Every target takes a display `Name` (the row's title) and a `Required` flag; TCP and HTTP targets may also carry a `Group`.

```json
"Tests": {
  "PingTargets": [
    { "Name": "Default Gateway", "Address": "AUTO_GATEWAY", "Required": true },
    { "Name": "File server", "Address": "10.0.0.20", "Required": false }
  ],
  "NearEndTarget": { "Name": "Floor printer", "Address": "10.0.0.7", "Required": false },
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
| `NearEndTarget` | `Name`, `Address`, `Required` | `false` | One object, not a list: the near-end rung of the ping ladder - an IPv4 address in dotted-decimal form on the users' own subnet that is not the gateway, pinged first. Empty as shipped; see *The near-end rung* below. A name, a placeholder, the gateway, one of this computer's own addresses, a subnet's network or broadcast address, or an address outside the machine's subnets is not probed, and the row says why; marked required with no address, it is a required check that did not run |
| `DnsNames` | `Name`, `Host`, `Required` | **`true`** | A bare string in the list is accepted and treated as required. The lookup goes through the operating system's resolver; it does not query each configured server |
| `TcpTargets` | `Name`, `Host`, `Port`, `Required`, `Group` | `false` | A TCP connection to the port, closed once it is established; the tool sends no data on it |
| `HttpTargets` | `Name`, `Url`, `Required`, `Group` | `false` | One GET through the system proxy, TLS 1.2 offered, redirects followed; a 4xx or 5xx answer still counts as reachable and keeps its status code. Use side-effect-free URLs: the target's logs will show the request |
| `RequiredConnectivityGroups` | names | — | The groups the verdict depends on |

**The near-end rung (`NearEndTarget`).** As shipped the ping ladder has two rungs, the gateway and `1.1.1.1`, and each rung includes everything before it: the gateway's probes cross the adapter, the cable or Wi-Fi link and the switch or access point and are answered by the gateway's own control plane; the public target's cross all of that, the gateway and the WAN. A **near-end host** adds the rung before the gateway - a host on the users' own subnet that is not the gateway, answered by an ordinary IP stack - so that the local path is measured on its own, with neither the gateway's control plane nor the WAN in the figure. The report then reads as a ladder, and the *Gateway does not answer* summary says which side of the gateway the fault is on (section 7). **Choosing one.** The tool cannot choose it, because whether a candidate is a stable host that answers ICMP is your judgement: a printer, a file server or a NAS on the same VLAN as the users, given by its IPv4 address. The report's adapter rows name the DHCP server that answered the lease; it is a candidate only if it is an ordinary host on that subnet and not the gateway itself, which on a small network it usually is. **The gateway cannot serve as it** - it is the next rung already, and it answers pings from its control plane, which devices commonly rate-limit - so an address that is one of the machine's default gateways is refused before anything is sent, and so are this computer's own addresses (a ping to them is answered by its own stack and crosses no cable, radio or switch) and a subnet's network or broadcast address; so is a name (the rung has to be placed before the probes go, and a name would put it behind the resolver), and so is any spelling other than four decimal numbers with dots - a single number, hexadecimal parts, leading zeros - because different parsers read those as different addresses and the probe has to go to the address the file names; an address outside every subnet the primary adapters are on is reported as not probed (a laptop at home with the office file: the row says so, sends nothing and counts for nothing; a required one adds the *did not run* row every required target adds). A required near-end target with no address is reported the same way - a required check that did not run - rather than silently skipped; only an optional one with no address is the disabled state the file ships in. **The row claims the rung only when it can.** The probes are sent unbound, so the row reads the route table's selection before and after them - the *Route selection* line every ping row carries - and claims the local path only where both selected an address on the target's subnet with no next hop - an on-link route, not one through a router; where a VPN, a second connection or a more specific route was selected instead, or the selection changed, or the lookup was unavailable, the row says so, counts as an ordinary ping target and is not read by the summary as a near-end witness. The gateway row claims its rung on the same terms - a selection on the subnet of the adapter that supplied that gateway - and otherwise says it cannot, while the gateway stays the target the row measured. **Reading the rungs.** A rung that passes clears what it crossed, at that moment; the first rung that fails puts the problem beyond the last rung that passed, and no closer than that. The figures of two rungs are separate traffic sent at separate moments, so **they may never be subtracted into a loss figure for the segment between them** - 3 % to the public address and 0 % to the gateway is not 3 % in the WAN - and the tool computes no such figure, nor any per-hop loss from TTL-limited probes, whose replies come from rate-limited control planes and show loss at hops that forward perfectly. The three-way comparison that separates wireless from wired - a wired and a wireless client against the same local host, then both against the same external target - needs a second machine and a source-bound probe, and lives in the repository's SOP rather than in a tool that runs on one machine. **Cost.** One more ping target: `PingCount` probes, continued like any other where replies are lost (the loss rules below apply unchanged), so a healthy run is longer by well under a second and a silent host costs `PingCount` × `PingTimeoutMs` - 4.8 s as shipped.

**What a failed target does to the verdict.** The rule is the same one the run options use (section 4), and the reader of the report needs to know it:

| Target | Required | Optional |
|---|---|---|
| Ping, no reply at all | Fail | Information (ICMP may simply be blocked) |
| Ping, replies but loss or latency over a threshold | Fail at the critical threshold, Warning at the warning threshold | Warning |
| DNS name that does not resolve | Fail | **Warning** |
| TCP or HTTP target that cannot connect | Fail | Information |

**A loss verdict that would rest on one packet is withheld (backlog #51).** Where the sample is smaller than the count the warning threshold needs **and** the classification would be a different one had one fewer reply been lost, the row keeps every number it measured, is marked weightless and leaves the verdict alone. Three lost of four still fails a required target — 75 %, and two lost is still 50 %, so nothing there rests on one packet — A target that answered nothing at all is judged by the same rule and passes it at the shipped count — three lost of four is still critical — so only a whole sample of one probe has that verdict withheld, which is why `PingCount` 1 no longer fails a required target on a single timeout. This qualifies the loss rules of section 3.5 and nothing else: a latency threshold reached on the replies that did arrive is a measurement, and a row that reaches one keeps its weight.

An Information row never moves the verdict, so an optional TCP or HTTP target can fail in a report that reads **Overall Healthy** with *Everything passed* above it; the user manual tells the person to read those rows. Groups are how optional targets are made to count together: a group's row passes when **at least one** member succeeded, and when every member failed it is Fail for a group named in `RequiredConnectivityGroups` and Warning for any other group. A required group with no member at all — the name is listed but no target carries it — is an *Unable to Check* row (*This group has no executable test items.*), which on its own makes the verdict Test Incomplete.

**Timeouts and counts** (whole numbers; a decimal, a word or a value of zero or less is reported in the *Configuration Thresholds* row and replaced):

| Key | Default | Floor | Notes |
|---|---|---|---|
| `PingCount` | 4 | 1 | Echo requests per ping target **to begin with**. This is a starting count, where earlier versions sent a fixed one: where some replies are lost but not all, the sample continues up to `PingCountMaximum`; where every reply arrives, and where none does, nothing more is sent. It is also the number of TCP connections made to a TCP target that answers — the first, then `PingCount` − 1 more to the address it reached, timed one by one, each socket's own count of the SYNs it had to send again read with it on Windows 10 version 1703 / Windows Server 2016 or later, an older build reading the times against the initial retransmission timeout instead, as a stand-in (backlog #52); they decide nothing, and a target that does not answer is connected to once |
| `PingCountMaximum` | 21 | `PingCount` | The furthest a continued sample goes for one ping target. **The tool computes the count it needs and this value only caps it**, so it does not have to be set to that count. 21 is the smallest count at which one lost reply is below the shipped 5 % warning threshold **as the row prints it** — the printed figure is rounded to one decimal, so 100 ÷ 21 prints as 4.8 % while 20 is exactly 5 % and still warns; a calibrated threshold moves it, and at 4.8 % the count is 22 rather than 21. A value below `PingCount` is reported in the *Configuration Thresholds* row and the starting count is used as the ceiling. There is no upper limit: the IT panel's two ping spinners open at this value, so raising it raises them |
| `PingTimeoutMs` | 1200 | 250 | Per echo request |
| `DnsTimeoutMs` | 4000 | 500 | Per name |
| `TcpTimeoutMs` | 4000 | 500 | Per connection — and a target that answers gets `PingCount` connections, one after another, stopping at the first that fails (backlog #52), so a target that answers costs `PingCount` − 1 more handshakes — milliseconds on the reference machine — and a target that stops answering costs at most one more timeout; a target that never answers still costs one |
| `HttpTimeoutMs` | 6000 | 500 | Per request, connect and read alike |
| `RetransmissionSampleSeconds` | 8 | 1 | The TCP counters are sampled at the start and again once this many seconds have passed, so this is the run's minimum length; the tests run inside the window and, when targets do not answer, their timeouts add up on top of it; the wireless retry counters (section 3.4) are sampled over the same window |
| `RetransmissionIntervalSeconds` | 2 | 0 | The counters are read again inside the sample window at least this many seconds apart — from the run's own thread, between its steps and inside its waits — so that a row which counted retransmissions can say where inside the window they fell: the intervals, and the one that held the most with its share of the count and of the time (1.2.14, backlog #65); 0 switches these reads off. The cost on the reference machine is about 0.1 s per read, most of it inside the wait the run sleeps through anyway; a read inside the window that runs out of its eight seconds ends these reads for that run, so the worst case is one timeout per run, named on the row. The figures place retransmissions in time and decide nothing. Not in the IT panel and no switch: a site property, set once in this file |

**A site without outbound internet.** Remove the public ping, TCP and HTTP targets, replace the `www.microsoft.com` name lookup with an internal name your resolver answers (the shipped `DnsNames` entry is required, and a name that does not resolve fails the run), replace the `Internet` group with your internal services — or remove `Internet` from `RequiredConnectivityGroups`, otherwise the group row is *Unable to Check* for want of members — and set `Checks.Traceroute` to `false`: the traceroute probes toward the first ping target that is not a placeholder, and when there is none it probes toward `1.1.1.1` regardless.

### 3.4 · Optional checks (`Checks`)

The IT diagnostics — IT-scoped rows in the collapsed section at the bottom of the report, never counted in the verdict — can each be switched off, here or for one run in the IT panel. An Information row there carries what was collected, or says that there was nothing to collect or that the source is not on this machine (no connected wireless interface or no `netsh.exe`, no `Get-NetRoute`, no default route or no gateway, no connected physical adapter); an *Unable to Check* row means that reading the source threw an error (the wireless data, the route table, the neighbour table or the traceroute). Since 1.2.14 `WifiRf` also governs the three access-point samples and the *Wi-Fi association* row they produce, and the `GatewayNeighbor` row compares the gateway's address with the access point's (see the two rows). `WifiRetryCounters` below is the exception: it switches a measurement in the main report, not an IT diagnostic — see its row.

| Key | Default | Collects |
|---|---|---|
| `WifiRf` | `true` | The wireless interface's SSID, BSSID, band, channel, rates and signal, parsed from `netsh wlan show interfaces`; and, since 1.2.14, the same command read before the first measurement and after the last as well, so that the *Wi-Fi association* row — IT-scoped, one Information row per wireless interface netsh listed — can say whether each interface stayed on one access point during the run: a roam under the same SSID, another network, or no BSSID reported, never called disconnected. A machine that listed no interface gets one row saying so, and every read failing gets an *Unable to Check* row; a roam out and back between two samples is invisible, and the row says so. The interface list and the connection state come from the WLAN service (backlog #62), through the same in-memory P/Invoke reader as `WifiRetryCounters` — compiled once per process, about 0.7 s, by whichever of the two runs first — and where `netsh wlan show interfaces` prints no interface because desktop programs may not use the location (Windows 11 24H2 and later; Settings > Privacy & security > Location) the row still reports the connected interface, with the network name, access point, signal and rates marked not reported and the setting named where the consent store shows the denial (an access-denied without that witness is reported as such, cause unidentified); allow desktop apps the location on machines where those fields matter. Off here or with `-NoWifi`: no radio row, no samples, no association row |
| `WifiRetryCounters` | `true` | Not an IT diagnostic: the wireless adapter's 802.11 retry counters over the run, read through the Native Wifi API by a few lines of P/Invoke compiled in memory at run time (about 0.7 s once per process, nothing written to disk) and written into the main report as an Information row that decides nothing — frames sent again over frames tried, with the frames abandoned after the retry limit, one row per wireless interface the machine has. Where the reader cannot be compiled or loaded, the WLAN service does not answer or there is no wireless interface, one weightless row says so, and an interface that appeared or disappeared during the run gets a weightless *Unable to Check* row of its own. No panel box and no parameter: it is switched here only |
| `RouteTable` | `true` | The IPv4 default routes in the order Windows uses them |
| `GatewayNeighbor` | `true` | The gateway's hardware address from the neighbour (ARP) table; since 1.2.14 compared with the BSSID of the wireless interface whose adapter supplied the gateway, the result a line on the row — one device, probably one device, the same maker, or two devices — a hint, never a topology claim; no line where the gateway's adapter is wired or `WifiRf` is off |
| `ProxySettings` | `true` | The user's proxy settings, the WinHTTP proxy, and which proxy Windows would use for the first HTTP target (`https://www.microsoft.com/` when there is none) — the resolver is asked, no request is made |
| `Traceroute` | `true` | The first hops toward the first ping target that is not a placeholder, one second per hop |
| `TracerouteHops` | 3 | 1 to 10; anything else falls back to 3 with a warning. Three hops show where packets stop; they rarely reach a public target |
| `DriverInfo` | `true` | Driver version, date and maker of every connected physical adapter |

A flag that is not `true` or `false` disables that check; a value of another type is reported in the Thresholds row, a `null` is not — the check is simply off.

### 3.5 · Thresholds

The defaults are generic starting points, and each of them is an **operational default with no external basis**: no standard, measurement or recorded decision stands behind any value in this table, which was established and written down on 2026-09-10 (backlog #56) so that nobody has to infer a provenance the repository does not have. Two of the values are a policy rather than a magnitude — `AdapterErrorWarningDelta` and `AdapterDiscardWarningDelta` are 1 because *any at all is worth showing* — and the rest are magnitudes somebody chose. The standards that exist define how to measure, or set objectives for a named service class over a named scope, never a general fault threshold; what was examined, with each source and the date it was checked, is on the repository's threshold page at the version this manual belongs to: <https://github.com/kevintechin/network-support-toolkit/blob/v1.2.14/docs/thresholds.md>. Calibrate them against your own baselines (section 2) rather than reading them as engineering values. What the rows do with them, read off the code:

| Key | Default | Basis | Rule |
|---|---|---|---|
| `PacketLossWarningPercent`, `PacketLossCriticalPercent` | 5, 20 | Two chosen magnitudes; no external basis | Per ping target, in this order: no reply at all → Fail if required, Information otherwise; loss ≥ critical → Fail if required, Warning otherwise; loss ≥ warning → Warning; then the latency rules. The warning percentage also decides how far a continued sample goes (`PingCountMaximum`, section 3.3) and when a loss verdict is withheld for resting on one packet |
| `LatencyWarningMs`, `LatencyCriticalMs` | 100, 250 | Two chosen magnitudes; no external basis — the published delay figures nearby are one-way or mouth-to-ear bounds for public IP networks over a minute, not a round-trip average over a few echoes on a LAN | On the average of the replies that came back: ≥ critical → Fail if required, Warning otherwise; ≥ warning → Warning |
| `TcpRetransmissionWarningPercent`, `TcpRetransmissionCriticalPercent` | 2, 5 | Two chosen magnitudes; no external basis | Retransmitted ÷ sent segments over the sample, computer-wide, for TCPv4 and TCPv6 separately — *sent* being the `Segments Sent/sec` counter: every segment this computer sent, acknowledgements included, segments carrying only retransmitted bytes excluded, so the percentage is the tool's own and not comparable with a published retransmission rate (backlog #57): rate ≥ critical → Fail; rate ≥ warning → Warning |
| `TcpRetransmissionCriticalCount` | 50 | A chosen magnitude; no external basis | Retransmitted segments in the sample: Fail **when the rate is also at or above the warning percentage**. It no longer warns on its own, as it did in earlier versions — it sharpens a verdict the rate has already reached and never creates one, because above `TcpRetransmissionCriticalCount ÷ TcpRetransmissionWarningPercent` sent segments (2 500 at the shipped values) all it added was a warning on a rate below the tool's own warning threshold |
| `MinimumTcpSegmentsForRate` | 50 | A chosen magnitude; no external basis — and it is `100 ÷ TcpRetransmissionWarningPercent`, so at this floor one retransmission is the warning threshold itself, which is why the floor below exists | Below this many sent segments the rate is not judged: any retransmission is Information that decides nothing (a Warning in earlier versions), none is Information too. No traffic at all is Information. A sample that ends below this floor **with** a retransmission in it has its window extended once and is read again |
| `MinimumTcpRetransmissionsForVerdict` | 5 | Chosen with its reasoning recorded (backlog #51); no external basis | Retransmissions needed before a rate becomes a verdict. Fewer than this at or above the warning percentage is Information with its numbers and decides nothing: at fifty sent segments one retransmission is 2 %, the warning threshold itself, and three are 6 %. It suppresses nothing above two hundred sent segments at the shipped values |
| `AdapterErrorWarningDelta`, `AdapterErrorCriticalDelta` | 1, 10 | 1 is a policy — *any at all is worth showing* — and 10 a chosen magnitude; no external basis for either | Receive plus send errors added during the sample, per adapter: ≥ critical → Fail, ≥ warning → Warning. A virtual adapter is Information whatever its counters, and so is a physical one that carried no traffic and no errors during the sample; a counter that went backwards is a Warning |
| `AdapterDiscardWarningDelta`, `AdapterDiscardCriticalDelta` | 1, 100 | 1 is the same policy, 100 a chosen magnitude; no external basis for either | The same for discarded packets |

Percentages and milliseconds may be decimals; the counts and deltas must be whole numbers. A value that is not a number is replaced by its default and reported; a `null` is replaced by its default silently. A warning level above its critical level is reported and used as written for loss, latency and the retransmission percentages; for the adapter deltas the critical level is silently raised to the warning level, and a warning level below 1 becomes 1.

### 3.6 · What the report says about the configuration

A report begins with the configuration rows — Configuration File, any Startup Notice, then Configuration Validation, Configuration Thresholds, Configured Targets and Configured Checks — so a mistake is visible where the person cannot miss it; the Standard Configuration row sits further down, with the comparison. The last two of those, and the Startup Notice that names a dropped target, are **weightless**: they are facts about what this run was given rather than measurements of the network, so they keep their row, their badge and their place in the counts, and the overall result is not theirs to change:

| Row | Status | Meaning |
|---|---|---|
| **Configuration File** | Pass — *Loaded: <path>* | The file was read; the path is the one in use |
| **Configuration File** | Unable to Check | Missing or not valid JSON; the built-in defaults ran. Verdict Test Incomplete |
| **Configuration Validation** | Unable to Check | An invalid value under `Expected`: an IPv4 address, subnet, prefix, gateway or DNS server that does not parse, or a `DhcpEnabled` that is not `true`, `false` or `null`. The count and the offending values are in the row's details. Nothing is removed — an invalid value under `Expected` simply never matches anything. Targets and check flags are not judged here; they have rows of their own below |
| **Configuration Validation** | Pass — *Configuration value format validation passed.* | Nothing to report anywhere. This row appears only when the three rows below have nothing to say |
| **Configuration Thresholds** | Warning | Present when a count, a timeout or a threshold had the wrong type or was out of range, or a warning level sits above its critical level; the details name each one and, for a value that was replaced, say what was used instead — an ordering warning only states the pair, because those values are used as written (section 3.5). Check flags are no longer here; see Configured Checks |
| **Configured Targets** | Unable to Check | A target this run was given and cannot test, **weightless**: a TCP target without a usable host name or with a port outside 1–65535, an HTTP target whose URL is not an absolute `http` or `https` address or whose host is not a usable name, a ping or DNS target whose value cannot be a host name at all. Nothing is skipped and nothing is silently dropped: each such target also keeps a row where its result belonged, and a **required** one adds a second, weighted row saying the check did not run. A malformed URL is refused before the request rather than attempted and reported as a failure |
| **Configured Checks** | Warning | A flag under `Checks` that is not `true` or `false`, or a `TracerouteHops` outside 1–10, **weightless**: the built-in default is used and the details name each one |
| **Standard Configuration** | Information | No rule under `Expected`; the comparison rows appear once one is set |
| **Startup Notice** | Warning | A run-time condition: the report folder fell back to the temporary folder, the tool is running from inside a compressed-folder view, or the window could not open and text mode was used. Those three keep their weight and turn the verdict to Attention Required on their own. The notice that an extra TCP target was ignored does not: it is weightless, and that target has a row of its own in the section where its result belonged |

---

## 4 · Run options — the IT entry and the command line

Run options change one run and never the file. They come from two places.

**The IT panel.** `Start-NetworkCheck-IT.cmd` opens the window with **Run options (IT)** at the top and waits: *Ready - adjust the options, then select Start Test.* The fields are **Extra ping**, **Extra DNS**, **Extra TCP (host:port)**, **Extra URL**, **Ping count**, **Ping ceiling** and **Sample seconds**; the boxes **Wi-Fi RF**, **Traceroute** with **Traceroute hops**, **Routes**, **Gateway ARP**, **Proxy** and **Drivers** switch the optional checks for this run; **Expand details in HTML** is ticked; **Reset to config** puts every field back to the file's values. **Ping count** is what each ping target is sent to begin with and **Ping ceiling** is the furthest a continued sample goes (section 3.3); both spinners open at the configured `PingCountMaximum`, the sample spinner at 1–120 seconds, and a configured value above either widens the range so the file's value is what an untouched Start runs with.

**What the panel checks before it starts.** Each of the four free-text fields shows an example on hover (`1.1.1.1`, `www.example.com`, `8.8.8.8:443`, `https://www.example.com/`), and on **Start Test** the extra TCP target is parsed with the same rule the run itself uses: a value that is not `host:port` marks the field, is named on the screen with an example, and the run does not start. A second press runs without that target — today's behaviour, Startup Notice and all, described under *What an extra target counts for* below. The labels also carry their own widths now: in earlier versions the extra-TCP label needed 136 px in a box of 100 (147 px in the Traditional Chinese package), so it wrapped and lost its second line, and the format the label carries was in the source rather than on the screen. The chain's headless GUI step measures every control's text against its box in both languages, so a translation that outgrows one fails there rather than on somebody's desk.

**The switches.** Most of the panel's options as parameters of the script, for a console run or a scripted one — the extra targets, the counts, and the Wi-Fi and traceroute boxes; the panel's other four boxes (Routes, Gateway ARP, Proxy, Drivers) have no switch, so for a console run they are turned off in a configuration file passed with `-ConfigPath`:

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
| `-PingCount`, `-PingCountMaximum`, `-SampleSeconds`, `-TracerouteHops` | Override the file's values for this run; hops outside 1–10 fall back to 3, and a ceiling below the starting count is reported and the starting count used |
| `-NoTraceroute`, `-NoWifi` | Skip those two diagnostics — the only two with a switch; the wireless retry counters have neither a box nor a switch and follow `WifiRetryCounters` in the file; `-NoWifi` also drops the access-point samples and the *Wi-Fi association* row, which ride `WifiRf` |
| `-ConfigPath <file>` | Load another configuration file (section 3) |
| `-STA` (PowerShell's own switch) | What the window launchers add; not needed for `-ConsoleOnly` |

**Two forms to avoid.** A second value after a bare space — `-PingTarget a b`, `-HttpUrl u1 u2` — is not a second target: PowerShell refuses to bind it - *A positional parameter cannot be found that accepts argument 'b'* - and the script does not start. In earlier versions it bound to the script's first positional parameter, `-ConfigPath`, so the run loaded no configuration (*Configuration file not found: b*, an *Unable to Check* row, built-in defaults, verdict Test Incomplete) and tested the first value only; the second target was lost in silence. And at a PowerShell prompt an unquoted semicolon ends the statement — `-PingTarget a;b` tests `a` and then tries to run `b` as a command — while cmd.exe passes it through. The comma-separated and the quoted forms above avoid both.

**What an extra target counts for.** Extra targets are optional and belong to no group: an extra ping that gets no reply, and an extra TCP or HTTP target that cannot connect, are Information rows and leave the verdict alone; a degraded ping and an extra DNS name that does not resolve are Warning rows. An extra TCP target that is not `host:port` is dropped with a Startup Notice warning (*Ignored extra TCP target '…': expected host:port.*). The rows are titled *Extra ping*, *Extra DNS*, *Extra TCP* and *Extra URL*, each carrying the value it was given - the ping rows after a colon, the other three in the title itself - so two added targets of the same kind are told apart in the table and in the summary. A near-end host is not an extra target: it is a property of the site, chosen once, and has neither a switch nor a panel field - it is set in the file (section 3.3), where `-ConfigPath` can point a console run at a candidate file.

**Where a run's options are recorded.** In the report header's *Run profile* line — `IT entry | extra targets: ping 10.0.0.1, tcp fileserver:445 | ping count 4 | sample 20 s | reads inside it every 2 s | traceroute 3 hops`, with `disabled: …` for switched-off checks — and in the JSON under `RunOptions`: `EntryPoint`, `ExpandDetails`, `ExtraTargets` (the values accepted), `RawTargets` (as typed), `PingCount`, `PingCountMaximum`, `SampleSeconds`, `IntervalSeconds` (1.2.14: the interval of the reads inside the sample window, 0 where they are off), `TracerouteHops`, `ChecksEnabled`. The run profile's `ping count` is the starting count, and `ping ceiling` beside it is where a continued sample stops; what a row actually sent is in the row itself.

---

## 5 · Deploying

**Ship the whole folder.** Every language launcher looks for `NetworkHealthCheck.ps1` beside itself and stops when it is missing; the script looks for its configuration beside itself and runs on defaults when it is missing. A language folder — `en-US` or `zh-TW` — is complete on its own: launchers, program, configuration, this manual, the user manual and the technical guide. The two root launchers (`Start-English.cmd`, `Start-Traditional-Chinese.cmd`) only call into a folder of that exact name, so keep the folder names when you ship them, and leave them out when you ship one language.

**Do not rename the program or the configuration file.** The launchers and the script find them by name.

**Two ways it arrives, and what the person sees.**

- *A ZIP downloaded with a browser* carries the Mark of the Web; the files Windows Explorer extracts from it carry the same mark, and a double-click on a launcher shows **Open File - Security Warning**, after which the tool runs. Unblocking the ZIP before extracting (right-click → Properties → Unblock, or `Unblock-File` in PowerShell) leaves the extracted files without the mark. Both were measured on two virtual machines (the validation record, `VALIDATION.md`, *Acceptance on a second machine*).
- *A package that arrives without a browser* — pushed by a distribution tool, or copied in, as the campaign's copy from its host was — carried no mark on the machines measured, and no prompt appears.

Whichever way it arrives, the person must extract the whole ZIP: a launcher double-clicked inside Explorer's ZIP view finds nothing beside itself and stops (the user manual, sections 2 and 6).

**Where to put it.** Any local folder the user can write to — the Desktop or Documents are what the user manual suggests, and where the acceptance runs were made. The folder must stay writable if the reports are to land beside the program; otherwise set `ReportFolderName` (section 3.1) or expect the temporary-folder fallback. **On a default Windows 11 that means not the Desktop or Documents, if the reports are to stay on the machine.** OneDrive's Known Folder Move backs both folders up unless it was turned off, so a package extracted there writes its `Reports` folder inside a synced folder, and every report — computer and user names, MAC and IP addresses, SSID and BSSID, DNS servers, proxy settings, routes, driver versions, profile paths — is copied to that user's OneDrive as it is written, before anyone sends anything. It was measured that way on `win11-enUS` during the user-manual walk recorded in `VALIDATION.md`. Where that is not what you want, put the package in a folder outside the sync root — a per-machine tools folder, or `C:\NetworkHealthCheck` — or set `ReportFolderName` (section 3.1) to a rooted path that is not synced; the user manual says the same thing from the person's side in its sections 1, 5 and 9. On such a machine the desktop is also `%OneDrive%\Desktop` and not `%USERPROFILE%\Desktop`, which a deployment script that copies to the desktop has to handle.

**Upgrading.** Replace the folder with the new version and carry your configuration file over. The file's version does not matter to the tool: a key the new version added takes its default when your file does not have it. Compare the shipped file with yours after an upgrade and run one check (section 3.6) before the new folder goes out. Keep your edited configuration under version control; the package cannot tell your edits from the shipped file except by their hash (section 6).

**The program file.** Configure; do not edit the script. An edited script no longer matches the manifest, and the two language versions are checked against each other by the validator (section 6), so a change in one folder alone fails it. If a change is really needed, keep the original, re-run the validator knowing which checks you expect to fail, and record your own digests. The scripts are not digitally signed (section 8, *Signing*).

---

## 6 · Verifying the package

**The download.** The release notes on the project's Releases page give the SHA-256 of `NetworkHealthCheck-<version>.zip`. Compare before extracting:

```text
certutil -hashfile NetworkHealthCheck-1.2.14.zip SHA256
```

or in PowerShell `Get-FileHash NetworkHealthCheck-1.2.14.zip`. The asset is built from the repository's tracked files only, so it contains no report and no other output of a run.

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

**For your tools.** The JSON report is schema 2: `SchemaVersion`, `ToolVersion`, `RunOptions` (section 4), `Fingerprint` (`Key`, `Title`, `Lines` — the *What to tell IT* section), `Overall` (`Code`, `Text`, `Description`), `Counts`, `System`, `StartedAt`, `FinishedAt`, and `Results`, one object per row with `Time`, `Category`, `Check`, `Status` (`PASS`, `WARN`, `FAIL`, `INFO`, `ERROR`), `Message`, `Details`, `Diagnostics`, `Tag`, `Scope` (`Main` or `IT`), `Weightless`, `Rule` and `Path`. `Tag` is the language-neutral name of the check (`ping-gateway`, `ping-near-end`, `dns`, `connectivity-group`, `tcp-retransmissions`, `wifi-retry`, `wifi-association`, `expected-standard`, …); the technical guide (section 4.10) lists them, and the `Scope` tells you which rows the verdict ignores; `Weightless` (additive under schema 2) is `true` on a row that keeps its badge, its message and its place in `Counts` but decides neither `Overall` nor `Fingerprint` — a statistic that could not be taken, a sample too coarse for the threshold applied to it, or a fact about what this run was given. It is the field that explains an `ERROR` or `WARN` row beside an `Overall` of `PASS`. `Rule` (additive under schema 2 as well) is set on ping rows only: `loss` where the loss band decided the row's status, `latency` where the replies that did arrive did, and empty where nothing did - the field the summary reads to tell a gateway that lost its replies from one that answered them slowly. `Path` (additive as well) is set on a near-end or gateway row that claimed its rung - the interface alias of the adapter whose local path the probes are attested to have crossed - and empty where the row could not claim it and on every other ping row; it is what pairs a near-end row with a failed gateway row, so a gateway reached through a router, or through another adapter, is never paired.

**Reading them.** The user manual explains the verdicts, the *What to tell IT* titles and the badges; the technical guide explains each rule. The repository's `sop` folder holds a support engineer's field manual and a report template for turning a report into a hand-off. One of that field manual's reading rules belongs here too, because the person on the phone does not have it: the one required ping target, the default gateway, is answered by the gateway's own stack, and network devices commonly rate-limit or deprioritise ICMP addressed to themselves — so a gateway that answers promptly is good evidence that the near-end path works, while *Gateway does not answer* is a suspect, not a conviction. The title means that replies did not come back: a gateway that answered every ping but slowly is *Connected, but quality is poor* instead - or *A required check failed*, beside another failure - because the summary reads which measurement decided the row (in earlier versions it read the status alone and titled both the same). With a near-end host configured (section 3.3), the summary's second line says which side of the gateway the fault is on - where the near-end host and the failed gateway were reached through the same adapter, which each row records in its `Path` field once it has claimed its rung; where either could not claim it - a route through a router, a VPN - on a multihomed machine where they were not the same adapter, or where gateways failed through different adapters, the line stays the neutral one. Read it as *investigate the local path, and also consider that the device may not answer for itself* — a target beyond the gateway that passed in the same report shows that it forwards only if its route ran through that gateway: a same-subnet host, a VPN or a proxy can succeed without touching it, and on a multihomed machine `AUTO_GATEWAY` writes one row per gateway. The check stays required, because a machine that cannot reach its own gateway usually does have a problem worth reporting (decided 2026-09-10, backlog #58), and the failed row's details and the *What to tell IT* summary now say the same.

---

## 8 · Security policy: what blocks it, and what the person sees

The launchers set the execution policy for their own process (`-ExecutionPolicy Bypass`), which is enough on a machine without policy. Where there is policy, this is what happens — each line measured on the project's virtual machines and recorded in `VALIDATION.md`, unless marked otherwise:

| Mechanism | What happens | What reaches IT |
|---|---|---|
| **Mark of the Web** on a downloaded ZIP | *Open File - Security Warning* on the launcher; the tool runs after *Run* | Nothing — unless the person cancels |
| **Execution policy set by Group Policy** (`MachinePolicy` / `UserPolicy`, e.g. *AllSigned*) | Overrides the launcher's process-scope Bypass: the script does not start. PowerShell prints *…NetworkHealthCheck.ps1 is not digitally signed. You cannot run this script on the current system…* on its error stream; the launcher keeps that in `PowerShellMessages_<time>.txt`, prints it back under its own error, reports the non-zero exit code and pauses, and `LauncherError_<time>.txt` says to send both files and ask IT to allow the program (until 1.2.14 the person was asked to read the message off the screen) | `LauncherError_<time>.txt` and `PowerShellMessages_<time>.txt`, beside the launcher. No environment report: the script never ran |
| **PowerShell restricted to a limited language mode** — what an enforced application-control policy (WDAC) does to a script it does not allow, and what `__PSLockdownPolicy` does to every script | The script's first lines detect a mode other than *FullLanguage* and stop before any check: exit code 3, the reason on the console, and `NetworkHealthCheck_ENVIRONMENT_<time>.txt` beside the program (or in `%TEMP%`, when that folder cannot be written or is a compressed-folder view) naming the reason, the mode, the tool version, the computer, the user, the program's folder, the PowerShell version, the culture and the operating system, and two lines under *What IT can do*: allow `NetworkHealthCheck.ps1` in the application-control policy (WDAC / AppLocker), or run the check on a computer that is not restricted in this way. The launcher explains exit code 3 and points at that file. Measured with `__PSLockdownPolicy` on both machines; no WDAC-enforced machine has been measured | The environment report and `LauncherError_<time>.txt` |
| **AppLocker script rules** | Not measured to take effect: the one machine that reported an enforcing policy denying the script ran it unrestricted (backlog #31 on the repository's backlog page, section 10). Whether an enforced rule refuses the script or runs it in the restricted mode above has not been observed. One more thing an enforced DLL or EXE rule can do short of stopping the script: refuse the C# compiler or the in-memory assembly the wireless retry reader is built with — that one row is then *Unable to Check* and nothing else changes | Whichever of the two files above the outcome produces |
| **EDR or antivirus** blocking `powershell.exe` or the script | Not measured: no machine with such a product was part of the acceptance runs. The launcher reports whatever exit code it gets, writes `LauncherError_<time>.txt` and keeps whatever PowerShell printed on its error stream in `PowerShellMessages_<time>.txt` | `LauncherError_<time>.txt`, `PowerShellMessages_<time>.txt` where PowerShell said anything, and the product's own record |

**What to ask the person for** is in the user manual's section 6, row by row; the environment report, `LauncherError_<time>.txt` and `PowerShellMessages_<time>.txt` are written for exactly this hand-off. Since 1.2.14 every attempt writes its own files, so a third try no longer overwrites the first: the number in the names is the date and time in the digits the machine prints them, which sorts by time on that machine and not across machines. The error report's `Date/time:` line quotes the shell's own date and states, beside it, the short-date pattern that date is in — `08/09/2026` cannot be resolved without one, and a machine with an English display and a British regional format writes exactly that — read from `HKCU\Control Panel\International\sShortDate` and omitted when it cannot be read; nothing is converted. The authoritative stamp is the file's own modified time, which your Explorer renders in your format, for files written before this version as well. The files sit beside the launcher, or — when that folder cannot be written — in `%TEMP%` as `NetworkHealthCheck_LauncherError_<time>.txt` and `NetworkHealthCheck_PowerShellMessages_<time>.txt`, with the same lines.

**Allowing the tool.** The two scripts are unsigned, so a policy that allows by publisher has nothing to match; what an IT department has today is the hash: `SHA256SUMS.txt` gives the digest of each `NetworkHealthCheck.ps1`, and a WDAC or AppLocker rule can allow that hash. A new version means a new hash. Which Windows builds and editions enforce AppLocker, and what has and has not been observed, changes faster than this package: the repository keeps a page on it, at the version this manual belongs to — <https://github.com/kevintechin/network-support-toolkit/blob/v1.2.14/docs/application-control.md> — and its current version on the `main` branch.

**Signing.** An Authenticode signature from your own certificate authority satisfies an *AllSigned* policy when the signing certificate is also trusted on the machine — its chain trusted, and the certificate in the Trusted Publishers store: for a publisher not yet classified as trusted, PowerShell asks the person before running the script (the launcher's window shows the question), and a session that cannot ask does not run it. A signature also lets an application-control rule allow by publisher. Signing appends a signature block to the script, so the signed file no longer matches `SHA256SUMS.txt`; record the signed files' digests yourself.

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
- **Validation record** — `VALIDATION.md`: every release's evidence and the acceptance runs on other machines.
- **Backlog** — <https://github.com/kevintechin/network-support-toolkit/blob/v1.2.14/docs/backlog.md>: what is known and not yet done, and what would close each item. It is in the repository rather than in the package, like the application-control page of section 8, because it changes between releases.
- **Thresholds** — <https://github.com/kevintechin/network-support-toolkit/blob/v1.2.14/docs/thresholds.md>: where the shipped threshold values come from — nowhere external, by a recorded decision — and what the published standards do and do not supply, each verified against its source on a stated date. It is in the repository for the same reason.
- **The repository** — <https://github.com/kevintechin/network-support-toolkit>: releases, the validation chain (`tests`), the support engineer's field manual and report template (`sop`), and the application-control page named in section 8.

---

*NetworkHealthCheck 1.2.14. This manual describes the tool as shipped and the behaviour measured for this release; the rules quoted here are the code's, and the technical guide states them in full.*
