# NetworkHealthCheck Portable 1.2.0：功能、設計、驗證與限制

## 1. 文件目的

本文件說明 `NetworkHealthCheck` 免安裝工具的功能、架構、判定方式、錯誤處理、驗證方法、已知限制與原始碼註解策略。文件對應版本 **1.2.0**，適用於套件中的繁體中文版與英文版；兩者的執行邏輯相同，只有使用者可見文字、預設測試名稱與註解語言不同。

## 2. 程式定位

這是一個 Windows PowerShell 可攜式診斷工具，不需要安裝服務、驅動程式或封包擷取元件。它的主要目的不是取代 Wireshark、網路監控平台或交換器管理系統，而是讓一般使用者按一次即可收集一致的網路資訊，並把無法執行的原因保留在報告中供 IT 判讀。

程式採唯讀設計：不修改 IP、DNS、路由、防火牆、代理伺服器或網卡啟停狀態。主動行為只有 Ping、DNS 查詢、TCP 連線與 HTTP/HTTPS GET 測試。

## 3. 套件內容

| 檔案 | 用途 |
|---|---|
| `Start-NetworkCheck.cmd` | 圖形介面啟動器；檔案缺少、PowerShell 不存在或回傳非零代碼時顯示錯誤並嘗試寫入 `LauncherError.txt`。 |
| `Start-NetworkCheck-Console.cmd` | GUI 無法使用時的文字模式啟動器。 |
| `Start-NetworkCheck-IT.cmd` | IT 入口（1.2）：執行選項面板、不自動開始、HTML 預設展開 IT 診斷資料；同樣的參數可用於文字模式。 |
| `NetworkHealthCheck.ps1` | 主要檢測、判定、錯誤處理與報告程式碼。 |
| `NetworkHealthCheck.config.json` | 公司 IP 標準、測試目標、逾時與門檻。 |
| `README_*.txt` | 快速操作及設定說明。 |
| `NetworkHealthCheck_Technical_Guide_*.md` | 本文件的中英文版本。 |
| `SHA256SUMS.txt` | 發行檔案的 SHA-256。 |
| `tools/validate_release.py` | 跨平台靜態發行驗證腳本，不執行 Windows 網路檢測。 |

## 4. 功能與判定方式

### 4.1 設定檔載入

程式先建立內建安全預設值，再讀取 JSON 設定並遞迴合併。設定檔不存在或 JSON 無法解析時，不會直接終止；程式改用內建預設值，將原因記成 `ERROR / 無法檢查`，並繼續能執行的項目。

語意驗證包含：IPv4、CIDR、前綴長度、閘道、DNS、DHCP 布林值、TCP 主機/連接埠、HTTP/HTTPS URL、DNS 目標及主要逾時值。部分不合理門檻會列為警告。自 1.1.4 起，所有數值門檻改用不受地區設定影響、不會拋出例外的轉換器：非數值（含布林值、NaN 與無限大）會列入設定警告並改用內建預設值，小數門檻（例如 `2.5`）照原值使用，不再四捨五入成整數。計數類設定，即網卡錯誤／丟棄增量、`TcpRetransmissionCriticalCount`、`MinimumTcpSegmentsForRate`、`PingCount` 與各逾時值，必須是 32 位元整數範圍內的整數；填小數或超出範圍的值會被列入警告並改用預設值，不再被靜默改動。語意錯誤目前不會把相關設定自動全部刪除，因此錯誤設定仍可能使部分結果失去判斷意義；報告會明確提示。

### 4.2 網卡與 IP 資料來源

優先使用 `Get-NetIPConfiguration`、`Get-NetIPInterface` 及 NetAdapter/NetTCPIP 物件。若不可用或無法取得資料，改用 `Win32_NetworkAdapterConfiguration` 與 `Win32_NetworkAdapter` 的 CIM/WMI 資料。

