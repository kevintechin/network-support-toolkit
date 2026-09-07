# 網路健檢工具 1.2.4 — IT 部署手冊

**寫給把工具發出去的 IT 部門。** 套件需要什麼、怎麼依你的環境設定、怎麼部署、安全政策會對它做什麼、怎麼驗證收到的東西沒被動過，以及回來的報告該怎麼處理。

本手冊對應繁體中文套件（`zh-TW` 資料夾）。`en-US` 資料夾裡的英文套件是同一支工具，附有英文版手冊和它自己的設定檔。執行檢測的人看的是旁邊的使用手冊（`NetworkHealthCheck_User_Manual_zh-TW.html`）；設計、判定規則與已知限制在技術文件（`NetworkHealthCheck_Technical_Guide_zh-TW.md`）。本手冊不重複那些內容，只講 IT 需要決定和動手做的事。

---

## 1 · 你要部署的是什麼

**一個資料夾，不是安裝程式。** 網路健檢工具是一支 Windows PowerShell 腳本，加上批次檔啟動器、一個 JSON 設定檔和幾份文件。它不安裝任何服務、驅動程式或封包擷取元件，也不登錄任何東西；它寫出的只有報告（第 3.1 節），以及執行無法開始或無法完成時寫在程式旁邊或使用者暫存資料夾裡的錯誤檔（第 3.6 與第 8 節）。對系統而言它是唯讀的：不改 IP、DNS、路由、防火牆、Proxy 或網卡設定。它的主動行為只有幾次 Ping、一次名稱查詢、幾個 TCP 連線，以及對設定檔裡的目標發出 HTTP/HTTPS GET 請求。

**電腦需要什麼。**

