# Smart Schedules

> App 名稱是 **Smart Schedules**（「Smart Schedule」在 App Store 已經有人用）：iPhone 主畫面、App Store、網站和 Google 同意畫面都用這個名稱。程式碼裡的 target、scheme、型別、資料夾和 Xcode 專案仍叫 `SmartSchedule`；bundle ID 是 `com.smartschedules.app`；App Group（`group.com.smartschedule.shared`）、URL scheme（`smartschedule://`）、商品 ID（`com.smartschedule.pro.*`）和 Worker（`smart-schedule-worker`）都不變。

一款 iOS 智慧行程 App。核心理念是**常駐背景、不打擾、輸入極快**：
控制中心一鍵打開快速輸入，行程開始前自動出現在動態島；長按提醒就能原地修改；一句「我想半年內變壯」就由 Gemini 拆成週期計畫，寫進 Google Calendar。

> 平台：iOS 18 以上（Control Center 控制項需要 iOS 18）· SwiftUI · ActivityKit · WidgetKit · App Intents · UserNotificationsUI · Gemini function calling · Google Calendar API v3

---

## 設計稿和程式碼的對應

| 設計稿 | 功能 | 主要檔案 |
|---|---|---|
| Artboard 1 | 鎖定畫面提醒 → 長按展開 → 原地對話（MY TEXT／THE RESPOND／輸入列） | `NotificationContent/NotificationViewController.swift`、`NotificationChatView.swift`、`Shared/Notifications/*` |
| Artboard 2 | 動態島 compact 狀態「⏰ Online meeting in 21 MIN」 | `Widgets/ScheduleLiveActivity.swift`（`compactLeading`／`compactTrailing`） |
| Artboard 3 | 控制中心時鐘按鈕 → 打開快速輸入；動態島只在行程前出現，展開後顯示一週微型日曆和「編輯」按鈕（點了打開快速輸入） | `Widgets/SmartScheduleControl.swift`、`Shared/Intents/OpenQuickCaptureIntent.swift`、`Widgets/ScheduleLiveActivity.swift`（`ExpandedIslandView`） |
| Artboard 4（04 Quick Capture） | 點了動態島之後出現的 Quick Capture：DAY／WEEK／MONTH 切換（記住上次的選擇）、24 小時制時間軸、可左右翻頁的週卡、可上下捲動的連續月曆、對話面板、建議膠囊 | `App/Views/QuickCaptureView.swift`、`CaptureModePicker.swift`、`WeekAgendaCard.swift`、`MonthScrollCard.swift`、`CaptureCalendarParts.swift`、`Shared/Core/CalendarPaging.swift`（日期運算）、`RootView.swift`（從島的位置放大出現的動畫） |
| Artboard 5 | 主畫面：標頭（漢堡選單 ·「2027 October」· 頭像）、月份選擇、月曆格（multi-day bar、task、+N）、AI 對話區、行程頁（點行程打開，可直接修改，含備註） | `App/Views/MainView.swift`、`Navigation/AppHeader.swift`、`MonthGridView.swift`、`ChatPanel.swift`、`EventDetailSheet.swift`、`Events/EventPage.swift` |
| Artboard 5（側邊選單） | 漢堡選單打開的抽屜：General、「行程」區（進行中和接下來的行程、全部行程）、每個 Google 帳號一區、列出該帳號的行事曆；點色塊顯示或隱藏，點列進入行事曆設定 | `App/Views/Navigation/CalendarDrawer.swift`、`CalendarDetailsView.swift`、`App/Views/Events/*` |
| 頭像、General | 帳號（頭像；訂閱在 1.0 隱藏）；設定（General）：通知、行事曆與新行程、助理、AI 與隱私、資料、捷徑與 Siri、語言、示範模式、關於 | `App/Views/Account/AccountSheet.swift`、`App/Views/Settings/*`、`App/ViewModels/SettingsModel.swift` |
| Artboard 5（6 個月健身計畫） | 長期目標拆成 phases 和 RRULE series | `Shared/AI/FunctionDeclarations.json`（`create_long_term_plan`）、`Shared/Calendar/CalendarEventMapper.swift` |

### 長期計畫：先審閱，按 Add 才加入

