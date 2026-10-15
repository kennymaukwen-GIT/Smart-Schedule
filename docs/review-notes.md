# App Review notes (paste into App Store Connect › App Review Information › Notes)

給審核員看的說明。以下英文段落可以直接貼到 App Store Connect 的 Notes 欄位；最後一節是送審前自己要確認的事項。

---

**How to review without a Google account.** On the first screen tap "Try without signing in". Demo mode has sample calendars and an offline assistant: no Google sign-in, nothing is sent to any AI service, and every feature below can be tried.

**Live Activities / Dynamic Island.** Smart Schedule shows a Live Activity only for an event that is about to start or under way:

- Each timed event gets its own Live Activity. It appears 30, 15, 10 or 5 minutes before the event starts (Settings › Notifications › Dynamic Island; default 30 minutes, or Off) and ends with the event: whenever Smart Schedule runs after the event (opening the app, a background refresh or a sync) it ends the activity, which then leaves the Lock Screen 10 minutes after the event ends. If the app does not run, iOS ends the activity at its 8-hour limit. The app sends no update pushes.
- When no event is coming up, there is no Live Activity. The app never keeps one open as a permanent widget.
- iOS 26: the app schedules each activity ahead with `Activity.request(…, start:)` for events in the next 48 hours, with the start alert iOS requires. iOS 18: a push-to-start notification from our server starts it at the same time.
- The countdown uses `Text(timerInterval:)`, so the activity needs no update pushes. `NSSupportsLiveActivitiesFrequentUpdates` is declared, but the app sends no frequent updates: only the one push-to-start per event on iOS 18.
- Tapping the Live Activity opens the app's quick-input screen (`smartschedule://compose`). Its microphone button opens the same screen with voice input.

**Control Center control.** The "Smart Schedule" control opens the app directly on the quick-input screen with the keyboard up (`openAppWhenRun`). It does not start a Live Activity.

**Time Sensitive notifications.** Reminders are Time Sensitive only when they fire 30 minutes or less before an event starts (the default "Automatic" urgency). Earlier reminders, the morning summary and suggestions are Normal. People can change the urgency per kind of event in Settings › Notifications › Urgency, including turning Time Sensitive off.

**Long-press on a reminder.** The notification content extension lets people reply to a reminder by typing or speaking. The extension calls the AI service and Google Calendar itself, so a change ("move it to 4 pm") or a deletion (confirmed with a red button) is done before the notification closes. It uses an ephemeral network session with a 30-second timeout.

**AI and personal data (Guideline 5.1.2(i)).** Before anything is sent, a one-time dialog explains that requests (typed, or spoken and transcribed to text) and the related events' titles, times, locations and notes are sent to Google's Gemini API, names Google as the recipient, and asks for permission ("Allow" / "Not now"). On iOS 18 the same dialog also says that the titles and start times of the next two days' events are kept on our server to start the Live Activities on time (no notes or places). Nothing is sent before the person taps Allow. Permission can be withdrawn in Settings › AI & privacy, and demo mode works without it.

**Sign in with Apple (Guideline 4.8).** Not required. The app has no account of its own. Connecting a Google account ("Connect Google Calendar" / "Add Google account") only authorizes access to the person's Google Calendar (Calendar scopes), the same way a calendar app connects to a calendar service. No app account is created and no login is needed to use the app (see demo mode).

**Background modes.** `fetch`: background app refresh syncs Google Calendar changes and keeps reminders and Live Activities up to date. `remote-notification`: Live Activity push-to-start on iOS 18.

**Microphone and speech recognition.** Used only while the person holds the microphone button, to turn a spoken plan into text.

---

## 送審前確認（不要貼給審核員）

- [ ] 用 Distribute App 匯出（TestFlight / App Store）後，`codesign -d --entitlements :- SmartSchedule.app` 的 `aps-environment` 是 `production`。專案裡所有設定都寫 `development`（和自動簽章的開發用 profile 一致），匯出時由發佈用 provisioning profile 改成 `production`；不要在 project.yml 寫死 production。
- [ ] Part B 的伺服器已部署，iOS 18 的 push-to-start 實測可用；否則上面 iOS 18 那句要改成「打開 App 時，行程在提前量內就出現」，同意視窗的伺服器說明也要先拿掉。
- [ ] App Store Connect 的 App Privacy 問卷與 `PrivacyInfo.xcprivacy` 一致：Other User Content（App Functionality，連結身分，不追蹤）、Device ID（App Functionality，連結身分，不追蹤）。
- [ ] 隱私權政策網址（`SSPrivacyURL`）換成真的頁面，內容涵蓋 Gemini 與伺服器暫存。
- [ ] 是否保留 `NSSupportsLiveActivitiesFrequentUpdates`：目前沒有任何頻繁更新，拿掉可以少一個被追問的點。
