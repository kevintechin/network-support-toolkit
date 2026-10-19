# Network Support Toolkit

[![Validation chain](https://github.com/kevintechin/network-support-toolkit/actions/workflows/validation-chain.yml/badge.svg)](https://github.com/kevintechin/network-support-toolkit/actions/workflows/validation-chain.yml)

A working support engineer's toolkit: a fault-isolation SOP and a portable network health-check tool.

## Components

### 📋 [sop/](sop/) — Network Troubleshooting SOP

A one-page fault-isolation playbook, from the user's chair to the ISP ([markdown](sop/network-troubleshooting-sop.md) · [one-page HTML](sop/network-troubleshooting-sop.html)):

- **Station 0 — Profile the Reporter**: IT-professional vs general-user delegation tracks
- **Front door**: four isolation questions that cut the search space before touching anything
- **The Packet's Journey**: eight stations, each in *read state → verify config → healthy → if broken* form
- **Read State Before Config**: tables / counters / probes, a counter reference, and two fault discriminators
- **Escalation — when, and with what**: four hand-off rules, the evidence package that travels with the hand-off, and how the topology sketch, the device logs and the config exports are collected
- **Fingerprint library**: fast symptom-to-suspect lookups

### 🔧 [healthcheck/](healthcheck/) — NetworkHealthCheck (Portable)

A read-only Windows diagnostic a non-technical user can run with **one double-click** — no install, no admin rights. Produces HTML / TXT / JSON reports that drop straight into the escalation package. Bilingual (en-US / zh-TW), config-driven expected-standards comparison, delta-based counter sampling.

See [healthcheck/docs](healthcheck/docs/) for the technical guide (design, validation, known limits). The validation chain that every release runs through is committed under [tests/](tests/) and runs from a fresh checkout with one command; its deterministic part also runs on GitHub Actions for every push and pull request.

## Quick start

**SOP** — open [sop/network-troubleshooting-sop.html](sop/network-troubleshooting-sop.html) in any browser, or read the [markdown version](sop/network-troubleshooting-sop.md).

**NetworkHealthCheck** — no installation, no admin rights, no prerequisites beyond stock Windows 10 / 11 (Windows PowerShell 5.1 and .NET Framework 4.x are built into the OS):

1. Download the latest **NetworkHealthCheck** ZIP from the [Releases page](https://github.com/kevintechin/network-support-toolkit/releases/latest) and extract it to a local folder (Code → Download ZIP also works — the package is then under `healthcheck/`)
2. Open the `en-US/` folder (or `zh-TW/` for Traditional Chinese)
3. Double-click **`Start-NetworkCheck.cmd`** — the GUI runs all checks automatically and writes HTML / TXT / JSON reports into a `Reports/` folder next to the script
4. If the GUI cannot start, **`Start-NetworkCheck-Console.cmd`** runs the same checks in text mode

**IT staff** — double-click **`Start-NetworkCheck-IT.cmd`** in the same folder: the tool opens with a run-options panel (extra targets, sample length, optional checks) and the HTML report opens with the IT diagnostics expanded. The same options work as switches in console mode, e.g. `-ConsoleOnly -PingTarget 10.0.0.1 -TcpTarget fileserver:445 -SampleSeconds 20 -ExpandDetails`. The IT deployment manual inside the package (`en-US/NetworkHealthCheck_IT_Deployment_Manual_en-US.html`) covers the configuration file key by key, deployment, package verification and what security policy does to the tool.

> If Windows flags the downloaded ZIP: right-click the ZIP → Properties → **Unblock**, then extract. Corporate policies (AppLocker / WDAC) may still block PowerShell — the user manual inside the package (`en-US/NetworkHealthCheck_User_Manual_en-US.html`, section 6) says what the person at the machine sees and what to send, the IT deployment manual (section 8) says what each policy does to the tool and what reaches IT, and [docs/application-control.md](docs/application-control.md) keeps the measured facts behind that section, which change faster than the package.

## Design principles

- **Follow the packet, not the device list**
- **Fix one, test one** — predict the result before you retest
- **Read state before config** — state cannot lie, and it's read-only
- **A failed ping is a suspect, not a conviction** — corroborate before acting

## Status & roadmap

| Item | Status |
|---|---|
| SOP | v1.2 — *Collecting the infrastructure evidence*: what the topology sketch, the device logs and the config exports have to contain, and that a configuration export's secrets come out before the file travels. v1.1 — the eight-station map, the two fault discriminators and the escalation package |
| NetworkHealthCheck | **v1.2.15** — released 2026-09-16. What each release changed, what was run and what it measured: [healthcheck/VALIDATION.md](healthcheck/VALIDATION.md) |
| Guided triage wizard | Planned — single-file HTML decision tree over the SOP that imports the NHC JSON report, asks only what the machine cannot see, and produces the escalation package ([design](docs/design-v1.2-triage-wizard.md)). NHC v1.2 Phase A shipped as v1.2.0 (no separate modes, IT entry point, IT diagnostics, schema 2); Phase C, the report's links into the wizard, follows the wizard itself |
| Backlog | 5 items open — [docs/backlog.md](docs/backlog.md) carries the statement of each: two changes to the tool ([#38](docs/backlog.md#38--the-retransmission-counter-read-fails-intermittently-and-takes-the-verdict-and-the-runs-length-with-it) the intermittent counter read, [#43](docs/backlog.md#43--the-tool-does-not-say-when-the-reports-are-being-written-into-a-synced-folder) no warning about a synced report folder), one in `tests/` ([#42](docs/backlog.md#42--nothing-proves-the-tool-changes-nothing) proving the tool changes nothing), two decisions ([#22](docs/backlog.md#22--the-two-shipped-scripts-are-not-signed) signing, and [#72](docs/backlog.md#72--a-shipped-manual-dates-its-own-features-and-every-date-moves-with-the-release) whether a shipped manual should date its own features) — no item stands in more than one group, so the groups sum to five where the items are five. The links, the counts and the closed list are read against the page by the chain's `backlog` step (#55). Numbers 1 to 21, 23 to 37, 39 to 41, 44 to 71 are closed |

## Working method

Built and maintained **with AI assistance** — the methodology, requirements, and field experience behind it are mine; every release is validated end-to-end before it ships (PowerShell 5.1 parser checks, dual-language parity, unit and functional tests, real-window GUI runs, real-machine acceptance runs, fault-injection scenarios). See the [validation record](healthcheck/VALIDATION.md); the chain itself is in [tests/](tests/).

## Author

Kevin (Te-Chin) Lin · 2026