| 需求 | 說明 |
|---|---|
| Windows 10 或 Windows 11（或相容的 Windows Server） | 其他平台，或低於 5 的 PowerShell，會在設定檔那幾列之後得到一列「異常」，執行就停在那裡 |
| Windows PowerShell 5.1 | Windows 內建。啟動器執行 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`；該檔案不存在時改找 PATH 上的 `pwsh.exe`（PowerShell 7），兩者都沒有就停下並顯示「此電腦找不到 PowerShell」 |
| 含 Windows Forms 的 .NET Framework | Windows 內建；只有視窗需要。視窗建不起來時，工具會自己改用文字模式跑同樣的檢測，並在一列警告裡說明 |
| 一般使用者帳號 | 不需要系統管理員權限。一般使用者讀不到的東西會變成「無法檢查」列，檢測繼續 |
| 使用者可寫入的資料夾 | 報告預設寫在程式旁邊（第 3.1 節）。那個資料夾不可寫時，工具改寫到使用者的暫存資料夾 |

**三個入口。** 每個語言資料夾有三個啟動器；套件最上層的兩個啟動器各自開啟自己語言的使用者入口。

| 啟動器 | 啟動什麼 | 給誰用 |
|---|---|---|
| `Start-NetworkCheck.cmd`（最上層：`Start-Traditional-Chinese.cmd`） | 視窗，自己開始檢測 | 遇到問題的人 |
| `Start-NetworkCheck-IT.cmd` | 上方多一個「**執行選項（IT）**」面板的視窗；按下開始之前什麼都不跑；HTML 報告預設展開所有詳細資料 | 在機器前的 IT |
| `Start-NetworkCheck-Console.cmd` | 文字模式（`-ConsoleOnly`），結束時暫停，報告路徑留在畫面上 | 視窗開不起來的電腦，或遠端工作階段 |

每個啟動器都以 `-NoProfile -ExecutionPolicy Bypass` 和它自己固定的參數執行 PowerShell，不會轉送任何接在 `.cmd` 後面輸入的東西。要傳參數，看第 4 節。

**出廠設定會連到哪裡。** 這台電腦的預設閘道（Ping）、`1.1.1.1`（Ping、一次連接埠 443 的 TCP 連線、往它的 traceroute 前三跳）、`www.microsoft.com`（經作業系統解析器的一次名稱查詢，以及經 Windows 設定的 Proxy 的一次 HTTPS 請求，會跟隨轉址）。換掉它們的方法在第 3.3 節。不會上傳任何東西：報告是報告資料夾裡的檔案。

---

## 2 · 發出去之前

1. **驗證下載的檔案**（第 6 節）：先比對 ZIP 的 SHA-256 與發行說明，再比對套件內的清單檔。
2. **決定測試目標**（第 3.3 節）。把公網位址換成使用者實際需要的服務，並決定「能不能連外」是不是這個檢測該要求的事。
3. **設定公司標準**（第 3.2 節），如果你希望報告能說位址、閘道、DNS 伺服器或 DHCP 模式*對不對*。出廠狀態下，工具只顯示目前設定，並說明尚未定義標準。
4. **依你自己的基準校正門檻**（第 3.5 節）：有線、Wi-Fi、VPN、WAN 和資料中心的線路不會共用同一組數字。
5. **決定報告放哪裡、怎麼處理**（第 3.1 與第 7 節）。報告含電腦與使用者名稱、位址、Wi-Fi 網路、Proxy 與前幾跳的路由器；完整清單由使用手冊第 5 節「報告裡有什麼」維護。工具交到任何人手上之前，先決定處理規定。
6. **在一台有代表性的電腦上用 `Start-NetworkCheck-IT.cmd` 跑一次**，讀報告最前面幾列（第 3.6 節），把那份報告留作基準。你支援的每一種連線方式（有線、Wi-Fi、VPN、限制連外）都各跑一次。
7. **兩個語言資料夾都要設定**，如果兩個都要發。`zh-TW\NetworkHealthCheck.config.json` 和 `en-US\NetworkHealthCheck.config.json` 是兩個獨立的檔案；出廠時兩者只差預設目標的顯示名稱。

---

## 3 · 設定檔

`NetworkHealthCheck.config.json` 放在程式旁邊。工具每次啟動都讀它，把它合併到內建預設值之上，而且永遠不會寫回去：執行選項（第 4 節）改的是一次執行，不是檔案。

**怎麼讀的。** 沒寫的鍵保留內建預設值；有寫的鍵取代預設值。物件逐鍵合併，所以 `Expected` 可以只給兩條規則、其餘省略。清單則整個取代：檔案裡的 `PingTargets` 清單*就是*那份清單，出廠項目沒有重寫的就不存在了。工具不認識的鍵會被忽略。

**讀不了的時候。** 檔案不存在，或不是合法 JSON，都不會讓執行中止：工具改用內建預設值，報告第一列「**設定檔**」會是「無法檢查」並寫出原因（「找不到設定檔：…」或「設定檔格式錯誤，程式已改用內建預設值。」加上解析器的訊息）。光是這一列就會讓整體結果變成「**檢測未完整**」，所以壞掉的設定檔在每份報告裡都看得到。能解析的檔案接著逐值檢查（第 3.6 節）。

**JSON 規則。** 文字用雙引號；項目之間有逗號、最後一個項目後面沒有；`true`、`false`、`null` 不加引號；不能寫註解。出廠檔案是含位元組順序標記（BOM）的 UTF-8、Windows 換行，記事本會保留這兩者；工具本身有沒有 BOM、哪一種換行都讀得了，但發行驗證程式（第 6 節）預期的是出廠形式。

**不換掉檔案就測試一份新設定。** 腳本接受 `-ConfigPath <檔案>`，所以候選設定可以先在主控台試跑，再放進資料夾：

```text
powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly -ConfigPath C:\Temp\candidate.config.json
```

報告的「設定檔」列會寫出載入的是哪個檔案，「電腦與執行資訊」一節也會再列一次。

### 3.1 · 識別與報告資料夾

| 鍵 | 預設 | 作用 |
|---|---|---|
| `OrganizationName` | `""` | 印在 HTML 報告的標頭；空值印出「未指定單位」。文字與 JSON 報告不含這個值 |
| `ReportFolderName` | `"Reports"` | 相對名稱建立在程式旁邊（`zh-TW\Reports`）；有根的路徑（磁碟機代號或 UNC 路徑）照用。資料夾不存在會建立。無法寫入時，報告改寫到 `%TEMP%\NetworkHealthCheck\Reports`，報告裡多一列「**啟動提示**」警告說明這件事，光是這一列就會讓整體結果變成「需要注意」 |

每次執行最多寫出三個檔案：`NetworkHealthCheck_<yyyyMMdd>_<HHmmss>_<電腦名稱>.html`、`.txt`、`.json`，含 BOM 的 UTF-8。三種格式各自寫入：寫不出來的那一種會被指出（視窗說「3 種報告格式中有 N 種無法寫入」，主控台列為「（未寫入）」），其他格式照常可用；三種都失敗時，工具才改寫緊急的 `NetworkHealthCheck_FATAL_<時間>.txt`。同一時間只跑一份工具時檔名不會重複；工具不刪任何東西，所以資料夾每跑一次最多多三個檔案，直到有人清理。

指到共用資料夾的有根 `ReportFolderName`，是唯一會讓報告在沒有人送出的情況下離開這台電腦的設定：每個使用者的每份報告都直接落在那裡，報告裡的「報告目錄」一行會告訴使用者，但不會問他。要用就有意識地用，把第 7 節的處理規定先定好，並確認每個使用者都寫得進去：寫不進去的使用者會得到暫存資料夾的備援。

### 3.2 · 公司標準（`Expected`）

出廠時每條規則都是空的，報告會在一列「資訊」裡說明：「設定檔尚未填入公司標準，因此只能顯示目前設定，不能判定 IP 是否符合公司規範。」填入描述你環境的規則，其餘留空。只要設了一條規則，比對就會執行。

```json
"Expected": {
  "AllowedIPv4Addresses": [],
  "AllowedIPv4Cidrs": ["192.168.10.0/24"],
  "AllowedPrefixLengths": [24],
  "AllowedDefaultGateways": ["192.168.10.1"],
  "RequiredDnsServers": ["192.168.10.5"],
  "DhcpEnabled": true
}
```

| 規則 | 通過條件 | 不通過時的列 |
|---|---|---|
| `AllowedIPv4Addresses`、`AllowedIPv4Cidrs`（算同一條規則） | 主要網卡的任一 IPv4 位址等於清單中的位址，或落在清單中的網段內 | 「**IPv4 位址/網段**」異常 |
| `AllowedPrefixLengths` | 主要網卡目前的任一前綴長度在清單中 | 「**子網路前綴**」異常 |
| `AllowedDefaultGateways` | 主要網卡目前的任一閘道在清單中 | 「**預設閘道**」異常 |
| `RequiredDnsServers` | 清單中的*每一個*伺服器都出現在主要網卡的 DNS 伺服器裡（IPv6 位址也接受） | 「**DNS 伺服器**」異常，列出缺少的 |
| `DhcpEnabled`（`true`／`false`／`null`） | 每張 DHCP 狀態已知的主要網卡都符合該值；`null` 跳過這條規則 | 「**DHCP 模式**」異常；沒有任何網卡回報 DHCP 狀態時為「無法檢查」 |

*主要網卡*指已連線、有 IPv4 位址又有預設閘道的網卡；沒有任何一張有閘道時，則是每一張已連線、有 IPv4 位址的網卡。所有主要網卡的值會先合併再套規則，所以在有 VPN 或第二條連線的電腦上，一張網卡可以滿足另一張違反的規則；技術文件第 4.3 節討論這個限制。設了規則卻完全沒有可用網卡時，比對只有一列異常。

### 3.3 · 測試目標（`Tests`）

四份清單加一份群組名稱清單。每個目標可以給顯示用的 `Name`（那一列的標題）和一個 `Required` 旗標；TCP 與 HTTP 目標還可以有 `Group`。

```json
"Tests": {
  "PingTargets": [
    { "Name": "預設閘道", "Address": "AUTO_GATEWAY", "Required": true },
    { "Name": "檔案伺服器", "Address": "10.0.0.20", "Required": false }
  ],
  "DnsNames": [
    { "Name": "DNS 名稱解析", "Host": "intranet.company.local", "Required": true }
  ],
  "TcpTargets": [
    { "Name": "ERP 系統", "Host": "erp.company.local", "Port": 443, "Required": true, "Group": "Company" }
  ],
  "HttpTargets": [
    { "Name": "公司入口網站", "Url": "https://portal.company.local/", "Required": false, "Group": "Company" }
  ],
  "RequiredConnectivityGroups": ["Company"]
}
```

| 清單 | 欄位 | 省略 `Required` 時 | 說明 |
|---|---|---|---|
| `PingTargets` | `Name`、`Address`、`Required` | `false` | `AUTO_GATEWAY` 代表主要網卡的 IPv4 預設閘道，`AUTO_DNS` 代表它們的 DNS 伺服器，解析出的每個位址各一列。佔位符解析不出任何位址時，必要目標列為異常，選用目標列為需注意 |
| `DnsNames` | `Name`、`Host`、`Required` | **`true`** | 清單裡直接寫一個字串也接受，視為必要。查詢走作業系統的解析器，不會逐一查詢每台設定的伺服器 |
| `TcpTargets` | `Name`、`Host`、`Port`、`Required`、`Group` | `false` | 對該連接埠做一次 TCP 連線，建立後立刻關閉；工具不在上面送任何資料 |
| `HttpTargets` | `Name`、`Url`、`Required`、`Group` | `false` | 經系統 Proxy 的一次 GET，提供 TLS 1.2，跟隨轉址；4xx 或 5xx 的回應仍算連得到，並保留狀態碼。請用沒有副作用的 URL：目標的記錄會看到這個請求 |
| `RequiredConnectivityGroups` | 名稱 | — | 整體結果所依據的群組 |

**目標失敗對整體結果的影響。** 規則和執行選項（第 4 節）用的是同一套，讀報告的人需要知道：

| 目標 | 必要 | 選用 |
|---|---|---|
| Ping 完全沒有回應 | 異常 | 資訊（ICMP 可能只是被擋） |
| Ping 有回應，但遺失或延遲超過門檻 | 達嚴重門檻為異常，達警告門檻為需注意 | 需注意 |
| 解析不出來的 DNS 名稱 | 異常 | **需注意** |
| 連不上的 TCP 或 HTTP 目標 | 異常 | 資訊 |

「資訊」列永遠不影響整體結果，所以一個選用的 TCP 或 HTTP 目標可以在一份寫著「**整體正常**」、上方還有「全部通過」的報告裡失敗；使用手冊要求使用者去讀那幾列。群組是讓選用目標一起計入的方法：群組那一列在**至少一個**成員成功時通過；成員全部失敗時，列在 `RequiredConnectivityGroups` 的群組為異常，其他群組為需注意。一個必要群組完全沒有成員（名稱有列，但沒有目標帶這個名稱）時，會是一列「無法檢查」（「此群組沒有可執行的測試項目。」），光是這一列就會讓整體結果變成「檢測未完整」。

**逾時與次數**（整數；小數、文字或零以下的值會在「設定值門檻」列裡被指出並取代）：

| 鍵 | 預設 | 下限 | 說明 |
|---|---|---|---|
| `PingCount` | 4 | 1 | 每個 Ping 目標的回應請求次數。四次探測配出廠的 20 % 嚴重遺失門檻，掉一次就是 25 %、算嚴重；覺得太敏感就提高次數或門檻 |
| `PingTimeoutMs` | 1200 | 250 | 每次回應請求 |
| `DnsTimeoutMs` | 4000 | 500 | 每個名稱 |
| `TcpTimeoutMs` | 4000 | 500 | 每個連線 |
| `HttpTimeoutMs` | 6000 | 500 | 每個請求，連線與讀取皆同 |
| `RetransmissionSampleSeconds` | 8 | 1 | TCP 計數器在開始時取樣一次，過了這麼多秒再取樣一次，所以這是執行時間的下限；各項測試在這段時間內進行，目標不回應時，它們的逾時會再疊上去 |

**不允許連外的環境。** 移除公網的 Ping、TCP、HTTP 目標，把 `www.microsoft.com` 的名稱查詢換成你的解析器查得到的內部名稱（出廠的 `DnsNames` 項目是必要的，解析不出來就會讓這次執行失敗），把 `Internet` 群組換成你的內部服務，或者把 `Internet` 從 `RequiredConnectivityGroups` 移除（否則群組列會因為沒有成員而變成「無法檢查」），並把 `Checks.Traceroute` 設為 `false`：traceroute 會探測往第一個不是佔位符的 Ping 目標，一個都沒有時，仍然會探測往 `1.1.1.1`。

### 3.4 · 可選檢查（`Checks`）

IT 診斷資料（報告最下方收合區裡 IT 範圍的列，永遠不計入整體結果）每一項都可以關掉，在這裡關，或在 IT 面板裡只關一次。那裡的「資訊」列記的是收集到的內容，或者說明沒有東西可收集、來源在這台電腦上不存在（沒有已連線的無線介面或沒有 `netsh.exe`、沒有 `Get-NetRoute`、沒有預設路由或閘道、沒有已連線的實體網卡）；「無法檢查」列表示讀取來源時發生錯誤（無線資料、路由表、鄰居表或 traceroute）。

| 鍵 | 預設 | 收集什麼 |
|---|---|---|
| `WifiRf` | `true` | 無線介面的 SSID、BSSID、頻段、頻道、速率與訊號，從 `netsh wlan show interfaces` 解析 |
| `RouteTable` | `true` | IPv4 預設路由，依 Windows 使用的順序 |
| `GatewayNeighbor` | `true` | 鄰居（ARP）表裡閘道的硬體位址 |
| `ProxySettings` | `true` | 使用者的 Proxy 設定、WinHTTP Proxy，以及 Windows 對第一個 HTTP 目標（沒有時是 `https://www.microsoft.com/`）會用哪個 Proxy：只問解析器，不發請求 |
| `Traceroute` | `true` | 往第一個不是佔位符的 Ping 目標的前幾跳，每跳一秒 |
| `TracerouteHops` | 3 | 1 到 10；其他值退回 3 並附警告。三跳看得出封包停在哪裡，通常到不了公網目標 |
| `DriverInfo` | `true` | 每張已連線實體網卡的驅動程式版本、日期與廠商 |