收集欄位包括介面名稱、描述、介面索引、連線速度、MAC、網路設定檔、IPv4/IPv6、前綴、閘道、DNS、DHCP 與資料來源。具有 IPv4 且有閘道的介面優先視為主要介面；若沒有，退而使用具有 IPv4 的介面。CIM/WMI 備援路徑（1.1.4）只把 `DefaultIPGateway` 中的 IPv4 下一跳視為閘道；`DHCPEnabled` 缺值時列為未知，而不是靜態 IP。

基本異常規則：

| 條件 | 結果 |
|---|---|
| 找不到已連線且有 IP 的網卡 | `FAIL` |
| 偵測到 `169.254.x.x` | `FAIL`，通常表示 DHCP 未取得位址 |
| 網卡沒有 IPv4、但仍有其他 IP 資料 | `WARN` |
| 沒有 IPv4 預設閘道 | `FAIL` |
| 沒有 DNS 伺服器 | `FAIL` |

### 4.3 公司標準比對

只有 `Expected` 至少設定一項規則時才會判定合規；全部留空時僅顯示目前設定，不會宣稱正確或錯誤。

- IP：目前主要介面的任一 IPv4，只要精確符合允許 IP 或落在任一允許 CIDR 即通過。
- 前綴：目前主要介面的任一前綴符合允許清單即通過。
- 閘道：目前主要介面的任一閘道符合允許清單即通過。
- DNS：設定檔列出的每一個必要 DNS，都必須出現在主要介面彙整後的 DNS 清單中。
- DHCP：所有可取得 DHCP 狀態的主要介面都必須符合預期；完全無法取得時列為 `ERROR`。

這種「多介面彙整」設計方便一般情境，但 VPN、虛擬交換器或同時連接有線/無線時，可能需要公司客製介面篩選規則。

### 4.4 Ping、封包遺失與延遲

每個目標使用 .NET `Ping` 類別送出設定次數的 ICMP。計算公式：

```text
封包遺失率 = (送出數 - 成功數) / 送出數 × 100%
```

延遲以成功回覆計算平均、最低與最高值。判定依序考慮：完全無回覆、嚴重遺失、警告遺失、嚴重平均延遲、警告平均延遲。`Required=true` 的目標在嚴重情況會成為 `FAIL`；非必要目標完全不回覆通常為 `INFO`，因為 ICMP 可能被防火牆封鎖。

預設只有 4 次 Ping；在預設嚴重遺失門檻 20% 下，遺失 1 次即為 25%。公司若不希望這麼敏感，應提高 `PingCount` 或調整門檻。

### 4.5 DNS

使用 `System.Net.Dns.GetHostAddressesAsync()` 並套用逾時。必要 DNS 名稱解析失敗為 `FAIL`，非必要目標為 `WARN`。這個測試驗證作業系統實際解析結果，不會逐台指定 DNS 伺服器送查詢。

### 4.6 TCP 與 HTTP/HTTPS

TCP 測試使用 `TcpClient.BeginConnect()`、逾時等待及 `EndConnect()`，確認主機與連接埠是否可建立 TCP 連線。

HTTP/HTTPS 使用 `HttpWebRequest`：

- 方法為 GET，允許重新導向。
- 使用 Windows 系統代理伺服器及預設代理認證。
- 嘗試啟用 TLS 1.2。
- 讀取回應資料流的 1 byte，以確認回應可讀。
- 即使伺服器回傳 4xx/5xx，只要取得 HTTP 回應，也視為「網路路徑可達」；報告仍保留狀態碼。

`RequiredConnectivityGroups` 的邏輯是「群組內至少一種方式成功即通過」，不是所有成員都必須成功。預設 Internet 群組因此可由 TCP 或 HTTP/HTTPS 任一成功證明基本連線。

### 4.7 網卡錯誤與丟棄

使用 `Get-NetAdapterStatistics` 在檢測前後取樣。計算：

```text
錯誤增量 = ΔReceivedPacketErrors + ΔOutboundPacketErrors
丟棄增量 = ΔReceivedDiscardedPackets + ΔOutboundDiscardedPackets
```

