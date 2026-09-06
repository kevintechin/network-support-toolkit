# Support Report Template

**One skeleton, two fill patterns — the hand-off that goes to L3, and the delivery that goes to whoever asked**

Version 1.0 · Kevin (Te-Chin) Lin · September 2026

Companion to the [Network Troubleshooting SOP](network-troubleshooting-sop.md) and the [Support Engineer's Field Manual](support-engineer-field-manual.md).

---

## How to use it

Copy everything below the second rule. Each section carries a marker:

- **`[both]`** — fill it in whichever report you are writing
- **`[hand-off]`** — for an escalation to L3; delete it for a delivery report

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

> *Quote them. Their words are evidence about what they can and cannot see; your paraphrase is not.*

**Front door** — the four isolation questions, answered before anything was touched:

| | |
|---|---|
| **Blast radius** | one user · one VLAN / SSID / location · everyone — wired, wireless, or both |
| **What changed** | config, firmware, new device, cabling, power — in the last 24–72 h |
| **Failure fingerprint** | no IP (169.254.x.x) · IP but gateway unreachable · gateway OK but internet dead · IP works, names fail |
| **Constant or intermittent** | *intermittent points at RF, congestion, duplex, retransmissions* |

## 3 · What was measured `[both]`

**NetworkHealthCheck runs**

| # | When | Entry point | Verdict | Fingerprint | Note |
|---|---|---|---|---|---|
| 1 | | user / IT / console | Overall Healthy · Attention Required · Test Incomplete · Problem Detected | | |

*Targets added for this case, and what they returned:*

> A target you add is **optional**: one that gets no reply at all, or that cannot connect over TCP or HTTP, is an `INFO` row and **does not move the verdict**. Record what it returned here even when the report came back healthy — see the field manual, §3.

**Other measurements** — switch, AP, firewall, or anything read by hand:

| What | Where read | Value |
|---|---|---|

## 4 · What is excluded, and by what evidence `[hand-off]`

*This is the section that lets L3 start at your frontier instead of from zero. One line per exclusion; no line without its evidence.*

| Excluded | Evidence that excludes it |
|---|---|
| | |

## 5 · Where the fault is isolated to `[both]`

**Station / domain:**

*Two or three sentences: what the evidence points at, and what it does not. If the isolation is partial, say which way it is partial — "somewhere between the access port and the gateway" is a useful sentence; "network issue" is not.*

## 6 · What was tried `[hand-off]`

*Fix one, test one. Predict the outcome before the retest, and record the prediction — a prediction that missed is evidence about the model you were working from.*

| # | Change (one at a time) | Predicted | Observed | Reverted? |
|---|---|---|---|---|

## 7 · Impact and workaround `[both]`

| | |
|---|---|
| Who is affected, and how badly | |
| Business impact / severity | |
| Workaround in place | *and whether the reporter knows about it* |

## 8 · The ask `[both]`

**Hand-off** — name the rule that was invoked, because it says what kind of help is needed:

- [ ] **Timebox** expired without isolation
- [ ] Needs **access or authority** I do not have — *say which*
- [ ] **Severity** policy — site-down or many users
- [ ] **My layers are excluded** — the remaining suspects are in your domain

*What I need from you, specifically:*

**Delivery** — the conclusion in the reader's language, and the one thing they should do next.

## 9 · Attachments `[both]`

| | Attached | Note |
|---|---|---|
| Health check report — HTML | ☐ | whichever formats the run wrote; the HTML is the readable one |
| Health check report — JSON | ☐ | schema 2: run options, fingerprint, every result |
| Environment report / `LauncherError.txt` | ☐ | *only where the tool could not run — best effort, so it may not exist* |
| Topology sketch of the affected path | ☐ | hand-drawn is fine; **the tool never draws one** |
| Device logs covering the failure window | ☐ | switch / AP / firewall — **not in the report** |
| Config exports of the devices in the path | ☐ | **not in the report** |
| Screenshots the user took | ☐ | |

---

## A filled example — the shape, not the wording

*An illustration, not a transcript. The measurements come from the acceptance campaign's `A3` scenario — a lab machine deliberately moved to a host-only network, which is a real "an address, no gateway" case, run on both campaign machines; the wording around them is mine. Abbreviated to the sections a delivery report keeps.*

**1 · Identity** — Machine `DESKTOP-CO7QIMR` (Windows 10 Pro 22H2, 19045.3803), lab, run by the engineer at the console.

**2 · Symptom** — "Nothing loads, but the network icon looks normal." Blast radius: this machine only. Changed: the adapter was moved to a host-only segment. Fingerprint lane: **IP, but gateway unreachable**. Constant.

**3 · What was measured** — One console run, verdict **Problem Detected**, fingerprint `local`. The shape recorded on both machines: `gateway-config` FAIL (no IPv4 gateway on any adapter); `ping-gateway` FAIL, because `AUTO_GATEWAY` resolved to nothing; DNS timed out; no gateway rows at all. On the 1.2.3 run the `routes` row read `INFO — No IPv4 default route exists.` — the fact rather than an error, which is what backlog #27 changed.

**5 · Isolated to** — The segment the machine is attached to: it has an address, but no default route exists, so nothing beyond that segment is reachable. The link itself is up and the adapter is healthy; nothing above the gateway was tested, because nothing could be reached to test it.

**8 · Delivery** — This machine has an address but no way out of its own segment: the network it is attached to hands out addresses without a router. Move it back to the office segment, or add a gateway to that segment's DHCP scope.

**9 · Attachments** — HTML and JSON of the run. No device logs: the segment has no switch to read.
