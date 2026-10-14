# Gemini Function Calling：Schema 設計

唯一的 schema 來源是 [`Shared/AI/FunctionDeclarations.json`](../Shared/AI/FunctionDeclarations.json)，App 和 notification extension 都直接讀這個檔，作為 bundle resource 載入。
驗證方式：`python3 -I scripts/validate_schema.py --print-payloads`（lint、fixtures、DST 參考測試）。

## 1. 為什麼拆成 8 個函式，而不是一個大函式

需求是「一個 schema 同時處理單一事件和長期計畫」。實作上用的是**一組 toolset**，由模型自己選要呼叫哪一個：

| 函式 | 負責的情境 | 設計重點 |
|---|---|---|
| `create_events` | 一句話裡有 1 到 20 個具體事件，也可以帶簡單的重複規則 | `events[]` 陣列，一句話寫入多筆 |
| `create_long_term_plan` | 跨度超過 2 週的目標：「半年變壯」「三月前考到 IELTS 7.5」 | 分階段 `phases` 和 `sessions` 樣板，加上 `daily_nudge`、`milestones`。只產生**草稿**給使用者審閱；修改時再呼叫一次，帶上**完整**的修訂版（見第 5 節） |
| `modify_event` | 「延後 30 分鐘」「改到四點」「加個備註：帶護照」 | `event_id` 只能取自 UPCOMING 或 FOCUS；`changes.notes` 只放**新加的**那句備註，App 接在原本的備註下面（見第 4.4 節） |
| `delete_events` | 取消事件或整個計畫 | 支援 `plan_id`；批次刪除由 App 要求使用者確認 |
| `query_schedule` | 「Show me my schedule for today」（Artboard 4） | 只讀，回傳區間讓 UI 跳轉 |
| `confirm_plan` | 使用者對畫面上的草稿計畫或「等你確認的行程」說「好」「looks good」或「不要了」 | `decision`：`add` 或 `discard`。只有 prompt 裡有 DRAFT PLAN 或 PENDING EVENTS 區塊時才能呼叫；兩個都有時，套用在比較新的那個 |
| `reply_to_user` | 缺資訊時追問，或婉拒 | `suggested_replies` 讓使用者一鍵回答 |
| `update_preferences` | 「以後」「從現在開始」「別再」「always」這類**長期**指示：「8 點前不要提醒我」「健身提前 2 小時提醒」「以後用學校帳號」 | `changes[]`（`key` 是 18 個固定值之一，`value` 依 key 編碼）+ `summary_for_user`。只改設定，不碰行事曆；App 顯示「設定已更新」卡片並提供復原（見第 10 節） |

不做成一個大函式加 `oneOf` 的理由：
1. **分流更準。** 函式名稱和描述本身就是分類器。「健身半年」和「明天開會」的參數結構完全不同，硬塞進同一個物件會讓模型在必填欄位之間猶豫，產生半成品的呼叫。
2. **Schema 深度。** `oneOf` 和深層巢狀是 Gemini 回傳格式錯誤的常見原因。本設計最深只有 5 層（validator 會印出深度）。
3. **驗證和執行可以各自獨立**，每個函式各對應一個 Swift `Decodable`（`Shared/Models/AssistantDrafts.swift`）。

## 2. 關鍵設計決策