若結束累積值小於起始值，視為網卡重連、計數器重設或溢位，列為 `WARN`，不硬算錯誤增量。門檻分別由 AdapterError* 與 AdapterDiscard* 控制。

### 4.8 TCP 重傳

程式以 CIM/WMI 讀取：

- `Win32_PerfRawData_Tcpip_TCPv4`
- `Win32_PerfRawData_Tcpip_TCPv6`
- `SegmentsSentPersec`
- `SegmentsRetransmittedPersec`

這些 RawData 欄位名稱雖含 `Persec`，程式把它們當作前後累積值使用並計算增量：

```text
近似重傳率 = ΔRetransmittedSegments / ΔSentSegments × 100%
```

判定規則：

1. 前後任一資料缺少：`ERROR`。
2. 結束值小於起始值：計數器重設/溢位，`ERROR`。
3. 傳送與重傳增量都為 0：樣本不足，`INFO`。
4. 傳送 segment 少於 `MinimumTcpSegmentsForRate`：若有重傳則 `WARN`，否則 `INFO`。
5. 樣本足夠後，依比例與絕對重傳次數判定 `PASS/WARN/FAIL`。

這是整台電腦、整個取樣期間的系統級近似值，無法指出哪一個程式、遠端主機或 TCP stream 造成重傳。

### 4.9 整體結果

整體狀態採固定優先序：

```text
FAIL > ERROR > WARN > PASS
```

因此任何 `FAIL` 會顯示「偵測到異常」；沒有 FAIL 但有無法執行項目時顯示「檢測未完整」；再其次是警告；最後才是整體正常。

### 4.10 網卡分類、IT 診斷資料與指紋（1.2）

每張網卡都會分類為實體或虛擬：以 NetAdapter 的 `Virtual`／`HardwareInterface` 旗標為準，CIM 備援用 `Win32_NetworkAdapter.PhysicalAdapter`，沒有旗標時以描述字串樣式判斷（VirtualBox、Hyper-V、VMware、TAP、tunnel、loopback、WAN Miniport、WireGuard、ZeroTier、Tailscale、Docker、VPN、ISATAP、Teredo）。虛擬網卡列為 `INFO`，不套用 APIPA 與無 IPv4 規則；「可用網卡」列出實體與虛擬數量，只有虛擬網卡承載閘道時（VPN 或虛擬化）為 `WARN`，完全沒有實體網卡時為 `FAIL`。取樣期間沒有流量的網卡或虛擬網卡，其錯誤計數列為 `INFO`，因為計數器只有在有流量時才能作證。公司標準比對的主要網卡選取方式不變。

IT 診斷資料每次都會執行（可在設定檔 `Checks` 區段或用 `-NoWifi`／`-NoTraceroute` 個別停用），只產生 `INFO`，帶 `Scope = "IT"`，顯示在 HTML 報告收合的 IT 區段：

| 檢查 | 來源 | 說明 |
|---|---|---|
| Wi-Fi 無線 | `netsh wlan show interfaces`，因標籤隨語系不同、Windows 10 與 11 順序不同，改依值的形狀解析（MAC、GHz、802.11x、百分比、數字） | SSID、BSSID、頻段（該版本未印出時由頻道推斷）、頻道、速率、訊號 %、RSSI（netsh 有印時用實際值，否則由百分比估算） |
| IPv4 預設路由 | `Get-NetRoute -DestinationPrefix 0.0.0.0/0`，依有效計量（路由計量＋介面計量，即 Windows 的選路順序）排序 | 多條路由分屬不同介面時在詳細資料提示 |
| 閘道鄰居（ARP） | `Get-NetNeighbor`（備援 `arp -a`） | MAC 缺少或不完整時提示；閘道 Ping 仍是權威判定 |
| Proxy 設定 | HKCU Internet Settings、`WebRequest.GetSystemWebProxy`、`netsh winhttp show proxy` | 解釋「TCP 443 通但 HTTPS 失敗」 |
| Traceroute（前幾跳） | .NET `Ping` 以 TTL 1..N（預設 3，最多 10），每跳 1000 ms | 目標為第一個非 AUTO 的 Ping 目標 |
| 網卡驅動程式 | NetAdapter 的 `DriverVersion`／`DriverDate`／`DriverProvider` | 只列實體網卡 |

