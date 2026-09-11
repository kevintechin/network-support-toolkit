# Network Troubleshooting SOP

**From the user's chair to the ISP — a fault-isolation playbook**

Version 1.2 · Kevin (Te-Chin) Lin · September 2026

---

## Principle

**Follow the packet, not the device list.** Every step states three things: what I check, what healthy looks like, and where I go if it's broken. Change one thing at a time, and predict the result out loud before you test it.

---

## Station 0 — Profile the Reporter (30 seconds)

Support engineers rarely touch the broken network directly; we work through the person reporting it. Who that person is decides what evidence you can trust and what actions you can delegate.

**Calibration:** ask *"Are you comfortable running a command in a terminal?"* — and listen to their vocabulary (*"the network is down"* vs *"DHCP isn't handing out leases"*).

| | IT professional | General user |
|---|---|---|
| **Delegation** | Commands by name, several in parallel | One action at a time, exact click path |
| **Evidence** | Paraphrase acceptable | Raw output only — read back or screenshot |
| **Pace** | Match theirs | Confirm each step before the next |

Same action, two scripts:

- **IT:** "Run `ipconfig /all` and paste me the output."
- **User:** "Click Start, type **cmd**, press Enter. In the black window, type **ipconfig /all** — then read me the line that says *IPv4 Address*."

---

## Front Door — Four Isolation Questions

Cut the search space before touching anything.

1. **Blast radius** — One user or many? One VLAN / SSID / location, or all? Wired and wireless both?
   *(One user → endpoint. One switch → uplink. Everyone → gateway or ISP.)*
2. **What changed?** — Config, firmware, new device, cabling work, power event?
3. **Failure fingerprint** — pick the lane:
   | Fingerprint | Lane |
   |---|---|
   | **No IP** (169.254.x.x) | DHCP path: port VLAN → uplink → relay → server |
   | **IP, but gateway unreachable** | Local L1/L2: cable or RF, port, VLAN |
   | **Gateway OK, internet dead** | Routing / NAT / firewall / ISP |
   | **IP works, names fail** | DNS |
4. **Constant or intermittent?** — Intermittent points at performance causes: RF interference, congestion, duplex mismatch, retransmissions.

**Sketch the path while you ask.** The blast-radius answer already names the devices between the reporter's machine and the point where the traffic fails. Draw them in a line now — five boxes on paper — rather than at escalation time: the sketch is what you mark up as stations are excluded, and it is the first item in the package below.

---

## The Packet's Journey — Station Map

> Format per station: **Read state → Verify config** → **Healthy looks like** → **If broken, go…**

### 1 · PC / Client

- **Read state:** `ipconfig /all` — lease details and the **DHCP Server** field; ping ladder — loopback → gateway → `8.8.8.8` → a domain name; `arp -a`; `tracert`.
- **Verify config:** NIC set to DHCP — no stale static IP or DNS override.
- **Healthy:** valid lease from the expected scope; ladder climbs all four rungs.
- **If broken:** APIPA (Automatic Private IP Addressing) → DHCP lane (stations 3–5). Wrong-scope IP → port VLAN (station 3). Ladder breaks at a rung → that rung names your next station *(corroborate the failed rung first — Rule 3)*.
- *One-click evidence: NetworkHealthCheck (see Tools).*

### 2 · Wi-Fi Link — RF + AP *(wireless cases)*

