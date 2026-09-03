Windows 免安裝網路健檢工具
版本：1.2.0
========================================

一、快速使用
----------------------------------------
1. 將整個 ZIP 解壓縮到本機資料夾，例如：
   C:\Tools\NetworkHealthCheck

2. 不要只從 ZIP 裡直接開啟單一檔案；四個主要檔案必須放在同一資料夾：
   - Start-NetworkCheck.cmd
   - NetworkHealthCheck.ps1
   - NetworkHealthCheck.config.json
   - README_zh-TW.txt

3. 雙擊「Start-NetworkCheck.cmd」。

4. 圖形介面開啟後會自動開始檢測。完成後按「開啟報告」。

5. 報告預設存放於程式資料夾下的 Reports 子資料夾，包含：
   - HTML：給一般使用者或 IT 閱讀
   - TXT：純文字備用報告
   - JSON：供 IT 或其他系統後續處理

6. IT 人員請改雙擊「Start-NetworkCheck-IT.cmd」。同一支工具會先顯示「執行選項」面板
   （本次額外的 Ping／DNS／TCP／URL 目標、Ping 次數、取樣秒數、traceroute 跳數、可選檢查），
   不會自動開始，HTML 報告會預設展開 IT 診斷資料。文字模式可用同樣的參數，例如：
   powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly
     -PingTarget 10.0.0.1 -TcpTarget fileserver:445 -SampleSeconds 20 -ExpandDetails
   執行選項永遠不會改動 NetworkHealthCheck.config.json。

本工具不需要安裝，也不需要系統管理員權限。它只讀取網路資訊並執行連線測試，不會修改 IP、DNS、路由、防火牆或網卡設定。


二、檢查內容
----------------------------------------
- 已連線網卡與連線速度
- IPv4、IPv6、子網路前綴、預設閘道、DNS、DHCP 狀態
- 169.254.x.x 自動私人 IP（常見於 DHCP 失敗）
- 與公司預先設定標準的 IP、網段、前綴、閘道、DNS、DHCP 比對
- 預設閘道與指定目標的 Ping
- 封包遺失、平均／最低／最高延遲
- DNS 名稱解析
- 指定 TCP 主機與連接埠
- HTTP/HTTPS 連線；會使用 Windows 系統代理伺服器設定
- 網卡接收／傳送錯誤與丟棄封包的檢測期間增量
- TCPv4／TCPv6 系統級重傳增量與近似重傳比例
- 實體與虛擬網卡分類（虛擬網卡只列為資訊；沒有實體網卡時列為注意或異常）
- IT 診斷資料（僅供參考，HTML 報告中預設收合）：Wi-Fi 無線（SSID、頻段、頻道、訊號、速率）、
  IPv4 預設路由、閘道鄰居（ARP）、Proxy 設定、前幾跳 traceroute、網卡驅動版本

HTML 報告開頭是依結果整理的「要告訴 IT 的話」。JSON 報告（schema 2）帶有執行選項、指紋，
以及每筆結果的 Tag／Scope，供工具使用。

TCP 重傳結果是「整台電腦在本次取樣期間」的系統級統計，不只屬於單一程式。短時間樣本沒有重傳，不代表長時間一定沒有問題；最好在問題發生時執行。


三、錯誤處理
----------------------------------------
本工具會區分：

1. 「異常」
   檢查已成功執行，但結果未通過，例如無預設閘道、必要 TCP 連接埠連不上、封包遺失過高。

2. 「無法檢查」
   該步驟因權限、公司政策、系統元件缺少、計數器無法讀取或程式錯誤而沒有完成。完整例外訊息會放在報告的詳細資料中。

3. 啟動器錯誤
   若 PowerShell 無法啟動、檔案缺少或公司安全政策封鎖，黑色視窗會顯示錯誤，並嘗試建立：
   LauncherError.txt