| 決策 | 原因 |
|---|---|
| `functionCallingConfig.mode = "ANY"` | 每一輪都**一定**是結構化呼叫，純聊天走 `reply_to_user`。解析結果可預測，不需要處理自由文字 |
| 時間一律輸出**本地牆上時間** `YYYY-MM-DDTHH:mm`（不帶 offset、不帶 Z） | 模型最常犯的錯是算 offset，尤其跨夏令時間時。由 client 加上 IANA `timeZone`，交給 Google 展開，DST 就不會出錯（見 Calendar 文件第 3 節） |
| `sessions` 攤平，用 `phase_index` 指回所屬階段，不巢狀在 `phases` 底下 | 減少 2 層巢狀，降低格式錯誤率 |
| `summary_for_user` 放在函式參數裡 | 模型解析的同時也把要回給使用者的話寫好了，**一次 round trip** 就完成，不用執行完再呼叫第二次產生回覆，大約省 1 秒。內容只寫 1–2 句（見第 6 節） |
| `create_events` 的確認由 client 產生 | 同上。聊天裡顯示成確認列（`Reply.addedEvents`），文字版是「Added: 標題 · 日期 時間」，給 Siri、通知和 VoiceOver 用 |
| `reminder_minutes` 「省略就用預設值」 | 只有使用者對**這一個**行程要求提醒時才填。預設值是使用者的設定（prompt 的 PREFERENCES 區塊），由 `ReminderPolicy(preferences:)` 套用 |
| `assumptions[]` | 把模型做的假設（「假設你是初學者」「假設平日晚上有空」）攤開給使用者看，讓他能修正 |
| UPCOMING 區塊（`id \| title \| start \| end \| flags`，有備註時再加 `\| notes: …`） | 一次提供四種資訊：衝突偵測、`modify` 和 `delete` 要用的 id 來源、`plan=` 對照，以及行程的備註（使用者問「護照帶了沒」「那個會要準備什麼」時看得到）。標題和備註裡的 `\|` 和換行會先移除，防止 prompt injection；備註縮成一行、最多 300 字（`AssistantPrompt.notesLimit`），Smart Schedule 自己寫的來源行（「由 Smart Schedule 智慧助理自動排程：…」）不放進去 |

## 3. 實際送出的 request（簡化版）

```http
POST {GEMINI_BASE_URL}/models/{GEMINI_MODEL_ID}:generateContent
x-goog-api-key: <dev only — production goes through proxy>
```
```json
{
  "systemInstruction": { "parts": [{ "text": "You are Smart Schedule ...\n# Clock\nnow_local: 2026-10-13T10:15 (Tuesday)\ntime_zone: Europe/London (currently UTC+1.0)\n...\n# UPCOMING / BUSY (id | title | start | end | flags | notes: … when the event has notes)\nss0k3p | Online meeting with Joe | 2026-10-13T15:30 | 2026-10-13T16:30 | event | notes: Product quality review" }] },
  "contents": [
    { "role": "user", "parts": [{ "text": "I want to be muscular in 6 month design me a daily routine" }] }
  ],
  "tools": [{ "functionDeclarations": [ "...FunctionDeclarations.json..." ] }],
  "toolConfig": { "functionCallingConfig": { "mode": "ANY" } },
  "generationConfig": { "thinkingConfig": { "thinkingLevel": "low" } }
}
```

完整的 system prompt 在 [`Shared/AI/AssistantPrompt.swift`](../Shared/AI/AssistantPrompt.swift)。

## 4. 回傳範例

### 4.1 單一事件
Fixture：[`Tests/fixtures/create_events.single.json`](../Tests/fixtures/create_events.single.json)
```json
{ "functionCall": { "name": "create_events", "args": {
  "events": [{ "title": "與Joe開會", "start": "2026-10-14T14:00", "duration_minutes": 60,
               "kind": "event", "add_video_conference": true }] } } }
```

### 4.2 長期計畫拆解：「I want to be muscular in 6 month…」
Fixture：[`Tests/fixtures/create_long_term_plan.muscle.json`](../Tests/fixtures/create_long_term_plan.muscle.json)

模型輸出的是一個**程式**，不是 104 筆事件：

```
Foundation   2026-10-14 → 2026-11-30   Full body A (MO,TH 18:30, 60m) · Full body B (TU,FR 18:30, 60m)
Hypertrophy  2026-12-01 → 2027-02-28   Upper (MO,TH) · Lower (TU,FR)
Strength     2027-03-01 → 2027-04-13   Strength upper/lower (70m)
daily_nudge  07:30 "Protein 1.6 g/kg + 8h sleep today…"
milestones   每月 14 日 check-in（全天、提醒時間是前一天 09:00）
```

