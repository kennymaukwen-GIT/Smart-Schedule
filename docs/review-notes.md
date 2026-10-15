# App Review notes（背景說明，不要整份貼上）

給審核員的說明的背景版本，比 App Store Connect 的 Notes 上限（4000 位元組）長，也沒有測試帳號和備用驗證碼。**要貼進 App Store Connect › App Review Information › Notes 的是 [`app-store-metadata.md`](app-store-metadata.md) 第 8.2 節的 `asc:en/review-notes` 區塊**（3,829 位元組）；審核員追問細節時，可以從下面的英文段落或第 8.3 節摘取。最後一節是送審前自己要確認的事項。

---

**How to review without a Google account.** On the first screen tap "Try without signing in". Demo mode has sample calendars and an offline assistant: no Google sign-in, nothing is sent to any AI service, and every feature below can be tried.

**Live Activities / Dynamic Island.** Smart Schedule shows a Live Activity only for an event that is about to start or under way:

- Each timed event gets its own Live Activity. It appears 30, 15, 10 or 5 minutes before the event starts (Settings › Notifications › Dynamic Island; default 30 minutes, or Off) and ends with the event: whenever Smart Schedule runs after the event (opening the app, a background refresh or a sync) it ends the activity, which then leaves the Lock Screen 10 minutes after the event ends. If the app does not run, iOS ends the activity at its 8-hour limit. The app sends no update pushes.
- When no event is coming up, there is no Live Activity. The app never keeps one open as a permanent widget.
- iOS 26: the app schedules each activity ahead with `Activity.request(…, start:)` for events in the next 48 hours, with the start alert iOS requires. iOS 18: a push-to-start notification from our server starts it at the same time, but only after the person allows AI data sharing (the consent dialog, or Settings › AI & privacy › Allow, which also works in demo mode), because the server needs the event titles. Without it, the activity appears when the app is opened during the lead time.
- The countdown uses `Text(timerInterval:)`, so the activity needs no update pushes. `NSSupportsLiveActivitiesFrequentUpdates` is declared, but the app sends no frequent updates: only the one push-to-start per event on iOS 18.
- Tapping the Live Activity opens the app's quick-input screen (`smartschedule://compose`). Its microphone button opens the same screen with voice input.

**Control Center control.** The "Smart Schedule" control opens the app directly on the quick-input screen with the keyboard up (`openAppWhenRun`). It does not start a Live Activity.

**Time Sensitive notifications.** Reminders are Time Sensitive only when they fire 30 minutes or less before an event starts (the default "Automatic" urgency). Earlier reminders, the morning summary and suggestions are Normal. People can change the urgency per kind of event in Settings › Notifications › Urgency, including turning Time Sensitive off.

**Long-press on a reminder.** The notification content extension lets people reply to a reminder by typing or speaking. The extension calls the AI service (through our server) and Google Calendar itself, so a change ("move it to 4 pm") or a deletion (confirmed with a red button) is done before the notification closes. It uses an ephemeral network session with a 30-second timeout.

**AI and personal data (Guideline 5.1.2(i)).** Before anything is sent, a one-time dialog lists exactly what goes to Google's Gemini API: what the person types or says (speech is turned into text by Apple's speech recognition, on the iPhone or on Apple's servers), the titles, times, notes and Google event IDs of up to 40 events in the next 14 days and of the event whose reminder they reply to, the location of one event only when they ask for AI suggestions on it, their calendar names and assistant settings, and their time zone and language. Google account email addresses are never sent: the AI sees calendars as "Account 1", "Account 2", and the app removes the accounts' addresses from event text and error messages first. The dialog names Google as the recipient, says requests pass through our server, which does not keep them, and asks for permission ("Allow" / "Not now"). The same dialog appears when permission is given later in Settings › AI & privacy. On iOS 18 it also says that the titles, start and end times, event IDs and calendar colours of the events in the next 48 hours are kept on our server and sent through Apple's push service to start the Live Activities on time (no notes or places). Nothing is sent to the AI before the person taps Allow. Permission can be withdrawn in Settings › AI & privacy, and demo mode never contacts the AI. The current wording is version 4 of the disclosure, so people who allowed an earlier version are asked again.

**Sign in with Apple (Guideline 4.8).** Not required. The app has no account of its own. Connecting a Google account ("Connect Google Calendar" / "Add Google account") only authorizes access to the person's Google Calendar (Calendar scopes), the same way a calendar app connects to a calendar service. No app account is created and no login is needed to use the app (see demo mode).

**Background modes.** `fetch`: background app refresh syncs Google Calendar changes and keeps reminders and Live Activities up to date. `remote-notification`: Live Activity push-to-start on iOS 18.

**Microphone and speech recognition.** Used only after the person taps the microphone button, until they tap it again or send, to turn a spoken plan into text.

**In-app purchases.** Version 1.0 has no in-app purchases or subscriptions; every feature is free to use.

**Age rating.** The app is rated 18+ because the AI service it uses, Google's Gemini API, is only for people 18 or older.

---

## 送審前確認（不要貼給審核員）

- [ ] 用 Distribute App 匯出（TestFlight / App Store）後，`codesign -d --entitlements :- SmartSchedule.app` 的 `aps-environment` 是 `production`。專案裡所有設定都寫 `development`（和自動簽章的開發用 profile 一致），匯出時由發佈用 provisioning profile 改成 `production`；不要在 project.yml 寫死 production。
- [ ] Part B 的伺服器已部署，iOS 18 的 push-to-start 實測可用；否則上面 iOS 18 那句要改成「打開 App 時，行程在提前量內就出現」，同意視窗的伺服器說明也要先拿掉。
- [ ] App Store Connect 的 App Privacy 問卷與 `PrivacyInfo.xcprivacy` 一致：Other User Content（App Functionality，連結身分，不追蹤）、Device ID（App Functionality，連結身分，不追蹤）。
- [ ] 隱私權政策（`SSPrivacyURL` = https://smart-schedules.com/privacy，原始檔 `site/public/privacy.html`）已部署且打得開；佔位值都已填好。
- [ ] 是否保留 `NSSupportsLiveActivitiesFrequentUpdates`：目前沒有任何頻繁更新，拿掉可以少一個被追問的點。
- [ ] 1.0 不賣訂閱：`AppConstants.subscriptionsEnabled` 是 false（`ReleaseConfigurationTests`、`validate_schema.py` 第 7 項會檢查）；App Store Connect 不要把任何 App 內購買項目或訂閱附加到這個版本（已經建立的「Smart Schedule Pro」群組或商品就留著不送審）；App 隱私問卷不勾 Purchases（購買項目）。
- [ ] 要不要在上面的 In-app purchases 段落後面加一句（你決定；Guideline 2.3.1 不允許隱藏的功能，這段程式碼在 1.0 碰不到）："The binary contains StoreKit code for a possible later subscription; it is switched off at build time and can only be turned on in a later version submitted for review."
- [ ] 年齡分級：App Store Connect 的年齡分級設為 18+（Gemini API 的條款要求使用者年滿 18 歲；問卷算出來比較低就選較高的分級）；隱私權政策和支援頁寫同樣的最低年齡。
- [ ] 供應地區：1.0 不在歐洲經濟區和瑞士上架。價格與供應狀況裡取消 27 個歐盟會員國，加上挪威、冰島、列支敦斯登和瑞士；英國和其他地區照常上架。
