# Design — NetworkHealthCheck v1.2 and the SOP triage wizard

Status: Phase A implemented in NetworkHealthCheck 1.2.0 (2026-09-03); Phases B and C open · applies to SOP v1.1
Supersedes the earlier roadmap line "NHC v1.2 — separate User / IT modes".

## 1. Decisions

1. **No modes.** Every check runs on every run. All checks are read-only, automatic and time-bounded, so there is no reason to withhold any of them from anyone. What differs between a user and an IT person is presentation and entry point, not measurement.
2. **One program, one JSON, one HTML.** The JSON report is the single source of truth (schema 2, a superset of today's). The HTML has two layers: a user summary on top, IT diagnostics collapsed below, with an "Expand all" control. No second HTML file.
3. **The IT entry point is a launcher plus command-line switches plus an options panel** in the existing window — not a second code base. The validator already keeps two language versions in lock-step; a third variant would triple the maintenance and validation surface for no measurement benefit.
4. **The triage wizard is a standalone single-file HTML decision tree** under `sop/`, driven by the SOP and able to import the NHC JSON report. NHC measures; the wizard reasons. The two are used together on the IT track and independently on the user track.
5. **Existing constraints stay:** Windows PowerShell 5.1, no dependencies, portable, read-only (including the tool's own config file), identical executable token skeleton in both language versions, every release validated end-to-end.

## 2. Why not modes

The SOP's Station 0 distinguishes *reporters* (IT professional vs general user), not tool variants. The only real costs of "run everything" are runtime and noise, and both are handled by presentation:

- New items that only gather facts (routes, ARP, proxy, driver, Wi-Fi RF) are reported as **INFO** and live in a collapsed "IT diagnostics" section. They never change the overall verdict, so the number of warnings a user sees does not grow.
- The one slow item, traceroute, is bounded (3 hops, 1 s per hop by default) and switchable in the config.
- Anything the IT person wants to *change* for a run (extra targets, longer sample) is a run option, not a mode.

## 3. New checks in v1.2 (all read-only)

| Check | Source | Result status | Cost | Notes |
|---|---|---|---|---|
| Physical vs virtual adapter classification | `Get-NetAdapter` (`Virtual`, `InterfaceDescription` patterns), CIM fallback by description | Changes verdicts: virtual adapters become INFO; **0 physical adapters is a FAIL**; adapter count reports physical / virtual separately | none | Closes backlog #10 and its zero-traffic note (counters only testify when traffic flows) |
| Wi-Fi RF data | `netsh wlan show interfaces` (SSID, BSSID, band, channel, RSSI, receive/transmit rate) | INFO in v1.2.0; thresholds later | < 1 s | Closes backlog #13. Parsing is locale-sensitive: parse by line position within the interface block and by numeric patterns, never by label text. The client-side view is weaker evidence than the AP's client table — say so in the Method line |
| Route table summary | `Get-NetRoute` (IPv4 default routes, interface, metric) | INFO | < 1 s | Explains "two default routes" and VPN split-tunnel cases |
| Gateway neighbor (ARP) | `Get-NetNeighbor` for each IPv4 gateway after the ping check | INFO (WARN later if unreachable after a successful ping is impossible) | < 1 s | Distinguishes "gateway IP configured" from "gateway actually answers on the LAN" |
| Proxy / WinHTTP | `netsh winhttp show proxy`, per-user proxy registry values | INFO | < 1 s | Explains "TCP to 443 passes but HTTPS fails" |
| First hops traceroute | .NET `Ping` with TTL 1..N to the public ping target | INFO | ≤ N × 1 s, N = 3 default, config switch | Shows where packets stop when the gateway is fine but the internet is dead |
| NIC driver version / date | `Get-NetAdapter` `DriverVersion`, `DriverDate` | INFO | none | Goes into the escalation package |

Not in scope for v1.2: backlog #14 (OS-locale exception strings); it is a separate fix.

Runtime budget: the healthy-path run stays under 20 s; the worst case with every timeout hit stays under 45 s (today: 27 s).

## 4. Report changes

**HTML (one file, two layers)**

1. Header: overall verdict, computer, time, and a new **Run profile** line — entry point (User / IT), extra targets, sample seconds, traceroute hops, which optional checks ran.
2. "What to tell IT": three to five plain-language lines derived from the fingerprint (e.g. "Gateway answers, internet does not — the fault is at or beyond the router"), plus how to send the report and a reminder that it contains the computer name, user name, SSID and MAC addresses.
3. Check results, as today (Method and Manual-check lines included).
4. **IT diagnostics** — collapsed by default from the user launcher, expanded from the IT launcher; one "Expand all / Collapse all" control. Inline script only; no external resources, so the file stays self-contained and offline.

**JSON (schema 2)**

- `SchemaVersion: 2`.
- New top-level `RunOptions`: `EntryPoint` ("User" | "IT"), `ExtraTargets` (ping / DNS / TCP / HTTP arrays), `SampleSeconds`, `TracerouteHops`, `ChecksEnabled` (per optional check).
- Every result keeps `Diagnostics` (since 1.1.4); IT diagnostics results use `Category: "IT Diagnostics"`.
- The wizard and any future comparison tool read only documented fields; the field list is frozen in the technical guide.

**TXT** — same order as the HTML.

## 5. IT entry point

**Files** (per language folder): `Start-NetworkCheck-IT.cmd`, which runs the same script with `-Interactive -ExpandDetails`. The root launchers `Start-English.cmd` / `Start-Traditional-Chinese.cmd` stay user-oriented; IT opens the language folder (documented in the READMEs).

**Switches** (names to be finalized at implementation; all have defaults so the one-click path is unchanged):

| Switch | Effect |
|---|---|
| `-Interactive` | Do not auto-run; show the options panel first |
| `-ExpandDetails` | HTML opens with IT diagnostics expanded |
| `-PingTarget`, `-DnsName`, `-TcpTarget` (host:port), `-HttpUrl` | Additional targets for this run only |
| `-SampleSeconds`, `-PingCount` | Override the sampling window / ping count |
| `-TracerouteHops`, `-NoTraceroute`, `-NoWifi` | Tune or skip the optional checks |
| `-ConsoleOnly` (existing) | All of the above also work in console mode |

**Options panel** (same window, collapsible group above the log):

```
▼ Run options
  Config file : [en-US\NetworkHealthCheck.config.json] [Browse]
  Extra ping  : [10.0.0.1          ]   Extra DNS : [intranet.corp    ]
  Extra TCP   : [fileserver:445    ]   Extra URL : [https://...      ]
  Ping count [4]   Sample seconds [8 ]   Traceroute hops [3]
  [x] Wi-Fi RF   [x] Route / ARP / Proxy   [x] Expand details in HTML
  [Run]  [Reset to config]
```

After a run the button row gains **Open JSON** and **Triage Wizard** (opens `sop/triage-wizard.html`; the wizard then imports the JSON through its file picker — browsers do not allow a page to read a local file on its own).

Rules: panel values override the in-memory configuration only; the JSON config file is never written. GUI initialization failure falls back to console mode with the same switches, as today.

## 6. Triage wizard

**Role.** The interactive form of the whole SOP — not a way to produce the report (that is one double-click) and not only a post-report annotation tool:

1. Before the report: Station 0 (who is reporting) and the four front-door isolation questions; decides whether to have the user run NHC or to run it from the IT entry.
2. Import: reads the NHC JSON and auto-answers the stations the machine can measure (adapter / IP / gateway / DNS / internet / retransmissions / Wi-Fi), jumping straight to the matching fingerprint.
3. After the report: asks only what the machine cannot see (link lights, AP state, other devices affected, recent changes, scope), then produces the suspect, the next action, and the SOP's escalation evidence package with a copy button.

Without a report it walks the same tree by hand and shows the manual commands at each station (the same commands as the report's Manual-check lines).

**Files.** `sop/triage-wizard.html` (single file, inline CSS/JS, offline, bilingual through two string tables over one tree) and `sop/triage-tree.json` (the source of the tree; embedded into the HTML at build time by a small script under `tools/`).

**Node schema** (one tree, two languages):

```json
{
  "id": "S3-gateway",
  "kind": "question",
  "text": { "en": "Does the default gateway answer a ping?", "zh": "預設閘道 ping 得通嗎？" },
  "autoAnswer": { "category": "Latency and Packet Loss", "checkPrefix": "Default Gateway", "PASS": "yes", "FAIL": "no", "ERROR": "unknown" },
  "manualCheck": "ping -n 4 <gateway>",
  "evidence": ["Default Gateway result", "Adapter: gateway list"],
  "options": [
    { "label": { "en": "Yes", "zh": "是" }, "next": "S4-internet" },
    { "label": { "en": "No", "zh": "否" }, "next": "F-local-lane" }
  ]
}
```

`kind` is `question`, `instruction` or `verdict`; a verdict node carries the fingerprint name, the suspect, the next action, and the list of evidence fields to include in the escalation package. PII fields (computer name, user, SSID, MAC) are individually selectable before copying.

**Validation** (same spirit as the release chain): a `tools/` script that walks every path (no dead ends, every leaf is a verdict), checks every `autoAnswer` refers to a check that exists in the JSON schema, cross-references node ids to SOP station headings, and replays the five fault-scenario JSON reports from the validation record to assert the expected fingerprint for each (AP off → local lane; WAN off → gateway-up-internet-dead; NIC off → local / no route; bad DNS → DNS lane; healthy → no fault).

## 7. Phases and acceptance

| Phase | Deliverable | Acceptance |
|---|---|---|
| A — NHC 1.2.0 | New checks (§3), report changes (§4), IT entry (§5), schema 2, validator constants | Existing chain (parser × 2, validator, unit and report-stage tests, both-language acceptance, fault configs) plus: runtime budget, a proxy-misconfiguration scenario, virtual-only-adapter scenario, IT launcher on both languages, JSON schema 2 documented |
| B — Wizard 1.0 | Tree, HTML, import, escalation package, tree tests | Path-traversal test, five-scenario replay, manual walkthrough of both languages |
| C — Integration | Report links to the wizard; READMEs describe both tracks | Release notes; SOP Tools section updated |

Phase A ships as v1.2.0 on its own; the wizard does not block it.

## 8. Package layout after v1.2

```
healthcheck/<lang>/
  NetworkHealthCheck.ps1               (same script; new switches)
  NetworkHealthCheck.config.json       (new optional-check switches, traceroute hops)
  Start-NetworkCheck.cmd               (user entry, unchanged behaviour)
  Start-NetworkCheck-Console.cmd       (unchanged)
  Start-NetworkCheck-IT.cmd            (NEW — IT entry)
  README_<lang>.txt, technical guides  (updated)
  Reports/                             (runtime output, ignored)
sop/
  network-troubleshooting-sop.md/.html (Tools section updated)
  triage-wizard.html                   (NEW)
  triage-tree.json                     (NEW — source of the tree)
tools/  (repo root)
  build-wizard.py, test-wizard-tree.py (NEW)
```

## 9. Documents to update at implementation time

| File | Change |
|---|---|
| `healthcheck/en-US/README_en-US.txt`, `healthcheck/zh-TW/README_zh-TW.txt` | Quick start gains the IT launcher and the switch list; "what the report contains" gains the IT diagnostics section; PII reminder for the escalation package |
| `healthcheck/docs/NetworkHealthCheck_Technical_Guide_*.md` (and the copies in `en-US/`, `zh-TW/`) | §3 package contents (IT launcher), §4/§5 new checks and their decision rules, report format (schema 2, `RunOptions`), §7 validation status, §8 limitations (Wi-Fi client-side view, traceroute bound), function count |
| `healthcheck/README_BILINGUAL.md` | Launcher list |
| `README.md` (root) | Quick start: an "IT" paragraph; status row; roadmap rows |
| `healthcheck/VALIDATION.md` | v1.2.0 entry; backlog #10 and #13 struck; new scenarios in the matrix |
| `healthcheck/tools/validate_release.py` | `TOOL_VERSION`, `FUNCTION_COUNT`, required-file list and CRLF checks extended to the IT launchers |
| `healthcheck/SHA256SUMS.txt` | New launchers added; regenerated |
| `sop/network-troubleshooting-sop.md`, `.html` | Tools section: NHC IT entry and the wizard; Escalation section links the wizard's evidence package |
| `.gitattributes` | No change for `healthcheck/**` (CRLF); wizard files under `sop/` stay LF |
| Release notes | Asset list (unchanged: one ZIP), schema 2 note, IT entry note |

## 10. Implementation notes — v1.2.0 (Phase A as shipped)

- "0 physical adapters" is a **WARN** when a virtual adapter still carries a default gateway (VPN or virtualization) and a **FAIL** only when no physical adapter is connected at all — a refinement of the FAIL-only rule in §3, so VPN-only or VM-guest situations do not fail on classification alone. Primary-adapter selection for the company-standard comparison is unchanged.
- The options panel ships with the extra-target boxes, ping count, sample seconds, traceroute hops, three check toggles, "Expand details" and "Reset to config"; the bottom "Start Test" button is the Run button. The "Config file / Browse" field and the "Triage Wizard" button are deferred (the wizard does not exist yet — Phase C).
- Wi-Fi RSSI uses the real `Rssi` line when the Windows build prints it (Windows 11 24H2+) and the percentage-based estimate otherwise; the parser is value-shape based (MAC, GHz, 802.11x, percentage, numbers), not position based, because the field order differs between Windows 10 and 11.
- Every result carries `Tag` and `Scope`; the fingerprint keys are `local`, `gateway-unreachable`, `gateway-up-internet-dead`, `dns`, `quality`, `mixed`, `incomplete`, `healthy` — the wizard's auto-answer rules (§6) can use tags instead of category / check-name matching.

## 11. Open questions

1. Traceroute default: on (more evidence, +3 s) or off (faster, IT enables it). Proposal: on, 3 hops.
2. Wi-Fi source: `netsh` parsing (locale-sensitive but dependency-free) vs the native WLAN API through P/Invoke (robust but adds unmanaged code to a script that is reviewed for being plain PowerShell). Proposal: `netsh` with position-based parsing and a documented limitation.
3. Should "0 physical adapters" be a FAIL in 1.2.0 (proposal: yes; it is the strongest local-lane signal) or a WARN for one release?
4. Wizard tree source of truth: one tree with two string tables (proposal) vs two trees.
