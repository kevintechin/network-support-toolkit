Windows 免安裝網路健檢工具
版本：1.2.4
========================================

本檔案是給 IT 的設定說明。執行檢測、看懂報告、把報告交給 IT 所需要的一切，都在旁邊的使用手冊裡：
  NetworkHealthCheck_User_Manual_zh-TW.html（內容與 .md 相同）
設計、判定規則、驗證方式與已知限制請參閱 NetworkHealthCheck_Technical_Guide_zh-TW.md。


一、執行選項（IT 入口）
----------------------------------------
Start-NetworkCheck-IT.cmd 會開啟同一支工具，先顯示「執行選項」面板（本次額外的 Ping／DNS／TCP／URL 目標、
Ping 次數、取樣秒數、traceroute 跳數、可選檢查），不會自動開始，HTML 報告預設展開 IT 診斷資料。
文字模式可用同樣的參數，例如：
  powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly
    -PingTarget 10.0.0.1 -TcpTarget fileserver:445 -SampleSeconds 20 -ExpandDetails
執行選項永遠不會改動 NetworkHealthCheck.config.json。這樣加入的目標屬於選用：完全沒有回應的 Ping，
以及連不上的 TCP 或 HTTP 目標，列為「資訊」，不影響整體結果；有回應但品質不佳的目標，以及解析失敗的
DNS 名稱，列為「需注意」。


二、設定公司標準 IP
----------------------------------------
請用記事本編輯 NetworkHealthCheck.config.json。

預設 Expected 區段全部為空白，因此程式只會顯示目前網路設定，並明確標示「尚未設定公司標準，不能判定 IP 是否符合規範」。

範例：允許 192.168.10.0/24、前綴 /24、閘道 192.168.10.1、必要 DNS 192.168.10.5，且必須使用 DHCP：

  "Expected": {
    "AllowedIPv4Addresses": [],
    "AllowedIPv4Cidrs": ["192.168.10.0/24"],
    "AllowedPrefixLengths": [24],
    "AllowedDefaultGateways": ["192.168.10.1"],
    "RequiredDnsServers": ["192.168.10.5"],
    "DhcpEnabled": true
  }

固定 IP 可把 DhcpEnabled 改為 false；不檢查 DHCP 則使用 null。

若只允許特定 IP：

  "AllowedIPv4Addresses": [
    "192.168.10.25",
    "192.168.10.26"
  ]

JSON 格式注意事項：
- 文字必須使用雙引號。
- 每個項目之間要有逗號，但最後一個項目後面不要加逗號。
- true、false、null 不要加引號。
- 設定檔格式錯誤時，程式不會直接中止；它會改用內建預設值，並在畫面與報告中記錄錯誤。


三、加入公司系統連線測試
----------------------------------------
在 Tests → TcpTargets 中加入一個項目，例如：

  {
    "Name": "ERP 系統",
    "Host": "erp.company.local",
    "Port": 443,
    "Required": true,
    "Group": "Company"
  }

Required 為 true 時，連線失敗會列為「異常」；false 時只作為資訊或群組判斷。

也可以測試 HTTP/HTTPS：

  {
    "Name": "公司入口網站",
    "Url": "https://portal.company.local/",
    "Required": true,
    "Group": "Company"
  }

若公司完全不允許連外，請移除預設的公網 Ping、TCP、HTTP 目標，並從 RequiredConnectivityGroups 移除 "Internet"，再改成公司內部必要目標，避免產生預期中的外網失敗。

AUTO_GATEWAY 會自動測試目前的 IPv4 預設閘道。
AUTO_DNS 可用在 PingTargets，會自動測試目前設定的 DNS 伺服器。


四、門檻值
----------------------------------------
Thresholds 可調整：

- PacketLossWarningPercent：封包遺失警告百分比
- PacketLossCriticalPercent：封包遺失嚴重百分比
- LatencyWarningMs：延遲警告毫秒數
- LatencyCriticalMs：延遲嚴重毫秒數
- TcpRetransmissionWarningPercent：TCP 近似重傳比例警告值
- TcpRetransmissionCriticalPercent：TCP 近似重傳比例嚴重值
- TcpRetransmissionCriticalCount：取樣期間的絕對重傳次數門檻；達門檻至少列為注意，若比例也偏高則列為異常
- MinimumTcpSegmentsForRate：樣本至少達到多少傳送 segment 才按比例判斷
- AdapterErrorWarningDelta／CriticalDelta：網卡錯誤增量門檻
- AdapterDiscardWarningDelta／CriticalDelta：網卡丟棄增量門檻

預設門檻是通用起始值，不一定適合所有公司、Wi-Fi、VPN、資料中心或高延遲跨國連線環境，應由 IT 依實際基準調整。


五、部署注意事項
----------------------------------------
- 請部署整個資料夾，不要只給單一啟動器。報告資料夾由設定檔的 ReportFolderName 決定（相對名稱建立在程式旁邊，
  絕對路徑照用）；資料夾無法寫入時改存到 %TEMP%\NetworkHealthCheck\Reports。
- 啟動器使用程序範圍的 ExecutionPolicy Bypass；AppLocker、WDAC、EDR 或群組原則仍可能封鎖。若政策把 PowerShell
  限制在受限語言模式，工具會在任何檢測開始前停止，並在程式旁邊（或 Windows 暫存資料夾）寫出
  NetworkHealthCheck_ENVIRONMENT_<時間>.txt，內容是 IT 需要知道的事。
- 預設會連線到 1.1.1.1:443、www.microsoft.com，Ping 1.1.1.1，traceroute 探測往 1.1.1.1 的前幾跳。大量部署前請改成
  公司核准的目標。
- 報告包含電腦名稱、目前登入使用者、網卡、MAC、IP、閘道、DNS、Wi-Fi 網路名稱（SSID）與基地台 BSSID、測試目標與錯誤資訊。
  使用手冊要求使用者依公司規定處理報告；發放工具前請先決定那個規定是什麼。
- 主程式可以修改，但建議只修改 JSON 設定檔。修改前請先備份，修改後重新驗證（SHA256SUMS.txt、tools/validate_release.py）。
