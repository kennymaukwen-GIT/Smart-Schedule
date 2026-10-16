# Google Calendar 整合：從 Gemini JSON 寫進行事曆，再同步回來

程式碼位置：`Shared/Calendar/`（mapper、RRULE、client、sync、`CalendarRouter`、`SyncEngine`、`SyncOutbox`、`SyncMerge`、`EventEditor`、`EventNotes`）、`Shared/Models/EventDigest.swift`、`Shared/Storage/SyncStatusStore.swift`、`Shared/Auth/GoogleTokenProvider.swift`、`Shared/Auth/IDToken.swift`、`Shared/Storage/AccountStore.swift`、`Shared/Models/GoogleAccount.swift`、`Shared/Models/EventVisibility.swift`、`App/Auth/GoogleSignInCoordinator.swift`、`App/Auth/AccountManager.swift`、`App/Intents/CalendarFocusFilter.swift`

## 1. OAuth 設定

1. Google Cloud Console：啟用 **Google Calendar API**。
2. OAuth consent screen：加入 scope `https://www.googleapis.com/auth/calendar.events` 和 `https://www.googleapis.com/auth/calendar.calendarlist.readonly`，再加上 `openid` 和 `email`。`calendarlist.readonly` 是能列出使用者所有行事曆的最小 scope；`calendar.events` 本來就能讀寫使用者可存取的每個行事曆裡的事件，所以不需要更大的 scope。
3. Credentials：建立 OAuth client ID，類型選 **iOS**，Bundle ID 填 `com.smartschedules.app`。把 client ID 和 reversed client ID 寫進 `Config/Secrets.xcconfig`。
4. 登入流程：`ASWebAuthenticationSession` 加 PKCE（S256），redirect 是 `com.googleusercontent.apps.XXX:/oauth2redirect`。iOS 類型的 client **沒有 client secret**。授權網址由 `GoogleAuthorization.url(…)` 產生：`include_granted_scopes=true`；有 `login_hint`（新增帳號頁輸入的 email，或重新連接的帳號）時 `prompt=consent`，Google 直接走到那個帳號或填好 email 請使用者登入；沒有時 `prompt=consent select_account`（顯示帳號選擇器，才能加第二個帳號）。consent 確保拿得到 refresh token。email 裡的「+」送成 `%2B`。redirect 帶 `error=`（`access_denied`、`admin_policy_enforced` 等）時轉成 `GoogleSignInFailure`，用一句話告訴使用者（`docs/SETTINGS.md` §5.11）。
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
| 原始輸入的整句話 | `description` | `由 Smart Schedule 智慧助理自動排程：<原句>`（和 Artboard 5 的詳情頁一樣），後面空一行接 notes、目標、階段說明。Google 日曆照原樣顯示整段；App 的備註編輯框隱藏來源行、存檔時自動放回，其餘就是 App 裡的「備註」（純文字，使用者可以改或刪，見第 11 節）；沒有程式會把它解析回來，計畫靠 `ssPlanId` 找 |
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

**`ssReminders`：** 因為「只用 Smart Schedule」時 Google 那邊是空的，Smart Schedule 把自己要發的提醒另外記在 `extendedProperties.private.ssReminders`：用的是該類型的預設值就寫 `"default"`，使用者指定的就寫分鐘數 `"60,10"`，在行程頁把提醒全部關掉就寫 `"none"`（Google 那邊同時送 `useDefault: false`、`overrides: []`）。每次建立事件、或修改提醒時都會寫（PATCH 只送這一個 key，Google 會合併 private 裡的其他 key）。讀回來時：`"default"` → `reminderMinutes = nil`（排提醒時用當下的預設值）；`"none"` → `[]`；分鐘數 → 那些分鐘；沒有這個 property 的事件（使用者在 Google 建立的）：`useDefault == true` → nil，有 overrides → 那些分鐘，`useDefault == false` 而且沒有 overrides → `[]`（使用者在 Google 關掉了提醒）。

## 6. 寫入策略與錯誤處理（`GoogleCalendarClient.swift`）

