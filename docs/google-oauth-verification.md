# Google OAuth 驗證送審手冊（品牌驗證＋敏感 scope 驗證）

Smart Schedules 要求兩個 Google Calendar 的**敏感 scope**（`calendar.events`、`calendar.calendarlist.readonly`），所以正式上線前要在 Google Auth Platform 完成兩件事：**品牌驗證**（App 名稱和 logo 才會出現在同意畫面）和**敏感 scope 驗證**。這份文件列出要填的每個欄位、要貼進表單的英文、示範影片的分鏡腳本、送審順序、常見退件原因，以及回覆審查信的範本。

> **2026-10-22 狀態：Google 驗證已通過**（擁有者回報）。之後的改動：出發提醒「該出發了」在 2026-10-20 決定延到 **1.1**，改用 Google Routes API（使用者的位置和行程地點經過 Smart Schedules 的伺服器送到 Google），程式只在 `claude/departure-reminders` 分支；**1.0 沒有這個功能，也不取得位置**。網站的隱私權政策和使用條款在 2026-10-22 拿掉了出發提醒（政策第 8 節只剩語音輸入等；條款原本的第 9 節刪除，後面各節往前一號）。下面提到出發提醒、Apple 地圖服務（MapKit）或 Google 地圖的段落是當時送審的寫法，留作紀錄，**不要再貼**。1.1 送出前：照新的做法改寫政策和條款，更新第 4.2、5.2 節的資料使用說明，並確認是否要通知 Google（這是新的資料傳輸：位置和行程地點經我們的伺服器送到 Google Routes）。

- 中文是說明；`text` 區塊裡的英文是要**原樣貼進 Google 表單或回信**的內容。
- 依據的程式是 2026-10-16 的工作目錄（Google 帳號 email 不送給 Gemini（同意說明第 4 版起）；1.0 不用 iOS 18 的即時動態 push-to-start，伺服器不存任何行程，同意畫面在 iOS 18 也沒有伺服器那一段（第 5 版起）），加上 2026-10-18 的決定：AI 同意說明在 1.0 是**第 7 版**，列五項（第 6 版曾加入附件那一項，只出現在 TestFlight；附件延到 1.1 後拿掉）；1.0 會一起上的兩項：App 自己的語音輸入（只在 iPhone 上辨識，已在程式裡），以及出發提醒「該出發了」（只有使用者問什麼時候該出發、或說要在什麼時間到哪裡時才取得位置，只送到 Apple 的地圖服務；行程的地點和開始時間也送到那裡，見 5.1）。出發提醒在審查期間建置；隱私權政策已先照 1.0 上架時的樣子寫好，審查期間不再改政策（2026-10-19 例外：App 還沒有這個功能，網站的政策和條款把它標成「即將推出」，見 5.1）。1.0 不賣任何東西，也沒有照片或 PDF 附件：AI 訂閱和附件延到 1.1，送審內容和影片都不提（1.1 加入時照第 9 節處理）。網站在 **https://www.smart-schedules.com**（Vercel，DNS 留在 Squarespace，見 [`site/README.md`](../site/README.md) §3）。程式的 scope、同意說明或網站改了，這份文件、表單和影片都要跟著改。
- Google 的官方頁面（developers.google.com、support.google.com）在撰寫環境打不開，下面的規定來自這些頁面的搜尋摘要，另有幾項來自第三方或開發者論壇（會註明）。**送審前請再讀一次第 10 節列出的原文**，按鈕名稱以控制台實際顯示為準。

> **重要，先讀這段：Cloud 專案在 Google Workspace 組織 `smart-schedules.com` 底下（2026-10-15 依 Admin console 截圖更新）**
>
> 擁有者有 Google Workspace：組織「Smart Schedule」，smart-schedules.com 是主要網域（Verified）。support@smart-schedules.com 是這個 Workspace 的**真實 Gmail 信箱**，也是登入 Google Cloud 的帳號；Cloud 控制台顯示「Set up Google Cloud for your organisation」，表示專案建在組織 `smart-schedules.com` 底下（專案選擇器（project picker）裡專案上方的組織名稱，請在畫面上確認）。所以：
>
> - **Audience › User type 一定選 External，不要選 Internal。** Internal 只有在專案屬於 Workspace 組織時才會出現，選了之後只有這個 Workspace 自己的帳號（`@smart-schedules.com`）能登入：App Review 審核員和真正的使用者（Gmail 或其他學校、公司的帳號）都會被 Google 擋下，而且 Internal 的 App 不走第 3.6 節的送審。已經選成 Internal 的話，到 Audience 頁改成 External（按鈕名稱類似 **Make external**，請在畫面上確認）。
> - **Publishing status 要從 Testing 改成 In production**（第 3.5 節）。External 而且還在 Testing 時，只有測試使用者能登入，refresh token 7 天就失效。
> - **User support email 和 Developer contact information 都填 support@smart-schedules.com。** 它是真實信箱，用它登入時會直接出現在 User support email 的下拉選單（第 3.2 節）；Google 的審查信也會寄到這裡，在 Gmail 裡直接回覆即可。
> - **Search Console 的網域驗證可能已經完成**：Workspace 驗證 smart-schedules.com 時通常會在 DNS（Squarespace）加一筆 `google-site-verification` TXT（也可能用別的方式驗證），用同一個帳號在 Search Console 新增網域資源時可能直接通過（請在畫面上確認）。見第 3.1 節。
> - **DNS 留在 Squarespace，不搬到 Cloudflare**（nameserver `nsa1`～`nsa4.squarespacedns.com`，DNSSEC 照舊）。網站只在 Squarespace 加一筆 `www` 的 CNAME 指到 Vercel（[`site/README.md`](../site/README.md) §3.3）。Google 的 MX、SPF、DKIM、DMARC 和**每一筆** `google-site-verification` TXT 一筆都不要動，也不用 Cloudflare Email Routing；刪了 MX，support@ 收不到信，Google 的審查信也會漏掉；刪了驗證 TXT，Workspace 和 Search Console 的網域驗證都會失效。
> - 整個 Cloud 組織和專案都掛在 support@ 這個 Workspace 帳號上：Workspace 訂閱要持續有效，帳號要設好救援 email 和電話。新建立的組織可能預設啟用「Domain restricted sharing」（`iam.allowedPolicyMemberDomains`）這類組織政策，在 IAM 加入組織外的帳號（例如個人 Gmail）時可能被擋（請在畫面上確認）。「Set up Google Cloud for your organisation」精靈不是 OAuth 驗證的前提，可以之後再做（請在畫面上確認）。

## 0. 一覽：要填的值

| 欄位（Google Auth Platform） | 填什麼 |
|---|---|
| App name | `Smart Schedules`（和首頁、App Store、iPhone 上的名稱完全一致；不能含「Google」。「Smart Schedule」在 App Store 已經有人用，所以名稱多一個 s：Branding 之前填過「Smart Schedule」的話要改掉，已經送審或核准時改名會重新審查（第 9 節）。Workspace 的組織名稱「Smart Schedule」是另一回事，不用跟著改） |
| User support email | `support@smart-schedules.com`（Workspace 的真實信箱；用它登入才會出現在下拉選單，見 3.2） |
| App logo | [`site/public/logo.png`](../site/public/logo.png)（120×120 PNG，約 3 KB，由 App 圖示縮小，和首頁同一張） |
| Application home page | `https://www.smart-schedules.com` |
| Application privacy policy link | `https://www.smart-schedules.com/privacy` |
| Application terms of service link | `https://www.smart-schedules.com/terms`（使用條款頁，`site/public/terms.html`；這個專案的 Branding 表單不讓這一欄空白（2026-10-18）。條款說明 App 的使用授權依 Apple 的標準 EULA，另外加上服務規則。不要填支援頁 `/support`：它不是條款） |
| Authorized domains | `smart-schedules.com`（不加 `www`；授權網域涵蓋它的子網域，首頁和政策放在 www 沒問題） |
| Developer contact information | `support@smart-schedules.com`（真實信箱，審查信寄到這裡） |
| Audience › User type | **External**（不要選 Internal，見文件開頭的提醒） |
| Audience › Publishing status | **In production**（第 3.5 節） |
| Clients | 只有一個：類型 **iOS**、Bundle ID `com.smartschedules.app` |
| Data access › scopes | `openid`、`.../auth/userinfo.email`、`.../auth/calendar.events`、`.../auth/calendar.calendarlist.readonly`（第 1 節） |
| Limited Use 聲明 | 首頁 https://www.smart-schedules.com/ 的「AI and privacy」段落；隱私權政策第 11 節 https://www.smart-schedules.com/privacy#en-limited-use （中文 `#zh-limited-use`） |

## 1. App 實際要求的 scope（已對照程式）

授權網址由 [`Shared/Auth/GoogleAuthorization.swift`](../Shared/Auth/GoogleAuthorization.swift) 產生，scope 清單是 [`Shared/Auth/GoogleTokenProvider.swift`](../Shared/Auth/GoogleTokenProvider.swift) 的 `GoogleTokenProvider.scopes`，登入流程在 [`App/Auth/GoogleSignInCoordinator.swift`](../App/Auth/GoogleSignInCoordinator.swift)（`ASWebAuthenticationSession` 加 PKCE S256，`access_type=offline`、`prompt=consent`、`include_granted_scopes=true`，有輸入 email 時帶 `login_hint`）。

