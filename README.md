# Smart Schedule

一款 iOS 智慧行程 App。核心理念是**常駐背景、不打擾、輸入極快**：
從控制中心一鍵把行程叫到動態島；長按提醒就能原地修改；一句「我想半年內變壯」就由 Gemini 拆成週期計畫，寫進 Google Calendar。

> 平台：iOS 18 以上（Control Center 控制項需要 iOS 18）· SwiftUI · ActivityKit · WidgetKit · App Intents · UserNotificationsUI · Gemini function calling · Google Calendar API v3

---

## 設計稿和程式碼的對應

| 設計稿 | 功能 | 主要檔案 |
|---|---|---|
| Artboard 1 | 鎖定畫面提醒 → 長按展開 → 原地對話（MY TEXT／THE RESPOND／輸入列） | `NotificationContent/NotificationViewController.swift`、`NotificationChatView.swift`、`Shared/Notifications/*` |
| Artboard 2 | 動態島 compact 狀態「⏰ Online meeting in 21 MIN」 | `Widgets/ScheduleLiveActivity.swift`（`compactLeading`／`compactTrailing`） |
| Artboard 3 | 控制中心時鐘按鈕 → 動態島就緒；展開後顯示一週微型日曆和輸入列 | `Widgets/SmartScheduleControl.swift`、`Shared/Intents/SummonScheduleIntent.swift`、`Widgets/ScheduleLiveActivity.swift`（`ExpandedIslandView`） |
| Artboard 4（04 Quick Capture） | 點了動態島之後出現的 Quick Capture：DAY／WEEK／MONTH 切換（記住上次的選擇）、24 小時制時間軸、可左右翻頁的週卡、可上下捲動的連續月曆、對話面板、建議膠囊 | `App/Views/QuickCaptureView.swift`、`CaptureModePicker.swift`、`WeekAgendaCard.swift`、`MonthScrollCard.swift`、`CaptureCalendarParts.swift`、`Shared/Core/CalendarPaging.swift`（日期運算）、`RootView.swift`（從島的位置放大出現的動畫） |
| Artboard 5 | 主畫面：年份、月份選擇、月曆格（multi-day bar、task、+N）、AI 對話區、事件詳情 | `App/Views/MainView.swift`、`MonthGridView.swift`、`ChatPanel.swift`、`EventDetailSheet.swift` |
| Artboard 5（6 個月健身計畫） | 長期目標拆成 phases 和 RRULE series | `Shared/AI/FunctionDeclarations.json`（`create_long_term_plan`）、`Shared/Calendar/CalendarEventMapper.swift` |

### 長期計畫：先審閱，按 Add 才加入

AI 做好一個長期計畫後，不會馬上寫進 Google Calendar，而是先存成草稿（`PlanDraft`，放在 App Group，App、通知擴充和 Siri 共用），在對話裡顯示計畫卡片（`App/Views/PlanPreviewCard.swift`），月曆上用虛線、半透明的「幽靈」行程預覽每一堂課。卡片有兩個按鈕：**Add** 才會真的寫入；**Keep editing** 會問「What would you like to change?」，使用者說要改什麼之後，AI 產生一份完整的新版本（revision 2、3…）再給使用者看一次，舊卡片標示為已被取代，直到按下 Add 為止。直接打字「好」「加入」「looks good」等同按 Add，打「不要了」「cancel the plan」則捨棄草稿。單一行程（`create_events`）仍然立即加入。用 Siri 建立的計畫會停在草稿，打開 App 就能看到卡片。

### 對話紀錄與回覆排版