| 狀況 | 處理方式 |
|---|---|
| 長期計畫有多筆寫入 | `insertAll`：用 `TaskGroup` 最多 4 路並行，結果保持原本順序 |
| 409 Conflict | 代表這個 ID 已經存在，也就是重試前其實寫成功了。改用 GET 取回該事件，當作成功 |
| 401 | 強制 refresh token 後重試一次 |
| 403 rateLimitExceeded、429、5xx | 指數退避加隨機抖動，最多重試 3 次。**一般的 403（權限不足）不重試** |
| 404 或 410（刪除時） | 視為已經刪除 |
| 部分失敗 | 因為 ID 是確定的，使用者再說一次「再試一次」只會補寫缺少的那幾筆 |
| 連不到 Google（沒有網路、逾時、重試後仍是 5xx） | 寫進 outbox，畫面上立刻顯示並標成「等待同步」，之後依序送出（第 10.3 節） |
| 412 Precondition Failed（PATCH／DELETE 帶的 If-Match 過期） | 重新 GET，只把使用者改的欄位套到 Google 目前的版本上，再送一次（第 10.2 節） |

修改整個 series（`modify_event`，scope 設 `all_occurrences`）：先 GET 取得 master，保留 master 的第一天，只套用新的時刻，然後 PATCH master。

## 7. 雙向同步

| 方向 | 方式 |
|---|---|
| App 寫到 Google | 上面的 insert、patch、delete（PATCH／DELETE 帶 If-Match），寫完後立刻 upsert 到本地 cache。連不到 Google 時進 outbox（第 10.3 節） |
| Google 回到 App（拉取） | 兩種：**完整列出**（`CalendarSync.refreshWindow()`：**每個帳號的每個行事曆**各抓 −7 到 +120 天、`singleEvents=true`（重複事件展開成個別 instance）、`orderBy=startTime`、每頁 250 筆，然後**整段取代** cache 裡那個行事曆的部分，不需要保存狀態，結果永遠正確），和**變更增量**（`updatedMin` 加 `showDeleted`，只問上次之後改了什麼）。由 `SyncEngine` 依觸發來源決定，見第 10 節。視窗以外的日期在畫面捲到時才載入，見第 8 節；多帳號的細節見第 9 節 |
| Google 回到 App（即時） | 需要後端，見第 10.8 節 |
| 其他人在 Google 那邊改了事件 | 下次同步時，Google 的版本覆蓋本地（還在 outbox 裡等待的本機變更會再疊上去）。Google 是唯一的事實來源，App 只是 cache |

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
| 新增帳號 | 帶輸入的 email 當 `login_hint` 登入；沒有勾選日曆權限（grant 裡沒有 `calendar.events`）就撤銷、不存；ID token 的 email 和輸入的不同（Gmail 忽略點和 `+標籤`）時**什麼都不存**，讓使用者選「加入 X」「改用 Y 重新登入」或「取消」（撤銷剛拿到的 token，但那個帳號已經連接的話不撤銷）；`sub` 已經連接過就更新 token 和行事曆清單，不重複 |
| 移除帳號 | POST `https://oauth2.googleapis.com/revoke`（表單 `token=<refresh_token>`，10 秒逾時，失敗也繼續）→ 刪 Keychain item → `SharedStore.purge(accountID:)`（這個帳號的事件、範圍記錄、只存在它行事曆裡的計畫提醒）→ `AccountStore.remove` → 如果「新行程的行事曆」設在這個帳號，改回自動 → 如果「先問我」的待加入行程要寫進這個帳號，清掉 → 重排提醒。**Google 日曆裡的東西一律不刪** |
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

`DemoData.accounts`：`demo-personal`（`example@gmail.com`：「我的行事曆」`#039BE5`、「Gym」`#0B8043`）和 `demo-school`（`example@yourmail.com`：「我的行事曆」`#7986CB`）。Gym、Yoga 在 Gym 行事曆；Weekly team sync 和 Deadline for Plan 5008 在學校帳號；其他都在個人主要行事曆。Demo 模式下 `AccountStore.accounts()` 回傳這兩個帳號並套用使用者對它們的本機設定（隱藏、顏色、提醒），`syncedCalendars()` 是空的（不抓任何東西）。沒有記錄行事曆的 demo 事件（例如 demo 助理新增的）永遠顯示。

## 10. 雙向同步的保證（Two-way sync guarantees）