AI 做好一個長期計畫後，不會馬上寫進 Google Calendar，而是先存成草稿（`PlanDraft`，放在 App Group，App、通知擴充和 Siri 共用），在對話裡顯示計畫卡片（`App/Views/PlanPreviewCard.swift`），月曆上用虛線、半透明的「幽靈」行程預覽每一堂課。卡片有兩個按鈕：**Add** 才會真的寫入；**Keep editing** 會問「What would you like to change?」，使用者說要改什麼之後，AI 產生一份完整的新版本（revision 2、3…）再給使用者看一次，舊卡片標示為已被取代，直到按下 Add 為止。直接打字「好」「加入」「looks good」等同按 Add，打「不要了」「cancel the plan」則捨棄草稿。單一行程（`create_events`）仍然立即加入。用 Siri 建立的計畫會停在草稿，打開 App 就能看到卡片。

### 對話紀錄與回覆排版

- **完整對話紀錄**：主畫面的對話區、Quick Capture 的對話面板（和主畫面共用同一份 `ChatViewModel.messages`）、長按通知的展開卡片，都保留整段對話，可以往上滑看之前的內容。使用者停在最底部時，新訊息會自動捲到底；往上滑在讀舊訊息時位置不變，底部出現「最新訊息 ↓」膠囊，點了才跳到最新（`App/Views/ConversationScrollView.swift`，通知擴充裡是 `NotificationMessageViews.swift` 的精簡版）。計畫卡片留在對話中原本的位置，舊版本顯示「已由第 N 版取代」並收合，點一下可以展開比較。建議膠囊只跟著最新一則回覆。
- **回覆不再是一整段文字**：`App/Views/AssistantMessageView.swift` 依照回覆帶的資料分別呈現。文字依空行分段，「• 」「- 」「1. 」開頭的行顯示成縮排清單，支援 **粗體**，15 pt、行距 4。新增的行程顯示成「已加入 Google 日曆」列（標題、日期時間、地點或 Meet）；查詢行程顯示成對齊的時間表（「12:30  午餐」）；長期計畫卡片是一張表：每個階段一個小標題，每堂課一列（星期幾 · 時間 · 時長 · 名稱），再加上提醒、檢查點，假設預設收合。模型的 `summary_for_user` 只寫一兩句目標和每週負荷，日期時間只出現在表格裡，不會重複。
- `Reply.text` 仍然是完整的文字版本，給 Siri、通知內文和 Live Activity 使用；對話裡只顯示表格和列沒有涵蓋的部分（例如修改了什麼、時間重疊的提醒）。
- **語言**：介面字串在 `Shared/Localization/Localizable.xcstrings`（英文為 key，附繁體中文），裝置語言是中文時顯示中文。日期用語系格式（「10月14日（週三）」），時間一律 24 小時制。Previews 裡有 zh-Hant 版本（`.environment(\.locale, …)`），日期、星期和 `Text` 標籤會跟著切換；要看 `String(localized:)` 產生的字串也變中文，請在 Scheme 的 App Language 選繁體中文再執行。

### 行程管理（抽屜 › 行程）

日曆裡看得到的每個行程，都能在抽屜裡管理（規格：[`docs/SETTINGS.md`](docs/SETTINGS.md) §2.2.1、§2.2.2）。