- **Read state:** client sees the SSID? AP client table — associated vs **authenticated**; RSSI ≥ **−65 dBm**, SNR ≥ **25 dB** as the AP sees them (client side: `netsh wlan show interfaces`); RADIUS log — **Access-Reject** is fast and appears in the server log; a **timeout** is slow (AP retries) and the server log stays silent; channel utilization and client count.
- **Verify config:** the SSID's security settings — current PSK (*forget network and rejoin*) or 802.1X server and shared secret.
- **Healthy:** associated, authenticated, sane RF numbers.
- **If broken:** auth fails → credentials / RADIUS. Poor RSSI → coverage or interference. Associated but no IP → continue to station 3 (the AP's wired side).
- *Order of operations: 802.1X gates the connection — DHCP starts only after authentication succeeds. "Authenticated but no IP" means the wireless part is already done and healthy.*

### 3 · Access Switch

- **Read state:** port up and not err-disabled; client MAC learned on the expected port, in the expected VLAN; error-counter delta (two samples, 30–60 s apart — **CRC / alignment errors say physical; discards say congestion or policy**).
- **Verify config:** port **VLAN + PVID** — tagging governs frames going **out** (egress); PVID assigns **incoming untagged** frames (ingress); AP uplink **tagged for every SSID VLAN + AP management VLAN**.
- **Healthy:** link up, MAC in the table, VLANs match the design, counters clean.
- **If broken:** VLAN/PVID mismatch → fix here, retest. Errors climbing → cable/SFP/duplex. Port RX climbs but no MAC learned → something is eating frames after arrival: STP, port auth (802.1X / port security), or LAG state.

### 4 · Uplink / LAG

- **Read state:** LAG up with **all members active**; LACP partner status per member; per-member traffic counters; STP state **forwarding** — a port STP has blocked is up but passes nothing, which looks exactly like a dead link.
- **Verify config:** same LAG type on both ends — prefer **LACP** (negotiated: a mismatched port refuses to join) over **static** (no negotiation: a misconfig stays silently up); **VLANs tagged on the LAG interface itself (e.g., ch1) — member-port settings do not carry over**.
- **Healthy:** members active, LACP negotiated, VLANs ride the LAG.
- **If broken:** members missing → membership / port properties. Negotiated but traffic dies → the LAG interface's VLAN membership, both ends.

### 5 · Core & Gateway

- **Read state:** the client VLAN's gateway answers — its **SVI** (Switched Virtual Interface: the VLAN's gateway IP living on the L3 switch); the gateway's ARP table sees the client; DHCP lease table and **scope utilization** (a full scope hands out nothing while the server looks perfectly healthy); default route active in the routing table.
- **Verify config:** **DHCP server or relay (IP helper)** configured for that VLAN.
- **Healthy:** gateway answers from the client VLAN; leases flow.
- **If broken:** relay missing → DHCP lane root cause. No default route → routing.

### 6 · Firewall / NAT *(triage depth)*

- **Read state:** policy **hit counters** for the source; **NAT translation** created; session table entry and state; deny logs; WAN interface up with the expected IP.
- **Verify config:** the permit rule itself — source / destination / service, and rule order.
- **Healthy:** permits hit, translations build, sessions establish.
- **If broken:** locate and collect evidence here — fix what's in scope, escalate the rest with the package below.

### 7 · DNS

- **Read state:** `nslookup` against the configured server, then against a known-good resolver — and read the failure type: timeout vs SERVFAIL vs NXDOMAIN.
- **Verify config:** which DNS servers the client actually points at — DHCP-assigned or a static override.
- **Healthy:** both resolve.
- **If broken:** configured-only fails → internal DNS/forwarder. Both fail (IP ping still OK) → upstream filtering or ISP.

### 8 · ISP / Beyond

- **Read state:** modem/ONT line stats — sync, SNR margin, CRC; WAN IP sanity (public vs CGNAT); last responding `tracert` hop; provider status page.
- **Verify config:** WAN settings — PPPoE credentials, ISP handoff VLAN tag.
- **If broken:** open the provider ticket **with your evidence package** — you've already excluded everything on your side.

---

## Read State Before Config

Config tells you what the network is **supposed** to do; state tells you what it is **actually** doing. Read state first — it needs no design document, it cannot lie, and it is read-only. Then open config to confirm the root cause.

Three families of state:

- **Tables** — the network's memory: MAC, ARP, AP client list, DHCP leases, firewall sessions.
- **Counters** — always read as a **delta**: two samples, 30–60 seconds apart.
- **Probes** — differential tests: two pings that differ in exactly one thing (ping the IP vs ping the name — if one works and one fails, that one difference names the fault).

