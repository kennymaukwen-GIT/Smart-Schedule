# Google Calendar 整合：從 Gemini JSON 寫進行事曆，再同步回來

程式碼位置：`Shared/Calendar/`（mapper、RRULE、client、sync、`CalendarRouter`）、`Shared/Auth/GoogleTokenProvider.swift`、`Shared/Auth/IDToken.swift`、`Shared/Storage/AccountStore.swift`、`Shared/Models/GoogleAccount.swift`、`Shared/Models/EventVisibility.swift`、`App/Auth/GoogleSignInCoordinator.swift`、`App/Auth/AccountManager.swift`、`App/Intents/CalendarFocusFilter.swift`

## 1. OAuth 設定

1. Google Cloud Console：啟用 **Google Calendar API**。
2. OAuth consent screen：加入 scope `https://www.googleapis.com/auth/calendar.events` 和 `https://www.googleapis.com/auth/calendar.calendarlist.readonly`，再加上 `openid` 和 `email`。`calendarlist.readonly` 是能列出使用者所有行事曆的最小 scope；`calendar.events` 本來就能讀寫使用者可存取的每個行事曆裡的事件，所以不需要更大的 scope。
3. Credentials：建立 OAuth client ID，類型選 **iOS**，Bundle ID 填 `com.smartschedule.app`。把 client ID 和 reversed client ID 寫進 `Config/Secrets.xcconfig`。
4. 登入流程：`ASWebAuthenticationSession` 加 PKCE（S256），redirect 是 `com.googleusercontent.apps.XXX:/oauth2redirect`。iOS 類型的 client **沒有 client secret**。授權網址帶 `prompt=consent select_account`（每次都顯示帳號選擇器，才能加第二個帳號；consent 確保拿得到 refresh token）、`include_granted_scopes=true`，重新連接時再帶 `login_hint=<email>`。
5. 登入後從 token 回應的 `id_token` 解出 `sub` 和 `email`（`IDToken`：只解 payload，不驗簽章，因為 token 是我們自己用授權碼從 Google token endpoint 透過 TLS 換來的）。`scope` 欄位以空白分隔，就是實際授予的 scope。`GoogleSignInCoordinator.signIn(loginHint:)` 只回傳結果，不存任何東西，由 `AccountManager` 決定是新帳號、重新連接，還是選錯帳號。
6. Token 存在 Keychain 的共享 group，**每個帳號一個 item**：service `com.smartschedule.tokens`、account `google.oauth.<sub>`，屬性是 `AfterFirstUnlock`，所以鎖定畫面上的 notification extension 也能自己 refresh。refresh 只是一個表單 POST 到 `oauth2.googleapis.com/token`，不需要 SDK。

**容易踩到的雷：**
- Consent screen 在 *Testing* 狀態時，refresh token **7 天後失效**，伺服器回 `invalid_grant`。`GoogleTokenProvider` 收到時**只刪掉那個帳號的 token**，並把帳號標成 `needsReconnect`；它的快取事件保留，其他帳號照常同步。抽屜和帳號頁會顯示「重新連接」。
- `calendar.events` 和 `calendar.calendarlist.readonly` 都屬於 **sensitive scope**，正式上線要提交 Google 的 App 驗證（品牌資料、隱私權政策、scope 用途說明、示範影片：要拍到登入流程、新增事件、抽屜裡列出行事曆）。

## 2. 欄位對應：Gemini draft 到 Event resource