IT 範圍的項目不影響整體結果與摘要計數：`Get-OverallStatus` 與 `Get-SummaryCounts` 排除 `Scope = "IT"`，IT 資料收集失敗只會在 IT 區段內顯示為「無法檢查」（整個 IT 步驟都在該範圍執行，即使發生非預期例外也不會翻轉整體結果）。虛擬網卡的計數器項目不論增量大小都只列為資訊。

每筆結果現在帶有語言中立的 `Tag`（例如 `ping-gateway`、`dns`、`connectivity-group`、`tcp-retransmissions`、`wifi`）與 `Scope`（`Main` 或 `IT`）。指紋由標籤計算：`local`、`gateway-unreachable`、`gateway-up-internet-dead`、`dns`（只在沒有任何 DNS 檢查通過時）、`quality`（遺失、延遲、重傳或網卡錯誤的警告或異常，且沒有其他項目失敗）、`attention`（其他只有警告的執行）、`mixed`、`incomplete`、`healthy`，驅動 HTML 與文字報告頂端的「要告訴 IT 的話」，JSON 存在 `Fingerprint`。

執行選項由入口決定：`Start-NetworkCheck-IT.cmd` 帶 `-Interactive -ExpandDetails`；`-PingTarget`、`-DnsName`、`-TcpTarget`（host:port）、`-HttpUrl`、`-PingCount`、`-SampleSeconds`、`-TracerouteHops`、`-NoTraceroute`、`-NoWifi` 只影響本次執行（多個值以逗號分隔，例如 `-PingTarget 10.0.0.1,10.0.0.2`），並記錄在報告的執行設定行與 JSON 的 `RunOptions`（`EntryPoint`、`ExtraTargets` 為通過驗證的值、`RawTargets` 為原始輸入、`PingCount`、`SampleSeconds`、`TracerouteHops`、`ChecksEnabled`）。設定檔永遠不會被寫入。JSON 的 `SchemaVersion` 為 2。

## 5. 錯誤處理設計

- 每個主要步驟經 `Invoke-CheckStep` 包裝；例外轉成 `ERROR` 結果並繼續後續檢測。
- `Get-ExceptionDetails` 記錄例外型別、訊息與最多五層內部例外。自 1.1.4 起，腳本位置與呼叫堆疊改由 `Get-ExceptionDiagnostics` 另外收集，只寫入 JSON 報告的 `Diagnostics` 欄位；HTML 與文字報告改為顯示一行提示，因此本機檔案路徑不會出現在給人看的報告中。緊急（`FATAL`）檔案仍保留完整內容。
- GUI 初始化失敗時改用 Console 模式。
- 報告資料夾不可寫時改到 `%TEMP%\NetworkHealthCheck\Reports`。
- HTML、TXT、JSON 分別嘗試寫入。自 1.1.5 起，單一格式失敗只會記錄並在 GUI 顯示警告，成功的格式仍可使用：「開啟報告」會開啟 HTML、TXT、JSON 中第一個可用的檔案，文字模式對缺少的格式顯示「（未寫入）」。三種格式全部失敗時才寫一份緊急 `FATAL` 文字報告（含三個寫入錯誤與呼叫堆疊）並顯示一次錯誤對話框，文字模式結束碼為 1。報告階段在 `Run-AllChecks` 內只處理一次、不再重新拋出，外層處理器不會再產生第二份 FATAL 檔或第二個對話框。
- 啟動器本身找不到檔案/PowerShell或收到非零結束碼時，顯示提示並寫 `LauncherError.txt`。