使用者的要求：「Google 日曆出現哪些更改，這裡也要出現；這邊出現任何更改，Google 日曆也要出現。」這一節說明目前（沒有伺服器）能保證到什麼程度。程式碼：`Shared/Calendar/SyncEngine.swift`（觸發與流程）、`SyncOutbox.swift`（待送佇列）、`SyncMerge.swift`（衝突合併、增量套用、待送變更疊加，純函式並有單元測試）、`CalendarRouter.swift`（寫入）、`CalendarSync.swift`（拉取）、`Shared/Storage/SyncStatusStore.swift`（狀態）。

### 10.1 什麼會同步、什麼時候

| 方向 | 內容 | 時機 |
|---|---|---|
| App → Google | 助理新增、修改、刪除的行程，計畫的「加入」，「先問我」的「加入」，行程頁（抽屜的「行程」、行程清單、日曆上的行程、對話卡的「管理」）的修改和刪除（第 11 節） | 立刻送出。連不到 Google 時進 outbox，之後在下一列的每個時機依序送出 |
| Google → App | 每個同步中的行事曆（包括在 App 裡隱藏的）的新增、修改、刪除，含重複事件的單一 instance | 見下表 |

`SyncEngine.sync(_ trigger:)` 每次都是：先送 outbox → 再拉取 → 拉取成功而且 outbox 在這期間又有新項目時再送一次。同時進來的呼叫共用同一次執行（比較徹底的呼叫會等目前這次跑完再跑自己的）。

| 觸發（`SyncTrigger`） | 誰呼叫 | 拉取方式 |
|---|---|---|
| `pull` | 下拉重新整理、狀態列的「點一下重試」 | 一定完整列出 |
| `background` | BGAppRefresh（`earliestBeginDate` 15 分鐘，實際時間由 iOS 決定） | 一定完整列出 |
| `foreground` | App 回到前景、啟動 | 上次完整列出超過 15 分鐘才完整列出，否則變更增量 |
| `timer` | App 在前景而且看得到時每 60 秒 | 變更增量；上次完整列出超過 30 分鐘就完整列出 |
| `network` | `NWPathMonitor` 從離線變回連線 | 同 `timer` |
| `outbox` | outbox 送出了東西之後、失敗項目按「重試」 | 同 `timer` |
| `notification` | 通知內容擴充開啟提醒時（另外用 `events.get` 抓那一個事件） | 同 `timer` |
| `summon` | 目前沒有觸發者（控制中心按鈕改為打開快速輸入）；保留給沒有 SyncEngine 的程式碼透過 `SyncRequests` 要求同步 | 同 `timer` |

同步改變了 cache 時：重排提醒、更新 Live Activity（App 在啟動時用 `AppRefresh.installSyncHooks()` 掛上），並發出 `SharedChange.syncStatus`，其他 process 收到後重新讀取。

### 10.2 衝突規則

- 每個快取的事件都記著 Google 給的 `etag`（`ScheduleEvent.etag`，來自 list、insert、patch、get 的回應）。PATCH 和 DELETE 都帶 `If-Match: <etag>`。Google 的錯誤說明：412 `conditionNotMet` 表示 If-Match 的 etag 已經不是目前的版本，建議「重新取得、重新套用變更」。
- **412 時**：GET 目前的版本 → `ConflictMerge.rebase` 只保留使用者這次改的欄位、而且跟 Google 現在不同的欄位（標題、時間、地點、提醒、`ssReminders` 等）→ 用新的 etag 再 PATCH 一次。使用者沒改的欄位不會送出，所以 Google 那邊較新的修改不會被舊值蓋掉。使用者只是把行程移到別的時間（長度沒變），而 Google 那邊同時改了長度時，新的結束時間沿用 Google 的長度。只改開始時間時，結束時間跟著移動。
- 第二次又是 412：不再重試，即時寫入時回「「X」同時在 Google 日曆被修改了，請再試一次。」；outbox 裡的則進失敗清單。
- GET 回 404／410 或 `status = cancelled`（事件在 Google 已被刪除）：這個修改不再有意義，丟掉，快取移除那份副本，並說「「X」已在 Google 日曆刪除，所以這項變更沒有儲存。」（outbox 裡的進失敗清單，理由「它已在 Google 日曆刪除。」）。
- 刪除遇到 412：使用者要刪的就是這個事件，所以不帶 If-Match 再刪一次。
- 整個系列的時間修改（`all_occurrences`）在送出當下才 GET master、算出新的時間，並用 master 的 etag 當 If-Match。

### 10.3 離線規則（outbox）