| Gemini 欄位 | Google Event 欄位 | 轉換規則（`CalendarEventMapper`） |
|---|---|---|
| — | `id` | `GoogleEventID.make(seed:)`：取 SHA-256 前 128 bit，轉成 base32hex（`a–v`、`0–9`），前面加 `ss`。**同一個 seed 一定得到同一個 ID，重試時不會重複建立事件** |
| `title` | `summary` | 計畫事件會加前綴：`Muscle 6M · Upper` |
| 原始輸入的整句話 | `description` | `由 Smart Schedule 智慧助理自動排程：<原句>`（和 Artboard 5 的詳情頁一樣），後面接 notes、目標、階段說明 |
| `start` / `end` / `duration_minutes` | `start.dateTime` / `end.dateTime` 加 `timeZone` | 用牆上時間 `2026-10-14T14:00:00` 加 IANA 時區，**不帶 offset** |
| `all_day` 或只給日期 | `start.date` / `end.date` | `end.date` 是**不包含的那一天**，所以要加 1 天 |
| `recurrence` | `recurrence: ["RRULE:..."]` | 見第 4 節 |
| `reminder_minutes` 或預設值 | `reminders.useDefault=false` 加 `overrides[]` | 見第 5 節 |
| `kind` | `colorId` 加 `extendedProperties.private.ssKind` | routine 用 10（Basil 綠，對應 Gym）、deadline 用 6（Tangerine 橘）、task 用 5、event 沿用行事曆預設色 |
| — | `extendedProperties.private` | `ssSource`、`ssKind`、`ssPlanId`、`ssSchema`、`ssReminders`（見第 5 節），可以用 `privateExtendedProperty=ssPlanId=<id>` 查回整個計畫 |
| `add_video_conference` | `conferenceData.createRequest`（`hangoutsMeet`） | request 要帶 `conferenceDataVersion=1`，Meet 連結才會產生 |
| `attendees`（只接受 email） | `attendees[]` | 有受邀者時設 `sendUpdates=all`，沒有就是 `none` |

### 最終送出的 request（「明天下午兩點跟 Joe 開線上會議」）

`<calendarId>` 是預設寫入的行事曆（第 9.6 節），主要行事曆的 id 就是帳號 email；token 是那個帳號的。
```http
POST https://www.googleapis.com/calendar/v3/calendars/<calendarId>/events?sendUpdates=none&conferenceDataVersion=1
Authorization: Bearer <access_token>
```
```json
{
  "id": "ss…26 base32hex chars…",
  "summary": "與Joe開會",
  "description": "由 Smart Schedule 智慧助理自動排程：明天下午兩點跟 Joe 開線上會議",
  "start": { "dateTime": "2026-10-14T14:00:00", "timeZone": "Europe/London" },
  "end":   { "dateTime": "2026-10-14T15:00:00", "timeZone": "Europe/London" },
  "reminders": { "useDefault": false, "overrides": [
    { "method": "popup", "minutes": 1440 },
    { "method": "popup", "minutes": 60 },
    { "method": "popup", "minutes": 30 },
    { "method": "popup", "minutes": 0 }
  ]},
  "conferenceData": { "createRequest": { "requestId": "ss…", "conferenceSolutionKey": { "type": "hangoutsMeet" } } },
  "extendedProperties": { "private": { "ssSource": "smart-schedule", "ssKind": "event", "ssSchema": "1", "ssReminders": "default" } }
}
```

## 3. 時間格式：為什麼用牆上時間加 IANA 時區

Google 的規則是：`dateTime` 採 RFC3339 格式；**有指定 `timeZone` 時，offset 可以省略**。另外，重複事件**一定要**帶 `timeZone`。

**實例：** 2026-10-13 在倫敦建立一個 6 個月的健身計畫，會跨過兩次時制切換：
- 2026-10-25：BST 切回 GMT（UTC+1 變 UTC+0）
- 2027-03-28：GMT 切回 BST

如果寫死 `18:30+01:00`，從 10/25 到 3/28 這五個月，健身都會在 **17:30** 跳出來。用 `"dateTime":"…T18:30:00","timeZone":"Europe/London"`，Google 會在每個 instance 自動套用當天正確的 offset。

其他格式：
- `events.list` 的 `timeMin` 和 `timeMax` 用完整的 RFC3339（`ISO8601DateFormatter`）。
- 解析 Google 回傳的時間時，接受帶 offset 或 `Z`、有無小數秒的格式（`WallClock.parseRFC3339`）。
- 牆上時間不存在的情況（例如 2027-03-28 的 01:30）：`Calendar.date(from:)` 會往後推到下一個合法時刻。

## 4. RRULE 規則（`RecurrenceRule.swift`）