## 6. 原始碼設計與註解

程式主要由 77 個命名函式組成，依功能分成：輔助函式、設定、系統資料、規範比對、主動測試、計數器、報告、執行協調與 GUI。

版本 1.1.0 已加入：

- 檔頭的架構與安全特性說明。
- 主要功能區塊前的分區註解。
- 原有的回退與特殊情況註解。
- 中文版使用中文註解；英文版使用英文註解。

註解刻意說明「為什麼」與風險，不逐行重述顯而易見的語法。兩種語言版本保留相同函式名稱與可執行結構，降低維護分歧。

## 7. 驗證方法

### 7.1 本次發行實際完成的靜態驗證

本次打包執行了下列不需 Windows 網路環境的檢查：

1. 必要檔案與目錄存在。
2. 中英文 JSON 均能以 UTF-8 BOM 解析。
3. PowerShell 與 JSON 使用 UTF-8 BOM；Windows 腳本使用 CRLF。
4. 英文版 PowerShell、設定檔與 README 不含中文使用者文字。
5. 中英文 PowerShell 在移除字串與註解後，可執行語法骨架完全一致。
6. 中英文函式集合一致，函式數為 77。
7. 啟動器正確引用 `NetworkHealthCheck.ps1`。
8. SHA-256 清單逐項重新計算並比對。
9. ZIP 執行完整性測試，沒有損壞項目。

驗證程式位於 `tools/validate_release.py`，對套件根目錄執行即可重現檢查；最新結果記錄於 `../VALIDATION.md`。

### 7.2 Windows 驗證狀態

原始 1.1.0 套件在非 Windows 環境打包，當時無法實際執行 Windows Forms、NetTCPIP、NetAdapter、CIM/WMI 效能計數器與真實網路連線。其後 1.1.1–1.1.3 版（2026-07-28／30）已在 Windows 11＋Windows PowerShell 5.1 完成完整實機驗證：中英兩版驗收執行、獨立程式碼審查、以及五個作者實測的故障注入場景。最新記錄維護於 `../VALIDATION.md`。1.1.4 版（2026-09-03）修掉待辦 #4、#5、#6、#11（門檻解析、CIM 備援的閘道／DHCP 判定、無用變數、堆疊不進 HTML/TXT），並以同一條驗證鏈重新驗證：parser、validator、輔助函式單元測試、中英兩版驗收執行、以及故障注入設定檔。1.1.5 版（2026-09-03）修掉待辦 #2 與 #3（緊急報告只產生一次；部分報告格式寫入失敗時保留成功的格式），並以同一條驗證鏈加上模擬檔案寫入失敗的報告階段功能測試完成驗證。1.2.0 版（2026-09-03）實作 v1.2 設計的 Phase A（repo 內 `docs/design-v1.2-triage-wizard.md`）：網卡分類、IT 診斷資料、指紋與「要告訴 IT 的話」、JSON schema 2、IT 入口，並以同一條驗證鏈加上擴充的單元測試（Windows 10／11／本地化的 Wi-Fi 樣本、分類）與執行選項、指紋的功能測試完成驗證。靜態驗證仍不能取代 Windows 實機驗收——兩者互補。

### 7.3 建議 Windows 驗收矩陣

| 情境 | 預期結果 |
|---|---|
| Windows 11、一般使用者、正常 DHCP | GUI 自動完成；HTML/TXT/JSON 產生；核心連線項目通過。 |
| 關閉 Wi-Fi/拔除網線 | 無可用網卡、閘道或 DNS 顯示 FAIL；仍產生報告。 |
| DHCP 失敗取得 169.254.x.x | APIPA 項目顯示 FAIL。 |
| 無效 JSON | 畫面與報告記錄設定檔錯誤，改用預設值繼續。 |
| 報告目錄唯讀 | 改存 `%TEMP%` 並顯示提示。 |
| 公司政策封鎖 PowerShell | 啟動視窗顯示原因並嘗試寫 `LauncherError.txt`。 |
| GUI 元件不可用 | 自動切換文字模式，或手動執行 Console 啟動器。 |
| DNS 被阻擋 | DNS 必要目標 FAIL，但 IP/TCP 測試仍執行。 |
| TCP Port 關閉 | 必要 TCP 目標 FAIL；非必要目標 INFO；群組依其他成員判定。 |
| HTTP 回傳 403/500 | 視為路徑可達並保留狀態碼，不誤判為完全無網路。 |
| 網卡重連 | 計數器下降時報告重設警告，不產生負增量。 |
| 有足夠 TCP 流量 | 與 `Get-CimInstance Win32_PerfRawData_Tcpip_TCPv4/TCPv6` 前後差值比對。 |

