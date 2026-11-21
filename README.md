# display-lite / ddcprobe

Apple Silicon macOS 外接螢幕 DDC/CI 探測工具，目標環境為 M2、macOS 26、BenQ MA270U USB-C / DisplayPort Alt Mode。`DDCKit` 是共用同步核心；`ddcprobe` 是 CLI；`DisplayLite` 是 AppKit 原生選單列程式。無第三方相依，僅使用 AppKit、Foundation、IOKit、CoreGraphics、CoreAudio、ApplicationServices 與系統函式庫，不需完整 Xcode。

## 編譯與使用

需要 Swift 6.0 以上與 macOS Command Line Tools（本機為 Swift 6.3.3）：

```sh
swift build
.build/debug/ddcprobe selftest
.build/debug/ddcprobe env
.build/debug/ddcprobe list
.build/debug/ddcprobe get 10 --tries 5
.build/debug/ddcprobe set 10 50
.build/debug/ddcprobe caps
.build/debug/ddcprobe scan
```

VCP 碼一律十六進位（`10` 與 `0x10` 相同），set 值為十進位 UInt16。只有一個外接端點時自動選取；多個端點必須加 `--display <list 顯示的十進位 registry-id>`，不會猜測要寫哪個螢幕。ID 可能在重新連接／重開機後改變。`--help` 不存取硬體。

`get` 印出每次完整原始 buffer、I2C 狀態、解析值或拒收原因。預設做滿 5 次，每次送出後等 50ms，下一次嘗試前再等 50ms。`scan` 對 00–FF 各讀 3 次，僅發送 Get VCP Request（底層必須以 I2C write 發出查詢，**不發 Set VCP、不改設定**），約需一分鐘以上。衝突的有效回覆也會列出，與採信值區分。

## 核心介面與採信

- `DDCDisplay.list()`：外接 DCPAVServiceProxy 端點、名稱（若 registry 提供）、registry ID/path、可取得的 EDID UUID／廠商／序號與開啟狀態。
- `read(vcp:options:)`：回傳 `(current, max)`；`readReport(vcp:options:onAttempt:)`：包含每次原始結果、最後採信值與一致次數，失敗仍保留紀錄。回呼可即時輸出每次結果。
- `ReadOptions(tries:interval:checksumMode:)`：預設 5 次、0.05 秒、Apple Silicon 相容 checksum。全部嘗試完成後，採用有效樣本中嚴格過半的相同 current/max/type；唯一有效樣本標示 provisional，平手／無過半不採信。零值合法，不因為是 0 就丟棄；重複的錯值仍可能被採信，不能保證代表真實狀態。
- `write(vcp:value:repetitions:interval:)`：預設寫 2 次，間隔 50ms；I2C 成功不等於螢幕已套用。任一寫入失敗會回報，可能已有部分寫入成功。
- `capabilities(options:)`：0xF3 request / 0xE3 reply，16-bit big-endian offset，檢查 checksum、長度、回覆 offset；空段或 NUL 終止，短段不等於結束。每段預設最多試 5 次，上限 4096 段／65535 bytes，錯誤不回傳假裝完整的字串。

解析拒絕錯誤來源、長度、checksum、opcode、VCP code、monitor result code 與 type。IOAVService 不回報實收長度，因此檢查宣告長度並忽略固定 buffer 尾端 padding；無法辨認驅動補出的 bytes。對未知／非連續 VCP 不套用 `current <= max` 限制。

## 已知限制與參考

私有 API 透過 `dlsym` 載入，採 CF retained ownership；核心已在 M2／macOS 26／BenQ MA270U 實機驗證亮度、對比與音量讀寫，GUI 仍待實機驗證。macOS 升級可能改變 ABI、registry 結構或存取權限。DDC 核心不直接控制內建螢幕；Intel、DisplayLink 不支援；不保證 dock／轉接器／MST 能運作。列的是 IOKit 端點，不是已確認對應的 CGDisplayID；名稱及 EDID 屬性只從端點及祖先取用，缺少時顯示 unknown，避免跨分支誤配其他螢幕。