| 規則 | 實作 |
|---|---|
| `UNTIL` 必須是 UTC | DTSTART 帶 TZID 時，RFC 5545 §3.3.10 規定 UNTIL 要用 UTC。把當地那一天的 23:59:59 換算成 UTC：GMT 日是 `20261130T235959Z`，BST 日是 `20270413T225959Z`（validator 有 assert） |
| DTSTART 要對齊第一個 BYDAY | DTSTART 一定算第一次。如果階段從星期二開始、規則是 `BYDAY=MO,TH`，DTSTART 要放在星期四，否則會多出一個星期二的事件 |
| `UNTIL` 和 `COUNT` 二選一 | 兩者都有時保留 UNTIL（使用者之後改日期比較穩） |
| 驗證 | `FREQ` 只接受白名單值，BYDAY 去除重複並排序，INTERVAL 不超過 52，COUNT 不超過 730 |

## 5. 提醒（24 小時、1 小時、30 分鐘、開始時）

Google 的限制：`overrides` **最多 5 個**，每個 `minutes` 介於 **0 到 40320**（4 週），`method` 是 `popup` 或 `email`。

| 類型 | 預設 overrides | 理由 |
|---|---|---|
| event（會議） | `[1440, 60, 30, 0]` | 對應 Artboard 1 的前一天、1 小時、30 分鐘，再加開始當下 |
| deadline | `[1440, 60]` | |
| task | `[60]` | |
| routine（計畫課程） | `[30]` | 一週 4 次，每次響 3 聲，使用者很快就會把它關掉 |
| 全天事件或 milestone | `[900]` | 全天事件的提醒是從**當天 00:00** 往前算，900 分鐘就是前一天 09:00 |

上表是出廠預設；實際值來自「設定 › 通知 › 預設提醒」（`ReminderPolicy(preferences:)`，每次寫入時從偏好設定建立 `CalendarEventMapper.current()`）。`ReminderPolicy.minutes()` 會把數值限制在合法範圍、去除重複、由大到小排序，最多取 5 個。全天事件和 milestone 走 `googleAllDayReminders(requested:)`。

**由誰發送提醒（設定 › 通知）：**

| 模式 | 寫給 Google 的 popup | Smart Schedule 自己的提醒 |
|---|---|---|
| 兩者都用（預設） | `useDefault=false`，overrides = 指定的或預設的 | 有 |
| 只用 Smart Schedule | `useDefault=false`、**`overrides: []`**：Google 不跳任何通知，其他裝置也不會 | 有（能長按回覆、延後、改時間） |
| 只用 Google 日曆 | 同「兩者都用」 | 沒有 |

切換模式不會改寫既有事件，只影響之後新增或修改的事件。

**`ssReminders`：** 因為「只用 Smart Schedule」時 Google 那邊是空的，Smart Schedule 把自己要發的提醒另外記在 `extendedProperties.private.ssReminders`：用的是該類型的預設值就寫 `"default"`，使用者指定的就寫分鐘數 `"60,10"`。每次建立事件、或修改提醒時都會寫（PATCH 只送這一個 key，Google 會合併 private 裡的其他 key）。讀回來時：`"default"` → `reminderMinutes = nil`（排提醒時用當下的預設值）；分鐘數 → 那些分鐘；沒有這個 property 的事件（使用者在 Google 建立的）：`useDefault == true` → nil，有 overrides → 那些分鐘，`useDefault == false` 而且沒有 overrides → `[]`（使用者在 Google 關掉了提醒）。

## 6. 寫入策略與錯誤處理（`GoogleCalendarClient.swift`）

| 狀況 | 處理方式 |
|---|---|
| 長期計畫有多筆寫入 | `insertAll`：用 `TaskGroup` 最多 4 路並行，結果保持原本順序 |
| 409 Conflict | 代表這個 ID 已經存在，也就是重試前其實寫成功了。改用 GET 取回該事件，當作成功 |
| 401 | 強制 refresh token 後重試一次 |
| 403 rateLimitExceeded、429、5xx | 指數退避加隨機抖動，最多重試 3 次。**一般的 403（權限不足）不重試** |
| 404 或 410（刪除時） | 視為已經刪除 |
| 部分失敗 | 因為 ID 是確定的，使用者再說一次「再試一次」只會補寫缺少的那幾筆 |

修改整個 series（`modify_event`，scope 設 `all_occurrences`）：先 GET 取得 master，保留 master 的第一天，只套用新的時刻，然後 PATCH master。

## 7. 雙向同步

