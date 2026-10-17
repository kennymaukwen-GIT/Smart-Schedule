# App Store Connect 上架資料（Smart Schedules 1.0）

可以直接貼到 App Store Connect 的文字（繁體中文和英文），以及每個問卷該怎麼填、為什麼這樣填。
每個功能說法都對照過 2026-10-16 的程式碼（`App/`、`Shared/`、`Widgets/`、`NotificationContent/`、`server/worker/`），
對照表在第 11 節。程式碼改了功能、或 AI 同意說明改版（`AIConsent.disclosureVersion`，目前是 **5**），這份文件要一起更新。

1.0 已決定的事：年齡分級 **18+**（Gemini API 條款要求年滿 18 歲）、**不賣訂閱也沒有任何 App 內購買**、
**不在歐洲經濟區（歐盟、挪威、冰島、列支敦斯登）、瑞士、香港、澳門和中國大陸上架**（英國和其他地區照常）、**Google 帳號的 email 不會傳給 Gemini**（同意說明第 4 版起）、
**不用 iOS 18 的即時動態 push-to-start**（`AppConstants.pushToStartEnabled = false`：伺服器不存任何行程、App 不用遠端推播（APNs）；同意說明第 5 版）、**開發者在英國**（不需要英國 GDPR 第 27 條的代表人）、**沒有 App 內的語音輸入**（不用麥克風和語音辨識；Siri 和鍵盤的聽寫是 Apple 的系統功能，App 只收到文字）。

`<!-- asc:… -->` 標記後面的區塊就是要貼的內容；`python3 -I <腳本> docs/app-store-metadata.md` 可以檢查字數上限
（第 12 節）。方括號 `[…]` 是送審前要填的佔位值。

---

## 0. 送審前一定要處理的事