使用者按下 Add 之後，client 端才由 `CalendarEventMapper.events(fromPlan:)` 展開成 **6 個 RRULE series 加 6 個 milestone**，一共 12 次 API 寫入。如果逐日建立事件，6 個月每週 4 次大約是 104 次寫入。逐日建立還有一個問題：使用者說「把健身全部改到晚上」時，要 patch 104 筆；用 series 只要 patch 6 個 master。

validator 會印出實際的 Google payload，例如：
```
"start": {"dateTime": "2026-10-15T18:30:00", "timeZone": "Europe/London"}
"recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20261130T235959Z"]
```
注意第一次上課是 **10/15（四）**，不是計畫開始的 10/14（三），因為 DTSTART 對齊到第一個符合 BYDAY 的日子（RFC 5545 規定 DTSTART 本身一定算一次）。

### 4.3 在通知裡回「延後 30 分鐘」
Fixture：[`Tests/fixtures/modify_event.push.json`](../Tests/fixtures/modify_event.push.json)。FOCUS 區塊已經告訴模型「it」指的是哪個事件，所以使用者不用說出事件名稱。

### 4.4 「加個備註：帶護照」
Fixture：[`Tests/fixtures/modify_event.add_note.json`](../Tests/fixtures/modify_event.add_note.json)。
```json
{ "name": "modify_event", "args": { "event_id": "ssfl1ght", "changes": { "notes": "帶護照" } } }
```
行程的「備註」就是 Google 行程的 `description`（純文字，見 [`GOOGLE_CALENDAR_SYNC.md`](GOOGLE_CALENDAR_SYNC.md) 第 11 節），使用者在行程頁可以直接編輯。助理這邊的規則：

| 項目 | 做法 |
|---|---|
| 模型看到什麼 | UPCOMING 和 FOCUS 的每一列在有備註時多一欄 `notes: …`：一行、最多 300 字（太長以「…」結尾），換行變成 ` / `，`\|` 變成 `/`，Smart Schedule 寫的來源行不放 |
| `changes.notes` 的意思 | **只放新加的那句**（schema 的 description 寫明）。App（`CalendarEventMapper.patch(from:existing:)`）把它接在原本備註的下一行（`EventNotes.appending`；同一句已經有了就不重複），PATCH 送出整段 `description` |
| 為什麼不讓模型送「整段新的備註」 | 模型只看到截短的一行，要它重寫整段一定會弄丟 300 字以後的內容和原本的換行。用「追加」就不可能誤刪；要改寫或清空備註，使用者在行程頁直接編輯 |
| 衝突 | 跟其他欄位一樣：PATCH 帶 If-Match，412 時 `ConflictMerge` 只重送使用者這次改的欄位 |
| Schema | `modify_event.changes.notes` 原本就有，沒有新增欄位，只補上 description；validator 和 fixture 照常通過 |

Demo 模式（`DemoAssistant`）不經過 Gemini，自己認「加個備註：…」「備註：…」「看牙醫加備註 帶健保卡」「add a note: …」「add a note to the dentist: …」「note: …」：加到通知提醒的那個行程（FOCUS），否則是句子裡點名的行程，否則是這段對話剛新增、移動或加過備註的行程；都沒有就問「要把備註加到哪個行程？」。「明天下午 3 點開會，備註：帶簡報」這種前面有時間的句子仍然是新增行程。

## 5. 長期計畫先審閱再寫入：草稿 → Add / Keep editing

計畫一次就是幾十到上百個行程，所以 `create_long_term_plan` **不會直接寫進 Google Calendar**，而是先讓使用者看過：