- **抽屜的「行程」區**（在「一般」和帳號之間）：列出正在進行和接下來的行程，最多 6 列，每列是行事曆顏色的圓點、標題和時間（「進行中 · 到 15:00」「今天 14:00」「明天 09:00」「10月16日（週三）09:00」），重複行程有 ↻，還沒同步到 Google 的有同步符號。點一下打開行程頁；下面「全部行程（N）」打開完整清單；沒有行程時寫「接下來沒有行程」。
- **全部行程**：分成「進行中」「今天」「明天」「這週」「之後」，重複的行程（例如每週六的瑜伽）在「重複行程」裡只佔一列，寫出規則和下一次（「每週六 09:00」「下一次：10月18日（週六）」）。可以搜尋標題、地點和備註；向左滑有「刪除」（重複行程會問只刪除這次或刪除全部）和「編輯」。打開時會確認接下來 12 個月的行程都已載入（`ScheduleViewModel.loadUpcomingEvents`），清單最下面有說明。
- **自動更新**：清單每分鐘重新整理，結束的行程自動消失；助理、長期計畫、Siri、通知回覆或其他裝置（同步）新增的行程會直接出現，不用手動重新整理。只列出在 Smart Schedules 顯示的行事曆（隱藏的行事曆不列，和日曆一樣），計畫草稿的幽靈行程不列，示範模式列出範例行程。
- **行程頁**（`App/Views/Events/EventPage.swift`，從月曆、Quick Capture、抽屜、全部行程和對話的「管理」按鈕打開，都是同一頁）：可以改標題、全天、開始和結束、地點、提醒和**備註**（多行，至少顯示 5 行，對應 Google 日曆的「說明」；Google 存的 HTML 會轉成純文字顯示，儲存時送純文字）。重複行程顯示規則，儲存時選「只改這次」或「全部」（「全部」只改時間，日期不變）。行事曆只顯示不能改。Meet、Google 日曆和備註裡的連結是可以點的列。「刪除行程」會先確認。只能檢視的行事曆會顯示「你不能修改這個日曆裡的行程。」；有沒儲存的修改時關閉會問「要捨棄變更嗎？」。儲存走和助理一樣的寫入路徑（`EventEditor` → `CalendarRouter`：If-Match、離線時進待送佇列並顯示待同步）。
- **備註建議**（`App/Views/Events/NoteSuggestionViews.swift`，規則在 `Shared/Orchestrator/NoteSuggester.swift`、`NoteSuggestionRules.swift`）：行程頁的備註下面有「建議」，依行程的標題、地點和備註判斷可能需要帶什麼、做什麼，例如出國或搭飛機：護照、簽證或入境文件、轉接頭、旅遊保險（國際線再加「提早 2–3 小時到機場」）；高鐵、火車：身分證、車票、行動電源；健身、跑步、重訓：水、毛巾、運動服和運動鞋；另外還有瑜伽、游泳、登山、面試和會議、看醫生、考試、生日和聚會、開車、演唱會和看展、訂位。繁中、簡中、英文的關鍵字都認得（「跑步機維修」這類不算運動），不用網路、馬上出現，最多 4 個。點一下膠囊（「+ 帶護照」）就在備註最後加一行「• 帶護照」，和其他修改一樣按「儲存」才寫入；備註裡已經有的不再建議；「×」把這個行程（重複行程是整個系列）的建議收起來，只記在這支 iPhone，「顯示建議」可以再打開。**建議永遠不會自動寫進備註。**規則和函式的細節在 [`docs/GEMINI_FUNCTION_CALLING.md`](docs/GEMINI_FUNCTION_CALLING.md) §12。
  - **✨ AI 建議**：請 Gemini 依標題、日期、地點、時長、現有備註和時區，再給 2–4 個貼近這個行程的項目（例如「東京旅遊」：護照、日圓現金、IC 交通卡、Visit Japan Web 入境 QR 碼），用獨立的 `suggest_event_notes` 函式呼叫，不碰行事曆。要先同意 AI 資料分享：還沒同意時會在行程頁上跳出同意說明，按「允許」後自動再試一次。示範模式和離線時改用內建規則，顯示「來自 Smart Schedules 的建議」。建議的語言跟著行程標題，標題看不出來就跟著 App 的語言。
  - **對話卡片**：助理剛加入的行程，卡片上最多 3 個建議；Gemini 建立行程時可以附上 `suggested_notes`（只存在這支 iPhone，不送到 Google，行程頁也看得到），沒有就用內建規則。點一下馬上寫進那個行程的備註（和行程頁同一條寫入路徑，離線時進待送佇列），膠囊變成「已加入：…」。助理自己不會寫備註，除非使用者要求（「加個備註：帶護照」）。規則表、AI request 和保存方式見 [`docs/GEMINI_FUNCTION_CALLING.md`](docs/GEMINI_FUNCTION_CALLING.md) 第 12 節。

### 設定、帳號與訂閱

規格在 [`docs/SETTINGS.md`](docs/SETTINGS.md)。分工一句話：**漢堡選單管「看什麼」**（帳號、行事曆、顯示與否），**頭像管「我是誰」**（Google 帳號；Smart Schedules Pro 在 1.0 隱藏），**General 管「App 怎麼運作」**。

