# Gemini Function Calling：Schema 設計

唯一的 schema 來源是 [`Shared/AI/FunctionDeclarations.json`](../Shared/AI/FunctionDeclarations.json)，App 和 notification extension 都直接讀這個檔，作為 bundle resource 載入。
驗證方式：`python3 -I scripts/validate_schema.py --print-payloads`（lint、fixtures、DST 參考測試）。

## 1. 為什麼拆成 6 個函式，而不是一個大函式

需求是「一個 schema 同時處理單一事件和長期計畫」。實作上用的是**一組 toolset**，由模型自己選要呼叫哪一個：

| 函式 | 負責的情境 | 設計重點 |
|---|---|---|
| `create_events` | 一句話裡有 1 到 20 個具體事件，也可以帶簡單的重複規則 | `events[]` 陣列，一句話寫入多筆 |
| `create_long_term_plan` | 跨度超過 2 週的目標：「半年變壯」「三月前考到 IELTS 7.5」 | 分階段 `phases` 和 `sessions` 樣板，加上 `daily_nudge`、`milestones` |
| `modify_event` | 「延後 30 分鐘」「改到四點」 | `event_id` 只能取自 UPCOMING 或 FOCUS |
| `delete_events` | 取消事件或整個計畫 | 支援 `plan_id`；批次刪除由 App 要求使用者確認 |
| `query_schedule` | 「Show me my schedule for today」（Artboard 4） | 只讀，回傳區間讓 UI 跳轉 |
| `reply_to_user` | 缺資訊時追問，或婉拒 | `suggested_replies` 讓使用者一鍵回答 |

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
| `summary_for_user` 放在函式參數裡 | 模型解析的同時也把要回給使用者的話寫好了，**一次 round trip** 就完成，不用執行完再呼叫第二次產生回覆，大約省 1 秒 |
| `create_events` 的確認文字由 client 用 template 產生 | 同上，而且格式固定：「Schedule set to Google Calendar on …」（Artboard 5） |
| `reminder_minutes` 「省略就用預設值」 | 模型不需要知道使用者的偏好；預設值由 `ReminderPolicy` 統一管理 |
| `assumptions[]` | 把模型做的假設（「假設你是初學者」「假設平日晚上有空」）攤開給使用者看，讓他能修正 |
| UPCOMING 區塊（`id \| title \| start \| end \| flags`） | 一次提供三種資訊：衝突偵測、`modify` 和 `delete` 要用的 id 來源、`plan=` 對照。標題裡的 `\|` 和換行會先移除，防止 prompt injection |

## 3. 實際送出的 request（簡化版）

```http
POST {GEMINI_BASE_URL}/models/{GEMINI_MODEL_ID}:generateContent
x-goog-api-key: <dev only — production goes through proxy>
```
```json
{
  "systemInstruction": { "parts": [{ "text": "You are Smart Schedule ...\n# Clock\nnow_local: 2026-10-13T10:15 (Tuesday)\ntime_zone: Europe/London (currently UTC+1.0)\n...\n# UPCOMING / BUSY (id | title | start | end | flags)\nss0k3p | Online meeting with Joe | 2026-10-13T15:30 | 2026-10-13T16:30 | event" }] },
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

Client 端由 `CalendarEventMapper.events(fromPlan:)` 展開成 **6 個 RRULE series 加 6 個 milestone**，一共 12 次 API 寫入。如果逐日建立事件，6 個月每週 4 次大約是 104 次寫入。逐日建立還有一個問題：使用者說「把健身全部改到晚上」時，要 patch 104 筆；用 series 只要 patch 6 個 master。

validator 會印出實際的 Google payload，例如：
```
"start": {"dateTime": "2026-10-15T18:30:00", "timeZone": "Europe/London"}
"recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,TH;UNTIL=20261130T235959Z"]
```
注意第一次上課是 **10/15（四）**，不是計畫開始的 10/14（三），因為 DTSTART 對齊到第一個符合 BYDAY 的日子（RFC 5545 規定 DTSTART 本身一定算一次）。

### 4.3 在通知裡回「延後 30 分鐘」
Fixture：[`Tests/fixtures/modify_event.push.json`](../Tests/fixtures/modify_event.push.json)。FOCUS 區塊已經告訴模型「it」指的是哪個事件，所以使用者不用說出事件名稱。

## 5. 多輪對話與 Gemini 3 的 thought signature

- 模型那一輪的 content（包含 `thoughtSignature`）以 **raw JSON 原樣保存**，下一輪原封送回。這是 Gemini 3 function calling 的硬性規定，少了會回 400。
- 歷史紀錄以「exchange」為單位修剪（使用者發話、模型回覆、function responses 三個一組），最多保留 6 組。這樣 `functionCall` 和它對應的 `functionResponse` 永遠不會被拆開。
- 執行出錯時，也會回傳一個 `functionResponse`，內容是 `{"ok": false, "error": ...}`，讓模型下一輪可以自我修正。

## 6. 模型設定

- `GEMINI_MODEL_ID`：由 xcconfig 注入，預設 `gemini-3.5-flash`。2.5 系列已經過了公告的最早關機日（2026-10-16），3.x 的版本也換得很快。**上線前到 ai.google.dev/gemini-api/docs/deprecations 確認 ID**，最好改成 remote config。
- `thinkingLevel: "low"`：只對 Gemini 3.x 有效。2.x 用的是 `thinkingBudget`，參數不相容。
- **不設定 temperature**：Gemini 3 的官方建議是保持預設值 1.0，調低可能造成迴圈或品質下降。
- 「send a link」（Artboard 5 的迴紋針）：Gemini API 的 changelog（2026-03）寫明，內建工具（如 `url_context`）可以和自訂 function 在同一次呼叫裡並用。建議把這件事放在 proxy 端做，讓模型直接讀活動頁面。舊模型則先跑一次 `url_context` 抽出文字，再呼叫 function。

## 7. 本地驗證

```bash
python3 -I scripts/validate_schema.py --print-payloads
```
- Lint 只允許 Gemini OpenAPI subset 支援的 key；檢查 `required` 是否都存在、`enum` 是否只用在 string 上、陣列是否都有 `items`。
- 用 JSON Schema 驗證 `Tests/fixtures/*.json` 裡的 `expected_call`。
- Python 參考版的 mapper 會重算 RRULE、UNTIL（UTC）和 DTSTART 對齊，並 assert 倫敦 GMT 和 BST 的邊界值。