```
使用者：「半年內練出肌肉」
  → create_long_term_plan（revision 1）
  → App 存成 PlanDraft（SharedStore.pendingPlan），顯示計畫卡片 + 日曆上的預覽（預覽行程的 id 以 draft- 開頭，從不寫入任何地方）
     ┌ [Add]          → commitPlan → 寫入 Google（RRULE series + milestones + 晨間提醒）
     └ [Keep editing] → 「What would you like to change?」+ 4 個建議
          使用者：「改成早上 7 點」
          → create_long_term_plan（revision 2，完整的修訂版、同一個 plan id）
          → 舊卡片標成「Replaced by revision 2」，新卡片再次顯示 Add / Keep editing
打字也可以：「好」「looks good」「加入」→ confirm_plan add；「不要了」「cancel the plan」→ confirm_plan discard
```

| 環節 | 做法 |
|---|---|
| 草稿 | `PlanDraftBuilder` 先用真正的 mapper 驗證參數（寫不進去的計畫在審閱前就失敗），算出 `writeCount`，再用 `RecurrenceExpander` 把每個 weekly series 展開成預覽：整個計畫或 26 週，取較短者。預覽以牆上時間展開，跨夏令時間也維持 18:30 |
| 回給 Gemini 的結果 | `{"ok": true, "status": "draft_shown_for_review", "plan_id": …, "revision": n}`。這時 Google Calendar 裡什麼都沒有 |
| 修訂 | 有待審草稿時，system prompt 多一個 `# DRAFT PLAN (… revision N)` 區塊（標題、日期、階段、每個 session 的星期/時間/長度、milestones、nudge），並規定：修改就再呼叫一次 `create_long_term_plan`，帶上**完整**計畫、保留 `plan_title`；同意就 `confirm_plan add`；放棄就 `confirm_plan discard`。修訂沿用同一個 plan id，`revision` 加 1 |
| Add | 按鈕直接呼叫 `commitPlan(draft)`，不經過 Gemini：重新解碼草稿裡原樣保存的 args（`argsJSON`），以 `planID = draft.id` 寫入。event id 由 plan id 決定，重按 Add 只會得到 409，不會重複。之後在對話歷史補一句「[app] The user tapped Add…」，讓下一輪知道計畫已經在日曆上 |
| 跨 process | 草稿存在 App Group，App、Siri 和通知 extension 看到的是同一份 |
| 單一事件 | `create_events` 不變，照樣立刻寫入 |

Demo 模式（`DemoAssistant`）走同一個流程：計畫先變成草稿；有草稿時，「好 / looks good」會加入、「不要了 / cancel the plan」會丟棄，其他訊息當成修改要求（`7am`、`mornings`、`MWF`、`weekdays`、`3 days a week`、`週一三五`、`45 min`、`shorter`、`next Monday`、`Nov 1`），看不懂就問「What would you like to change?」並附上 4 個建議。

Fixtures：[`create_long_term_plan.revision.json`](../Tests/fixtures/create_long_term_plan.revision.json)（肌肉計畫改到早上 7 點，`revises` 指向原始 fixture）、[`confirm_plan.add.json`](../Tests/fixtures/confirm_plan.add.json)。

## 6. 回覆怎麼寫、怎麼顯示（可讀性）

使用者回報過一段難讀的回覆：「Phase 1 (Oct 14–Nov 30): full body Tue/Thu 18:30 and Sat 11:00, 60 min. Phase 2 …」。問題是同一句塞了太多事實、用斜線縮寫，而且卡片上的表格又把同樣的內容再說一次。現在分成兩邊處理：

**模型怎麼寫**（`AssistantPrompt` 的 `# Writing style` 區塊，加上 `summary_for_user` 和 `reply_to_user.message` 的 schema 描述）：