- [ ] 把聯絡電話、測試帳號、備用驗證碼這些佔位值填好（開發者名稱已決定：SHENG HAN HSIEH，和 Apple 帳號的 Entity Name 一致）。網站（`site/public/`）的佔位值已在 2026-10-16 填好：Guideline 2.1 不接受佔位文字和打不開的網址，而 Support URL 必須通到真正的聯絡資訊。
- [ ] https://www.smart-schedules.com 的首頁、`/privacy`、`/support` 都已上線、直接回 200（三個網址在這份文件裡都會用到）。一律用 **www**：網站放在 Vercel，DNS 留在 Squarespace，只加一筆 `www` 的 CNAME；沒有 www 的根網域不提供網站（`site/README.md` §3）。
- [ ] Smart Schedules 的伺服器（`server/worker/`）已部署成正式環境：`APP_ATTEST_ENV = "production"`，`GEMINI_API_KEY` 和 `APPLE_TEAM_ID` 兩個 secret 已設定，`SESSION_MODELS` 包含這個版本的 `GEMINI_MODEL_ID`。1.0 沒有 push-to-start，所以 `crons = []`，不需要 APNs 的 `.p8` 和 `APNS_*` secrets（`server/worker/README.md`「1.0：push-to-start 關閉」）。審核期間要一直開著（Guideline 2.1：「turn on your back-end service」）。
- [ ] Gemini API 的 Google Cloud 專案已開啟 Cloud Billing（付費層級）。英國在上架範圍內，Gemini API 條款寫明「You may use only Paid Services when making API Clients available to users in the European Economic Area, Switzerland, or the United Kingdom」（[Gemini API Additional Terms](https://ai.google.dev/gemini-api/terms)；這段文字來自搜尋摘錄，送審前到條款頁再確認一次）。
- [ ] Google OAuth consent screen 已通過驗證並設為「In production」（步驟見 [`google-oauth-verification.md`](google-oauth-verification.md)）。還在 Testing 時，審核員會看到「Google 尚未驗證這個應用程式」，測試帳號也必須先加進 test users，而且 refresh token 7 天就失效。
- [ ] 價格與供應狀況已取消歐洲經濟區、瑞士、香港、澳門和中國大陸（第 4.3 節；後三個是因為 Gemini API 不在那裡提供，第 4.4 節）。
- [ ] 到 ICO 網站的「Do I need to pay the fee?」確認要不要繳資料保護費（data protection fee），金額以 ICO 網站為準（第 4.4 節第 4 點）。
- [ ] 上傳的 build 的 Info.plist 沒有 `NSMicrophoneUsageDescription` 和 `NSSpeechRecognitionUsageDescription`（`plutil -p SmartSchedule.app/Info.plist | grep -E 'NSMicrophone|NSSpeech'` 什麼都不印）：1.0 沒有麥克風和語音辨識，App 隱私問卷也不勾 Audio Data（第 5.3 節）。

---

## 1. App 資訊（App Information，不分語言）

| 欄位 | 填什麼 | 說明 |
|---|---|---|
| Bundle ID | `com.smartschedules.app` | `project.yml` |
| SKU | `[例如 smart-schedule-ios]` | 只給自己看，之後不能改 |
| 主要語言（Primary Language） | English (U.S.) | 沒有對應語系的店面會顯示主要語言；英文比中文適合當全球的預設。再加一個 Chinese (Traditional) 語系。英文文字是美式拼法；如果另外加 English (U.K.) 語系，同一份要改兩處：關鍵字的「organizer」改成「organiser」，描述的「Control Center」改成「Control Centre」（Apple 英式介面的名稱）。 |
| 類別（Category） | 主要：**Productivity（生產力）**；次要：**Business（商務）** | 行事曆和待辦都在 Productivity。次要也可以選 Utilities（工具程式）。不要選 Health & Fitness：長期計畫雖然能排健身課，但 App 本身是行事曆工具。 |
| 內容版權（Content Rights） | 「Yes, it contains, shows, or accesses third-party content」並勾選有權使用 | App 讀取並顯示使用者自己的 Google 日曆（經使用者授權、依 Google API 條款），也顯示 Gemini 產生的文字。 |
| 年齡分級（Age Rating） | **18+**（問卷算出來比較低，用「Override to Higher Age Rating」調高） | 第 6 節 |
| 授權合約（License Agreement） | Apple 標準 EULA | App 內「使用條款」連到 Apple 的標準 EULA（`SSTermsURL`） |
| 隱私權政策網址（Privacy Policy URL） | `https://www.smart-schedules.com/privacy` | 和 App 內 設定 › 關於 › 隱私權政策（`SSPrivacyURL`）相同 |
| 使用者隱私選項網址（User Privacy Choices URL，選填） | `https://www.smart-schedules.com/support#en-delete`（中文頁面用 `#zh-delete`） | 說明怎麼刪除資料、移除帳號、撤回 AI 同意 |

App 是 iPhone 專用（`TARGETED_DEVICE_FAMILY: "1"`、只支援直向、只有深色介面），最低 iOS 18.0。

---

## 2. 繁體中文（Chinese, Traditional）產品頁

台灣的 App Store 用這個語系（1.0 不在香港和澳門上架，見第 4.3 節）。用語跟 App 的繁體中文介面一致（行事曆、行程、動態島、即時動態、快速輸入、先問我、助理記得的事）。

### 2.1 名稱（Name，最多 30 字元）

<!-- asc:zh-Hant/name -->
```text
Smart Schedules
```

「Smart Schedule」（沒有 s）在 App Store 已經有人用，所以名稱是「Smart Schedules」，和主畫面上的 App 名稱（`CFBundleDisplayName`）、網站首頁、Google 同意畫面的 App name 完全一樣，符合 Guideline 2.3.8「名稱要相近」。

想在名稱裡多放用途說明時的備用名稱（都以「Smart Schedules」開頭；在 App Store Connect 改名稱時會檢查能不能用）：

<!-- asc:zh-Hant/name.backup1 -->
```text
Smart Schedules：AI 行程助理
```

<!-- asc:zh-Hant/name.backup2 -->
```text
Smart Schedules 智慧行程助理
```

### 2.2 副標題（Subtitle，最多 30 字元）

<!-- asc:zh-Hant/subtitle -->
```text
一句話排好行程，準時提醒你
```

### 2.3 宣傳文字（Promotional Text，最多 170 字元，隨時可改、不用送審）

<!-- asc:zh-Hant/promo -->
```text
輸入一句話，行程就加進你的 Google 日曆。長期目標會拆成計畫，先給你看過、按「加入」才寫入；快開始的行程會在動態島倒數。
```

### 2.4 描述（Description，最多 4000 字元）

<!-- asc:zh-Hant/description -->
```text
Smart Schedules 是搭配 Google 日曆的 iPhone AI 行程助理。輸入一句話，例如「明天下午兩點和 Joe 開線上會議」、「團隊會議延後 30 分鐘」、「我想在半年內變壯」，助理就幫你排進行事曆。

■ 一句話排好行程
• 用日常語言新增、移動、改名或刪除行程。
• 沒說時間的話，助理會先問你，不會自己亂猜。
• 長期目標會拆成分階段的計畫：固定的練習時段、檢查點和每日提醒。先在日曆上預覽，按「加入」才寫進 Google 日曆；想改哪裡直接說，助理會給你新的版本。
• 想每個行程都先過目？打開「先問我」，單一行程也會等你按「加入」。
• 一句話就能改設定，例如「以後 8 點前不要提醒我」、「健身提前 2 小時提醒」。改完可以在對話裡馬上復原，之後也能在「助理記得的事」刪除。

■ 隨時一鍵叫出
• 控制中心和鎖定畫面的控制項目，一按就打開快速輸入，鍵盤已經準備好。有動作按鈕的 iPhone，也可以把它設定成「加入 Smart Schedules」。
• 支援 Siri 與捷徑，不用打開 App 就能新增行程。
• 動態島和鎖定畫面的即時動態：每個有時間的行程會在開始前 30、15、10 或 5 分鐘出現，顯示倒數和這一週的行程，結束後自動消失。
• 長按提醒就能在通知裡直接回覆：改時間，或順便新增別的計畫，不用打開 App；也可以延後 10 分鐘。

■ 你的行事曆，照你的方式
• 月、週、日檢視，日檢視是 24 小時制的時間軸。
• 可以連接多個 Google 帳號，每個行事曆分別顯示或隱藏，也能選擇新行程要存到哪裡。
• 在行程頁修改標題、時間、地點、提醒和備註；重複的行程可以只改這一次或全部一起改。
• 依照行程內容建議要帶什麼、準備什麼（例如護照、轉接頭、水和毛巾），不用網路，點一下就加進備註。想要更貼近這個行程的點子，也可以請 AI 建議。
• 沒有網路時做的修改會先保留，連上網路後再同步到 Google。

■ 提醒，配合你的生活
• 選擇由誰發送提醒：Smart Schedules、Google 日曆，或兩者都要。
• 依行程種類設定預設提醒和緊急程度（例如只有開始前 30 分鐘內才用時效性通知）、安靜時段、每日提醒上限，還有早晨摘要和晚間預覽。
• 專注模式過濾條件：選擇每個專注模式下要顯示和提醒哪些行事曆。
• 一直略過同一種提醒時，Smart Schedules 會問你要不要停掉；你按下之前什麼都不會改。

■ 隱私
• 不登入先試用：示範模式用虛構的範例行事曆，不需要帳號，也不會用到你的 Google 帳號。允許 AI 資料分享後可以試用真正的 AI 助理；沒有允許或連不上時改用離線規則。
• AI 助理使用 Google 的 Gemini API。第一次使用前，App 會列出會傳送哪些內容並徵求你的同意；按「允許」之前，不會傳送任何資料給 AI。請求會經過 Smart Schedules 的伺服器轉給 Gemini，伺服器不保存這些內容。你 Google 帳號的 email 不會傳給 AI。隨時可以在設定裡停止分享。
• 和 Google 日曆的同步直接在你的 iPhone 和 Google 之間進行。沒有廣告，也沒有追蹤。
• 可以匯出你的資料、移除任何一個 Google 帳號（同時撤銷授權），或清除這台 iPhone 上 Smart Schedules 的所有資料。

■ 使用前須知
• 需要 iOS 18 以上。要使用自己的行事曆，需要 Google 帳號；AI 助理需要網路連線。
• 依 Google Gemini API 的條款，Smart Schedules 只提供給年滿 18 歲的人使用。
• 在 iOS 18 上，即時動態只有在行程開始前的那段時間內（或行程進行中）打開 App 才會出現；iOS 26 以上不用打開 App 也會準時出現。
• 介面支援繁體中文和英文。

隱私權政策：https://www.smart-schedules.com/privacy
```

### 2.5 關鍵字（Keywords，最多 100 位元組，逗號後不加空格）

中文字在 UTF-8 是 3 個位元組，所以大約只能放 30 個中文字。名稱和副標題裡的字（Smart、Schedules、行程）已經會被搜尋，不再重複。名稱只有「Smart Schedules」，「AI」「助理」不在名稱裡：「助理」放在關鍵字裡（取代原本的「語音」，1.0 沒有 App 內的語音輸入）；想讓「AI」也被搜尋，可以改用備用名稱 1，或換掉下面的某個關鍵字（已經 99 位元組）。
「計畫」（台灣）和「計劃」（香港常用）兩種寫法都放；1.0 不在香港上架，「計劃」留著不影響其他關鍵字，要換成別的詞也可以。不放其他 App 或公司的名稱（包括 Google、Gemini）。

<!-- asc:zh-Hant/keywords -->
```text
行事曆,日曆,提醒,待辦,計畫,計劃,規劃,助理,會議,習慣,目標,時間管理,日程
```

### 2.6 網址

| 欄位 | 網址 |
|---|---|
| 支援網址（Support URL） | `https://www.smart-schedules.com/support` |
| 行銷網址（Marketing URL） | `https://www.smart-schedules.com` |
| 隱私權政策網址 | `https://www.smart-schedules.com/privacy`（在 App 資訊裡設定，第 1 節） |

網站同一頁裡繁體中文在前、英文在後，兩個語系用同樣的網址。

---

## 3. English product page

### 3.1 Name (30 characters max)

<!-- asc:en/name -->
```text
Smart Schedules
```

"Smart Schedule" (without the s) is already taken on the App Store. The name matches the Home Screen name (`CFBundleDisplayName`), the website and the app name on Google's consent screen.

Backup names, if you want the name to say what the app does (both start with "Smart Schedules"; App Store Connect checks whether a name is available when you change it):

<!-- asc:en/name.backup1 -->
```text
Smart Schedules: AI Planner
```

<!-- asc:en/name.backup2 -->
```text
Smart Schedules – AI Calendar
```

### 3.2 Subtitle (30 characters max)

<!-- asc:en/subtitle -->
```text
Plan your day in one sentence
```

### 3.3 Promotional Text (170 characters max)

<!-- asc:en/promo -->
```text
Type a plan and it lands in your Google Calendar. Long-term goals become a plan you review first, and upcoming events count down in the Dynamic Island.
```

### 3.4 Description (4000 characters max)

<!-- asc:en/description -->
```text
Smart Schedules is an AI scheduling assistant for iPhone that works with your Google Calendar. Type what you need, like "online meeting with Joe tomorrow at 2 pm", "push the team sync 30 minutes" or "I want to get stronger in six months", and the assistant puts it in your calendar.

PLAN IN A SENTENCE
• Add, move, rename or delete events in everyday language.
• If you don't say a time, the assistant asks instead of guessing.
• Long-term goals become a phased plan with regular sessions, checkpoints and a daily nudge. Preview it on your calendar first; nothing is added until you tap Add. Say what to change and the assistant makes a new version.
• Want to approve everything? Turn on "Ask me first" and single events wait for your Add too.
• Change settings just by asking: "from now on, don't remind me before 8", "remind me 2 hours before gym". Undo a change right in the chat, or delete it later in "What the assistant remembers".

ONE TAP AWAY
• A Control Center and Lock Screen control opens Quick Capture with the keyboard ready. On iPhones with the Action Button, you can set it to "Add to Smart Schedules".
• Siri and Shortcuts: add an event without opening the app.
• Live Activities in the Dynamic Island and on the Lock Screen: each timed event appears 30, 15, 10 or 5 minutes before it starts, with a countdown and a glance at your week, and goes away after it ends.
• Long-press a reminder to reply in the notification: move the event or add another plan, or snooze it for 10 minutes.

YOUR CALENDAR, YOUR WAY
• Month, week and day views, with a 24-hour timeline for the day.
• Connect several Google accounts, show or hide each calendar, and choose where new events go.
• Edit an event's title, time, place, reminders and notes; for a repeating event, change just this one or all of them.
• Suggestions of what to bring or prepare (passport, travel adapter, water and a towel…) based on the event, even offline; tap one to add it to the notes, or ask the AI for more.
• Changes made offline sync when you're back online.

REMINDERS THAT FIT YOUR DAY
• Choose who sends reminders: Smart Schedules, Google Calendar or both.
• Default reminders and urgency for each kind of event (e.g. Time Sensitive only in the last 30 minutes), quiet hours, a daily limit, a morning briefing and an evening preview.
• Focus filters: choose which calendars show and alert during each Focus.
• Keep dismissing the same reminder? Smart Schedules offers to stop it; nothing changes until you tap.

PRIVACY
• Try without signing in: demo mode has fictional sample calendars, needs no account and never uses your Google account. Allow AI data sharing to try the real AI assistant on them; otherwise, or offline, built-in rules answer.
• The AI assistant uses Google's Gemini API. Before its first use, the app lists what will be sent and asks for your permission; nothing goes to the AI until you tap Allow. Requests pass through the Smart Schedules server to Gemini, and the server doesn't keep them. Your Google account email addresses are never sent to the AI. You can stop sharing any time in Settings.
• Calendar sync runs directly between your iPhone and Google. No ads, no tracking.
• Export your data, remove any Google account (its access is revoked), or erase everything Smart Schedules keeps on your iPhone.

GOOD TO KNOW
• Requires iOS 18 or later. Using your own calendar requires a Google account; the AI assistant needs an internet connection.
• Under Google's Gemini API terms, Smart Schedules is for people aged 18 or older.
• On iOS 18, a Live Activity appears only if you open the app shortly before the event starts or while it's under way; on iOS 26 and later it appears on time without opening the app.
• Available in English and Traditional Chinese.

Privacy Policy: https://www.smart-schedules.com/privacy
```

### 3.5 Keywords (100 bytes max, no spaces after commas)

Words already in the name and subtitle (smart, schedules, plan, day, sentence) are left out, and so are other apps' and companies' names. The name is just "Smart Schedules", so "AI" and "planner" are not in it; to be found for them too, use backup name 1 or swap one of the keywords below (the list is at the 100-byte limit). "diary" replaces "voice": 1.0 has no in-app speech input.

<!-- asc:en/keywords -->
```text
calendar,agenda,reminder,to-do,task,routine,habit,goal,meeting,diary,assistant,organizer,daily,event
```

### 3.6 URLs

| Field | URL |
|---|---|
| Support URL | `https://www.smart-schedules.com/support` |
| Marketing URL | `https://www.smart-schedules.com` |
| Privacy Policy URL | `https://www.smart-schedules.com/privacy` (set under App Information) |

### 3.7 字數

| 欄位 | 繁體中文 | English | 上限 |
|---|---|---|---|
| 名稱（主要／備用 1／備用 2） | 15／23／22 字元 | 15／27／29 字元 | 30 字元 |
| 副標題 | 13 字元 | 29 字元 | 30 字元 |
| 宣傳文字 | 63 字元 | 151 字元 | 170 字元 |
| 描述 | 1,693 字元 | 3,825 字元 | 4,000 字元 |
| 關鍵字 | 99 位元組 | 100 位元組 | 100 位元組 |
| 審核備註（第 8.2 節） | — | 3,930 位元組（填入備用驗證碼後要重算） | 4,000 位元組 |

精確數字用第 12 節的腳本算；改了文字就重跑一次。

---

## 4. 版本資訊、價格與供應狀況

### 4.1 版本資訊（Version Information）

| 欄位 | 填什麼 |
|---|---|
| 版本號 | `1.0.0`（要和 `MARKETING_VERSION` 一致，見 `project.yml`） |
| 版權（Copyright） | `2026 SHENG HAN HSIEH`（不要自己加 ©，App Store Connect 會自動加；年份是取得權利的那一年） |
| What's New | 第一版沒有這個欄位 |
| App 內購買項目 | **一個都不要附加。** 如果 App Store Connect 裡已經建立「Smart Schedules Pro」群組或商品，就留著不送審。 |

### 4.2 價格

**免費（Free）**，沒有 App 內購買、沒有訂閱。免費 App 不需要簽 Paid Apps 協議，也不用填稅務和銀行資料。
1.0 的 App 裡完全不會呼叫 StoreKit（`AppConstants.subscriptionsEnabled = false`，`ReleaseConfigurationTests` 和
`scripts/validate_schema.py` 會擋下把它打開的改動），商店頁也就不會出現「App 內購買」。描述和截圖都不要提訂閱或 Pro。

### 4.3 供應地區：不在歐洲經濟區、瑞士、香港、澳門和中國大陸上架（英國照常）

價格與供應狀況（Pricing and Availability）› 國家或地區（Countries or Regions）：取消下面 **27 個歐盟會員國**，再加上 **挪威 Norway、冰島 Iceland、列支敦斯登 Liechtenstein、瑞士 Switzerland**，以及 **香港 Hong Kong、澳門 Macau、中國大陸 China mainland**；其他地區（包括英國和台灣）保留。澳門在清單上的英文名稱可能是「Macao」（請在畫面上確認）。

| | |
|---|---|
| 奧地利 Austria、比利時 Belgium、保加利亞 Bulgaria、克羅埃西亞 Croatia、賽普勒斯 Cyprus、捷克 Czechia、丹麥 Denmark、愛沙尼亞 Estonia、芬蘭 Finland | 法國 France、德國 Germany、希臘 Greece、匈牙利 Hungary、愛爾蘭 Ireland、義大利 Italy、拉脫維亞 Latvia、立陶宛 Lithuania、盧森堡 Luxembourg |
| 馬爾他 Malta、荷蘭 Netherlands、波蘭 Poland、葡萄牙 Portugal、羅馬尼亞 Romania、斯洛伐克 Slovakia、斯洛維尼亞 Slovenia、西班牙 Spain、瑞典 Sweden | |

加上這 7 個（歐盟以外，不會跟著歐盟一起取消，要一個一個取消）：挪威 Norway、冰島 Iceland、列支敦斯登 Liechtenstein、瑞士 Switzerland、香港 Hong Kong、澳門 Macau、中國大陸 China mainland。香港、澳門和中國大陸要取消，是因為 Gemini API 不在那裡提供，AI 助理用不了（第 4.4 節第 1、2 點）。

其他設定：

- 預購（Pre-Order）：不要開。
- 「iPhone and iPad Apps on Apple Silicon Macs」和「Apple Vision Pro」：建議都取消。App 依賴動態島、控制中心、即時動態和 App Attest，這些在 Mac 和 Vision Pro 上不是同樣的體驗，也沒有測過。
- 英國照常上架，適用英國 GDPR。隱私權政策已涵蓋（第 1 節的「控管者」、第 15 節的權利、ICO 和法律依據）。開發者在英國（網域 WHOIS 的註冊人國家是 GB），所以**不需要英國代表人**；要確認的是 ICO 的資料保護費，見第 4.4 節第 4 點。

**數位服務法（DSA）交易商身分。** Apple 的說明（[Manage EU Digital Services Act trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)，2026-10-15 讀取）寫的是：

> "Even if you don't distribute apps in the EU, you'll still need to declare a trader status."
>
> "If you don't distribute apps on the App Store in the EU (for example you only distribute apps through alternative distribution, or TestFlight, or on the App Store only outside the EU), you're not acting as a trader on the App Store."

所以 1.0 **不需要**交易商的驗證（公開地址、電話、email 和身分文件），但帳號**還是要做一次聲明**：送審新 App 時 App Store Connect 會要求。
路徑：Business › Agreements › Compliance › Digital Services Act › Complete Compliance Requirements › 選「This is not a trader account」（不用填聯絡資訊）。
之後的版本要加入歐盟店面時，再重新判斷是不是交易商。

### 4.4 上架地區的決定（2026-10-16 已決定）與剩下要確認的事

1. **香港和澳門：1.0 不上架（已決定，第 4.3 節）。** 一份第三方整理（2026 年 4 月核對）說 Google AI Studio／Gemini API 的可用地區清單沒有香港、澳門和中國大陸（台灣、英國有）；Google 開發者論壇上也有從香港伺服器和 Cloudflare Workers 呼叫被拒的回報。
   依這些回報，Gemini 判斷地區時看的是送出請求的伺服器：Cloudflare Worker 預設在離使用者最近的機房執行，香港使用者的請求很可能從香港機房送出，被 Google 以「User location is not supported」拒絕。
   取消這兩個店面之後，1.0 不需要再查可用地區，也不需要調整 Worker 的執行位置。之後的版本想加回來時，先到 <https://ai.google.dev/gemini-api/docs/available-regions> 確認，再評估 Worker 的執行位置（Cloudflare 的 Smart Placement 或指定區域的設定，部署前查 Cloudflare 文件），讓呼叫 Gemini 的請求從支援的地區送出，同時確認 Gemini 條款允許服務該地區的使用者。
2. **中國大陸：1.0 不上架（已決定，第 4.3 節）。** Gemini API 不在中國大陸提供；Apple 說明部分 App 在中國大陸上架需要 ICP 備案號（[App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/)），生成式 AI 服務另外需要主管機關核准。
3. **其他 Gemini API 不提供的地區（還沒做）**：把 Google 的可用地區清單和 App Store 的店面清單對照一次，清單外的地區照第 1 點的方式處理（取消店面）。
4. **英國：不需要英國代表人；要確認 ICO 的資料保護費。** 開發者在英國（網域 WHOIS 的註冊人國家是 GB）。英國 GDPR 第 27 條的代表人只要求英國境外的控管者指定，所以不需要；歐洲經濟區和瑞士不上架，也不需要那邊的代表人。要確認的是 **ICO 的資料保護費（data protection fee）**：在英國處理個人資料的組織或個人，除非符合豁免，都要向 ICO 繳年費。上架前到 ICO 網站（ico.org.uk）的「Do I need to pay the fee?」自我評估，依結果繳費，或記下不用繳的理由；級距、金額和豁免條件以 ICO 網站當時寫的為準（這份文件不寫金額）。隱私權政策第 1、19 節的控管者名稱，要和繳費登記的名稱一致。

---

## 5. App 隱私問卷（App Privacy）

答案和 `App/PrivacyInfo.xcprivacy` 一致（兩種資料類型、都連結到使用者、都不用於追蹤、用途都只有 App 功能），而且逐項對照過目前的程式碼，見 5.3 和 5.4。

### 5.1 怎麼填

1. 「Do you or your third-party partners collect data from this app?」→ **Yes, we collect data from this app**。
2. 勾選資料類型，**只勾這兩個**：
   - **User Content › Other User Content**
   - **Identifiers › Device ID**
3. 每一種都這樣回答：

| 問題 | Other User Content | Device ID |
|---|---|---|
| 用途（purposes） | 只勾 **App Functionality** | 只勾 **App Functionality** |
| Is this data linked to the user's identity? | **Yes** | **Yes** |
| Is this data used for tracking purposes? | **No** | **No** |

產品頁會顯示：「Data Linked to You：User Content、Identifiers」；沒有「Data Used to Track You」。
Apple 的定義（[App privacy details](https://developer.apple.com/app-store/app-privacy-details/)）：「collect」是指資料離開裝置，而且你或第三方能存取的時間超過即時處理請求所需；「Personal Information」和「Personal Data」一律算連結到使用者。

### 5.2 為什麼是這兩項

| 資料 | 去哪裡、留多久 | 歸類 | 程式碼 |
|---|---|---|---|
| 使用者輸入的請求（對 Siri 說或用鍵盤聽寫的，App 收到的也是 Apple 轉好的文字）；最多 40 個、今天起 14 天內行程的標題、時間、備註和 Google 行程 ID；回覆的那則提醒的行程；行事曆名稱（以「Account 1」這類代稱區分帳號）和助理設定；時區和語言；「AI 建議」那一個行程的地點 | 經 Smart Schedules 伺服器（Cloudflare Worker）原封不動轉給 Google Gemini API，伺服器不保存；Google 為偵測濫用最多保存 55 天（[Gemini API 使用政策](https://ai.google.dev/gemini-api/docs/usage-policies)，付費層級也一樣） | Other User Content（第三方保存超過即時處理所需，所以算 collect；每個請求都帶這個安裝的 App Attest 金鑰 ID，所以宣告為連結到使用者） | `Shared/AI/AssistantPrompt.swift`、`Shared/AI/NoteSuggestionPrompt.swift`、`Shared/AI/GeminiClient.swift`、`server/worker/src/gemini.ts` |
| App Attest 金鑰 ID（這個安裝在 Secure Enclave 產生的金鑰，每個請求都帶）；給通知擴充用的 session（只存 token 的雜湊） | 伺服器以金鑰 ID 保存公開金鑰和計數器，用來驗證每個請求、依安裝限制請求次數，沒有到期時間；session 7 天 | Device ID（用途：驗證、防濫用，屬於 App Functionality） | `Shared/Security/AppAttestClient.swift`、`server/worker/src/attest-routes.ts`、`session.ts` |
| 連線 IP（IPv4，或 IPv6 的 /64） | 只用來限制 `/attest` 的頻率，每日計數保存 2 天 | Device ID。Apple 要求依用途歸類 IP；這裡的用途是防濫用 | `server/worker/src/ratelimit.ts` |
| 伺服器日誌：金鑰 ID、App 識別碼、HTTP 狀態和錯誤代碼 | Workers Logs 最多 7 天，不含請求內容、標題、token 或 IP | 已包含在 Device ID（App Functionality：安全與服務穩定） | `server/worker/src/http.ts` 的 `log()`；`wrangler.toml` 關掉 invocation logs |

1.0 不用 iOS 18 的即時動態 push-to-start（`AppConstants.pushToStartEnabled = false`）：App 不要求 push token、不上傳任何行程，也沒有隨機安裝 ID，所以這張表沒有「iOS 18 的行程登記」和「安裝 ID／push token」兩列，伺服器上也沒有任何行程資料。之後的版本開啟 push-to-start 時，要把它們加回來（Other User Content、Device ID），並在 App Store Connect 重新填問卷。

### 5.3 考慮過、但不勾的類型

| 類型 | 為什麼不勾 |
|---|---|
| Contact Info › Email Address | Google 帳號的 email 只存在 iPhone（Keychain、`accounts.json`），只在 OAuth 登入時當 `login_hint` 送給 Google 自己。同意說明第 4 版起，帳號 email 不會以帳號資訊送到伺服器或 Gemini：使用者的請求和行程文字裡的帳號 email 都換成佔位字（`Shared/AI/CalendarAliases.swift`、`Shared/Models/PromptRedaction.swift`，測試在 `Tests/Unit/AccountEmailPrivacyTests.swift`）。使用者自己打進請求裡的其他 email（例如邀請對象）也屬於 Other User Content。 |
| Google 日曆的行程本身 | 行程在 iPhone 和使用者自己的 Google 帳號之間直接同步（`Shared/Calendar/GoogleCalendarClient.swift`），開發者拿不到；App 裡沒有任何 Google 的 SDK，所以 Google 不是 Apple 定義的「third-party partner」（加進 App 的程式碼的提供者）。送到伺服器和 Gemini 的那部分已算在 Other User Content。 |
| User Content › Audio Data | App 不使用麥克風和語音辨識：Info.plist 沒有 `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`，程式裡沒有 Speech 或 AVAudio。使用者對 Siri 說話或用鍵盤聽寫時由 Apple 轉成文字，App 只收到文字；Apple：「You are not responsible for disclosing data collected by Apple.」 |
| Purchases | 1.0 完全不呼叫 StoreKit。 |
| Contacts | 沒有使用 Contacts framework。 |
| Location（Precise / Coarse） | 沒有使用 CoreLocation；行程地點是使用者內容（Other User Content），IP 不用來推算位置。 |
| Health & Fitness | 沒有 HealthKit 或動作感測資料；「我想半年內變壯」這類目標是使用者輸入的內容。 |
| Usage Data、Diagnostics（含 Crash Data）、Advertising | 沒有分析、廣告、當機回報或追蹤的 SDK（`project.yml` 只有 target 之間的相依，沒有任何第三方套件），也沒有用 MetricKit、AdSupport 或 App Tracking Transparency。 |
| User ID | App 沒有自己的帳號系統。 |
| 對話紀錄、偏好設定、「助理記得的事」、匯出檔 | 只存在 iPhone，不會上傳。 |

### 5.4 對照 `PrivacyInfo.xcprivacy` 的結果

- `App/PrivacyInfo.xcprivacy`：`NSPrivacyTracking` false、沒有 tracking domains；宣告 Other User Content 和 Device ID，都 linked、不追蹤、用途 App Functionality。和 5.1 一致。Device ID 指的是 App Attest 金鑰 ID（1.0 沒有 push-to-start 的安裝 ID 或 push token）。
- `NotificationContent/PrivacyInfo.xcprivacy`：只宣告 Other User Content（擴充會送 AI 請求，帶的是 App 替它取得的 session token；金鑰 ID 由主 App 的 Device ID 宣告）；`Widgets/PrivacyInfo.xcprivacy`：沒有收集任何資料。App Privacy 問卷是整個 App 一份，以主 App 為準。

---

## 6. 年齡分級問卷：18+

**理由：** Gemini API 的條款要求使用者年滿 18 歲，也不允許把 API 用在「directed towards or likely to be accessed by individuals under the age of 18」的服務裡（[Gemini API Additional Terms](https://ai.google.dev/gemini-api/terms)；這個沙盒連不到 Google 的網站，文字來自搜尋摘錄，請再確認一次）。
Apple 說明：如果你的條款或 EULA 的最低年齡比算出來的分級高，就必須用「Override to Higher Age Rating」調到符合的分級
（[Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating)）。

路徑：App Information › Age Ratings › Set Up Age Ratings（之後修改是 Edit）。依實際內容誠實回答；Apple 提醒 AI 助理和聊天功能產生的內容也要算進頻率。
助理只能透過函式呼叫回應，回覆最多兩句話（`Shared/AI/FunctionDeclarations.json` 的 `reply_to_user`），用途只有排行程。

| 步驟 | 問題 | 回答 | 原因 |
|---|---|---|---|
| In-App Controls | Parental Controls | 不勾 | 沒有家長控制功能 |
| | Age Assurance | 不勾 | 沒有年齡驗證機制 |
| Capabilities | Unrestricted Web Access | **No** | App 裡沒有瀏覽器；連結（Meet、Google 日曆）交給 Safari 或其他 App 打開；Google 登入用系統的登入視窗（ASWebAuthenticationSession） |
| | User-Generated Content | **No** | 內容不會分享給其他使用者 |
| | Messaging and Chat | **No** | 對話對象是助理，不是其他人 |
| | Advertising | **No** | 沒有廣告 |
| | Social Media | **No** | |
| Mature Themes | Profanity or Crude Humor、Horror/Fear Themes、Alcohol, Tobacco, or Drug Use or References | **None** | |
| Medical or Wellness | Medical or Treatment Information | **None** | |
| | Health or Wellness Topics | **Yes**（如果要選頻率，選 **Infrequent**） | 長期計畫可以把健身目標排成運動課表（範例「我想在 6 個月內增肌」），屬於 Apple 定義裡的「exercise recommendations」。這題只會讓計算結果變成 9+，最後一樣調到 18+。 |
| Sexuality or Nudity | 全部 | **None** | |
| Violence | 全部 | **None** | |
| Chance-Based Activities | Gambling、Simulated Gambling、Contests、Loot Boxes | **None / No** | |
| Additional Information | Age Categories and Override | **Override to Higher Age Rating → 18+** | 算出來應該是 9+ |
| | Age Suitability URL（選填） | `https://www.smart-schedules.com/support#en-needs` | 支援頁寫明只提供給年滿 18 歲的人（中文段落是 `#zh-needs`） |

存檔後到 App Information 看全球和各地區的分級。iOS 26 以前的系統用舊的分級制度，顯示在「Operating Systems Earlier than Version 26」，
18+ 在那裡應該會對應到 17+，請在 App Store Connect 確認。韓國若另有分級通知，照 Apple 的指示處理。
隱私權政策和支援頁寫的最低年齡（18 歲）要和這裡一致。

---

## 7. 出口合規（Export Compliance）

- `project.yml` 的主 App Info.plist 已設 `ITSAppUsesNonExemptEncryption: false`（也就是 NO），所以每次上傳 build 時 App Store Connect 不會再問加密問題。上傳前可以用 `plutil -p SmartSchedule.app/Info.plist | grep ITSApp` 確認 build 裡有這個 key。
- **依據：** App 只用 iOS 內建的加密：URLSession 的 HTTPS（Google API、Smart Schedules 伺服器）、Keychain、App Attest（DeviceCheck）、ASWebAuthenticationSession。CryptoKit 只用來算 SHA-256 雜湊（PKCE、App Attest 的 client data hash、行程 ID），沒有自己實作或專有的加密演算法，也沒有任何第三方加密函式庫。
  Apple 的說明（[Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)）：只用免除文件要求的加密時把這個值設成 NO；「the use of encryption that's built into the operating system—for example, when your app makes HTTPS connections using URLSession—is exempt from export documentation upload requirements」。
- 如果 App Store Connect 還是問（例如 build 少了這個 key）：回答 App 只使用作業系統內建、屬於免除範圍的加密，不需要上傳文件。
- Apple 也提到使用免除範圍加密的 App「might」需要向美國政府提交年度自我分類報告（self-classification report）；是否適用請依 Apple 頁面連到的美國商務部 BIS 說明自行確認。
- 法國的加密進口聲明：法國是歐盟國家，1.0 不在那裡上架。

---

## 8. 審核資訊（App Review Information）

### 8.1 聯絡人與登入

| 欄位 | 填什麼 |
|---|---|
| 聯絡人姓名 | `[名] [姓]` |
| 電話 | `+[國碼] [電話]`（要用國際格式、加號開頭） |
| Email | `support@smart-schedules.com` |
| Sign-in required | **勾選。** User name：`[測試 Google 帳號，例如 example@gmail.com 這種格式]`；Password：`[密碼]` |

**為什麼要提供測試帳號，不能只靠示範模式：** Guideline 2.1 要求有登入的 App 提供 demo account；用內建示範模式代替帳號需要 Apple 事先核准。
示範模式涵蓋大部分畫面，允許 AI 資料分享後也能測真正的 AI 助理（用的是範例行程）；只有讀寫真正的 Google 日曆要用 Google 帳號測試。

測試用 Google 帳號的準備：

1. 開一個新的 Google 帳號，只用來送審，不要用任何人的私人帳號。
2. 在它的日曆裡放一週虛構的行程（可以照 `Shared/Core/DemoData.swift` 的範例：Online meeting with Joe、Lunch、Dentist、Gym…）。
3. 開啟兩步驟驗證，產生備用驗證碼（backup codes），挑三組填進下面備註的 `[CODE 1]`～`[CODE 3]`。Google 碰到陌生裝置或地點常會要求驗證，審核員可以用這些碼通過。每組只能用一次，每次送審前換新的。
4. 帳號不能過期或被停用；OAuth consent screen 要已經是 In production（第 0 節）。

### 8.2 備註（Notes，最多 4000 位元組，英文）

**要貼的是下面這一段**（唯一的貼上來源）。`docs/review-notes.md` 是背景說明：英文段落超過 App Store Connect 的 4000 位元組上限，也沒有測試帳號，不要整份貼上。下面是重寫並更新到同意說明第 5 版（1.0 沒有 iOS 18 push-to-start）、且放得下的版本；`☰`、`›`、`⋯` 每個佔 3 位元組，已經算進去。

<!-- asc:en/review-notes -->
```text
TRY IT WITHOUT SIGNING IN
On first launch the main screen shows "Connect Google Calendar" and "Try without signing in". Tap "Try without signing in" (also: avatar at top right, or ☰ › General › Demo mode). Demo mode has fictional sample calendars and needs no Google account. Its assistant is the real AI (see below) on the sample data; without AI permission or a connection, offline rules answer and say so. Try the chips, e.g. "I want to be muscular in 6 months" (a plan card with Add / Keep editing). Please allow notifications at launch: the sample "Online meeting with Joe" starts 21 minutes after the demo starts, its Live Activity appears at once and a reminder arrives about a minute later.

FULL FEATURES: TEST GOOGLE ACCOUNT
The account in Sign-In Information is a test Google account with sample events. Tap "Connect Google Calendar", enter its address, tap "Continue with Google", sign in on Google's page and allow calendar access. If Google asks for a code, use a backup code: [CODE 1] [CODE 2] [CODE 3]. A Google account is needed only to read and write Google Calendar. Google sign-in only connects the person's own Google Calendar; the app has no accounts of its own, so Sign in with Apple is not required (4.8).

AI ASSISTANT AND CONSENT (5.1.2(i))
The assistant uses Google's Gemini API through our server (it holds the API key; the app has none and uses App Attest), so the server must be reachable; calendar features work without it. The first message opens "Use the AI assistant?", which lists what is sent: the request text; titles, times, notes and Google event IDs of up to 40 events in the next 14 days; one event's location only for AI suggestions; calendar names and assistant settings; time zone and language. It names Google as the recipient and asks Allow / Not now. Google account email addresses are never sent (calendars appear as "Account 1", "Account 2"). Not now keeps the assistant off. Settings (☰ › General) › AI & privacy shows the status, "What is sent", Allow and Stop sharing. Siri and notification replies refuse until permission is given in the app (demo mode: offline rules). Demo requests carry only the fictional sample events, never Google data.

LIVE ACTIVITY / DYNAMIC ISLAND
One Live Activity per timed event, from 30/15/10/5 minutes before it starts (Settings › Notifications › Dynamic Island; default 30, or Off) until it ends; it leaves the Lock Screen 10 minutes after the end. No upcoming event, no Live Activity. Everything happens on the iPhone: nothing is sent to our server and no AI permission is needed. iOS 26: opening the app schedules the next two days' activities (Activity.request with a start date), so each appears on time with the app closed. iOS 18 cannot schedule them: an activity appears when the app is opened during the lead time or the event, and stays after the app closes. The countdown is a system timer. Tapping it opens Quick Capture.

CONTROL CENTER
The "Smart Schedules" control (Control Center › + › Add a Control) opens Quick Capture with the keyboard up. It never starts a Live Activity.

NOTIFICATION REPLIES
Long-press a reminder and type, e.g. "push this 30 minutes later". The extension updates the event (Google Calendar, or the sample data in demo mode) before the notification closes; deleting needs a red Confirm button. "Snooze 10 min" is also offered.

DATA DELETION (5.1.1(v))
Remove account (avatar › ⋯ next to the account, or swipe left; or ☰ › ⋯ next to the address) revokes Google access and deletes its tokens and cached events. ☰ › General › Data › "Erase all data on this device" revokes every Google account, withdraws AI permission and deletes all local data. Events in Google Calendar are not deleted.

OTHER
No in-app purchases or subscriptions. Rated 18+ because Google's Gemini API terms require users to be 18 or older. The app does not use the microphone or speech recognition.
```

### 8.3 審核員追問時可以用的回答（英文，不受 4000 位元組限制）

需要時貼到 App Review 的回覆（App Review 訊息或 Resolution Center）。

```text
Time Sensitive notifications: reminders are Time Sensitive only when they fire 30 minutes or less before an event starts (the default "Automatic" urgency). Earlier reminders, the morning briefing and suggestions are Normal. People can change the urgency for each kind of event in Settings › Notifications › Urgency, including turning Time Sensitive off. During quiet hours reminders arrive silently.

Background modes: only "fetch", which lets background app refresh sync Google Calendar changes and keep reminders and Live Activities up to date. Reminders are local notifications created on the iPhone.

NSSupportsLiveActivitiesFrequentUpdates: declared, but Live Activities get no updates from a server at all; the countdown uses Text(timerInterval:).

What our server keeps: AI requests are passed to Google's Gemini API and not stored, and no calendar data is stored at all (Live Activities are made on the iPhone). The server keeps the App Attest key record used to verify the app.

Speech: the app has no microphone or speech-recognition feature and asks for neither permission. People can speak a request to Siri ("Add a plan in Smart Schedules") or use the keyboard's dictation key; Apple turns the speech into text, and the app only receives the text.

Siri: "Add a plan in Smart Schedules" runs without opening the app. It checks AI permission first and answers "Turn on AI data sharing in the Smart Schedules settings first." when it is missing. Long-term plans made through Siri wait in the app until the person taps Add. In demo mode Siri uses the real assistant on the sample data when AI permission was given in the app, and the offline demo rules otherwise.

Provenance: events the assistant creates carry a line at the top of their Google Calendar description saying they were scheduled by the Smart Schedules assistant, with what the person asked.

iPhone only: the app targets iPhone. The Dynamic Island needs an iPhone that has one; on other iPhones the Live Activity shows on the Lock Screen.

Accounts: Smart Schedules has no accounts of its own, so there is no account to delete (5.1.1(v)). Connected Google accounts can be removed one by one, which revokes the app's access at Google, and "Erase all data on this device" removes everything. Google sign-in tokens never leave the iPhone except to Google.
```

如果你決定說明二進位檔裡保留的 StoreKit 程式碼（Guideline 2.3.1 不允許隱藏功能；這段程式碼在 1.0 執行不到），可以在上面加一句：
`The binary contains StoreKit code for a possible later subscription; it is switched off at build time and can only be turned on in a later version submitted for review.`

---

## 9. 截圖規劃

### 9.1 規格

- **6.9 吋（iPhone with Dynamic Island, large display）：1320 × 2868 直向**，用 iPhone 17 Pro Max 模擬器或實機拍。這是這份規劃的主要尺寸。
- Apple 的截圖規格頁（[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)，2026-10-15 讀取）現在寫的必要尺寸是「At least one screenshot for **iPhone with Dynamic Island (medium display)**」，也就是 6.3 吋 **1206 × 2622**（iPhone 17 Pro）。用同樣的畫面在 iPhone 17 Pro 模擬器再拍一組，兩組都上傳最保險；App Store Connect 的版本頁會標出哪一格必填。
- 用 iOS 26 的模擬器拍（iPhone 17 Pro Max／17 Pro）。第 2 張的「開始前 30、15、10 或 5 分鐘出現」在 iOS 26 成立；iOS 18 要在那段時間內打開 App 才會出現，描述的「使用前須知」已寫明，畫面本身兩種系統一樣。
- 每種尺寸最多 10 張，`.png` 或 `.jpg`，**不能有透明（alpha）**。不支援 iPad，所以不用 iPad 截圖。
- 兩個語系各一組：繁體中文組把模擬器的語言設成繁體中文（台灣），用中文輸入；英文組用英文。
- 狀態列統一：`xcrun simctl status_bar booted override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`。
- 只放虛構的資料（Guideline 2.3.9）：行程標題用範例，畫面上的帳號 email 只能是 `example@gmail.com` 這類範例。示範模式的兩個範例帳號正好是 `example@gmail.com` 和 `example@yourmail.com`。
- 內容要適合所有年齡（Guideline 2.3.8，即使 App 是 18+）。
- 示範模式的主畫面對話區會顯示「示範」（英文介面是「DEMO」）標籤，回覆也會加「示範模式：沒有寫入 Google 日曆。」。第 1、3 張建議用測試 Google 帳號加虛構行程、透過真正的助理拍；抽屜、設定、行程頁、即時動態可以用示範模式。
- 可以加背景和說明文字。不要放其他行動平台的圖示或名稱（Guideline 2.3.10），也不要放 Google 的 logo。
- App 只有深色介面，說明文字用深色背景、白字最協調。

### 9.2 畫面和說明文字

前三張會出現在搜尋結果，放最有代表性的。每張的說明是「主標／副標」。

| # | 畫面 | 怎麼拍 | 繁體中文說明 | English caption |
|---|---|---|---|---|
| 1 | 主畫面：月曆加上對話區，剛加入一個行程（「已加入 Google 日曆」那一列） | 輸入「明天下午 1 點跟 Andrew 吃午餐」／「Lunch with Andrew tomorrow 1pm」 | 一句話，行程就排好／輸入一句話，助理幫你寫進 Google 日曆 | Plan your day in one sentence / Type it, and it goes into Google Calendar |
| 2 | 鎖定畫面的即時動態（行程標題和倒數），可以疊一張展開的動態島（一週行程和「編輯」按鈕） | 開始示範模式後馬上鎖定模擬器（⌘L）：範例「Online meeting with Joe」21 分鐘後開始 | 下一個行程，在動態島倒數／開始前 30、15、10 或 5 分鐘出現 | Your next event, counting down / Appears 30, 15, 10 or 5 minutes before it starts |
| 3 | 長期計畫卡（各階段、每堂課）和週檢視上的虛線預覽 | 輸入「我想在 6 個月內增肌」／「I want to be muscular in 6 months」 | 長期目標，拆成每週計畫／先看過，按「加入」才寫進日曆 | Big goals, broken into a weekly plan / Nothing is added until you tap Add |
| 4 | 快速輸入的日檢視（24 小時時間軸、對話面板） | 從控制中心的 Smart Schedules 按鈕打開 | 控制中心一按，馬上輸入／日、週、月檢視隨時切換 | Quick Capture from Control Center / Switch between day, week and month |
| 5 | 長按提醒後的對話（輸入「延後 30 分鐘」／「push this 30 minutes later」和助理的回覆） | 示範模式開始約 1 分鐘後會收到 Joe 會議的提醒；在鎖定畫面長按 | 長按提醒，直接改時間／不用打開 App | Reply to a reminder to reschedule / Right in the notification |
| 6 | 行程頁：備註和建議膠囊（例如「+ 帶護照」） | 建一個虛構的「飛往東京」／「Flight to Tokyo」行程 | 該帶什麼，先幫你想好／點一下就加進備註 | Know what to bring / Tap a suggestion to add it to your notes |
| 7 | ☰ 抽屜：兩個 Google 帳號和各自的行事曆 | 示範模式（範例帳號 email 是 example@ 開頭） | 多個 Google 帳號，一次看清楚／每個行事曆都能分別顯示或隱藏 | All your Google calendars together / Show or hide each calendar |
| 8 | 設定 › 通知（安靜時段、早晨摘要、每日上限、動態島） | 打開安靜時段和早晨摘要 | 提醒方式，由你決定／安靜時段、每日上限、早晨摘要 | Reminders on your terms / Quiet hours, a daily limit, a morning briefing |
| 9（選用） | AI 同意說明「要使用 AI 助理嗎？」 | 已連接帳號、尚未同意時送出第一則訊息 | AI 看到什麼，由你決定／按「允許」之前，不會傳送任何資料給 AI | You decide what the AI sees / Nothing is sent until you tap Allow |

App 預覽影片（App Preview）可以不做。要做的話，用同樣的流程錄 15–30 秒：控制中心 → 快速輸入 → 輸入一句話 → 行程出現在月曆 → 動態島倒數。

---

## 10. 這次核對時發現、要另外處理的事

這些不在這份文件的範圍內，已經避免寫進上面的商店文字：

1. **Siri 片語只有英文。** `SmartScheduleShortcuts` 的片語（「Add a plan in Smart Schedules」）沒有 `AppShortcuts.xcstrings`，Siri 用中文時不會認得。中文描述因此只寫「支援 Siri 與捷徑」，不引用片語。
2. **截圖必要尺寸：** Apple 現在把 6.3 吋（1206 × 2622）列為必要，見第 9.1 節。
3. **香港、澳門和中國大陸：1.0 不上架**（Gemini API 不在那裡提供），見第 4.3、4.4 節。
4. **英國代表人：不需要**（開發者在英國）；**ICO 的資料保護費要確認**，見第 4.4 節第 4 點。

---

## 11. 功能說法對照程式碼

| 商店文字的說法 | 程式碼依據 |
|---|---|
| 用日常語言新增、移動、改名、刪除行程 | `Shared/AI/FunctionDeclarations.json`：`create_events`、`modify_event`、`delete_events`、`query_schedule` |
| 沒說時間會先問 | `reply_to_user`（`needs_clarification`）；`App/Intents/AddPlanIntent.swift` 讓 Siri 追問最多兩次 |
| 長期計畫先預覽，按「加入」才寫入，可以要求修改 | `create_long_term_plan`、`confirm_plan`；`App/Views/PlanPreviewCard.swift`；README「長期計畫：先審閱，按 Add 才加入」 |
| 「先問我」 | `AssistantAutonomy.askFirst`（`Shared/Models/AppPreferences.swift`）、`App/Views/Settings/AssistantSettingsView.swift` |
| 用一句話改設定、復原、「助理記得的事」 | `update_preferences`；`App/Views/Chat/SettingsUpdatedCard.swift`；`App/Views/Settings/PrivacySettingsView.swift` |
| 控制中心、鎖定畫面控制項打開快速輸入；動作按鈕 | `Widgets/SmartScheduleControl.swift`、`Shared/Intents/OpenQuickCaptureIntent.swift`、`App/Views/Settings/ShortcutsGuideView.swift` |
| Siri 與捷徑，不用打開 App | `AddPlanIntent`（`openAppWhenRun = false`）、`SmartScheduleShortcuts` |
| 即時動態：開始前 30／15／10／5 分鐘出現、倒數、這一週、結束後消失 | `AppPreferences.liveActivityLeadChoices = [30, 15, 10, 5]`；`Shared/LiveActivity/ActivityScheduler.swift`；`Widgets/ScheduleLiveActivity.swift`（`IslandWeekStrip`、`Text(timerInterval:)`） |
| iOS 18 只有在提前時間內（或進行中）打開 App 才出現；iOS 26 不用打開 App 也準時出現 | `ActivityPlanner.schedulesOnDevice`、`ActivityPlanner.pushToStartStep`（`Shared/LiveActivity/ActivityScheduler.swift`）；`AppConstants.pushToStartEnabled = false`；`App/Views/Settings/NotificationSettingsView.swift` 的說明文字 |
| 長按提醒回覆、延後 10 分鐘 | `NotificationContent/`；`Shared/Notifications/NotificationIDs.swift`（「Type in any plan to add or change」、「Snooze 10 min」） |
| 月、週、日檢視，24 小時時間軸 | `App/Views/MonthGridView.swift`、`QuickCaptureView.swift`、`CaptureModePicker.swift`、`CaptureDayPager.swift` |
| 多個 Google 帳號、行事曆顯示或隱藏、新行程存到哪裡 | `App/Views/Navigation/CalendarDrawer.swift`、`App/Views/Settings/CalendarSettingsView.swift`、`Shared/Calendar/CalendarRouter.swift` |
| 行程頁修改，重複行程只改這次或全部 | `App/Views/Events/EventPage.swift`、`Shared/Calendar/EventEditor.swift` |
| 帶什麼的建議，離線，點一下加進備註；AI 建議 | `Shared/Orchestrator/NoteSuggester.swift`、`NoteSuggestionRules.swift`；`App/Views/Events/NoteSuggestionViews.swift`；`suggest_event_notes` |
| 離線修改之後同步 | `Shared/Calendar/SyncOutbox.swift`、`SyncEngine.swift` |
| 由誰發送提醒、緊急程度、安靜時段、每日上限、早晨摘要、晚間預覽 | `App/Views/Settings/NotificationSettingsView.swift`、`Shared/Notifications/ReminderPlanner.swift`、`BriefingBuilder.swift` |
| 專注模式過濾條件 | `App/Intents/CalendarFocusFilter.swift` |
| 一直略過的提醒會問要不要停掉 | `Shared/Notifications/ReminderEngagement.swift`、`Shared/Storage/PreferencesStore.swift`（連續 `LearnedSuggestion.dismissThreshold` = 5 次，`Shared/Models/PreferenceLedger.swift`） |
| 示範模式：允許 AI 後用真正的助理處理範例行程；沒有允許或 AI 無法使用時用離線規則 | `Shared/Orchestrator/DemoModeAssistant.swift`；`Shared/Calendar/CalendarRouter+Sample.swift`；`ChatViewModel.enableDemo()` |
| 同意前不送任何資料給 AI；同意說明的內容 | `GeminiClient.generate` 的 `consentRequired`；`Shared/Storage/AIConsentStore.swift`（`AIConsentDisclosure`，第 5 版；`serverNote` 在 1.0 是 nil） |
| 帳號 email 不會傳給 AI | `Shared/AI/CalendarAliases.swift`、`Shared/Models/PromptRedaction.swift`、`Tests/Unit/AccountEmailPrivacyTests.swift` |
| 伺服器不保存請求，也不存任何行程（1.0 沒有 push-to-start） | `server/worker/src/gemini.ts`；`AppConstants.pushToStartEnabled = false`、`PushToStartRegistrar.install(enabled:upload:)`；`server/worker/wrangler.toml` 的 `crons = []` |
| 沒有廣告、沒有追蹤 | `project.yml` 沒有第三方套件；`App/PrivacyInfo.xcprivacy` 的 `NSPrivacyTracking` 是 false |
| 匯出、移除帳號（撤銷授權）、清除所有資料 | `App/Privacy/DataExporter.swift`、`App/Auth/AccountManager.swift`、`App/Privacy/DataEraser.swift` |
| iOS 18 以上；繁體中文和英文 | `project.yml`（`deploymentTarget iOS 18.0`）；`Shared/Localization/Localizable.xcstrings` |

刻意**沒有**寫進商店文字的：主畫面小工具（沒有）、貼上連結就讀網頁內容（迴紋針只把網址文字貼進輸入框，Gemini 只看到網址文字）、
訂閱或 Pro、iPad 或 Mac、特定的 Gemini 模型版本、語音輸入（1.0 沒有麥克風；Siri 和鍵盤的聽寫是系統功能）。

---

## 12. 檢查字數的腳本

每個 `<!-- asc:… -->` 標記後面的區塊，對照 App Store Connect 的上限：名稱和副標題 30 字元、宣傳文字 170 字元、描述 4000 字元、
關鍵字 100 位元組、審核備註 4000 位元組（[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)、
[App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)）。

```python
import re, sys
LIMITS = {"name": (30, "chars"), "name.backup1": (30, "chars"), "name.backup2": (30, "chars"),
          "subtitle": (30, "chars"), "promo": (170, "chars"), "description": (4000, "chars"),
          "keywords": (100, "bytes"), "review-notes": (4000, "bytes")}
text = open(sys.argv[1], encoding="utf-8").read()
bad = 0
for field, body in re.findall(r"<!-- asc:([\w.-]+/[\w.-]+) -->\s*```[a-z]*\n(.*?)\n```", text, re.S):
    limit, unit = LIMITS[field.split("/", 1)[1]]
    size = len(body.encode("utf-8")) if unit == "bytes" else len(body)
    bad += size > limit
    print(f"{'OK ' if size <= limit else 'BAD'} {field:28} {size:5} / {limit} {unit}")
sys.exit(1 if bad else 0)
```