不是 `true` 或 `false` 的旗標會停用該檢查；其他型別的值會在設定值門檻列被指出，`null` 則不會，檢查只是關掉了。

### 3.5 · 門檻值（`Thresholds`）

預設值是通用的起始點。各列拿它們怎麼判定，照程式碼寫出來：

| 鍵 | 預設 | 規則 |
|---|---|---|
| `PacketLossWarningPercent`、`PacketLossCriticalPercent` | 5、20 | 每個 Ping 目標，依這個順序：完全沒有回應 → 必要為異常、選用為資訊；遺失 ≥ 嚴重 → 必要為異常、選用為需注意；遺失 ≥ 警告 → 需注意；接著才是延遲規則 |
| `LatencyWarningMs`、`LatencyCriticalMs` | 100、250 | 以有回應的探測平均值判定：≥ 嚴重 → 必要為異常、選用為需注意；≥ 警告 → 需注意 |
| `TcpRetransmissionWarningPercent`、`TcpRetransmissionCriticalPercent` | 2、5 | 取樣期間重傳 ÷ 傳送的 segment 數，整台電腦、TCPv4 與 TCPv6 分開算：比例 ≥ 嚴重 → 異常；≥ 警告 → 需注意 |
| `TcpRetransmissionCriticalCount` | 50 | 取樣期間的重傳 segment 數：達到就是需注意；若比例同時達到警告百分比，則為異常 |
| `MinimumTcpSegmentsForRate` | 50 | 傳送的 segment 少於這個數時不判比例：有任何重傳就是需注意，沒有就是資訊。完全沒有流量也是資訊 |
| `AdapterErrorWarningDelta`、`AdapterErrorCriticalDelta` | 1、10 | 取樣期間每張網卡新增的接收加傳送錯誤數：≥ 嚴重 → 異常，≥ 警告 → 需注意。虛擬網卡不論計數一律資訊，取樣期間沒有流量也沒有錯誤的實體網卡也是資訊；計數器倒退是需注意 |
| `AdapterDiscardWarningDelta`、`AdapterDiscardCriticalDelta` | 1、100 | 丟棄封包的同一套規則 |

