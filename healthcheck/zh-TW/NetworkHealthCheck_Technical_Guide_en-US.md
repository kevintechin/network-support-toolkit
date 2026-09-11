# NetworkHealthCheck Portable 1.2.12: Features, Design, Validation, and Limitations

## 1. Purpose

This document describes the features, architecture, decision rules, error handling, validation approach, known limitations, and source-comment strategy of the portable `NetworkHealthCheck` tool. It applies to version **1.2.12** and to both the Traditional Chinese and English packages. The executable logic is the same; user-visible text, default test names, and comment language are localized separately.

## 2. Product scope

This is a portable Windows PowerShell diagnostic tool. It installs no service, driver, or packet-capture component. Its purpose is not to replace Wireshark, enterprise monitoring, or switch management. It gives non-technical users a single action that collects consistent network evidence and preserves reasons when a check cannot run.

The tool is read-only with respect to system configuration. It does not change IP, DNS, routes, firewall, proxy, or adapter state. Its active behavior is limited to ping, DNS lookup, TCP connection, and HTTP/HTTPS GET tests.

## 3. Package contents

| File | Purpose |
|---|---|
| `Start-NetworkCheck.cmd` | GUI launcher. Displays startup failures and attempts to write `LauncherError.txt`, whose suggested action follows the reason since 1.2.3. |
| `Start-NetworkCheck-Console.cmd` | Console fallback when Windows Forms cannot be used. |
| `Start-NetworkCheck-IT.cmd` | IT entry (1.2): run-options panel, no auto-run, HTML opens with the IT diagnostics expanded. Same switches work in console mode. |
| `NetworkHealthCheck.ps1` | Main diagnostics, decision logic, error handling, and report generation. |
| `NetworkHealthCheck.config.json` | Company IP standards, targets, timeouts, and thresholds. |
| `NetworkHealthCheck_User_Manual_*.md`, `.html` | The end-user manual, since 1.2.4: before you start, running the check, reading the result, sending the report, what to do when it does not run. Markdown and a single HTML page with the same content. |
| `NetworkHealthCheck_IT_Deployment_Manual_*.md`, `.html` | The IT deployment manual, since 1.2.4: requirements, the configuration file key by key, run options, deployment, package verification, security policy and what the person sees under it, the reports. Markdown and a single HTML page with the same content. |
| `NetworkHealthCheck_Technical_Guide_*.md` | English and Traditional Chinese versions of this document. |
| `SHA256SUMS.txt` | SHA-256 values for release files. |
| `tools/validate_release.py` | Cross-platform static release validator; it does not run Windows network checks. |

## 4. Features and decision rules

### 4.1 Configuration loading

The program creates safe built-in defaults, reads the JSON file, and recursively merges overrides. A missing or malformed configuration does not terminate the whole run. Built-in defaults are used, the reason is recorded as `ERROR / Unable to Check`, and other executable checks continue.

Semantic validation covers IPv4 addresses, CIDRs, prefix lengths, gateways, DNS servers, DHCP Boolean state, TCP host/port values, HTTP/HTTPS URLs, DNS targets, and primary timeout values. Some inconsistent thresholds produce warnings. Since 1.1.4, every numeric threshold is parsed by a culture-invariant, non-throwing converter: a non-numeric value (Booleans, NaN and infinities included) is listed in the configuration warnings and replaced by the built-in default, and decimal thresholds (for example `2.5`) are honored instead of being rounded to integers. Count-based settings — the adapter error/discard deltas, `TcpRetransmissionCriticalCount`, `MinimumTcpSegmentsForRate`, `PingCount` and the timeouts — must be whole numbers within the 32-bit integer range; a decimal or out-of-range value there is reported and replaced by the default rather than silently changed. Semantic errors do not currently remove every affected value automatically, so an invalid setting can still make a related result meaningless; the report states this explicitly.

### 4.2 Adapter and IP discovery

The preferred source is `Get-NetIPConfiguration`, `Get-NetIPInterface`, and NetAdapter/NetTCPIP objects. If those are unavailable or fail to provide data, the program falls back to CIM/WMI `Win32_NetworkAdapterConfiguration` and `Win32_NetworkAdapter`.

Collected fields include interface name, description, index, link speed, MAC, network profile, IPv4/IPv6, prefixes, gateways, DNS, DHCP state, and source. Adapters with IPv4 plus a gateway are treated as primary; if none exist, adapters with IPv4 are used. In the CIM/WMI fallback (1.1.4), only IPv4 next hops from `DefaultIPGateway` count as gateways, and a missing `DHCPEnabled` value is reported as unknown rather than as static. Since 1.2.12 each adapter's details also name the **DHCP server** that answered its lease (backlog #32), read from `Win32_NetworkAdapterConfiguration.DHCPServer` on both paths — one CIM query on the NetTCPIP path, keyed by interface index, since those cmdlets carry the mode and not the server. A static address names no server whatever the class holds; where the class could not be read the line says the datum is unavailable rather than leaving a blank that would read as *no server*; a configuration that holds no server address says that. The query is not attempted twice: it is not a performance-counter read, and 1.2.8 recorded why the adapter-configuration queries keep a single attempt.

Base rules:

| Condition | Result |
|---|---|
| No connected adapter with an IP address | `FAIL` |
| `169.254.x.x` detected | `FAIL`; commonly indicates DHCP failure |
| Adapter has no IPv4 but has other IP data | `WARN` |
| No IPv4 default gateway | `FAIL` |
| No DNS servers | `FAIL` |

### 4.3 Company-standard comparison

Compliance is evaluated only when at least one rule exists under `Expected`. When all rules are empty, the tool displays current values and does not claim that they are correct or incorrect.

- IP: any IPv4 on a primary adapter may exactly match an allowed address or fall within an allowed CIDR.
- Prefix: any current primary-adapter prefix may match the allowed list.
- Gateway: any current primary-adapter gateway may match the allowed list.
- DNS: every required DNS entry must appear in the aggregated DNS list from primary adapters.
- DHCP: every primary adapter with a known DHCP state must match the expected value; no available state produces `ERROR`.

