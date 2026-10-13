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
| Artboard 4 | 點了動態島之後出現的 Quick Capture：當日時間軸加對話 | `App/Views/QuickCaptureView.swift`、`RootView.swift`（從島的位置放大出現的動畫） |
| Artboard 5 | 主畫面：年份、月份選擇、月曆格（multi-day bar、task、+N）、AI 對話區、事件詳情 | `App/Views/MainView.swift`、`MonthGridView.swift`、`ChatPanel.swift`、`EventDetailSheet.swift` |
| Artboard 5（6 個月健身計畫） | 長期目標拆成 phases 和 RRULE series | `Shared/AI/FunctionDeclarations.json`（`create_long_term_plan`）、`Shared/Calendar/CalendarEventMapper.swift` |

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
  Orchestrator/         ScheduleAssistant：輸入一句話 → Gemini → Calendar → 回覆
  Notifications/        Category 註冊、ReminderScheduler（64 個上限的滾動視窗）
  LiveActivity/         ActivityAttributes、4KB 預算的 state builder、manager
  Intents/              SummonScheduleIntent（LiveActivityIntent）
  DesignSystem/         Theme tokens
Tests/fixtures/         Gemini 函式呼叫範例（也就是 schema 的驗收案例）
scripts/                validate_schema.py、make_app_icon.py
project.yml             XcodeGen 設定（三個 target、App Group、Keychain group、entitlements）
```

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
| Gemini schema lint（OpenAPI subset）、5 個 fixture 的 JSON Schema 驗證、DST 和 RRULE 參考測試 | ✅ `python3 -I scripts/validate_schema.py` 全部通過 |
| Swift 編譯 | ⚠️ 這份程式碼是在 Linux 環境寫的，沒有 Xcode 也沒有 iOS SDK，**還沒編譯過**。第一次 `xcodegen generate` 加 build 時，預期要修一些小地方 |
| 只能在實機上確認的行為（控制中心啟動 Live Activity、通知內 inline TextField、160 pt 高度） | ⏳ 清單在 `docs/ARCHITECTURE.md` 第 7 節 |
| Gemini 模型 ID | ⚠️ 預設 `gemini-3.5-flash`；上線前到 Gemini deprecations 頁確認 |
