# Support Report Template

**One skeleton, two fill patterns — the hand-off that goes to L3, and the delivery that goes to whoever asked**

Version 1.0 · Kevin (Te-Chin) Lin · September 2026

Companion to the [Network Troubleshooting SOP](network-troubleshooting-sop.md) and the [Support Engineer's Field Manual](support-engineer-field-manual.md).

---

## How to use it

**Copy sections 1 to 9** — everything between the rule below and the line that says the template ends. The filled example after it is an illustration and must never travel into a ticket: it carries a real lab machine's name and measurements that are not yours.

Each section carries a marker:

- **`[both]`** — fill it in whichever report you are writing
- **`[hand-off]`** — for an escalation to L3; delete it for a delivery report

A marker can also sit on a **block inside** a section: §8 is `[both]` because its closure block belongs in every report, while the request to L3 inside it is `[hand-off]` and goes with the rest. One sits on a **column**: §3's infrastructure-evidence table is `[both]`, but the column naming the devices, the ports and the people is `[hand-off]` — delete the column, keep the rows.

**A delivery report is this document with the `[hand-off]` sections removed** — the same facts in the same order, about a page. There is deliberately no second structure for it: the person reading the delivery report today may be the one reading the hand-off tomorrow, and two shapes for one case is how details go missing between them.

Three rules for filling it in:

- **Write what you measured, not what you concluded from it.** The conclusion has a section of its own, and a reader who cannot separate the two cannot check either.
- **Every exclusion carries its evidence beside it.** "The cable is fine" is not an exclusion. "Port error counters clean across two samples 60 s apart, while the link carried traffic" is.
- **Leave a field empty rather than guessing.** An empty field is information — it says nobody has looked yet. A filled-in guess reads exactly like a measurement to whoever picks the case up next.

---

## 1 · Identity `[both]`

| | |
|---|---|
| Ticket / case | |
| Reporter, and which track | *name* — IT professional / general user (SOP Station 0) |
| Site / location | |
| Machine | *the computer name as the report header shows it* |
| First observed / reported at | |
| Written by / at | |

## 2 · Symptom, in the reporter's words `[both]`

| | |
|---|---|
| **They said** | *quote them* |

> *Their words are evidence about what they can and cannot see; your paraphrase is not.*

**Front door** — the four isolation questions, answered before anything was touched:

| | |
|---|---|
| **Blast radius** | one user · one VLAN / SSID / location · everyone — wired, wireless, or both |
| **What changed** | config, firmware, new device, cabling, power — in the last 24–72 h |
| **Failure fingerprint** | no IP (169.254.x.x) · IP but gateway unreachable · gateway OK but internet dead · IP works, names fail · **IP, no gateway configured** — *the last is the case the SOP's four lanes do not name; the tool reports it as `local`, and it is a client-configuration branch rather than L1/L2 (field manual §4.1)* |
| **Constant or intermittent** | *intermittent points at RF, congestion, duplex, retransmissions* |

**Timeline** — *the SOP asks for it beside the blast radius, and "first observed" is not one. Outages, recoveries, recurrences, and what you did, in the order they happened.*

| Time | Event |
|---|---|
| | |
| | |

## 3 · What was measured `[both]`

**NetworkHealthCheck runs**

| # | When | Entry point / mode | Verdict | Fingerprint | Note |
|---|---|---|---|---|---|
| 1 | | *user or IT* — *GUI or console* | Overall Healthy · Attention Required · Test Incomplete · Problem Detected | | |

*Targets added for this case, and what they returned:*

> A target you add is **optional**, and what it does to the verdict depends on **how** it fails: a **ping** that gets no reply at all, and a **TCP or HTTP** target that cannot connect, are `INFO` rows and leave the verdict alone; a degraded reply, and a **DNS name that will not resolve**, are `WARN` and move it to `Attention Required`. Record what every added target returned here **even when the report came back healthy** — see the field manual, §3.

| Target | Probe | What the row said | Row status |
|---|---|---|---|
| | ping · TCP · HTTP · DNS | | PASS · INFO · WARN · FAIL |
| | | | |

**Other measurements** — switch, AP, firewall, or anything read by hand:

| What | Where read | Value |
|---|---|---|
| | | |
| | | |

**Infrastructure evidence** — the topology, the device logs, the configuration exports:

> **"No" is a normal entry.** These three do not come from the endpoint and none of them is guaranteed; the row is filled in either way. What each has to contain when you do get it is in the SOP's *Collecting the infrastructure evidence*. The last column is the point of the table: an item you could not obtain changes what the case may claim, and that is a finding rather than an empty line.

| Evidence | Obtained | Source and coverage `[hand-off]` | If not obtained, why | Effect on the analysis |
|---|---|---|---|---|
| Topology of the affected path | yes · partial · no | *who drew it; which devices and ports it covers, and where it stops* | | |
| Device logs covering the failure window | yes · partial · no | *which devices; the window they cover, and whether their clocks agree* | | |
| Config exports of the devices in the path | yes · partial · no | *which devices, and that the secrets were removed* | | |

*The third column names devices, ports and people: it is `[hand-off]` — delete that column for a delivery report and keep the rest. Reasons that belong in the fourth: no access, the reporter does not know, a third-party-managed device, logs no longer retained, the window already rotated out. The fifth is written so that either report can carry it — "the switch's records were not available, so the port's VLAN is unverified" — and §4 and §5 have to agree with it.*

## 4 · What is excluded, and by what evidence `[hand-off]`

*This is the section that lets L3 start at your frontier instead of from zero. One line per exclusion; no line without its evidence.*

| Excluded | Evidence that excludes it |
|---|---|
| | |

*An exclusion rests on evidence you actually obtained. Where §3's infrastructure-evidence table says **no**, the station it covers is **not excluded** — it is unexamined; write it into §5's second field as still open rather than leaving it out of both, because a station absent from this table and from §5 reads as one nobody considered.*

## 5 · Where the fault is isolated to `[both]`

| | |
|---|---|
| **Station / domain** | |
| **What the evidence points at, and what it does not** | |

*Two or three sentences in that second field. If the isolation is partial, say which way it is partial — "somewhere between the access port and the gateway" is a useful sentence; "network issue" is not.*

## 6 · What was tried `[hand-off]`

**How to reproduce the failure** — *the steps someone else can follow, or "not reproducible on demand" with what is known about when it appears. Without this, L3 starts by trying to make it happen.*

| | |
|---|---|
| Steps | |
| Reproduces | every time · sometimes — *when?* · not on demand |

*Then: fix one, test one. Predict the outcome before the retest, and record the prediction — a prediction that missed is evidence about the model you were working from.*

| # | Change (one at a time) | Predicted | Observed | Reverted? |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |

## 7 · Impact and workaround `[both]`

| | |
|---|---|
| Who is affected, and how badly | |
| Business impact / severity | |
| Workaround in place | *and whether the reporter knows about it* |

## 8 · Closure, and the ask `[both]`

**Closure** — *only when the case is resolved. The SOP's second rule: close the loop end to end, then confirm with the user and write it down. A delivery report without this is a claim, not a result.*

| | |
|---|---|
| End-to-end retest | valid IP → gateway → external IP → a name → **the application the user actually cares about** |
| That application | works / does not |
| User confirmed service is restored | *who, and when* |

**Hand-off** `[hand-off]` — name the rule that was invoked, because it says what kind of help is needed. *Delete this block along with the other hand-off sections: a customer-facing report should not carry your request to L3.*

- [ ] **Timebox** expired without isolation
- [ ] Needs **access or authority** I do not have — *say which*
- [ ] **Severity** policy — site-down or many users
- [ ] **My layers are excluded** — the remaining suspects are in your domain

| | |
|---|---|
| **What I need from you, specifically** | |

**Delivery** `[both]` — the conclusion in the reader's language, and the one thing they should do next.

| | |
|---|---|
| **Conclusion** | |
| **What to do next** | |

## 9 · Attachments `[both]`

> **Before you attach anything.** The reports carry the computer name, the user name, adapter / MAC / IP / gateway / DNS data, the Wi-Fi network name and the access-point BSSID, the test targets and exception details. The package's own instruction is unconditional — handle them according to company policy — so apply that policy **before this report is stored or sent**, on the delivery path as much as the hand-off (field manual, §7). **The device evidence carries more than the reports do:** a configuration export contains credentials — SNMP communities, Wi-Fi PSKs, RADIUS shared secrets, VPN keys — which come out before the file travels, and the list and the rule are the SOP's, in *Collecting the infrastructure evidence*; device logs carry user names, MAC and IP addresses, and the destinations people reached. The same policy governs them, and it applies before the file is attached, not after.

| | Attached | Note |
|---|---|---|
| Health check report — HTML | ☐ | whichever formats the run wrote; the HTML is the readable one |
| Health check report — JSON | ☐ | schema 2: run options, fingerprint, every result |
| Health check report — TXT | ☐ | *the readable fallback when the HTML was one of the formats that failed* |
| Raw command output — `ipconfig /all`, `ping`, `tracert` | ☐ | **not in the report**: it carries measured values, not command output. Run the rows' Manual-check lines where the escalation asks for raw output |
| Switch and AP status pages for the path `[hand-off]` | ☐ | **not in the report** — the tool never reads a device. What you read from them goes into §3's *Other measurements*; where you could not read them at all, the same missing access shows in §3's infrastructure-evidence table |
| `NetworkHealthCheck_ENVIRONMENT_<time>.txt` | ☐ | *written by the script's own guard before it exits 3: the machine, the language mode, what IT can do. Beside the script, or in `%TEMP%` — **best effort**: if both refuse the write, no file exists* |
| `LauncherError.txt`, or `%TEMP%\NetworkHealthCheck_LauncherError.txt` | ☐ | *written by the launcher for its own stop or any nonzero exit, with the reason and the suggested action. **The fallback has a different name**, so a read-only share or protected folder leaves it in `%TEMP%` under the longer one — and the launcher prints the path it used. **A restricted-mode run started through a launcher produces both this and the environment report**; attach each. A direct `powershell -File …` run writes the environment report and exits 3 with no launcher involved, so there is no launcher file to look for. **Best effort too**: the fallback write is not verified* |
| `NetworkHealthCheck_FATAL_<time>.txt` | ☐ | *where the run collapsed before it could write a report — the only evidence that attempt left, and best effort too* |
| Topology sketch of the affected path `[hand-off]` | ☐ | hand-drawn is fine; **the tool never draws one**. What it has to show: the SOP's *Collecting the infrastructure evidence* — and §3 records whether you got it |
| Device logs covering the failure window `[hand-off]` | ☐ | switch / AP / firewall — **not in the report**. The window, the margin and the clock note: same SOP sub-section; what they cover goes in §3 |
| Config exports of the devices in the path `[hand-off]` | ☐ | **not in the report**, and the **secrets come out before the file travels** (SOP, same sub-section); §3 records that they were removed |
| Screenshots, or a photo of the window | ☐ | *where nothing was written at all, the photo of the black window is the evidence — field manual §6* |

*The four rows marked `[hand-off]` are internal infrastructure evidence: the SOP asks for them so that L3 can start at your frontier. **Leave them out of a delivery report**, which goes to the person who asked. And where the environment report, the launcher error or the fatal file does not exist — each is best effort — capture the text the window showed instead, and say in §9 that you did.*

---

*End of the copyable template. What follows is an example, not part of it — do not paste it into a ticket.*

## A filled example — the shape, not the wording

*An illustration, not a transcript. The measurements come from the acceptance campaign's `A3` scenario — a lab machine deliberately moved to a host-only network, which is a real "an address, no gateway" case, run on both campaign machines; the wording around them is mine. Abbreviated to the sections a delivery report keeps.*

**1 · Identity** — Machine `DESKTOP-CO7QIMR` (Windows 10 Pro 22H2, 19045.3803), lab, run by the engineer at the machine.

**2 · Symptom** — "Nothing loads, but the network icon looks normal." Blast radius: this machine only. Changed: the adapter was moved to a host-only segment. Fingerprint lane: **IP, but gateway unreachable** — *the guess before the run; the report then showed no gateway is configured at all, which is the client-configuration branch rather than L1/L2.* Constant.

**3 · What was measured** — One run at **08:14 on 2026-09-06** — **user entry point, console mode** — verdict **Problem Detected**, fingerprint `local`. The shape recorded on both machines: `gateway-config` FAIL (no IPv4 gateway on any adapter); `ping-gateway` FAIL, because `AUTO_GATEWAY` resolved to nothing; DNS timed out; and the IT-scope `gateway-neighbor` row `INFO — No IPv4 default gateway to look up.` On the 1.2.3 run the `routes` row read `INFO — No IPv4 default route exists.` — the fact rather than an error, which is what backlog #27 changed.

**3 · Evidence status** — Topology of the affected path: **yes** — two boxes, the machine and the host-only segment it was moved to, carried in §5's words rather than a drawing; a host-only segment has nothing beyond it to add. Device logs and config exports: **no** — the only infrastructure on this path is the host's own virtual network, and it was not read. *Effect:* none. The isolation rests on the endpoint's own rows, and what §5 leaves open — the adapter itself, and upstream — is open because the run did not measure it, not because a device refused to be read. *The shape when the absence does cost something, invented for the illustration:* on an office port whose access switch the ISP manages, the config export is a **no — third-party-managed device**, and the effect line reads "the port's VLAN and PVID are unverified; a port in the wrong VLAN is not excluded" — the sentence a delivery report can carry as it stands.

**5 · Isolated to** — The segment the machine is attached to. It holds an address and has no IPv4 default gateway, and **every destination the run could attempt beyond the segment failed** — DNS and the external targets. The gateway was never probed at all: `AUTO_GATEWAY` resolved to nothing, so the `ping-gateway` row is FAIL for *no testable target*, not for a ping that went unanswered — a missing configuration, not a measured unreachability. *Not excluded:* the adapter itself — its row says **connected and addressed**, which is not the same as verified healthy; nothing here tests the NIC, the driver or the physical path, and on the CIM fallback path even a disconnected adapter holding a static address reports as `Up` (field manual, §5). *Nor is the whole of upstream excluded:* a more specific route, or IPv6, would not show in the IPv4 default-route rows, and this run did not look for either.

**7 · Impact and workaround** — This machine only, and it is a lab VM: nothing outside the campaign was affected, and no workaround was needed.

**8 · Closure** — *written as it would be for a real case; the campaign reverted this scenario rather than resolving it with a user, so these three lines — and the clock time in §3 — are the invented parts of the example.* Adapter moved back to the office segment; end-to-end retest: address, gateway, `1.1.1.1`, a name, and the intranet page all reached. The application the user cares about works. Confirmed by the reporter at 09:12.

**8 · Delivery** — The machine had an address but no IPv4 default gateway — no default next hop was configured — and every destination the run could try beyond its own segment failed: DNS and the external targets. Moving the adapter back to the office segment restored it. *What the run did not settle:* whether that address had been leased or configured by hand. The measured shape — an address, no gateway — is identical either way, and the report's own DHCP mode field is what separates them (field manual, §4.1). It matters if the same thing happens on that segment again: leased, and the scope is handing out addresses without a router option; static, and the client's configuration was missing its gateway.

**8 · What to do next** — Nothing for you: the machine works again. Tell us if it comes back on that segment, and we will settle which of the two cases it is.

**9 · Attachments** — HTML and JSON of the run. *The `[hand-off]` rows — topology, device logs, configuration exports, device status pages — are internal evidence and do not appear in a delivery report, so they are not listed here.*
