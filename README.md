# Network Support Toolkit

A working support engineer's toolkit: a fault-isolation SOP and a portable network health-check tool — built from 15+ years of customer-facing network support.

## Components

### 📋 [sop/](sop/) — Network Troubleshooting SOP

A one-page fault-isolation playbook, from the user's chair to the ISP ([markdown](sop/network-troubleshooting-sop.md) · [one-page HTML](sop/network-troubleshooting-sop.html)):

- **Station 0 — Profile the Reporter**: IT-professional vs general-user delegation tracks
- **Front door**: four isolation questions that cut the search space before touching anything
- **The Packet's Journey**: eight stations (PC → Wi-Fi → switch → LAG → core → firewall → DNS → ISP), each in *read state → verify config → healthy → if broken* form
- **Read State Before Config**: tables / counters / probes, a counter reference, and two fault discriminators
- **Escalation — when, and with what**: four hand-off rules and the evidence package L3 receives
- **Fingerprint library**: fast symptom-to-suspect lookups

### 🔧 [healthcheck/](healthcheck/) — NetworkHealthCheck (Portable)

A read-only Windows diagnostic a non-technical user can run with **one double-click** — no install, no admin rights. Produces HTML / TXT / JSON reports that drop straight into the escalation package. Bilingual (en-US / zh-TW), config-driven expected-standards comparison, delta-based counter sampling.

See [healthcheck/docs](healthcheck/docs/) for the technical guide (design, validation, known limits).

## Design principles

- **Follow the packet, not the device list**
- **Fix one, test one** — predict the result before you retest
- **Read state before config** — state cannot lie, and it's read-only
- **A failed ping is a suspect, not a conviction** — corroborate before acting

## Status & roadmap

| Item | Status |
|---|---|
| SOP | v1.1 |
| NetworkHealthCheck | v1.1.0 — static validation passed; Windows acceptance in progress |
| NHC v1.2 | Planned: separate User / IT modes |
| Guided triage wizard | Planned: decision-tree front-end over the SOP |

## Author

Kevin (Te-Chin) Lin · 2026
