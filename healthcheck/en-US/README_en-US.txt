Windows Portable Network Health Check
Version: 1.2.4
========================================

This file holds the configuration notes for IT. Everything a person needs in order to
run the check, read the report and send it is in the user manual beside this file:
  NetworkHealthCheck_User_Manual_en-US.html   (the same text as .md)
The design, decision rules, validation approach and known limitations are in
NetworkHealthCheck_Technical_Guide_en-US.md.


1. Run options (the IT entry)
----------------------------------------
Start-NetworkCheck-IT.cmd opens the same tool with a Run options panel (extra ping /
DNS / TCP / URL targets for this run, ping count, sample seconds, traceroute hops,
optional checks), does not start automatically, and the HTML report opens with the IT
diagnostics expanded. The same options are switches in text mode, for example:
  powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly
    -PingTarget 10.0.0.1 -TcpTarget fileserver:445 -SampleSeconds 20 -ExpandDetails
Run options never change NetworkHealthCheck.config.json. A target added this way is
optional: a ping that gets no reply at all, and a TCP or HTTP target that cannot
connect, are Information rows and leave the verdict alone; a degraded reply and a DNS
name that will not resolve are Warning rows.


2. Company-standard IP configuration
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

JSON rules: strings in double quotes; a comma between items and none after the last;
true, false and null without quotes. A malformed file does not stop the run: the tool
uses its built-in defaults and records the error in the report.


3. Company service tests
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


4. Thresholds
----------------------------------------
Thresholds controls packet loss, latency, TCP retransmission, and adapter counter
warning/failure levels. The defaults are starting points only and should be calibrated
for the organization's Wi-Fi, VPN, WAN, data-center, and application baselines.


5. Deployment notes
----------------------------------------
- Deploy the whole folder, never a single launcher. The report folder is
  ReportFolderName in the configuration (a relative name is created beside the script,
  an absolute path is taken as given); an unwritable folder falls back to
  %TEMP%\NetworkHealthCheck\Reports.
- The launcher uses a process-scoped ExecutionPolicy Bypass. AppLocker, WDAC, EDR, or
  Group Policy can still block it. If policy restricts PowerShell to a limited language
  mode, the tool stops before any check and writes NetworkHealthCheck_ENVIRONMENT_<time>.txt
  next to the program (or in the Windows temporary folder) with what IT needs to know.
- Default tests contact 1.1.1.1:443 and www.microsoft.com and ping 1.1.1.1; the
  traceroute probes the first hops toward 1.1.1.1. Replace these with approved targets
  before broad deployment.
- Reports carry personal and infrastructure data - from the computer and user names through
  adapter/MAC/IP/gateway/DNS data, the Wi-Fi SSID and BSSID, the proxy settings and the
  first-hop routers to the configuration and report paths; the user manual (section 5,
  "What the report contains") keeps the list. It tells the person to handle the report
  according to company policy; decide what that policy is before the tool is handed out.
- The program file can be edited, but prefer the JSON configuration. Back up and
  re-validate (SHA256SUMS.txt, tools/validate_release.py) before changing the script.