| 方向 | 方式 |
|---|---|
| App 寫到 Google | 上面的 insert、patch、delete，寫完後立刻 upsert 到本地 cache |
| Google 回到 App（拉取） | `CalendarSync.refreshWindow()`：**每個帳號的每個行事曆**各抓 −7 到 +120 天、`singleEvents=true`（重複事件展開成個別 instance）、`orderBy=startTime`、每頁 250 筆，然後**整段取代** cache 裡那個行事曆的部分。觸發時機：開到前景、寫入之後、BGAppRefresh。這種做法不需要保存狀態，結果永遠正確。視窗以外的日期在畫面捲到時才載入，見第 8 節；多帳號的細節見第 9 節 |
| Google 回到 App（即時） | 需要後端：`events.watch` 註冊 webhook，事件有變動時發 APNs silent push 或 Live Activity push，App 收到後再跑 `refreshWindow`。channel 會過期，要排程續約 |
| 規模變大之後 | 改用 `syncToken` 增量同步；收到 410 Gone 就全量重抓 |
| 其他人在 Google 那邊改了事件 | 下次 refresh 時，Google 的版本覆蓋本地。Google 是唯一的事實來源，App 只是 cache |

## 8. 依需求載入任意日期（無限捲動的行事曆）

Quick Capture 的 DAY / WEEK / MONTH，以及主畫面的月份列和月曆，都可以一直往前、往後捲，沒有盡頭。滾動視窗（−7 到 +120 天）以外的日期，等畫面捲到那裡才載入。程式碼：`ScheduleViewModel.ensureEvents(covering:)`、`Shared/Calendar/LoadedRanges.swift`、`Shared/Calendar/SharedStore+LoadedRanges.swift`、`CalendarSync.load(_:)`。

| 項目 | 做法 |
|---|---|
| 入口 | 畫面每次捲動停下時，把看得到的範圍傳給 `ensureEvents(covering:)`。`focus(_:)`（助理要求顯示某段日期、按「今天」）也會呼叫，所以跳到好幾年後也會載入 |
| 範圍 | 看得到的範圍碰到的整個月份，前後再各加一個月（`LoadedRanges.request`），下一兩次滑動已經在 cache 裡。範圍超過 12 個月時只取前 12 個月，一次呼叫不會抓幾十年 |
| Request | 只抓缺少的部分（`LoadedRanges.missing`），而且每個行事曆只抓它自己缺的，每段一個 `events.list`：`timeMin`/`timeMax` 是缺少的那段，`singleEvents=true`、`orderBy=startTime`、每頁 250 筆，跟滾動視窗一樣 |
| Debounce | 最後一次呼叫後 300 ms 才開始。快速滑過的中間位置不會發 request。300 ms 內來自不同行事曆的範圍（例如主畫面月曆和 Quick Capture）最多保留最近 3 個，都會載入 |
| 去重 | 已經載入的範圍和正在載入的範圍都會跳過。已經載入的範圍是每個同步中行事曆覆蓋範圍（它的滾動視窗加上依需求載入的範圍）的交集，demo 模式則是 `loadedRanges` 加上滾動視窗（第 9.5 節）。兩次載入同時開始時，在同一個 MainActor 步驟裡先查再登記，所以不會抓同一個月兩次 |
| 不擋畫面 | 載入在獨立的 `Task` 裡跑，下一次呼叫只會取消 debounce，不會中斷已經送出的 request。載入期間 `isLoadingRange` 為 true，畫面可以顯示細小的進度提示 |
| 寫入 cache | `SharedStore.mergeRange(_:calendar:with:)`：取代那個行事曆在該範圍內的事件；同一份副本在別的日期的舊版本（事件被移動了）一起移除，別的行事曆不受影響。**不動 `windowStart`、`windowEnd`、`lastRefresh`**，提醒排程、Live Activity 和滾動同步都照舊 |
| 錯誤 | 不影響畫面：cache 保留原本的資料，範圍不標記為已載入，下次再顯示時重試。失敗只算那個行事曆的；某個帳號的 refresh token 失效時，只有那個帳號被標成需要重新連接 |
| 新鮮度 | 每次滾動同步（`replaceWindow`：開到前景、BGAppRefresh、助理寫入之後，不論哪個 process）都會清空那個行事曆依需求載入的範圍（demo 是 `loadedRanges`）。cache 裡的事件照樣顯示，但每段範圍下次出現在畫面上時會重抓一次，所以在 Google 網頁版改的遠期事件也會同步回來。`reloadFromCache()` 會馬上重抓目前畫面上的範圍；本月月曆第一列落在視窗開始之前的那幾天也是這樣補上的 |
| Demo 模式 | 不連 Google。`DemoData.recurringEvents(in:)` 產生該範圍的每週項目（Gym 一三五 18:30、週一 Weekly team sync、週六 Yoga），id 是 `demo-<series>-<yyyy-MM-dd>`，不同範圍產生的同一次項目 id 相同，合併時不會重複。一次性項目（會議、午餐、旅行等）只在 seed 裡，留在相對於 seed 當天的位置。合併時用 `replacingCached: false`，demo 助理建立、修改或刪除的事件不會被蓋掉 |