- **多個 Google 帳號**：抽屜每個帳號一區，標題是 email，下面是該帳號的每個行事曆。點色塊一下就隱藏或顯示；點列進入行事曆設定（只在這台 iPhone 的顏色、這個行事曆要不要提醒、「用於新行程」）。最後一列「新增 Google 帳號」。
- **新增 Google 帳號**（`App/Views/Account/AddAccountView.swift`）：抽屜、頭像的帳號頁、歡迎畫面的「新增 Google 帳號」／「連接 Google 日曆」都會打開這一頁。輸入自己的 email（例如 example@gmail.com），格式不完整會直接提示；按「前往 Google 登入」後，這個 email 會當作 Google 登入頁的 `login_hint`（Google 直接選好或填好這個帳號），使用者還是在 Google 自己的頁面登入、同意授權——只靠 email 沒辦法連結帳號，Smart Schedules 也看不到密碼。Google 回來後，App 比對 ID token 裡的 email 和輸入的 email（Gmail 會忽略大小寫、點和 `+標籤`）：相同就存下帳號、抓行事曆清單，顯示「已連接 example@gmail.com」，抽屜馬上出現它的行事曆；不同的話**先不存**，問「你登入的是 X，不是 Y。」，可以選「加入 X」、「改用 Y 重新登入」或「取消」（撤銷剛拿到的授權）；已經連接過的帳號只會更新，不會重複。Gmail、學校或公司的 Google Workspace 帳號都可以；學校或公司不允許時、沒有勾選日曆權限時、沒有網路時，都會用一句話說明怎麼辦。也可以按「從 Google 帳號清單選擇」不輸入 email。示範模式中繼續會先結束示範模式（頁面上有說明）。
- **移除帳號**：頭像的帳號頁（每列的「⋯」選單或向左滑）和抽屜（帳號標題旁的「⋯」）都有「移除帳號」。確認視窗說明這個帳號的日曆和行程只會從這支 iPhone 的 Smart Schedules 移除，Google 日曆裡的資料不會被刪除；如果這個帳號還有變更沒送到 Google，會寫出「還有 N 項變更尚未同步到 Google，移除後會遺失。」並提供「先同步」。移除會撤銷 Google 授權、刪除 Keychain 裡的 token、清掉這個帳號的快取行程和待送出的變更、把它的行事曆從專注模式過濾條件拿掉；如果新行程原本存到這個帳號，會改回自動並顯示「新行程改存到「X」。」。移除最後一個帳號就回到歡迎畫面。
- **AI 資料分享同意**（App Store 5.1.2(i)）：第一次送出訊息前先跳出說明，列出會傳給 Google Gemini API 的內容（輸入或說出的話、今天起 14 天內最多 40 個行程的標題、時間、備註和 Google 行程 ID、「AI 建議」那一個行程的地點、行事曆名稱和助理設定、時區和語言），按「允許」才送出；按「暫時不要」助理就不會呼叫 Gemini，輸入列上方會說明怎麼開啟。**Google 帳號的 email 不會送給 Gemini**：行事曆以「Account 1」「Account 2」區分，行程文字和錯誤訊息裡的帳號 email 先換成佔位字（[`docs/GEMINI_FUNCTION_CALLING.md`](docs/GEMINI_FUNCTION_CALLING.md) §10.6）。說明改版時（目前第 5 版：1.0 不用 iOS 18 的 push-to-start，所以 iOS 18 也沒有伺服器那一段）每個人都會再被問一次。設定 › AI 與隱私可以查看和撤回。示範模式不需要同意。
- **用說的改設定**：「以後 8 點前不要提醒我」「健身提前 2 小時提醒」「以後用學校帳號」會變成設定，對話裡出現「設定已更新」卡片（舊值 → 新值，可以復原），也記在設定 › AI 與隱私 ›「助理記得的事」，每一條都能刪除（回到預設值）。
- **先問我**：設定 › 助理 › 加入行程選「先問我」時，單一行程會先停在「尚未加入行事曆」卡片，按「加入」才寫入，按「編輯」說要改什麼。
- **從習慣學習**：連續略過同一種預設提醒 5 次，對話裡會問要不要停掉；按「停止」才會改。
- **對話紀錄**會保留（最多 200 則，7 天／30 天／永久），可以清除、匯出（JSON）或「清除這台裝置上的所有資料」。
- **訂閱**：1.0 不賣訂閱，也沒有任何 App 內購買。`AppConstants.subscriptionsEnabled = false` 隱藏頭像頁的 Smart Schedules Pro 區塊（Debug 版的 StoreKit testing 也一起隱藏），頭像的 VoiceOver 標籤是「帳號」，清除資料的確認說明不提訂閱，啟動時也不呼叫 StoreKit。StoreKit 2 程式碼（`isPro`，沒有鎖任何功能）保留給之後的版本；`ReleaseConfigurationTests` 和 `validate_schema.py` 會擋下把它打開的改動。之後的價格和要鎖什麼見 `docs/SETTINGS.md` 第 16 節。