| Scope（App 送出的字串） | Data access 裡的名稱 | 分類 | 用在哪裡 |
|---|---|---|---|
| `openid` | `openid` | 非敏感（登入用） | ID token 的 `sub`：每個帳號的 Keychain 項目和資料都以它為 key（[`Shared/Auth/IDToken.swift`](../Shared/Auth/IDToken.swift)） |
| `email` | `https://www.googleapis.com/auth/userinfo.email` | 非敏感（登入用） | ID token 的 email：抽屜和帳號頁顯示帳號、比對使用者輸入的 email 和實際登入的帳號。不以帳號資訊傳給伺服器或 Gemini（見 4.6） |
| `https://www.googleapis.com/auth/calendar.events` | 同左 | **敏感** | `events.list` / `get` / `insert` / `patch` / `delete`（[`Shared/Calendar/GoogleCalendarClient.swift`](../Shared/Calendar/GoogleCalendarClient.swift)）：顯示、提醒、即時動態；使用者或助理新增、修改、刪除行程 |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | 同左 | **敏感** | 只有 `calendarList.list`（`minAccessRole=reader`）：抽屜裡列出每個行事曆的名稱、顏色、權限，選擇顯示哪些、新行程寫到哪裡 |

- **沒有要求**：完整的 `calendar`（程式只是接受舊版授權裡已有的它，見 `GoogleAuthorization.calendarScope`）、`calendar.readonly`、`userinfo.profile`。Data access 裡也不要加，否則和 App 實際要求的不一致，使用者會看到「未驗證」畫面。
- 舊版單一帳號安裝的搬移流程會用既有的 `openid email` 授權呼叫一次 `openidconnect.googleapis.com/v1/userinfo`，不需要新的 scope。
- 兩個以上的非登入 scope 會讓 Google 顯示**可勾選的細部同意畫面**（granular consent）。使用者沒勾 `calendar.events` 時 App 不連接這個帳號，請他重試並勾選行事曆權限（新帳號的這次授權會被撤銷）；沒勾行事曆清單時只同步主要行事曆，抽屜提供「Show all calendars」再要一次。
- 撰寫時查到的官方描述：`calendar.events` = "View and edit events on all your calendars"；`calendar.calendarlist.readonly` = "See the list of Google calendars you're subscribed to"。控制台 Data access 頁會自動把 scope 分成非敏感／敏感／受限，以它顯示的為準（README 和 [`docs/GOOGLE_CALENDAR_SYNC.md`](GOOGLE_CALENDAR_SYNC.md) 都記為敏感）。

## 2. 送審前檢查

- [ ] **網站已上線**：`https://www.smart-schedules.com`、`https://www.smart-schedules.com/privacy` 和 `https://www.smart-schedules.com/terms` 直接回 200（不要用 `/privacy.html`、`http://` 或沒有 `www` 的根網域：前兩個會轉址，根網域不提供網站，最多轉到 www）。`grep -rn 'class="todo"' site/public` 什麼都不印（開發者名稱等佔位字已替換，見 [`site/README.md`](../site/README.md) 第 1 節）。網站沒有會擋機器人的驗證頁（DNS 不在 Cloudflare，所以沒有 Cloudflare 區域層級的 Bot Fight Mode、Under Attack 這些設定；用 `curl -sI https://www.smart-schedules.com/privacy` 看到 `200` 就好）。
- [ ] **首頁**：說明 App 做什麼、為什麼要用 Google 日曆，連到隱私權政策，有 Limited Use 聲明（`index.html` 的「AI and privacy」）。不是登入頁。
- [ ] **隱私權政策**：第 3 節逐一列出四個 scope 和用途，第 4 節說明 AI 送出什麼（和 App 的同意說明第 7 版的五項逐字相同），第 5 節說明即時動態只在 iPhone 上產生，第 7 節寫 1.0 沒有任何 App 內購買，第 8 節語音輸入只在 iPhone 上辨識和出發提醒（位置只送到 Apple 的地圖服務，行程只存提早分鐘數、交通方式和開始前幾分鐘出發），第 11 節 Limited Use（傳輸清單包括出發提醒用的 Apple 地圖服務和 Google 地圖），第 13 節保存期限，第 15 節刪除方式。
- [ ] **App**：TestFlight 上的版本已包含同意說明第 7 版（`AIConsent.disclosureVersion` = 7：只列五項，第 6 版的附件那一項拿掉了；同意的內容變了，所以在 TestFlight 上允許過第 5 或第 6 版的人也要重新同意，符合政策第 18 節；`CalendarAliases` 取代帳號 email，`AppConstants.pushToStartEnabled = false`），CI 的 `AccountEmailPrivacyTests` 和 `AIConsentStoreTests` 通過。影片要用這個版本錄。**錄影前**確認同意畫面是**五項**、沒有「A photo or PDF you attach …」那一項，語音那一句是目前程式的文字（「… The microphone button in Smart Schedules does it on your iPhone. Smart Schedules sends only the text, never audio.」），這樣影片裡的同意畫面才和政策第 4 節的引用一致；主畫面的對話輸入列也沒有迴紋針（1.0 把它藏起來了）。
- [ ] **Gemini 是付費層級**：Gemini API 的 Google Cloud 專案已連結有效的 Cloud Billing，AI Studio 的記錄（Logs）關閉、沒有選擇把資料集分享給 Google（[`site/README.md`](../site/README.md) 第 2 節）。這是下面「不用於訓練」那些句子成立的條件；免費層級時**不要送審**。英國也在上架範圍，Gemini 條款要求對英國使用者只能用付費服務，所以本來就必須是付費層級。
- [ ] **Cloud 專案**：已啟用 Google Calendar API；Google Auth Platform › Clients 只有一個 iOS client（Bundle ID `com.smartschedules.app`，填好 Team ID）。測試時建立的 Web／Desktop client 先刪掉：Google 要求影片涵蓋專案裡所有 OAuth client。
- [ ] **測試用 Google 帳號**：專門用來錄影的帳號（文件裡寫成 `example@gmail.com`），不要有真實的個人資料。準備幾個明天以後的行程、兩個自己的行事曆（例如 My calendar、Gym），再由另一個帳號共用一個行事曆給它（例如 Test，權限「See all event details」），或在 Other calendars › Browse calendars of interest 加一個國定假日行事曆，抽屜裡才看得到唯讀行事曆。行程可以用匯入 .ics 的方式建立（Settings › Import & export），建議設成每週重複，之後 Apple 審查時才不會已經過去。
- [ ] **信箱有人看**：support@smart-schedules.com（Google Workspace 的 Gmail 信箱）和 Cloud 專案擁有者的信箱（擁有者就是 support@ 時是同一個）。審查只用 email 聯絡專案的擁有者／編輯者和開發者聯絡信箱；第三方文章說來信的寄件地址以 `api-oauth-dev-verification-reply` 開頭（google.com），記得檢查垃圾郵件，並把它加進聯絡人。
- [ ] **support@ 收發信正常**：Squarespace DNS 裡 Google 的 MX、SPF 和所有 `google-site-verification` TXT 都還在，加 `www` CNAME 時沒有動到（Google Admin Toolbox 的 Check MX，或 `dig MX smart-schedules.com`）；做完 Admin console 的「Complete email setup」（DKIM、DMARC，紀錄加在 Squarespace），回給審查員的信比較不會被當成垃圾郵件。步驟見 [`site/README.md`](../site/README.md) §3.6。

## 3. 送審步驟（依序）

Search Console 驗證網域 → Branding（驗證並發佈品牌）→ 錄影片 → Data access（scope、用途說明、影片連結）→ Audience 發佈到 In production → Verification Center 送審。

整個過程用**同一個 Google 帳號**操作：support@smart-schedules.com（Workspace 帳號）。它是 Cloud 專案的 Owner，也是 Search Console 裡 smart-schedules.com 的擁有者（論壇上 Google 的回覆要求驗證網域的帳號是專案的 Owner 或 Editor）。

### 3.1 Search Console：驗證 smart-schedules.com

**可能已經驗證過了**：smart-schedules.com 是 Workspace 的主要網域，Workspace 驗證網域時通常會在 DNS 加一筆 `google-site-verification` TXT（請在 Squarespace › 網域（Domains）› `smart-schedules.com` › DNS › DNS 設定（DNS Settings）確認，可能在「Google Workspace」區塊或自訂紀錄（Custom Records）裡）。用驗證 Workspace 網域的同一個帳號（support@smart-schedules.com）在 Search Console 新增網域資源時，可能直接顯示已驗證，或給你和 DNS 裡已有的那筆相同的值，按驗證就通過（請在畫面上確認）。沒有的話照下面做。