百分比和毫秒可以是小數；次數與增量必須是整數。不是數字的值會被換成預設值並指出；`null` 會被換成預設值但不指出。警告值高於嚴重值時，封包遺失、延遲與重傳百分比會被指出並照寫的值使用；網卡增量則悄悄把嚴重值提高到警告值，低於 1 的警告值變成 1。

### 3.6 · 報告怎麼描述設定檔

報告一開始就是設定檔的幾列（設定檔、任何啟動提示，接著設定值驗證與設定值門檻），所以錯誤會出現在使用者不可能錯過的地方；「標準設定」那一列則在較後面比對的位置：

| 列 | 狀態 | 意思 |
|---|---|---|
| **設定檔** | 正常：「已載入：<路徑>」 | 檔案讀到了；路徑就是使用中的那一個 |
| **設定檔** | 無法檢查 | 檔案不存在或不是合法 JSON；用內建預設值跑了。整體結果為檢測未完整 |
| **設定值驗證** | 無法檢查 | 有無效值：`Expected` 底下解析不了的 IPv4 位址、網段、前綴、閘道或 DNS 伺服器，不是 `true`、`false`、`null` 的 `DhcpEnabled`，沒有主機或連接埠不在 1–65535 的 TCP 目標，URL 不是絕對 `http` 或 `https` 位址的 HTTP 目標，主機空白的 DNS 項目。數量與有問題的值寫在該列的詳細資料裡。值不會被移除：主機或連接埠無效的 TCP 目標、URL 空白的 HTTP 目標，必要時變成它自己的「無法檢查」列，選用時被跳過；主機空白的 DNS 項目被跳過；格式錯誤但不空白的 URL 仍會嘗試，並像連不上的目標一樣失敗；`Expected` 底下的無效值永遠比對不到任何東西 |
| **設定值驗證** | 正常：「設定值格式檢查通過。」 | 完全沒有東西要報。只有下面那列門檻有話要說時，這一列不會出現 |
| **設定值門檻** | 需注意 | 只在某個次數、逾時、門檻或檢查旗標型別錯誤、超出範圍，或警告值高於嚴重值時出現；詳細資料逐一點名，被取代的值會說明改用了什麼；順序警告只寫出那一對值，因為它們照寫的值使用（第 3.5 節） |
| **標準設定** | 資訊 | `Expected` 底下沒有規則；設了規則後改出現比對列 |
| **啟動提示** | 需注意 | 執行時的狀況：報告資料夾退到暫存資料夾、工具在壓縮檔檢視裡執行、視窗開不起來改用文字模式，或執行選項裡的額外 TCP 目標被忽略 |