- **完整對話紀錄**：主畫面的對話區、Quick Capture 的對話面板（和主畫面共用同一份 `ChatViewModel.messages`）、長按通知的展開卡片，都保留整段對話，可以往上滑看之前的內容。使用者停在最底部時，新訊息會自動捲到底；往上滑在讀舊訊息時位置不變，底部出現「最新訊息 ↓」膠囊，點了才跳到最新（`App/Views/ConversationScrollView.swift`，通知擴充裡是 `NotificationMessageViews.swift` 的精簡版）。計畫卡片留在對話中原本的位置，舊版本顯示「已由第 N 版取代」並收合，點一下可以展開比較。建議膠囊只跟著最新一則回覆。
- **回覆不再是一整段文字**：`App/Views/AssistantMessageView.swift` 依照回覆帶的資料分別呈現。文字依空行分段，「• 」「- 」「1. 」開頭的行顯示成縮排清單，支援 **粗體**，15 pt、行距 4。新增的行程顯示成「已加入 Google 日曆」列（標題、日期時間、地點或 Meet）；查詢行程顯示成對齊的時間表（「12:30  午餐」）；長期計畫卡片是一張表：每個階段一個小標題，每堂課一列（星期幾 · 時間 · 時長 · 名稱），再加上提醒、檢查點，假設預設收合。模型的 `summary_for_user` 只寫一兩句目標和每週負荷，日期時間只出現在表格裡，不會重複。
- `Reply.text` 仍然是完整的文字版本，給 Siri、通知內文和 Live Activity 使用；對話裡只顯示表格和列沒有涵蓋的部分（例如修改了什麼、時間重疊的提醒）。
- **語言**：介面字串在 `Shared/Localization/Localizable.xcstrings`（英文為 key，附繁體中文），裝置語言是中文時顯示中文。日期用語系格式（「10月14日（週三）」），時間一律 24 小時制。Previews 裡有 zh-Hant 版本（`.environment(\.locale, …)`），日期、星期和 `Text` 標籤會跟著切換；要看 `String(localized:)` 產生的字串也變中文，請在 Scheme 的 App Language 選繁體中文再執行。

## 文件

| 文件 | 內容 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 平台限制對照表、process 和資料邊界、各介面的框架選型、延遲預算、安全、打破框架的建議 |
| [`docs/GEMINI_FUNCTION_CALLING.md`](docs/GEMINI_FUNCTION_CALLING.md) | 6 個函式的 schema 設計理由、request 和 response 範例、Gemini 3 thought signatures |
| [`docs/GOOGLE_CALENDAR_SYNC.md`](docs/GOOGLE_CALENDAR_SYNC.md) | OAuth PKCE、欄位對應、時區和 DST、RRULE、提醒（24h／1h／30m）、idempotent 寫入、雙向同步 |
| [`docs/NOTIFICATIONS.md`](docs/NOTIFICATIONS.md) | Hold-to-spawn 流程、Info.plist、兩條輸入路徑、64 個通知上限 |

## 專案結構

```
App/                    主 App target（SwiftUI、Quick Capture、Google 登入、語音、Siri intents、BG refresh）
Widgets/                Widget extension：Live Activity（動態島和鎖定畫面）、Control Center 控制項
NotificationContent/    Notification Content Extension：長按通知後原地對話
Shared/
  Core/                 常數、deep link、WallClock（牆上時間和 IANA 時區）
  Models/               ScheduleEvent、Gemini 函式參數的 Decodable
  AI/                   FunctionDeclarations.json、GeminiClient（REST）、AssistantPrompt
  Calendar/             Google 的資料模型、mapper、RRULE、idempotent ID、client、sync、提醒策略
  Auth/                 GoogleTokenProvider（任何 process 都能 refresh）
  Orchestrator/         ScheduleAssistant：輸入一句話 → Gemini → Calendar → 回覆；DemoAssistant（離線 Demo）
  Notifications/        Category 註冊、ReminderScheduler（64 個上限的滾動視窗）
  LiveActivity/         ActivityAttributes、4KB 預算的 state builder、manager
  Intents/              SummonScheduleIntent（LiveActivityIntent）
  DesignSystem/         Theme tokens
App/Previews/           Xcode Canvas 預覽（Widgets/、NotificationContent/ 也各有一個 Previews 檔）
Tests/Unit/             XCTest 單元測試（hostless，不需要啟動 App）
Tests/fixtures/         Gemini 函式呼叫範例（也就是 schema 的驗收案例）
Tests/Simulator/        reminder.apns：拖進模擬器就能測試長按通知
.github/workflows/      iOS CI：schema 驗證、macOS 編譯、單元測試
scripts/                validate_schema.py、make_app_icon.py
project.yml             XcodeGen 設定（三個 App target 加一個測試 target、App Group、Keychain group、entitlements）
```

## 預覽與測試