1. 用上面那個帳號登入 https://search.google.com/search-console ，「新增資源」選**網域**（Domain），輸入 `smart-schedules.com`。不要選「網址前置字元」（URL prefix）：OAuth 驗證要的是網域層級的所有權。
2. 複製畫面上的 TXT 記錄（`google-site-verification=…`）。
3. Squarespace（https://account.squarespace.com/domains）› `smart-schedules.com` › DNS › DNS 設定（DNS Settings）› 自訂紀錄（Custom Records）› 新增紀錄（Add Record）：主機（Host）`@`、類型（Type）`TXT`、資料（Data）貼上，儲存（Save）。Search Console 如果提供自動驗證（登入 Squarespace 授權後自動加 TXT），也可以用（請在畫面上確認；詳見 [`site/README.md`](../site/README.md) §3.7）。根網域已經有 Workspace 用的 `google-site-verification` TXT 時，**另外加一筆**，不要覆蓋或刪掉舊的；同一個名稱可以有好幾筆 `google-site-verification` TXT（只能有一筆的是 SPF，`v=spf1` 開頭的那筆）。
4. 回 Search Console 按「驗證」。DNS 生效可能要幾分鐘到 24 小時。Squarespace 的 DNSSEC 不用動，新紀錄會一起簽章。
5. 通過後**不要刪掉任何一筆 `google-site-verification` TXT**，刪了會失去驗證（Workspace 用的那筆刪了，Workspace 的網域驗證也會失效）。網域資源 `smart-schedules.com` 涵蓋 `www.smart-schedules.com`，網站放在 www 不用另外驗證。之後換人管理時，在 Search Console › 設定 › 使用者和權限 加入新的擁有者，同時在 Cloud IAM 給他 Owner 或 Editor。

### 3.2 Branding：填資料、驗證、發佈

Google Cloud 控制台 › **Google Auth Platform**（從 APIs & Services › OAuth consent screen 也會進到這裡）。第一次設定時「Get started」精靈會依序問 App 資訊、Audience（選 **External**；專案在 Workspace 組織底下，所以也會出現 Internal，**不要選**，見文件開頭的提醒）、聯絡資訊（填 support@smart-schedules.com），最後同意 Google API Services User Data Policy。

到 **Branding** 頁，照第 0 節的表填：

- **User support email**：下拉選單只列出目前登入的帳號和你管理的 Google 群組。support@smart-schedules.com 是 Workspace「Smart Schedule」的真實帳號，用它登入 Cloud 控制台時就在選單裡，直接選它。用別的帳號（例如個人 Gmail）登入時它不會出現，改用 support@ 登入再選；整個專案和 Search Console 都由這個帳號擁有最簡單。不需要另外註冊 Google 帳號或用轉寄地址。不要選個人信箱。
- **App logo**：上傳 `site/public/logo.png`。規定：正方形、不超過 1 MB、JPG／PNG／BMP，建議 120×120 px，不能用 Google 的產品圖示或商標，送審後要和同意畫面上的一致。上傳 logo（或顯示 App 名稱）就需要品牌驗證。
- **Terms of service**：`https://www.smart-schedules.com/terms`（必須在已驗證的網域上，而且真的是使用條款；先確認網址回 200 再填）。
- **Authorized domains**：先加 `smart-schedules.com`（不加 `www`），再填首頁 `https://www.smart-schedules.com` 和政策網址 `https://www.smart-schedules.com/privacy`。

儲存後：

1. 按 **Verify branding**。自動檢查通常幾分鐘；進行中不能改 Branding。
2. 結果是 **Ready to publish** → 按 **Publish branding**。通過的結果只保留 7 天，過期會變成 **Need to re-verify**，要重跑。
3. 結果是 **Need to fix issues** → 按 **View issues** 看原因（常見原因見第 7 節），修好後再驗證；確定是誤判時，可以從 View issues 到 Verification Center 申請人工複查。Google 說品牌驗證的人工審查通常 2–3 個工作天。

Verification Center 的「Prepare for verification」在品牌**驗證並發佈**之前是灰的。

### 3.3 錄示範影片

品牌發佈之後再錄，同意畫面才會顯示「Smart Schedules」和 logo（Google 說品牌未驗證時同意畫面只顯示網域）。腳本和技巧在第 6 節。上傳 YouTube，可見度設 **Unlisted（不公開）**，複製連結。

### 3.4 Data access：宣告 scope、用途說明、影片

1. **Data access › Add or remove scopes**：勾 `openid`、`.../auth/userinfo.email`、`.../auth/calendar.events`、`.../auth/calendar.calendarlist.readonly`。清單裡找不到 Calendar 的 scope，代表 Calendar API 還沒啟用（APIs & Services › Library），或直接貼進「Manually add scopes」。不要加第 1 節列為「沒有要求」的 scope。
2. 確認分類：2026-10-18 的控制台把 `calendar.calendarlist.readonly` 放在 **Your non-sensitive scopes**（和 `openid`、`userinfo.email` 一起），**Your sensitive scopes** 只有 `calendar.events`。以控制台顯示的為準。
3. 「How will the scopes be used?」只有一個欄位，上限 1,000 字元：貼第 4.5 節（只講 `calendar.events`：為什麼要查看、為什麼要編輯、為什麼更窄的 scope 不夠，971 字元）。`calendar.calendarlist.readonly` 又被列為敏感時，改貼 4.4 節的合併版（998 字元）。4.2、4.3 節的長版留著回覆審查員的提問。影片欄位貼 YouTube 連結。
4. Save。

### 3.5 Audience：發佈到 In production

先確認 **Audience › User type 是 External**。這個專案在 Workspace 組織 `smart-schedules.com` 底下，User type 可以是 Internal，但 Internal 只讓 `@smart-schedules.com` 的帳號登入，審核員和使用者都會被擋；是 Internal 的話先改成 External（按鈕名稱類似 **Make external**，請在畫面上確認）。

接著 **Audience › Publishing status: Testing → Publish app**，確認後變成 **In production**。

- Testing 狀態下，Google 發的 refresh token **7 天就失效**（App 會要求重新連接），而且只有測試使用者能登入。發佈後不再有 7 天限制。
- 驗證通過前，使用者登入會先看到「Google hasn't verified this app」，而且最多 100 個新使用者。所以 **App Store 版要等驗證通過再上架**；Apple 審核員用審核備註裡的測試 Google 帳號登入時也會看到這個畫面（審核備註先介紹「Try without signing in」，再請他們用測試帳號試完整功能，見 [`docs/app-store-metadata.md`](app-store-metadata.md) 第 8.2 節），所以送 App Store 審核前就要通過驗證、設成 In production（同一份文件第 0 節）。

### 3.6 Verification Center：送審

1. **Verification Center › Prepare for verification**。
2. 核對畫面上的 Branding、scope 和影片連結；確認遵守 Google API Services User Data Policy。
3. 有「Additional information」之類的欄位時，貼第 4.1 節（App 說明）和第 5.2 節（AI 資料使用）的英文。
4. **Submit for verification**。專案聯絡人會收到確認信，狀態在 Verification Center 看。

### 3.7 送出之後

- **時間**：Google 的開發者文件寫敏感 scope 審查通常 3–5 個工作天，Cloud 說明中心的常見問題寫約 10 個工作天；2026 年論壇上也有人等了好幾週甚至幾個月。至少在預定上架日前 6 週送審。實例：一個同樣用 `calendar.events` 的 App 在 2026-09-28 送審、10-02 核准，中間只來回一次（首頁需要登入才能看，改成公開首頁後通過）。
- **審查期間不要改** Branding、scope、Clients 或網站上的政策，改了可能重新排隊。要改就先在信裡告訴審查員。
- **審查信要回**：見第 8 節。超過約 10 個工作天沒有任何信，先查垃圾郵件，再到 Verification Center 看狀態；論壇上不少人說「重新送出會讓排隊重來」，所以不要為了催件而重送，改用 Google Cloud 支援或開發者論壇詢問。

## 4. 要貼進表單的英文：App 說明和 scope 用途

### 4.1 App 說明（Additional information 或審查員問「App 做什麼」時）

```text
Smart Schedules is an iPhone calendar app and AI scheduling assistant for Google Calendar (iOS 18 or later). Users connect one or more Google accounts and see, add, change and delete their Google Calendar events in month, week and day views, with reminders and Live Activities on the iPhone. They can also type or say requests such as "lunch with Joe tomorrow at 12:30" (speech from the app's microphone button is turned into text on the iPhone; Siri also works), and an optional AI assistant, used only after the user allows it in an in-app consent dialog, turns them into calendar events.

Calendar sync runs directly between the iPhone and the Google Calendar API. OAuth tokens are kept in the iOS Keychain and are only ever sent to Google (the Calendar API and Google's token and revoke endpoints). Users can remove an account in the app, which revokes the app's access at Google.

Home page: https://www.smart-schedules.com
Privacy policy: https://www.smart-schedules.com/privacy (Google permissions: section 3; AI assistant: section 4; departure reminders: section 8; Limited Use: section 11)
```

### 4.2 `calendar.events`