---

## 4 · 執行選項：IT 入口與命令列

執行選項只改一次執行，永遠不改檔案。來源有兩個。

**IT 面板。** `Start-NetworkCheck-IT.cmd` 開啟的視窗上方有「**執行選項（IT）**」並停下來等：「就緒，調整選項後按「開始檢測」」。欄位有「**額外 Ping**」、「**額外 DNS**」、「**額外 TCP（host:port）**」、「**額外 URL**」、「**Ping 次數**」、「**取樣秒數**」；核取方塊「**Wi-Fi 無線**」、「**Traceroute**」與「**Traceroute 跳數**」、「**路由**」、「**閘道 ARP**」、「**Proxy**」、「**驅動程式**」為這次執行切換可選檢查；「**HTML 預設展開細節**」預設勾選；「**還原設定檔**」把每個欄位放回設定檔的值。旋轉鈕涵蓋 1–20 次 Ping 與 1–120 秒；設定檔的值超過這個範圍時範圍會跟著放寬，所以不動面板直接按開始，跑的就是設定檔的值。

**參數。** 面板上大部分的選項也有腳本參數，給主控台執行或腳本化執行用：額外目標、次數，以及 Wi-Fi 與 traceroute 兩個核取方塊；面板上另外四個核取方塊（路由、閘道 ARP、Proxy、驅動程式）沒有參數，主控台執行時要在以 `-ConfigPath` 傳入的設定檔裡關掉：

```text
powershell -NoProfile -ExecutionPolicy Bypass -File NetworkHealthCheck.ps1 -ConsoleOnly -PingTarget 10.0.0.1 -TcpTarget fileserver:445 -SampleSeconds 20 -ExpandDetails
```

| 參數 | 作用 |
|---|---|
| `-ConsoleOnly` | 文字模式；有寫出報告時程序以 0 結束，一份都寫不出來時以 1 結束 |
| `-Interactive` | 帶 IT 面板的視窗，不自動開始（IT 啟動器傳的就是它） |
| `-ExpandDetails` | HTML 裡每個「顯示詳細資料」預設展開；同時把這次執行標記為 IT 入口 |
| `-PingTarget`、`-DnsName`、`-TcpTarget`（host:port） | 額外目標。多個值寫成一個逗號分隔的清單：`-PingTarget 10.0.0.1,10.0.0.2`，從 cmd.exe（`powershell -File …`）和 PowerShell 提示字元都可以；加了引號的值裡也可以用空格或分號分隔（`-PingTarget "10.0.0.1 10.0.0.2"`）。見表格下方的說明 |
| `-HttpUrl` | 額外 URL。多個寫成一個加引號、以空格分隔的值：`-HttpUrl "https://a.company.local/ https://b.company.local/"`，兩種 shell 都可以。腳本只用空格切開 URL，因為逗號和分號在 URL 裡是合法字元，所以從 cmd.exe 傳 `u1,u2` 會變成一個無效的 URL；在 PowerShell 提示字元下逗號會組成陣列，可以用。見表格下方的說明 |
| `-PingCount`、`-SampleSeconds`、`-TracerouteHops` | 這次執行覆蓋設定檔的值；跳數不在 1–10 內退回 3 |
| `-NoTraceroute`、`-NoWifi` | 略過這兩項診斷，也只有這兩項有參數 |
| `-ConfigPath <檔案>` | 載入另一個設定檔（第 3 節） |
| `-STA`（PowerShell 自己的參數） | 視窗啟動器會加的；`-ConsoleOnly` 不需要 |