## 文件

| 文件 | 內容 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 平台限制對照表、process 和資料邊界、各介面的框架選型、延遲預算、安全、打破框架的建議 |
| [`docs/SETTINGS.md`](docs/SETTINGS.md) | 新介面和設定功能的規格：畫面、資料模型、儲存、多帳號同步、`update_preferences`、通知、AI 同意、訂閱、匯出與清除、上架前檢查清單 |
| [`docs/GEMINI_FUNCTION_CALLING.md`](docs/GEMINI_FUNCTION_CALLING.md) | 9 個函式的 schema 設計理由（包括備註建議的 `suggest_event_notes` 和 `create_events` 的 `suggested_notes`）、request 和 response 範例、Gemini 3 thought signatures |
| [`docs/GOOGLE_CALENDAR_SYNC.md`](docs/GOOGLE_CALENDAR_SYNC.md) | OAuth PKCE、欄位對應、時區和 DST、RRULE、提醒（24h／1h／30m）、idempotent 寫入、雙向同步 |
| [`docs/NOTIFICATIONS.md`](docs/NOTIFICATIONS.md) | Hold-to-spawn 流程、Info.plist、兩條輸入路徑、提醒來源（Smart Schedules／Google／兩者）、緊急程度、安靜時段、每日摘要、每日上限、64 個通知上限、略過提醒的學習 |
| [`docs/google-oauth-verification.md`](docs/google-oauth-verification.md) | Google OAuth 品牌驗證和敏感 scope 驗證：要填的欄位、scope 用途說明（英文）、AI 資料使用說明、示範影片分鏡、送審順序、常見退件原因、回覆審查信的範本 |

## 專案結構