```text
Smart Schedules is a Google Calendar client for iPhone. It uses calendar.events to:
1. Read events (events.list, events.get) in the user's calendars to show them in month, week and day views and in the event list, and to schedule reminders, departure reminders and Live Activities on the iPhone.
2. Create events (events.insert) when the user adds them, for example by typing "lunch with Joe tomorrow at 12:30" to the in-app assistant (or saying it to Siri), or by tapping Add on events or a plan the assistant proposed.
3. Change events (events.patch) when the user edits the title, time, location, reminders or notes on the event page, or asks the assistant to move an event or when to leave for it (the app then saves in the event's private extended properties only how many minutes early the user wants to arrive, the travel mode and how many minutes before the start to leave).
4. Delete events (events.delete) when the user taps Delete event, asks the assistant to delete an event, or confirms a bulk deletion the assistant proposed (several events, a whole series or a plan).
All calls are made by the app on the user's iPhone directly to the Google Calendar API, in response to the user's actions or to keep the on-device copy in sync.

Why a narrower scope is not enough: calendar.events.readonly and calendar.events.owned.readonly cannot create, change or delete events. calendar.events.owned covers only calendars the user owns, but users also see calendars other people share with them and edit the shared calendars they have "Make changes to events" access to (family or team calendars). calendar.app.created covers only calendars the app itself creates, while users manage events in their existing calendars. calendar.events.freebusy returns no event details. We do not request the full calendar scope: the app never changes calendar settings or sharing, and never creates or deletes calendars.

Data handling: calendar data is cached on the iPhone. Our server is not involved in sync and never receives OAuth tokens. Only after the user taps Allow in the in-app "Use the AI assistant?" dialog does the assistant send the request with limited event details (titles, times, notes and event IDs of up to 40 events in the 14 days from today; never Google account email addresses) through our server, which does not store it, to Google's Gemini API on a billed (paid) Cloud project. When the user asks when to leave for an event, the app sends that event's location and the time the user needs to arrive (from its start time), with the iPhone's current location (only with the iOS When In Use permission), from the iPhone to Apple's map service (MapKit) to estimate the travel time; this does not go through our server or to Gemini, and the location is not stored. If the user taps the leave button on the departure notification, the app opens Google Maps with the event's location text only. Reminders and Live Activities are created on the iPhone; no calendar data is stored on our server. We never sell Google user data, use it for ads, or use it to train any AI or ML model.
```

### 4.3 `calendar.calendarlist.readonly`

```text
Used for one call, calendarList.list (minAccessRole=reader), to read the list of the user's Google calendars: each calendar's ID, name, colour, access role, primary flag and time zone. The app shows this list in its sidebar under each connected account, so the user can show or hide each calendar, choose the calendar new events go to, and see which calendars are read-only (the app offers no edits there). The app only reads the list; it never adds, removes or changes calendars or calendar list entries.

Why a narrower scope is not enough: calendar.calendars.readonly reads a calendar's properties only when its ID is already known; it cannot list the user's calendars. calendar.calendarlist (read/write), calendar.readonly and calendar are broader than needed. If the user does not grant this permission, the app still works with the primary calendar only and offers "Show all calendars" to ask again later.
```

### 4.4 合併版（表單只有一個欄位，或欄位有字數限制時）

4.2 約 3,000 字元、4.3 約 900 字元，下面這段不到 1,000 字元（998 字元）。

```text
Smart Schedules is a Google Calendar client and AI scheduling assistant for iPhone.
calendar.events: reads events for calendar views, reminders and Live Activities; creates, changes and deletes events when the user does so or asks the assistant. Narrower scopes do not fit: readonly scopes cannot write, calendar.events.owned excludes shared calendars, calendar.app.created covers only app-created calendars.
calendar.calendarlist.readonly: calendarList.list only, to list the user's calendars to show or hide them and pick where new events go. calendar.calendars.readonly cannot list calendars.
Sync is direct between iPhone and Google. Only with in-app consent: limited event details (no account emails) pass through our server (not stored) to the paid Gemini API. Departure reminders send an event's place and start time to Apple's MapKit, its place to Google Maps on tap. Reminders and Live Activities are made on the iPhone; our server stores no calendar data. No ads, no sale, no AI training.
```

### 4.5 只有 `calendar.events` 是敏感 scope 時（Data access 的欄位，971 字元）

只回答欄位問的事：為什麼要「查看」和「編輯」行程，以及為什麼更窄的 scope 不夠（老闆 2026-10-19：不要放無關的內容）。伺服器、Gemini 和 Limited Use 的說明在隱私權政策裡，審查員問到時再用 4.2、4.3 節回答。

```text
Smart Schedules is an iPhone calendar app for the user's Google Calendar.

Why we need to view events: the app shows the user's events in month, week and day views and in a list of upcoming events, and before each event it sends a reminder and shows a countdown on the Lock Screen and Dynamic Island. These need each event's title, time and location.

Why we need to edit events: the user creates events, changes their time, title, location or notes, and deletes them, in the app's event editor or by asking the in-app assistant (for example "move my 3 pm meeting to 4"). The app saves these changes to the user's Google Calendar.

Why narrower scopes aren't sufficient: calendar.events.readonly can view but not create, change or delete events; calendar.events.owned only covers calendars the user owns, not calendars shared with them; calendar.app.created only covers calendars the app creates, not the user's existing calendars; free/busy scopes show no event details.
```

### 4.6 `openid`、`email`（非敏感，表單通常不問；審查員問到時用）

```text
openid and email identify which Google account the user connected. The app reads the account ID (sub) and email address from the ID token, stores that account's sign-in on the iPhone under its ID, shows the address in the sidebar and account list so users with several Google accounts can tell them apart, and checks that the account signed in on Google's page is the one the user typed. The app does not send the address as account information to our server or the AI service: calendars are named 'Account 1', 'Account 2', and the address is replaced by a placeholder in the user's requests and in event text sent to the AI. Apart from Google itself, the app sends the address nowhere.
```

## 5. AI（Gemini）資料使用說明

### 5.1 重點（中文）

審查員最可能問：Google 使用者資料（行事曆）被送到 AI 了嗎？在什麼條件下？會不會被拿去訓練？依目前的程式，答案是：

- **只有使用者同意後才送**：唯一的關卡在 `GeminiClient.generate`，`AIConsentStore.current.isGranted` 為 false 時連 request 都不組。聊天、快速輸入、Siri、通知回覆、通知擴充、「AI suggestions」全部經過這裡。示範模式不使用 Google 帳號；同意後送出的是使用者輸入的內容和虛構的範例行程，不含任何 Google 使用者資料。
- **同意畫面逐項列出送出的內容**（`AIConsentDisclosure`，[`Shared/Storage/AIConsentStore.swift`](../Shared/Storage/AIConsentStore.swift)，1.0 是第 7 版：第 6 版曾加入「A photo or PDF you attach (only when you attach one and send)」那一項，只出現在 TestFlight；附件延到 1.1，第 7 版拿掉它，又是五項；改了說明就把 `AIConsent.disclosureVersion` 加 1，所有人重新同意）：
  1. 使用者輸入或說出的內容（語音先轉成文字），包括其中提到的姓名或 email；
  2. 從今天起 14 天內最多 40 個行程的標題、時間、備註（最多 300 字）和 Google 行程 ID，以及回覆提醒的那個行程；
  3. 「AI suggestions」只送那一個行程，包括地點；
  4. 行事曆名稱和助理設定，但**不包括 Google 帳號的 email**；
  5. 時區和語言。