[![iOS CI](https://github.com/kennymaukwen-GIT/Smart-Schedule/actions/workflows/ios.yml/badge.svg?branch=claude/smart-schedule-ios-arch-e7z6e1)](https://github.com/kennymaukwen-GIT/Smart-Schedule/actions/workflows/ios.yml)

| 方式 | 需要什麼 | 能測什麼 |
|---|---|---|
| **網頁互動原型**（claude.ai Artifact） | 瀏覽器，手機也可以 | 5 個設計稿的流程、真實的自然語言解析（原型裡用 Claude 代替 Gemini，function schema 相同）、iOS App 會送出的 Google Calendar request |
| **Xcode Previews** | Mac + Xcode 16 以上 | 每個畫面，包括動態島 expanded／compact／minimal 和鎖定畫面，不用執行 App |
| **Simulator + Demo 模式** | Mac + Xcode | 完整 App：控制中心按鈕、Live Activity、長按通知回覆、主畫面、Quick Capture。不需要 Google 帳號或 Gemini key |
| **單元測試** | Xcode 按 ⌘U，或 GitHub Actions 自動跑 | 119 個測試：時區和 DST、RRULE、event ID、mapper、Gemini 回應解析、4 KB 預算 |
| **真機 + 真 API** | Apple ID（部分功能需付費開發者帳號）、Google OAuth client、Gemini key | 實際寫入 Google Calendar、Action Button、真正的鎖定畫面互動 |

### Simulator 步驟
```bash
brew install xcodegen
git clone https://github.com/kennymaukwen-GIT/Smart-Schedule.git && cd Smart-Schedule
xcodegen generate && open SmartSchedule.xcodeproj
```
1. 裝置選 **iPhone 17 Pro**（要有動態島的機型）。第一次會下載 iOS 模擬器，約 8.5 GB。
2. **Demo 模式**：Product → Scheme → Edit Scheme → Run → Arguments，加入 `-SSDemoMode YES`。不加的話，也可以在 App 內點「Try demo (no account)」。
3. 按 ⌘R。主畫面會載入示範行程；回到主畫面（⇧⌘H）可以看到動態島，按住動態島會展開。
4. **控制中心**：在模擬器右上角往下拖 → ＋ → 加入「Smart Schedule」。
5. **長按通知**：按 ⌘L 鎖定模擬器，把 `Tests/Simulator/reminder.apns` 拖進模擬器視窗，然後按住通知，輸入 `push this 30 minutes later`。
6. **Previews**：打開 `Widgets/ScheduleLiveActivityPreviews.swift`，按 ⌥⌘↩ 開啟 Canvas。

> 注意：`-SSDemoMode YES` 設著的時候，App 內的「Exit demo」不會生效。要離開 Demo 模式，請先把這個參數取消勾選。

## 開始開發

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # 填入 Team、Google iOS client ID、開發用的 Gemini key
xcodegen generate
open SmartSchedule.xcodeproj
```
1. 在 Apple Developer 後台建立 App Group `group.com.smartschedule.shared`，三個 target 都勾選。如果要改 bundle ID 前綴，記得同步改 `AppConstants.appGroupID`。
2. Google Cloud：啟用 Calendar API，OAuth consent screen 加入 `calendar.events`，建立 **iOS** 類型的 OAuth client。
3. Gemini：開發階段可以直接用 API key；**正式版**要把 `GEMINI_BASE_URL` 指向你的 proxy，並把 `GEMINI_API_KEY` 留空。
4. 實機執行，到控制中心加入「Smart Schedule」控制項。

## 驗證狀態

| 項目 | 狀態 |
|---|---|
| Gemini schema lint（OpenAPI subset）、5 個 fixture 的 JSON Schema 驗證、DST 和 RRULE 參考測試 | ✅ `python3 -I scripts/validate_schema.py`，CI 每次 push 都會跑 |
| Swift 編譯（App、Widgets、Notification extension） | ✅ GitHub Actions 的 macOS runner：xcodegen 加 xcodebuild 編譯通過 |
| 單元測試 | ✅ 119 個測試，0 個失敗（hostless `SmartScheduleCoreTests`） |
| 只能在實機上確認的行為（控制中心啟動 Live Activity、通知內 inline TextField、160 pt 高度） | ⏳ 清單在 `docs/ARCHITECTURE.md` 第 7 節 |
| Gemini 模型 ID | ⚠️ 預設 `gemini-3.5-flash`；上線前到 Gemini deprecations 頁確認 |