| 規則 | 例子 |
|---|---|
| `summary_for_user` 只寫 1–2 句：計畫要達成什麼、每週的量。**不列**星期、時間、階段、檢查點、提醒（App 會畫成表格） | 「6 個月增肌計畫：每週練 3 次，每次約 1 小時。」/ "A 6-month muscle plan: 3 workouts a week, about an hour each." |
| `reply_to_user.message` 最多 2 句短句，一次只問一個問題 | 「要幾點開始？」 |
| 一句只講一件事；不用斜線或「Tue/Thu」這類縮寫，把星期寫出來 | 「週二和週四」、"Tuesday and Thursday" |
| 用使用者寫的語言回覆，時間一律 24 小時制 | 18:30 |

`scripts/validate_schema.py` 會檢查 fixture 的 `summary_for_user` 最多 2 句、沒有時間、沒有斜線。

**App 怎麼顯示**：能用結構化資料的地方就不用長句子。`ReplyFormatter` 的字串是給 Siri、通知和 VoiceOver 的簡短文字版。

| 回覆 | 聊天裡顯示 | 文字版（`Reply.text`） |
|---|---|---|
| 計畫草稿 | 計畫卡片：標題、日期範圍、1–2 句摘要、每週課表（每個階段一組，每列「週二 · 週四　18:30　60 分鐘　課程名稱」）、每天提醒、每月檢查、收合的假設 | 摘要 + 一句「點加入或繼續修改」 |
| 修訂 | 新的計畫卡片；舊卡片顯示「已由第 N 版取代」 | 一句說明改了什麼（示範模式：「已改成每週一、三、五 07:00。」）+ 摘要 |
| 新增行程 | 確認列（`Reply.addedEvents`）：打勾、「已加入 Google 日曆」、標題、「10月14日（週三）14:00–15:00」 | 「Added: 標題 · 日期 時間」，多筆時每筆一行「• 」 |
| 查詢行程 | 行程表（`Reply.agenda`，型別 `AgendaDigest`）：標題「今天 · 10月15日（週四）」，每列「12:30　午餐」 | 標題 + 每列「• 12:30  午餐」；沒有行程時是「沒有行程」 |

日期依 UI 語言格式化（`ReplyFormatter.dayLabel` / `shortDate` / `when`），時間一律 `HH:mm`（`ReplyFormatter.clockTime`）。

**語言**：UI 和 template 字串都在 `Shared/Localization/Localizable.xcstrings`（String Catalog，source language 是英文，加上 zh-Hant 翻譯）。App 和兩個 extension 都把它當 resource，各自從自己的 bundle 讀。模型的回覆則跟著使用者輸入的語言走；示範模式（`DemoAssistant`）也一樣：輸入中文就用中文回。validator 會確認每個 key 都有 zh-Hant 翻譯、格式參數（`%@`、`%lld`，順序不同時用 `%1$@`）一致，而且原始碼裡每個 `String(localized:)` 都在 catalog 裡。

## 7. 多輪對話與 Gemini 3 的 thought signature

- 模型那一輪的 content（包含 `thoughtSignature`）以 **raw JSON 原樣保存**，下一輪原封送回。這是 Gemini 3 function calling 的硬性規定，少了會回 400。
- 歷史紀錄以「exchange」為單位修剪（使用者發話、模型回覆、function responses 三個一組），最多保留 6 組。這樣 `functionCall` 和它對應的 `functionResponse` 永遠不會被拆開。
- 執行出錯時，也會回傳一個 `functionResponse`，內容是 `{"ok": false, "error": ...}`，讓模型下一輪可以自我修正。

## 8. 送資料給 Gemini 之前：AI 資料分享同意

App Store 審查規則 5.1.2(i)（2025 年 11 月）：把個人資料分享給第三方 AI 之前，必須先說明並取得同意。