- **語音輸入只在 iPhone 上辨識**（已在程式裡）：聊天和快速輸入的麥克風按鈕用 iPhone 上的 Apple 語音辨識（`SFSpeechAudioBufferRecognitionRequest.requiresOnDeviceRecognition = true`；不支援裝置端辨識的語言不顯示按鈕）。聲音不錄、不存、不送出；轉好的文字出現在輸入框，使用者按送出才傳，和打字完全一樣（第 1 項）。
- **1.0 沒有照片或 PDF 附件，也不賣訂閱**（2026-10-18 決定，兩者都延到 1.1）：送審內容和影片都不提。1.1 加入附件時，附件會跟著那一次請求送到 Gemini（同意說明第 8 版加回附件那一項），送出的資料就變了：照第 9 節先更新政策和同意說明，必要時先寫信告訴審查團隊。原本為 1.0 寫的附件和訂閱說明（附件以 `inlineData` 放在同一個請求裡、不用 Files API；購買紀錄不放進轉給 Gemini 的 body）在 commit `6ce6551` 的這份文件和 [`docs/SETTINGS.md`](SETTINGS.md) §16。
- **出發提醒「該出發了」**（2026-10-18 決定，1.0，審查期間建置）：使用者告訴助理要在什麼時間到哪裡（「今天 5 點要到台北 101 開會，想提早 30 分鐘到」），或問某個行程什麼時候該出發時（只是加入有地點和時間的行程不會），App 才在 iPhone 上、只在 App 裡、只有「使用 App 期間」的位置權限時取得目前位置，連同目的地和需要到達的時間送到 **Apple 的地圖服務**（MapKit：地點搜尋，加上考慮預估路況的「在某時間前到達」交通時間估算）；回覆裡小張 Apple 地圖的範圍也會送到 Apple。App 扣 10 分鐘緩衝、自己寫回覆，排兩則本機通知（「準備出門」、「該出發了」）。既有行程時，目的地是行程的地點、到達時間依它的開始時間計算，所以這是**新的 Google 使用者資料傳輸**：行程的地點和開始時間送到 Apple，只在使用者要求時、為了這個使用者看得到的功能（Limited Use 允許為使用者看得到的功能傳輸）。點通知的「出發」時，App 用行程地點欄位（或使用者打的字）的**文字**打開 Google 地圖（App 或網站），不帶座標、Apple 找到的地點或出發地點；這也是一個傳輸，政策第 11 節一併列出。政策的重點摘要和第 2、3、4、8、11、12、13、15 節都已寫好（2026-10-18）。**2026-10-19：網站上的政策和條款現在把出發提醒標成「即將推出」**，因為目前送審的 build 還沒有這個功能（也不取得位置），審查員會拿政策對照 App：政策的本版更新、重點摘要、第 8 節的標題和第一句，以及第 2、3、4、11、12、13、15 節都加了「即將推出」，生效日期改成 2026 年 10 月 19 日；條款第 9 節加了第一項，最後更新日期也改了。這不用新的 scope。功能上線時，拿掉政策和條款裡所有「即將推出」的標示，並更新政策的生效日期和條款的最後更新日期。**不用新的 scope**：行程上只用 `calendar.events`（`events.patch`）在私人 extended properties 寫入提早幾分鐘到、交通方式和開始前幾分鐘出發；不存目前位置、出發地點或路線，也不另外存交通時間（助理建立的行程，說明欄本來就照政策第 3 節保留使用者的原話，其中可能有使用者打的出發地點）。**AI 同意說明不變（第 7 版），政策第 4 節的引用一字不改**：Gemini 收不到位置、交通時間、出發時間或算不出的原因（回覆由 App 自己寫）；它收到的和任何請求一樣：使用者打的字由同意說明第 1 項「What you type or say to the assistant」涵蓋（其中可能有目的地或出發地點），行程資訊照同意說明列出的項目（聊天請求的行程不含地點）；關於出發，它只知道有沒有排好出發提醒或需要問出發地點。出發提醒不會把位置、行程地點、交通時間或出發時間送到 Smart Schedules 的伺服器（Cloudflare Worker）；使用者打的字（可能包括目的地或出發地點）和任何請求一樣經伺服器轉給 Gemini、不保存。**建置時要守住**（這段和 5.2 的說法靠它成立）：App 放進請求的函式結果和錯誤訊息都不帶位置、Apple 找到的地點、交通時間、出發時間或算不出的原因（例如太遠或找不到路線），系統提示的行程資料也不帶出發的私人屬性（下一則訊息會把函式結果帶回 Gemini，Google 最多保存 55 天）；Google 地圖的網址只帶目的地的文字。
- **Google 帳號 email 不會送到 Gemini**：行事曆以 `CalendarAliases` 命名（多帳號時是「Account 1」「Account 2」，名稱是 email 的共用行事曆叫「Shared calendar」），行程文字和錯誤訊息裡的帳號 email 換成 `[account email]` 之類的佔位字（[`docs/GEMINI_FUNCTION_CALLING.md`](GEMINI_FUNCTION_CALLING.md) 10.6 節）。使用者打出或說出已連接帳號的 email 時也換成佔位字；別人的 email 照原樣送出（第 1 項寫明）。
- **經過我們的伺服器**：App 沒有 API key，不直接連 Gemini。Cloudflare Worker 驗證 App Attest，移除 IP、裝置和語言標頭，把 body 原封不動轉給 Gemini API，不保存也不記錄內容。
- **付費層級，不用於訓練**：Gemini API 專案有 Cloud Billing（Paid Services），依條款 Google 不用 prompt 和回覆改善產品，只為偵測濫用和法律要求保留最多 55 天。我們自己也不用 Google 使用者資料或其衍生資料訓練任何模型（隱私權政策第 11 節）。這兩點對 Limited Use 很重要：Google 的常見問題寫 Google 使用者資料只能用在執行使用者看得到的功能的個人化用途，不能用來訓練或改善基礎模型；有人在 2026 年被拒，原因是把 Workspace 資料送給條款保留訓練權利的 AI 供應商（只是個案報告）。
- **動態島和即時動態**：只在 iPhone 上產生，不上傳任何行程，也不需要 AI 同意。1.0 不用 iOS 18 的 push-to-start（`AppConstants.pushToStartEnabled = false`）：不要求 push token、不呼叫 `POST /devices/push-to-start`，伺服器不存任何行程（同意說明第 5 版因此拿掉 iOS 18 的伺服器說明）。iOS 26 在 iPhone 上排程；iOS 18 只有在提前時間內打開 App 才出現。
- **目前版本只有 Gemini**（2026-10-18）：隱私權政策第 4、11 節寫「在目前版本中」（第 4 節現在寫「唯一會把行事曆資料送到 AI 服務的功能」，另外指出出發提醒是唯一另一個把行事曆資料送到 Google 日曆以外的功能；第 11 節的傳輸清單加上了出發提醒用的 Apple 地圖服務和 Google 地圖），第 18 節說之後如果有其他 AI 選項（例如 Apple 的裝置端模型或使用者自己連結的 AI 帳號），會先更新政策、寫明收件者並在 App 裡再次徵求同意，而且只用條款寫明不拿資料訓練模型的服務。送審內容和影片只示範 Gemini，不提還沒做的其他 AI 選項；出發提醒還在建置，只在 5.1、5.2 說明資料怎麼處理，影片不示範（審查員要求時照第 8.5 節最後的方式補件）；照片和 PDF 附件、AI 訂閱不在 1.0（延到 1.1），送審內容完全不提；之後真的加入其他 AI 時，先寫信告訴審查團隊。
- **使用者可以隨時停止**：設定 › AI & privacy › Stop sharing；Remove account 撤銷 Google 授權。

### 5.2 英文（貼進 Additional information，或回覆 AI 相關的提問）

```text
How the Smart Schedules AI assistant uses Google user data

The AI assistant is a user-facing feature: the user types or says a request such as "lunch with Joe tomorrow at 12:30", and the assistant creates or changes the event in the user's Google Calendar.

Consent: nothing is sent until the user taps Allow in an in-app dialog ("Use the AI assistant?") that lists exactly what is sent. The same text is in our privacy policy, section 4 (https://www.smart-schedules.com/privacy#en-ai). Users can stop sharing at any time in Settings > AI & privacy. Demo mode (no Google sign-in) uses fictional sample calendars; after the same consent, its requests contain what the user types and those sample events, never Google user data.

What is sent: the user's request as text (speech from the app's microphone button is turned into text on the iPhone by Apple's on-device speech recognition, and no audio is recorded or sent; requests spoken to Siri or with the keyboard's dictation reach the app as text from Apple); the titles, times, notes (up to 300 characters) and Google event IDs of up to 40 events in the 14 days from today, and of the event whose reminder the user replies to; for "AI suggestions" on one event, that event including its location; the user's calendar names and assistant settings; time zone and language. Google account email addresses are never sent: the assistant sees calendars as "Account 1", "Account 2", and the app replaces the connected accounts' addresses in the user's request, event text and error messages with placeholders before sending (and puts them back on the iPhone in what it writes to Google Calendar). Attendees, organizer and video-call links are not sent.

Path and recipient: the request goes from the app to our server (a Cloudflare Worker), which verifies with Apple App Attest that it comes from our app, removes the user's IP address and device headers, and forwards the body unchanged to Google's Gemini API with our API key. The server does not store or log the content. The app contains no API key. In this version the only AI provider is Google's Gemini API (paid tier).

Training and retention: our Gemini API project has Cloud Billing enabled, so it is a Paid Service under the Gemini API terms: Google does not use the prompts or responses to improve its products, and keeps them for up to 55 days only to detect abuse and for legally required disclosures. We do not use Google user data, or data derived from it, to develop, improve or train any AI or machine-learning model, generalized or personalized, and we do not allow anyone else to do so (privacy policy, section 11: https://www.smart-schedules.com/privacy#en-limited-use).

Departure reminders (being built for this version): when the user tells the assistant where they need to be and when, or asks how long a trip takes or when to leave for an event (just adding an event with a place and a time does not count), the app on the iPhone gets the current location (only in the app, with the iOS When In Use permission) and sends it, with the destination and the time the user needs to arrive, to Apple's map service (MapKit) for a place search and a travel-time estimate. For an existing event, the destination is the event's location and the arrival time comes from its start time: these Google user data go to Apple only at the user's request, for this user-facing feature. This feature adds none of the following to any request to our server or to Gemini: the iPhone's location, the event's location field, the travel time and the departure time. The app works out the time and writes the reply itself; of the departure details, Gemini sees only what the user typed (which may name the destination or a starting point), as with any request, and learns only whether departure reminders were set or a starting point is needed. The location is not stored. On the event, the app saves only, in its private extended properties (calendar.events, events.patch), how many minutes early the user wants to arrive, the travel mode and how many minutes before the start to leave; it adds no current location, starting point or route. Two local notifications remind the user; their leave button opens Google Maps with the destination text only (the event's location field as written, or what the user typed), never coordinates and no starting point. No new scope is needed, and the AI consent text is unchanged.

Other features: reminders and Live Activities are created on the iPhone from the events already there. No calendar data is uploaded or stored on our server for them, and they need no AI consent.
```

## 6. 示範影片

### 6.1 Google 的要求（摘要）

- 拍出**完整的 OAuth 授權流程**和**完整的同意畫面**，同意畫面上的 scope 要和送審的**完全一樣**。
- 同意畫面要顯示正確的 **App 名稱**；同意畫面左下角的語言選單要切到 **English**，授權流程整段是英文。
- 拍出 **OAuth client ID**。網頁 App 的要求是網址列看得到 `client_id`；第三方整理和一封被引用的 Google 回信寫這一項**不適用原生 Android／iOS App**，但官方原文沒查到這句，所以照 6.3 的鏡頭 2 和 5b 另外拍出來。
- 示範**每個敏感 scope 在 App 裡怎麼使用**，並說明 App 的整體用途。
- 涵蓋專案裡**所有 OAuth client**（所以只留一個 iOS client）。
- 如果把資料用於訓練 AI 模型，要拍到使用者明確同意（我們不訓練，但同意畫面照樣拍）。
- 上傳 YouTube，可見度 **Unlisted**，連結貼在 Data access 或 Verification Center 的影片欄位。