Two discriminators, used in order. **Counters first:** climbing CRC or alignment errors mean physical — cable, SFP, duplex. (Discards are a different story: congestion or policy, not physical.) Clean counters largely clear the physical layer. **Then the VLAN probe:** a fault that hits one VLAN but spares another on the same wire is config — **physical faults are VLAN-blind; config faults are VLAN-selective.** Mind the asymmetry: VLAN-selective failure proves config, but all-VLANs-dead proves nothing by itself — a whole-link config error (LAG, STP, admin state) looks just like a dead wire. The station cards above embody this order — every **Read state** block comes before **Verify config**.

**Counter reference** — read as deltas; absolute values are history, not evidence:

| Counter | Climbing means | Which drawer to open next |
|---|---|---|
| **CRC / FCS errors** | Frames arriving corrupted — cable, connector, SFP, EMI, duplex | **Physical — the reliable convict** |
| Alignment / runts | Collisions, duplex mismatch | Physical / negotiation |
| **Late collisions** | The classic duplex-mismatch signature | Physical / negotiation |
| Giants (oversize) | MTU / jumbo-frame inconsistency between ends | Config |
| RX / TX **discards** | Valid frames dropped — buffers, QoS, storm control | Congestion / policy |
| Broadcast share spiking | Loop or storm | Config / loop |
| Link flaps (up/down count) | Unstable link or far-end reboots | Physical / power |
| **RX near zero** | Far end down, admin-down, or a broken pair — **ambiguous, never convict on this alone** | Needs a second witness (Rule 3) |

*Two caveats: counters only testify **when traffic flows** — a dead link shows zero errors, which clears nothing. And CRC counts at the **receiver** — the fault lies somewhere between the far-end transmitter and this port (cable, patch, SFP, either end).*

**Directional probe** — send a known burst, `ping -n 20 <gateway>`, and read deltas at **both ends**: NIC TX moves but switch-port RX doesn't → the outbound leg is broken; switch TX moves but NIC RX doesn't → the return leg. One test, direction resolved.

**Segment probe — the three-way comparison.** The ladder one machine can climb — a near-end host on its own subnet, its gateway, a far-end address — is cumulative, so a rung that fails places the fault *beyond the last rung that passed*, and two rungs' loss figures never subtract into a figure for the segment between them: they are separate traffic at separate moments. Separating the air from the wire takes a second machine: a **wired** client and a **wireless** client on the same segment, first against the **same local host** (a printer or server on that subnet — never the gateway, whose control plane rate-limits pings to itself), then both against the **same external target** — every probe bound to its own source address (`ping -S <source-ip> <target>` on Windows), so that a multihomed machine cannot answer through the other interface. Loss on the wireless client's local leg and none on the wired one's points at the air; loss on both local legs points at the switch or the host; clean local legs with loss on both external legs points at the gateway or beyond — each a suspect to corroborate, not a conviction. Prerequisite: a wired host on the segment — without one the comparison cannot be made, and the wireless client's own signs (retries absorbed as delay, a roam during the test) are all there is. And never per-hop loss from TTL-limited probes: an intermediate hop's reply is an ICMP error from its rate-limited control plane, so per-hop percentages show loss at hops that forward perfectly; only loss that persists to the final destination is evidence. *(The companion tool's `NearEndTarget` puts the first rung in every report of a site that names one; the comparison itself is the engineer's.)*