### Cache 上限

App Group 的 JSON 每次讀寫都是整個檔案，三個 process 都會讀，所以要設上限。每次載入成功後，如果 cache 超過 `ScheduleViewModel.maxCachedEvents`（2000 筆，約 1 MB），就丟掉離「今天」、「最後顯示的範圍」和「待確認計畫的日期」都超過 12 個月的事件（`LoadedRanges.evict`、`SharedStore.evictEvents`），並把那些範圍從 `loadedRanges` 和每個行事曆的覆蓋範圍移除，捲回去時再重抓。

永遠不會丟的：滾動視窗、計畫預覽（`draft-` 開頭的 id）、待確認計畫的事件。Demo 模式只會丟可以重新產生的每週項目，其他 demo 事件只存在 cache 裡，丟了就沒了。

提醒不受影響：`ReminderScheduler` 從最近的觸發時間開始排，最多 64 個。被丟掉的事件都在 12 個月以外，提醒最多提前 4 週（Google 的上限），在那之前它早就回到滾動視窗（+120 天）裡、重新排上了。

## 9. 多個 Google 帳號

### 9.1 帳號的生命週期（`AccountManager`）

| 動作 | 做法 |
|---|---|
| 新增帳號 | 登入 → 如果 `sub` 已經連接過：更新 token、清掉 `needsReconnect`、合併 scope（等於重新連接）→ 否則以 `google.oauth.<sub>` 存 token，`AccountStore.upsert` 一筆帳號（先放一個「主要行事曆」佔位，id 是 email）→ 讀行事曆清單 → 只同步這個帳號的行事曆 → 重排提醒、更新 Live Activity |
| 重新連接 | 帶 `login_hint` 登入；如果登入的是別的帳號（`sub` 不同），丟出「你登入的是 X，請選擇 Y 重新連接」，**什麼都不存** |
| 中斷連接 | POST `https://oauth2.googleapis.com/revoke`（表單 `token=<refresh_token>`，10 秒逾時，失敗也繼續）→ 刪 Keychain item → `SharedStore.purge(accountID:)`（這個帳號的事件、範圍記錄、只存在它行事曆裡的計畫提醒）→ `AccountStore.remove` → 如果「新行程的行事曆」設在這個帳號，改回自動 → 如果「先問我」的待加入行程要寫進這個帳號，清掉 → 重排提醒。**Google 日曆裡的東西一律不刪** |
| 清除所有資料 | `disconnectAll(revoke: true)`：撤銷每個 token（含舊版的）→ 清每個帳號的快取 → `KeychainStore.deleteAll()` → 刪 `accounts.json`。提醒和 Live Activity 由呼叫的 `DataEraser` 先移除 |
| 行事曆清單 | App 回到前景、打開抽屜、背景更新時：有 `calendarlist.readonly` 而且清單超過 6 小時的帳號重讀一次（`force` 時全部重讀）。已知的行事曆保留這台 iPhone 的設定；新的行事曆照 Google 的 `selected` 決定顯示與否（主要行事曆一定顯示），立刻同步；不見的行事曆從快取移除 |

### 9.2 從單一帳號版本升級（`migrateLegacyAccountIfNeeded`）

舊版只有一個 Keychain item `google.oauth`，事件快取也沒有記錄屬於哪個行事曆。`ScheduleViewModel.bootstrap()` 第一件事就是遷移，每次 App 回到前景（`refreshCalendarLists`）和背景更新也會再試，所以離線時沒做完也會補上。流程是冪等的：