### 6.2 錄影前準備

1. 品牌已發佈（3.2），iPhone 裝的是 TestFlight 上含同意說明第 7 版的版本：同意畫面有**五項**，沒有附件那一項，和政策第 4 節的引用逐字相同（有六項、含「A photo or PDF you attach …」的第 6 版不要拿來錄）；而且同意畫面的註腳已經是「… Demo mode sends the sample calendars and events instead of your Google Calendar.」（示範模式改用 AI 之後的註腳；舊註腳「Demo mode never contacts the AI.」的版本不要拿來錄）。
2. 到 https://myaccount.google.com/connections 把測試帳號對 Smart Schedules 的授權移除。App 帶 `include_granted_scopes=true`，帳號已授權過時 Google 可能只列出新增的 scope，同意畫面就不完整。
3. 刪除再重新安裝 App（或 設定 › Data › Erase all data on this device），讓「Connect Google Calendar」和 AI 同意畫面重新出現。
4. 語言全部用英文：iPhone 設定 › 一般 › 語言與地區 › iPhone 語言 = English，或只把 設定 › App › Smart Schedules › 語言 設成 English（App 的設定 › Language 會打開這一頁）。App 開 Google 頁面時帶 `hl`（跟著 App 的語言：英文 App 是 `hl=en`，繁中是 `hl=zh-TW`；`GoogleAuthorization.googleLanguage(forLocalization:)`），所以登入頁、未驗證警告和同意畫面都跟著 App 的語言，不受測試帳號或 Safari 記住的語言影響；底部的語言選單要顯示 English (United States)。Mac 上的 Google Calendar 網頁也用英文。
5. iOS 18 或 iOS 26 的 iPhone 都可以錄：1.0 的同意畫面在兩種系統上相同（沒有伺服器那一段）。
6. 打開勿擾模式，關掉通知預覽。
7. 主畫面的對話輸入列沒有迴紋針：1.0 把它藏起來（`App/Views/ChatPanel.swift` 的 `showsAttachment: false`）。還看得到迴紋針的舊建置不要拿來錄。
8. **出發提醒不用新的鏡頭**：沒有新的 scope（寫入行程私人屬性用的是 `calendar.events`，它的寫入已在鏡頭 11、12 拍到），AI 同意說明也不變（第 7 版，鏡頭 10）。鏡頭 3 會拍到隱私權政策，所以要在加了出發提醒（第 8 節）的政策上線之後才錄。錄影用的請求（「Lunch with Joe tomorrow at 12:30」）沒有地點、也不問出發時間；不要用會觸發出發提醒的句子（「… when should I leave?」或有地點和到達時間的請求），否則會跳出位置權限，影片沒有說明它。

### 6.3 分鏡腳本（約 5 分鐘）

`<PROJECT_ID>`、`<CLIENT_ID>` 換成實際值。旁白可以錄音，也可以做成英文字幕；兩者都有最好。

**鏡頭 1｜片頭（0:00–0:10）**
- 畫面：黑底字卡：`Smart Schedules – Google OAuth verification demo` / `Google Cloud project: <PROJECT_ID>` / `OAuth client: iOS, bundle ID com.smartschedules.app` / `Scopes: openid, email, calendar.events, calendar.calendarlist.readonly`。
- 旁白：
  ```text
  This is Smart Schedules, an iPhone calendar app and AI scheduling assistant for Google Calendar. This video shows the Google sign-in and consent flow, and how the app uses each scope it requests: openid, email, calendar.events and calendar.calendarlist.readonly.
  ```

**鏡頭 2｜OAuth client 和 Branding（0:10–0:35）**
- 畫面：Mac 瀏覽器，Google Auth Platform › Clients：只有一個 client；點開，放大 Client ID 全文、類型 iOS、Bundle ID。接著 Branding 頁：App name、logo、home page、privacy policy、authorized domain。
- 旁白：
  ```text
  The project has a single OAuth client: an iOS client for the bundle ID com.smartschedules.app. This is its client ID, the one the Smart Schedules app on the iPhone uses. The consent screen is branded Smart Schedules, with our home page and privacy policy on our verified domain, smart-schedules.com.
  ```

**鏡頭 3｜首頁和隱私權政策（0:35–1:00）**
- 畫面：打開 https://www.smart-schedules.com ，點「English」；捲到「Why Smart Schedules uses your Google Calendar」和「AI and privacy」，停在 Limited Use 那一句。點 Privacy Policy › English，捲到第 3 節（四個 scope），再到第 11 節。
- 旁白：
  ```text
  Our home page explains what the app does and why it needs Google Calendar, and states that our use of information received from Google APIs adheres to the Google API Services User Data Policy, including the Limited Use requirements. The privacy policy lists each permission and how it is used, explains the optional AI assistant, and repeats the Limited Use commitment in section 11.
  ```

**鏡頭 4｜語言（1:00–1:10）**
- 畫面：iPhone 設定 › App › Smart Schedules › 語言：English（或 iPhone 語言是 English）。
- 旁白：
  ```text
  The iPhone and the app are set to English.
  ```

**鏡頭 5｜開始登入（1:10–1:30）**
- 畫面：打開 Smart Schedules → 點「Connect Google Calendar」→「Add Google account」頁，在「Google account email」輸入測試帳號 → 點「Continue with Google」→ iOS 提示「"Smart Schedules" Wants to Use "google.com" to Sign In」→ Continue。
- 旁白：
  ```text
  On first launch I tap Connect Google Calendar and enter the Google account I want to connect. The app opens Google's own sign-in page in Apple's secure sign-in sheet. Smart Schedules never sees the password.
  ```

**鏡頭 5b｜授權網址裡的 client ID（選擇性，建議拍）**
- 為什麼：iOS 的 `ASWebAuthenticationSession` 只顯示網域（accounts.google.com），看不到網址裡的 `client_id`。
- 怎麼拍（不改程式）：iPhone 接 Mac，用 Xcode 跑 Debug 版（`Config/Secrets.xcconfig` 有 `GEMINI_BASE_URL[config=Debug]` 時它連開發用的 Worker，沒有時連正式版；AI 那段仍用 TestFlight 版錄，影片裡就是送審的 build；OAuth client 兩者相同）。在 `App/Auth/GoogleSignInCoordinator.swift` 的 `let authURL = GoogleAuthorization.url(…)` 下一行設中斷點 › Edit Breakpoint › Action「Debugger Command」`po authURL.absoluteString`，勾「Automatically continue after evaluating actions」。按「Continue with Google」時 Xcode 主控台印出完整網址；放大 `client_id=` 和 `scope=` 那一段，然後關掉 Google 的頁面。這段在主流程之前單獨錄：Debug 版和 TestFlight 版的 bundle ID 相同，錄完再從 TestFlight 裝回正式版錄鏡頭 5 以後。**不要**在鏡頭裡打開 `Config/Secrets.xcconfig`（裡面有開發用的 token 和伺服器網址）。
- 旁白：
  ```text
  Apple's sign-in sheet shows only the host name, so here is the full authorization URL the app opens, logged in Xcode. It carries our client ID and the four scopes: openid, email, calendar.events and calendar.calendarlist.readonly.
  ```

**鏡頭 6｜Google 登入頁（1:30–1:50）**
- 畫面：Google 登入頁（email 已填好）；捲到底，讓左下角語言選單「English (United States)」入鏡（不是就切過去）；輸入密碼（擋住或在鏡頭外輸入）。出現「Google hasn't verified this app」時：點 Advanced → Go to Smart Schedules (unsafe)。
- 旁白：
  ```text
  Google's sign-in page is in English; the language menu at the bottom shows English (United States). Because verification is still pending, Google shows its unverified-app notice, and I continue through Advanced.
  ```

**鏡頭 7｜同意畫面（1:50–2:20）**
- 畫面：「Smart Schedules wants access to your Google Account」，App 名稱、logo 和帳號都入鏡。每一行權限停 3 秒：「See the list of Google calendars you're subscribed to」、「View and edit events on all your calendars」，以及登入共用的 email 那一行。可以點 App 名稱顯示開發者資訊。勾選兩個行事曆權限（或 Select all）→ Continue。
- 旁白：
  ```text
  The consent screen names Smart Schedules and asks for two Google Calendar permissions: to see the list of calendars the user is subscribed to, and to view and edit events on all their calendars. Signing in also shares the account's email address. I select both calendar permissions and continue.
  ```

**鏡頭 8｜讀取行程：`calendar.events`（2:20–2:40）**
- 畫面：（刪除重裝後第一次連線才會出現；用 Erase all data 重來時 iOS 記得之前的答案，不會再問）回到 App 時 iOS 先問「"Smart Schedules" Would Like to Send You Notifications」→ 點 Allow（App 的通知權限，與 Google 無關）。回到 App，月曆出現測試帳號的行程；切到週、日檢視。旁邊（或接著）是 Mac 上的 Google Calendar 網頁，同樣的行程。
- 旁白：
  ```text
  Back in the app, Smart Schedules reads the events with the calendar.events scope and shows them in month, week and day views. They are the same events as in Google Calendar on the web.
  ```

