# smart-schedules.com 網站

smart-schedules.com 的靜態網站：首頁、隱私權政策和支援頁。Google OAuth 驗證、App Store Connect 和 App 裡的連結都指向這裡。

部署方式是**只放靜態檔案的 Cloudflare Worker**（沒有程式碼）。Cloudflare 的控制台和 CLI 現在把它稱為「最新版的 Cloudflare Pages」，新專案也建議用 Workers 而不是傳統 Pages。它和 `server/worker` 用同一個 wrangler、同一個 Cloudflare 帳號。傳統 Pages 的做法在 [§3.9](#39-如果一定要用傳統-pages)。

## 檔案

```
site/
  wrangler.toml        設定檔，不會上傳
  .gitignore           忽略 wrangler dev 產生的 .wrangler/
  README.md            本文件，不會上傳
  public/              唯一會上傳的資料夾
    index.html         https://smart-schedules.com/          首頁（Google OAuth 的 Home page）
    privacy.html       https://smart-schedules.com/privacy   隱私權政策（App Store Connect、Google OAuth、SSPrivacyURL）
    support.html       https://smart-schedules.com/support   支援頁（App Store Connect 的 Support URL）
    404.html           找不到頁面時回 404
    _headers           安全性標頭（不會被當成頁面提供）
    robots.txt
    logo.png           120×120，由 App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png 縮小；OAuth 同意畫面的 logo 用同一張
```

- 每一頁都是繁體中文在前、英文在後，頁首有語言切換（`#zh`、`#en`，純錨點，不用 JavaScript）。審核員可以直接點「English」。
- 沒有 JavaScript、外部字型、cookie 或追蹤。CSS 直接寫在每頁的 `<style>` 裡（四頁內容相同），依 `prefers-color-scheme` 切換淺色和深色。改樣式時四頁要一起改。
- 不需要 `_redirects`。`html_handling = "auto-trailing-slash"` 會讓 `/privacy` 提供 `privacy.html`，`/privacy.html` 和 `/privacy/` 307 轉到 `/privacy`。`_redirects` 只比對路徑，不能做 www → 根網域，那要用 [§3.3](#33-www--根網域控制台免費方案) 的 Redirect Rule。
- 本機測試過（wrangler 4.146.0 的 `wrangler dev` 和 `deploy --dry-run`）：`/`、`/privacy`、`/support` 都是 200，`/privacy.html` 是 307 → `/privacy`，`/nope` 是 404（`404.html`），`/_headers` 不會被提供，`_headers` 的標頭有套用；手機寬度（375 px）沒有水平捲動，淺色和深色都正常，所有錨點都存在。

## 1. 發佈前要替換的佔位文字

所有佔位文字都包在 `<mark class="todo">…</mark>` 裡，頁面上會以黃色標示。替換時連 `<mark>` 標籤一起換掉。

| 佔位文字 | 在哪裡 | 填什麼 |
|---|---|---|
| `[開發者名稱 / Developer name]` | 三頁的頁尾；`privacy.html` 第 1 節和第 19 節（中英文各一次） | 資料控管者的法定名稱，和 Apple Developer 帳號、App Store 上的賣家名稱一致（個人就是你的法定姓名） |
| `[3]` | `support.html`「多久會回覆」（中英文各一次） | 你願意承諾的回覆工作天數 |

郵件服務已經決定是 Google Workspace（不是佔位文字）：support@smart-schedules.com 是 Workspace 的信箱，政策第 9、12、13、17 節（中英文）寫的是由 Google（Google Workspace）的 Gmail 收信、保存和回信，Google 依雲端資料處理附錄（Cloud Data Processing Addendum）作為處理者。發佈前要做的事在 [§2 第 5 項](#2-發佈前要確認的事政策內容依賴這些)。

最低年齡已經決定是 18（不是佔位文字）：政策第 16 節「最低年齡」、支援頁「AI 助理需要什麼才能運作？」和首頁都寫 18，App Store Connect 的年齡分級要設成 18+（Gemini API 條款要求使用者年滿 18 歲，也不能用在以未成年人為對象或可能被未成年人使用的 App）。

替換完後，下面這個指令應該什麼都不印：

```sh
grep -rn 'class="todo"' site/public
```

## 2. 發佈前要確認的事（政策內容依賴這些）

1. **Gemini 必須是付費層級。** 政策第 4、11、12、13 節寫「Google 不會用提示或回覆改善產品，最多保留 55 天、只用於濫用監控和法律要求的揭露」。這只有在 Gemini API 的 Google Cloud 專案連結了有效的 Cloud Billing（Paid Services）時才成立；免費層級下 Google 會用內容改善產品，也可能有人工審閱。**發佈網站或送 Google 驗證的條件是：** 新金鑰所屬的 Cloud 專案在 Google Cloud 控制台 › Billing 顯示已連結有效的帳單帳戶，而且 AI Studio 的 API 金鑰／專案頁顯示付費層級（例如 Tier 1）。`cd server/worker && npm run check-key` 通過**不算**：它只送一個請求、印出 HTTP 狀態，免費層級的金鑰也會通過。
2. **Gemini 的記錄與資料分享要關著。** 政策第 4 節寫「伺服器不保存或記錄內容」，第 11 節寫「不允許別人用來訓練模型」。有帳單的專案可以在 AI Studio 開啟 Generate Content API 的請求記錄（開發者看得到、保留最多 55 天），專案擁有者也可以選擇把記錄的資料集分享給 Google 改善模型。在 AI Studio › Logs（記錄）確認這個 Gemini 專案的記錄是關閉的，而且從不選擇和 Google 分享資料集；如果要開，先改寫政策第 4、11、13 節。README 和 docs/SETTINGS.md §16 的上架清單也要加上這一項（這個資料夾以外的變更，另外處理）。
3. **對照官方原文。** 撰寫時下列頁面只能看到搜尋摘要，發佈前請再讀一次原文：
   - Gemini API 條款（https://ai.google.dev/gemini-api/terms ，含 18 歲規定和付費服務適用的處理者條款）；
   - 使用政策的 55 天保留期和「被標記時可能由 Google 授權人員人工審閱」（https://ai.google.dev/gemini-api/docs/usage-policies ）；
   - Gemini 的記錄政策（https://ai.google.dev/gemini-api/docs/logs-policy ）；
   - Google 的處理者資料處理附錄（https://business.safety.google/processorterms/ ）：第 12、17 節寫它以標準契約條款（SCC）處理跨境傳輸，並寫 Google LLC 有歐盟—美國資料隱私框架（DPF）和它的英國延伸（UK Extension）的認證（可在 https://www.dataprivacyframework.gov/list 查，Cloudflare 也一起確認：政策第 17 節寫它用 DPF、英國延伸、瑞士—美國 DPF 和標準契約條款）；
   - Google API Services User Data Policy（https://developers.google.com/terms/api-services-user-data-policy ，第 11 節的「合併、收購或資產出售須事先取得明確同意」）；
   - Apple App Review Guidelines 5.1.1(i)（第三方提供同等保護的聲明，第 12 節）；
   - Cloudflare DPA。
4. **政策照目前的程式寫，程式改了政策就要跟著改。** 依據是 2026-10-15 對照程式碼（base commit `b6fc485`）整理的事實，加上同一天工作區的改動（帳號 email 不送給 Gemini、同意說明第 4 版、1.0 不賣訂閱）。第一項已經在程式裡改好；其餘是 App 端的落差，都在這個資料夾以外，要另外處理，但**送審前一定要解決**：
   - **Google 帳號的 email 不送給 Gemini（程式已改）。** 助理的 prompt 經過 `CalendarAliases`（`Shared/AI/CalendarAliases.swift`）：有好幾個帳號時以「Account 1」「Account 2」區分，名稱是 email 的行事曆叫「Shared calendar」；行程標題、地點、備註和送回 Gemini 的錯誤訊息裡，已連接帳號的 email 換成「[account email]」「[Account N email]」，錯誤訊息裡的其他 email 換成「[email address]」；使用者自己輸入或說出的話裡如果有已連接帳號的 email，也換成佔位字，其他照原樣送出；Gemini 回覆裡的佔位字在 iPhone 上換回地址，才寫進 Google 日曆或顯示（`docs/GEMINI_FUNCTION_CALLING.md` §10.6）。同意說明是第 4 版（`AIConsent.disclosureVersion = 4`），五項內容和 prompt 實際送出的一致。網站照這個寫：政策第 4 節（中英文）列出實際送出的內容、說明帳號 email 的代稱和佔位字，並**逐字引用**同意說明的開頭、五項和收件者；第 11 節寫帳號 email 只在 iPhone 上用、不傳給 Gemini；支援頁「怎麼停止 AI 資料分享」引用其中一項；首頁的「AI 與隱私」也寫了。**`AIConsentDisclosure` 的文字再改時，政策第 4 節的引用要一起改**：英文照 `Shared/Storage/AIConsentStore.swift`，中文照 `Shared/Localization/Localizable.xcstrings` 的 zh-Hant 翻譯。
   - 麥克風是點一下開始、再點一下或送出才停（展開的動態島麥克風按鈕會直接開始錄音），政策第 8 節照實寫了；`project.yml` 和 `zh-Hant.lproj/InfoPlist.strings` 的 `NSMicrophoneUsageDescription` 也已改成「點麥克風後」（tap the mic）。
   - 示範模式：如果之前已經允許 AI 資料分享，App 在示範模式下仍會更新 session（`POST /session`），iOS 18 上也會把範例行程上傳到 `POST /devices/push-to-start`。政策第 1 節和首頁照實寫了。如果改成示範模式時跳過這些（並送一次清除），可以把第 1 節括號裡那句拿掉。
   - Google 撤銷授權是盡力而為（一次請求、10 秒逾時、失敗也不告訴使用者，權杖照樣刪除）。政策第 13、15 節和支援頁照實寫成「向 Google 要求撤銷，需要網路，離線時請到 Google 帳號移除」。如果 App 改成撤銷失敗時提示使用者或保留權杖重試，可以簡化這些句子。
   - App Attest 的 `key:<keyId>` 記錄沒有 TTL，Worker 也沒有刪除它的路由，「清除所有資料」後也還在（政策第 6、13 節照實寫了）。之後加上 TTL 或有簽章的刪除路由（讓「清除所有資料」呼叫）時，改這兩節。
   - 金鑰在**允許 AI 資料分享時**就產生，之後 session 每隔幾天自動更新（session 7 天、剩不到 3 天就換），即使沒用助理；政策第 6 節照實寫了。
   - iOS 18 動態島登記的法律依據寫成「履行契約」（第 15 節），因為 App 目前沒有它專屬的同意開關（AI 同意一併涵蓋、動態島設定預設開啟），用「同意」不夠具體。如果 App 之後在同意畫面或動態島設定加上 iOS 18 伺服器登記的獨立開關，可以改回「同意」。
   - 其他寫進政策的數字：最低年齡 18、48 小時、最多 50 個行程、登記 3 天後到期、session 7 天、計數 2 天、log 最多 7 天（Workers Paid plan）、對話從今天起 14 天、最多 40 個行程和最近 6 輪、備註 300 字、動態島提前時間 30／15／10／5 分鐘。
5. **support@smart-schedules.com 用 Google Workspace 收信和回信，政策照這個寫。** support@ 是 Google Workspace 的真實信箱（組織「Smart Schedule」，smart-schedules.com 是 Workspace 的主要網域，已驗證）。收信和回信都直接用 Workspace 的 Gmail，**不用 Cloudflare Email Routing**。政策第 9、12、13、17 節（中英文）照這個寫：Google（Google Workspace）的 Gmail 接收、保存客服信件並寄出回信，依 Google Workspace 適用的雲端資料處理附錄（Cloud Data Processing Addendum，CDPA）作為處理者。發佈前：
   - 換 DNS 時照 [§3.1](#31-網域squarespace--cloudflare一步一步) 把 Google 的郵件紀錄原樣搬到 Cloudflare，Active 後做 [第 3 步](#3-等-cloudflare-顯示-active)的郵件檢查，再照 [第 4 步](#4-完成-google-的郵件設定dkim-和-dmarc不用-email-routing)完成 DKIM 和 DMARC（Google Admin console 的「Complete email setup」）。
   - 確認 CDPA 已經生效：用超級管理員（super admin）登入 Google Admin console（https://admin.google.com）› 帳戶（Account）› 帳戶設定（Account settings）› 法律與法規遵循（Legal and compliance）› 安全性與隱私權附加條款（Security and Privacy Additional Terms）› 雲端資料處理附錄（Cloud Data Processing Addendum）› 檢查並接受（Review and Accept）。Google 說 Workspace 合約已經納入 CDPA 時不必再接受，不確定就接受，沒有副作用（請在畫面上確認）。
   - 之後如果改用別的收信方式（例如取消 Workspace），政策第 9、12、13、17 節要一起改。
6. **1.0 沒有 App 內購買。** 政策第 7 節「購買」寫 1.0 沒有任何 App 內購買或訂閱、App 不查詢購買記錄，第 12 節 Apple 那一項沒有「App 內購買」；支援頁的常見問題只留一題「有 App 內購買或訂閱嗎？」（`#zh-purchases`、`#en-purchases`），回答「沒有」。這要和 `AppConstants.subscriptionsEnabled = false`、App Store Connect 不附加任何購買項目一致。之後的版本開始賣 Smart Schedule Pro 時，在同一次發佈改回（舊的文字在 git 歷史裡）：政策第 7 節（由 Apple 銷售和收費、我們收不到付款資料、App 在 iPhone 上確認訂閱、清除資料不影響購買）和第 12 節的「App 內購買」；支援頁的「怎麼取消訂閱？」「怎麼回復購買項目？」（頭像 › 管理訂閱／回復購買項目、期間結束 24 小時前取消、退款到 reportaproblem.apple.com）、「多久會回覆」和「怎麼刪除我的資料？」裡訂閱的那一句，以及支援頁的 meta description。
7. **上架地區：1.0 不在歐洲經濟區和瑞士上架**（App Store Connect › 價格與供應狀況取消 27 個歐盟會員國，加上挪威、冰島、列支敦斯登和瑞士；**英國**和其他地區照常上架）。政策照仍在上架範圍內的地區寫：第 1 節用「英國 GDPR 等個資法」的用語，第 15 節的地區舉例是英國、美國加州和台灣，申訴機關舉英國的 ICO，法律依據的標題是「適用英國 GDPR 或類似法律時」，第 17 節寫英國使用者適用的 DPF 英國延伸。權利（查詢、更正、刪除、限制、反對、可攜、撤回同意）和法律依據的內容不變，英國 GDPR 一樣適用。
   - **歐洲經濟區和瑞士的代表（GDPR 第 27 條、瑞士 FADP 第 14 條）：排除期間不需要。** 之後的版本加入這些 storefront 前，要指定代表、把名稱和郵寄地址寫進政策第 1、19 節（中英文），並把第 1、15 節的法規、地區舉例和申訴機關（挪威 Datatilsynet、冰島 Persónuvernd、瑞士 FDPIC 等）加回去。
   - **英國代表（英國 GDPR 第 27 條）：英國照常上架，所以仍然要處理。** 豁免只適用於「偶發」而且低風險的處理；Smart Schedule 持續處理使用者資料（伺服器儲存、沒有到期時間的 App Attest 記錄、轉送給 AI），不算偶發。除非開發者在英國設有據點，上架前要指定英國代表，並把名稱和郵寄地址寫進政策第 1、19 節（中英文）；不想指定，就要在 1.0 也排除英國。
   - **挪威、冰島、列支敦斯登和瑞士不是歐盟**，只取消歐盟 storefront 不會排除它們，所以要另外勾掉。
8. **App 名稱。** 首頁標題是「Smart Schedule」。如果 App Store 名稱因為撞名改成別的，首頁、Google OAuth 的 App name 和 App Store 名稱三者要一致。
9. App 上架後，在首頁加上 App Store 連結。

## 3. 部署

以下都還沒做。所有指令都在 repo 根目錄執行，用 `server/worker` 已經裝好的 wrangler，`site/` 不需要 `package.json`。

### 3.1 網域：Squarespace → Cloudflare（一步一步）

smart-schedules.com 註冊在 Squarespace Domains（可能是從 Google Domains 搬過去的）。這一節只把 **DNS 交給 Cloudflare**（換 nameserver），**註冊、續約和帳單都還留在 Squarespace**。要不要把註冊也搬到 Cloudflare 是第 8 步，可以之後再做。

- 全程用**跑著 Worker `smart-schedule-worker` 的同一個 Cloudflare 帳號**。Worker 的 Custom Domain 只能用在同一個帳號裡、而且是 Active 的網域。
- **郵件留在 Google Workspace。** support@smart-schedules.com 是 Google Workspace 的信箱：Google Admin console 顯示組織「Smart Schedule」、smart-schedules.com 是主要網域（primary domain）、已驗證（Verified）、郵件設定狀態「All OK」，所以 Squarespace 的 DNS 裡已經有 Google 的 MX。搬 DNS 時 **Google 的郵件紀錄要一筆不漏、原樣搬到 Cloudflare**，而且**完全不用 Cloudflare Email Routing**：它要獨占整個網域的 MX，開了就會和 Google 的 MX 衝突，support@ 收不到信。
- 括號裡是畫面上的英文字。Squarespace 的按鈕名稱整理自官方說明文章被搜尋引擎收錄的內容（2026-10，當時無法直接打開 support.squarespace.com），Cloudflare 的整理自官方文件（2026-07～10 更新），Google Admin console 的整理自 Google Workspace 說明文件被搜尋引擎收錄的內容（2026-10）。**畫面和這裡不同時，以畫面為準。**
- `example@gmail.com` 一律換成你自己的私人信箱。私人信箱不要寫進這個 repo 或網站。
- `dig` 和 `curl` 指令在終端機執行；`dig` 也可以改用網頁 https://www.whatsmydns.net/ 或 https://dnsviz.net 檢查。

大概的時間：第 0 步關 DNSSEC 後，要等舊的 DS 紀錄從註冊局消失、再多等 24 小時，才能做第 2 步（合計大約 2～3 天，見第 0 步的「要多久」）；第 2 步之後最多再等 24～48 小時變成 Active；一變成 Active 就檢查郵件（第 3 步）；郵件正常後依序做第 4 步（DKIM、DMARC）、第 5 步（部署網站）和第 6 步（Search Console）。

#### 0. 開始前（在 Squarespace，先不換 nameserver）

1. **打開網域。** 到 https://account.squarespace.com/domains 登入（或 account.squarespace.com › 右上角頭像 › 網域（Domains）分頁）› 在網域總覽（Domains dashboard）點 `smart-schedules.com`，進入這個網域的設定頁。下面所有 Squarespace 的路徑都從這一頁開始。
   - 你目前用 support@smart-schedules.com 登入 Squarespace。網域原本在 Google Domains 的話，Squarespace 帳號就是當初 Google Domains 用的那個 Google 帳號 email。
   - 清單裡沒有 smart-schedules.com：可能在另一個 Squarespace 帳號底下。
   - 透過 Google Workspace 買的網域：帳單和取消在 Google Admin console，DNS 和 nameserver 還是在這裡改。
2. **先確保不會被鎖在帳號外。** 你用 support@smart-schedules.com 登入 Squarespace 和 Google Cloud，而這個信箱收信靠的正是這次要搬的 MX 紀錄。只要第 1 步把 Google 的 MX 原樣搬過去，郵件就不會中斷；但萬一漏了，寄到 support@ 的登入驗證碼和重設密碼信就收不到，可能連 Squarespace 都登不進去、沒辦法把 nameserver 改回來。所以換 nameserver 之前先做：
   - **support@ 的 Google 帳號：** https://myaccount.google.com › 安全性（Security）› 加上復原電話（Recovery phone）和復原電子郵件（Recovery email，填私人信箱 `example@gmail.com`，不要填 support@ 自己），並把兩步驟驗證的備用碼（Backup codes）存在安全的地方。Google 帳號登入本身用密碼和兩步驟驗證，不靠收信；但 Workspace 的超級管理員（super admin）能不能自己用「忘記密碼」復原，要看 Admin console › 安全性（Security）› 驗證（Authentication）› 帳戶復原（Account recovery）› 超級管理員帳戶復原（Super admin account recovery）有沒有開（請在畫面上確認）。Google Cloud 也是用這個帳號登入，一起受到保護。
   - **Squarespace：** 打開兩步驟驗證（用驗證器 App，不要只靠 email）並存好備用碼，這樣登入不需要收信。再考慮加一個用私人信箱的備用登入方式：把 Squarespace 帳號的登入 email 改成私人信箱，或用私人信箱的另一個 Squarespace 帳號接受這個網域的管理權限邀請（選項名稱請在畫面上確認）。你是用「用 Google 繼續」（Continue with Google）登入 Squarespace 的話，登入靠的是 Google 帳號，不靠收信。
   - **Cloudflare：** 帳號 email 如果也是 support@，同樣打開兩步驟驗證並存好備用碼。
3. **有沒有連著 Squarespace 網站。** 網域設定頁 › 網站（Website）：顯示連到某個 Squarespace 網站，或可以選變更連線（Change connection），就是有連著；DNS › DNS 設定（DNS Settings）裡有「Squarespace Defaults」區塊也是。換 nameserver 後這個連線會自動中斷，那個網站在 smart-schedules.com 打不開（內建的 `*.squarespace.com` 網址還能用），smart-schedules.com 改由第 5 步的網站提供。不需要先手動停放（Park this domain）。**那個 Squarespace 網站還要用的話，先停下來想清楚。**
4. **郵件：Google Workspace（已確認在用）。** Google Admin console（https://admin.google.com）顯示 smart-schedules.com 是 Workspace 的主要網域、已驗證，郵件設定狀態「All OK」，表示 Squarespace 的 DNS 裡已經有指向 Google 的 MX。所以這次要**保留所有 Google 的郵件紀錄**（下一項列出），**不用 Cloudflare Email Routing**。另外查兩件事：
   - **Workspace 的帳單在哪裡。** 網域設定頁 › 電子郵件（Email）› 管理方案（Manage plan）列出使用者，或 帳單（Billing）› 訂閱項目（Subscriptions）有 Google Workspace，就是透過 Squarespace 付費；都沒有就是直接付給 Google（Admin console › 帳單（Billing））。換 nameserver 不影響帳單，但第 8 步移轉註冊前要知道（請在畫面上確認）。
   - **有沒有 Squarespace 郵件轉寄（Mailgun）。** 同一頁往下的郵件轉寄（Email Forwarding）有沒有規則，以及 DNS 設定裡有沒有指向 `mxa.mailgun.org`、`mxb.mailgun.org` 的 MX（Google Domains 的轉寄規則搬到 Squarespace 後會變成這樣）。有的話，Mailgun 的紀錄**不要搬**：Workspace 收信用不到它們，和 Google 的 MX 並存反而可能讓部分信件跑到 Mailgun。規則裡如果有還需要的地址（例如 `info@` 要收進 support@），改在 Workspace 加成 support@ 的別名：Admin console › 目錄（Directory）› 使用者（Users）› support@ › 使用者資訊（User information）› 替代電子郵件地址（Alternate email addresses (email aliases)）（請在畫面上確認）。Squarespace 的轉寄規則等第 3 步確認郵件正常後再刪。
5. **抄下所有 DNS 紀錄。** DNS › DNS 設定（DNS Settings）。頁面分好幾個區塊：Squarespace Defaults、預設組合（preset，例如 Google Workspace）、郵件轉寄自動加的紀錄、第三方服務透過 Domain Connect 自動加的唯讀區塊（如果有）、自訂紀錄（Custom Records）。Squarespace **沒有匯出（Export）功能**，而且換 nameserver 後這些紀錄全部失效，所以：
   1. 每個區塊都截圖。
   2. 逐筆抄下 Host（主機）、Type（類型）、Priority（優先順序）、Data（值）。
   3. 第 1 步拿來和 Cloudflare 掃描匯入的結果逐筆比對。
   - **Google 的郵件紀錄（全部原樣搬，值和優先順序一個字都不要改）：** 通常在「Google Workspace」預設組合或自訂紀錄裡。另外列成一張清單，第 1、3 步會用到。
     - `@` 的 **MX**：新式是一筆 `smtp.google.com`、優先順序 1；舊式是五筆 `aspmx.l.google.com`（1）、`alt1.aspmx.l.google.com`（5）、`alt2.aspmx.l.google.com`（5）、`alt3.aspmx.l.google.com`（10）、`alt4.aspmx.l.google.com`（10）。**Squarespace 顯示哪一種就照抄哪一種**：Google 兩種都支援，搬家時不要順便改，也不要混用。
     - `@` 的 **SPF** TXT：`v=spf1 include:_spf.google.com ~all`。整個網域只能有一筆 `v=spf1`。裡面如果還有 `include:mailgun.org`（Squarespace 郵件轉寄加的），搬的時候拿掉那一段；沒有 SPF 的話，第 4 步再加。
     - **DKIM** TXT（有的話）：主機 `google._domainkey`，值是 `v=DKIM1; k=rsa; p=…` 開頭的一長串。
     - **DMARC** TXT（有的話）：主機 `_dmarc`，值是 `v=DMARC1;` 開頭。
     - **每一筆** `google-site-verification=…` TXT（可能不只一筆，Workspace、Search Console 等各自加的）。Workspace 的網域靠它維持已驗證。
     - 指向 `*.googlehosted.com` 的 CNAME（例如指向 `ghs.googlehosted.com` 的自訂網址，或 Google 驗證用的紀錄；從 Google Domains 搬來的網域，Squarespace 可能自動加過一筆）。主機是 `@` 或 `www` 的例外，不要搬（見下面）。
   - **其他要搬：** 你自己加的其他紀錄（例如別的子網域）。
   - **不要搬：** Squarespace Defaults（連 Squarespace 網站用的 `@` A 紀錄和 `www` CNAME；根網域改由第 5 步的 Worker 負責，`www` 改由 [§3.3](#33-www--根網域控制台免費方案) 轉址）；郵件轉寄區塊和 Mailgun 的紀錄（`mxa.mailgun.org`、`mxb.mailgun.org` 的 MX，以及只為 Mailgun 加的 SPF）。
   - 網路上有第三方 Chrome 擴充功能「Squarespace DNS Exporter」可以匯出，但它不是官方工具，隱私沒有經過驗證，不建議使用。
6. **關掉 DNSSEC（一定要在換 nameserver 之前）。** 網域設定頁 › DNS › DNSSEC › 關掉「DNS 安全性擴充」開關（DNS Security Extensions）› 在跳出的確認視窗按確認（Confirm）。Squarespace 說這會把 DNSSEC 資訊從註冊局移除，要 24～48 小時才會更新。
   - Squarespace 管理的 .com 網域預設會自動開 DNSSEC。從 Google Domains 搬來的網域官方沒寫，但有人回報 DNSSEC 跟著搬過來，請當成是開著的。
   - 看不到開關：刪掉 DNSSEC 面板裡 DS 紀錄（DS records）底下的每一筆，效果一樣。兩個都看不到、下面的檢查卻還有輸出，聯絡 Squarespace 客服。
   - 為什麼要先關：舊的 DS 還在快取裡就換 nameserver，會驗證失敗（SERVFAIL），整個網域連不上，或一直卡在 Pending。Squarespace 換 nameserver 的流程雖然也會順便關 DNSSEC，但不會等舊的快取過期。
7. **WHOIS 隱私保持開著。** 網域設定頁 › WHOIS 隱私（Whois Privacy）開關。Squarespace 管理的網域大多免費附送、預設開啟；關掉等於同意把聯絡資料公開。

**成功時會看到：** support@ 的 Google 帳號有復原電話、復原電子郵件和備用碼，Squarespace 有不靠 support@ 收信也能登入的方式；截圖和紀錄清單都有了，Google 的郵件紀錄另外列好；DNSSEC 開關是關的；過了 24～48 小時後，`dig DS smart-schedules.com +short` 沒有任何輸出（或 https://dnsviz.net 顯示沒有 DS）。剛關掉時還有輸出是正常的。

**要多久：** 兩段等待。(1) Squarespace 把 DS 從註冊局移除要 24～48 小時；(2) 移除後，各地 DNS 伺服器快取裡的舊 DS 最多還會留 24 小時（.com DS 紀錄的 TTL；Cloudflare 的說法是通常 24～48 小時）。所以等到 `dig DS smart-schedules.com +short` **第一次**沒有輸出（或 dnsviz 顯示沒有 DS）之後，**再多等 24 小時**，才做第 2 步。記下第一次沒有輸出的時間。關掉之前 `dig DS` 就已經沒有輸出的話（本來就沒開 DNSSEC），不用等。等的時候可以先做第 1 步。

#### 1. 在 Cloudflare 加入網域

1. 用跑著 `smart-schedule-worker` 的帳號登入 Cloudflare › 左側網域（Domains）› 加入網域（Onboard a domain）› 輸入 `smart-schedules.com`（不要加 `www`）› 加入 DNS 紀錄的方式選快速掃描（quick scan）› 繼續（Continue）› 方案選 **Free** › 檢查匯入的紀錄（review DNS records）› 繼續到啟用（Continue to activation）。
2. 最後一頁會顯示 Cloudflare 指派的**兩個 nameserver**（像 `xxxx.ns.cloudflare.com`）。之後也可以在這個網域的總覽（Overview）頁，或 DNS › Records 頁的「Cloudflare nameservers」卡片找到。**從畫面複製貼上，不要手打**（打成 `cloudlfare`、`cloudfare` 是卡在 Pending 最常見的原因）。每個網域指派的可能不同，不能沿用別的網域的。
3. 這個網域 › DNS › Records（DNS 紀錄）：和第 0 步的清單逐筆比對。快速掃描通常抓得到 `@` 的 MX 和 TXT，但可能漏掉子網域、DKIM（`google._domainkey`）和 DMARC（`_dmarc`），漏掉的用 Add record 補上。然後：
   - **保留 Google 的郵件紀錄，而且要和第 0 步的清單完全一樣：** MX 的郵件伺服器（Mail server）和優先順序（Priority）、唯一一筆 SPF、DKIM、DMARC（原本有的話）、每一筆 `google-site-verification`、指向 `*.googlehosted.com` 的 CNAME。MX 和 TXT 一律是 DNS only（Cloudflare 不會代理郵件），不用另外設定；`*.googlehosted.com` 的 CNAME 要把 Proxy status 切成 **DNS only**（灰色雲朵）（請在畫面上確認）。補 DKIM 時 Name 填 `google._domainkey`，Content 整段貼上。
   - **這些 Google 紀錄一定要在第 2 步之前就在 Cloudflare 上。** 一換 nameserver，只有 Cloudflare 上的紀錄算數，漏掉 MX 的話 support@ 會馬上收不到信。
   - **刪掉** `@`（根網域）的 **A、AAAA、CNAME** 紀錄（Squarespace 的，例如 `198.185.159.x`、`198.49.23.x`，以畫面為準）和 `www` 的 CNAME（例如 `ext-cust.squarespace.com`）。根網域要給第 5 步的網站，`www` 要給 [§3.3](#33-www--根網域控制台免費方案) 的轉址。已經有 CNAME 的主機名稱不能建立 Custom Domain。這幾筆也可以等 Active 之後再刪，但一定要在第 5 步部署之前刪掉。
   - **刪掉** Mailgun 的 MX（`mxa.mailgun.org`、`mxb.mailgun.org`）和只為 Mailgun 加的 SPF。SPF（`v=spf1` 開頭的 TXT）整個網域只能有一筆，就是 Google 那一筆。
   - **不要開 Email Routing。** Cloudflare 可能在 Email 或 DNS 頁面建議開啟 Email Routing，或建議加「防止冒名寄信」的紀錄（例如 `v=spf1 -all`、`p=reject` 的 DMARC）。那是給不寄信的網域用的，**都不要接受**，否則 support@ 收不到信或寄出的信被拒（請在畫面上確認）。

**成功時會看到：** Cloudflare 的網域（Domains）清單裡有 smart-schedules.com，狀態是「Pending Nameserver Update」（還沒換 nameserver 時本來就是這樣）；你手上有那兩個 nameserver；DNS Records 裡 Google 的 MX（值和優先順序）、唯一一筆 SPF、DKIM／DMARC（原本有的話）和所有 `google-site-verification` 都在，`@` 沒有 A／AAAA／CNAME，也沒有 Mailgun 的 MX。

**要多久：** 這一步不用等。但 Free 方案的網域停在 Pending 超過 28 天會被自動刪除，所以加入後一個月內要做完第 2 步。

#### 2. 在 Squarespace 換成 Cloudflare 的 nameserver

**先確認：** `dig DS smart-schedules.com +short` 沒有輸出，而且從**第一次**沒有輸出算起已經過了至少 24 小時（見第 0 步的「要多久」）；第 1 步的 Google 郵件紀錄都已經在 Cloudflare 的 DNS Records 裡；第 0 步的帳號備援（復原電話和 email、備用碼）已經弄好。

1. 網域設定頁 › DNS › 網域 Nameserver（Domain Nameservers）› 使用自訂 nameserver（Use Custom Nameservers）› 輸入 Squarespace 密碼或兩步驟驗證碼（2FA）› 出現停用 DNSSEC 的提示時確認（confirm disabling DNSSEC）› 在 Nameserver 1 和 Nameserver 2 各貼上一個 Cloudflare 給的 nameserver › 儲存（Save）。
   - 只填 Cloudflare 那兩個，字要完全一樣，不要留 Squarespace 或其他家的（Squarespace 規定最少 2 個、最多 13 個）。
   - Squarespace 會警告網域會和 Squarespace 網站斷開、DNS 設定裡的紀錄不再生效。這是預期的。
   - 網域有進行中的移轉（pending domain transfer）時這一頁不能改。
   - 要改回原狀：同一頁選使用 Squarespace nameserver（Use Squarespace nameservers）› 儲存，再依提示按查看 DNSSEC（View DNSSEC）把開關打開。
2. **換完之後，Squarespace 這邊會停掉的：** DNS 設定裡的所有紀錄（之後只有 Cloudflare 上的紀錄算數）；和 Squarespace 網站的連線；Squarespace 郵件轉寄（如果有；郵件頁會出現「需要處理」（Action required）橫幅）；Squarespace 或 Google Domains 的網域轉址（domain forwarding）；PayPal Payment Links；Squarespace 這邊的 DNSSEC。
   - **Google Workspace 收發信不會停**，前提是第 1 步已經把 Google 的郵件紀錄都放到 Cloudflare。Squarespace 的電子郵件（Email）頁之後可能顯示 DNS 紀錄有問題的提示，以 Google Admin console 和第 3 步的檢查為準（請在畫面上確認）。
3. **還留在 Squarespace 的：** 網域註冊本身、續約和帳單、WHOIS 隱私、網域鎖定（Domain Lock）、註冊資訊（Registration Information），以及透過 Squarespace 買的 Google Workspace 訂閱和帳單（如果是）。**換 nameserver 不等於移轉註冊。自動續約要保持開著，不要取消 Squarespace 的網域訂閱，否則網域會過期。**

**成功時會看到：** 網域 Nameserver（Domain Nameservers）那一區顯示的是 Cloudflare 的兩個 nameserver（請在畫面上確認）。

**要多久：** 存檔就好；生效要等第 3 步。

#### 3. 等 Cloudflare 顯示 Active

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

   2. 網頁檢查：Google Admin Toolbox 的 Check MX（https://toolbox.googleapps.com/apps/checkmx/）› 輸入 `smart-schedules.com` › 執行檢查（按鈕名稱請在畫面上確認）。MX 和 SPF 應該沒問題；第 4 步做完之前，DKIM、DMARC 的警告是正常的。
   3. **收發測試。** 從**另一個**信箱（例如 `example@gmail.com`）寄一封信到 support@smart-schedules.com › 用 support@ 登入 Gmail（https://mail.google.com）看到這封信 › 直接按回覆（Reply）› 那個信箱收到寄件人是 support@smart-schedules.com 的回信。不要用 support@ 寄給自己測試，那封信只會出現在寄件備份。
   4. Google Admin console › 帳戶（Account）› 網域（Domains）› 管理網域（Manage domains）：smart-schedules.com 仍然是已驗證（Verified），郵件設定狀態仍然是「All OK」（請在畫面上確認；Google 重新檢查可能要一點時間）。
   5. 第 0 步查到 Squarespace 郵件轉寄規則的話，現在刪掉：Squarespace 網域設定頁 › 電子郵件（Email）› 郵件轉寄（Email Forwarding）› 每條規則旁的垃圾桶圖示（要重新驗證身分）。刪掉最後一條時，Squarespace 自動加的轉寄紀錄也會一起移除。
   - 任何一項不對，看[疑難排解](#疑難排解)的「support@ 收不到信或寄不出去」。

**成功時會看到：** 收到 Cloudflare 的通知 email；Cloudflare › 網域（Domains）頁上 smart-schedules.com 的狀態從「Pending Nameserver Update」變成 **Active**；`dig MX` 是 Google 的 MX；測試信收得到、回信寄得出去；Admin console 仍然顯示 Verified 和 All OK。

**要多久：** Cloudflare 說通常最多 24 小時；Squarespace 說最多 48 小時才完全生效（有些文章寫 24～72 小時）。一直 Pending 請看下面的[疑難排解](#疑難排解)。

#### 4. 完成 Google 的郵件設定：DKIM 和 DMARC（不用 Email Routing）

support@smart-schedules.com 是 Google Workspace 的信箱：寄來的信由第 1 步保留的 Google MX 直接送進 Workspace 的 Gmail；**回信也直接在 Workspace 的 Gmail 按回覆**（用 support@ 登入 https://mail.google.com），寄件人就是 support@smart-schedules.com，不需要「以這個地址寄送郵件」（Send mail as）、SMTP 或應用程式密碼。收發是否正常已經在第 3 步檢查過。

這一步只剩 Google Admin console 首頁那條「Improve the chances of your email landing in inboxes … Complete email setup」橫幅：完成 DKIM 和 DMARC，讓回信比較不會被當成垃圾郵件。**一定要等第 3 步 Active、而且郵件檢查都正常之後再做**：紀錄要加在 Cloudflare（加在 Squarespace 的換完 nameserver 就失效），而且 Google 開始驗證時查的是公開的 DNS。也可以直接點橫幅上的 Complete email setup 跟著畫面做，畫面要你加的 DNS 紀錄一樣加在 Cloudflare（請在畫面上確認）。

DKIM 加好紀錄後最多要等 48 小時才開始驗證。等的時候可以先做第 5 步（部署網站），之後再回來按開始驗證、加 DMARC。

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

#### 5. 部署網站

**前提：** 第 3 步已經 Active、郵件檢查都正常；第 4 步的 DKIM 紀錄已經加到 Cloudflare（等 Google 開始驗證、再加 DMARC 的那段時間，可以先做這一步）；第 1 步說的 `@` 的 A／AAAA／CNAME 已經刪掉。

1. **打開 HTTPS 強制轉址。** 這個網域 › SSL/TLS › 總覽（Overview）：確認加密模式（encryption mode）不是 Off（Off 時看不到下一個選項）› SSL/TLS › 邊緣憑證（Edge Certificates）› 打開 **Always Use HTTPS**。Free 方案就有。HSTS 等網站確定正常後再考慮，不急。
2. **部署。** 在 repo 根目錄、**一般的終端機視窗**裡執行（最後一行就是 `site/wrangler.toml` 開頭註解寫的部署指令）：

   ```sh
   server/worker/node_modules/.bin/wrangler whoami                                   # 確認是跑 smart-schedule-worker 的同一個帳號
   server/worker/node_modules/.bin/wrangler deploy --dry-run -c site/wrangler.toml   # 只檢查，不部署
   server/worker/node_modules/.bin/wrangler deploy -c site/wrangler.toml             # 正式部署
   ```

   - 你的 Cloudflare 登入可以進好幾個帳號時，部署會先問「Select an account」：選跑 `smart-schedule-worker`、而且 smart-schedules.com 是 Active 的那個帳號。選錯帳號，Custom Domain 會建立失敗。
   - `wrangler.toml` 的 `[[routes]]`（`pattern = "smart-schedules.com"`、`custom_domain = true`）會建立 Custom Domain：Cloudflare 自動加一筆指向 Worker 的 DNS 紀錄（在 DNS Records 表裡是唯讀、Proxied 的，不要手動改），也自動簽發這個網域的憑證（Advanced Certificate，不另外收費）。
   - `@` 還有舊紀錄時，wrangler 會問「You already have DNS records that conflict for these Custom Domains: … Update them to point to this script instead?」。回答 No 會顯示「Publishing to Custom Domain "smart-schedules.com" was skipped, fix conflict and try again」：到 DNS › Records 刪掉 `@` 的 A／AAAA／CNAME，再部署一次。
   - **不要在腳本或 CI 裡跑部署指令。** 不是互動式終端機時，wrangler 不會問，直接覆蓋既有的 DNS 紀錄，連綁在別的 Worker 上的同名 Custom Domain 也會搶過來。
3. 接著做 [§3.3](#33-www--根網域控制台免費方案)（www 轉到根網域）和 [§3.4](#34-部署後檢查)（部署後檢查）。本機預覽和其他說明在 [§3.2](#32-本機預覽與部署)。

**成功時會看到：** DNS › Records 多了一筆 smart-schedules.com 的唯讀紀錄（指向 Worker）；Workers & Pages › `smart-schedules-site` › Settings › Domains & Routes 列出 `smart-schedules.com`（請在畫面上確認）；`curl -sI https://smart-schedules.com/` 回 `200`，瀏覽器打開是新的首頁。

**要多久：** 指令跑完就部署好了。憑證自動簽發要多久，研究時沒查到；剛部署完打不開或出現憑證錯誤，等一下再試（請在畫面上確認）。

#### 6. Google Search Console 驗證

Google OAuth 的品牌驗證要求這個網域在 Search Console 驗證過，而且驗證用的 Google 帳號是 Google Cloud 專案的 **Owner 或 Editor**。

1. **用 Workspace 帳號登入，先看是不是已經驗證了。** 用 support@smart-schedules.com 登入 https://search.google.com/search-console。它多半就是當初驗證 Workspace 網域的帳號，也是你登入 Google Cloud 的帳號（它要是 Cloud 專案的 Owner 或 Editor；換別的帳號的話，那個帳號也要是）。資源清單裡已經有 `smart-schedules.com` 網域資源而且打得開，就完成了。
2. 還沒有的話：新增資源（Add property）› 選左邊的 **網域（Domain）** › 輸入 `smart-schedules.com`（不加 `https://` 或 `www`）› 繼續（Continue）。網域資源只能用 DNS 驗證。DNS 裡如果有這個帳號驗證 Workspace 時加的 `google-site-verification` TXT（第 1 步保留的），Search Console 可能直接顯示已驗證，或按驗證（Verify）就通過（請在畫面上確認）。
3. **自動方式（沒有直接通過、而且有出現才用）：** Cloudflare 已經 Active 時，Search Console 通常會認出 DNS 在 Cloudflare，顯示開始驗證（Start verification）› 新分頁登入 Cloudflare（同一個帳號）› 授權（Authorize）› Cloudflare 自動加一筆 TXT › 回到 Search Console。這個流程只有第三方指南的說法（請在畫面上確認）。
4. **手動方式（沒有那個按鈕或自動失敗時）：** 下拉選單選任何 DNS 供應商（Any DNS provider），記錄類型選 TXT，複製 `google-site-verification=…` › Cloudflare › 這個網域 › DNS › Records › Add record：Type `TXT`、Name `@`、Content 貼上 › Save（TXT 一律是 DNS only，不會 proxied）› 回 Search Console 按驗證（Verify）。這是**新加一筆**，不要覆蓋 Workspace 原本那筆 `google-site-verification`；同一個網域可以有好幾筆。
5. **要加在 Cloudflare，不是 Squarespace。** 換 nameserver 後，加在 Squarespace 的紀錄不會生效。
6. **所有 `google-site-verification` TXT 都要永久保留**，刪掉會失去 Search Console 或 Workspace 的驗證。它們可以和 Google 的 SPF TXT 並存；只能有一筆的是 SPF（`v=spf1`）紀錄。

**成功時會看到：** Search Console 顯示擁有權已驗證，資源清單裡有 `smart-schedules.com`（請在畫面上確認）。

**要多久：** 已經驗證或自動方式幾分鐘。手動方式 DNS 生效可能要幾分鐘到幾小時，失敗就過幾分鐘再按驗證，**不要改紀錄**。

#### 7.（選做）在 Cloudflare 重新開 DNSSEC

這個專案沒有任何地方需要 DNSSEC，不做也不影響網站、Google Workspace 郵件或 Google 驗證。要做的話，等網站和 email 都正常後再做。很快就要做第 8 步的話可以先跳過：移出 Squarespace 前要先把這裡加的 DS 紀錄刪掉（移轉進行中不能改 DNSSEC），轉到 Cloudflare Registrar 後 Cloudflare 會自動處理 DNSSEC。

1. **先確認 Squarespace 能加 DS 紀錄。** Squarespace 的新增 DS 紀錄只適用「註冊商是 Squarespace Domains, LLC、而且用自訂 nameserver」的網域。到 https://lookup.icann.org/ 查 smart-schedules.com 的註冊商（Registrar）欄位；從 Google Domains 搬來的網域可能是 Squarespace Domains II LLC。Squarespace 網域設定頁 › DNS › DNSSEC 看不到新增紀錄（Add record）的話，就不要開。
2. Cloudflare › 這個網域 › DNS › Settings › DNSSEC › Enable DNSSEC。對話框會列出 Key Tag、Algorithm（13）、Digest Type（2，SHA-256）和 Digest。關掉對話框後，可以在 DNSSEC 卡片點 DS record 再看。
3. Squarespace 網域設定頁 › DNS › DNSSEC › 新增紀錄（Add record）› 輸入密碼或兩步驟驗證碼 › 填 Key tag、Algorithm（13，ECDSA Curve P-256 with SHA-256）、Digest type（2，SHA-256）、Digest › 儲存（Save）。

**成功時會看到：** https://dnsviz.net 或 https://dnssec-debugger.verisignlabs.com/ 檢查沒有錯誤；Cloudflare 的 DNSSEC 卡片顯示已生效。

**要多久：** 研究時沒查到確切時間（請在畫面上確認）。

#### 8.（選做，之後再做）把註冊轉到 Cloudflare Registrar

不急：DNS 已經在 Cloudflare 了，這一步只是把續約和帳單也搬過去。

**開始前要符合：**
- 網域在 Cloudflare 是 Active 的完整設定（full setup），否則 Cloudflare 不讓你輸入移轉碼。
- 不在 60 天鎖定期內：新註冊、移入 Squarespace、或改過註冊人姓名／組織／email 之後 60 天內不能移出。2023–2024 年 Google Domains 整批搬到 Squarespace，早已超過 60 天。換 nameserver 和關 DNSSEC 不會觸發 60 天鎖定。
- 剛在 Squarespace 續約的話，至少等 45 天，否則移轉加的那一年不算，等於同一年付兩次。
- Cloudflare 帳號的 email 已驗證，而且設定了付款方式。
- Google Workspace 是透過 Squarespace 付費的話（第 0 步查到的），先確認網域移出 Squarespace 後 Workspace 訂閱和帳單會怎麼處理，需要的話先把帳單改成直接付給 Google（請在畫面上確認）。DNS（包括 Google 的郵件紀錄）已經在 Cloudflare，移轉註冊本身不影響收信。
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

#### 疑難排解

**網站打不開**
- 還不是 Active：看第 3 步。一直 Pending 時依序檢查：Squarespace 有沒有真的存檔；nameserver 和 Cloudflare 畫面上的是否完全一樣（`cloudlfare` 這類拼錯）；有沒有多留 Squarespace 或別家的 nameserver；`dig DS smart-schedules.com +short` 是不是還有輸出（殘留的 DS，到 Squarespace › DNS › DNSSEC 刪掉）。Free 方案停在 Pending 超過 28 天會被自動刪除。
- 出現 SERVFAIL 或整個網域連不上：多半是舊的 DS 還在。到 Squarespace › DNS › DNSSEC 刪掉 DS 紀錄，再等至少 24 小時。
- 還是舊的 Squarespace 頁面，或部署時出現「Publishing to Custom Domain "smart-schedules.com" was skipped」：`@` 還有舊的 A／AAAA／CNAME。刪掉後重新執行第 5 步的部署指令。
- `www.smart-schedules.com` 打不開或沒轉址：`www` 要有一筆 Proxied 的紀錄（AAAA `100::`）再加上 Redirect Rule，見 [§3.3](#33-www--根網域控制台免費方案)。
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

### 3.2 本機預覽與部署

第一次部署前，先做完 [§3.1](#31-網域squarespace--cloudflare一步一步) 的第 0～4 步（zone 要是 Active、郵件檢查正常，DKIM 紀錄已經加到 Cloudflare）。

```sh
W=server/worker/node_modules/.bin/wrangler
$W whoami                                   # 確認登入的是和 API Worker 同一個帳號
$W dev -c site/wrangler.toml                # 本機預覽 http://localhost:8787
$W deploy --dry-run -c site/wrangler.toml   # 只檢查，不部署
$W deploy -c site/wrangler.toml             # 建立 Worker「smart-schedules-site」、根網域的 Custom Domain、DNS 紀錄和憑證
```

- `wrangler.toml` 設了 `workers_dev = false` 和 `preview_urls = false`：網站只在 smart-schedules.com 上提供，沒有平台主機名稱。
- 想要短一點的指令，可以在 `server/worker/package.json` 加 `"deploy:site": "wrangler deploy -c ../../site/wrangler.toml"`（設定檔裡的路徑以設定檔所在的資料夾為準）。
- 也可以在控制台加網域：Workers & Pages › `smart-schedules-site` › Settings › Domains & Routes › Add › Custom domain。

### 3.3 www → 根網域（控制台，免費方案）

1. DNS › Add record：類型 `AAAA`、名稱 `www`、內容 `100::`、**Proxied**。這只是佔位紀錄，沒有真的伺服器；Redirect Rule 需要一筆 proxied 紀錄。
2. Rules › Create rule › **Redirect Rule**（範本「Redirect from WWW to root」）：
   - 比對：Wildcard，Request URL `https://www.smart-schedules.com/*`
   - 目標：`https://smart-schedules.com/${1}`
   - 狀態碼 301，保留 query string。

另一個做法：在 `wrangler.toml` 多加一個 `www.smart-schedules.com` 的 `custom_domain` route，再搭配同一條 Redirect Rule。

### 3.4 部署後檢查

```sh
curl -sI https://smart-schedules.com/              # 200
curl -sI https://smart-schedules.com/privacy       # 200 text/html
curl -sI https://smart-schedules.com/privacy.html  # 307 -> /privacy
curl -sI https://smart-schedules.com/nope          # 404
curl -sI https://www.smart-schedules.com/support   # 301 -> https://smart-schedules.com/support
curl -sI http://smart-schedules.com/               # 301 -> https
```

再用手機打開三頁，確認淺色、深色和語言切換都正常，而且沒有黃色的佔位文字。

### 3.5 Google Search Console 網域驗證

Google OAuth 的品牌驗證要求首頁和隱私權政策所在的網域已經驗證，而且驗證的人是 OAuth 專案的 Owner 或 Editor。步驟在 [§3.1 第 6 步](#6-google-search-console-驗證)：先用 support@ 這個 Workspace 帳號登入看看是不是已經驗證（DNS 裡如果有它驗證 Workspace 時加的 `google-site-verification` TXT，可能已經通過），沒有再用自動或手動方式加 TXT；所有 `google-site-verification` TXT 都要永久保留。

### 3.6 Google Auth Platform（Google Cloud 控制台）

`calendar.events` 和 `calendar.calendarlist.readonly` 是敏感（sensitive）scope，不是受限（restricted）scope：要過品牌驗證和敏感 scope 審查。審查可能要好幾週，而且只依賴這個網站，不必等 Apple 開發者帳號，所以網站上線後就盡快送。

1. **Branding**：
   - App name：和首頁、App Store 名稱完全一致（目前是「Smart Schedule」）。
   - Logo：120×120，用 `public/logo.png`。
   - Application home page：`https://smart-schedules.com/`
   - Application privacy policy link：`https://smart-schedules.com/privacy`
   - Terms of service：留空。這裡的連結必須在授權網域上，所以不能填 Apple 的標準 EULA。
   - Authorized domains：`smart-schedules.com`
   - User support email：下拉選單只會列出登入的帳號和你管理的 Google 群組。要顯示 support@smart-schedules.com，它必須是專案 Owner／Editor 的 Google 帳號或群組。support@ 是 Workspace 帳號，你也用它登入 Google Cloud，所以用它登入、而且它是專案 Owner 或 Editor 時就可以直接選（請在畫面上確認）。
2. **Audience**：發佈（In production）。還在 Testing 時，refresh token 7 天就過期。
3. **Data Access**：加入兩個 calendar scope，各寫一段用途說明。
4. **Verification Center**：送審，附上不公開的 YouTube 示範影片：OAuth 同意畫面（語言設成英文）、新增行程（`calendar.events`）、抽屜列出行事曆（`calendar.calendarlist.readonly`）。
5. 首頁已經符合 Google 的要求：公開、不需登入、在已驗證的網域上、說明 App 做什麼和為什麼用 Google 日曆資料、有明顯的隱私權政策連結和 support@smart-schedules.com，也放了 Limited Use 聲明。隱私權政策第 11 節有 Google 規定的 Limited Use 原文，以及「不用 Google 使用者資料訓練 AI/ML 模型」的承諾。

### 3.7 App Store Connect 和 App

- **Privacy Policy URL**：`https://smart-schedules.com/privacy`。App Store Connect 可以依語言設定，但這一頁本來就有中英文，兩種語言都填同一個網址即可。
- **Support URL**（必填，頁面上必須有聯絡方式）：`https://smart-schedules.com/support`
- **Marketing URL**（選填）：`https://smart-schedules.com/`
- **`project.yml`**：`SSPrivacyURL` 從 `https://example.com/privacy` 改成 `https://smart-schedules.com/privacy`（這個資料夾以外的變更，另外處理）。

### 3.8 support@smart-schedules.com 收信

support@ 是 Google Workspace 的信箱，收信和回信都直接用 Workspace 的 Gmail，**不用 Cloudflare Email Routing**。搬 DNS 時保留 Google 的郵件紀錄（[§3.1 第 0、1 步](#31-網域squarespace--cloudflare一步一步)），Active 後檢查收發（[第 3 步](#3-等-cloudflare-顯示-active)），再完成 DKIM 和 DMARC（[第 4 步](#4-完成-google-的郵件設定dkim-和-dmarc不用-email-routing)），然後才部署網站（第 5 步）。Google 的郵件紀錄一直保留，不要開 Email Routing；要取消 Workspace 前該注意的事也在第 4 步。

### 3.9 如果一定要用傳統 Pages

```sh
W=server/worker/node_modules/.bin/wrangler      # 在 repo 根目錄執行
$W pages project create smart-schedules-site --production-branch main
$W pages deploy site/public --project-name smart-schedules-site --branch main --commit-dirty=true
```

- **第一次部署前先明確建立專案。** 對不存在的專案執行 `pages deploy` 時：在沒有終端機的腳本裡會直接失敗；在一般終端機會問 production branch，預設值是**目前的 git 分支**（不是 `main`），接受預設就會設錯；wrangler 偵測到 AI agent 時，還會改成部署 Worker。
- **每次都加 `--branch main`。** 只有分支等於專案的 production branch 時才是正式部署；不加的話，wrangler 用目前的 git 分支做預覽部署，網域會繼續提供舊版。
- `--commit-dirty=true` 只是不顯示「有未提交變更」的警告。
- 要在 repo 根目錄執行。在 `server/worker` 裡執行時，wrangler 會讀到那裡的 `wrangler.toml`，警告它沒有 `pages_build_output_dir` 然後忽略它，不影響結果但很吵。
- Custom domain 沒有 wrangler 指令，要在控制台設定：Workers & Pages › 專案 › Custom domains › **Set up a custom domain** › `smart-schedules.com` › Activate。www 用同樣的方式，或用 §3.3。
- 傳統 Pages 專案的 `*.pages.dev` 主機名稱也會一直公開。
- `public/404.html` 一定要保留：傳統 Pages 沒有最上層的 `404.html` 時，會把網站當成單頁應用程式，所有不存在的路徑都回首頁。