- **唯一的關卡在 `GeminiClient.generate`**：一開始就檢查 `AIConsentStore.current.isGranted`，沒有同意就丟出 `GeminiError.consentRequired`，連 request 都不會組。聊天、快速輸入、Siri、通知裡的回覆、notification extension 全都經過這裡，所以一個關卡就涵蓋全部入口。單元測試用注入的 `consentCheck` 和一個會計數的 `URLSession` 證明沒有任何 request 送出。
- 同意存在 App Group 的 `UserDefaults`（key `SSAIConsent`，JSON），三個 process 都能同步讀到；寫入時發 `SharedChange.consent`。
- 說明文字只有一份：`AIConsentDisclosure`（標題、會送出的 4 類資料、收件者「Google，透過 Gemini API」、註腳）。同意畫面和「設定 › AI 與隱私 › 會送出什麼」都用它。說明內容有重大改變時把 `AIConsent.disclosureVersion` 加 1，所有人會被重新詢問。
- **絕對不要寫「不會被用來訓練」**：這只在 Gemini 付費方案成立。上線檢查清單：在 Gemini API 專案啟用 Cloud Billing（付費方案）。免費方案下 Google 可能用 prompt 改善產品。
- 示範模式（`DemoAssistant`）不呼叫 Gemini，不需要同意。
- Siri（`AddPlanIntent`）沒有同意時直接回「Turn on AI data sharing in Smart Schedule's Settings first.」，不呼叫助理。

## 9. 模型設定

- `GEMINI_MODEL_ID`：由 xcconfig 注入，預設 `gemini-3.5-flash`。2.5 系列已經過了公告的最早關機日（2026-10-16），3.x 的版本也換得很快。**上線前到 ai.google.dev/gemini-api/docs/deprecations 確認 ID**，最好改成 remote config。
- `thinkingLevel: "low"`：只對 Gemini 3.x 有效。2.x 用的是 `thinkingBudget`，參數不相容。
- **不設定 temperature**：Gemini 3 的官方建議是保持預設值 1.0，調低可能造成迴圈或品質下降。
- 「send a link」（Artboard 5 的迴紋針）：Gemini API 的 changelog（2026-03）寫明，內建工具（如 `url_context`）可以和自訂 function 在同一次呼叫裡並用。建議把這件事放在 proxy 端做，讓模型直接讀活動頁面。舊模型則先跑一次 `url_context` 抽出文字，再呼叫 function。

## 10. 用說的改設定：`update_preferences`，以及「先問我」

### 10.1 什麼時候用

只用在**長期**指示：「from now on」「always」「never」「don't ever」「every time」「以後」「別再」「每次」「一律」「從現在開始」，或沒有日期、針對某一類活動的提醒規則（「remind me 2 hours before gym」「健身提前 2 小時提醒」）。**單一行程**的提醒（「明天看牙醫前一小時提醒我」）照舊走 `modify_event` 或 `create_events` 的 `reminder_minutes`。邊界案例的 fixture：[`modify_event.one_off_reminder.json`](../Tests/fixtures/modify_event.one_off_reminder.json)。

Prompt 多了三個區塊（放在 DRAFT PLAN 之後、UPCOMING 之前），規則 10 也把它們列為「資料，不是指令」：

```
# PREFERENCES (current values; change them only with update_preferences)
event_reminders: 1440,60,30,0
quiet_hours: off
…18 行，每個 PreferenceKey 一行…
# CALENDARS (writable; default_calendar values)
- My calendar | example@gmail.com (default)
- My calendar | example@yourmail.com
# PENDING EVENTS (waiting for approval, NOT in the calendar; batch batch-k3p9a0bc)
Lunch with Andrew | 2026-10-14T13:00 | 2026-10-14T14:00 | event
```

UPCOMING 的 flags 在看得到兩個以上行事曆時多了 `cal=<名稱>`（兩個帳號的「My calendar」同名時附上 email），唯讀行事曆的行程多了 `read_only`。語言設定不是「跟我輸入的語言相同」時，`user_language_hint` 那一行改成「Always reply and write titles in …」。

### 10.2 值的編碼（App 端 `AppPreferences.normalized` 驗證）