1. `AccountStore` 已經有帳號：刪掉殘留的 `google.oauth`，結束。
2. 讀舊 token，沒有就結束。
3. 取得 access token（需要時 refresh）。`invalid_grant` 會刪掉舊 token，UI 回到「連接 Google 日曆」。
4. `GET https://openidconnect.googleapis.com/v1/userinfo` 取得 `sub`、`email`（舊版的 `openid email` scope 就允許）。
5. 以 `google.oauth.<sub>` 存 token，登記帳號（scope 是舊版的三個，主要行事曆佔位）。
6. 試著讀行事曆清單：舊 token 沒有 `calendarlist.readonly`，Google 回 403，於是 `canListCalendars == false`，抽屜在這個帳號下顯示「顯示所有行事曆」，點了會重新授權補上 scope。
7. 刪掉 `google.oauth`、`SharedStore.dropUnscopedGoogleEvents()`（舊的無歸屬事件；demo 事件和計畫預覽保留）、重新同步。

在遷移完成前，`GoogleTokenProvider.accessToken(accountID: nil)`、`CalendarSync` 和 `CalendarRouter` 在沒有任何帳號時會退回舊 token 和它的主要行事曆（事件照舊不記錄行事曆），所以通知 extension 先被觸發也不會壞。

### 9.3 事件的身分

| 用途 | 身分 | 說明 |
|---|---|---|
| 快取（`SharedStore`） | `EventRef`：帳號、行事曆、Google event id | 同一個 id 出現在兩個行事曆是兩份快取副本。upsert、merge、刪除都以 `EventRef` 為準 |
| 畫面、通知、prompt | `ScheduleEvent.id`（Google 原本的 id） | `visibleEvents` 保證可見清單裡不會有兩個相同的 id，所以 SwiftUI、`ss.reminder.<id>.<minutes>`、`ssEventId`、UPCOMING 照舊。`event(id:)` 先回傳可見的那份，否則任何一份 |
| 同一場會議 | `iCalUID` 加開始時間 | Google 給每位與會者行事曆裡的副本相同的 iCalUID（通常 id 也相同）；重複事件的每個 instance 共用 iCalUID，用開始時間分開 |

Smart Schedule 產生的 id（`GoogleEventID.make(seed:)`）用每次請求的 UUID 或計畫 id 當 seed，不會跨行事曆撞號。Google 只要求 id 在單一行事曆內唯一；insert 收到 409 時在**同一個行事曆**裡 GET 回來（冪等性不變）。使用者在 Google 把事件搬到別的行事曆時 id 不變：舊行事曆下次列出時拿掉，新行事曆列出時加進來。

### 9.4 顯示與提醒（`EventVisibility`）

`SharedStore.visibleEvents(in:audience:)` 把快取交給 `EventVisibility.apply`，規則來自 `AccountStore.visibilityRules()`：

- **Demo 模式**只顯示 demo 事件和計畫預覽；離開 demo 模式後，殘留的 demo 事件一律不顯示。
- `display`：拿掉被隱藏的行事曆；專注模式過濾條件生效時，只留下它選的行事曆。
- `reminders`：`display` 再拿掉「提醒」關閉的行事曆。`ReminderScheduler` 用它排提醒，摘要和 Live Activity 用 `display`。
- **不認得的行事曆一律顯示、也會提醒**（沒有行事曆的事件，或帳號清單裡已經沒有的行事曆）。
- 沒有自己顏色的事件（`colorId` 為空，`usesCalendarColor`）用行事曆的顏色畫，所以「行事曆顏色」的本機設定會套用。
- **同一場會議只顯示一份**：依序選主辦人那份（`organizer.self`）、可寫入的行事曆、預設寫入的行事曆、帳號順序（再來是行事曆順序，主要行事曆優先）。沒選上的副本留在快取裡，勝出的行事曆被隱藏時會自動出現。
- 結果依開始時間排序。`snapshot().events` 仍是全部原始副本，只給快取維護用。

### 9.5 每個行事曆各自的滾動視窗和載入範圍