```
App/                    主 App target（SwiftUI、Quick Capture、Google 登入、語音、Siri intents、BG refresh）
  Views/Navigation/     Artboard 5 標頭、行事曆抽屜、行事曆設定
  Views/Events/         抽屜的「行程」區、全部行程、行程頁（可編輯、備註、備註建議）
  Views/Account/        帳號（訂閱區塊在 1.0 隱藏）
  Views/Settings/       設定（General）的每一頁
  Views/Chat/           AI 同意說明、同意提示列、設定已更新／學到的建議／先問我卡片
  Auth/ Store/ Privacy/ 多帳號（AccountManager）、StoreKit 2（1.0 關閉）、匯出與清除
Widgets/                Widget extension：Live Activity（動態島和鎖定畫面）、Control Center 控制項
NotificationContent/    Notification Content Extension：長按通知後原地對話
Shared/
  Core/                 常數、deep link、WallClock（牆上時間和 IANA 時區，跟著設定的時區和每週起始日）
  Models/               ScheduleEvent、GoogleAccount、AppPreferences、偏好紀錄、Gemini 函式參數的 Decodable
  AI/                   FunctionDeclarations.json、GeminiClient（REST）、AssistantPrompt、NoteSuggestionPrompt（AI 備註建議）
  Calendar/             Google 的資料模型、mapper、RRULE、idempotent ID、client、sync、提醒策略
  Auth/                 GoogleTokenProvider（任何 process 都能 refresh）
  Orchestrator/         ScheduleAssistant：輸入一句話 → Gemini → Calendar → 回覆；DemoAssistant（離線 Demo）；NoteSuggester（備註建議規則）
  Storage/              SharedStore、AccountStore、PreferencesStore、ChatHistoryStore、AI 同意、收起的備註建議、跨 process 變更通知
  Notifications/        Category 註冊、ReminderScheduler（64 個上限的滾動視窗）、每日摘要、略過提醒的學習
  LiveActivity/         ActivityAttributes、4KB 預算的 state builder、manager
  Intents/              OpenQuickCaptureIntent（控制中心、Siri）、DismissScheduleIntent
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
| **單元測試** | Xcode 按 ⌘U，或 GitHub Actions 自動跑 | 時區和 DST、RRULE、event ID、mapper、Gemini 回應解析、4 KB 預算、偏好設定與紀錄、多帳號（新增帳號的 email 檢查與比對、移除帳號、送給 Gemini 的內容沒有任何帳號 email）、提醒排程、週一開始的月曆、備註建議的規則（出國、運動、排除「跑步機維修」這類誤判、已經寫在備註裡的不再建議）、1.0 不賣訂閱（`ReleaseConfigurationTests`） |
| **真機 + 真 API** | Apple ID（部分功能需付費開發者帳號）、Google OAuth client、已部署的 Worker 網址（`GEMINI_BASE_URL`，見 [`server/worker/README.md`](server/worker/README.md)；Gemini 金鑰只在 Worker 上） | 實際寫入 Google Calendar、Action Button、真正的鎖定畫面互動 |

### Simulator 步驟
```bash
brew install xcodegen
git clone https://github.com/kennymaukwen-GIT/Smart-Schedule.git && cd Smart-Schedule
xcodegen generate && open SmartSchedule.xcodeproj
```
1. 裝置選 **iPhone 17 Pro**（要有動態島的機型）。第一次會下載 iOS 模擬器，約 8.5 GB。
2. **Demo 模式**：Product → Scheme → Edit Scheme → Run → Arguments，加入 `-SSDemoMode YES`。不加的話，也可以在 App 內點「Try without signing in」（不登入先試用），或打開設定 › 示範模式。示範模式有兩個範例帳號，抽屜、行事曆顯示與否、用說的改設定都能離線試。
3. 按 ⌘R。主畫面會載入示範行程；回到主畫面（⇧⌘H）可以看到動態島，按住動態島會展開。
4. **控制中心**：在模擬器右上角往下拖 → ＋ → 加入「Smart Schedules」。
5. **長按通知**：按 ⌘L 鎖定模擬器，把 `Tests/Simulator/reminder.apns` 拖進模擬器視窗，然後按住通知，輸入 `push this 30 minutes later`。
6. **Previews**：打開 `Widgets/ScheduleLiveActivityPreviews.swift`，按 ⌥⌘↩ 開啟 Canvas。

> 注意：`-SSDemoMode YES` 設著的時候，App 內的「Exit demo」不會生效。要離開 Demo 模式，請先把這個參數取消勾選。

## 開始開發

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # 填入 Team、Google iOS client ID、伺服器網址（GEMINI_BASE_URL）、開發用的 SS_DEV_TOKEN
xcodegen generate
open SmartSchedule.xcodeproj
```
1. 在 Apple Developer 後台建立 App Group `group.com.smartschedule.shared`，三個 target 都勾選。如果要改 bundle ID 前綴，記得同步改 `AppConstants.appGroupID`。
2. Google Cloud：啟用 Calendar API，OAuth consent screen 加入 `calendar.events` 和 `calendar.calendarlist.readonly`（抽屜列出每個行事曆要用），建立 **iOS** 類型的 OAuth client。
3. Gemini：App 裡**沒有** API key。key 只放在 Smart Schedules 的伺服器（`server/worker/`，Cloudflare Worker 的 secret），App 以 App Attest 證明自己後經由伺服器呼叫 Gemini（通知擴充不能用 App Attest，改送 App 替它要的 session token）。`GEMINI_BASE_URL` 指向伺服器（`https://<worker 網域>/v1beta`）；模擬器沒有 App Attest，Debug 版改送 `SS_DEV_TOKEN`（Release 一律為空）。上線前替 Gemini API 的專案開啟 Cloud Billing（付費層級）：免費層級下 Google 可能用請求內容改善產品，App 裡不會也不能宣稱「不用於訓練」。
4. 訂閱（1.0 關閉）：要在模擬器測試，暫時把 `AppConstants.subscriptionsEnabled` 改成 true，Scheme 的 StoreKit Configuration 會用 `Config/SmartSchedule.storekit`；不要提交這個改動（`validate_schema.py` 和 `ReleaseConfigurationTests` 會擋下來）。
5. 實機執行，到控制中心加入「Smart Schedules」控制項（設定 › 捷徑與 Siri 有步驟說明）。

## 上架前檢查清單

完整清單、1.0 已決定的事（不賣訂閱、年齡分級 18+、不在歐洲經濟區、瑞士、香港、澳門和中國大陸上架、不用 iOS 18 的即時動態 push-to-start、網站在 https://www.smart-schedules.com、開發者在英國）和待決定事項（之後版本的訂閱價格和 Pro 要鎖什麼、使用條款）在 [`docs/SETTINGS.md`](docs/SETTINGS.md) 第 16 節。App Store Connect 要貼的文字和每個問卷的答案在 [`docs/app-store-metadata.md`](docs/app-store-metadata.md)。