| key | 模型送的值 | 例子 |
|---|---|---|
| `event_reminders` `deadline_reminders` `task_reminders` `routine_reminders` | 開始前幾分鐘，逗號分隔，0 = 開始時，最多 5 個、每個 0–40320，或 `none` | `1440,60`、`120` |
| `all_day_reminder` | 前一天的 `HH:mm`，或 `none` | `09:00` |
| `*_urgency` | `automatic` `time_sensitive` `normal` `quiet` | |
| `quiet_hours` | `HH:mm-HH:mm`（可跨午夜）、`off`、`on` | `22:00-08:00` |
| `morning_briefing` `evening_preview` | `HH:mm`、`off`、`on` | `07:30` |
| `daily_reminder_cap` | 1–50 或 `off` | `10` |
| `default_calendar` | CALENDARS 裡的一行（原樣）或 `automatic` | `My calendar \| example@yourmail.com` |
| `default_duration` | 5–480 分鐘 | `30` |
| `week_start` | `sunday` `monday` | |
| `reply_language` | `match` `zh-Hant` `en` | |
| `autonomy` | `add_directly` `ask_first` | |

「8 點前不要提醒我」= `quiet_hours` 結束在 08:00，開始時間保持目前的設定（安靜時段關著時用 22:00）。安靜時段裡的提醒**照樣送達**，只是靜音。

### 10.3 執行、回覆、復原

1. 解碼 `UpdatePreferencesArgs`（`value` 送成數字也接受）；不認得的 key 直接拒絕（`unknown key`），不是解碼失敗。
2. `PreferencesStore.apply(…, source: .voice(utterance:), resolveCalendar:)`：一次寫入所有有效的變更，`default_calendar` 透過 `AccountStore.resolveWritableCalendar(matching:)` 找到可寫入的行事曆。值和目前一樣的變更直接略過。
3. `Reply.preferenceReceipt` 讓聊天顯示「設定已更新」卡片（舊值 → 新值，加上「復原」）；`Reply.rejectedPreferences` 列出被拒絕的項目。`Reply.text` 是 `summary_for_user`，加上 `ReplyFormatter.preferencesUpdated` 和 `preferencesRejected` 的文字版（給 Siri、通知、VoiceOver；聊天畫面畫卡片時會拿掉）。
4. 改到提醒、緊急程度、安靜時段、摘要或每日上限時，馬上 `ReminderScheduler.reschedule`。
5. 回給 Gemini：`{"ok": <沒有被拒絕>, "applied": [{"key","old","new"}], "rejected": [{"key","value","reason"}]}`。

每一筆變更都記進「助理記得的事」（設定 › AI 與隱私），來源寫「你說：「…」」；刪掉那一行就把該設定恢復預設。

示範模式（`DemoAssistant`）在**所有其他判斷之前**先檢查這類句子，所以「8 點前不要提醒我」不會變成 08:00 的行程。離線支援：「8 點前不要提醒我」「早上 8 點以前別提醒我」「don't remind me before 8am」「10 點後別提醒我」→ `quiet_hours`；「健身提前 2 小時提醒」「以後健身都提前兩小時提醒我」「remind me 2 hours before gym」→ `routine_reminders` `120`（句子裡有日期或時間就不算）；「別再提前一天提醒截止日」→ 從截止日的預設提醒拿掉 1 天；「以後用學校帳號」「from now on use my school account」→ 示範的學校行事曆；「以後會議預設 30 分鐘」→ `default_duration`；「以後用英文回覆」「always reply in Chinese」→ `reply_language`；「以後先問我再加」「ask me before adding events」→ `autonomy`。示範模式一樣經過 `PreferencesStore.apply`，所以驗證、紀錄和復原都相同。

Fixtures：[`update_preferences.quiet_hours.json`](../Tests/fixtures/update_preferences.quiet_hours.json)、[`update_preferences.routine_reminders.json`](../Tests/fixtures/update_preferences.routine_reminders.json)、[`update_preferences.default_calendar.json`](../Tests/fixtures/update_preferences.default_calendar.json)。fixture 可以帶 `preferences` 和 `calendars` 兩個字串，模擬 prompt 裡的 PREFERENCES 和 CALENDARS 區塊。

