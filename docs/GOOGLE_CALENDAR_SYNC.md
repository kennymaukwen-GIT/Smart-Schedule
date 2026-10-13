# Google Calendar 整合：從 Gemini JSON 寫進行事曆，再同步回來

程式碼位置：`Shared/Calendar/`（mapper、RRULE、client、sync）、`Shared/Auth/GoogleTokenProvider.swift`、`App/Auth/GoogleSignInCoordinator.swift`

## 1. OAuth 設定

1. Google Cloud Console：啟用 **Google Calendar API**。
2. OAuth consent screen：加入 scope `https://www.googleapis.com/auth/calendar.events`，再加上 `openid` 和 `email`。
3. Credentials：建立 OAuth client ID，類型選 **iOS**，Bundle ID 填 `com.smartschedule.app`。把 client ID 和 reversed client ID 寫進 `Config/Secrets.xcconfig`。
4. 登入流程：`ASWebAuthenticationSession` 加 PKCE（S256），redirect 是 `com.googleusercontent.apps.XXX:/oauth2redirect`。iOS 類型的 client **沒有 client secret**。
5. Token 存在 Keychain 的共享 group，屬性是 `AfterFirstUnlock`，所以鎖定畫面上的 notification extension 也能自己 refresh。refresh 只是一個表單 POST 到 `oauth2.googleapis.com/token`，不需要 SDK。

**容易踩到的雷：**
- Consent screen 在 *Testing* 狀態時，refresh token **7 天後失效**，伺服器回 `invalid_grant`。`GoogleTokenProvider` 收到這個錯誤會清掉 token，UI 會重新顯示「Connect Google Calendar」。
- `calendar.events` 屬於 **sensitive scope**，正式上線要提交 Google 的 App 驗證（品牌資料、scope 用途說明、示範影片）。

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
| — | `extendedProperties.private` | `ssSource`、`ssKind`、`ssPlanId`、`ssSchema`，可以用 `privateExtendedProperty=ssPlanId=<id>` 查回整個計畫 |
| `add_video_conference` | `conferenceData.createRequest`（`hangoutsMeet`） | request 要帶 `conferenceDataVersion=1`，Meet 連結才會產生 |
| `attendees`（只接受 email） | `attendees[]` | 有受邀者時設 `sendUpdates=all`，沒有就是 `none` |

