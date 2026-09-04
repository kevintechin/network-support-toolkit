# Network Support Toolkit

A working support engineer's toolkit: a fault-isolation SOP and a portable network health-check tool.

## Components

### 📋 [sop/](sop/) — Network Troubleshooting SOP

A one-page fault-isolation playbook, from the user's chair to the ISP ([markdown](sop/network-troubleshooting-sop.md) · [one-page HTML](sop/network-troubleshooting-sop.html)):

- **Station 0 — Profile the Reporter**: IT-professional vs general-user delegation tracks
- **Front door**: four isolation questions that cut the search space before touching anything
- **The Packet's Journey**: eight stations, each in *read state → verify config → healthy → if broken* form
- **Read State Before Config**: tables / counters / probes, a counter reference, and two fault discriminators
- **Escalation — when, and with what**: four hand-off rules and the evidence package that travels with the hand-off
- **Fingerprint library**: fast symptom-to-suspect lookups

### 🔧 [healthcheck/](healthcheck/) — NetworkHealthCheck (Portable)

A read-only Windows diagnostic a non-technical user can run with **one double-click** — no install, no admin rights. Produces HTML / TXT / JSON reports that drop straight into the escalation package. Bilingual (en-US / zh-TW), config-driven expected-standards comparison, delta-based counter sampling.

See [healthcheck/docs](healthcheck/docs/) for the technical guide (design, validation, known limits). The validation chain that every release runs through is committed under [tests/](tests/) and runs from a fresh checkout with one command.

## Quick start

**SOP** — open [sop/network-troubleshooting-sop.html](sop/network-troubleshooting-sop.html) in any browser, or read the [markdown version](sop/network-troubleshooting-sop.md).

**NetworkHealthCheck** — no installation, no admin rights, no prerequisites beyond stock Windows 10 / 11 (Windows PowerShell 5.1 and .NET Framework 4.x are built into the OS):

1. Download the latest **NetworkHealthCheck** ZIP from the [Releases page](https://github.com/kevintechin/network-support-toolkit/releases/latest) and extract it to a local folder (Code → Download ZIP also works — the package is then under `healthcheck/`)
2. Open the `en-US/` folder (or `zh-TW/` for Traditional Chinese)
3. Double-click **`Start-NetworkCheck.cmd`** — the GUI runs all checks automatically and writes HTML / TXT / JSON reports into a `Reports/` folder next to the script
4. If the GUI cannot start, **`Start-NetworkCheck-Console.cmd`** runs the same checks in text mode

**IT staff** — double-click **`Start-NetworkCheck-IT.cmd`** in the same folder: the tool opens with a run-options panel (extra targets, sample length, optional checks) and the HTML report opens with the IT diagnostics expanded. The same options work as switches in console mode, e.g. `-ConsoleOnly -PingTarget 10.0.0.1 -TcpTarget fileserver:445 -SampleSeconds 20 -ExpandDetails`.

> If Windows flags the downloaded ZIP: right-click the ZIP → Properties → **Unblock**, then extract. Corporate policies (AppLocker / WDAC) may still block PowerShell — see `en-US/README_en-US.txt` inside the package for details.

## Design principles

- **Follow the packet, not the device list**
- **Fix one, test one** — predict the result before you retest
- **Read state before config** — state cannot lie, and it's read-only
- **A failed ping is a suspect, not a conviction** — corroborate before acting

## Status & roadmap

| Item | Status |
|---|---|
| SOP | v1.1 |
| NetworkHealthCheck | v1.2.2 — one run for everyone: "What to tell IT" summary, collapsed IT diagnostics (Wi-Fi radio, routes, gateway ARP, proxy, traceroute, drivers), physical/virtual adapter classification, JSON schema 2 with run profile and fingerprint, IT entry point (launcher + switches + options panel); v1.2.1 fixes the IT panel truncating a configured ping count / sample length above its default range (Codex round 7 on PR #3) and two 1.2.0 GUI regressions caught by the first real GUI runs (both entries fell back to console mode; the IT launcher opened the user layout); v1.2.2 closes backlog #14 (network errors classified by their error code, so the cause is written in the report's language and the operating system's own message is kept beneath it) and #18 (a guard ahead of every other line detects a restricted PowerShell language mode — what WDAC / AppLocker application control creates — and writes an environment report naming what IT can do, instead of an engine error nobody can act on); v1.1.5 closed backlog #2/#3, v1.1.4 closed #4/#5/#6/#11; self-explaining Method + Manual-check lines in every check; validation chain: static checks, independent code review, Windows acceptance, real-window GUI runs, five fault-injection scenarios ([validation record](healthcheck/VALIDATION.md) · [scenario matrix](healthcheck/validation-matrix.html) · [tests/](tests/) runs the chain from a checkout, backlog #16, and holds the two PowerShell guards on the AST since backlog #17) |
| NHC v1.2 | Phase A shipped as v1.2.0 (no separate modes, IT entry point, IT diagnostics, schema 2 — [design](docs/design-v1.2-triage-wizard.md)); Phase C (report links to the wizard) follows the wizard |
| Guided triage wizard | Planned — single-file HTML decision tree over the SOP that imports the NHC JSON report, asks only what the machine cannot see, and produces the escalation package ([design](docs/design-v1.2-triage-wizard.md)) |

## Working method

Built and maintained **with AI assistance** — the methodology, requirements, and field experience behind it are mine; every release is validated end-to-end before it ships (PowerShell 5.1 parser checks, dual-language parity, unit and functional tests, real-window GUI runs, real-machine acceptance runs, fault-injection scenarios). See the [validation record](healthcheck/VALIDATION.md); the chain itself is in [tests/](tests/).

## Author

Kevin (Te-Chin) Lin · 2026
