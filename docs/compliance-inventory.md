# App Store 合規修正：Step 0 盤點（未改任何程式）

基準 commit `22474d0`：iOS CI run 38646401174 綠燈。`xcodegen generate` → `xcodebuild build -scheme SmartSchedule`（主 App 連同兩個 extension 依賴一起編）→ `xcodebuild test`：Executed 597 tests, 0 failures。

## 1. Live Activity 點擊目標

見 [`liveactivity-tap-baseline.md`](liveactivity-tap-baseline.md)：`widgetURL` 2 個、`Link` 3 個、`Button(intent:)` 0 個。

## 2. Control Center（ControlWidget）現況

| 環節 | 檔案 | 內容 |
|---|---|---|
| 控制項 | `Widgets/SmartScheduleControl.swift` | `StaticControlConfiguration(kind: AppConstants.controlKind)` + `ControlWidgetButton(action: SummonScheduleIntent())`，標籤「Smart Schedule」/ `clock` |
| Intent | `Shared/Intents/SummonScheduleIntent.swift` | `SummonScheduleIntent: LiveActivityIntent`，`perform()` → `LiveActivityManager.shared.summon()`，再 `SyncRequests.request("summon")` |
| 啟動 | `Shared/LiveActivity/LiveActivityManager.swift` `summon()` | 已有 activity 就 `update`，沒有就 `Activity.request(attributes:content:pushType:)`（**無時間參數，任何時刻都會叫出動態島**） |
| 其他使用者 | `App/Intents/AddPlanIntent.swift` `SmartScheduleShortcuts` | Siri App Shortcut「Show my schedule in Smart Schedule」也用 `SummonScheduleIntent` |
| 殘留 | 同檔 `DismissScheduleIntent` | 定義了「Island close button」，但沒有畫面使用 |

結論：控制中心和 Siri 都能在沒有近期行程時叫出一個常駐動態島（標題「Nothing next — type a plan」），這就是要修的違規狀態。

## 3. NotificationContent extension 的網路呼叫

Extension 的 sources 含 `Shared/AI`、`Shared/Calendar`、`Shared/Auth`、`Shared/Orchestrator`（`project.yml`）。入口是 `NotificationChatModel`（自己的 `ScheduleAssistant()` 實例）與 `NotificationViewController.didReceive(_:completionHandler:)`。

| 服務 | 呼叫 | 檔案 | Session |
|---|---|---|---|
| Gemini | `POST {SSGeminiBaseURL}/models/{model}:generateContent`，header `x-goog-api-key`（有 key 時） | `Shared/AI/GeminiClient.swift` `generate` / `send`（429、5xx 重試 2 次） | 注入的 `session`，預設 `URLSession.shared`；request `timeoutInterval: 30` |
| Google Calendar | `https://www.googleapis.com/calendar/v3/…` insert / patch / delete / get / list / calendarList | `Shared/Calendar/GoogleCalendarClient.swift`，經 `GoogleTransport.data(for:)` | `URLSession.shared` |
| Google OAuth | `POST https://oauth2.googleapis.com/token`（refresh）、`/revoke` | `Shared/Auth/GoogleTokenProvider.swift` | `URLSession.shared` |
| 同步 | `SyncEngine.shared.freshEvent`（Calendar GET） | `NotificationChatModel.swift:289` | 同 Calendar |

## 4. 全專案 grep

| 字串 | 結果 |
|---|---|
| `GEMINI_API_KEY` | `Config/Base.xcconfig:8`（空值）、`Config/Secrets.example.xcconfig:9-10`、`project.yml:64,151`、`README.md:140` |
| `SSGeminiAPIKey` | `project.yml:64`（主 App）、`project.yml:151`（NotificationContent）、`Shared/AI/GeminiClient.swift:16` |
| `x-goog-api-key` | `Shared/AI/GeminiClient.swift:138`、`docs/GEMINI_FUNCTION_CALLING.md:44` |
| `Activity.request(` | 1 處：`Shared/LiveActivity/LiveActivityManager.swift:27`（`summon()`，無 `start:`） |
| `pending`（ActivityKit） | 0 處使用 `ActivityState.pending`；其他 `pending` 都是「先問我」草稿與同步佇列，與 ActivityKit 無關 |
| 動態島提前量 | `Shared/Models/AppPreferences.swift:103` `liveActivityLeadMinutes: Int? = 30`（nil = 關）；選項 `App/Views/Settings/NotificationSettingsView.swift:10` `[nil, 15, 30, 60, 120]`；測試 `Tests/Unit/AppPreferencesTests.swift:37,167` 已驗證預設 30 |
| 本地提醒提前量（不在本次範圍） | `ReminderPolicy` / `ReminderPlanner`：事件預設 1 天、1 小時、30 分鐘、開始時；這些 `UNUserNotification` 不改 |
| `aps-environment` | `project.yml:75` 寫死 `development`（`.entitlements` 由 XcodeGen 產生，git-ignored） |

## 5. 現有 App 啟動動態島的路徑

- `App/SmartScheduleApp.swift`：啟動 `.task` 與 `scenePhase == .active` 都呼叫 `LiveActivityManager.shared.summonIfDue()`：沒有 activity 時，若下一個有時間的行程在 `liveActivityLeadMinutes` 內開始或正在進行就 `summon()`。
- 寫入後（聊天、Siri、背景更新、同步 hook、帳號變更、Focus filter）呼叫 `refreshIfRunning()`（共 16 處）。
- `App/Sync/AppRefresh.swift`：BGAppRefresh（`com.smartschedule.refresh`）也呼叫 `refreshIfRunning()`。
- `LiveActivityManager.observePushTokens` 存在但 `AppConstants.liveActivityPushEnabled = false`，沒有人呼叫。

## 6. 需求與現況的差異（實作時照此處理）

1. 隱私清單的 UserDefaults 原因碼：本專案經 App Group 與 extension 共用 UserDefaults，Apple 的對應原因碼是 **`1C8F.1`**；`CA92.1` 只涵蓋 App 自己讀寫。兩個都宣告。
2. iOS 26 排程啟動的正式簽名是 `request(attributes:content:pushType:style:alertConfiguration:start:)`，`alertConfiguration` **必填**（系統在 activity 開始時提醒使用者），而且這個呼叫本身仍然只能在前景做；背景更新只能 `update` / `end`。
3. `Config/Base.xcconfig` 的 `#include? "Secrets.xcconfig"` 已存在，但放在**最下方**：xcconfig 後面的定義會蓋掉前面的，若改到最上方，Base 裡的空預設值（`DEVELOPMENT_TEAM =` 等）會把 Secrets 的值清空。保留在最下方（功能等同「缺檔不報錯」）。
4. `SummonScheduleIntent` 不只控制中心在用，Siri App Shortcut 也用；兩者一起改。