4. 未處理錯誤
   若主程式發生未處理錯誤，會嘗試在 Reports 或 Windows 暫存資料夾產生：
   NetworkHealthCheck_FATAL_日期時間.txt
   若只有部分報告格式（HTML／TXT／JSON）無法寫入，其餘格式仍會保存，「開啟報告」會開啟第一個可用的檔案；
   三種格式全部失敗時才會產生 FATAL 檔（文字模式結束碼為 1）。

5. 報告資料夾無法寫入
   程式會自動改存到：
   %TEMP%\NetworkHealthCheck\Reports
   並在執行畫面與報告中顯示提示。

另附「Start-NetworkCheck-Console.cmd」，可在圖形介面無法啟動時以文字模式執行並保留畫面。


四、設定公司標準 IP
----------------------------------------
請由 IT 人員使用記事本編輯：
NetworkHealthCheck.config.json

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


五、加入公司系統連線測試
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


六、門檻值
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


七、報告判讀
----------------------------------------
- 整體正常：必要項目均通過，且沒有警告或執行錯誤。
- 需要注意：沒有必要項目失敗，但有封包遺失、延遲、網卡計數或其他警告。
- 偵測到異常：至少一項必要檢查未通過。
- 檢測未完整：沒有必要項目失敗，但至少一項因權限、系統元件或執行錯誤而無法檢查。

外部 Ping 失敗不一定代表網路中斷，因為部分防火牆會封鎖 ICMP；因此預設還會執行 TCP 與 HTTP/HTTPS 測試。報告應綜合判讀，不要只看單一 Ping。


八、安全與隱私
----------------------------------------
- 不會自動上傳報告。
- 報告只寫入本機程式資料夾或 Windows 暫存資料夾。
- 報告包含電腦名稱、目前登入使用者、網卡、MAC、IP、閘道、DNS、Wi-Fi 網路名稱（SSID）與基地台 BSSID、測試目標與錯誤資訊；對外傳送報告前請依公司規定處理。
- 預設會連線到 1.1.1.1:443、www.microsoft.com，並 Ping 1.1.1.1。IT 可在設定檔中改成公司核准的目標。


九、常見問題
----------------------------------------
A. Windows 顯示安全警告或檔案被封鎖
   請先確認檔案來源可信。可在 ZIP 或檔案上按右鍵 → 內容 → 解除封鎖，再完整解壓縮。公司 AppLocker、WDAC、EDR 或群組原則仍可能封鎖 PowerShell；此時 LauncherError.txt 會記錄啟動失敗，需交由 IT 處理。

B. 出現「無法讀取 TCP 計數器」
   可能是效能計數器、WMI/CIM、權限或公司端點防護限制。這不等同於已確認大量重傳；報告會把它列為「無法檢查」。

C. 執行後只有少量 TCP 流量
   報告會標示樣本不足。請在視訊、下載、公司系統卡頓或問題重現期間執行，或提高 RetransmissionSampleSeconds。

D. 公司使用 VPN
   報告可能同時顯示實體網卡與 VPN 網卡。公司標準應依預期情境設定；若需要更精準地只比對特定網卡，可由 IT 進一步客製化腳本。

E. 可否直接改 NetworkHealthCheck.ps1
   可以，但建議只修改 JSON 設定檔。修改主程式前請先備份並重新測試。


十、英文版與技術文件
----------------------------------------
本版套件同時提供 zh-TW 與 en-US 兩個獨立資料夾。兩者的檢測邏輯、設定鍵與
門檻相同，使用者介面、報告文字、預設測試名稱及程式碼註解依語言分開。

完整設計、驗證方式、限制及註解策略請參閱：
- NetworkHealthCheck_Technical_Guide_zh-TW.md
- NetworkHealthCheck_Technical_Guide_en-US.md

程式碼已加入架構說明與主要功能分區註解。註解著重於設計意圖、錯誤處理、
回退機制與判定規則，不會逐行重述顯而易見的 PowerShell 語法。