- [ ] **Gemini 付費層級**：替 Gemini API 的 Google Cloud 專案開啟 Cloud Billing。免費層級下 Google 可能用請求內容改善產品；App 和隱私權政策都不能宣稱「不用於訓練」。App 經由 `server/worker/` 呼叫 Gemini，API key 不在 App 裡。
- [ ] **Google OAuth 驗證**：`calendar.events` 和 `calendar.calendarlist.readonly` 都是敏感 scope。送審 consent screen（App 名稱、logo、首頁、隱私權政策、授權網域）、每個 scope 的用途說明，以及一段示範影片（OAuth 流程、新增行程、抽屜列出行事曆）。consent screen 還在 Testing 時，refresh token 7 天就會失效。步驟、要貼的英文和影片腳本見 [`docs/google-oauth-verification.md`](docs/google-oauth-verification.md)。
- [ ] **Apple Developer 帳號**：Apple Developer Program 已核准。Team ID（developer.apple.com › Membership details）填進 `Config/Secrets.xcconfig`，也用 `npx wrangler secret put APPLE_TEAM_ID` 設給正式環境的 Worker（沒設時 `POST /attest` 回 500，AI 助理不能用；見 [`server/worker/README.md`](server/worker/README.md)）。
- [ ] **App ID 和功能**：`com.smartschedules.app`、`com.smartschedules.app.widgets`、`com.smartschedules.app.notification-content` 三個都勾 App Groups（`group.com.smartschedule.shared`）；主 App 另外要 App Attest 和 Time Sensitive Notifications。**不需要 Push Notifications**：1.0 沒有 `aps-environment`（`AppConstants.pushToStartEnabled = false`）。
- [ ] **Worker（1.0）**：只要 `GEMINI_API_KEY` 和 `APPLE_TEAM_ID` 兩個 secret；正式環境 `crons = []`，不用建立 APNs 的 `.p8`，也不用設 `APNS_*` secrets（`server/worker/README.md`「1.0：push-to-start 關閉」）。
- [ ] **App Store 隱私標籤**（與 `App/PrivacyInfo.xcprivacy` 一致）：Other User Content（請求內容和跟請求一起送出的行程，經 Smart Schedules 的伺服器（Cloudflare Worker）轉給 Google Gemini，伺服器不保存；1.0 沒有 push-to-start，伺服器不存任何行程；Google 帳號 email 不送給 Gemini）、Device ID（App Attest 金鑰 ID：每個請求都帶，伺服器用來驗證請求和依安裝限制次數；1.0 沒有安裝 ID 或 push token），用途都是 App 功能、連結身分、不用於追蹤。隱私權政策要寫明 Cloudflare 是處理者、Google 是接收者。
- [ ] **不賣訂閱（1.0）**：`AppConstants.subscriptionsEnabled` 保持 false；不要把任何 App 內購買項目或訂閱附加到 1.0 送審（App Store Connect 裡如果已經建立「Smart Schedules Pro」群組或商品，就留著不送審）；App 隱私問卷不勾 Purchases。之後要賣時再把旗標和 `ReleaseConfigurationTests`、`validate_schema.py` 第 7 項一起改，建立跟 `Config/SmartSchedule.storekit` 相同 ID 的商品（`com.smartschedule.pro.monthly`、`com.smartschedule.pro.yearly`），簽署 Paid Apps 協議，加上各語系的訂閱名稱，用 sandbox 測試，並把支援頁的訂閱問答和隱私權政策第 7 節改回來。
- [ ] **年齡分級 18+**：在 App Store Connect 填年齡分級問卷，分級設為 18+（問卷算出來比較低就選較高的分級），因為 Gemini API 的條款要求使用者年滿 18 歲。隱私權政策和支援頁寫同樣的最低年齡。
- [ ] **不在歐洲經濟區、瑞士、香港、澳門和中國大陸上架**：價格與供應狀況裡取消 27 個歐盟會員國，加上挪威、冰島、列支敦斯登和瑞士，以及香港、澳門和中國大陸（Gemini API 不在那裡提供）；英國和其他地區照常上架（`docs/app-store-metadata.md` §4.3）。數位服務法（DSA）仍要先聲明一次「不是交易商」（見 `docs/app-store-metadata.md` §4.3），交易商驗證等之後的版本加入歐盟時再處理。
- [ ] **英國**：開發者在英國，不需要英國 GDPR 第 27 條的代表人。到 ico.org.uk 的「Do I need to pay the fee?」確認要不要繳 ICO 的資料保護費（data protection fee），金額以 ICO 網站為準（`docs/app-store-metadata.md` §4.4）。
- [ ] **App Review**：5.1.2(i) 同意說明在任何個人資料送到 Gemini 之前出現（全新安裝、Siri、通知擴充都要確認）；2.1 在審核備註說明「不登入先試用」，最好附測試用 Google 帳號；5.1.1(v) 說明「移除帳號」（撤銷授權）和「清除這台裝置上的所有資料」。
- [ ] **實機確認**：Time Sensitive 在專注模式下能穿透、專注模式過濾條件開關時 `perform()` 有執行；iOS 26 的即時動態在 App 關著時準時出現，iOS 18 在提前時間內打開 App 才出現（`docs/ARCHITECTURE.md` 第 7 節）。
- [ ] **App Store Connect**：建立 App（Bundle ID `com.smartschedules.app`），照 [`docs/app-store-metadata.md`](docs/app-store-metadata.md) 填 App 資訊、兩個語系的產品頁、App 隱私、年齡分級、供應地區和審核資訊（測試 Google 帳號、備用驗證碼）。
- [ ] **TestFlight**：用 Distribute App 上傳 Release build（正式環境的 `GEMINI_BASE_URL`），先在 TestFlight 用正式 Worker 測過 AI 助理、長按通知回覆和 App Attest，再送審。
- [ ] **截圖**：6.9 吋和 6.3 吋 iPhone 各一組、繁體中文和英文各一組，只用虛構資料（`docs/app-store-metadata.md` 第 9 節）。
- [ ] **網站 https://www.smart-schedules.com**（首頁、隱私權政策、支援頁，見 [`site/README.md`](site/README.md) §3）：先填好頁面裡標黃的佔位值（開發者名稱、支援頁的回覆天數），再把 `site/` 部署成 Cloudflare Pages 專案，在 Pages 加上自訂網域 `www.smart-schedules.com`，然後在 Squarespace 的 DNS 加**一筆** CNAME（`www` → 專案的 `pages.dev` 主機名稱）。**DNS 不搬到 Cloudflare**，nameserver 和 DNSSEC 不動，Google Workspace 的 MX、SPF、DKIM、DMARC 和 `google-site-verification` 一筆都不動。`SSPrivacyURL` 已設為 https://www.smart-schedules.com/privacy，網站上線前這個連結打不開。根網域 smart-schedules.com 轉到 www 是選做（`site/README.md` §3.5，Squarespace 的網域轉址；要是開了，隱私權政策第 10 節要補一句 Squarespace 會處理轉址的連線）。
- [ ] **support@ 郵件**：support@smart-schedules.com 是 Google Workspace 的 Gmail 信箱（隱私權政策第 9、12、13、17 節已寫明），在 Squarespace 完成 DKIM 和 DMARC（`site/README.md` §3.6），不用 Cloudflare Email Routing；Search Console 用網域資源 `smart-schedules.com` 驗證（§3.7，TXT 加在 Squarespace）。