App Group 的 `sync-outbox.json`，App、Siri、通知擴充共用，跟 `SharedStore` 一樣用 `NSFileCoordinator` 讀寫。

| 狀況 | 處理 |
|---|---|
| 連不到 Google（`URLError` 沒有網路、DNS 失敗、逾時、連線中斷；client 重試 3 次後仍是 5xx／429／rate limit） | 寫進 outbox，並立刻套到快取（`isPendingSync = true`，畫面上有「等待同步」小圖示）。回覆加一句「已存在這支 iPhone 上，能連線到 Google 時就會同步到 Google 日曆。」 |
| 同一個事件已經有項目在等 | 新的修改直接排在後面（合併），不先送，保持順序 |
| 合併規則 | 新增後修改 → 新增（body 是新的，另外記在 `followUp`）；修改後修改 → 一個修改（保留第一個 etag 和原本的樣子，後面的欄位優先）；任何操作後刪除 → 刪除；**還沒送出的新增後刪除 → 兩個都丟掉**；刪除後的修改 → 丟掉。被拒絕的項目不合併 |
| 新增是否可能已經到達 Google | 請求根本沒離開手機（沒有網路）就不算；逾時、5xx 算「可能已到達」。可能已到達的新增再被刪除時，改送 DELETE（404 也當成功） |
| 送出順序 | 依第一次排入的順序。遇到連線失敗就停在那裡，後面的都等 |
| 新增的冪等性 | 不變：ID 由 seed 算出（base32hex），409 就 GET 回來。若 409 而且之後有合併進來的修改，再送一次 PATCH（`followUp`） |
| 授權失敗（refresh 之後仍是 401、`invalid_grant`、沒有 token） | 不丟掉，留在佇列裡；那個帳號標成需要重新連接，重新連接後就會送出。其他帳號照常 |
| 永久錯誤（400、403 沒有權限、修改時 404、第二次 412） | 移到失敗清單（`SyncStatus.failed`），可以「重試」或「捨棄」。失敗項目不再疊到快取上，下次拉取就回到 Google 的版本 |
| 帳號被移除 | 那個帳號的項目永遠送不出去：`AccountManager.disconnect` 呼叫 `SyncOutbox.removeAll(accountID:)`。移除前的確認視窗用 `SyncOutbox.unsentCount(accountID:)` 說明會遺失幾項，並提供「先同步」 |
| 拉取 | 每次列出（完整、增量、依需求載入）之後，outbox 裡還在等待的變更會再疊上去，所以離線改的東西不會閃回 Google 的舊版本 |
| 跨 process 同時送出 | 沒有鎖：新增是冪等的，重複的修改會遇到 412 然後發現沒有東西要改，重複的刪除會遇到 404。完成時只移除送出那一版（`revision`），送出期間合併進來的修改留到下次 |

### 10.4 Google → App 的增量：為什麼用 `updatedMin` 而不是 `syncToken`

