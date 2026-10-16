# www.smart-schedules.com 網站

Smart Schedules 的靜態網站：首頁、隱私權政策和支援頁，網址是 **https://www.smart-schedules.com**。Google OAuth 驗證、App Store Connect 和 App 裡的連結都指向這裡。

部署方式（1.0）：**Cloudflare Pages 專案**（Direct Upload，只有靜態檔案，沒有 Functions），用 `server/worker` 已經裝好的 wrangler（4.146.0）從終端機上傳，和 `server/worker` 用同一個 Cloudflare 帳號。**DNS 留在 Squarespace，不搬到 Cloudflare**：nameserver 仍然是 `nsa1`～`nsa4.squarespacedns.com`，DNSSEC 照舊開著，Google Workspace 的郵件紀錄一筆都不動；唯一和網站有關的 DNS 變更是在 Squarespace 加**一筆 CNAME**（`www` → 專案的 `pages.dev` 主機名稱）。根網域 smart-schedules.com 不提供網站，可以選擇用 Squarespace 的網域轉址轉到 www（[§3.5](#35選做根網域-smart-schedulescom-轉到-www)）。步驟在 [§3](#3-網站上線wwwsmart-schedulescomcloudflare-pages--squarespace-一筆-cname不搬-dns)；之後如果要把 DNS 搬到 Cloudflare，見[附錄](#附錄之後若要把-dns-搬到-cloudflare10-不需要)（1.0 不需要）。

## 檔案

```
site/
  wrangler.toml        Pages 專案設定（專案名稱、上傳 ./public），不會上傳
  .gitignore           忽略 wrangler 在 site/ 產生的 .wrangler/
  README.md            本文件，不會上傳
  public/              唯一會上傳的資料夾
    index.html         https://www.smart-schedules.com/          首頁（Google OAuth 的 Home page）
    privacy.html       https://www.smart-schedules.com/privacy   隱私權政策（App Store Connect、Google OAuth、SSPrivacyURL）
    support.html       https://www.smart-schedules.com/support   支援頁（App Store Connect 的 Support URL）
    404.html           找不到頁面時回 404
    _headers           安全性標頭（不會被當成頁面提供）
    robots.txt
    logo.png           120×120，由 App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png 縮小；OAuth 同意畫面的 logo 用同一張
```

- 每一頁都是繁體中文在前、英文在後，頁首有語言切換（`#zh`、`#en`，純錨點，不用 JavaScript）。審核員可以直接點「English」。
- 沒有 JavaScript、外部字型、cookie 或追蹤。CSS 直接寫在每頁的 `<style>` 裡（四頁內容相同），依 `prefers-color-scheme` 切換淺色和深色。改樣式時四頁要一起改。
- 不需要 `_redirects`，網址規則是 Pages 的預設行為：`/privacy` 提供 `privacy.html`；`/privacy.html` 和 `/privacy/` 308 轉到 `/privacy`；`/index.html` 308 轉到 `/`；不存在的路徑回 `404.html`、狀態 404。**`public/404.html` 一定要保留**：沒有最上層的 `404.html` 時，Pages 會把網站當成單頁應用程式，所有不存在的路徑都回首頁（200）。
- 本機測試過（2026-10-15，wrangler 4.146.0 在 `site/` 執行 `wrangler pages dev`）：`/`、`/privacy`、`/support` 都是 200；`/privacy.html`、`/privacy/`、`/support.html` 是 308 → 去掉 `.html` 的網址，`/index.html` 是 308 → `/`；`/nope` 是 404（`404.html` 的內容）；`_headers` 的標頭（Content-Security-Policy、X-Frame-Options 等）有套用；`/README.md`、`/wrangler.toml` 是 404（沒有上傳）。之前也測過：手機寬度（375 px）沒有水平捲動，淺色和深色都正常，所有錨點都存在。

## 1. 發佈前要替換的佔位文字

所有佔位文字都包在 `<mark class="todo">…</mark>` 裡，頁面上會以黃色標示。替換時連 `<mark>` 標籤一起換掉。

| 佔位文字 | 在哪裡 | 填什麼 |
|---|---|---|
| `[開發者名稱 / Developer name]` | 三頁的頁尾；`privacy.html` 第 1 節和第 19 節（中英文各一次） | 資料控管者的法定名稱，和 Apple Developer 帳號、App Store 上的賣家名稱一致（個人就是你的法定姓名） |
| `[3]` | `support.html`「多久會回覆」（中英文各一次） | 你願意承諾的回覆工作天數 |

郵件服務已經決定是 Google Workspace（不是佔位文字）：support@smart-schedules.com 是 Workspace 的信箱，政策第 9、12、13、17 節（中英文）寫的是由 Google（Google Workspace）的 Gmail 收信、保存和回信，Google 依雲端資料處理附錄（Cloud Data Processing Addendum）作為處理者。發佈前要做的事在 [§2 第 5 項](#2-發佈前要確認的事政策內容依賴這些)。

最低年齡已經決定是 18（不是佔位文字）：政策第 16 節「最低年齡」、支援頁「AI 助理需要什麼才能運作？」和首頁都寫 18，App Store Connect 的年齡分級要設成 18+（Gemini API 條款要求使用者年滿 18 歲，也不能用在以未成年人為對象或可能被未成年人使用的 App）。

網址已經決定是 **www.smart-schedules.com**（不是佔位文字）：三頁 `<head>` 裡的 `<link rel="canonical">` 要是 `https://www.smart-schedules.com/`、`…/privacy`、`…/support`，不能是沒有 `www` 的根網域（根網域不提供網站，見 [§2 第 10 項](#2-發佈前要確認的事政策內容依賴這些)）。

替換完後，下面兩個指令都應該什麼都不印：

```sh
grep -rn 'class="todo"' site/public
grep -rn 'https://smart-schedules\.com' site/public      # 網址都要是 https://www.smart-schedules.com/…
```

## 2. 發佈前要確認的事（政策內容依賴這些）

1. **Gemini 必須是付費層級。** 政策第 4、11、12、13 節寫「Google 不會用提示或回覆改善產品，最多保留 55 天、只用於濫用監控和法律要求的揭露」。這只有在 Gemini API 的 Google Cloud 專案連結了有效的 Cloud Billing（Paid Services）時才成立；免費層級下 Google 會用內容改善產品，也可能有人工審閱。**發佈網站或送 Google 驗證的條件是：** 新金鑰所屬的 Cloud 專案在 Google Cloud 控制台 › Billing 顯示已連結有效的帳單帳戶，而且 AI Studio 的 API 金鑰／專案頁顯示付費層級（例如 Tier 1）。`cd server/worker && npm run check-key` 通過**不算**：它只送一個請求、印出 HTTP 狀態，免費層級的金鑰也會通過。
2. **Gemini 的記錄與資料分享要關著。** 政策第 4 節寫「伺服器不保存或記錄內容」，第 11 節寫「不允許別人用來訓練模型」。有帳單的專案可以在 AI Studio 開啟 Generate Content API 的請求記錄（開發者看得到、保留最多 55 天），專案擁有者也可以選擇把記錄的資料集分享給 Google 改善模型。在 AI Studio › Logs（記錄）確認這個 Gemini 專案的記錄是關閉的，而且從不選擇和 Google 分享資料集；如果要開，先改寫政策第 4、11、13 節。README 和 docs/SETTINGS.md §16 的上架清單也要加上這一項（這個資料夾以外的變更，另外處理）。
3. **對照官方原文。** 撰寫時下列頁面只能看到搜尋摘要，發佈前請再讀一次原文：
   - Gemini API 條款（https://ai.google.dev/gemini-api/terms ，含 18 歲規定和付費服務適用的處理者條款）；
   - 使用政策的 55 天保留期和「被標記時可能由 Google 授權人員人工審閱」（https://ai.google.dev/gemini-api/docs/usage-policies ）；
   - Gemini 的記錄政策（https://ai.google.dev/gemini-api/docs/logs-policy ）；
   - Google 的處理者資料處理附錄（https://business.safety.google/processorterms/ ）：第 12、17 節寫它以標準契約條款（SCC）處理跨境傳輸，並寫 Google LLC 有歐盟—美國資料隱私框架（DPF）和它的英國延伸（UK Extension）的認證（可在 https://www.dataprivacyframework.gov/list 查，Cloudflare 也一起確認：政策第 17 節寫它用 DPF、英國延伸和標準契約條款；瑞士不上架，所以沒寫瑞士—美國 DPF）；
   - Google API Services User Data Policy（https://developers.google.com/terms/api-services-user-data-policy ，第 11 節的「合併、收購或資產出售須事先取得明確同意」）；
   - Apple App Review Guidelines 5.1.1(i)（第三方提供同等保護的聲明，第 12 節）；
   - Cloudflare DPA。
4. **政策照目前的程式寫，程式改了政策就要跟著改。** 依據是 2026-10-15 對照程式碼（base commit `b6fc485`）整理的事實，加上到 2026-10-16 為止工作區的改動（帳號 email 不送給 Gemini、同意說明第 5 版、1.0 沒有 push-to-start、1.0 不賣訂閱）。第一項已經在程式裡改好；其餘是 App 端的落差，都在這個資料夾以外，要另外處理，但**送審前一定要解決**：
   - **Google 帳號的 email 不送給 Gemini（程式已改）。** 助理的 prompt 經過 `CalendarAliases`（`Shared/AI/CalendarAliases.swift`）：有好幾個帳號時以「Account 1」「Account 2」區分，名稱是 email 的行事曆叫「Shared calendar」；行程標題、地點、備註和送回 Gemini 的錯誤訊息裡，已連接帳號的 email 換成「[account email]」「[Account N email]」，錯誤訊息裡的其他 email 換成「[email address]」；使用者自己輸入或說出的話裡如果有已連接帳號的 email，也換成佔位字，其他照原樣送出；Gemini 回覆裡的佔位字在 iPhone 上換回地址，才寫進 Google 日曆或顯示（`docs/GEMINI_FUNCTION_CALLING.md` §10.6）。同意說明是第 5 版（`AIConsent.disclosureVersion = 5`；第 4 版起帳號 email 不送給 Gemini，第 5 版拿掉 1.0 用不到的 iOS 18 伺服器說明），五項內容和 prompt 實際送出的一致。第 5 版的同意畫面在任何 iOS 上都沒有 iOS 18 伺服器那一段（`AIConsentDisclosure.serverNote` 是 nil，因為 `AppConstants.pushToStartEnabled = false`，1.0 沒有 push-to-start），所以政策第 4 節**不能**引用那一段。網站照這個寫：政策第 4 節（中英文）列出實際送出的內容、說明帳號 email 的代稱和佔位字，並**逐字引用**同意說明的開頭、五項和收件者；第 11 節寫帳號 email 只在 iPhone 上用、不傳給 Gemini；支援頁「怎麼停止 AI 資料分享」引用其中一項；首頁的「AI 與隱私」也寫了。**`AIConsentDisclosure` 的文字再改時，政策第 4 節的引用要一起改**：英文照 `Shared/Storage/AIConsentStore.swift`，中文照 `Shared/Localization/Localizable.xcstrings` 的 zh-Hant 翻譯。
   - 麥克風是點一下開始、再點一下或送出才停（展開的動態島麥克風按鈕會直接開始錄音），政策第 8 節照實寫了；`project.yml` 和 `zh-Hant.lproj/InfoPlist.strings` 的 `NSMicrophoneUsageDescription` 也已改成「點麥克風後」（tap the mic）。
   - 示範模式：如果之前已經允許 AI 資料分享，App 在示範模式下仍會更新 session（`POST /session`），政策第 1 節照實寫了。1.0 沒有 push-to-start（`AppConstants.pushToStartEnabled = false`），示範模式和一般模式都不會上傳任何行程。如果改成示範模式時跳過 session 更新，可以把第 1 節括號裡那句拿掉。
   - Google 撤銷授權是盡力而為（一次請求、10 秒逾時、失敗也不告訴使用者，權杖照樣刪除）。政策第 13、15 節和支援頁照實寫成「向 Google 要求撤銷，需要網路，離線時請到 Google 帳號移除」。如果 App 改成撤銷失敗時提示使用者或保留權杖重試，可以簡化這些句子。
   - App Attest 的 `key:<keyId>` 記錄沒有 TTL，Worker 也沒有刪除它的路由，「清除所有資料」後也還在（政策第 6、13 節照實寫了）。之後加上 TTL 或有簽章的刪除路由（讓「清除所有資料」呼叫）時，改這兩節。
   - 金鑰在**允許 AI 資料分享時**就產生，之後 session 每隔幾天自動更新（session 7 天、剩不到 3 天就換），即使沒用助理；政策第 6 節照實寫了。
   - **1.0 沒有 iOS 18 的 push-to-start（`AppConstants.pushToStartEnabled = false`）。** 政策摘要、第 5 節、首頁和支援頁「動態島什麼時候會出現？」都寫即時動態直接在 iPhone 上產生、不會把行程傳到伺服器；第 5 節也寫伺服器不保存任何行程、不使用 Apple 推播通知服務。iOS 26 在 iPhone 上排程；iOS 18 只有在提前時間內或行程進行中打開 App（或 App 一直開著到那個時間）才出現。之後的版本打開這個旗標時，同一次發佈要把第 5 節的伺服器登記、第 13 節保存期限那一列、第 15 節的法律依據和摘要改回來（舊文字在 git 歷史裡），並重新填 App 隱私問卷。
   - 其他寫進政策的數字：最低年齡 18、即時動態排程接下來兩天（iOS 26）、session 7 天、計數 2 天、log 最多 7 天（Workers Paid plan）、對話從今天起 14 天、最多 40 個行程和最近 6 輪、備註 300 字、動態島提前時間 30／15／10／5 分鐘。
5. **support@smart-schedules.com 用 Google Workspace 收信和回信，政策照這個寫。** support@ 是 Google Workspace 的真實信箱（組織「Smart Schedule」，smart-schedules.com 是 Workspace 的主要網域，已驗證）。收信和回信都直接用 Workspace 的 Gmail，**不用 Cloudflare Email Routing**。政策第 9、12、13、17 節（中英文）照這個寫：Google（Google Workspace）的 Gmail 接收、保存客服信件並寄出回信，依 Google Workspace 適用的雲端資料處理附錄（Cloud Data Processing Addendum，CDPA）作為處理者。發佈前：
   - **DNS 留在 Squarespace，Google 的郵件紀錄一筆都不要動**（MX、SPF、`google-site-verification`，以及已經有的 DKIM、DMARC）。照 [§3.6](#36-google-workspace-郵件dkim-和-dmarc加在-squarespace) 在 Squarespace 的 DNS 完成 DKIM 和 DMARC（Google Admin console 的「Complete email setup」），並做那裡的收發測試。
   - 確認 CDPA 已經生效：用超級管理員（super admin）登入 Google Admin console（https://admin.google.com）› 帳戶（Account）› 帳戶設定（Account settings）› 法律與法規遵循（Legal and compliance）› 安全性與隱私權附加條款（Security and Privacy Additional Terms）› 雲端資料處理附錄（Cloud Data Processing Addendum）› 檢查並接受（Review and Accept）。Google 說 Workspace 合約已經納入 CDPA 時不必再接受，不確定就接受，沒有副作用（請在畫面上確認）。
   - 之後如果改用別的收信方式（例如取消 Workspace），政策第 9、12、13、17 節要一起改。
6. **1.0 沒有 App 內購買。** 政策第 7 節「購買」寫 1.0 沒有任何 App 內購買或訂閱、App 不查詢購買記錄，第 12 節 Apple 那一項沒有「App 內購買」；支援頁的常見問題只留一題「有 App 內購買或訂閱嗎？」（`#zh-purchases`、`#en-purchases`），回答「沒有」。這要和 `AppConstants.subscriptionsEnabled = false`、App Store Connect 不附加任何購買項目一致。之後的版本開始賣 Smart Schedules Pro 時，在同一次發佈改回（舊的文字在 git 歷史裡）：政策第 7 節（由 Apple 銷售和收費、我們收不到付款資料、App 在 iPhone 上確認訂閱、清除資料不影響購買）和第 12 節的「App 內購買」；支援頁的「怎麼取消訂閱？」「怎麼回復購買項目？」（頭像 › 管理訂閱／回復購買項目、期間結束 24 小時前取消、退款到 reportaproblem.apple.com）、「多久會回覆」和「怎麼刪除我的資料？」裡訂閱的那一句，以及支援頁的 meta description。
7. **上架地區：1.0 不在歐洲經濟區、瑞士、香港、澳門和中國大陸上架**（App Store Connect › 價格與供應狀況（Pricing and Availability）取消 27 個歐盟會員國，加上挪威、冰島、列支敦斯登、瑞士，以及香港、澳門（清單上可能寫 Macao，請在畫面上確認）、中國大陸（Gemini API 不在那裡提供）；**英國**和其他地區照常上架，見 `docs/app-store-metadata.md` §4.3）。政策照仍在上架範圍內的地區寫：第 1 節用「英國 GDPR 等個資法」的用語，第 15 節的地區舉例是英國、美國加州和台灣，申訴機關舉英國的 ICO，法律依據的標題是「適用英國 GDPR 或類似法律時」，第 17 節寫英國使用者適用的 DPF 英國延伸。權利（查詢、更正、刪除、限制、反對、可攜、撤回同意）和法律依據的內容不變，英國 GDPR 一樣適用。
   - **歐洲經濟區和瑞士的代表（GDPR 第 27 條、瑞士 FADP 第 14 條）：排除期間不需要。** 之後的版本加入這些 storefront 前，要指定代表、把名稱和郵寄地址寫進政策第 1、19 節（中英文），並把第 1、15 節的法規、地區舉例和申訴機關（挪威 Datatilsynet、冰島 Persónuvernd、瑞士 FDPIC 等）加回去。
   - **英國代表（英國 GDPR 第 27 條）：不需要。** 開發者在英國（網域 WHOIS 的註冊人國家是 GB），第 27 條只要求英國境外的控管者指定代表。要確認的是 ICO 的資料保護費（data protection fee）：上架前到 ico.org.uk 的「Do I need to pay the fee?」自我評估，依結果繳費或記下不用繳的理由，金額以 ICO 網站為準（`docs/app-store-metadata.md` §4.4 第 4 點）；政策第 1、19 節的控管者名稱要和繳費登記的名稱一致。
   - **挪威、冰島、列支敦斯登、瑞士、香港、澳門和中國大陸都不是歐盟**，只取消歐盟 storefront 不會排除它們，所以要一個一個另外勾掉。
8. **App 名稱是「Smart Schedules」。** 「Smart Schedule」（沒有 s）在 App Store 已經有人用，所以三頁的標題、頁首、內文和 meta 都寫「Smart Schedules」，和 App Store 名稱、Google OAuth 的 App name、iPhone 主畫面上的名稱（`CFBundleDisplayName`）一致。之後名稱再改時，這四處要一起改。隱私權政策和支援頁引用的來源行「由 Smart Schedules 智慧助理自動排程：」要和 App 寫進 Google 日曆說明欄的文字（`CalendarEventMapper.provenancePrefix`）一字不差。
9. App 上架後，在首頁加上 App Store 連結。
10. **網址一律用 https://www.smart-schedules.com。** 網站只在 www 上提供；根網域 smart-schedules.com 最多轉址到 www（[§3.5](#35選做根網域-smart-schedulescom-轉到-www)，選做），所以任何正式填寫的網址都不要用根網域：Google OAuth 的 Application home page 和 privacy policy link（[§4](#4-google-auth-platformgoogle-cloud-控制台)）、App Store Connect 的 Privacy Policy URL、Support URL、Marketing URL 和 `project.yml` 的 `SSPrivacyURL`（[§5](#5-app-store-connect-和-app)）、三頁的 `<link rel="canonical">`（[§1](#1-發佈前要替換的佔位文字)）。Google OAuth 的授權網域（Authorized domains）和 Search Console 的網域資源仍然是 `smart-schedules.com`，涵蓋 www。

## 3. 網站上線：www.smart-schedules.com（Cloudflare Pages ＋ Squarespace 一筆 CNAME，不搬 DNS）

以下都還沒做。順序：[3.1](#31-建立-pages-專案並部署在終端機) 建立專案並部署 → [3.2](#32-在-pages-加上自訂網域-wwwsmart-schedulescom) 在 Pages 加自訂網域 → [3.3](#33-在-squarespace-加一筆-cnamewww--pagesdev) 在 Squarespace 加 CNAME → [3.4](#34-等-active-和憑證然後檢查網站) 等 Active、檢查 → [3.5](#35選做根網域-smart-schedulescom-轉到-www)（選做）根網域轉址。郵件的 [3.6](#36-google-workspace-郵件dkim-和-dmarc加在-squarespace)（DKIM、DMARC）和 [3.7](#37-google-search-console-驗證)（Search Console）和網站無關，隨時可以做，但都要在送 Google 驗證之前完成。

**不會變的事：**

- **DNS 留在 Squarespace。** 不換 nameserver（仍然是 `nsa1.squarespacedns.com`～`nsa4.squarespacedns.com`），不在 Cloudflare 加入網域。網域的註冊、續約和帳單照舊（網域是 2026-10-14 透過 Google Workspace 購買，註冊商是 Squarespace Domains II LLC）。
- **DNSSEC 不用動。** DNS 一直由 Squarespace 回答和簽章，新加的紀錄 Squarespace 會一起簽。不要關掉 DNSSEC，也不用加 DS 紀錄。
- **Google Workspace 的郵件紀錄一筆都不要動**：MX（`smtp.google.com` 或 `aspmx.l.google.com` 那幾筆）、SPF（`v=spf1 include:_spf.google.com ~all`）、`google._domainkey`（DKIM）、`_dmarc`（DMARC）、每一筆 `google-site-verification`，以及 Squarespace DNS 設定裡的「Google Workspace」區塊。support@ 的收發信、Admin console 的網域驗證都靠它們。網站只用到 `www` 這個主機名稱，和郵件完全無關。
- **不用 Cloudflare Email Routing**，也不用改 Google Admin console 的任何設定（DKIM、DMARC 是 [§3.6](#36-google-workspace-郵件dkim-和-dmarc加在-squarespace) 另外補的）。

**開始前：**

- 括號裡是畫面上的英文字。Cloudflare 的整理自官方文件（2026-10），Squarespace 的整理自官方說明文章被搜尋引擎收錄的內容（2026-10，當時無法直接打開 support.squarespace.com），Google Admin console 的整理自 Google Workspace 說明文件。**畫面和這裡不同時，以畫面為準。**
- 全程用**跑著 Worker `smart-schedule-worker` 的同一個 Cloudflare 帳號**，之後比較好管理（Pages 的子網域自訂網域本身不要求網域在這個帳號裡）。
- **之前如果照舊版指南在 Cloudflare 加過 smart-schedules.com**（Cloudflare › 網域（Domains）清單裡有它，狀態是 Pending 或 Pending Nameserver Update），先把它移除：選 smart-schedules.com › 總覽（Overview）頁右下角的進階動作（Advanced Actions）› 從 Cloudflare 移除網站（Remove site from Cloudflare）（請在畫面上確認）。留著的話，Pages 可能把 www 的紀錄加到這個沒有生效的 Cloudflare 區域，而不是請你加到 Squarespace（請在畫面上確認）。沒加過就跳過。
- `dig` 和 `curl` 指令在終端機執行；`dig` 也可以改用網頁 https://www.whatsmydns.net/ 或 Google Admin Toolbox 的 Dig（https://toolbox.googleapps.com/apps/dig/ ）。
- `example@gmail.com` 一律換成你自己的私人信箱。私人信箱不要寫進這個 repo 或網站。

**大概的時間：** 3.1～3.3 幾分鐘；Squarespace 的新紀錄通常幾分鐘到幾小時就查得到（第三方說明寫最多 24～48 小時）；查得到之後，Pages 通常幾分鐘內變成 Active 並簽好憑證（Cloudflare 說超過 15 分鐘還在驗證就要查原因，見 [§3.9](#39-疑難排解)）。

### 3.1 建立 Pages 專案並部署（在終端機）

在**一般的終端機視窗**（macOS 的「終端機」App 或 iTerm）裡執行，不要在 AI 工具或腳本裡執行（原因見下面）。先 `cd` 到 repo 的根目錄：

```sh
cd site                                       # 之後的指令都在 site/ 裡執行
W=../server/worker/node_modules/.bin/wrangler
$W --version                                  # 4.146.0
$W whoami                                     # 確認是跑 smart-schedule-worker 的帳號；沒登入就先執行 $W login
$W pages project create smart-schedules-site --production-branch main      # 只做一次
$W pages deploy public --project-name smart-schedules-site --branch main --commit-dirty=true
```

- 沒有 `server/worker/node_modules` 的話，先在 `server/worker` 裡執行 `npm ci`。
- **`pages project create` 只做一次。** 成功時印出「✨ Successfully created the 'smart-schedules-site' project. It will be available at https://…pages.dev/ once you create your first deployment.」。**把那個 `pages.dev` 主機名稱抄下來**，[§3.3](#33-在-squarespace-加一筆-cnamewww--pagesdev) 的 CNAME 要指向它。通常就是 `smart-schedules-site.pages.dev`；名稱被別人用掉時 Cloudflare 會加上幾個隨機字元。之後忘了可以用 `$W pages project list` 查（Project Domains 欄），或在控制台 Workers & Pages › smart-schedules-site 看。
- **`pages deploy` 每次都加 `--branch main`。** 只有分支等於專案的 production branch（`main`）時才是正式部署；不加的話 wrangler 用目前的 git 分支做預覽部署，www 會繼續提供舊版。成功時印出「✨ Deployment complete! Take a peek over at https://….pages.dev」（這次部署專屬的網址）。`--commit-dirty=true` 只是不顯示「有未提交變更」的警告。
- **要在 `site/` 裡執行。** Pages 只讀目前資料夾的 `wrangler.toml`，不接受 `-c`／`--config`（會報錯「Pages does not support custom paths for the Wrangler configuration file」）；在 `site/` 裡執行時，wrangler 的快取也會放在 `site/.wrangler/`（git 已忽略）。在 repo 根目錄執行也能部署（`$W pages deploy site/public …`），但會在根目錄多出沒被忽略的 `.wrangler/`；在 `server/worker` 裡執行會讀到 API Worker 的 `wrangler.toml`，不要在那裡執行。
- 上傳的只有 `public/` 的內容；`wrangler.toml`、`README.md`、`.gitignore` 不會上傳。
- 你的 Cloudflare 登入可以進好幾個帳號時，會先問「Select an account」：選跑 `smart-schedule-worker` 的那個。
- **wrangler 偵測到 AI agent 時的行為。** wrangler 4.146.0 在偵測到自己是被 AI 工具執行時，`pages project create` 會改成建立一個 Worker（印出「Delegating to the latest version of Cloudflare Pages, now part of Cloudflare Workers」），而不是 Pages 專案。在一般終端機執行不會發生。萬一看到這一行：到控制台 Workers & Pages 看有沒有多出叫 `smart-schedules-site` 的 Worker，有的話刪掉（Worker › 設定（Settings）› 刪除（Delete），請在畫面上確認），然後在一般終端機重新執行 `pages project create`；還是一樣才在那一行最後加上 `--force`（wrangler 4.146.0 有這個隱藏旗標，意思是直接建立 Pages 專案）。`--force` 只需要在 `project create` 用一次；專案存在之後，加了 `--branch` 的 `pages deploy` 不會被轉成 Worker。
- **本機預覽：** 在 `site/` 裡執行 `$W pages dev`，打開 http://localhost:8788 。啟動時會列出 `SS_KV` 等 `server/worker` 的 binding（wrangler 從自己所在的 `server/worker` 讀到 API Worker 的設定），只在本機、和網站無關，可以忽略；本機的 `/_headers` 會回 502，上線後是 404，都不會提供那個檔案。

**成功時會看到：** `curl -sI https://<專案>.pages.dev/privacy` 回 `200`（`<專案>.pages.dev` 換成剛才抄下的主機名稱）；控制台 Workers & Pages 有 `smart-schedules-site`，部署（Deployments）分頁最上面是 Production 的部署（請在畫面上確認）。

**要多久：** 指令跑完就部署好了，`pages.dev` 馬上打得開。

`<專案>.pages.dev` 和每次部署專屬的 `….<專案>.pages.dev` 網址會一直公開，內容和 www 一樣；三頁的 canonical 指向 www，搜尋引擎會以 www 為準。不用把它們關掉。

### 3.2 在 Pages 加上自訂網域 www.smart-schedules.com

**一定要先在 Pages 加自訂網域，再（或同時）去 Squarespace 加 CNAME。** Cloudflare 說只加 CNAME、沒有在 Pages 登記這個網域的話，網址會出現 522 錯誤。

1. Cloudflare 控制台 › Workers & Pages › `smart-schedules-site` › 自訂網域（Custom domains）› 設定網域（Set up a domain，有時顯示 Set up a custom domain）。
2. 輸入 `www.smart-schedules.com`（不要加 `https://`）› 繼續（Continue）。
3. 因為 smart-schedules.com 不在 Cloudflare，畫面會請你自己到 DNS 供應商加一筆 CNAME（例如按 Begin CNAME setup 後顯示）：類型 `CNAME`、名稱 `www`（或 `www.smart-schedules.com`）、目標 `<專案>.pages.dev`。照畫面按啟用網域（Activate domain）或確認（請在畫面上確認按鈕名稱）。畫面上的目標和 3.1 抄下的不同時，**以畫面為準**。
4. 自訂網域清單會出現 `www.smart-schedules.com`，狀態先是驗證中（Verifying）或 Pending，等 3.3 的 CNAME 生效後才會變成 Active。接著馬上做 3.3。

- **不要在 Pages 加根網域 `smart-schedules.com`。** Pages 的根網域自訂網域要求網域用 Cloudflare 的 nameserver，1.0 不搬 DNS，所以加了也不會生效。根網域見 [§3.5](#35選做根網域-smart-schedulescom-轉到-www)。
- 不用在 Pages 加 `www.smart-schedules.com` 以外的網域，也不要對它設定 Cloudflare Access（Access 會擋住憑證驗證）。

**成功時會看到：** Custom domains 清單有 `www.smart-schedules.com`（狀態還不是 Active 是正常的）。

### 3.3 在 Squarespace 加一筆 CNAME（www → pages.dev）

1. **先截圖備份。** 到 https://account.squarespace.com/domains 登入（或 account.squarespace.com › 右上角頭像 › 網域（Domains））› 點 `smart-schedules.com` › DNS › DNS 設定（DNS Settings）。把整頁每個區塊都截圖：Squarespace Defaults（如果有）、Google Workspace、自訂紀錄（Custom Records）等。萬一刪錯，照截圖加回來。
2. **找出 `www` 現有的紀錄。** 同一個主機名稱有 CNAME 時不能再有其他紀錄，所以 `www` 原本的紀錄要先拿掉：
   - **Squarespace Defaults 區塊**（如果有）：通常有幾筆 `@` 的 A 紀錄（例如 `198.185.159.144`、`198.49.23.144` 這類 Squarespace 的位址）和一筆 `www` 的 CNAME（指向 `ext-sq.squarespace.com` 或 `ext-cust.squarespace.com`）。那一列有自己的刪除（垃圾桶）圖示的話，**只刪 `www` 那一筆**；只能整個區塊刪除的話，按「Squarespace Defaults」標題旁的垃圾桶 › 依提示重新輸入密碼或兩步驟驗證碼 › 確認（請在畫面上確認）。整個區塊刪掉的話，根網域也不再指向 Squarespace 的預設頁面；這不影響郵件，根網域要不要轉址見 [§3.5](#35選做根網域-smart-schedulescom-轉到-www)。**刪之前確認這個區塊裡只有 A／AAAA／CNAME（可能還有 HTTPS 類型）紀錄，沒有 MX 或 TXT。**
   - **自訂紀錄（Custom Records）** 裡如果有主機是 `www` 的 A、AAAA 或 CNAME，也刪掉（每一列的垃圾桶圖示）。
   - 沒有 Squarespace Defaults、也沒有任何 `www` 紀錄：不用刪。
   - **不要刪**「Google Workspace」區塊、任何 MX、任何 TXT（SPF、DKIM、DMARC、`google-site-verification`），也不要動 `@` 以外和網站無關的紀錄。
3. **加 CNAME。** 自訂紀錄（Custom Records）› 新增紀錄（Add Record）：
   - 主機（Host）：`www`（只填 `www`，Squarespace 會自己接上 `.smart-schedules.com`；填成 `www.smart-schedules.com` 會變成 `www.smart-schedules.com.smart-schedules.com`）
   - 類型（Type）：`CNAME`
   - 資料（Data）：`<專案>.pages.dev`（3.2 畫面上顯示的目標，從畫面複製貼上；不要加 `https://`、`/` 或空白）
   - 優先順序（Priority）、TTL：沒有要求，保留預設
   - 儲存（Save）。出現錯誤多半是 `www` 還有別的紀錄（回到第 2 步）。
4. **不要改** nameserver、DNSSEC 和其他紀錄。
5. **檢查憑證限制（CAA）。** 在終端機執行 `dig CAA smart-schedules.com +short` 和 `dig CAA www.smart-schedules.com +short`：
   - 都沒有輸出：不用做什麼（大多數情況）。
   - 有輸出，但沒有 `letsencrypt.org`、`pki.goog`、`ssl.com`：Cloudflare 簽不了憑證。在 Squarespace 自訂紀錄加 CAA 紀錄（類型選 CAA；Squarespace 支援這個類型）：主機 `@`，資料分別是 `0 issue "letsencrypt.org"`、`0 issue "pki.goog; cansignhttpexchanges=yes"`、`0 issue "ssl.com"`（Cloudflare 文件列的值；欄位怎麼填請在畫面上確認）。原有的 CAA 保留，只是另外加這三筆。

**成功時會看到：** DNS 設定的自訂紀錄裡有 `www` → `<專案>.pages.dev` 的 CNAME，Google Workspace 的紀錄都還在（和截圖比對）；過一陣子，`dig CNAME www.smart-schedules.com +short @8.8.8.8` 印出 `<專案>.pages.dev.`。

**要多久：** 存檔就好；生效通常幾分鐘到幾小時，見 3.4。

### 3.4 等 Active 和憑證，然後檢查網站

1. 用 `dig CNAME www.smart-schedules.com +short @8.8.8.8`（或 `@1.1.1.1`）確認 CNAME 已經查得到。
2. Cloudflare › Workers & Pages › `smart-schedules-site` › 自訂網域（Custom domains）：`www.smart-schedules.com` 的狀態從驗證中（Verifying）變成 **Active**（請在畫面上確認）。Pages 用 HTTP 驗證（透過這筆 CNAME 存取 `/.well-known/acme-challenge/…`），驗證通過時會一起簽好 SSL 憑證，不用另外設定。
3. CNAME 已經查得到、15 分鐘後還是驗證中：看 [§3.9](#39-疑難排解)。
4. 檢查（全部用 www）：

   ```sh
   curl -sI https://www.smart-schedules.com/               # 200
   curl -sI https://www.smart-schedules.com/privacy        # 200 text/html
   curl -sI https://www.smart-schedules.com/support        # 200 text/html
   curl -sI https://www.smart-schedules.com/privacy.html   # 308 -> /privacy
   curl -sI https://www.smart-schedules.com/nope           # 404
   curl -sI https://www.smart-schedules.com/ | grep -i content-security-policy   # _headers 有套用
   curl -sI http://www.smart-schedules.com/                # 應該轉到 https://（研究時沒找到官方說明，請實際確認）
   dig MX smart-schedules.com +short @8.8.8.8              # 和 3.3 之前一樣（Google 的 MX），證明郵件沒被動到
   ```

5. 用手機打開三頁，確認淺色、深色和語言切換都正常，而且沒有黃色的佔位文字。
6. 從另一個信箱（例如 `example@gmail.com`）寄一封信到 support@smart-schedules.com，用 support@ 登入 Gmail 看到它並回覆，確認郵件照常。

**成功時會看到：** Custom domains 顯示 Active；上面的 `curl` 結果和註解一樣；瀏覽器打開 https://www.smart-schedules.com 是新的首頁、網址列有鎖頭。

**要多久：** CNAME 查得到之後通常幾分鐘。

### 3.5（選做）根網域 smart-schedules.com 轉到 www

1.0 的所有正式網址都是 www，根網域打不開也不影響審查。Pages 不能直接提供根網域（要 Cloudflare 的 nameserver），但 Squarespace 的網域轉址（domain forwarding）可以把 `smart-schedules.com` 轉到 `https://www.smart-schedules.com`。**這一節的選項名稱和行為都只來自說明文章摘要和使用者回報，請在畫面上確認。**

**開了根網域轉址的話，`smart-schedules.com` 的連線由 Squarespace 處理：** 同一次發佈在政策第 10 節（中英文）補一句，例如「沒有 www 的網址由網域註冊商 Squarespace 轉到 www.smart-schedules.com，Squarespace 會處理這些連線的 IP 位址」/ "Requests to the address without www are forwarded to www.smart-schedules.com by our domain registrar, Squarespace, which processes the IP address of those requests."。沒開就不用改。

1. 網域總覽 › `smart-schedules.com` › 網站（Website）› 網域轉址規則（Domain Forwarding Rules）› 新增規則（Add rule，名稱請在畫面上確認）：
   - 子網域（Subdomain）：`@`（代表根網域）
   - 目標網址（URL / Destination）：`https://www.smart-schedules.com`
   - 進階設定（Advanced settings）：轉址類型選 **301（永久，Permanent）**；路徑選保留路徑（例如 Forward path／Maintain path），讓 `/privacy` 轉到 `https://www.smart-schedules.com/privacy`；透過 SSL 轉址（Forwarding over SSL）打開
   - 儲存（Save）
2. **只加 `@` 的規則，不要加 `www` 的轉址規則**（`www` 已經是 3.3 的 CNAME，轉址規則會和它衝突或把它換掉）。
3. 已知的不確定處：
   - Squarespace 說網域轉址規則只出現在 Squarespace 註冊的網域；smart-schedules.com 的註冊商是 Squarespace Domains II LLC，應該看得到（請在畫面上確認）。
   - 新增時如果出現衝突錯誤：表示 `@` 還有別的 A／AAAA／CNAME（例如 Squarespace Defaults 的 A 紀錄）。依畫面提示處理；有使用者回報 `@` 的轉址需要 Squarespace Defaults 還在。兩種情況都**只處理 `@` 和 `www` 以外無關郵件的紀錄**，MX 和 TXT 不要動。
   - 轉址只影響網頁（HTTP），不影響郵件（MX）。
   - `https://smart-schedules.com` 能不能正常轉（需要 Squarespace 為根網域簽憑證）沒有官方說明；`http://` 能轉、`https://` 出現憑證錯誤的話，就維持這樣，1.0 不需要。
4. 看不到這個選項或一直不成功：跳過。根網域就只是打不開網站，Google OAuth 的授權網域 `smart-schedules.com` 仍然涵蓋 www，Search Console 的網域資源也一樣。

**成功時會看到：** `curl -sI http://smart-schedules.com/privacy` 回 `301`，`Location: https://www.smart-schedules.com/privacy`（`https://smart-schedules.com/` 也能轉更好，不是必要）。

**要多久：** 研究時沒查到確切時間，通常 DNS 生效後就會轉（請在畫面上確認）。

### 3.6 Google Workspace 郵件：DKIM 和 DMARC（加在 Squarespace）

support@smart-schedules.com 是 Google Workspace 的信箱：寄來的信由 Squarespace DNS 裡 Google 的 MX 直接送進 Workspace 的 Gmail；**回信也直接在 Workspace 的 Gmail 按回覆**（用 support@ 登入 https://mail.google.com），寄件人就是 support@smart-schedules.com，不需要「以這個地址寄送郵件」（Send mail as）、SMTP 或應用程式密碼。DNS 不搬，所以 MX、SPF 等**都不用動**。

這一步只處理 Google Admin console 首頁那條「Improve the chances of your email landing in inboxes … Complete email setup」橫幅：完成 DKIM 和 DMARC，讓回信比較不會被當成垃圾郵件。紀錄一律加在 **Squarespace › DNS › DNS 設定（DNS Settings）› 自訂紀錄（Custom Records）**。也可以直接點橫幅上的 Complete email setup 跟著畫面做，畫面要你加的 DNS 紀錄一樣加在 Squarespace（請在畫面上確認）。這一步和網站無關，3.1～3.5 之前或之後做都可以。

1. **SPF 確認只有一筆。** Squarespace 的 DNS 設定裡，`@` 只有一筆 `v=spf1` 開頭的 TXT，內容是 `v=spf1 include:_spf.google.com ~all`（可能在「Google Workspace」區塊）。有就不要動；完全沒有的話，自訂紀錄 › 新增：主機 `@`、類型 `TXT`、資料貼上這一行 › 儲存。不要加第二筆 `v=spf1`。
2. **DKIM：先看是不是已經好了。** 用超級管理員（super admin）登入 Google Admin console（https://admin.google.com）› 選單 › 應用程式（Apps）› Google Workspace › Gmail › 驗證電子郵件（Authenticate email）› 選 `smart-schedules.com`：
   - 頁面上方已經顯示 DKIM 正在驗證（Authenticating email with DKIM）：DKIM 已經完成（透過 Google Workspace 買的網域，Google 可能已經自動設好，請在畫面上確認），直接做第 5 項（DMARC）。
   - Squarespace 已經有主機 `google._domainkey` 的 TXT，而且值和這頁顯示的 TXT 記錄值（TXT record value）一樣：**不要按產生新記錄**（會換掉金鑰），直接做第 4 項。
   - 否則按產生新記錄（Generate new record）› DKIM 金鑰長度（key bit length）選 2048 › 前置字串選取器（Prefix selector）保留預設的 `google` › 產生（Generate）。畫面會顯示 DNS 主機名稱（DNS Host name，`google._domainkey`）和 TXT 記錄值（`v=DKIM1; k=rsa; p=…`）。
3. **DKIM：加到 Squarespace。** 自訂紀錄（Custom Records）› 新增紀錄（Add Record）：主機 `google._domainkey`、類型 `TXT`、資料整段貼上 TXT 記錄值（不要自己加引號、空白或換行）› 儲存。已經有一筆 `google._domainkey` 的話，編輯那一筆，不要再加第二筆。Squarespace 不接受這麼長的值，或之後驗證一直失敗的話，回第 2 項改選 1024 重新產生，再把新的值貼上（Google 的建議；請在畫面上確認）。
4. **DKIM：開始驗證。** 回到 Admin console 的驗證電子郵件（Authenticate email）頁 › 開始驗證（Start authentication）。Google 說加入金鑰後最多 48 小時才會生效，這段期間頁面可能一直提示要更新 DNS 紀錄；確定紀錄加對了，就過一陣子再按。
5. **DMARC（DKIM 開始驗證之後）。** 自訂紀錄 › 新增紀錄：主機 `_dmarc`、類型 `TXT`、資料填下面這一行 › 儲存。

   ```
   v=DMARC1; p=none; rua=mailto:support@smart-schedules.com
   ```

   - 整個網域只能有一筆 `_dmarc`。已經有一筆的話，不要加第二筆：編輯那一筆，保留原本的 `p=`（不要改得更寬鬆），只把 `rua=mailto:support@smart-schedules.com` 放進去。
   - `p=none` 只監看、不影響投遞。各家信箱會把彙總報告（XML 附件）寄到 support@，可以用 Gmail 篩選器自動加標籤或封存。
   - 看了幾週報告、確認自己寄的信 SPF 和 DKIM 都通過之後，才考慮改成 `p=quarantine`。
6. **檢查。**

   ```sh
   dig MX smart-schedules.com +short @8.8.8.8                      # Google 的 MX（smtp.google.com 或五筆 aspmx），和以前一樣
   dig TXT smart-schedules.com +short @8.8.8.8                     # 剛好一筆 "v=spf1 include:_spf.google.com ~all"，加上 google-site-verification
   dig TXT google._domainkey.smart-schedules.com +short @8.8.8.8   # v=DKIM1; k=rsa; p=…（和 Admin console 顯示的一樣）
   dig TXT _dmarc.smart-schedules.com +short @8.8.8.8              # "v=DMARC1; p=none; rua=mailto:support@smart-schedules.com"
   ```

   - Google Admin Toolbox 的 Check MX（https://toolbox.googleapps.com/apps/checkmx/）› 輸入 `smart-schedules.com` › 執行檢查（按鈕名稱請在畫面上確認）。
   - **收發測試。** 從**另一個**信箱（例如 `example@gmail.com`）寄一封信到 support@smart-schedules.com › 用 support@ 登入 Gmail 看到這封信 › 直接按回覆（Reply）› 那個信箱收到寄件人是 support@smart-schedules.com 的回信 › 在那封回信按顯示原始郵件（Show original），SPF、DKIM、DMARC 都是 `PASS`。不要用 support@ 寄給自己測試，那封信只會出現在寄件備份。

**成功時會看到：** Admin console 的驗證電子郵件頁上方顯示 DKIM 正在驗證（Authenticating email with DKIM）；Check MX 不再警告 DKIM 和 DMARC；測試回信的 SPF、DKIM、DMARC 都是 `PASS`；Admin console 首頁的「Complete email setup」橫幅不見了（請在畫面上確認）。

**要多久：** DNS 通常幾分鐘到幾小時生效；DKIM 最多 48 小時才開始驗證；DMARC 報告大約一天一份。

**Google 的郵件紀錄一直保留，不要開 Email Routing。** 只要還在用 Google Workspace，Squarespace 上 Google 的 MX、SPF、DKIM、DMARC 和 `google-site-verification` 就都不要刪。之後真的要取消 Workspace，先停下來重新規劃，不要只改 DNS：support@ 的 Google 帳號會跟著消失，而 Squarespace、Google Cloud 專案、OAuth 的聯絡信箱和 Search Console 都掛在它上面，要先把這些登入和擁有者換到之後還會存在的帳號，決定新的收信方式，並改寫政策第 9、12、13、17 節（中英文）。

### 3.7 Google Search Console 驗證

Google OAuth 的品牌驗證要求首頁和隱私權政策所在的網域已經在 Search Console 驗證，而且驗證用的 Google 帳號是 Google Cloud 專案的 **Owner 或 Editor**。用**網域（Domain）資源** `smart-schedules.com` 驗證，它涵蓋 www 和所有子網域，所以網站放在 www 不用另外驗證。

1. **用 Workspace 帳號登入，先看是不是已經驗證了。** 用 support@smart-schedules.com 登入 https://search.google.com/search-console。它多半就是當初驗證 Workspace 網域的帳號，也是你登入 Google Cloud 的帳號（它要是 Cloud 專案的 Owner 或 Editor；換別的帳號的話，那個帳號也要是）。資源清單裡已經有 `smart-schedules.com` 網域資源而且打得開，就完成了。
2. 還沒有的話：新增資源（Add property）› 選左邊的 **網域（Domain）** › 輸入 `smart-schedules.com`（不加 `https://` 或 `www`）› 繼續（Continue）。網域資源只能用 DNS 驗證。Squarespace 的 DNS 裡如果有這個帳號驗證 Workspace 時加的 `google-site-verification` TXT，Search Console 可能直接顯示已驗證，或按驗證（Verify）就通過（請在畫面上確認）。
3. **自動方式（有出現才用）：** Search Console 認出 DNS 在 Squarespace 時，可能提供自動驗證（例如開始驗證（Start verification）› 登入 Squarespace › 授權），Squarespace 會自動加一筆 TXT（請在畫面上確認）。
4. **手動方式：** 記錄類型選 TXT，複製 `google-site-verification=…` › Squarespace › DNS › DNS 設定 › 自訂紀錄 › 新增紀錄：主機 `@`、類型 `TXT`、資料貼上 › 儲存 › 回 Search Console 按驗證（Verify）。這是**新加一筆**，不要覆蓋 Workspace 原本那筆 `google-site-verification`；同一個網域可以有好幾筆。
5. **所有 `google-site-verification` TXT 都要永久保留**，刪掉會失去 Search Console 或 Workspace 的驗證。它們可以和 Google 的 SPF TXT 並存；只能有一筆的是 SPF（`v=spf1`）紀錄。

**成功時會看到：** Search Console 顯示擁有權已驗證，資源清單裡有 `smart-schedules.com`（請在畫面上確認）。

**要多久：** 已經驗證或自動方式幾分鐘。手動方式 DNS 生效可能要幾分鐘到幾小時，失敗就過幾分鐘再按驗證，**不要改紀錄**。

### 3.8 之後更新網站

改了 `public/` 裡的檔案後，只要重新執行 [§3.1](#31-建立-pages-專案並部署在終端機) 的最後一行（在 `site/` 裡，一樣加 `--branch main`）。不用再建立專案，Squarespace 的 DNS 也不用動。Pages 每次部署都會更新快取，通常馬上看得到新版。

### 3.9 疑難排解

**www 打不開或出錯**
- **522 錯誤**：Pages 沒有登記 `www.smart-schedules.com`（[§3.2](#32-在-pages-加上自訂網域-wwwsmart-schedulescom) 沒做，或被移除了）。到 Pages › Custom domains 加回去。
- **一直是驗證中（Verifying），超過 15 分鐘**：
  - `dig CNAME www.smart-schedules.com +short @8.8.8.8` 沒有輸出：Squarespace 的紀錄還沒生效，或沒存好；主機要是 `www`（不是 `www.smart-schedules.com`），資料要和 Pages 畫面上的目標一字不差。
  - 有輸出但不是 `<專案>.pages.dev.`：`www` 還有舊的紀錄（例如 Squarespace Defaults 的 `ext-sq.squarespace.com`），回 [§3.3](#33-在-squarespace-加一筆-cnamewww--pagesdev) 第 2 步刪掉。
  - CAA 擋住憑證：見 §3.3 第 5 步。
  - 都正常還是卡住：在 Custom domains 那一列的選單重試驗證，或移除後重新加一次（請在畫面上確認）。
- **在 Squarespace 新增 CNAME 時出現錯誤**：`www` 還有別的紀錄（Squarespace Defaults 或自訂紀錄裡的 A／AAAA／CNAME），先刪掉。
- **還是舊的內容**：部署時沒有加 `--branch main`，那次只是預覽部署。`$W pages deployment list --project-name smart-schedules-site` 看最新的 Production 部署，然後用 `--branch main` 重新部署。
- **不存在的網址也回首頁（200）**：上傳的資料夾裡沒有最上層的 `404.html`，Pages 進了單頁應用程式模式。確認 `public/404.html` 還在，重新部署。
- **部署時印出「Delegating to the latest version of Cloudflare Pages…」**：見 [§3.1](#31-建立-pages-專案並部署在終端機) 的「wrangler 偵測到 AI agent 時的行為」。
- **`The Pages project "smart-schedules-site" does not exist`**：還沒做 `pages project create`，或登入的是另一個 Cloudflare 帳號（`$W whoami`）。

**根網域 smart-schedules.com**
- 打不開：1.0 本來就不提供，要轉址見 [§3.5](#35選做根網域-smart-schedulescom-轉到-www)（選做）。不要為了根網域去改 MX 或 TXT。

**support@ 收不到信或寄不出去**
- 這次的步驟只動了 `www`（和選做的 `@` 轉址、DKIM／DMARC 的 TXT），不會影響收信。先查 `dig MX smart-schedules.com +short @8.8.8.8`：沒有輸出或不是 Google 的 MX，表示 Google Workspace 的紀錄被刪了，照 3.3 第 1 步的截圖在 Squarespace 加回來（值和優先順序照抄）。寄件伺服器通常會重試好幾天，修好之後，這段期間寄來的信大多還會陸續送到。
- Google Admin console 說網域沒驗證，或郵件設定狀態不是 All OK：有 `google-site-verification` TXT 或 MX 被刪了，照截圖補上。
- 回信進了對方的垃圾郵件，或被退信說 SPF／DMARC 沒通過：`@` 要剛好一筆 `v=spf1 include:_spf.google.com ~all`（有兩筆 `v=spf1` 就合併成一筆）；完成 3.6 的 DKIM；DMARC 先用 `p=none`。
- DKIM 按開始驗證（Start authentication）失敗：`dig TXT google._domainkey.smart-schedules.com +short @8.8.8.8` 沒有輸出，或和 Admin console 顯示的值不同。主機要是 `google._domainkey`、資料要完整、只能有一筆；剛加的話最多等 48 小時再按；一直失敗就改用 1024 位元的金鑰（3.6 第 3 項）。
- 用 support@ 寄給 support@ 自己：只會出現在寄件備份，改用另一個信箱測試。

**Search Console 驗證失敗**
- 新的 TXT 覆蓋了 Workspace 原本那筆 `google-site-verification`：把原本那筆照截圖加回來，兩筆並存。
- 主機要填 `@`，資料要完整貼上 `google-site-verification=…`。
- 還沒生效：過幾分鐘再按驗證（Verify），不要改紀錄。
- 資源類型要選網域（Domain），只輸入 `smart-schedules.com`，不要加 `https://` 或 `www`。
- Search Console 驗證過了，Google 品牌驗證卻還說網域沒驗證：驗證用的 Google 帳號不是 Cloud 專案的 Owner 或 Editor，換對的帳號再驗證一次。

## 4. Google Auth Platform（Google Cloud 控制台）

`calendar.events` 和 `calendar.calendarlist.readonly` 是敏感（sensitive）scope，不是受限（restricted）scope：要過品牌驗證和敏感 scope 審查。審查可能要好幾週，而且只依賴這個網站，不必等 Apple 開發者帳號，所以網站上線後就盡快送。

1. **Branding**：
   - App name：和首頁、App Store 名稱完全一致（「Smart Schedules」；「Smart Schedule」在 App Store 已經有人用）。
   - Logo：120×120，用 `public/logo.png`。
   - Application home page：`https://www.smart-schedules.com/`
   - Application privacy policy link：`https://www.smart-schedules.com/privacy`
   - Terms of service：留空。這裡的連結必須在授權網域上，所以不能填 Apple 的標準 EULA。
   - Authorized domains：`smart-schedules.com`（不加 `www`；授權網域涵蓋它的子網域，首頁和政策放在 www 沒問題）
   - User support email：下拉選單只會列出登入的帳號和你管理的 Google 群組。要顯示 support@smart-schedules.com，它必須是專案 Owner／Editor 的 Google 帳號或群組。support@ 是 Workspace 帳號，你也用它登入 Google Cloud，所以用它登入、而且它是專案 Owner 或 Editor 時就可以直接選（請在畫面上確認）。
2. **Audience**：發佈（In production）。還在 Testing 時，refresh token 7 天就過期。
3. **Data Access**：加入兩個 calendar scope，各寫一段用途說明。
4. **Verification Center**：送審，附上不公開的 YouTube 示範影片：OAuth 同意畫面（語言設成英文）、新增行程（`calendar.events`）、抽屜列出行事曆（`calendar.calendarlist.readonly`）。
5. 首頁已經符合 Google 的要求：公開、不需登入、在已驗證的網域上（Search Console 的網域資源 `smart-schedules.com` 涵蓋 www）、說明 App 做什麼和為什麼用 Google 日曆資料、有明顯的隱私權政策連結和 support@smart-schedules.com，也放了 Limited Use 聲明。隱私權政策第 11 節有 Google 規定的 Limited Use 原文，以及「不用 Google 使用者資料訓練 AI/ML 模型」的承諾。
6. 首頁和政策網址要直接回 200（[§3.4](#34-等-active-和憑證然後檢查網站) 的檢查），不要填根網域、`http://` 或 `/privacy.html` 這些會轉址的網址。

## 5. App Store Connect 和 App

- **Privacy Policy URL**：`https://www.smart-schedules.com/privacy`。App Store Connect 可以依語言設定，但這一頁本來就有中英文，兩種語言都填同一個網址即可。
- **Support URL**（必填，頁面上必須有聯絡方式）：`https://www.smart-schedules.com/support`
- **Marketing URL**（選填）：`https://www.smart-schedules.com/`
- **`project.yml`**：`SSPrivacyURL` 要是 `https://www.smart-schedules.com/privacy`（這個資料夾以外的變更，另外處理）。

## 附錄：之後若要把 DNS 搬到 Cloudflare（1.0 不需要）

**1.0 不需要做這一節。** 網站已經在 Cloudflare Pages 上（[§3](#3-網站上線wwwsmart-schedulescomcloudflare-pages--squarespace-一筆-cname不搬-dns)），DNS 留在 Squarespace 就能運作。只有之後想讓 Cloudflare 管 DNS（例如根網域也要由 Cloudflare 轉址、或要把註冊轉到 Cloudflare Registrar）時才照這裡做。搬 DNS 不需要重新部署網站。

這個附錄只把 **DNS 交給 Cloudflare**（換 nameserver），**註冊、續約和帳單都還留在 Squarespace**。要不要把註冊也搬到 Cloudflare 是第 8 步，可以之後再做。所有指令都在 repo 根目錄執行。

- 全程用**建立 Pages 專案 `smart-schedules-site`、跑著 Worker `smart-schedule-worker` 的同一個 Cloudflare 帳號**。DNS 在同一個帳號裡，Pages 的自訂網域才會由 Cloudflare 自動管理。
- **郵件留在 Google Workspace。** support@smart-schedules.com 是 Google Workspace 的信箱：Google Admin console 顯示組織「Smart Schedule」、smart-schedules.com 是主要網域（primary domain）、已驗證（Verified）、郵件設定狀態「All OK」，所以 Squarespace 的 DNS 裡已經有 Google 的 MX。搬 DNS 時 **Google 的郵件紀錄要一筆不漏、原樣搬到 Cloudflare**，而且**完全不用 Cloudflare Email Routing**：它要獨占整個網域的 MX，開了就會和 Google 的 MX 衝突，support@ 收不到信。
- **網站的 `www` CNAME 也要搬。** [§3.3](#33-在-squarespace-加一筆-cnamewww--pagesdev) 加的 `www` → `<專案>.pages.dev` 一定要在 Cloudflare 上，否則換完 nameserver 網站就打不開。
- 括號裡是畫面上的英文字。Squarespace 的按鈕名稱整理自官方說明文章被搜尋引擎收錄的內容（2026-10，當時無法直接打開 support.squarespace.com），Cloudflare 的整理自官方文件（2026-07～10 更新），Google Admin console 的整理自 Google Workspace 說明文件被搜尋引擎收錄的內容（2026-10）。**畫面和這裡不同時，以畫面為準。**
- `example@gmail.com` 一律換成你自己的私人信箱。私人信箱不要寫進這個 repo 或網站。
- `dig` 和 `curl` 指令在終端機執行；`dig` 也可以改用網頁 https://www.whatsmydns.net/ 或 https://dnsviz.net 檢查。

大概的時間：第 0 步關 DNSSEC 後，要等舊的 DS 紀錄從註冊局消失、再多等 24 小時，才能做第 2 步（合計大約 2～3 天，見第 0 步的「要多久」）；第 2 步之後最多再等 24～48 小時變成 Active；一變成 Active 就檢查郵件和網站（第 3 步）；然後依序做第 4 步（確認 DKIM、DMARC）、第 5 步（確認網站、根網域轉到 www）和第 6 步（Search Console）。

### 0. 開始前（在 Squarespace，先不換 nameserver）

1. **打開網域。** 到 https://account.squarespace.com/domains 登入（或 account.squarespace.com › 右上角頭像 › 網域（Domains）分頁）› 在網域總覽（Domains dashboard）點 `smart-schedules.com`，進入這個網域的設定頁。下面所有 Squarespace 的路徑都從這一頁開始。
   - 你目前用 support@smart-schedules.com 登入 Squarespace。網域原本在 Google Domains 的話，Squarespace 帳號就是當初 Google Domains 用的那個 Google 帳號 email。
   - 清單裡沒有 smart-schedules.com：可能在另一個 Squarespace 帳號底下。
   - 透過 Google Workspace 買的網域：帳單和取消在 Google Admin console，DNS 和 nameserver 還是在這裡改。
2. **先確保不會被鎖在帳號外。** 你用 support@smart-schedules.com 登入 Squarespace 和 Google Cloud，而這個信箱收信靠的正是這次要搬的 MX 紀錄。只要第 1 步把 Google 的 MX 原樣搬過去，郵件就不會中斷；但萬一漏了，寄到 support@ 的登入驗證碼和重設密碼信就收不到，可能連 Squarespace 都登不進去、沒辦法把 nameserver 改回來。所以換 nameserver 之前先做：
   - **support@ 的 Google 帳號：** https://myaccount.google.com › 安全性（Security）› 加上復原電話（Recovery phone）和復原電子郵件（Recovery email，填私人信箱 `example@gmail.com`，不要填 support@ 自己），並把兩步驟驗證的備用碼（Backup codes）存在安全的地方。Google 帳號登入本身用密碼和兩步驟驗證，不靠收信；但 Workspace 的超級管理員（super admin）能不能自己用「忘記密碼」復原，要看 Admin console › 安全性（Security）› 驗證（Authentication）› 帳戶復原（Account recovery）› 超級管理員帳戶復原（Super admin account recovery）有沒有開（請在畫面上確認）。Google Cloud 也是用這個帳號登入，一起受到保護。
   - **Squarespace：** 打開兩步驟驗證（用驗證器 App，不要只靠 email）並存好備用碼，這樣登入不需要收信。再考慮加一個用私人信箱的備用登入方式：把 Squarespace 帳號的登入 email 改成私人信箱，或用私人信箱的另一個 Squarespace 帳號接受這個網域的管理權限邀請（選項名稱請在畫面上確認）。你是用「用 Google 繼續」（Continue with Google）登入 Squarespace 的話，登入靠的是 Google 帳號，不靠收信。
   - **Cloudflare：** 帳號 email 如果也是 support@，同樣打開兩步驟驗證並存好備用碼。
3. **有沒有連著 Squarespace 網站。** 網域設定頁 › 網站（Website）：顯示連到某個 Squarespace 網站，或可以選變更連線（Change connection），就是有連著；DNS › DNS 設定（DNS Settings）裡有「Squarespace Defaults」區塊也是。換 nameserver 後這個連線會自動中斷，那個網站在 smart-schedules.com 打不開（內建的 `*.squarespace.com` 網址還能用）。網站本來就在 www（Pages）上，根網域改由第 5 步轉到 www。不需要先手動停放（Park this domain）。**那個 Squarespace 網站還要用的話，先停下來想清楚。** [§3.3](#33-在-squarespace-加一筆-cnamewww--pagesdev) 已經刪掉 Squarespace Defaults 的話，這一項不用管。
4. **郵件：Google Workspace（已確認在用）。** Google Admin console（https://admin.google.com）顯示 smart-schedules.com 是 Workspace 的主要網域、已驗證，郵件設定狀態「All OK」，表示 Squarespace 的 DNS 裡已經有指向 Google 的 MX。所以這次要**保留所有 Google 的郵件紀錄**（下一項列出），**不用 Cloudflare Email Routing**。另外查兩件事：
   - **Workspace 的帳單在哪裡。** 網域設定頁 › 電子郵件（Email）› 管理方案（Manage plan）列出使用者，或 帳單（Billing）› 訂閱項目（Subscriptions）有 Google Workspace，就是透過 Squarespace 付費；都沒有就是直接付給 Google（Admin console › 帳單（Billing））。換 nameserver 不影響帳單，但第 8 步移轉註冊前要知道（請在畫面上確認）。
   - **有沒有 Squarespace 郵件轉寄（Mailgun）。** 同一頁往下的郵件轉寄（Email Forwarding）有沒有規則，以及 DNS 設定裡有沒有指向 `mxa.mailgun.org`、`mxb.mailgun.org` 的 MX（Google Domains 的轉寄規則搬到 Squarespace 後會變成這樣）。有的話，Mailgun 的紀錄**不要搬**：Workspace 收信用不到它們，和 Google 的 MX 並存反而可能讓部分信件跑到 Mailgun。規則裡如果有還需要的地址（例如 `info@` 要收進 support@），改在 Workspace 加成 support@ 的別名：Admin console › 目錄（Directory）› 使用者（Users）› support@ › 使用者資訊（User information）› 替代電子郵件地址（Alternate email addresses (email aliases)）（請在畫面上確認）。Squarespace 的轉寄規則等第 3 步確認郵件正常後再刪。
5. **抄下所有 DNS 紀錄。** DNS › DNS 設定（DNS Settings）。頁面分好幾個區塊：Squarespace Defaults（如果還在）、預設組合（preset，例如 Google Workspace）、郵件轉寄自動加的紀錄、網域轉址（[§3.5](#35選做根網域-smart-schedulescom-轉到-www)）自動加的紀錄、第三方服務透過 Domain Connect 自動加的唯讀區塊（如果有）、自訂紀錄（Custom Records）。Squarespace **沒有匯出（Export）功能**，而且換 nameserver 後這些紀錄全部失效，所以：
   1. 每個區塊都截圖。
   2. 逐筆抄下 Host（主機）、Type（類型）、Priority（優先順序）、Data（值）。
   3. 第 1 步拿來和 Cloudflare 掃描匯入的結果逐筆比對。
   - **Google 的郵件紀錄（全部原樣搬，值和優先順序一個字都不要改）：** 通常在「Google Workspace」預設組合或自訂紀錄裡。另外列成一張清單，第 1、3 步會用到。
     - `@` 的 **MX**：新式是一筆 `smtp.google.com`、優先順序 1；舊式是五筆 `aspmx.l.google.com`（1）、`alt1.aspmx.l.google.com`（5）、`alt2.aspmx.l.google.com`（5）、`alt3.aspmx.l.google.com`（10）、`alt4.aspmx.l.google.com`（10）。**Squarespace 顯示哪一種就照抄哪一種**：Google 兩種都支援，搬家時不要順便改，也不要混用。
     - `@` 的 **SPF** TXT：`v=spf1 include:_spf.google.com ~all`。整個網域只能有一筆 `v=spf1`。裡面如果還有 `include:mailgun.org`（Squarespace 郵件轉寄加的），搬的時候拿掉那一段；沒有 SPF 的話，第 4 步再加。
     - **DKIM** TXT（[§3.6](#36-google-workspace-郵件dkim-和-dmarc加在-squarespace) 做過就有）：主機 `google._domainkey`，值是 `v=DKIM1; k=rsa; p=…` 開頭的一長串。
     - **DMARC** TXT（§3.6 做過就有）：主機 `_dmarc`，值是 `v=DMARC1;` 開頭。
     - **每一筆** `google-site-verification=…` TXT（可能不只一筆，Workspace、Search Console 等各自加的）。Workspace 的網域靠它維持已驗證。
     - 指向 `*.googlehosted.com` 的 CNAME（例如指向 `ghs.googlehosted.com` 的自訂網址，或 Google 驗證用的紀錄；從 Google Domains 搬來的網域，Squarespace 可能自動加過一筆）。主機是 `@` 或 `www` 的例外，不要搬（見下面）。
   - **網站要搬：** `www` 的 CNAME → `<專案>.pages.dev`（§3.3 加的）。
   - **其他要搬：** 你自己加的其他紀錄（例如別的子網域、§3.3 第 5 步加的 CAA）。
   - **不要搬：** Squarespace Defaults（如果還在；連 Squarespace 網站用的 `@` A 紀錄和 `www` CNAME，根網域改由第 5 步轉到 www）；§3.5 的網域轉址規則和它自動加的紀錄（換 nameserver 後轉址就停了，由第 5 步取代）；郵件轉寄區塊和 Mailgun 的紀錄（`mxa.mailgun.org`、`mxb.mailgun.org` 的 MX，以及只為 Mailgun 加的 SPF）。
   - 網路上有第三方 Chrome 擴充功能「Squarespace DNS Exporter」可以匯出，但它不是官方工具，隱私沒有經過驗證，不建議使用。
6. **關掉 DNSSEC（一定要在換 nameserver 之前）。** 網域設定頁 › DNS › DNSSEC › 關掉「DNS 安全性擴充」開關（DNS Security Extensions）› 在跳出的確認視窗按確認（Confirm）。Squarespace 說這會把 DNSSEC 資訊從註冊局移除，要 24～48 小時才會更新。
   - Squarespace 管理的 .com 網域預設會自動開 DNSSEC（smart-schedules.com 目前就是開著、有簽章的）。
   - 看不到開關：刪掉 DNSSEC 面板裡 DS 紀錄（DS records）底下的每一筆，效果一樣。兩個都看不到、下面的檢查卻還有輸出，聯絡 Squarespace 客服。
   - 為什麼要先關：舊的 DS 還在快取裡就換 nameserver，會驗證失敗（SERVFAIL），整個網域連不上（網站和郵件都會受影響），或一直卡在 Pending。Squarespace 換 nameserver 的流程雖然也會順便關 DNSSEC，但不會等舊的快取過期。
   - **只有這個附錄要關 DNSSEC。** DNS 留在 Squarespace 的 1.0 做法（§3）完全不用動它。
7. **WHOIS 隱私保持開著。** 網域設定頁 › WHOIS 隱私（Whois Privacy）開關。Squarespace 管理的網域大多免費附送、預設開啟；關掉等於同意把聯絡資料公開。

**成功時會看到：** support@ 的 Google 帳號有復原電話、復原電子郵件和備用碼，Squarespace 有不靠 support@ 收信也能登入的方式；截圖和紀錄清單都有了，Google 的郵件紀錄另外列好；DNSSEC 開關是關的；過了 24～48 小時後，`dig DS smart-schedules.com +short` 沒有任何輸出（或 https://dnsviz.net 顯示沒有 DS）。剛關掉時還有輸出是正常的。

**要多久：** 兩段等待。(1) Squarespace 把 DS 從註冊局移除要 24～48 小時；(2) 移除後，各地 DNS 伺服器快取裡的舊 DS 最多還會留 24 小時（.com DS 紀錄的 TTL；Cloudflare 的說法是通常 24～48 小時）。所以等到 `dig DS smart-schedules.com +short` **第一次**沒有輸出（或 dnsviz 顯示沒有 DS）之後，**再多等 24 小時**，才做第 2 步。記下第一次沒有輸出的時間。關掉之前 `dig DS` 就已經沒有輸出的話（本來就沒開 DNSSEC），不用等。等的時候可以先做第 1 步。

### 1. 在 Cloudflare 加入網域

1. 用建立 Pages 專案、跑著 `smart-schedule-worker` 的帳號登入 Cloudflare › 左側網域（Domains）› 加入網域（Onboard a domain）› 輸入 `smart-schedules.com`（不要加 `www`）› 加入 DNS 紀錄的方式選快速掃描（quick scan）› 繼續（Continue）› 方案選 **Free** › 檢查匯入的紀錄（review DNS records）› 繼續到啟用（Continue to activation）。
2. 最後一頁會顯示 Cloudflare 指派的**兩個 nameserver**（像 `xxxx.ns.cloudflare.com`）。之後也可以在這個網域的總覽（Overview）頁，或 DNS › Records 頁的「Cloudflare nameservers」卡片找到。**從畫面複製貼上，不要手打**（打成 `cloudlfare`、`cloudfare` 是卡在 Pending 最常見的原因）。每個網域指派的可能不同，不能沿用別的網域的。
3. 這個網域 › DNS › Records（DNS 紀錄）：和第 0 步的清單逐筆比對。快速掃描通常抓得到 `@` 的 MX 和 TXT，但可能漏掉子網域、DKIM（`google._domainkey`）和 DMARC（`_dmarc`），漏掉的用 Add record 補上。然後：
   - **保留 Google 的郵件紀錄，而且要和第 0 步的清單完全一樣：** MX 的郵件伺服器（Mail server）和優先順序（Priority）、唯一一筆 SPF、DKIM、DMARC（原本有的話）、每一筆 `google-site-verification`、指向 `*.googlehosted.com` 的 CNAME。MX 和 TXT 一律是 DNS only（Cloudflare 不會代理郵件），不用另外設定；`*.googlehosted.com` 的 CNAME 要把 Proxy status 切成 **DNS only**（灰色雲朵）（請在畫面上確認）。補 DKIM 時 Name 填 `google._domainkey`，Content 整段貼上。
   - **保留網站的 `www` CNAME：** Name `www`、Target `<專案>.pages.dev`（和 Squarespace 上的一樣）。掃描沒抓到就用 Add record 補上。Proxy status 先照匯入的樣子，第 5 步再確認（請在畫面上確認）。
   - **這些 Google 紀錄和 `www` CNAME 一定要在第 2 步之前就在 Cloudflare 上。** 一換 nameserver，只有 Cloudflare 上的紀錄算數，漏掉 MX 的話 support@ 會馬上收不到信，漏掉 `www` 的話網站會打不開。
   - **刪掉** `@`（根網域）的 **A、AAAA、CNAME** 紀錄（Squarespace 的，例如 `198.185.159.x`、`198.49.23.x`，以畫面為準）和指向 Squarespace 的 `www` CNAME（例如 `ext-cust.squarespace.com`，§3.3 沒刪乾淨時才會有）。根網域要給第 5 步的轉址。這幾筆也可以等 Active 之後再刪，但一定要在第 5 步之前刪掉。
   - **刪掉** Mailgun 的 MX（`mxa.mailgun.org`、`mxb.mailgun.org`）和只為 Mailgun 加的 SPF。SPF（`v=spf1` 開頭的 TXT）整個網域只能有一筆，就是 Google 那一筆。
   - **不要開 Email Routing。** Cloudflare 可能在 Email 或 DNS 頁面建議開啟 Email Routing，或建議加「防止冒名寄信」的紀錄（例如 `v=spf1 -all`、`p=reject` 的 DMARC）。那是給不寄信的網域用的，**都不要接受**，否則 support@ 收不到信或寄出的信被拒（請在畫面上確認）。

**成功時會看到：** Cloudflare 的網域（Domains）清單裡有 smart-schedules.com，狀態是「Pending Nameserver Update」（還沒換 nameserver 時本來就是這樣）；你手上有那兩個 nameserver；DNS Records 裡 Google 的 MX（值和優先順序）、唯一一筆 SPF、DKIM／DMARC（原本有的話）、所有 `google-site-verification` 和 `www` → `<專案>.pages.dev` 都在，`@` 沒有 A／AAAA／CNAME，也沒有 Mailgun 的 MX。

**要多久：** 這一步不用等。但 Free 方案的網域停在 Pending 超過 28 天會被自動刪除，所以加入後一個月內要做完第 2 步。

### 2. 在 Squarespace 換成 Cloudflare 的 nameserver

**先確認：** `dig DS smart-schedules.com +short` 沒有輸出，而且從**第一次**沒有輸出算起已經過了至少 24 小時（見第 0 步的「要多久」）；第 1 步的 Google 郵件紀錄和 `www` CNAME 都已經在 Cloudflare 的 DNS Records 裡；第 0 步的帳號備援（復原電話和 email、備用碼）已經弄好。

1. 網域設定頁 › DNS › 網域 Nameserver（Domain Nameservers）› 使用自訂 nameserver（Use Custom Nameservers）› 輸入 Squarespace 密碼或兩步驟驗證碼（2FA）› 出現停用 DNSSEC 的提示時確認（confirm disabling DNSSEC）› 在 Nameserver 1 和 Nameserver 2 各貼上一個 Cloudflare 給的 nameserver › 儲存（Save）。
   - 只填 Cloudflare 那兩個，字要完全一樣，不要留 Squarespace 或其他家的（Squarespace 規定最少 2 個、最多 13 個）。
   - Squarespace 會警告網域會和 Squarespace 網站斷開、DNS 設定裡的紀錄不再生效。這是預期的。
   - 網域有進行中的移轉（pending domain transfer）時這一頁不能改。
   - 要改回原狀：同一頁選使用 Squarespace nameserver（Use Squarespace nameservers）› 儲存，再依提示按查看 DNSSEC（View DNSSEC）把開關打開。
2. **換完之後，Squarespace 這邊會停掉的：** DNS 設定裡的所有紀錄（之後只有 Cloudflare 上的紀錄算數）；和 Squarespace 網站的連線；Squarespace 郵件轉寄（如果有；郵件頁會出現「需要處理」（Action required）橫幅）；Squarespace 或 Google Domains 的網域轉址（domain forwarding，包括 §3.5 的根網域轉址）；PayPal Payment Links；Squarespace 這邊的 DNSSEC。
   - **Google Workspace 收發信不會停**，前提是第 1 步已經把 Google 的郵件紀錄都放到 Cloudflare。Squarespace 的電子郵件（Email）頁之後可能顯示 DNS 紀錄有問題的提示，以 Google Admin console 和第 3 步的檢查為準（請在畫面上確認）。
   - **www 的網站不會停**，前提是第 1 步已經把 `www` CNAME 放到 Cloudflare。
3. **還留在 Squarespace 的：** 網域註冊本身、續約和帳單、WHOIS 隱私、網域鎖定（Domain Lock）、註冊資訊（Registration Information），以及透過 Squarespace 買的 Google Workspace 訂閱和帳單（如果是）。**換 nameserver 不等於移轉註冊。自動續約要保持開著，不要取消 Squarespace 的網域訂閱，否則網域會過期。**

**成功時會看到：** 網域 Nameserver（Domain Nameservers）那一區顯示的是 Cloudflare 的兩個 nameserver（請在畫面上確認）。

**要多久：** 存檔就好；生效要等第 3 步。

### 3. 等 Cloudflare 顯示 Active

1. 不用做什麼，等就好。想快一點：Cloudflare › 這個網域的總覽（Overview）頁 › 重新檢查 nameserver（re-check nameservers，按鈕名稱請在畫面上確認）。有次數限制，按了也可能要幾分鐘到幾小時。
2. 自己檢查：`dig ns smart-schedules.com @1.1.1.1`（或 `@8.8.8.8`），或到 https://www.whatsmydns.net/ 查 `NS`。看到的是 Cloudflare 那兩個 nameserver，就是換好了。
3. Active 之後回 Squarespace › DNS › DNSSEC，確認沒有殘留的 DS 紀錄，有就刪掉。
4. **馬上確認郵件正常。**
   1. 查 DNS。MX 要和第 0 步的清單一樣，不能有 `mailgun.org` 或 `mx.cloudflare.net`；TXT 只能有一筆 `v=spf1`：

      ```sh
      dig MX smart-schedules.com +short @1.1.1.1                      # 1 smtp.google.com.（或舊式的五筆 aspmx）
      dig TXT smart-schedules.com +short @1.1.1.1                     # "v=spf1 include:_spf.google.com ~all" 和所有 google-site-verification
      dig TXT google._domainkey.smart-schedules.com +short @1.1.1.1   # 原本有 DKIM 時
      dig TXT _dmarc.smart-schedules.com +short @1.1.1.1              # 原本有 DMARC 時
      ```

   2. 網頁檢查：Google Admin Toolbox 的 Check MX（https://toolbox.googleapps.com/apps/checkmx/）› 輸入 `smart-schedules.com` › 執行檢查（按鈕名稱請在畫面上確認）。MX 和 SPF 應該沒問題；還沒做 DKIM、DMARC 的話，那兩項的警告是正常的（第 4 步處理）。
   3. **收發測試。** 從**另一個**信箱（例如 `example@gmail.com`）寄一封信到 support@smart-schedules.com › 用 support@ 登入 Gmail（https://mail.google.com）看到這封信 › 直接按回覆（Reply）› 那個信箱收到寄件人是 support@smart-schedules.com 的回信。不要用 support@ 寄給自己測試，那封信只會出現在寄件備份。
   4. Google Admin console › 帳戶（Account）› 網域（Domains）› 管理網域（Manage domains）：smart-schedules.com 仍然是已驗證（Verified），郵件設定狀態仍然是「All OK」（請在畫面上確認；Google 重新檢查可能要一點時間）。
   5. 第 0 步查到 Squarespace 郵件轉寄規則的話，現在刪掉：Squarespace 網域設定頁 › 電子郵件（Email）› 郵件轉寄（Email Forwarding）› 每條規則旁的垃圾桶圖示（要重新驗證身分）。刪掉最後一條時，Squarespace 自動加的轉寄紀錄也會一起移除。
   - 任何一項不對，看[搬 DNS 的疑難排解](#搬-dns-的疑難排解)的「support@ 收不到信或寄不出去」。
5. **確認網站還在。** `curl -sI https://www.smart-schedules.com/privacy` 回 `200`。不是的話看[搬 DNS 的疑難排解](#搬-dns-的疑難排解)的「網站打不開」。

**成功時會看到：** 收到 Cloudflare 的通知 email；Cloudflare › 網域（Domains）頁上 smart-schedules.com 的狀態從「Pending Nameserver Update」變成 **Active**；`dig MX` 是 Google 的 MX；測試信收得到、回信寄得出去；Admin console 仍然顯示 Verified 和 All OK；www 的網站正常。

**要多久：** Cloudflare 說通常最多 24 小時；Squarespace 說最多 48 小時才完全生效（有些文章寫 24～72 小時）。一直 Pending 請看下面的[搬 DNS 的疑難排解](#搬-dns-的疑難排解)。

### 4. 完成 Google 的郵件設定：DKIM 和 DMARC（不用 Email Routing）

support@smart-schedules.com 是 Google Workspace 的信箱：寄來的信由第 1 步保留的 Google MX 直接送進 Workspace 的 Gmail；**回信也直接在 Workspace 的 Gmail 按回覆**（用 support@ 登入 https://mail.google.com），寄件人就是 support@smart-schedules.com，不需要「以這個地址寄送郵件」（Send mail as）、SMTP 或應用程式密碼。收發是否正常已經在第 3 步檢查過。

**照 [§3.6](#36-google-workspace-郵件dkim-和-dmarc加在-squarespace) 在 Squarespace 做完 DKIM 和 DMARC 的話，第 1 步已經把那兩筆搬過來，這一步只要確認**：Admin console 的驗證電子郵件（Authenticate email）頁仍然顯示 DKIM 正在驗證，第 3 步的 `dig` 查得到 `google._domainkey` 和 `_dmarc`。還沒做的話照下面做；紀錄要加在 Cloudflare（加在 Squarespace 的換完 nameserver 就失效），而且**一定要等第 3 步 Active、郵件檢查都正常之後再做**，因為 Google 開始驗證時查的是公開的 DNS。也可以直接點 Admin console 首頁橫幅上的 Complete email setup 跟著畫面做，畫面要你加的 DNS 紀錄一樣加在 Cloudflare（請在畫面上確認）。

DKIM 加好紀錄後最多要等 48 小時才開始驗證。等的時候可以先做第 5 步，之後再回來按開始驗證、加 DMARC。

1. **SPF 確認只有一筆。** Cloudflare › 這個網域 › DNS › Records：`@` 只有一筆 `v=spf1` 開頭的 TXT，內容是 `v=spf1 include:_spf.google.com ~all`。沒有的話 Add record：Type `TXT`、Name `@`、Content 貼上這一行 › Save。有兩筆就合併成一筆。
2. **DKIM：產生金鑰。** 用超級管理員（super admin）登入 Google Admin console（https://admin.google.com）› 選單 › 應用程式（Apps）› Google Workspace › Gmail › 驗證電子郵件（Authenticate email）› 選 `smart-schedules.com`：
   - 頁面上方已經顯示 DKIM 正在驗證（Authenticating email with DKIM）：DKIM 已經完成，直接做第 5 項（DMARC）。
   - 第 1 步已經從 Squarespace 搬了 `google._domainkey`，而且這頁顯示的 TXT 記錄值（TXT record value）和 Cloudflare 上的一樣：**不要按產生新記錄**（會換掉金鑰），直接做第 4 項。
   - 否則按產生新記錄（Generate new record）› DKIM 金鑰長度（key bit length）選 2048 › 前置字串選取器（Prefix selector）保留預設的 `google` › 產生（Generate）。畫面會顯示 DNS 主機名稱（DNS Host name，`google._domainkey`）和 TXT 記錄值（`v=DKIM1; k=rsa; p=…`）。
3. **DKIM：加到 Cloudflare。** Cloudflare › 這個網域 › DNS › Records › Add record：Type `TXT`、Name `google._domainkey`、Content 整段貼上 TXT 記錄值（不要自己加引號或拆段；超過 255 字元時 Cloudflare 會自己處理，請在畫面上確認）› Save。已經有一筆 `google._domainkey` 的話，編輯（Edit）那一筆，不要再加第二筆。
4. **DKIM：開始驗證。** 回到 Admin console 的驗證電子郵件（Authenticate email）頁 › 開始驗證（Start authentication）。Google 說加入金鑰後最多 48 小時才會生效，這段期間頁面可能一直提示要更新 DNS 紀錄；確定紀錄加對了，就過一陣子再按。
5. **DMARC（DKIM 開始驗證之後）。** Cloudflare › 這個網域 › DNS › Records › Add record：Type `TXT`、Name `_dmarc`、Content 填下面這一行 › Save。

   ```
   v=DMARC1; p=none; rua=mailto:support@smart-schedules.com
   ```

   - 整個網域只能有一筆 `_dmarc`。第 1 步已經搬來一筆的話，不要加第二筆：編輯那一筆，保留原本的 `p=`（不要改得更寬鬆），只把 `rua=mailto:support@smart-schedules.com` 放進去。
   - `p=none` 只監看、不影響投遞。各家信箱會把彙總報告（XML 附件）寄到 support@，可以用 Gmail 篩選器自動加標籤或封存。
   - 看了幾週報告、確認自己寄的信 SPF 和 DKIM 都通過之後，才考慮改成 `p=quarantine`。

**成功時會看到：** Admin console 的驗證電子郵件（Authenticate email）頁上方顯示 DKIM 正在驗證（Authenticating email with DKIM）；Check MX（https://toolbox.googleapps.com/apps/checkmx/）不再警告 DKIM 和 DMARC；從 support@ 寄一封信到另一個信箱，在那邊的顯示原始郵件（Show original）看到 SPF、DKIM、DMARC 都是 `PASS`；Admin console 首頁的「Complete email setup」橫幅不見了（請在畫面上確認）。

**要多久：** DNS 通常幾分鐘就生效；DKIM 最多 48 小時才開始驗證；DMARC 報告大約一天一份。

**Google 的郵件紀錄一直保留，不要開 Email Routing。** 只要還在用 Google Workspace，Cloudflare 上 Google 的 MX、SPF、DKIM、DMARC 和 `google-site-verification` 就都不要刪，也不要接受 Cloudflare 開啟 Email Routing 的建議（它會換掉 MX）。之後真的要取消 Workspace，先停下來重新規劃，不要只改 DNS：support@ 的 Google 帳號會跟著消失，而 Squarespace、Google Cloud 專案、OAuth 的聯絡信箱和 Search Console 都掛在它上面，要先把這些登入和擁有者換到之後還會存在的帳號，決定新的收信方式，並改寫政策第 9、12、13、17 節（中英文）。

### 5. 確認網站，根網域轉到 www

**前提：** 第 3 步已經 Active、郵件和網站檢查都正常；第 1 步說的 `@` 的 A／AAAA／CNAME 已經刪掉。網站不用重新部署。

1. **確認 Pages 的自訂網域。** Workers & Pages › `smart-schedules-site` › 自訂網域（Custom domains）：`www.smart-schedules.com` 仍然是 Active（請在畫面上確認）。不是 Active，或 www 出現錯誤：在那一列的選單移除這個網域（Remove domain），再用設定網域（Set up a domain）加回 `www.smart-schedules.com`；網域現在在同一個帳號的 Cloudflare 上，Cloudflare 會自己建立（或請你確認）`www` 的 CNAME，不用再手動加（請在畫面上確認）。
2. **打開 HTTPS 強制轉址。** 這個網域 › SSL/TLS › 總覽（Overview）：確認加密模式（encryption mode）不是 Off（Off 時看不到下一個選項）› SSL/TLS › 邊緣憑證（Edge Certificates）› 打開 **Always Use HTTPS**。Free 方案就有。HSTS 等網站確定正常後再考慮，不急。
3. **根網域轉到 www。**
   1. DNS › Records › Add record：Type `A`、Name `@`、IPv4 address `192.0.2.0`、**Proxied**（橘色雲朵）› Save。這只是佔位紀錄，沒有真的伺服器；Redirect Rule 需要一筆 proxied 紀錄，請求不會真的送到這個位址。
   2. 規則（Rules）› 建立規則（Create rule）› **Redirect Rule**（可用範本「Redirect from root to WWW」，請在畫面上確認）：
      - 比對：Wildcard，Request URL `https://smart-schedules.com/*`
      - 目標：`https://www.smart-schedules.com/${1}`
      - 狀態碼 301，保留 query string。
   - 另一個做法：把 `smart-schedules.com` 也加成 Pages 的自訂網域（網域在 Cloudflare 上之後就可以），兩個網址都提供網站；但正式網址只有 www，所以用轉址比較單純。

**成功時會看到：**

```sh
curl -sI https://www.smart-schedules.com/              # 200
curl -sI https://www.smart-schedules.com/privacy       # 200 text/html
curl -sI https://smart-schedules.com/support           # 301 -> https://www.smart-schedules.com/support
curl -sI http://smart-schedules.com/                   # 301（http -> https，再轉到 www）
```

**要多久：** 規則存檔後幾分鐘內生效。

### 6. Google Search Console 驗證（DNS 在 Cloudflare 時）

[§3.7](#37-google-search-console-驗證) 已經驗證過的話，第 1 步把所有 `google-site-verification` TXT 搬過來，就不用再做什麼。還沒驗證時：

1. **用 Workspace 帳號登入，先看是不是已經驗證了。** 用 support@smart-schedules.com 登入 https://search.google.com/search-console 。資源清單裡已經有 `smart-schedules.com` 網域資源而且打得開，就完成了（它要是 Cloud 專案的 Owner 或 Editor）。
2. 還沒有的話：新增資源（Add property）› 選左邊的 **網域（Domain）** › 輸入 `smart-schedules.com`（不加 `https://` 或 `www`）› 繼續（Continue）。DNS 裡如果有這個帳號驗證 Workspace 時加的 `google-site-verification` TXT（第 1 步保留的），Search Console 可能直接顯示已驗證，或按驗證（Verify）就通過（請在畫面上確認）。
3. **自動方式（沒有直接通過、而且有出現才用）：** Cloudflare 已經 Active 時，Search Console 通常會認出 DNS 在 Cloudflare，顯示開始驗證（Start verification）› 新分頁登入 Cloudflare（同一個帳號）› 授權（Authorize）› Cloudflare 自動加一筆 TXT › 回到 Search Console。這個流程只有第三方指南的說法（請在畫面上確認）。
4. **手動方式（沒有那個按鈕或自動失敗時）：** 下拉選單選任何 DNS 供應商（Any DNS provider），記錄類型選 TXT，複製 `google-site-verification=…` › Cloudflare › 這個網域 › DNS › Records › Add record：Type `TXT`、Name `@`、Content 貼上 › Save（TXT 一律是 DNS only，不會 proxied）› 回 Search Console 按驗證（Verify）。這是**新加一筆**，不要覆蓋 Workspace 原本那筆 `google-site-verification`；同一個網域可以有好幾筆。
5. **要加在 Cloudflare，不是 Squarespace。** 換 nameserver 後，加在 Squarespace 的紀錄不會生效。
6. **所有 `google-site-verification` TXT 都要永久保留**，刪掉會失去 Search Console 或 Workspace 的驗證。它們可以和 Google 的 SPF TXT 並存；只能有一筆的是 SPF（`v=spf1`）紀錄。

**成功時會看到：** Search Console 顯示擁有權已驗證，資源清單裡有 `smart-schedules.com`（請在畫面上確認）。

**要多久：** 已經驗證或自動方式幾分鐘。手動方式 DNS 生效可能要幾分鐘到幾小時，失敗就過幾分鐘再按驗證，**不要改紀錄**。

### 7.（選做）在 Cloudflare 重新開 DNSSEC

這個專案沒有任何地方需要 DNSSEC，不做也不影響網站、Google Workspace 郵件或 Google 驗證。要做的話，等網站和 email 都正常後再做。很快就要做第 8 步的話可以先跳過：移出 Squarespace 前要先把這裡加的 DS 紀錄刪掉（移轉進行中不能改 DNSSEC），轉到 Cloudflare Registrar 後 Cloudflare 會自動處理 DNSSEC。

1. **先確認 Squarespace 能加 DS 紀錄。** Squarespace 的新增 DS 紀錄只適用「註冊商是 Squarespace Domains, LLC、而且用自訂 nameserver」的網域。smart-schedules.com 的註冊商是 Squarespace Domains II LLC，不是 Squarespace Domains, LLC（可在 https://lookup.icann.org/ 查 Registrar 欄位確認），所以可能不能加（請在畫面上確認）。Squarespace 網域設定頁 › DNS › DNSSEC 看不到新增紀錄（Add record）的話，就不要開。
2. Cloudflare › 這個網域 › DNS › Settings › DNSSEC › Enable DNSSEC。對話框會列出 Key Tag、Algorithm（13）、Digest Type（2，SHA-256）和 Digest。關掉對話框後，可以在 DNSSEC 卡片點 DS record 再看。
3. Squarespace 網域設定頁 › DNS › DNSSEC › 新增紀錄（Add record）› 輸入密碼或兩步驟驗證碼 › 填 Key tag、Algorithm（13，ECDSA Curve P-256 with SHA-256）、Digest type（2，SHA-256）、Digest › 儲存（Save）。

**成功時會看到：** https://dnsviz.net 或 https://dnssec-debugger.verisignlabs.com/ 檢查沒有錯誤；Cloudflare 的 DNSSEC 卡片顯示已生效。

**要多久：** 研究時沒查到確切時間（請在畫面上確認）。

### 8.（選做，之後再做）把註冊轉到 Cloudflare Registrar

不急：DNS 已經在 Cloudflare 了，這一步只是把續約和帳單也搬過去。

**開始前要符合：**
- 網域在 Cloudflare 是 Active 的完整設定（full setup），否則 Cloudflare 不讓你輸入移轉碼。
- 不在 60 天鎖定期內：新註冊、移入 Squarespace、或改過註冊人姓名／組織／email 之後 60 天內不能移出。smart-schedules.com 是 2026-10-14 註冊的，**2026-12-13 之前不能移出**（以 Squarespace 畫面顯示的日期為準）。換 nameserver 和關 DNSSEC 不會觸發 60 天鎖定。
- 剛在 Squarespace 續約的話，至少等 45 天，否則移轉加的那一年不算，等於同一年付兩次。
- Cloudflare 帳號的 email 已驗證，而且設定了付款方式。
- 網域是透過 Google Workspace 購買的（Squarespace 是經銷商），Workspace 的帳單也可能在 Squarespace（第 0 步查到的）。移轉前先確認網域移出 Squarespace 後 Workspace 訂閱和帳單會怎麼處理，需要的話先把帳單改成直接付給 Google（請在畫面上確認）。DNS（包括 Google 的郵件紀錄）已經在 Cloudflare，移轉註冊本身不影響收信。
- Squarespace 上沒有 DS 紀錄（Squarespace 說移轉進行中不能開關 DNSSEC，所以要在申請移轉碼之前弄好）。做過第 7 步的話，先到 Squarespace › DNS › DNSSEC 刪掉 DS 紀錄，**但 Cloudflare 那邊的 DNSSEC 不要關**：DS 還在註冊局或快取裡時先關掉 Cloudflare 的簽章，整個網域會 SERVFAIL。轉進 Cloudflare Registrar 後，Cloudflare 會自動重新加上 DS。

**Squarespace 端：**
1. 網域設定頁 › 註冊資訊（Registration Information）：確認 email 是你現在收得到的，移轉碼會寄到那裡。要改姓名、組織或 email 時，勾選不要啟動 60 天移轉鎖定（Don't initiate 60-day transfer lock）。
2. 網域設定頁 › 關掉網域鎖定（Domain Lock）開關。看到無法解除鎖定（Can't unlock domain）代表某個 60 天鎖定還沒過；找不到開關就直接做下一步。之後移轉還是因為鎖定失敗，Squarespace 建議把開關先開再關一次。
3. 申請移轉碼（Request transfer code）› 輸入密碼或 2FA › 確認。24 小時內會收到 no-reply@squarespace.com 寄來、主旨「Auth code for smart-schedules.com」的信。**只申請一次**：重複申請會產生好幾組，只有最新的一組有效。移轉碼會過期（.com 的有效天數官方沒寫清楚），所以要轉的時候才申請、收到就用。

**Cloudflare 端：**
4. Cloudflare › 網域註冊（Domain Registration）› 移轉網域（Transfer Domains）（https://dash.cloudflare.com/?to=/:account/registrar/transfer）› 選 smart-schedules.com › 貼上移轉碼 › 確認價格 › 填註冊人聯絡資料（Cloudflare 預設會在公開 WHOIS 遮蔽，但資料必須正確）› 確認付款。輸入移轉碼並確認時才扣款。**交出移轉碼後就不能取消。**
   - 價格：.com 移轉會從原到期日起多續一年，照 Cloudflare 的成本價。第三方比價網列約 US$10.46／年，以結帳頁為準。
   - Squarespace 收不收移出費：官方頁面沒找到；2022 年有第三方文章寫 US$20，沒有證實（請在畫面上確認）。
5. Squarespace 可能寄信請你確認，在信裡或 Squarespace 面板主動核准可以加快。
6. 移轉進行中時 Squarespace 不能改 DNS 或 nameserver，所以 DNS 要在開始移轉前弄好。

**成功時會看到：** Cloudflare 的移轉網域（Transfer Domains）頁顯示進度，完成時收到 Cloudflare 的 email。

**要多久：** 原註冊商最多可以等 5 天才放行（你核准就立刻放行）；Squarespace 寫整個移轉最多 15 天。轉入後：60 天內不能再轉出；網域必須一直用 Cloudflare 的 nameserver；DNSSEC 由 Cloudflare 自動處理，約 1～2 天。

### 搬 DNS 的疑難排解

**網站打不開**
- 還不是 Active：看第 3 步。一直 Pending 時依序檢查：Squarespace 有沒有真的存檔；nameserver 和 Cloudflare 畫面上的是否完全一樣（`cloudlfare` 這類拼錯）；有沒有多留 Squarespace 或別家的 nameserver；`dig DS smart-schedules.com +short` 是不是還有輸出（殘留的 DS，到 Squarespace › DNS › DNSSEC 刪掉）。Free 方案停在 Pending 超過 28 天會被自動刪除。
- 出現 SERVFAIL 或整個網域連不上：多半是舊的 DS 還在。到 Squarespace › DNS › DNSSEC 刪掉 DS 紀錄，再等至少 24 小時。
- `www.smart-schedules.com` 打不開或出現 522：Cloudflare 的 DNS › Records 沒有 `www` → `<專案>.pages.dev` 的 CNAME（第 1 步漏搬），或 Pages 的自訂網域變成不是 Active。補上紀錄，或照第 5 步第 1 項在 Pages 移除再加回 `www.smart-schedules.com`。
- `smart-schedules.com` 沒有轉到 www：第 5 步的 `@` A 紀錄要是 Proxied，Redirect Rule 的比對網址要是 `https://smart-schedules.com/*`。`@` 還有 Squarespace 的舊 A 紀錄的話刪掉。
- `http://` 沒有轉到 `https://`：第 5 步的 Always Use HTTPS 沒開。

**support@ 收不到信或寄不出去**
- 先查 `dig MX smart-schedules.com +short @1.1.1.1`：
  - 沒有輸出，或還有 Mailgun（`mxa.mailgun.org`、`mxb.mailgun.org`）：到 Cloudflare › DNS › Records 補上第 0 步抄下的 Google MX（值和優先順序照抄），再刪掉 Google 以外的 MX（Mailgun 那幾筆）。寄件伺服器通常會重試好幾天，所以修好之後，這段期間寄來的信大多還會陸續送到。
  - 出現 `mx.cloudflare.net`：Email Routing 被打開了，要把它關掉。Cloudflare › 運算（Compute）› Email Service › Email Routing › 選 smart-schedules.com › 設定（Settings）› 停用 Email Routing（Disable Email Routing）› 確認。Cloudflare 說停用時會一併移除它加的 MX、SPF 和 DKIM（`cf2024-1._domainkey`）；這些紀錄在 DNS › Records 是鎖定（Locked）的，不能直接刪（請在畫面上確認）。然後到 DNS › Records 照第 0 步的清單補回 Google 的 MX 和唯一一筆 SPF。
- Google Admin console 說網域沒驗證，或郵件設定狀態不是 All OK：有 `google-site-verification` TXT 或 MX 沒搬到 Cloudflare，照第 0 步的截圖補上。
- 回信進了對方的垃圾郵件，或被退信說 SPF／DMARC 沒通過：`@` 要剛好一筆 `v=spf1 include:_spf.google.com ~all`（有兩筆 `v=spf1` 就合併成一筆）；完成第 4 步的 DKIM；DMARC 先用 `p=none`；也確認沒有接受 Cloudflare 建議的 `v=spf1 -all`。
- DKIM 按開始驗證（Start authentication）失敗：`dig TXT google._domainkey.smart-schedules.com +short @1.1.1.1` 沒有輸出，或和 Admin console 顯示的值不同。Name 要是 `google._domainkey`、Content 要完整、只能有一筆；剛加的話最多等 48 小時再按。
- 用 support@ 寄給 support@ 自己：只會出現在寄件備份，改用另一個信箱測試。
- 因為收不到信而登不進 Squarespace：用第 0 步準備的方式登入（驗證器 App、備用碼、私人信箱的備用登入）。support@ 的 Google 帳號（Gmail、Admin console、Google Cloud）用密碼和兩步驟驗證登入，不靠收信。修好 Cloudflare 的 MX 之後信就會恢復。

**Search Console 驗證失敗**
- TXT 加在 Squarespace：換 nameserver 後無效，要加在 Cloudflare › DNS › Records。
- 新的 TXT 覆蓋了 Workspace 原本那筆 `google-site-verification`：把原本那筆照第 0 步的截圖加回來，兩筆並存。
- Name 要填 `@`，Content 要完整貼上 `google-site-verification=…`。
- 還沒生效：過幾分鐘再按驗證（Verify），不要改紀錄。Cloudflare 還不是 Active 的話，先等第 3 步。
- 資源類型要選網域（Domain），只輸入 `smart-schedules.com`，不要加 `https://` 或 `www`。
- Search Console 驗證過了，Google 品牌驗證卻還說網域沒驗證：驗證用的 Google 帳號不是 Cloud 專案的 Owner 或 Editor，換對的帳號再驗證一次。
