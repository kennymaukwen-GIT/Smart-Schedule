# App Review notes（背景說明，不要整份貼上）

給審核員的說明的背景版本，比 App Store Connect 的 Notes 上限（4000 位元組）長，也沒有測試帳號和備用驗證碼。**要貼進 App Store Connect › App Review Information › Notes 的是 [`app-store-metadata.md`](app-store-metadata.md) 第 8.2 節的 `asc:en/review-notes` 區塊**（3,930 位元組）；審核員追問細節時，可以從下面的英文段落或第 8.3 節摘取。最後一節是送審前自己要確認的事項。

---

**How to review without a Google account.** On the first screen tap "Try without signing in". Demo mode has fictional sample calendars and needs no Google sign-in. Its assistant is the real one: after the "Use the AI assistant?" dialog it sends what the reviewer types and the sample events to Google's Gemini API (never Google data); without permission, or when the AI can't be reached, offline demo rules answer and the reply says so. Every feature below can be tried.

**Live Activities / Dynamic Island.** Smart Schedules shows a Live Activity only for an event that is about to start or under way:

- Each timed event gets its own Live Activity. It appears 30, 15, 10 or 5 minutes before the event starts (Settings › Notifications › Dynamic Island; default 30 minutes, or Off) and ends with the event: whenever Smart Schedules runs after the event (opening the app, a background refresh or a sync) it ends the activity, which then leaves the Lock Screen 10 minutes after the event ends. If the app does not run, iOS ends the activity at its 8-hour limit. No server is involved.
- When no event is coming up, there is no Live Activity. The app never keeps one open as a permanent widget.
- iOS 26: the app schedules each activity ahead with `Activity.request(…, start:)` for events in the next 48 hours, with the start alert iOS requires, so it appears on time even when the app is closed. iOS 18 cannot schedule an activity ahead, and version 1.0 does not start one from a server, so on iOS 18 the activity appears when the app is opened during the lead time or while the event is under way, and stays after the app is closed.
- Everything happens on the iPhone, on both versions: Live Activities need no AI data sharing, and no event details are sent to our server for them.
- The countdown uses `Text(timerInterval:)`, so the activity needs no updates from a server. `NSSupportsLiveActivitiesFrequentUpdates` is declared, but the app receives no updates from a server at all.
- Tapping the Live Activity opens the app's quick-input screen (`smartschedule://compose`). In the expanded Dynamic Island, the Edit button opens the same screen with the keyboard up.

**Control Center control.** The "Smart Schedules" control opens the app directly on the quick-input screen with the keyboard up (`openAppWhenRun`). It does not start a Live Activity.

**Time Sensitive notifications.** Reminders are Time Sensitive only when they fire 30 minutes or less before an event starts (the default "Automatic" urgency). Earlier reminders, the morning summary and suggestions are Normal. People can change the urgency per kind of event in Settings › Notifications › Urgency, including turning Time Sensitive off.

**Long-press on a reminder.** The notification content extension lets people reply to a reminder by typing (or with the keyboard's dictation). The extension calls the AI service (through our server) and Google Calendar itself, so a change ("move it to 4 pm") or a deletion (confirmed with a red button) is done before the notification closes. It uses an ephemeral network session with a 30-second timeout.

**AI and personal data (Guideline 5.1.2(i)).** Before anything is sent, a one-time dialog lists exactly what goes to Google's Gemini API: what the person types (or says to Siri or with the keyboard's dictation, which Apple turns into text before the app gets it), the titles, times, notes and Google event IDs of up to 40 events in the next 14 days and of the event whose reminder they reply to, the location of one event only when they ask for AI suggestions on it, their calendar names and assistant settings, and their time zone and language. Google account email addresses are never sent: the AI sees calendars as "Account 1", "Account 2", and the app removes the accounts' addresses from event text and error messages first. The dialog names Google as the recipient, says requests pass through our server, which does not keep them, and asks for permission ("Allow" / "Not now"). The same dialog appears when permission is given later in Settings › AI & privacy. Nothing is sent to the AI before the person taps Allow. Permission can be withdrawn in Settings › AI & privacy. Demo mode asks the same way; with permission its requests carry the fictional sample events instead of Google data, and without it offline rules answer. The current wording is version 5 of the disclosure, so people who allowed an earlier version are asked again.

**Sign in with Apple (Guideline 4.8).** Not required. The app has no account of its own. Connecting a Google account ("Connect Google Calendar" / "Add Google account") only authorizes access to the person's Google Calendar (Calendar scopes), the same way a calendar app connects to a calendar service. No app account is created and no login is needed to use the app (see demo mode).

**Background modes.** Only `fetch`: background app refresh syncs Google Calendar changes and keeps reminders and Live Activities up to date. Reminders are local notifications created on the iPhone.

