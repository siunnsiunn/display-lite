# display-lite / ddcprobe

Apple Silicon macOS 外接螢幕 DDC/CI 探測工具，目標環境為 M2、macOS 26、BenQ MA270U USB-C / DisplayPort Alt Mode。`DDCKit` 是共用同步核心；`ddcprobe` 是 CLI；`DisplayLite` 是 AppKit 原生選單列程式。無第三方相依，僅使用 AppKit、Foundation、IOKit 與系統函式庫，不需完整 Xcode。

## 編譯與使用

需要 Swift 6.0 以上與 macOS Command Line Tools（本機為 Swift 6.3.3）：

```sh
swift build
.build/debug/ddcprobe selftest
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

私有 API 透過 `dlsym` 載入，採 CF retained ownership；核心已在 M2／macOS 26／BenQ MA270U 實機驗證亮度、對比與音量讀寫，GUI 仍待實機驗證。macOS 升級可能改變 ABI、registry 結構或存取權限。內建螢幕、Intel、DisplayLink 不支援；不保證 dock／轉接器／MST 能運作。列的是 IOKit 端點，不是已確認對應的 CGDisplayID；名稱及 EDID 屬性只從端點及祖先取用，缺少時顯示 unknown，避免跨分支誤配其他螢幕。

Get VCP 預設採 [MonitorControl Arm64DDC](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift) 的 Apple Silicon checksum 慣例：Get 省略 source 0x51，Set 則包含。若 get／scan 無有效回覆，可加 `--standard-checksum` 比較標準封包；不會自動混用兩種結果。能力查詢採標準 checksum，分段格式亦參考 [ddcutil 封包實作](https://github.com/rockowitz/ddcutil/blob/master/src/base/ddc_packets.c)。這些差異與 MA270U 的 capabilities 分段行為仍需實機確認。

操作同一螢幕需序列化，暫停其他 DDC 控制程式；核心同步且不宣告 Sendable，GUI 應在背景序列佇列呼叫。不要把 `scan` 無回覆解讀成確定不支援；螢幕忙碌、休眠、checksum 模式及讀取不穩都可能造成失敗。

若受限 sandbox 無法寫入使用者快取，可將快取限定在 repo（不需安裝或改系統設定）：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift build --disable-sandbox --cache-path .build/swiftpm-cache
.build/debug/ddcprobe selftest
```

`--disable-sandbox` 僅停用 SwiftPM 自己的 manifest sandbox，以免與外層 sandbox 衝突，不會停用作業系統或執行環境的安全限制。

## 測試結果

本機 CLT 的 `swift test` 無法匯入 `XCTest` 或 `Testing`，因此依備案使用 `ddcprobe selftest`，不保留無法編譯的 test target。`Sources/ddcprobe/SelfTest.swift` 包含 9 組純函式檢查：滑桿範圍／換算、90ms 節流與放開強制送出、獨立已知封包向量、checksum／長度／VCP／狀態錯誤、零值與衝突採信、I2C 失敗排除、分段 offset／拼接／空段與 NUL 終止／溢位，以及完整 32-byte 分段。selftest 不枚舉或存取螢幕；檢查失敗會以非零狀態結束，release build 也不會移除檢查。

## DisplayLite 選單列程式

只需 Command Line Tools，不需 Xcode、XCTest 或第三方套件：

```sh
swift build
.build/debug/DisplayLite
```

程式不顯示在 Dock，點選選單列太陽圖示即可調整亮度（0x10）、對比（0x12）、音量（0x62），最下方「結束」可退出。三項數值使用螢幕回報的 max；尚無有效 max 時分別使用 100／100／50。讀取失敗保留上次成功值與範圍，數字顯示「—」。

僅在開啟選單時重新偵測並讀取三項數值（沿用核心重試與共識採信，約需 1.5 秒）；讀取期間停用滑桿，快速重開會共用尚未完成的讀取。所有 DDC 工作都在同一條背景序列佇列，閒置無輪詢、無常駐計時器。拖動中每 90ms 最多接受一次設定，放開必定送出最後值；鍵盤調整直接送出。GUI 每次設定只傳送一次，避免核心預設的重複傳送超出拖動節流頻率；CLI 的預設行為不變。設定後不立即回讀；下次開選單若距上次設定不足 200ms，背景佇列會先稍候再讀。成功設定僅代表 I2C 傳送成功，不保證螢幕已套用。

沒有可開啟的外接端點時顯示「沒有偵測到可控制的螢幕」並停用滑桿，下次開選單重新偵測。目前僅控制單一可用端點；多個端點時顯示提示並停用，避免誤寫。更換端點會清除前一台螢幕快取。

目前還沒有 `.app` 包裝、沒有開機自動啟動；色彩模式與全域鍵盤按鍵之後才做。請暫停 Display Pilot 等其他 DDC 程式以免互相干擾。選單滑桿拖曳／放開、拔插螢幕與螢幕忙碌時的行為仍需實機驗證。