**鏡頭 9｜行事曆清單：`calendar.calendarlist.readonly` 和 `email`（2:40–3:10）**
- 畫面：點左上角 ☰ 打開抽屜：帳號那一區的標題是帳號 email，下面是 My calendar、Gym、Test（另一個帳號分享的，唯讀；或 Holidays in United Kingdom 這類國定假日行事曆）和各自的顏色。點 Gym 的色塊隱藏它，行程消失，再點一次恢復。點 My calendar 那一列，打開詳細頁，指出「Show in Smart Schedules」和「Use for new events」。Mac 上 Google Calendar 左側的「My calendars」「Other calendars」做對照。
- 旁白：
  ```text
  The calendar.calendarlist.readonly scope lets the app list the user's calendars. The sidebar shows them under the account, which is identified by its email address from the email scope, with each calendar's name and colour as in Google Calendar. The user can hide or show each calendar and choose which calendar new events go to. The app only reads this list; it never changes the user's calendars.
  ```

**鏡頭 10｜AI 同意畫面（3:10–3:50）**
- 畫面：關掉抽屜，在輸入框打「Lunch with Joe tomorrow at 12:30」送出 →「Use the AI assistant?」出現 → 慢慢捲過 5 項說明、收件者那一行、語音那一行（Siri 和鍵盤聽寫由 Apple 轉成文字，麥克風按鈕在 iPhone 上轉，只送文字）→ 點 Allow。
- 旁白：
  ```text
  The AI assistant is optional. Before anything is sent, the app shows this consent dialog. It lists exactly what goes to Google's Gemini API: the request; the titles, times, notes and event IDs of up to forty events in the next fourteen days and of the event whose reminder is answered; for AI suggestions on one event, only that event, including its location; calendar names and assistant settings; and time zone and language. Google account email addresses are never sent. Requests pass through our server, which doesn't keep them. Nothing is sent until the user taps Allow.
  ```

**鏡頭 11｜新增行程：`calendar.events` 寫入（3:50–4:15）**
- 畫面：助理回覆和行程卡片；月曆明天出現「Lunch with Joe」。Mac 上重新整理 Google Calendar，打開這個行程：說明欄第一行是「由 Smart Schedules 智慧助理自動排程：」加上剛才的請求。
- 旁白：
  ```text
  The assistant understood the request, and the app created the event with the calendar.events scope. Here it is in Google Calendar. The first line of the description, in Chinese, says that the Smart Schedules assistant scheduled it, followed by the user's request.
  ```

**鏡頭 12｜修改和刪除：`calendar.events`（4:15–4:45）**
- 畫面：點這個行程 → Event 頁：在 Notes 加「Bring the contract」→ Save → Google Calendar 網頁重新整理看到備註。回到 Event 頁 → Delete event → 確認 → 網頁重新整理，行程不見了。
- 旁白：
  ```text
  Users can also edit events directly. I add a note and save, and the change appears in Google Calendar. Deleting the event removes it from Google Calendar as well.
  ```

**鏡頭 13｜使用者的控制權（4:45–5:10）**
- 畫面：☰ → General（設定）→ AI & privacy：狀態 Allowed、「What is sent」（和同意畫面同樣的文字）、Stop sharing（點開確認框再取消）。再回 ☰ → 帳號標題旁的「…」→ Remove account（顯示確認框；要的話確認，再到 myaccount.google.com/connections 顯示授權已移除）。
- 旁白：
  ```text
  In Settings, under AI and privacy, users can review what is sent and stop sharing at any time. Remove account revokes the app's access at Google and deletes the account's token and cached events from the iPhone. Google Calendar itself is not changed.
  ```

**片尾（5:10–5:15）**：`www.smart-schedules.com · support@smart-schedules.com`。

### 6.4 錄影技巧

- **畫面來源**：iPhone 用線接 Mac，QuickTime Player › 新增影片錄製 › 攝影機選 iPhone，就能把 iPhone 畫面和 Mac 上的 Cloud 控制台、Google Calendar 網頁錄在同一段。也可以分開錄（iPhone 的螢幕錄製、Mac 的 Shift-Command-5），再用 iMovie 剪在一起。
- **OAuth 那一段（鏡頭 5 到 8）一鏡到底**，不要剪接；同意畫面每一行停 3 秒以上，必要時放大。
- **Client ID 不要打馬賽克**（它不是秘密）；要遮的是密碼、存取權杖、`Config/Secrets.xcconfig`、Worker 的網址和任何真實的個人資料。
- 1080p 以上；全部英文（App、Google 頁面、Google Calendar 網頁、字幕）；不需要配樂。
- YouTube 說明欄寫章節時間（例如 `0:10 OAuth client ID`、`1:50 Consent screen`、`2:40 calendar.calendarlist.readonly`、`3:10 AI consent`），回審查信時可以直接引用時間點。
- 上傳後用無痕視窗打開連結確認看得到（Unlisted 可以，Private 審查員看不到）。審查期間不要刪除或換掉影片；要換就上傳新影片，在信裡給新連結。
- 同意說明、scope 或 App 名稱改了，就重錄。

## 7. 常見退件原因與對策

| 原因 | 對策 |
|---|---|
| 網域沒驗證、首頁「not registered」 | 3.1：Search Console 的**網域**資源 `smart-schedules.com`（涵蓋 www），由專案 Owner／Editor 驗證，Squarespace DNS 裡 Workspace 和 Search Console 的 `google-site-verification` TXT 都保留 |
| 審核員或使用者登入時被擋，只有 `@smart-schedules.com` 的帳號能登入 | Audience › User type 是 Internal：改成 External（3.5），發佈到 In production |
| 首頁沒說明 App 用途、是登入頁、或 App 名稱和同意畫面不同 | 首頁開頭就是「Smart Schedules」和用途說明；Branding 的 App name 一字不差 |
| 首頁「unresponsive」 | 填 `https://www.smart-schedules.com`（不要 http、沒有 www 的根網域或會轉址的網址）；網站不要對機器人出驗證頁。論壇上也有網站正常仍被標記的案例，這時在 View issues 申請人工複查 |
| 隱私權政策不在同一網域、沒從首頁連過去、沒說明怎麼存取／使用／保存／分享 Google 使用者資料 | `https://www.smart-schedules.com/privacy`，首頁有連結；第 3、4、5、8、11、13 節分別說明 |
| 缺 Limited Use 聲明 | 首頁和政策第 11 節都有 Google 範本的那一句 |
| App 要求的 scope 和 Data access 不一致 | 只有第 1 節的四個；程式改 scope 就要重新送審 |
| 要求的 scope 比需要的大 | 第 4.2、4.3 節的「Why a narrower scope is not enough」；回信範本 8.2 |
| 影片沒拍到英文同意畫面、App 名稱、client ID、每個 scope 的使用、或所有 OAuth client | 照 6.3 拍；專案只留一個 iOS client |
| App 名稱或 logo 用了 Google 的商標 | 名稱不要寫成「… for Google Calendar」；logo 是 App 自己的圖示 |
| 品牌驗證通過後 7 天內沒發佈 | 通過就按 Publish branding；過期了重跑 Verify branding |
| 審查信沒回、或寄到沒人看的信箱 | 第 2 節的信箱檢查；Google 只用 email 聯絡 |
| 資料送到可能拿來訓練的 AI | Gemini 付費層級、AI Studio 記錄關閉；政策和第 5.2 節寫明不訓練 |

## 8. 回覆審查信

### 8.1 原則

- **直接回覆審查團隊寄來的那封信**（同一個討論串、保留主旨），不要另外重新送審；Google 的說明也是請你直接回最後一封信。
- 一個問題一段，照對方的編號回答，引用對方的句子，附上網址和影片時間點。改了什麼就寫改了什麼、在哪裡。
- 只寫事實，不承諾程式做不到的事。答案要和隱私權政策、App 的同意說明一致。
- Google 建議縮小 scope 時，「Requesting Minimum Scopes」說明頁給兩種回覆：**Confirm Downscoping**（同意改用建議的 scope，改程式後再回信）或 **Unable to use narrower scopes**（說明為什麼不行）。我們的情況是後者（8.2）。
- 要補影片或改網站時，先改好再回信，並給新連結。

### 8.2 範本：建議改用較小的 scope

```text
Hello,

Thank you for the review. Our resolution for project <PROJECT_ID>: Unable to use narrower scopes.

calendar.events: Smart Schedules is a Google Calendar client. Users view events in all their calendars, including calendars other people share with them, and create, edit and delete events in the calendars they own or have "Make changes to events" access to. calendar.events.readonly and calendar.events.owned.readonly cannot write; calendar.events.owned does not cover calendars shared with the user; calendar.app.created covers only calendars the app creates; calendar.events.freebusy has no event details. We do not request the full calendar scope. The video shows reading (<mm:ss>), creating (<mm:ss>), editing and deleting (<mm:ss>) events.

calendar.calendarlist.readonly: used only for calendarList.list, to show the user's calendars with their names, colours and access roles so the user can choose which to show and where new events go (<mm:ss>). calendar.calendars.readonly cannot list calendars; it only reads a calendar whose ID is already known.

Please let us know if you need more information.

Best regards,
Smart Schedules
support@smart-schedules.com
```

### 8.3 範本：影片的 client ID、語言或 scope 示範