### 10.4 「先問我」：單一行程先不寫入

「加入行程」設成「先問我」時，`create_events` 照樣把每個行程 map 過一次（日期錯誤在這裡就會被擋下），但**不寫入**：

- 存成 `PendingEventBatch`（`SharedStore.pendingEventBatch()`，App Group 的單一欄位，App、Siri、通知 extension 共用）：原樣保存的 args、這次 request 的 seed、目標行事曆（`CalendarRouter.defaultTarget()`）和預覽行程（id 是 `draft-ev-<batch>-<n>`，跟計畫預覽一樣畫成虛線）。新的 batch 會取代舊的。
- 回給 Gemini：`{"ok": true, "status": "awaiting_user_approval", "count": n}`；`Reply.pendingEvents` 讓聊天顯示「還沒加入行事曆」卡片（加入／編輯）。
- 按「加入」→ `commitPendingEvents(batch)`：用同一個 seed 重新 map args，所以 Google event id 跟第一次一樣，重按只會得到 409，不會重複；寫到 batch 的目標行事曆（不能寫了就改用目前的預設），清掉欄位。之後在對話歷史補一句「[app] The user tapped Add…」。
- 打字也可以：有 PENDING EVENTS 區塊時，「好」「add them」→ `confirm_plan add`，「不要了」→ `discard`，要修改就再呼叫一次 `create_events` 帶完整的新清單。
- 長期計畫不受這個設定影響，一律先審閱（第 5 節）。

### 10.5 寫入走 `CalendarRouter`

多帳號之後，助理的每一次寫入都經過 `CalendarRouter`：新行程寫到預設行事曆（設定或 `default_calendar` 選的，否則第一個帳號的「我的行事曆」）；修改和刪除寫到擁有那份行程的帳號和行事曆；`delete_events` 的 `plan_id` 會在每個可寫入、有同步的行事曆裡找 series master。`PendingDeletion.refs` 記住每個 id 屬於哪個行事曆，確認刪除時照著刪。偏好、時鐘和 mapper 每次 request 都重新讀，設定一改下一句就生效。

## 11. 本地驗證

```bash
python3 -I scripts/validate_schema.py --print-payloads
```
- Lint 只允許 Gemini OpenAPI subset 支援的 key；檢查 `required` 是否都存在、`enum` 是否只用在 string 上、陣列是否都有 `items`。
- 用 JSON Schema 驗證 `Tests/fixtures/*.json` 裡的 `expected_call`。
- Python 參考版的 mapper 會重算 RRULE、UNTIL（UTC）和 DTSTART 對齊，並 assert 倫敦 GMT 和 BST 的邊界值。
- 草稿預覽的參考展開（`--print-payloads` 會印出每個計畫 fixture 的預覽數量），並 assert 18:30 在兩次夏令時間切換前後都不變。
- `confirm_plan` 的 fixture 必須帶 `draft_plan`；帶 `revises` 的 fixture 必須是 `create_long_term_plan`，而且保留原本的 `plan_title`。
- 回覆寫法：fixture 的 `summary_for_user` 最多 2 句、不列時間、不用斜線（第 6 節）；`update_preferences` 的 `summary_for_user` 只能 1 句。
- `update_preferences`：每個 key 只能出現一次，`value` 符合該 key 的編碼（第 10 節表格）；`default_calendar` 的值必須是 fixture `calendars` 裡的一行。`confirm_plan` 的 fixture 要有 `draft_plan` 或 `pending_events`；`modify_event` 的 `event_id` 必須出現在 fixture 的 `upcoming` 或 `focus_event`（列裡的 `| notes: …` 不影響比對，例如 `modify_event.add_note.json`）。
- String Catalog：每個 key 都有 zh-Hant 翻譯、格式參數一致，原始碼裡的每個 `String(localized:)` 都在 catalog 裡。