| St. | Key observable | What it tells you |
|---|---|---|
| 1 | `arp -a` — gateway MAC resolved? | L2 path proven without ICMP (Rule 3's second witness) |
| 1 | DHCP Server field in `ipconfig /all` | Who actually answered — rogue-DHCP detector |
| 2 | AP client table — state, RSSI, data rate | Absent = RF/SSID · auth-pending = credentials · low rate = coverage |
| 2 | RADIUS log — reject vs silence | Reject = bad credentials · silence = AP↔server path or secret |
| 3 | MAC table — client on expected port, in expected VLAN | Frame arrived **and** was classified; wrong VLAN here = PVID fault |
| 3 | Port error counters, sampled twice | Climbing delta = physical: cable / SFP / duplex |
| 4 | LACP partner info per member | No partner = far end not running LACP · out-of-sync = property mismatch |
| 4 | Per-member traffic counters · MAC table on ch1, per VLAN | Idle member = not bundling · a VLAN with no MACs on ch1 = tagging fault |
| 5 | Gateway's ARP for the client · DHCP lease table, scope % | Gateway sees client = path proven · DISCOVERs but no lease = scope exhausted |
| 6 | Session table · policy hit counters for the source IP | A deny counter ticking while the user retries = the smoking gun |
| 7 | Failure type: timeout vs SERVFAIL vs NXDOMAIN | Timeout = path · SERVFAIL = server · NXDOMAIN = record / split-DNS |
| 8 | WAN line stats (sync, SNR margin, CRC) · last `tracert` hop | Line-level truth · the last responding hop names the boundary |

---

## Three Rules That Keep You Honest

- **Fix one, test one.** State the expected outcome before you retest. If the result doesn't match the prediction, revert before trying the next idea.
- **Close the loop end-to-end.** Valid IP → ping gateway → ping external IP → resolve a name → open the app the user actually cares about. Then confirm with the user, and write it down.
- **A failed ping is a suspect, not a conviction.** ICMP is often blocked or deprioritized. A successful ping proves the path; a failed one needs a second witness — `arp -a`, `tracert`, or a TCP/HTTP test — before you act on it. *(This is also why the companion tool tests TCP and HTTP alongside ICMP.)*

---

## Escalation — When, and With What

**When to escalate — rules, not feelings:**

- The **timebox** expires without isolation — the pre-set window is the signal
- The fix needs **access or authority** you don't have — firmware, code-level debugging, config ownership
- **Severity** says so — site-down or many-users impact escalates early, by policy
- Your layers are **excluded** — the evidence points the remaining suspects into L3's domain (bug, hardware, design)

**The package** — a good escalation lets L3 start at your frontier instead of from zero:

- Topology sketch of the affected path (hand-drawn is fine)
- Blast radius, timeline, and what changed
- **What you excluded, with the evidence that excludes it**
- Raw outputs: ipconfig / ping / tracert (or the NetworkHealthCheck report), relevant switch & AP status pages
- **Device logs** (switch / AP / firewall) covering the failure window, and **config exports** of the devices in the path
- Reproduction steps, and the current workaround if any
- Business impact and severity

### Collecting the infrastructure evidence

The sketch, the device logs and the config exports are collected from the devices, and the package is only as good as what they contain. What each has to show:

**Topology sketch — the affected path, not the network.** Every device the traffic crosses between the reporter's machine and the point where it fails, in order. For each one: the device and its management IP, the port the client or the next hop sits on, that port's **VLAN and PVID**, and how the device connects upward — uplink port or LAG, with its member ports. For a wireless case add the AP, the SSID and the VLAN it maps to, and the AP's own uplink port. Five boxes in a line beat a site diagram: the whole network takes an hour to draw and tells L3 less. Mark where your evidence stops — the last device you could actually read.

**Device logs — the failure window, with a margin.** Which devices: the ones on the path — the access switch, the AP or its controller, the firewall — and the server whose lane is in play: DHCP, RADIUS, or the DNS resolver or forwarder the client actually points at. Take the window **with a margin on both sides** — starting before the first report, because the event that explains a failure usually precedes what the user noticed, and ending past the recovery. **A hand-off while the fault is still live has no recovery to end at** — the timebox and the severity rules both produce one — so run the window to the moment you export, say in the ticket that it is still open, and send a second export once it recovers. Record each device's **time zone** and whether its clock is synchronized: logs from two devices whose clocks disagree cannot be put on one timeline. Where a clock is not synchronized, read it against a reliable reference at the moment you export and **write the offset down** — the number of minutes, not just the fact — because that is what lets L3 shift those events onto the shared timeline; an unsynchronized clock belongs in the ticket rather than being quietly corrected for. Export text where the device offers it; a screenshot of a log page is evidence for one screen. **A log can carry a secret as well** — a token in a logged URL, a password typed into the username field, an authentication debug trace — so it travels under the same rule as a config export: read it before it goes, and redact what you find. Screenshots too.

**Config exports — the running config, with the secrets out.** The **running** configuration of each device on the path — that is what the device is doing now; where the device also keeps a startup copy, a difference between the two is itself a finding: a change nobody saved, or a reboot that would undo it. **Take it before your first change.** A config exported after you have touched something records the state you made, not the one the fault happened in — take a timestamped copy before the first change and keep the later ones, so the pair lets L3 check what the report template's *What was tried* table says you did. **Take the secrets out before the file travels** — before it is attached to a ticket, pasted into a chat, or copied to a share. **The rule is every password, key, token and credential in the file, and it is not a list to tick off:** read the export through once looking for anything that would let someone in. The ones most often left behind are SNMP community strings and SNMPv3 auth/priv keys, Wi-Fi PSKs, RADIUS and TACACS shared secrets, local account credentials and their hashes, VPN pre-shared keys, private keys and the passphrases that protect them, routing-protocol authentication keys, and API or controller tokens — but a config you have not read is not a config you have cleaned.

**Before any of it travels: redact the value, not the line.** Replace the secret itself with a visible marker and leave the rest of the line standing: an SNMP community line also carries its access mode and its ACL, a routing-protocol key line carries its key id, and those are exactly what L3 has to check. **A public certificate is not a secret either** — its issuer, its subject and SAN, its validity dates and its chain are often the evidence itself when a certificate-backed RADIUS, VPN or TLS handshake is what failed — so take out the private key and leave the certificate standing. A whole line deleted silently reads as a setting that was never there. And a password the device prints in its own encrypted or hashed form is still a secret — some of those forms reverse trivially, and the rest are worth an offline attack — so redact it like any other rather than trusting the display.

**What you could not get travels too.** Say which of the three you could not obtain, and why — no access, a third-party-managed device, logs already rotated out. The package asks for *what you excluded, with the evidence that excludes it*: a station whose evidence you never obtained is **not excluded**, it is unexamined, and a blank line invites L3 to assume somebody looked. The [support report template](support-report-template.md) carries a row for each of the three, with columns for why an item was not obtained and what its absence does to the analysis.

---

## Fingerprint Library — fast lookups

| Symptom | First suspect |
|---|---|
| 169.254.x.x address | DHCP unreachable — VLAN, relay, or scope exhaustion |
| Ping 8.8.8.8 OK, browsing fails | DNS |
| Some sites fine, VPN / large uploads fail | MTU / fragmentation |
| One user down | Endpoint — port, cable, NIC, profile |
| Whole switch down | Uplink / LAG / switch power |
| Whole site down | Gateway, firewall, or ISP |
| Wireless-only and intermittent | RF interference, roaming, band steering |
| Reboot fixes it, keeps returning | DHCP scope, duplicate IP, or a loop |
| Connected but slow | Duplex mismatch, port errors, retransmissions |
| Link negotiates 100 M instead of 1 G | Damaged pair or connector — gigabit needs all four pairs |

---

## Tools

- **NetworkHealthCheck** (companion tool) — portable, read-only Windows health check that a non-technical user can run with one double-click; produces HTML / TXT / JSON reports that drop straight into the escalation package. Roadmap v1.2: one run for everyone (user summary plus collapsed IT diagnostics), an IT entry point, and a guided triage wizard over this SOP — see docs/design-v1.2-triage-wizard.md.
- **Wireshark / pktmon** — when packet-level proof is required.