```text
Hello,

Thank you. We have uploaded an updated demo video: <YouTube link> (unlisted).

- OAuth client ID: Smart Schedules is a native iOS app (OAuth client type iOS, bundle ID com.smartschedules.app). On iOS the sign-in page opens in ASWebAuthenticationSession, Apple's system sign-in sheet, which shows only the host name, not the full URL. The video shows the project's only OAuth client and its client ID in Google Auth Platform > Clients (<mm:ss>), and the full authorization URL the app opens, with client_id=<CLIENT_ID> and all four scopes, logged in Xcode (<mm:ss>).
- Language: the consent flow is in English; the language menu at the bottom of Google's page shows English (United States) (<mm:ss>).
- Consent screen: shows the app name Smart Schedules and exactly the scopes in our request (<mm:ss>).
- Scope use: calendar.events (<mm:ss> read, <mm:ss> create, <mm:ss> edit and delete); calendar.calendarlist.readonly (<mm:ss>).

Best regards,
Smart Schedules
support@smart-schedules.com
```

### 8.4 範本：首頁、隱私權政策、Limited Use、網域

2026-10-19：政策第 8 節現在把出發提醒標成「即將推出」（目前的 build 還沒有，不用新的 scope）。下面的英文照樣可用；要更精確時，在「section 8 how departure reminders」的 reminders 後面加「 (coming soon; not in the current build)」。審查員追問時照第 8.5 節回答。

```text
Hello,

Thank you. Here is where each requirement is met:

- Home page: https://www.smart-schedules.com (no sign-in required). It names the app, describes what it does and why it needs Google Calendar, links to the privacy policy, and includes the Limited Use statement under "AI and privacy".
- Privacy policy: https://www.smart-schedules.com/privacy, on the same domain and linked from the home page and the consent screen. Section 3 lists each Google permission and how it is used; section 4 explains what the optional AI assistant sends and when; section 5 that Live Activities are created on the iPhone; section 8 how departure reminders use the location and send an event's place and start time to Apple's map service; section 11 Google user data and Limited Use; section 13 retention; section 15 how users revoke access and delete data.
- Limited Use statement: "Smart Schedules' use and transfer to any other app of information received from Google APIs will adhere to Google API Services User Data Policy, including the Limited Use requirements." (https://www.smart-schedules.com/privacy#en-limited-use)
- Domain: smart-schedules.com is verified in Google Search Console as a Domain property by an Owner of this project; it is our authorized domain, and the website is served on its www subdomain.

<If we changed anything, describe it here.>

Best regards,
Smart Schedules
support@smart-schedules.com
```

### 8.5 範本：AI／資料傳輸的提問

回信開頭寫「Thank you. Here is how the Smart Schedules AI assistant uses Google user data:」，接著貼第 5.2 節全文，最後補上影片裡同意畫面的時間點（鏡頭 10），以及「The Gemini API project is <GEMINI_PROJECT_ID>, with Cloud Billing enabled.」。

審查員問出發提醒或位置時：回信貼第 5.2 節的「Departure reminders」段落。它不用新的 scope，寫入行程用的是影片已經拍到的 `calendar.events`，AI 同意說明也沒變，所以第一支影片不用重錄。審查員要求示範時，功能做好、裝到 TestFlight 後錄一段短片補件（說「Meeting at <地點> at 5 pm, I want to be there 30 minutes early」→ iOS 的位置權限（使用 App 期間）→ 回覆裡的建議出發時間和小張 Apple 地圖 → 鎖定畫面上的通知 → 點出發打開 Google 地圖），回信寫「Departure reminders were built after our first video; this clip shows them: <YouTube link> (unlisted).」。

2026-10-19：網站上的政策和條款現在把出發提醒標成「即將推出」，目前送審的 build 沒有這個功能、也不取得位置；它不用新的 scope。審查員問 App 裡為什麼找不到時，回信可以寫「Departure reminders are not in the current build yet; the privacy policy (section 8) and the terms (section 9) mark them as coming soon. They need no new scope.」。功能上線時，拿掉政策和條款裡的「即將推出」標示、更新政策的生效日期和條款的最後更新日期，再照上面的方式補短片。

### 8.6 範本：補件後追蹤

```text
Hello,

Following up on our reply of <date> for project <PROJECT_ID>. We have addressed the points in your last email (<one-line summary>). Please let us know if anything else is needed for the verification of calendar.events and calendar.calendarlist.readonly.

Best regards,
Smart Schedules
support@smart-schedules.com
```

## 9. 核准之後

- 新增 scope、改 App 名稱、logo、首頁或隱私權政策網址、新增 OAuth client，都會再審（Google「Changes to approved app」）。程式裡改 `GoogleTokenProvider.scopes` 之前先看這份文件。
- 網站要一直在線上，Search Console 的 TXT 記錄、隱私權政策第 3、4、8、11 節要和 App 一致；同意說明改版時（`AIConsent.disclosureVersion` 加 1）同時改網站，必要時主動通知審查團隊。
- Gemini 專案一直保持付費層級。改用其他 AI 供應商，或改變送出的資料，都要先確認符合 Limited Use，並更新政策和同意說明。
- 專案的擁有者、聯絡信箱有變動時立刻更新；Google 寄到專案聯絡人的通知沒處理，可能失去 API 存取權。

## 10. 參考資料

Google 官方（撰寫環境打不開，以搜尋摘要為準，送審前請再讀原文）：

- Sensitive scope verification：https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification
- Submit for brand verification：https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification
- Comply with OAuth 2.0 policies（網域驗證涵蓋首頁、政策等所有網域）：https://developers.google.com/identity/verification/authentication-policy-compliance
- OAuth 2.0 Policies：https://developers.google.com/identity/protocols/oauth2/policies
- Verification requirements（首頁、隱私權政策、scope 說明）：https://support.google.com/cloud/answer/13464321
- Submitting your app for verification：https://support.google.com/cloud/answer/13461325
- Manage OAuth App Branding（logo 規格、Verify／Publish branding、7 天有效、2–3 個工作天）：https://support.google.com/cloud/answer/15549049
- Manage App Data Access（scope 分類、用途說明、影片要涵蓋所有 client、左下角語言切到 English）：https://support.google.com/cloud/answer/15549135
- Demo Video：https://support.google.com/cloud/answer/13804565
- Requesting Minimum Scopes（Confirm Downscoping／Unable to use narrower scopes）：https://support.google.com/cloud/answer/13807380
- Frequently Asked Questions（AI／ML 與 Google 使用者資料）：https://support.google.com/cloud/answer/13463817
- Unverified apps（100 位新使用者上限、scope 不一致時的未驗證畫面）：https://support.google.com/cloud/answer/7454865
- Manage App Audience（User type：Internal 需要 Google Cloud 組織、只限組織成員；External 給任何 Google 帳號；Testing 最多 100 位測試使用者）：https://support.google.com/cloud/answer/15549945
- Changes to approved app：https://support.google.com/cloud/answer/13464018
- Choose Google Calendar API scopes：https://developers.google.com/workspace/calendar/api/auth
- OAuth 2.0 Scopes for Google APIs：https://developers.google.com/identity/protocols/oauth2/scopes
- How to handle granular permissions：https://developers.google.com/identity/protocols/oauth2/resources/granular-permissions
- Google API Services User Data Policy：https://developers.google.com/terms/api-services-user-data-policy
- Google Workspace user data and developer policy：https://developers.google.com/workspace/workspace-api-user-data-developer-policy
- Workspace API policy protections for generative AI：https://workspace.google.com/blog/ai-and-machine-learning/api-policy-protections
- Get smart about preparing your app for OAuth verification（影片要能看出 App 身分，包括 client ID）：https://developers.googleblog.com/get-smart-about-preparing-your-app-for-oauth-verification/
- Gemini API 條款（付費服務、18 歲、英國只能用付費服務）：https://ai.google.dev/gemini-api/terms ；使用政策（55 天）：https://ai.google.dev/gemini-api/docs/usage-policies ；記錄政策：https://ai.google.dev/gemini-api/docs/logs-policy
- Search Console：https://search.google.com/search-console ；帳號授權管理：https://myaccount.google.com/connections

第三方和論壇（只作參考）：

- 原生 iOS／Android 不需在網址列拍 client ID：https://www.cloudsponge.com/blog/google-oauth-verification-video/
- 影片 client ID 在轉址後看不到的討論（2026）：https://discuss.google.dev/t/oauth-verification-demo-video-client-id-visibility-after-googles-redirects/403727
- Verify／Publish branding 按鈕不出現、Prepare for verification 灰掉的案例：https://discuss.google.dev/t/verification-center-prepare-for-verification-permanently-disabled-branding-page-has-no-verify-branding-button/381088
- 首頁被標記 unresponsive 的案例：https://discuss.google.dev/t/oauth-verification-homepage-flagged-unresponsive-but-confirmed-reachable-via-multiple-independent-checks/385652
- `calendar.events` 送審 4 天核准的實例（2026-09）：https://github.com/yuval-yssak/gtd-app/issues/18
- 因 AI 供應商保留訓練權利被拒的個案：https://x.com/realBobbyHealy/status/2007404130499694909
- 驗證網域的帳號需是專案 Owner／Editor（Google 支援的回覆被引用於）：https://mongodb.com/community/forums/t/google-oauth-consent-screen-3rd-party-issues/246983