**兩種要避免的寫法。** 用空格再接第二個值（`-PingTarget a b`、`-HttpUrl u1 u2`）不是第二個目標：PowerShell 會把它繫結到腳本的第一個位置參數 `-ConfigPath`，於是這次執行載入不到設定檔（「找不到設定檔：b」、一列「無法檢查」、內建預設值、整體結果為檢測未完整），而且只測第一個值；從 cmd.exe 和 PowerShell 提示字元都量測過。另外在 PowerShell 提示字元下，沒加引號的分號會結束陳述式：`-PingTarget a;b` 只測 `a`，然後把 `b` 當成命令執行；cmd.exe 則會原樣傳入。上面的逗號寫法和加引號的寫法可以避開這兩者。

**額外目標算什麼。** 額外目標都是選用的，也不屬於任何群組：沒有回應的額外 Ping，以及連不上的額外 TCP 或 HTTP 目標，是「資訊」列，不影響整體結果；品質不佳的 Ping 和解析不出來的額外 DNS 名稱是「需注意」列。格式不是 `host:port` 的額外 TCP 目標會被丟掉，並留下一列「啟動提示」警告（「已忽略額外 TCP 目標「…」：格式應為 host:port。」）。這些列的標題是「額外 Ping」、「額外 DNS」、「額外 TCP」、「額外 URL」。

**這次執行的選項記在哪裡。** 報告標頭的「執行設定」一行：`IT 入口 | 額外目標：ping 10.0.0.1, tcp fileserver:445 | Ping 次數 4 | 取樣 20 秒 | traceroute 3 跳`，關掉的檢查以「已停用：…」列出；以及 JSON 的 `RunOptions`：`EntryPoint`、`ExpandDetails`、`ExtraTargets`（接受的值）、`RawTargets`（輸入的原文）、`PingCount`、`SampleSeconds`、`TracerouteHops`、`ChecksEnabled`。

---

## 5 · 部署

**整個資料夾一起發。** 每個語言啟動器都在自己旁邊找 `NetworkHealthCheck.ps1`，找不到就停；腳本在自己旁邊找設定檔，找不到就用預設值跑。一個語言資料夾（`zh-TW` 或 `en-US`）本身是完整的：啟動器、程式、設定檔、本手冊、使用手冊與技術文件。最上層的兩個啟動器（`Start-Traditional-Chinese.cmd`、`Start-English.cmd`）只會呼叫那個名稱的資料夾，所以要發它們就保留資料夾名稱，只發一種語言時就別放它們。

**不要改程式或設定檔的檔名。** 啟動器和腳本靠名稱找它們。

**兩種送達方式，以及使用者會看到什麼。**

- *用瀏覽器下載的 ZIP* 帶有「網路標記」（Mark of the Web）；Windows 檔案總管解壓縮出來的檔案帶著同一個標記，對啟動器按兩下會出現「**開啟檔案 - 安全性警告**」，按執行後工具照常運作。解壓縮前先解除封鎖 ZIP（右鍵 → 內容 → 解除封鎖，或 PowerShell 的 `Unblock-File`），解出來的檔案就沒有標記。兩者都在兩台虛擬機上量測過（驗證記錄 `VALIDATION.md`，「Acceptance on a second machine」）。
- *不經瀏覽器送達的套件*：派送工具推的，或直接複製進去的（驗證活動從主機複製進虛擬機的那份就是），在量測過的機器上沒有標記，不會出現提示。

不管怎麼送達，使用者都必須把整個 ZIP 解壓縮：在檔案總管的 ZIP 檢視裡對啟動器按兩下，它在旁邊找不到東西就停下（使用手冊第 2 與第 6 節）。

**放在哪裡。** 任何使用者可寫入的本機資料夾；使用手冊建議桌面或文件，驗收執行也是在那裡做的。報告要落在程式旁邊，資料夾就得一直可寫；否則設定 `ReportFolderName`（第 3.1 節），或接受暫存資料夾的備援。

**升級。** 用新版本換掉整個資料夾，把你的設定檔帶過去。檔案是哪一版對工具無所謂：新版本新增的鍵，你的檔案沒有時就取預設值。升級後比對出廠檔案與你的檔案，並在新資料夾發出去之前跑一次檢測（第 3.6 節）。改過的設定檔請納入版本控制；套件分不出你的修改和出廠檔案，只能靠雜湊值（第 6 節）。

**程式檔。** 用設定，不要改腳本。改過的腳本不再符合清單檔，而且驗證程式（第 6 節）會把兩個語言版本互相比對，只改一個資料夾就會過不了。真的需要改，就保留原檔、心裡有數哪些檢查會失敗地重跑驗證程式，並自己記下雜湊值。腳本沒有數位簽章（第 8 節「簽章」）。

---

## 6 · 驗證套件

**下載檔。** 專案 Releases 頁面的發行說明給出 `NetworkHealthCheck-<版本>.zip` 的 SHA-256。解壓縮前先比對：

```text
certutil -hashfile NetworkHealthCheck-1.2.4.zip SHA256
```

或在 PowerShell 用 `Get-FileHash NetworkHealthCheck-1.2.4.zip`。發行檔只由 repo 裡受版本控制的檔案打包，所以裡面沒有任何報告或執行輸出。

**清單檔。** 套件最上層的 `SHA256SUMS.txt` 列出每個出廠檔案的摘要，除了它自己、`VALIDATION.md` 和 `validation-matrix.html`：每個檔案一行，`<sha256>  <相對路徑>`，中間兩個空格。單一檔案可以用 `Get-FileHash <檔案>` 手動比對，全部則交給驗證程式。