### 最終送出的 request（「明天下午兩點跟 Joe 開線上會議」）
```http
POST https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=none&conferenceDataVersion=1
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
  "extendedProperties": { "private": { "ssSource": "smart-schedule", "ssKind": "event", "ssSchema": "1" } }
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

`ReminderPolicy.minutes()` 會把數值限制在合法範圍、去除重複、由大到小排序，最多取 5 個。

**重複通知的問題：** Google 的 popup 會由 Google Calendar App 在 iPhone 上跳出，Smart Schedule 也會自己發一次有互動功能的提醒。建議的使用方式：
- iPhone 上關掉 Google Calendar App 的通知，改由 Smart Schedule 負責（因為只有它的通知能長按後原地輸入）。
- 網頁和 Android 上照常使用 Google 的 popup。
- 想讓 Google 那邊完全安靜，就把 `AppConstants.localRemindersEnabled` 和 `ReminderPolicy` 改成寫入 `overrides: []`。

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
| Google 回到 App（拉取） | `CalendarSync.refreshWindow()`：抓 −7 到 +120 天、`singleEvents=true`（重複事件展開成個別 instance）、`orderBy=startTime`、每頁 250 筆，然後**整段取代** cache。觸發時機：開到前景、寫入之後、BGAppRefresh。這種做法不需要保存狀態，結果永遠正確。視窗以外的日期在畫面捲到時才載入，見第 8 節 |
| Google 回到 App（即時） | 需要後端：`events.watch` 註冊 webhook，事件有變動時發 APNs silent push 或 Live Activity push，App 收到後再跑 `refreshWindow`。channel 會過期，要排程續約 |
| 規模變大之後 | 改用 `syncToken` 增量同步；收到 410 Gone 就全量重抓 |
| 其他人在 Google 那邊改了事件 | 下次 refresh 時，Google 的版本覆蓋本地。Google 是唯一的事實來源，App 只是 cache |

## 8. 依需求載入任意日期（無限捲動的行事曆）

Quick Capture 的 DAY / WEEK / MONTH，以及主畫面的月份列和月曆，都可以一直往前、往後捲，沒有盡頭。滾動視窗（−7 到 +120 天）以外的日期，等畫面捲到那裡才載入。程式碼：`ScheduleViewModel.ensureEvents(covering:)`、`Shared/Calendar/LoadedRanges.swift`、`Shared/Calendar/SharedStore+LoadedRanges.swift`、`CalendarSync.load(_:)`。

| 項目 | 做法 |
|---|---|
| 入口 | 畫面每次捲動停下時，把看得到的範圍傳給 `ensureEvents(covering:)`。`focus(_:)`（助理要求顯示某段日期、按「今天」）也會呼叫，所以跳到好幾年後也會載入 |
| 範圍 | 看得到的範圍碰到的整個月份，前後再各加一個月（`LoadedRanges.request`），下一兩次滑動已經在 cache 裡。範圍超過 12 個月時只取前 12 個月，一次呼叫不會抓幾十年 |
| Request | 只抓缺少的部分（`LoadedRanges.missing`），每段一個 `events.list`：`timeMin`/`timeMax` 是缺少的那段，`singleEvents=true`、`orderBy=startTime`、每頁 250 筆，跟滾動視窗一樣 |
| Debounce | 最後一次呼叫後 300 ms 才開始。快速滑過的中間位置不會發 request。300 ms 內來自不同行事曆的範圍（例如主畫面月曆和 Quick Capture）最多保留最近 3 個，都會載入 |
| 去重 | 已經載入的範圍（App Group 裡的 `loadedRanges` 加上滾動視窗）和正在載入的範圍都會跳過。兩次載入同時開始時，在同一個 MainActor 步驟裡先查再登記，所以不會抓同一個月兩次 |
| 不擋畫面 | 載入在獨立的 `Task` 裡跑，下一次呼叫只會取消 debounce，不會中斷已經送出的 request。載入期間 `isLoadingRange` 為 true，畫面可以顯示細小的進度提示 |
| 寫入 cache | `SharedStore.mergeRange`：取代該範圍內的事件；同一個 id 在別的日期的舊副本（事件被移動了）一起移除。**不動 `windowStart`、`windowEnd`、`lastRefresh`**，提醒排程、Live Activity 和滾動同步都照舊 |
| 錯誤 | 不影響畫面：cache 保留原本的資料，範圍不標記為已載入，下次再顯示時重試。只有 token refresh 失敗會把 `isSignedIn` 設回 false（跟 `refresh()` 一樣） |
| 新鮮度 | 每次滾動同步（`replaceWindow`：開到前景、BGAppRefresh、助理寫入之後，不論哪個 process）都會清空 `loadedRanges`。cache 裡的事件照樣顯示，但每段範圍下次出現在畫面上時會重抓一次，所以在 Google 網頁版改的遠期事件也會同步回來。`reloadFromCache()` 會馬上重抓目前畫面上的範圍；本月月曆第一列落在視窗開始之前的那幾天也是這樣補上的 |
| Demo 模式 | 不連 Google。`DemoData.recurringEvents(in:)` 產生該範圍的每週項目（Gym 一三五 18:30、週一 Weekly team sync、週六 Yoga），id 是 `demo-<series>-<yyyy-MM-dd>`，不同範圍產生的同一次項目 id 相同，合併時不會重複。一次性項目（會議、午餐、旅行等）只在 seed 裡，留在相對於 seed 當天的位置。合併時用 `replacingCached: false`，demo 助理建立、修改或刪除的事件不會被蓋掉 |

### Cache 上限

App Group 的 JSON 每次讀寫都是整個檔案，三個 process 都會讀，所以要設上限。每次載入成功後，如果 cache 超過 `ScheduleViewModel.maxCachedEvents`（2000 筆，約 1 MB），就丟掉離「今天」、「最後顯示的範圍」和「待確認計畫的日期」都超過 12 個月的事件（`LoadedRanges.evict`、`SharedStore.evictEvents`），並把那些範圍從 `loadedRanges` 移除，捲回去時再重抓。

永遠不會丟的：滾動視窗、計畫預覽（`draft-` 開頭的 id）、待確認計畫的事件。Demo 模式只會丟可以重新產生的每週項目，其他 demo 事件只存在 cache 裡，丟了就沒了。

提醒不受影響：`ReminderScheduler` 從最近的觸發時間開始排，最多 64 個。被丟掉的事件都在 12 個月以外，提醒最多提前 4 週（Google 的上限），在那之前它早就回到滾動視窗（+120 天）裡、重新排上了。