This multi-adapter aggregation is convenient for common systems, but VPNs, virtual switches, or simultaneous wired/wireless connections may require a customized interface filter.

### 4.4 Ping, packet loss, and latency

Each target uses the .NET `Ping` class and the configured number of probes:

```text
packet loss = (sent - received) / sent × 100%
```

Average, minimum, and maximum latency use successful replies. The decision order is: no replies, critical loss, warning loss, critical average latency, then warning average latency. A severe condition on `Required=true` becomes `FAIL`. A completely silent optional target is normally `INFO`, because ICMP may be blocked.

**The required gateway target is answered by the gateway's own stack (1.2.11, backlog #58).** `AUTO_GATEWAY` is the only target shipped as `Required`, and an echo addressed to a device's own address is answered by that device's control plane, which network devices commonly rate-limit or deprioritise. A gateway that answers promptly is therefore good evidence that the near-end path works; one that does not answer, or answers slowly, is not proof that it is broken or slow to forward — the control plane answers at a lower priority than the traffic it forwards, so the failed row's sentence names which of the two happened. Since 1.2.12 the fingerprint reads which measurement decided the row — the `Rule` field, `loss` or `latency` (backlog #67) — so *Gateway does not answer* is selected only by a gateway row that lost its replies, and a gateway that answered every probe slowly is a quality finding: `quality` when nothing else warned or failed, `mixed` otherwise. Decided 2026-09-12: a slow-but-answering gateway is a quality fingerprint and not a connectivity one, because the gateway was reached and `ping-gateway` is one of the four quality tags; the `gateway-up-internet-dead` key still requires a gateway row that passed, so a slow gateway beside a failed group is `mixed`, which names neither and is right to. The check stays required — a machine that cannot reach its own gateway usually does have a problem worth reporting, and the alternative, a weightless row, would leave a Wi-Fi-only machine's one near-end measurement unable to move anything (decided 2026-09-10) — and since 1.2.11 the failed row's details and the *What to tell IT* summary say what the failure does and does not establish, in the words of the support engineer's field manual: a suspect, not a conviction.

**The near-end rung (1.2.12, backlog #60).** The shipped ladder — the gateway, then `1.1.1.1` — is cumulative: every rung includes the path of the one before it, so differencing latency between rungs is weak and differencing loss is not valid at all, the two rungs being separate traffic sent at separate instants. `Tests.NearEndTarget` adds the rung before the gateway: an IPv4 address on a primary adapter's subnet that is not the gateway, absent as shipped, pinged first and measured by exactly the path the other targets use (`Invoke-PingMeasurement`, the route lookup before and after, the adaptive sample) under its own tag, `ping-near-end`. It is placed before it is probed (`Test-NearEndTargetPlacement`): one of the primary adapters' gateways, one of this computer's own addresses (a probe to it is answered by this stack and crosses nothing) or the network or broadcast address of the subnet it falls in is refused as a configuration mistake, an address outside every primary subnet is reported as not probed — a weightless `INFO` row, a fact about where the machine is rather than about the network, plus the weighted *did not run* row where the target is required — and only an on-subnet address is measured. A name and a placeholder fail the configuration check's narrower rule for this key, because the rung has to be placed before anything is sent and a name would put it behind the resolver. The near-end row and the gateway row each carry a **rung line** saying which segments their probes crossed and which they did not — the local path only, answered by an ordinary host; the local path, answered by the gateway's control plane — and the near-end row carries the reading rule: a rung that passes clears what it crossed at that moment, the first rung that fails puts the problem beyond the last rung that passed and no closer, and the figures of two rungs cannot be subtracted into a loss figure for the segment between them. A far-end row claims no rung, because where an extra target sits relative to the gateway is not something the row has measured. The near-end entry is built by the run and never read from `PingTargets`, so a list entry cannot promote itself to the rung and the traceroute — which walks the list for its target — never traces toward it (a site that lists an on-subnet host first in `PingTargets` has always had that host traced, and still does). Nothing computes per-hop loss from TTL-limited probes, and nothing should: an intermediate hop's reply is an ICMP error from its rate-limited control plane. The *What to tell IT* summary for `gateway-unreachable` reads the rung: a near-end row that passed chooses a second line placing the fault at the gateway itself, one that lost its replies a line placing it on the local path before the gateway, and anything else — no near-end host, or one that answered slowly — the line the summary always had. Cost: one more ping target, `PingCount` probes, continued where replies are lost like any other; `PingCount × PingTimeoutMs` at worst for a silent host.

**`PingCount` is where a target starts, not where it stops (1.2.10, backlog #51).** Four probes against the shipped 5% warning threshold make one lost reply 25% — past the critical threshold as well — and the tool has no way to express "a little loss" at that count. The configured count is therefore the first pass, and what it found decides what happens next:

- **Every reply arrived.** Nothing is ambiguous, nothing more is sent, and a healthy run is no slower than it was before this release.
- **Nothing answered at all.** 100% loss is conclusive at four probes and no larger count makes it more so, while this is the one case where every extra probe costs a whole timeout. Nothing more is sent here either.
- **Some replies were lost but not all.** This is the ambiguous case. The sample continues to the count at which one lost reply can no longer decide the classification, or to `PingCountMaximum` where that is lower. That count is the smallest *n* at which one lost reply is below the warning percentage **as the row prints it** — the figure is rounded to one decimal and the classification reads the printed figure, so the exact `100/n` is not what decides. At the shipped 5% it is **21**: twenty is exactly 5%, and 4.7619% prints as 4.8%. At a calibrated **4.8%** it is **22**, because 21 prints as 4.8% too and 4.8 reaches a 4.8% threshold — the exact arithmetic would have stopped at 21 and left one packet deciding, which is this section's own defect one layer in. The tool computes the count it needs; `PingCountMaximum` only stops it going further, and does not have to be set to that count.

The extra probes are **spread across the rest of the run rather than sent back to back**. The .NET `Ping` class used here sends with no delay between echoes, so twenty of them land inside a fraction of a second and measure one instant twenty times, while what a person is usually trying to catch — a connection that is intermittently unstable — needs span rather than count. They are sent immediately before the retransmission sample window sleeps out the seconds it still owes, so the span costs wall-clock time the run was going to spend anyway; where that budget is already gone they go back to back and the run is longer by what they cost. The row is written where it belongs when the first pass ends and rewritten when the sample is finished, so a continued sample never moves its own row out of the ping section — and the figures, the method line and the manual check all count the probes that were actually sent, not the number configured.

**A verdict is withheld when it would rest on a single packet.** The row keeps every number it measured and stops deciding the overall result when **both** of these hold: the sample is smaller than the count the warning threshold needs, so one packet is worth a whole band there; **and** the classification would be a different one had one fewer reply been lost, so the verdict *is* that packet. Either on its own leaves the verdict standing — three lost of four is 75% and two lost is still 50%, so nothing there rests on one packet, while two lost of twenty-one does turn on a packet but twenty-one is a sample the 5% threshold fits and 9.5% is a measurement. A target that answered nothing at all reaches the rule too, and passes it at the shipped count: three lost of four is still critical, so the verdict stands. It is withheld only where the whole sample is one probe, because there “100 % loss” and “one lost packet” are the same event — `PingCount` 1 is a value the configuration permits. Nothing more is sent either way. And a withheld loss verdict does not hide a latency one: the row is handed to the latency rules and keeps its weight if it reaches one of those.

**Which adapter the probes left by (1.2.9, backlog #59; this paragraph corrected in 1.2.11, backlog #64).** A ping row whose target was given as an **address** names in its details the source address and the interface the route table selects for that target, read with `Find-NetRoute -RemoteIPAddress <target>` before and after that target's probes. That is the rule for an address; a target given as a **name** has no address to ask about until something replies, and the paragraph after this one describes it. And three shapes of ping row carry no route line at all, because nothing was sent and there is no measurement to place: a configured value that cannot become a target (*The configured address cannot be used as a ping target*), a placeholder that expands to nothing on this machine (*No testable target was found* — `AUTO_GATEWAY` with no default route, `AUTO_DNS` with no DNS server on the primary adapters), and an attempt that threw (*The ping test could not be performed*). It is a **selection, not an observation**: the lookup answers what the system would choose at the moment it is asked, and the probes are then sent unbound, so on a multi-homed machine — a dock, a Wi-Fi roam, a VPN coming up — the route can change between the two. The row therefore never claims the echoes used what the lookup returned. When the two lookups disagree — including one resolving where the other did not — the row reports the change and states that it cannot say which of them carried the probes. Where `Find-NetRoute` is absent, returns no route, or fails, the datum is reported as unavailable with its reason and the ping measurement is unaffected, which is the treatment every other NetTCPIP call in this tool gets. Binding a source, which is what would make this an observation rather than a selection, needs `ping.exe -S` and is deliberately not done.

**A target given as a name is looked up by the address its replies came from.** The route table is asked by address — `Find-NetRoute` rejects a name outright — so for a name there is nothing to ask before the probes and no before-and-after pair is taken; the row says so and names the address it did look up. Where nothing replied there is no address at all, and the row says that instead. **The tool does not resolve the name itself**, which would put the ping check behind the resolver on a machine whose resolver is often the thing being diagnosed. The three ways the lookup can come back empty are told apart by the error's identifier rather than its message, which follows the machine's locale: an unroutable address, a value that is not an address, and a failure of the lookup itself each say which one they are.

### 4.5 DNS

DNS uses `System.Net.Dns.GetHostAddressesAsync()` with a timeout. A required name-resolution failure is `FAIL`; an optional one is `WARN`. This validates the operating system's effective resolver behavior. It does not query each configured DNS server independently.

### 4.6 TCP and HTTP/HTTPS

TCP uses `TcpClient.BeginConnect()`, a bounded wait, and `EndConnect()` to verify whether a socket can be established.

HTTP/HTTPS uses `HttpWebRequest`:

- GET method and automatic redirects.
- Windows system proxy and default proxy credentials.
- Attempts to enable TLS 1.2.
- Reads one byte from the response stream to confirm readability.
- A 4xx/5xx response is still considered network-path reachability; the status code remains in the report.

A `RequiredConnectivityGroups` group passes when at least one member succeeds, not when every member succeeds. The default Internet group can therefore be satisfied by either its TCP or HTTP/HTTPS member.

### 4.7 Adapter errors and discards

`Get-NetAdapterStatistics` is sampled before and after the test:

```text
error delta = ΔReceivedPacketErrors + ΔOutboundPacketErrors
discard delta = ΔReceivedDiscardedPackets + ΔOutboundDiscardedPackets
```

If an ending cumulative value is lower than its baseline, the adapter probably reconnected or the counter reset/overflowed. The tool reports `WARN` rather than calculating a negative delta. Thresholds are controlled by AdapterError* and AdapterDiscard* settings.

### 4.8 TCP retransmissions

CIM/WMI reads:

- `Win32_PerfRawData_Tcpip_TCPv4`
- `Win32_PerfRawData_Tcpip_TCPv6`
- `SegmentsSentPersec`
- `SegmentsRetransmittedPersec`

Although the RawData property names contain `Persec`, the program treats the values as cumulative snapshots and computes deltas:

```text
approximate retransmission rate = ΔRetransmittedSegments / ΔSentSegments × 100%
```

**What the denominator counts (1.2.11, backlog #57).** `Segments Sent/sec` counts every segment this computer sent — pure acknowledgements included — and excludes segments containing *only* retransmitted bytes; `Segments Retransmitted/sec` counts every segment containing one or more previously transmitted bytes, so a segment carrying new bytes beside retransmitted ones is in both counts (the operating system's own counter help text and Microsoft's *TCP Object* counter reference, both read on 2026-09-10). The ratio above is therefore this tool's own figure and not comparable with a published retransmission rate: it is not the data-segment rate RFC 4898 keeps apart from the segment count (`tcpEStatsPerfSegsOut` against `tcpEStatsPerfDataSegsOut`), and not RFC 6349's TCP Efficiency, which is counted in bytes with the retransmitted bytes inside the denominator. The row says what it divides by — every row that prints the figure carries the sentence — and does not say which way it errs: the acknowledgements pull it below a data-segment rate, the excluded pure retransmissions pull it above a byte ratio, and neither bias has been quantified on any run of this tool. No data-segment rate is computed, by decision (2026-09-10): the per-connection counters that would give one are TCP extended statistics, whose collection is off until a member of the Administrators group turns it on, and which Microsoft advises against turning off again — a write to the machine, by an elevated user, in a tool that ships with *no admin rights* and *changes nothing*. `Segments/sec` is not an alternative denominator either, being Received plus Sent.

Rules:

1. Missing before/after data: `ERROR`.
2. Ending value below baseline: reset/overflow, `ERROR`.
3. Both sent and retransmitted deltas are zero: insufficient sample, `INFO`. A window in which **no** segment was counted as sent has no ratio whatever the retransmitted delta is: the row says the rate is not computable instead of printing 0%, carries no denominator sentence, and — since the sent counter excludes segments carrying only previously sent bytes — can still carry a retransmission count, which the small-sample rule below reports (1.2.11).
4. Sent segments below `MinimumTcpSegmentsForRate`: the rate is not judged. A sample carrying retransmissions is `INFO` and decides nothing — a `WARN` until 1.2.10, weightless since 1.2.8, which left a badge saying *attention* beside a sentence saying the row is not evidence; a sample carrying none is `INFO` too. **The window is extended once (1.2.10, backlog #51)** where a sample ends below this floor with at least one retransmission in it, which is the one case where waiting longer settles anything. A machine that retransmitted nothing is not extended, because a longer window buys more of the same nothing, and a sample that already has a rate is not extended either. The second reading is merged per protocol, so a read that fails cannot cost a reading the first one already had, and the row says that its window was extended.
5. With enough traffic the **rate** decides and the **count** qualifies it:
   - **A rate needs enough events behind it (1.2.10, backlog #51).** Fewer than `MinimumTcpRetransmissionsForVerdict` retransmissions at or above the warning percentage is reported as `INFO` with its numbers and decides nothing. At the smallest sample this tool rates — fifty sent segments as shipped — one retransmission is 2%, the warning threshold itself, and three are 6%, which failed on the rate alone until this release. The floor gates both branches, because a floor on the warning branch alone would leave the coarsest sample convicting harder than the one above it. It suppresses nothing above two hundred sent segments at the shipped values: suppression needs a rate at the threshold with fewer events than the floor, which is `(floor − 1) × 100 ÷ warning percentage`.
   - `rate ≥ TcpRetransmissionCriticalPercent` → `FAIL`.
   - `rate ≥ TcpRetransmissionWarningPercent` **and** `retransmitted ≥ TcpRetransmissionCriticalCount` → `FAIL`. The count sharpens a verdict the rate has already reached.
   - `rate ≥ TcpRetransmissionWarningPercent` → `WARN`.
   - **The count no longer warns on its own (1.2.10, backlog #63).** Until this release `retransmitted ≥ TcpRetransmissionCriticalCount` warned whatever the rate was, so a large enough sample reached it at a rate the threshold table calls healthy: 57 retransmissions of 3 832 sent segments is 1.487% and was reported as *Attention Required*. The boundary is `TcpRetransmissionCriticalCount ÷ TcpRetransmissionWarningPercent`, 2 500 sent segments at the shipped 50 and 2% — below it, reaching fifty retransmissions means the rate is already at or above the warning threshold and the standalone trigger changed nothing; above it, all the standalone trigger added was a warning on a sample whose rate is below the tool's own warning threshold. What it gives up is the only signal that fired on a burst inside an otherwise healthy window, and section 8 records that.
   - **Every classified row names the rule that decided it.** A `PASS` names none, because none did.

Reads, attempts, and what a row says about them:

- Each counter read is allowed eight seconds and is attempted **twice**. A read that fails on the first attempt is made again, and only a second failure writes the `ERROR` (*Unable to Check*) row — whose status, name and message are what they were before the second attempt existed. A read that fails twice is not retried a third time.
- The **baseline** snapshot takes one additional throwaway read per class, in a pass of its own **before either counter is read**; the readings are discarded and a failure of one is neither an error nor a measured attempt. Whatever a first query of the performance-counter provider costs is therefore spent before both baseline stamps, which it delays equally, so it lengthens no protocol's window — not even by being slow rather than failing. Interleaving the warm-ups with the measured reads would put TCPv6's warm-up after TCPv4's baseline stamp and so inside TCPv4's window. The ending snapshot takes no such read at all: inside the window it would lengthen the very thing it is there to protect.
- Every attempt that failed is kept, with the seconds it spent, **even where a later attempt succeeded**. The rows are written from that record: a row for a counter that could not be read names the attempts behind it, and a row whose window ran long names the seconds that went on failed reads and which reads they were.
- The cost in time is bounded and stated: on a machine whose counters answer, the two pre-window reads are the only addition and they cost milliseconds; on one where every read runs out of time, the six reads of a run spend up to eighty seconds between them, against thirty-two before the second attempt existed.

Sample duration is computed from **that protocol's own two stamps**, not from the stamps of the snapshots enclosing them. The two protocols are read serially and each stamp is taken when its own read returns, so a window is lengthened by a read that delayed the stamp closing it without delaying the stamp opening it: in the **ending** snapshot that is every read at or before that protocol, and in the **baseline** snapshot every read *after* it, whose delay moves the later opening stamps and the whole rest of the run alike. A TCPv6 baseline read that waits out its limit therefore falls inside TCPv4's window and not inside its own. The pre-window reads fall inside no window at all, since they are all taken before either baseline stamp. The deltas are unaffected — each is the difference between that protocol's own two readings — and the rate is a ratio and not a time, so the duration was the only figure a failed read ever corrupted. The row prints the measured duration beside the configured `RetransmissionSampleSeconds`, which is a minimum and not a target.

This is a system-wide approximation for the whole computer and sample period. It cannot identify the application, remote host, or TCP stream responsible for a retransmission.

### 4.9 Overall result

Overall precedence is fixed:

```text
FAIL > ERROR > WARN > PASS
```

Any `FAIL` produces Problem Detected. With no failure but at least one unexecuted check, the result is Test Incomplete. Warnings are next, and only then Overall Healthy. **Since 1.2.8 the precedence is applied to the rows the run measured** (backlog #39): a row marked `Weightless` — a statistic that could not be taken, a sample too coarse for the threshold applied to it, a fact about this run's own input — is excluded from this comparison and from every predicate of the fingerprint, while `Get-SummaryCounts` and the report notice go on reading every row on the page, so such a row keeps its badge and the explanation of it. The marking is opt-in per branch: a row is weighted unless it is named, so a check added later cannot become weightless by omission.

### 4.10 Adapter classification, IT diagnostics, and the fingerprint (1.2)

Every adapter is classified as physical or virtual: the NetAdapter `Virtual` / `HardwareInterface` flags win, the CIM fallback uses `Win32_NetworkAdapter.PhysicalAdapter`, and without flags a description pattern (VirtualBox, Hyper-V, VMware, TAP, tunnel, loopback, WAN Miniport, WireGuard, ZeroTier, Tailscale, Docker, VPN, ISATAP, Teredo) decides. Virtual adapters are `INFO` rows and never trigger the APIPA or no-IPv4 rules; the "Usable Network Adapters" row reports physical and virtual counts and becomes `WARN` when only virtual adapters carry a gateway (VPN or virtualization) and `FAIL` when no physical adapter is connected. Error-counter rows for adapters with no traffic during the sample, or for virtual adapters, are `INFO` — counters only testify when traffic flows. Primary-adapter selection for the company-standard comparison is unchanged.

IT diagnostics run on every run (each can be disabled under `Checks` in the configuration or with `-NoWifi` / `-NoTraceroute`), are `INFO` rows — what was collected, or a note that there was nothing to collect or no source on this machine — and `ERROR` rows when reading a source throws, carry `Scope = "IT"`, and appear in the collapsed IT section of the HTML report:

| Check | Source | Notes |
|---|---|---|
| Wi-Fi radio | `netsh wlan show interfaces`, parsed by value shape (MAC, GHz, 802.11x, percentage, numbers) because labels are localized and their order differs between Windows 10 and 11 | SSID, BSSID, band (inferred from the channel when the build prints none), channel, rates, signal %, RSSI (real when netsh prints it, otherwise estimated from the percentage) |
| IPv4 default routes | `Get-NetRoute -DestinationPrefix 0.0.0.0/0`, sorted by the effective metric (route metric + interface metric, the order Windows uses) | more than one route on different interfaces is called out in the details; a machine without a default route is an `INFO` row saying so, not a route-table error (1.2.3) |
| Gateway neighbor (ARP) | `Get-NetNeighbor` (fallback `arp -a`) | a missing or incomplete MAC is noted; the gateway ping stays the authoritative test |
| Proxy settings | HKCU Internet Settings, `WebRequest.GetSystemWebProxy`, `netsh winhttp show proxy` | explains "TCP to 443 passes but HTTPS fails" |
| Traceroute (first hops) | .NET `Ping` with TTL 1..N (default 3, maximum 10), 1000 ms per hop | target is the first non-AUTO ping target |
| Adapter drivers | NetAdapter `DriverVersion` / `DriverDate` / `DriverProvider` | physical adapters only |

IT-scoped rows never affect the overall result or the summary counts: `Get-OverallStatus` and `Get-SummaryCounts` exclude `Scope = "IT"`, and a failed IT collection shows as "Unable to Check" inside the IT section only (the whole IT step runs in that scope, so even an unexpected exception there cannot flip the verdict). Virtual-adapter counter rows are informational regardless of their deltas.

Every result now carries a language-neutral `Tag` (for example `ping-gateway`, `ping-near-end`, `dns`, `connectivity-group`, `tcp-retransmissions`, `wifi`), a `Scope` (`Main` or `IT`) and, since 1.2.8, a `Weightless` boolean (backlog #39): `true` on a row that keeps its badge, its message and its place in the counts but does not decide the overall result or the fingerprint. The field is **additive under `SchemaVersion: 2`** rather than a bump to 3, on this document's own rule that a consumer reads only documented fields — one it does not read cannot affect it, and the field list here is where a new field becomes part of the contract. Since 1.2.12 a `Rule` string is added on the same rule (backlog #67): set on ping rows only, `loss` where the loss band decided the status, `latency` where the replies that did arrive did, and empty otherwise. A fingerprint is computed from the tags — `local`, `gateway-unreachable` (a gateway row that lost its replies and none passed; its second line reads the near-end rung where one is configured), `gateway-up-internet-dead` (a required connectivity group failed and no group passed while the gateway answers), `dns` (only when no DNS check passed), `quality` (loss, latency — a gateway that answered every probe slowly included — retransmission or adapter-error warnings or failures, when nothing else failed), `attention` (other warning-only runs), `mixed`, `incomplete`, `healthy` — and drives the "What to tell IT" section at the top of the HTML and text reports; the JSON report stores it under `Fingerprint`.

Run options come from the entry point: `Start-NetworkCheck-IT.cmd` passes `-Interactive -ExpandDetails`; the switches `-PingTarget`, `-DnsName`, `-TcpTarget` (host:port), `-HttpUrl`, `-PingCount`, `-PingCountMaximum`, `-SampleSeconds`, `-TracerouteHops`, `-NoTraceroute`, `-NoWifi` add or tune this run only (inside one value, several ping / DNS / TCP entries may be separated by commas, semicolons or spaces, e.g. `-PingTarget 10.0.0.1,10.0.0.2`, and several URLs by spaces only, because commas and semicolons are legal inside a URL; from a shell, pass the list as one comma-separated or quoted value — a bare second value is refused by PowerShell before the script starts, since 1.2.7 binds nothing positionally, and an unquoted semicolon ends the statement at a PowerShell prompt) and are recorded in the report's run profile line and in the JSON `RunOptions` object (`EntryPoint`, `ExtraTargets` — the accepted values, `RawTargets` — the values as entered, `PingCount`, `PingCountMaximum`, `SampleSeconds`, `TracerouteHops`, `ChecksEnabled`). The IT panel's **two** ping spinners — the starting count and the ceiling — cover the configured `PingCountMaximum`, 21 by default, and the sample-seconds spinner 1–120 s; a configured value above these widens the spinner's range, so the configured value is displayed and an untouched Start runs with it (1.2.1). Until 1.2.10 the ping spinner opened at 20, a number nothing in the repository or the package explained, while the configuration validated no upper bound at all. The configuration file is never written. JSON `SchemaVersion` is 2.

## 5. Error-handling design

- Every major step is wrapped by `Invoke-CheckStep`; exceptions become `ERROR` results and later checks continue.
- `Get-ExceptionDetails` records exception type, message, and up to five inner exceptions. Since 1.1.4 the script position and call stack are collected separately by `Get-ExceptionDiagnostics` and stored only in the JSON report's `Diagnostics` field; the HTML and text reports show a one-line pointer instead, so local file paths never render in the human-facing reports. The emergency (`FATAL`) file still carries the full detail.
- A network error also carries a `Cause:` line in the report language, taken from the error code rather than from the operating system's wording: `SocketException.SocketErrorCode` and `WebException.Status` are enumerations, while the message text follows the machine's system locale and can therefore appear in another language inside this report (backlog #14). The line names the code as well (`[SocketError HostNotFound]`), a code the tables do not cover yields the code on its own, and the operating system's own message is always kept and always follows the cause — on the next line where the text is multi-line, after it on the one-line ping and traceroute entries. It appears in the exception details, in the per-attempt ping log, in the TCP and HTTP failure text and in a traceroute hop status. Errors raised by cmdlets, CIM/WMI or the file system have no such code and keep the operating system's wording unchanged. The tool's own DNS and TCP time limits are classified the same way since 1.2.3, as `[ToolTimeout]`: nothing replied and nothing refused within the configured limit, which is what a firewall dropping packets or an unreachable host looks like (backlog #27).
- GUI initialization failure falls back to console mode.
- An unwritable report directory falls back to `%TEMP%\NetworkHealthCheck\Reports`.
- HTML, TXT, and JSON are attempted separately. Since 1.1.5 a failed format is reported (log line, GUI warning dialog) while the formats that succeeded stay usable — "Open Report" opens the first available of HTML, TXT, JSON, and console mode prints "(not written)" for the missing one. Only when all three fail is a single emergency `FATAL` text report written (with the three write errors and their call stacks) and a single error dialog shown; console mode then exits with code 1. The report stage is handled once inside `Run-AllChecks` and never re-thrown, so the outer handlers no longer produce a second FATAL file or dialog.
- The launcher displays missing-file/PowerShell/non-zero-exit failures and attempts to write `LauncherError.txt`. Since 1.2.3 its suggested action follows the reason: a missing program file → extract the complete ZIP; exit code 3 (the language-mode guard) → read the environment report; any other exit code → read PowerShell's own message above the error and, if it names a signature or a policy, ask IT to allow the script (backlog #28).

## 6. Source design and comments

The program consists of 79 named functions grouped into helpers, configuration, system discovery, policy comparison, active tests, counters, reporting, orchestration, and GUI.

Version 1.1.0 adds:

- An architecture and safety overview at the top of each source file.
- Section comments before each major functional group.
- Existing local comments for fallbacks and edge cases.
- Traditional Chinese comments in the zh-TW source and English comments in the en-US source.

Comments focus on intent and risk rather than restating every obvious PowerShell statement. Function names and executable structure remain the same in both languages to reduce maintenance drift.

## 7. Validation approach

### 7.1 Static validation completed for this release

The build performed checks that do not require a Windows network environment:

1. Required files and directories exist.
2. Both JSON files parse as UTF-8 with BOM.
3. PowerShell/JSON use UTF-8 BOM and Windows scripts use CRLF.
4. English PowerShell, configuration, and README contain no Chinese user-facing text.
5. After removing strings and comments, the English and Chinese PowerShell executable skeletons are identical.
6. Both sources expose the same 79-function set.
7. Launchers reference `NetworkHealthCheck.ps1` correctly.
8. Every SHA-256 entry is recalculated and compared.
9. ZIP integrity tests report no damaged members.

The validator is `tools/validate_release.py`; run it against the package root to reproduce these checks. Current results are recorded in `../VALIDATION.md`.

### 7.2 Validation status on Windows

The original 1.1.0 package was produced in a non-Windows build environment, so Windows Forms, NetTCPIP, NetAdapter, CIM/WMI performance counters, and real network operations could not be executed at packaging time. Since then, versions 1.1.1–1.1.3 (2026-07-28/30) have completed full Windows validation on Windows 11 with Windows PowerShell 5.1: real-machine acceptance runs of both language versions, an independent code review, and five author-executed fault-injection scenarios. The current record is maintained in `../VALIDATION.md`. Version 1.1.4 (2026-09-03) closes backlog items #4, #5, #6, and #11 (threshold parsing, CIM-fallback gateway/DHCP semantics, dead stores, stack traces kept out of HTML/TXT) and was re-validated with the same chain: parser, validator, helper unit tests, acceptance runs of both languages, and a fault-injection configuration. Version 1.1.5 (2026-09-03) closes backlog items #2 and #3 (single emergency report; partial report-write failures keep the successful formats usable) and was validated with the same chain plus report-stage functional tests that stub the file writer. Version 1.2.0 (2026-09-03) implements Phase A of the v1.2 design (`docs/design-v1.2-triage-wizard.md` in the repository): adapter classification, IT diagnostics, the fingerprint and "What to tell IT" section, JSON schema 2, and the IT entry point. It was validated with the same chain plus the extended unit tests (Wi-Fi parser on Windows 10 / 11 / localized samples, classification) and functional tests of the run options and fingerprint. Version 1.2.1 (2026-09-03) closes the one finding of the seventh Codex pass on the v1.2.0 pull request, which completed after the merge (the IT panel no longer truncates a configured ping count or sample length that exceeds the spinner defaults), and fixes two 1.2.0 regressions found by the first real GUI runs of that version. First, six control positions were written as `New-Object System.Drawing.Point(22, 84 + $offset)`, which PowerShell parses as a three-element argument list because the comma binds tighter than `+`, so `Initialize-Gui` threw and both entry points silently fell back to console mode. Second, the script-level initialization `$script:Interactive = $false` overwrote the bound `-Interactive` parameter (a script's top-level scope and its `$script:` scope are the same), so `Start-NetworkCheck-IT.cmd` opened the user layout and auto-started instead of showing the run-options panel. The arithmetic is now parenthesized, the initialization takes the parameter's value, a static guard rejects both patterns (inside this validator up to 1.2.1; on the PowerShell AST in the repository's test chain since 2026-09-04, which is why the packaged validator ran 62 checks rather than 66 through 1.2.3; the document checks joined in 1.2.4), and both entries were exercised through the real window (UI Automation) in both languages in addition to the usual chain. Version 1.2.2 (2026-09-04) closes backlog items #14 and #18. A network error is now classified by its error code (`SocketException.SocketErrorCode`, `WebException.Status`) rather than by the operating system's wording, so the cause is stated in the report's language while the original message is kept beneath it. And a guard ahead of every other line detects a restricted PowerShell language mode - what application control (WDAC / AppLocker) creates, where a script may not create the .NET objects this tool needs from its first line - and writes `NetworkHealthCheck_ENVIRONMENT_<time>.txt` naming the mode, the machine and what IT can do, instead of failing with an engine message no user can act on. The validation chain gained a console run against unreachable targets, so the failure paths are executed on every run, and a case that starts the script in a restricted mode. Static validation still does not replace Windows acceptance testing — the two complement each other. Version 1.2.3 (2026-09-06) closes backlog items #26, #27 and #28, the findings of the first acceptance campaign on a Windows 11 virtual machine: the compressed-folder detection recognizes the Windows 11 view folder (`<guid>_<name>.zip.<hex>`) as well as the Windows 10 one; a machine without an IPv4 default route is reported as such instead of as a route-table error, and the tool's own DNS and TCP timeouts carry a cause line like every other network failure; and `LauncherError.txt` suggests the action that fits the reason the launcher stopped. Version 1.2.4 (2026-09-07) is a documents release: the end-user manual and the IT deployment manual join the package in both languages, each as markdown and as a single HTML page; the user READMEs are absorbed by them and retired — the quick-start half by the user manual, the configuration notes by the IT manual — and the validator checks the version string in every document that carries one; the tool itself is unchanged. Version 1.2.5 (2026-09-08) is a documents release as well: the six findings of a walk of the user manual by a person on a Windows 11 machine, every one of them the manuals' and none the scripts' - the tool's own eight-second limit on the retransmission counter read is named among the causes of an unreadable counter; all three of the small-sample messages are covered where one was, including the one that turns the verdict to Attention Required; the PowerShell path that `LauncherError.txt` also carries beside the launcher is named; the reports written into a folder OneDrive backs up are said to reach the cloud as they are written, which is what the package extracted to a Windows 11 Desktop does; the folder that Extract All leaves inside the extracted folder is described where the reader meets it; and the security dialog's unverified publisher is answered with the tool's lack of a signature and with the digest IT compares against the release notes. The tool is again unchanged, and the walk's tool findings are backlog #38 to #47. Version 1.2.6 (2026-09-09) is a documents release as well, and it comes from the same walk in the other language: a person walked the Traditional Chinese user manual on a Traditional Chinese machine, and two sentences did not survive it - the manual quoted a publisher phrase that dialog does not use on such a machine, and all four manuals named the IT panel's extra-TCP field by a label the panel cannot show, since `Extra TCP (host:port)` is 134 px of text in the 100 px box the panel gives it (153 px in the Traditional Chinese package) and its second line is clipped. The format now stands in the text, with an example value, instead of in a label nobody can read. The tool is unchanged again, and that walk's tool findings are backlog #49 and #50. Version 1.2.7 (2026-09-09) is the first release since 1.2.3 to change the tool itself, and every one of its six items is about what the screen says at the moment it says it. The IT panel's labels carry their own widths, so the one that wrapped and lost its second line in both languages fits, and the headless GUI step measures every control's text against its box in both languages (#49). The panel parses a typed extra TCP target before the run starts, with the rule the run itself uses, marks the field, names an example value, and starts on a second press without that target; every free-text field shows an example on hover (#45). The window and the console name one file to send rather than a path and three paths, and the summary's last line names the same one (#46). That summary claims what the verdict actually made - all required checks passed - and names an optional target that did not answer (#35). The report's notice explains the Unable to Check badge only when a row carries it, and the retransmission rate only when a rate was computed (#40). And a stray value on the command line is refused by PowerShell instead of binding to -ConfigPath and losing a target in silence (#36). Version 1.2.8 (2026-09-09) is about a measurement the tool lost and the seconds it never accounted for (backlog #38). A performance-counter read that runs out of its eight seconds is attempted a second time, and only a second failure writes the Unable to Check row, whose status, name and message are unchanged; the baseline snapshot takes one throwaway read per class before the sample window opens, so that whatever a first query of the provider costs is paid outside the measurement; every attempt that failed is kept with the seconds it spent, even where a later one succeeded, and the rows are written from that record; each row's sample duration is computed from its own protocol's two stamps rather than from the enclosing snapshots' and is printed beside the configured minimum; and a window that ran long names the reads that lengthened it. Where nothing failed, the status, the message and every count are what they were; two things in the details are not, and are the point of the release: the sample duration is that protocol's own window rather than the span of the snapshots enclosing it, and the configured minimum stands beside it.

### 7.3 Recommended Windows acceptance matrix

| Scenario | Expected result |
|---|---|
| Windows 11, standard user, healthy DHCP | GUI completes; HTML/TXT/JSON are created; core connectivity passes. |
| Wi-Fi disabled/cable removed | Adapter/gateway/DNS failures appear; a report is still created. |
| DHCP failure with 169.254.x.x | APIPA check is `FAIL`. |
| Invalid JSON | Error is shown/reported; built-in defaults continue. |
| Read-only report folder | Output falls back to `%TEMP%` with a notice. |
| PowerShell blocked by policy | Launcher shows the reason and attempts `LauncherError.txt` with the action that fits the reason. |
| GUI components unavailable | Automatic console fallback or manual console launcher works. |
| DNS blocked | Required DNS fails while IP/TCP tests still execute. |
| TCP port closed | Required target fails; optional target is informational; group uses other members. |
| HTTP returns 403/500 | Path is reachable and status code is retained. |
| Adapter reconnects | Counter reset warning appears; no negative delta is reported. |
| Sufficient TCP traffic | Deltas match before/after CIM values for TCPv4/TCPv6. |

Acceptance should cross-check reports against `Get-NetIPConfiguration`, `Get-NetAdapterStatistics`, raw CIM/WMI counters, and the organization's network plan.

## 8. Known limitations

1. **Windows only.** Intended for Windows 10/11 and compatible Windows Server with PowerShell 5.1 or later.
2. **Not a packet analyzer.** It does not capture packets or inspect ACK/sequence numbers and cannot prove a per-flow root cause.
3. **Short, system-wide TCP sample.** Background updates, browsers, and other programs affect the numbers; zero traffic means insufficient evidence.
4. **ICMP may be blocked.** Ping failure does not prove that TCP/HTTPS is unavailable.
5. **Multi-adapter/VPN aggregation.** One adapter may satisfy part of a rule; complex environments need adapter/type/route filtering.
6. **No VLAN, switch, or radio telemetry.** It cannot directly read VLAN IDs, switch CRCs, optics, Wi-Fi signal/channel congestion, or AP roaming logs.
7. **Cannot infer an unspecified company standard.** Empty Expected rules display current state only.
8. **HTTP GET reaches the target service.** Use approved, side-effect-free health URLs. Targets may log source IP, User-Agent, or proxy-authentication activity.
9. **Thresholds require calibration, because the shipped values have no external basis.** The twelve values of the thresholds block that backlog #56 examined are operational defaults chosen without a standard, a measurement or a recorded reason behind any of them — two of them the policy *any at all is worth showing* (the adapter error and discard warning deltas of 1), ten of them magnitudes somebody picked — and the thirteenth, `MinimumTcpRetransmissionsForVerdict`, added in 1.2.10, has its reasoning recorded (backlog #51) and no external basis either. The published standards do not supply one: they define how to measure, or set objectives for a named service class over a named scope, never a general *above X % the network is faulty*. What was examined, what each source actually defines, and the date each was verified against its source are recorded once, on the repository's threshold page at the version this guide belongs to — <https://github.com/kevintechin/network-support-toolkit/blob/v1.2.12/docs/thresholds.md> — and in its current form on the `main` branch (decided 2026-09-10; the IT deployment manual's threshold table names each value as such). Defaults are not guaranteed for Wi-Fi, VPN, satellite, international WAN, data center, or high-throughput servers.
10. **Policy and endpoint security can block data.** AppLocker, WDAC, EDR, WMI policy, or damaged performance counters produce `ERROR`, not proof of a network defect.
11. **Reports contain sensitive data.** Computer/user names, MAC/IP/DNS, internal services, and exception stacks (JSON report only, with local script paths) may be present.
12. **No automatic repair.** Diagnosis is intentionally separated from configuration changes.

12. **Wi-Fi data is client-side and text-parsed.** `netsh` output is parsed by value shape; an unusual build may leave a field empty, and the RSSI is estimated when the build does not print it. The access point's client table is the stronger evidence.
13. **Adapter classification without NetAdapter flags is heuristic** (description patterns).
14. **Traceroute is bounded** to 10 hops and 1 s per hop; silent hops show as `*`, and the default 3 hops rarely reach a public target — the goal is to see where packets stop, not to reach it.
15. **A whole-window average cannot tell a burst from an even spread.** The retransmission counters are read twice, at the two ends of the window, so fifty retransmissions inside ten seconds of it and fifty spread evenly across the whole of it produce the same two numbers. Until 1.2.10 the standalone count trigger fired on either and named neither, which is why it was removed; reading the counters at intervals inside the window is what would answer the question, and no release does that yet.
16. **Rung differences are not segment figures.** The ping ladder — near-end host, gateway, far end — is cumulative: a rung that fails puts the problem beyond the last rung that passed, and the loss figures of two rungs cannot be subtracted into a figure for the segment between them, because they are separate traffic at separate moments. Nothing computes per-hop loss from TTL-limited probes, and nothing should: an intermediate hop's reply is an ICMP error from its rate-limited control plane, so per-hop percentages show loss at hops that forward perfectly.

## 9. Release and maintenance guidance

- The IT deployment manual in the package (`NetworkHealthCheck_IT_Deployment_Manual_*.md`, since 1.2.4) is the operational form of this section: the configuration file key by key, deployment, verification of the package, and what security policy does to the tool.
- Replace default public targets with organization-approved services before broad deployment.
- Establish baseline reports for wired, Wi-Fi, VPN, and restricted-internet environments.
- After editing `.ps1`, rerun static validation and Windows acceptance and regenerate SHA-256 values.
- Deploy the whole folder rather than a single launcher.
- For precise retransmission diagnosis, correlate report timestamps with Wireshark, pktmon, switch counters, or centralized monitoring.