**Microphone and speech recognition.** Not used. The app has no microphone button and asks for neither permission (no `NSMicrophoneUsageDescription` or `NSSpeechRecognitionUsageDescription`). People who prefer to speak can use Siri or the keyboard's dictation key; Apple turns the speech into text and the app only receives the text.

**In-app purchases.** Version 1.0 has no in-app purchases or subscriptions; every feature is free to use.

**Age rating.** The app is rated 18+ because the AI service it uses, Google's Gemini API, is only for people 18 or older.

---

## 送審前確認（不要貼給審核員）

- [ ] 1.0 沒有推播：用 Distribute App 匯出（TestFlight / App Store）後，`codesign -d --entitlements :- SmartSchedule.app` 的輸出裡**沒有** `aps-environment`，Info.plist 的 `UIBackgroundModes` 只有 `fetch`（`project.yml` 已拿掉 `aps-environment`、`APS_ENVIRONMENT` 和 `remote-notification`；`AppConstants.pushToStartEnabled` 和 `liveActivityPushEnabled` 都是 false 時，`scripts/validate_schema.py` 會擋下把它們加回來的改動）。App ID 不需要開 Push Notifications 功能。
- [ ] 上傳 build 後，看 App Store Connect 寄來的信有沒有 ITMS-90078（Missing Push Notification Entitlement）之類的警告：二進位檔裡還留著關掉的 push-to-start 程式碼。這是警告不是退件，1.0 不用推播，可以不理（請在畫面上確認）。
- [ ] Part B 的伺服器（Gemini 代理、App Attest）已部署，正式環境 `crons = []`、沒有 APNs secrets。實機確認上面 Live Activities 那段：iOS 18 在提前時間內打開 App 時即時動態出現、關掉 App 後還在，App 關著時不會出現（1.0 的預期行為）；iOS 26 在 App 關著時，排程的即時動態準時出現（App 沒有 `aps-environment` 也一樣，請在實機上確認）。同意視窗在兩種系統上都沒有伺服器那一段（`AIConsentDisclosure.serverNote` 在 1.0 是 nil）。
- [ ] App Store Connect 的 App Privacy 問卷與 `PrivacyInfo.xcprivacy` 一致：Other User Content（App Functionality，連結身分，不追蹤）、Device ID（App Functionality，連結身分，不追蹤；指 App Attest 金鑰 ID，1.0 沒有 push-to-start 的安裝 ID 或 push token）。
- [ ] 隱私權政策（`SSPrivacyURL` = https://www.smart-schedules.com/privacy，原始檔 `site/public/privacy.html`）已部署且打得開；佔位值都已填好。
- [ ] 是否保留 `NSSupportsLiveActivitiesFrequentUpdates`：目前沒有任何頻繁更新，拿掉可以少一個被追問的點。
- [ ] 1.0 不賣訂閱：`AppConstants.subscriptionsEnabled` 是 false（`ReleaseConfigurationTests`、`validate_schema.py` 第 7 項會檢查）；App Store Connect 不要把任何 App 內購買項目或訂閱附加到這個版本（已經建立的「Smart Schedules Pro」群組或商品就留著不送審）；App 隱私問卷不勾 Purchases（購買項目）。
- [ ] 要不要在上面的 In-app purchases 段落後面加一句（你決定；Guideline 2.3.1 不允許隱藏的功能，這段程式碼在 1.0 碰不到）："The binary contains StoreKit code for a possible later subscription; it is switched off at build time and can only be turned on in a later version submitted for review."
- [ ] 年齡分級：App Store Connect 的年齡分級設為 18+（Gemini API 的條款要求使用者年滿 18 歲；問卷算出來比較低就選較高的分級）；隱私權政策和支援頁寫同樣的最低年齡。
- [ ] 供應地區：1.0 不在歐洲經濟區、瑞士、香港、澳門和中國大陸上架。價格與供應狀況裡取消 27 個歐盟會員國，加上挪威、冰島、列支敦斯登、瑞士、香港、澳門和中國大陸（後三個沒有 Gemini API）；英國和其他地區照常上架（`app-store-metadata.md` 第 4.3 節）。
- [ ] 英國：開發者在英國，不需要英國 GDPR 第 27 條的代表人。到 ICO 網站（ico.org.uk）的「Do I need to pay the fee?」確認要不要繳資料保護費，金額以 ICO 網站為準（`app-store-metadata.md` 第 4.4 節第 4 點）。
- [ ] 1.0 沒有麥克風和語音辨識：上傳的 build 的 Info.plist 沒有 `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`（`plutil -p SmartSchedule.app/Info.plist | grep -E 'NSMicrophone|NSSpeech'` 什麼都不印）；App 隱私問卷不勾 Audio Data；實機上整個 App 不會跳出麥克風或語音辨識的權限提示。