Get VCP 預設採 [MonitorControl Arm64DDC](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift) 的 Apple Silicon checksum 慣例：Get 省略 source 0x51，Set 則包含。若 get／scan 無有效回覆，可加 `--standard-checksum` 比較標準封包；不會自動混用兩種結果。能力查詢採標準 checksum，分段格式亦參考 [ddcutil 封包實作](https://github.com/rockowitz/ddcutil/blob/master/src/base/ddc_packets.c)。這些差異與 MA270U 的 capabilities 分段行為仍需實機確認。

操作同一螢幕需序列化，暫停其他 DDC 控制程式；核心同步且不宣告 Sendable，GUI 應在背景序列佇列呼叫。不要把 `scan` 無回覆解讀成確定不支援；螢幕忙碌、休眠、checksum 模式及讀取不穩都可能造成失敗。

若受限 sandbox 無法寫入使用者快取，可將快取限定在 repo（不需安裝或改系統設定）：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift build --disable-sandbox --cache-path .build/swiftpm-cache
.build/debug/ddcprobe selftest
```

`--disable-sandbox` 僅停用 SwiftPM 自己的 manifest sandbox，以免與外層 sandbox 衝突，不會停用作業系統或執行環境的安全限制。

## 測試結果

本機 CLT 的 `swift test` 無法匯入 `XCTest` 或 `Testing`，因此依備案使用 `ddcprobe selftest`，不保留無法編譯的 test target。`Sources/ddcprobe/SelfTest.swift` 包含 12 組純函式檢查：媒體鍵解碼／條件路由／靜音切換、步進／夾限／亮度同步換算／連發累積與放開最終值、色彩模式對照／選取與未知值、滑桿範圍／換算、90ms 節流與放開強制送出、獨立已知封包向量、checksum／長度／VCP／狀態錯誤、零值與衝突採信、I2C 失敗排除、分段 offset／拼接／空段與 NUL 終止／溢位，以及完整 32-byte 分段。selftest 不枚舉或存取螢幕；檢查失敗會以非零狀態結束，release build 也不會移除檢查。

## DisplayLite 選單列程式

只需 Command Line Tools，不需 Xcode、XCTest 或第三方套件：

```sh
swift build
.build/debug/DisplayLite
```

程式不顯示在 Dock，點選選單列太陽圖示即可調整亮度（0x10）、對比（0x12）、音量（0x62），最下方「結束」可退出。三項數值使用螢幕回報的 max；尚無有效 max 時分別使用 100／100／50。讀取失敗保留上次成功值與範圍，數字顯示「—」。

三個滑桿下方的「色彩模式」子選單使用 VCP `0xDC`，依序提供 M-book（15／0x0F）、sRGB（10／0x0A）、Display P3（34／0x22）、使用者（18／0x12）、遊戲（40／0x28）、劇院（50／0x32）。這是 BenQ MA270U 實測可接受的模式；能力字串中的 0x23、0x27 不列入。可修改 `Sources/DDCKit/ColorModeLogic.swift` 的值→名稱陣列調整選項，純函式決定勾選位置並由 selftest 驗證。

開啟主選單時讀取模式並勾選；未知值或讀取失敗時全部不勾選。點選後先樂觀移動勾選，再送一次 Set；若 I2C 傳送失敗則清除勾選。切換後螢幕可能拒絕立即讀取，因此不回讀驗證，也不重讀可能受影響的亮度／對比；下次開啟主選單才以實際讀值更新全部項目。色彩模式 GUI 切換仍待實機驗證。

啟動、螢幕配置變更及開啟主選單時重新偵測並讀取三項數值與色彩模式（沿用核心重試與共識採信，約需 2 秒）；讀取期間停用滑桿與模式選項，快速重開會共用尚未完成的讀取。所有 DDC 工作都在同一條背景序列佇列，閒置無輪詢、無常駐計時器。拖動中每 90ms 最多接受一次設定，放開必定送出最後值；鍵盤調整直接送出。GUI 每次設定只傳送一次，避免核心預設的重複傳送超出拖動節流頻率；CLI 的預設行為不變。設定後不立即回讀；下次開選單若距上次設定不足 200ms，背景佇列會先稍候再讀。成功設定僅代表 I2C 傳送成功，不保證螢幕已套用。

沒有可開啟的外接端點時顯示「沒有偵測到可控制的螢幕」並停用滑桿與模式選項，下次開選單重新偵測。目前僅控制單一可用端點；多個端點時顯示提示並停用，避免誤寫。更換端點會清除前一台螢幕快取。

目前還沒有 `.app` 包裝、沒有開機自動啟動；全域媒體鍵與亮度同步已加入，仍待本機實測。請暫停 Display Pilot 等其他 DDC 程式以免互相干擾。選單滑桿拖曳／放開、拔插螢幕與螢幕忙碌時的行為仍需實機驗證。

## 系統媒體鍵與亮度同步

全程事件驅動：沒有輪詢、常駐或週期性計時器。DDC 讀取、寫入（包含靜音、按鍵及同步）全部經過同一條序列佇列；CGEventTap 回呼不做 DDC 收發。唯一的延遲排程是事件觸發的一次性工作：亮度同步節流尾端送出、亮度鍵退回讀取（120ms），及螢幕配置事件合併（250ms）。事件停止後不會自行再排程。

### 權限與按鍵

啟動只用 `AXIsProcessTrusted` 檢查輔助使用權限，**不自動跳詢問**。沒有權限時不建立 tap；點選「啟用鍵盤按鍵控制（需要輔助使用權限）…」才呼叫 `AXIsProcessTrustedWithOptions`。在「系統設定 → 隱私權與安全性 → 輔助使用」授權後，再打開 DisplayLite 選單即可重新檢查並建立監聽。若權限已開啟但 tap 建立失敗，選單提供重新啟用。未包裝／未固定簽章的 CLI 執行檔，其權限歸屬及重新編譯後是否需再次授權，須由實機確認。

監聽 `NX_SYSDEFINED`、subtype 8 的音量加減、靜音與亮度加減，包含按下、按住連發及放開。tap 被 timeout 或 user input 停用時重新啟用。一般 F1/F2 功能鍵事件不在監聽範圍；鍵盤需送出系統亮度／媒體鍵事件。

- 音量／靜音：只有單一可用 DDC 螢幕，且 CoreAudio 預設輸出符合螢幕條件，才轉為 DDC 並吞掉事件。條件依需求採「DisplayPort／HDMI 傳輸，或沒有可設定的輸出音量控制」；檢查主音量及各輸出聲道。查詢失敗視為未知，不以未知推論沒有音量控制。預設裝置與其屬性變更透過 CoreAudio listener 更新快取，每次按鍵不查裝置。
- MacBook 喇叭、具有可設定音量的耳機等輸出原樣放行。上述判斷是啟發式，沒有 CoreAudio 裝置到 DDC registry ID 的精確配對；無軟體音量控制的其他音訊介面也可能符合條件，多外接螢幕仍不支援。
- 沒有內建螢幕在線上時，亮度加減控制外接螢幕；有內建螢幕時原樣放行，由亮度同步跟隨。透過 `CGGetOnlineDisplayList` 與 `CGDisplayIsBuiltin` 判斷；枚舉失敗不當作闔蓋。
- 一格是 `round(max / 16)`，限制在 `0...max`。BenQ MA270U 已實測亮度 `0x10` 為 0–100（每格 6），音量 `0x62` 為 0–50（每格 3）。連發累積目標值，沿用 90ms 節流，放開強制送出最後值。
- 靜音用 `0x8D`，首次按下讀取目前狀態，之後切換快取；連發不重複切換。能力字串提供 01／02，目前實測讀到 2；**1＝靜音、2＝未靜音是依 MCCS 慣例的推測，尚未實測確認**。讀取失敗或未知值不猜測切換方向。
- **不提供音量／亮度浮動提示（HUD）**；放行給系統的按鍵仍可能顯示 macOS 自己的 HUD。

### 亮度跟隨 MacBook

選單「亮度跟隨 MacBook」預設開啟，以 `UserDefaults` 的 `followMacBookBrightness` 記住選擇。內建亮度 `b`（0–1）對應外接 `0x10 = round(b × max)`；滑桿仍可手動拖曳，下次內建亮度變化會再覆蓋。相同 VCP 值不重送；通知密集時節流並以一次性尾端工作保留最新值，關閉同步、手動調亮度或螢幕配置變更會取消待送出的同步值。

從 `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices` 使用 `dlopen`／`dlsym` 找以下符號，不直接連結私有框架：

- `DisplayServicesGetBrightness`
- `DisplayServicesRegisterForBrightnessChangeNotifications`
- `DisplayServicesUnregisterForBrightnessChangeNotifications`

通知 ABI 參考 [Lunar 的 bridging header](https://github.com/alin23/Lunar/blob/master/Lunar/DDC/Lunar-Bridging-Header.h)：observer 是 32 位元 display token，callback 是 `CFNotificationCallback`。回呼只排入主執行緒再讀內建亮度，不把 observer 當物件指標。拔插、開蓋／闔蓋以 `CGDisplayRegisterReconfigurationCallback` 觸發重新偵測與通知註冊，退出時解除監聽。

符號不存在或通知註冊失敗時，不輪詢：後續只在 tap 看見亮度鍵後延遲 120ms 讀取一次，連發會合併；此退回模式無法跟隨控制中心或環境光引起的變化，且需要輔助使用權限讓 tap 運作。啟動、配置變更及手動開啟跟隨時會嘗試讀取初始值。有內建螢幕但讀不到亮度時不寫同步值，選單顯示「無法讀取內建螢幕亮度」。缺少私有符號不造成連結失敗或強制解包崩潰，但未公開 ABI 若隨 macOS 改變，仍有相容性風險；通知是否實際送達須在目標機確認，不用 watchdog 輪詢補救。

### 唯讀環境診斷與驗證

```sh
.build/debug/ddcprobe env
```

印出內建螢幕在線狀態、可讀取的內建亮度、上述三個 DisplayServices 符號是否存在、預設音訊輸出裝置名稱／傳輸類型／是否有可設定音量，以及 `AXIsProcessTrusted` 結果。只查詢，不建立 tap、不註冊亮度通知、不跳權限詢問、不讀寫 DDC、不修改系統設定。這是 `ddcprobe` 程序的權限結果，不保證與 DisplayLite 的權限歸屬相同。

既有 debug 版實測基準（使用者提供）：閒置 CPU **0.0%**、idle wakeups **0**、記憶體約 **13 MB**（`top` 的 MEM）。這些數字不是新增功能後重新量測的結果；新增監聽後的資源用量、授權、按住／放開、音訊切換、開闔蓋、通知及退回路徑，由使用者實機測試。