## 驗證狀態

| 項目 | 狀態 |
|---|---|
| Gemini schema lint（OpenAPI subset，9 個函式）、15 個 fixture 的 JSON Schema 驗證、DST 和 RRULE 參考測試、String Catalog（每個 key 都有繁體中文）、1.0 不賣訂閱（`AppConstants.subscriptionsEnabled` 是 false，用到 StoreKit 或訂閱文字的檔案都讀這個旗標） | ✅ `python3 -I scripts/validate_schema.py`，CI 每次 push 都會跑 |
| Swift 編譯（App、Widgets、Notification extension） | ⏳ 設定、多帳號改動後待 CI 重新編譯（GitHub Actions 的 macOS runner：xcodegen 加 xcodebuild） |
| 單元測試 | ⏳ 設定、多帳號改動後待 CI 重跑（hostless `SmartScheduleCoreTests`） |
| 只能在實機上確認的行為（控制中心打開快速輸入、iOS 26 排程啟動的 Live Activity、iOS 18 打開 App 時出現的 Live Activity（1.0 沒有 push-to-start）、通知內 inline TextField、160 pt 高度） | ⏳ 清單在 `docs/ARCHITECTURE.md` 第 7 節 |
| Gemini 模型 ID | ⚠️ 預設 `gemini-3.5-flash`；上線前到 Gemini deprecations 頁確認。換 ID 前先加進 Worker 的 `SESSION_MODELS` |