官方文件的事實（2026-10-14 整理；這個環境連不到 developers.google.com，內容取自同一份 discovery 文件產生的 client library 參考，以及官方指南的搜尋摘要，上線前請再對照 [events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)、[同步指南](https://developers.google.com/workspace/calendar/api/guides/sync)、[錯誤處理](https://developers.google.com/workspace/calendar/api/guides/errors)、[版本與 ETag](https://developers.google.com/workspace/calendar/api/guides/version-resources)）：

- `syncToken`：取自上一次 list **最後一頁**的 `nextSyncToken`，只回傳之後有變動的項目；**刪除的項目一定會回傳**，`showDeleted` 不能設成 false。**不能和 `iCalUID`、`orderBy`、`privateExtendedProperty`、`q`、`sharedExtendedProperty`、`timeMin`、`timeMax`、`updatedMin` 一起用**；其他參數要和第一次完整同步相同。token 過期時回 **410 Gone**（reason `fullSyncRequired`），要清掉本地資料、不帶 token 重新完整同步。增量同步也可能分頁。
- `updatedMin`：最後修改時間的下限；**有設定時，那之後刪除的項目一定會回傳，不管 `showDeleted`**。可以和 `timeMin`／`timeMax` 一起用。太久以前會回 410（reason `updatedMinTooLongAgo`）。
- `showDeleted` 和 `singleEvents` 都是 true 時，只回傳被刪除的單一 instance，不回傳底層的重複事件。
- `timeMin` 是**結束時間**的下限（不含），`timeMax` 是**開始時間**的上限（不含）。

選擇 `updatedMin` 的理由：

1. Smart Schedule 的快取只有滾動視窗（−7 到 +120 天）加上畫面捲到的範圍，而且上限 2000 筆。`syncToken` 不能帶 `timeMin`／`timeMax`，token 的基準等於整個行事曆：`singleEvents=true` 時沒有結束日的重複事件會展開成大量 instance，`singleEvents=false` 則要在本地完整實作 RRULE、EXDATE 和例外（`RecurrenceExpander` 只處理計畫用的每週規則）。
2. 滾動視窗的邊界每天移動，新進入視窗的日子本來就不在任何 token 的基準裡，還是要完整列出。
3. `updatedMin` 可以限定在已經快取的範圍（每個行事曆的 coverage，通常一段），平常的回應是 0 筆，一個請求。

做法（`CalendarSync.pull`）：每個行事曆記一個 `SyncMark`（`SharedStore.Snapshot.syncMarks`）：上次完整列出的時間，以及 `changesSince` = 上次請求時 Google 的時鐘（第一頁回應的 HTTP `Date` header）減 60 秒，下一次就從這裡問，兩次之間不會漏。請求：`updatedMin=<changesSince>&showDeleted=true&singleEvents=true&timeMin=<範圍開始>&timeMax=<範圍結束>&maxResults=250`，最多 2 頁。套用（`IncrementalChanges.apply`）：`status=cancelled` → 移除那份副本（以及取消的系列的所有 instance）；其他 → 取代同一個 `EventRef` 的副本或新增；行事曆已經不在帳號清單裡就忽略；其他行事曆的副本不動。以下情況改成完整列出：沒有 `SyncMark`、上次完整列出太久（前景 15 分鐘，其他 30 分鐘）、`changesSince` 超過 7 天、超過 2 頁、410，以及出現已快取系列的**新** instance id（`IncrementalChanges.reshapesSeries`：系列在 Google 改了時間或延長時，instance id 帶著原始開始時間所以會換掉，舊的 instance 不會以 cancelled 回傳）。

已知限制：被移到快取範圍**以外**的事件，在有範圍限制的增量請求裡不會出現（它的新時間不在範圍內），舊的那份會留到下一次完整列出（使用中最多 15／30 分鐘；下拉重新整理和背景更新一定完整列出）。這就是「完整列出是定期的事實來源」的意思。

### 10.5 刻意只存在這支 iPhone 上的東西

| 項目 | 原因 |
|---|---|
| 行事曆的顯示／隱藏、本機顏色、提醒開關、專注模式過濾條件 | 每台裝置各自的顯示偏好。**隱藏只是不顯示**，資料照常雙向同步 |
| 設定（偏好、預設提醒、安靜時段、新行程的行事曆等）、「助理記得的事」、學到的建議 | App 自己的設定，Google 日曆沒有對應的欄位 |
| 對話紀錄、AI 同意、計畫的每日提醒（nudge）、「先問我」還沒加入的行程、計畫草稿 | 還不是行事曆資料；按「加入」之後才寫進 Google |
| Smart Schedule 自己的提醒 | 依據 Google 的事件和 `ssReminders` 在本機排程；「只用 Smart Schedule」模式下 Google 那邊不跳通知 |

**新行程寫進被隱藏的行事曆：** 新增的行程（助理的 create_events、計畫的「加入」、「先問我」的「加入」）一律寫進設定的預設行事曆，不會改寫到別的行事曆，所以 Google 一定有。那個行事曆在 App 裡被隱藏時，回覆帶 `Reply.savedToHiddenCalendar`（和名稱），確認卡片顯示「已存到「X」（目前在 Smart Schedule 隱藏）」和「顯示」按鈕，按下就把那個行事曆設成顯示。Demo 模式的範例行事曆也一樣。

### 10.6 Demo 模式

完全不連 Google：`SyncEngine` 的 `sync`、`flushOutbox`、`freshEvent`、`retry`、`discard` 在 demo 模式都不發出任何網路請求（有單元測試，用替身 transport 確認沒有請求）。狀態是 `isDemo = true`，狀態列顯示「示範 · 不同步」。Demo 助理的寫入本來就只存在本機快取。outbox 裡屬於真實帳號的項目保留，離開 demo 模式後才送出。

### 10.7 同步狀態

`SyncStatusStore`（App Group UserDefaults `SSSyncStatus`，可以同步讀取，改變時發 `SharedChange.syncStatus`）：

| 欄位 | 意義 |
|---|---|
| `lastSuccess[accountID]` | 那個帳號的每個行事曆都成功拉取的時間 |
| `pendingCount` | outbox 裡還在等待的項目（不含失敗的） |
| `failed` | 失敗清單（`FailedChange`：標題、做了什麼、時間、原因），`SyncEngine.retry(id)`／`discard(id)` |
| `isOffline` | 上一次連網路都沒有（請求沒離開手機） |
| `lastError` | 上一次同步的其他問題（Google 沒回應、5xx、拒絕）；需要重新連接的帳號不算，抽屜另外顯示 |
| `isDemo` | Demo 模式 |

### 10.8 下一步：伺服器推播

沒有伺服器時，Google 那邊的修改要等 App 被叫起來（前景、計時器、背景更新）才會進來；App 從來沒開的話，提醒用的是上一次同步的資料。要做到即時：

1. **每個行事曆一個 `events.watch` channel**：伺服器用該帳號的 token 呼叫 `POST /calendars/<id>/events/watch`（`type=web_hook`、自訂 `id`、`token`、HTTPS `address`）。Channel 有到期時間（`expiration`，由 Google 決定），要在到期前一天左右建立新的 channel 再 `channels.stop` 舊的；新增或移除行事曆時也要跟著建立或停止。
2. **Webhook → 增量同步 → APNs**：Google 只通知「有變動」（header `X-Goog-Channel-ID`、`X-Goog-Resource-State` 為 `sync`／`exists`／`not_exists`、`X-Goog-Message-Number`），不帶內容。伺服器收到後在伺服器端做增量同步（伺服器端可以用 `syncToken`，因為它可以保存整個行事曆的狀態），再對裝置發 **background push**（`content-available: 1`、`apns-priority: 5`），App 被叫起來跑 `SyncEngine.sync(.notification)`。iOS 會節流 background push，所以要合併短時間內的多次變動。
3. **提醒改由伺服器發 alert push**：伺服器知道事件的最新時間，就能在正確時間發提醒（含 category，讓 Content Extension 照樣能長按回覆），即使 App 從來沒開也不會錯。Live Activity 也可以用 push-to-start／update。
4. **隱私與 OAuth 的影響**：refresh token 要存在伺服器（目前只在 Keychain）。要改用 server-side OAuth（App 取得授權碼後交給伺服器換 token），token 加密存放（KMS）、移除帳號或清除資料時伺服器端撤銷並刪除，隱私權政策要寫明伺服器保存行事曆資料與 token、保存期限和刪除方式。`calendar.events` 是 sensitive scope，伺服器端保存使用者資料會影響 Google 的 App 驗證審查（Limited Use 規範）。Apple 的隱私標籤也要更新。
5. **粗估每月費用（估計值，未含 Gemini proxy，以 2025 年公開價目估算，上線前要重算）**：假設每位使用者 2 個行事曆、每天約 20 次變動、每次 webhook 約 0.2 秒 CPU 和 2–3 次資料庫操作，用 serverless（例如 Cloud Run + Firestore + Cloud Scheduler，APNs 直連免費）：

| 規模 | Webhook 次數／月 | 主要費用 | 粗估 |
|---|---|---|---|
| 1,000 位使用者 | 約 60 萬 | 多半在免費額度內；Firestore 讀寫、記錄、KMS | 約 US$5–15／月 |
| 10,000 位使用者 | 約 600 萬 | Cloud Run CPU 約 US$25、Firestore 約 US$20、記錄與監控 | 約 US$50–120／月 |

Calendar API 本身不收費，但有每日與每分鐘的配額，要依使用量申請提高。

## 11. 行程管理：抽屜的「行程」、行程清單、行程頁與備註

使用者的要求：日曆裡的每個行程都能在抽屜裡管理（例如只出現在日曆上的「瑜伽」），已結束的自動消失，新加的行程也會出現；行程頁要有「備註」欄位。程式碼：`Shared/Models/EventDigest.swift`（清單，純函式）、`Shared/Calendar/EventNotes.swift`（備註 ⇄ `description`）、`Shared/Calendar/EventEditor.swift`（修改與刪除）；畫面在 `App/Views/Events/`。

### 11.1 清單裡有什麼（`EventDigest`）

| 項目 | 做法 |
|---|---|
| 來源 | 日曆畫面用的同一份 `ScheduleViewModel.events`（`SharedStore.visibleEvents`）：隱藏的行事曆、專注模式過濾掉的不算，同一場會議只有一份，demo 模式只有 demo 行程。計畫和「先問我」的預覽（`isDraft`）不列 |
| 什麼算「正在進行或還沒開始」 | `end > now`。進行中的（`start <= now < end`，全天行程不算「進行中」，歸到「今天」）也列。清單每分鐘、以及快取每次變動（同步、助理、計畫、Siri、通知擴充、別台裝置經同步）都重新算，所以結束的行程自己消失、新的自己出現 |
| 重複行程 | 同一個 `seriesID` 只有一列，顯示正在進行的那一次，否則下一次；`occurrenceCount` 是快取裡還沒結束的次數 |
| 分區 | 進行中（重複行程也算）→ 今天 → 明天 → 這週（依「每週起始日」）→ 之後；其他重複行程在「重複行程」。用日曆天計算，所以 25 小時的夏令時間切換日（倫敦 2026-10-25）仍是一天 |
| 抽屜的短清單 | 進行中的先，然後依開始時間，最多 6 列 |
| 搜尋 | 標題、地點、備註；每個詞都要出現；不分大小寫、全形半形、重音 |
| 範圍 | 打開清單時呼叫 `ensureEvents(covering:)` 載入接下來 12 個月（第 8 節），註腳說明清單涵蓋 12 個月 |
| 重複規則的說明 | 快取裡是 Google 展開的單次（`singleEvents=true`），**沒有 RRULE**，所以由日期推回來：每天、每個工作日、每週幾（「Every Sat 09:00」「每週六 09:00」）、每 N 週、每 N 天、每月幾號、每年；停一兩週也還算每週；看不出來時顯示 `Repeats` 的翻譯。週幾的名稱跟著語言（`locale`），句型來自 String Catalog |

### 11.2 備註 ⇄ `description`（`EventNotes`）

- **讀**（mapper、outbox 疊加、Google 回傳）：`ScheduleEvent.notes` 一律是純文字。Google 日曆網頁版存的是 HTML：`<br>`、`<p>`、`</div>`、清單、標題、表格列變成換行，`<li>` 變成「• 」，`<a href="x">文字</a>` 變成「文字 (x)」（文字就是網址時只留網址），其他標籤拿掉，`&amp;` `&lt;` `&gt;` `&quot;` `&#39;` `&nbsp;` 和數字實體解碼；沒有標籤的純文字（例如「a < b」）原樣保留。前後空白去掉，連續空行最多留一行。
- **寫**：行程頁送純文字（換行保留，前後空白去掉）。清空 = 送 `"description": ""`。沒動備註就不送，所以 Google 那邊的 HTML 不會被改寫；改了才會變成純文字。
- **Smart Schedule 自己寫進 `description` 的東西**：第 2 節的來源行、建立時的 notes、計畫的目標和階段說明。Google 日曆照樣顯示（和 Artboard 5 一樣）。行程頁的備註編輯框不顯示來源行（`EventNotes.provenanceLine`），存檔時用 `EventNotes.joining` 放回第一行、空一行再接使用者的備註，所以 Google 那邊不會消失；其餘內容就是備註的一部分，照樣顯示、可以改或刪。想刪來源行要到 Google 日曆刪；沒有程式會解析它們（計畫靠 `ssPlanId`），所以刪掉不影響任何功能。助理的 prompt 不放來源行（第 11.5 節）。
- 舊版快取裡的 `notes` 可能還是 HTML（這版之前沒轉換），下次完整列出那段日期時就換成純文字；在那之前行程頁顯示時也會先轉一次。

### 11.3 修改：只送改了的欄位（`CalendarEventMapper.patch(from: EventEdit, existing:)`）

`EventEdit` 的每個欄位 nil 表示沒動；`location`、`notes` 給 `""` 或 `.some(nil)` 表示清空，`reminderMinutes` 給 `.some(nil)` 表示回到預設、`.some([])` 表示不提醒。行程頁用 `EventEdit.changes(from:to:)` 或自己比較草稿產生。

| 欄位 | PATCH body |
|---|---|
| 標題 | 空白的不送；和原本一樣不送 |
| 地點、備註 | 和原本（去掉前後空白後）一樣不送；清空送 `""` |
| 時間 | 只改開始時，長度不變；結束不晚於開始 → `EventEditError.endBeforeStart`。全天行程的 `end` 跟 `ScheduleEvent` 一樣是最後一天的隔天 00:00（`EventEdit.allDayEnd(lastDay:calendar:)`／`lastDay(ofAllDayEnd:start:calendar:)` 給日期選擇器用），只改開始時天數不變（用日曆天，跨夏令時間也對） |
| 全天 ⇄ 指定時間 | Google 的 PATCH 會**逐欄合併**物件，刪欄位要送 `null`，所以另一種格式送成 `null`：`"start": {"date": "2026-10-15", "dateTime": null}`（`GCalDateTime.clearsOtherForm`；寫進 outbox 檔案時也保留這個 null，讀回來仍然有效）。改成指定時間又沒給結束時，長度用「預設長度」。用的是預設提醒時，同時送新格式的預設提醒（全天的從當天 00:00 往前算） |
| 提醒 | 指定分鐘數、`[]`（`overrides: []` + `ssReminders: "none"`）、回到預設（預設 overrides + `"default"`）；只送 `ssReminders` 這一個 private key |

### 11.4 寫入的路徑（`EventEditor`）

| 項目 | 做法 |
|---|---|
| 入口 | `EventEditor.shared.update(_:with:scope:)`、`delete(_:scope:)`。先從快取拿最新的那份（最新 etag、是否還在等同步） |
| 「只改這次」 | PATCH 那一次（Google 存成這個系列的例外），經 `CalendarRouter.patch`：If-Match、412 時 `ConflictMerge` 重送、連不到就進 outbox |
| 「全部」 | `CalendarRouter.patchSeries`：標題、地點、備註、提醒送到 series master；新的時刻和長度在送出當下套在 master 自己的第一天（第 10.2 節）。改到別天或切換全天會改變重複規則本身 → `EventEditError.seriesDayChange`／`seriesAllDayChange`，請使用者到 Google 日曆改。完成後重抓那個行事曆的滾動視窗；時間改了的話 Google 的單次 id 會換（id 帶著原本的開始時間），回傳同一天的那一次 |
| 刪除 | 「只刪這次」刪那一次；「全部」刪 series master（快取裡這個系列的每一次一起拿掉）。Google 會放進垃圾桶 |
| 唯讀 | `CalendarInfo.isWritable`（owner、writer）。reader、freeBusyReader 的行程 `EventEditor.canEdit` 是 false，行程頁只能看（「你不能修改這個日曆裡的行程。」）；硬寫也會在送出前丟 `RouterError.readOnly`。不認得的行事曆交給 Google 判斷。預覽（`isDraft`）不能改 |
| 離線 | 進 outbox，畫面立刻顯示並標「等待同步」；`SyncStatus.pendingCount` 立刻更新 |
| 之後 | 重排提醒，發 `SharedChange.syncStatus`（日曆、清單和其他 process 重新讀快取）；App 另外更新 Live Activity |
| Demo 模式 | 只改快取裡的範例行程，不連網路（有單元測試）。「全部」改的是快取裡這個系列的每一次；之後才載入的日期範圍由 `DemoData` 產生，仍是原本的樣子；刪掉的範例系列在範圍重新載入（重新開始示範）後會回來 |
| 不做的 | 把行程搬到別的行事曆（Google 的 `events.move`）、改重複規則、邀請對象。行程頁把行事曆顯示成唯讀 |

### 11.5 助理也看得到備註

UPCOMING 和 FOCUS 的每一列在有備註時多一欄 `| notes: …`（一行、最多 300 字、不含來源行），所以「明天的飛機要帶什麼？」答得出來。`modify_event` 的 `changes.notes` 是**要加上的那一句**，App 接在原本備註的下一行（`EventNotes.appending`），不會因為模型只看到截短的備註而刪掉內容。Demo 助理認「加個備註：帶護照」「add a note: bring passport」。細節見 [`GEMINI_FUNCTION_CALLING.md`](GEMINI_FUNCTION_CALLING.md) 第 4.4 節。