**驗證程式。** `tools\validate_release.py` 只需要 Python 3。對套件最上層執行：

```text
python tools\validate_release.py .
```

每項檢查印一行 `[PASS]` 或 `[FAIL]`，最後是 `Summary: N passed, M failed`，有任何失敗時結束代碼為 1。它檢查：必要檔案存在；兩個設定檔都能解析；腳本與設定檔是含 BOM 的 UTF-8 與 Windows 換行；六個語言啟動器都指向程式；英文與中文腳本除了文字以外是同一支程式（相同的函式、相同的可執行骨架）；英文檔案不含中文；兩支腳本和每份帶版本號的文件裡的版本字串；套件內的驗證記錄有這個版本的項目；以及清單檔的每一行。它不做網路檢測，也不需要 Windows。

**改過設定檔之後**，該檔案在清單檔裡那一行會失敗，驗證程式和手動比對都一樣；只要檔案仍是出廠形式的合法 JSON（第 3 節），其他都不變。這一個失敗是「設定過的套件」的正常特徵；其他任何一行失敗，表示有檔案被改動或在傳輸中損壞。

**記錄。** `VALIDATION.md` 是每一版的驗證記錄：跑了什麼、在哪些機器上、發現什麼、延後了什麼；`validation-matrix.html` 是較早版本的故障情境矩陣。驗證鏈本身，包括在只有 Windows PowerShell 的機器上用的驗收執行器，在 repo 的 `tests` 資料夾。

---

## 7 · 報告

**落在哪裡、叫什麼名字**：第 3.1 節。**裡面有什麼**：使用手冊第 5 節維護完整清單：身分與版本、每張已連線網卡的位址與硬體位址、Wi-Fi 網路與基地台、路由、閘道的硬體位址、Proxy 設定、你設定的標準與目標、每項結果與時間，以及設定檔和報告資料夾的路徑（可能含使用者的個人資料夾）。JSON 還多了工具遇到的錯誤的技術細節，其中會寫出程式所在的資料夾。

**發出去之前先定處理規定**：報告可以送到哪裡、留多久、誰能看，並在把工具交給使用者的同一則訊息裡說明；使用手冊只說請依公司對這類資訊的規定處理。報告是一般檔案：保留期限就是你對報告資料夾（或共用資料夾，第 3.1 節）套用的規定。

**給你的工具用。** JSON 報告是 schema 2：`SchemaVersion`、`ToolVersion`、`RunOptions`（第 4 節）、`Fingerprint`（`Key`、`Title`、`Lines`，即「要告訴 IT 的話」）、`Overall`（`Code`、`Text`、`Description`）、`Counts`、`System`、`StartedAt`、`FinishedAt`，以及 `Results`：每一列一個物件，含 `Time`、`Category`、`Check`、`Status`（`PASS`、`WARN`、`FAIL`、`INFO`、`ERROR`）、`Message`、`Details`、`Diagnostics`、`Tag` 與 `Scope`（`Main` 或 `IT`）。`Tag` 是與語言無關的檢查名稱（`ping-gateway`、`dns`、`connectivity-group`、`tcp-retransmissions`、`expected-standard`……）；技術文件第 4.10 節有清單，`Scope` 則告訴你整體結果忽略了哪些列。

**讀報告。** 使用手冊解釋整體結果、「要告訴 IT 的話」的標題與各種標籤；技術文件解釋每一條規則。repo 的 `sop` 資料夾有支援工程師的現場手冊和把報告整理成交接文件的範本。

---

## 8 · 安全政策：什麼會擋住它，使用者會看到什麼

啟動器只對自己的程序設定執行原則（`-ExecutionPolicy Bypass`），在沒有政策的電腦上這樣就夠了。有政策時會發生的事如下：除非另有標註，每一列都在本專案的虛擬機上量測過，並記錄在 `VALIDATION.md`。

| 機制 | 發生什麼 | IT 會拿到什麼 |
|---|---|---|
| 下載的 ZIP 帶有**網路標記** | 啟動器出現「開啟檔案 - 安全性警告」；按「執行」後工具照常運作 | 沒有東西，除非使用者取消 |
| **群組原則設定的執行原則**（`MachinePolicy`／`UserPolicy`，例如 *AllSigned*） | 蓋過啟動器的程序範圍 Bypass：腳本不會啟動。PowerShell 印出自己的訊息（英文 Windows 上是「…NetworkHealthCheck.ps1 is not digitally signed. You cannot run this script on the current system…」，中文 Windows 則是它的中文版本），啟動器回報非零的結束代碼並暫停，`LauncherError.txt` 建議閱讀上方的訊息並請 IT 允許程式 | `LauncherError.txt` 和主控台的文字。沒有環境報告：腳本根本沒跑 |
| **PowerShell 被限制在受限語言模式**：強制執行的應用程式控制政策（WDAC）對不允許的腳本做的事，以及 `__PSLockdownPolicy` 對每支腳本做的事 | 腳本最前面幾行偵測到不是 *FullLanguage* 的模式，在任何檢測之前停下：結束代碼 3、原因印在主控台，並在程式旁邊（該資料夾不可寫或是壓縮檔檢視時，改在 `%TEMP%`）寫出 `NetworkHealthCheck_ENVIRONMENT_<時間>.txt`，載明原因、語言模式、工具版本、電腦名稱、使用者、腳本資料夾、PowerShell 版本、地區設定與作業系統，以及「IT 可以怎麼做」下的兩行：在應用程式控制政策（WDAC / AppLocker）中放行 `NetworkHealthCheck.ps1`，或改在沒有這項限制的電腦上執行檢測。啟動器會解釋結束代碼 3 並指向這個檔案。在兩台機器上以 `__PSLockdownPolicy` 量測過；沒有量測過強制執行 WDAC 的機器 | 環境報告和 `LauncherError.txt` |
| **AppLocker 指令碼規則** | 沒有量測到它生效：唯一一台回報政策在強制執行、且判定拒絕這支腳本的機器，還是不受限制地跑完了它（`VALIDATION.md` 的待辦 #31）。強制執行的規則會拒絕腳本，還是讓它在上面那種受限模式裡跑，都還沒有觀察到 | 看結果產生上面兩個檔案中的哪一個 |
| **EDR 或防毒**擋住 `powershell.exe` 或腳本 | 沒有量測：驗收執行沒有包含裝了這類產品的機器。啟動器回報它拿到的結束代碼並寫出 `LauncherError.txt` | `LauncherError.txt` 和該產品自己的記錄 |