驗收時應把報告值與 `Get-NetIPConfiguration`、`Get-NetAdapterStatistics`、CIM/WMI 原始計數器及公司網路規劃表交叉比對。

## 8. 已知限制

1. **只支援 Windows。** 目標為 Windows 10/11 與相容 Windows Server，需 PowerShell 5.1 或更新版本。
2. **不是封包分析器。** 不擷取封包、不分析 ACK/序號，也不能證明某一條 TCP 連線的重傳根因。
3. **TCP 重傳是系統級短樣本。** 背景更新、瀏覽器或其他程式都可能影響數字；無流量時結果只代表樣本不足。
4. **Ping 可能被封鎖。** ICMP 失敗不等於 TCP/HTTPS 一定失敗，必須綜合判讀。
5. **多網卡/VPN 會彙整。** 任一介面符合部分規則可能使該項通過；複雜公司環境應增加介面名稱、類型或路由篩選。
6. **沒有 VLAN、交換器或 Wi-Fi 射頻資料。** 無法直接看到 VLAN ID、交換器 CRC、光模組、訊號強度、頻道壅塞或 AP 漫遊紀錄。
7. **無法確認未提供的公司標準。** Expected 留空時只顯示現況，不猜測正確 IP。
8. **HTTP GET 會接觸目標服務。** 應使用公司核准、無副作用的健康檢查 URL；部分網站可能記錄來源 IP、User-Agent 或代理認證流程。
9. **門檻需要校準。** 預設值不保證適合 Wi-Fi、VPN、衛星、跨國 WAN、資料中心或高吞吐伺服器。
10. **權限/端點防護可能限制資料。** AppLocker、WDAC、EDR、WMI 政策或損壞的效能計數器會導致 `ERROR`，不代表已證實網路故障。
11. **報告含敏感資訊。** 可能包含電腦名稱、使用者、MAC、IP、DNS、內部服務名稱與例外堆疊（後者僅存在於 JSON 報告，含本機腳本路徑）；外傳前需依公司政策處理。
12. **沒有自動修復。** 工具只診斷，不變更設定；這是刻意的安全界線。

12. **Wi-Fi 資料來自用戶端且由文字解析。** `netsh` 輸出依值的形狀解析，特殊版本可能留空欄位；該版本未印出 RSSI 時為估算值。AP 的用戶端列表才是較強的證據。
13. **沒有 NetAdapter 旗標時的網卡分類是啟發式的**（描述字串樣式）。
14. **Traceroute 有上限**：最多 10 跳、每跳 1 秒；沒有回應的跳顯示為 `*`，預設 3 跳通常到不了公網目標，目的是看封包停在哪裡，而不是抵達。

## 9. 發行與維護建議

- IT 應先修改設定檔，把外部預設目標換成公司核准的內部/外部服務。
- 在代表性的有線、Wi-Fi、VPN 與無外網環境建立基準報告。
- 修改 `.ps1` 後重新執行靜態驗證與 Windows 驗收，並更新 SHA-256。
- 大量部署可用軟體派送系統散佈整個資料夾，但不要只派送單一啟動檔。
- 若需要精確定位重傳，將本工具的時間點與 Wireshark、pktmon、交換器介面計數器或集中監控資料對照。
