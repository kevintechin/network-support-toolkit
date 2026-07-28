Windows Portable Network Health Check
Version: 1.1.0
========================================

1. Quick start
----------------------------------------
1. Extract the complete ZIP file to a local folder, for example:
   C:\Tools\NetworkHealthCheck

2. Do not run a single file directly from inside the ZIP. Keep these files together:
   - Start-NetworkCheck.cmd
   - NetworkHealthCheck.ps1
   - NetworkHealthCheck.config.json
   - README_en-US.txt

3. Double-click Start-NetworkCheck.cmd.

4. The graphical interface starts the test automatically. When it finishes, select
   Open Report.

5. Reports are written to the Reports subfolder by default:
   - HTML: readable report for users and IT staff
   - TXT: plain-text fallback
   - JSON: structured output for later processing

No installation or administrator rights are normally required. The tool reads network
information and performs connectivity tests; it does not change IP, DNS, routes,
firewall rules, or adapter settings.


2. What it checks
----------------------------------------
- Connected adapters and link speed
- IPv4, IPv6, prefix length, default gateway, DNS, and DHCP state
- 169.254.x.x automatic private addresses commonly associated with DHCP failure
- Comparison with company-defined IPs, CIDRs, prefixes, gateways, DNS, and DHCP mode
- Ping to the default gateway and configurable targets
- Packet loss and average/minimum/maximum latency
- DNS name resolution
- Configurable TCP hosts and ports
- HTTP/HTTPS connectivity using the Windows system proxy
- During-test deltas for adapter receive/transmit errors and discarded packets
- System-wide TCPv4/TCPv6 sent and retransmitted segment deltas and an approximate rate

TCP retransmission results cover the entire computer during the sampling period, not a
single application. A short sample with no retransmissions does not prove that a
long-running problem is absent. Run the tool while the problem is occurring.


3. Error handling
----------------------------------------
- Fail: the check ran, but the result did not meet the rule.
- Unable to Check: the step could not finish because of permissions, policy, missing
  components, unavailable counters, or an execution error. Detailed exception data is
  included in the report.
- Launcher failure: the command window displays the reason and tries to write
  LauncherError.txt.
- Unhandled program failure: the tool tries to write
  NetworkHealthCheck_FATAL_yyyyMMdd_HHmmss.txt.
- Unwritable report folder: output automatically falls back to
  %TEMP%\NetworkHealthCheck\Reports.

Start-NetworkCheck-Console.cmd is included for systems where the graphical interface
cannot be initialized.


4. Company-standard IP configuration
----------------------------------------
Edit NetworkHealthCheck.config.json with a text editor. The Expected section is empty
by default, so the tool displays current settings but does not claim that they comply
with company policy.

Example: allow 192.168.10.0/24, require prefix /24, gateway 192.168.10.1, DNS
192.168.10.5, and DHCP:

  "Expected": {
    "AllowedIPv4Addresses": [],
    "AllowedIPv4Cidrs": ["192.168.10.0/24"],
    "AllowedPrefixLengths": [24],
    "AllowedDefaultGateways": ["192.168.10.1"],
    "RequiredDnsServers": ["192.168.10.5"],
    "DhcpEnabled": true
  }

Set DhcpEnabled to false for static IP or null to skip the DHCP-mode check.


5. Company service tests
----------------------------------------
Add TCP targets under Tests -> TcpTargets, for example:

  {
    "Name": "ERP System",
    "Host": "erp.company.local",
    "Port": 443,
    "Required": true,
    "Group": "Company"
  }

HTTP/HTTPS targets can be added under HttpTargets. A required connectivity group passes
when at least one member test succeeds. If outbound internet access is prohibited,
remove the default public targets and replace the Internet group with approved internal
services.

AUTO_GATEWAY resolves to current IPv4 default gateways. AUTO_DNS can be used in
PingTargets to test configured DNS servers.


6. Thresholds
----------------------------------------
Thresholds controls packet loss, latency, TCP retransmission, and adapter counter
warning/failure levels. The defaults are starting points only and should be calibrated
for the organization's Wi-Fi, VPN, WAN, data-center, and application baselines.


7. Security and privacy
----------------------------------------
- Reports are not uploaded automatically.
- Reports stay in the local program folder or Windows temporary folder.
- Reports may contain computer name, user name, adapter/MAC/IP/gateway/DNS data, test
  targets, and exception details. Handle them according to company policy.
- Default tests contact 1.1.1.1:443 and www.microsoft.com and ping 1.1.1.1. IT may
  replace these with approved targets.
- The launcher uses a process-scoped ExecutionPolicy Bypass. AppLocker, WDAC, EDR, or
  Group Policy can still block it.


8. Documentation and source comments
----------------------------------------
The source includes an architecture/safety header, major functional section comments,
and local comments for important fallback or edge-case behavior. Comments describe
intent rather than repeating every obvious statement.

Detailed design, validation methodology, limitations, and acceptance tests are in:
- NetworkHealthCheck_Technical_Guide_en-US.md
- NetworkHealthCheck_Technical_Guide_zh-TW.md