**要向使用者要什麼**，使用手冊第 6 節逐列寫了；環境報告和 `LauncherError.txt` 就是為這個交接而寫的。`LauncherError.txt` 在啟動器旁邊，那個資料夾無法寫入時改寫在 `%TEMP%` 的 `NetworkHealthCheck_LauncherError.txt`，欄位較少。

**放行工具。** 兩支腳本沒有簽章，所以依發行者放行的政策沒有東西可比對；IT 現在手上有的是雜湊值：`SHA256SUMS.txt` 給出每支 `NetworkHealthCheck.ps1` 的摘要，WDAC 或 AppLocker 規則可以放行這個雜湊。新版本就是新雜湊。哪些 Windows 組建與版本會強制執行 AppLocker、什麼已經觀察到、什麼還沒有，變得比這個套件快：repo 保有一頁專門記錄，本手冊所屬版本的那一頁在 <https://github.com/kevintechin/network-support-toolkit/blob/v1.2.4/docs/application-control.md>（英文），最新版本在 `main` 分支。

**簽章。** 用你自己的憑證授權單位做 Authenticode 簽章，要在簽署憑證也受這台電腦信任時（憑證鏈受信任，且憑證在「受信任的發行者」存放區）才滿足 *AllSigned* 原則：發行者尚未被歸為信任時，PowerShell 會先詢問使用者才執行腳本（問題會出現在啟動器的視窗裡），無法詢問的工作階段就不執行。簽章也讓應用程式控制規則能依發行者放行。簽章會在腳本後面附加一段簽章區塊，所以簽過的檔案不再符合 `SHA256SUMS.txt`；請自己記下簽過檔案的摘要。

---

## 9 · 套件裡的檔案

| 檔案或資料夾 | 是什麼 |
|---|---|
| `Start-Traditional-Chinese.cmd`、`Start-English.cmd` | 最上層啟動器：各語言的使用者入口 |
| `README_BILINGUAL.md` | 套件的首頁 |
| `SHA256SUMS.txt`、`tools\validate_release.py` | 清單檔與驗證程式（第 6 節） |
| `VALIDATION.md`、`validation-matrix.html` | 驗證記錄，以及較早版本的情境矩陣 |
| `docs\` | 技術文件，中英文各一份 |
| `zh-TW\`、`en-US\` | 每種語言一個完整套件： |
| `…\Start-NetworkCheck.cmd`、`-IT.cmd`、`-Console.cmd` | 三個啟動器（第 1 節） |
| `…\NetworkHealthCheck.ps1` | 程式 |
| `…\NetworkHealthCheck.config.json` | 設定檔（第 3 節），你唯一要編輯的檔案 |
| `…\NetworkHealthCheck_User_Manual_*.md`、`.html` | 使用手冊，給執行檢測的人 |
| `…\NetworkHealthCheck_IT_Deployment_Manual_*.md`、`.html` | 本手冊 |
| `…\NetworkHealthCheck_Technical_Guide_*.md` | 技術文件，中英文再各一份 |
| `…\Reports\` | 第一次執行時建立（第 3.1 節） |

---

## 10 · 相關文件

- **使用手冊**：`NetworkHealthCheck_User_Manual_zh-TW.html`（或 `.md`）：使用者看到什麼、整體結果與標籤、報告裡有什麼、跑不起來時怎麼辦。
- **技術文件**：`NetworkHealthCheck_Technical_Guide_zh-TW.md`：設計、每一條判定規則、驗證方式、已知限制、版本歷程。
- **驗證記錄**：`VALIDATION.md`：每一版的證據、在其他機器上的驗收執行、待辦清單。
- **Repo**：<https://github.com/kevintechin/network-support-toolkit>：發行版本、驗證鏈（`tests`）、支援工程師現場手冊與報告範本（`sop`），以及第 8 節提到的應用程式控制頁面。

---

*NetworkHealthCheck 1.2.4。本手冊描述的是出廠狀態的工具與本版本量測到的行為；這裡引用的規則都是程式碼的規則，技術文件有完整的陳述。*