- `CalendarSync.refreshWindow` 對每個同步中的行事曆（`AccountStore.syncedCalendars()`：每個帳號的每個行事曆，包含在 App 裡隱藏的，這樣重新顯示時立刻有資料；需要重新連接的帳號除外）各自列出 −7 到 +120 天，`replaceWindow(_:calendar:with:)` 只取代那個行事曆在視窗裡的事件，並把它的覆蓋範圍設成視窗（忘掉它依需求載入的範圍，跟以前一樣）。最多 4 個行事曆同時抓。
- `CalendarSync.load` 對每個行事曆只抓**它自己**還沒有的部分（`coverage(for:)`），`mergeRange(_:calendar:with:)` 合併。
- `SharedStore.coverage()` 回傳所有同步中行事曆覆蓋範圍的**交集**，所以 `ScheduleViewModel.loadMissing` 不用改：任何一個行事曆缺的都算缺，新加入的帳號沒有任何範圍，畫面上的範圍會立刻替它載入。Demo 模式或沒有行事曆時用原本的全域範圍。
- 不分行事曆的 `replaceWindow(_:with:)`（demo 種子）取代視窗裡所有事件，也清空每個行事曆的覆蓋範圍；`mergeRange(_:with:replacingCached:)` 留給 demo 範圍。
- 快取上限（`evictEvents`）也會把每個行事曆的覆蓋範圍修剪到保留區。
- 失敗只影響那個行事曆：保留它的快取和範圍；`invalid_grant` 把帳號標成需要重新連接；只有「沒有任何帳號」或「每個行事曆都失敗」才丟出錯誤。

### 9.6 寫入：預設行事曆和路由（`CalendarRouter`）

- **新事件**寫到 `AccountStore.defaultWriteTarget()`：設定或語音選的「新行程的行事曆」（帳號仍連接、行事曆存在且可寫入時），否則第一個帳號的主要行事曆；沒有帳號就丟 `AuthError.signedOut`。Demo 模式用 demo 的個人主要行事曆（或 `default_calendar` 選的）。
- **既有事件**帶著帳號和行事曆，修改、刪除都送到那份副本所在的行事曆（去重之後就是主辦人或可寫入的那份）。整個系列的修改 PATCH 該 instance 所在行事曆的 `seriesID`。沒有行事曆的事件送到預設行事曆。
- `delete_events` 帶 `plan_id` 時，在每個可寫入的同步行事曆用 `privateExtendedProperty=ssPlanId=<id>` 找系列（計畫寫在當初加入的行事曆）。
- 寫入唯讀行事曆會在送出前擋下，Google 回 403 `requiredAccessLevel` 也一樣，顯示「你無法修改「<行事曆>」裡的行程。」
- 寫完立刻 upsert 到快取（帶上帳號、行事曆）；有重複事件時改為重新列出那個行事曆的滾動視窗。

### 9.7 專注模式過濾條件（`CalendarFocusFilter`）

`SetFocusFilterIntent`，參數是要顯示的行事曆（`CalendarEntity`，id 是 `CalendarRef.key`，標題是行事曆名稱，副標題是帳號 email）。使用者在「設定」App › 專注模式 › 某個專注模式 › 加入過濾條件 › Smart Schedule 選擇。專注模式開啟時 iOS 執行 `perform()`：`AccountStore.setFocusFilter(選的行事曆)` → 重排提醒 → 更新 Live Activity；關閉時 iOS 再以預設值（nil）執行一次，過濾條件就清掉。App 沒有公開的網址能直接打開專注模式設定，所以設定頁只說明路徑。**要在實機上確認開啟和關閉都有呼叫 `perform()`。**

### 9.8 Demo 帳號

`DemoData.accounts`：`demo-personal`（`you@example.com`：「我的行事曆」`#039BE5`、「Gym」`#0B8043`）和 `demo-school`（`student@university.example.edu`：「我的行事曆」`#7986CB`）。Gym、Yoga 在 Gym 行事曆；Weekly team sync 和 Deadline for Plan 5008 在學校帳號；其他都在個人主要行事曆。Demo 模式下 `AccountStore.accounts()` 回傳這兩個帳號並套用使用者對它們的本機設定（隱藏、顏色、提醒），`syncedCalendars()` 是空的（不抓任何東西）。沒有記錄行事曆的 demo 事件（例如 demo 助理新增的）永遠顯示。
