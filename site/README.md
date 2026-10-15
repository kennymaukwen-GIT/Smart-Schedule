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
| `[郵件服務提供者 / Email provider]` | `privacy.html` 第 12 節（中英文各一次） | Email Routing 轉寄目的地信箱的服務商名稱（例如公司名稱），以及寄出回信用的服務。兩者不同時，各列一項。要選有資料處理條款（DPA）的服務，因為第 12 節寫了「依契約或其本身的條款，以不低於本政策的程度保護你的資料」。不要寫任何個人 email 地址 |

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
5. **support@smart-schedules.com 要真的收得到信，而且收信和回信的服務要寫進政策。** 發佈前先完成 [§3.8](#38-supportsmart-schedulescom-收信) 的 Email Routing，再把轉寄目的地信箱的服務商（和寄回信用的服務，如果不同）填進政策第 12 節的 `[郵件服務提供者 / Email provider]`（見 §1）。政策第 9、12 節寫的是 Cloudflare Email Routing；如果改用別的收信方式，這兩節要改。
6. **1.0 沒有 App 內購買。** 政策第 7 節「購買」寫 1.0 沒有任何 App 內購買或訂閱、App 不查詢購買記錄，第 12 節 Apple 那一項沒有「App 內購買」；支援頁的常見問題只留一題「有 App 內購買或訂閱嗎？」（`#zh-purchases`、`#en-purchases`），回答「沒有」。這要和 `AppConstants.subscriptionsEnabled = false`、App Store Connect 不附加任何購買項目一致。之後的版本開始賣 Smart Schedule Pro 時，在同一次發佈改回（舊的文字在 git 歷史裡）：政策第 7 節（由 Apple 銷售和收費、我們收不到付款資料、App 在 iPhone 上確認訂閱、清除資料不影響購買）和第 12 節的「App 內購買」；支援頁的「怎麼取消訂閱？」「怎麼回復購買項目？」（頭像 › 管理訂閱／回復購買項目、期間結束 24 小時前取消、退款到 reportaproblem.apple.com）、「多久會回覆」和「怎麼刪除我的資料？」裡訂閱的那一句，以及支援頁的 meta description。
7. **上架地區：1.0 不在歐洲經濟區和瑞士上架**（App Store Connect › 價格與供應狀況取消 27 個歐盟會員國，加上挪威、冰島、列支敦斯登和瑞士；**英國**和其他地區照常上架）。政策照仍在上架範圍內的地區寫：第 1 節用「英國 GDPR 等個資法」的用語，第 15 節的地區舉例是英國、美國加州和台灣，申訴機關舉英國的 ICO，法律依據的標題是「適用英國 GDPR 或類似法律時」，第 17 節寫英國使用者適用的 DPF 英國延伸。權利（查詢、更正、刪除、限制、反對、可攜、撤回同意）和法律依據的內容不變，英國 GDPR 一樣適用。
   - **歐洲經濟區和瑞士的代表（GDPR 第 27 條、瑞士 FADP 第 14 條）：排除期間不需要。** 之後的版本加入這些 storefront 前，要指定代表、把名稱和郵寄地址寫進政策第 1、19 節（中英文），並把第 1、15 節的法規、地區舉例和申訴機關（挪威 Datatilsynet、冰島 Persónuvernd、瑞士 FDPIC 等）加回去。
   - **英國代表（英國 GDPR 第 27 條）：英國照常上架，所以仍然要處理。** 豁免只適用於「偶發」而且低風險的處理；Smart Schedule 持續處理使用者資料（伺服器儲存、沒有到期時間的 App Attest 記錄、轉送給 AI），不算偶發。除非開發者在英國設有據點，上架前要指定英國代表，並把名稱和郵寄地址寫進政策第 1、19 節（中英文）；不想指定，就要在 1.0 也排除英國。
   - **挪威、冰島、列支敦斯登和瑞士不是歐盟**，只取消歐盟 storefront 不會排除它們，所以要另外勾掉。
8. **App 名稱。** 首頁標題是「Smart Schedule」。如果 App Store 名稱因為撞名改成別的，首頁、Google OAuth 的 App name 和 App Store 名稱三者要一致。
9. App 上架後，在首頁加上 App Store 連結。

## 3. 部署

以下都還沒做。所有指令都在 repo 根目錄執行，用 `server/worker` 已經裝好的 wrangler，`site/` 不需要 `package.json`。

### 3.1 先把網域加進 Cloudflare（控制台）

1. Cloudflare 控制台 › Domains › **Onboard a domain** › `smart-schedules.com` › Free 方案。要用**和 `server/worker` 同一個帳號**。
2. 到網域註冊商把 nameserver 換成 Cloudflare 給的兩個，等 zone 顯示 **Active**。根網域（apex）要接 Worker 或 Pages，這個 zone 必須在同一個帳號裡而且是 Active。如果網域是在 Cloudflare Registrar 買的，nameserver 已經是 Cloudflare 的。
3. DNS › Records：刪掉快速掃描匯入的 `@` 和 `www` 的 **A、AAAA、CNAME** 紀錄（例如註冊商的停放頁）。已有 CNAME 的主機名稱不能建立 Custom Domain。MX 和 TXT 紀錄保留。
4. SSL/TLS › Edge Certificates：打開 **Always Use HTTPS**。

### 3.2 本機預覽與部署

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

Google OAuth 的品牌驗證要求首頁和隱私權政策所在的網域已經驗證，而且驗證的人是 OAuth 專案的 Owner 或 Editor。

1. 用一個在 Google Cloud 專案裡是 **Owner 或 Editor** 的 Google 帳號登入。
2. 到 https://search.google.com/search-console › 新增資源 › 選 **網域（Domain）** › 輸入 `smart-schedules.com` › 複製 `google-site-verification=…` 那串文字。
3. Cloudflare › DNS › Add record：類型 `TXT`、名稱 `@`、內容貼上剛才的文字（TXT 紀錄只會是 DNS only，不會 proxied）。
4. 回到 Search Console 按「驗證」。DNS 生效可能要幾分鐘到幾小時，失敗就稍後再按。
5. **這筆 TXT 紀錄要永久保留**，刪掉會失去驗證。它可以和 Email Routing 的 SPF TXT 紀錄並存；SPF（`v=spf1`）紀錄只能有一筆。

### 3.6 Google Auth Platform（Google Cloud 控制台）

`calendar.events` 和 `calendar.calendarlist.readonly` 是敏感（sensitive）scope，不是受限（restricted）scope：要過品牌驗證和敏感 scope 審查。審查可能要好幾週，而且只依賴這個網站，不必等 Apple 開發者帳號，所以網站上線後就盡快送。

1. **Branding**：
   - App name：和首頁、App Store 名稱完全一致（目前是「Smart Schedule」）。
   - Logo：120×120，用 `public/logo.png`。
   - Application home page：`https://smart-schedules.com/`
   - Application privacy policy link：`https://smart-schedules.com/privacy`
   - Terms of service：留空。這裡的連結必須在授權網域上，所以不能填 Apple 的標準 EULA。
   - Authorized domains：`smart-schedules.com`
   - User support email：下拉選單只會列出登入的帳號和你管理的 Google 群組。要顯示 support@smart-schedules.com，它必須是專案 Owner／Editor 的 Google 帳號或群組，否則會顯示你自己的 Google 帳號。
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

1. Cloudflare › Email › **Email Routing** › 新增 `support@` › 轉寄到你自己的信箱（要先驗證那個信箱）。Cloudflare 會自動加上 MX 和 SPF 紀錄。
2. Email Routing 只負責收信。要用 support@smart-schedules.com 寄出回信，需要另外設定寄信服務。

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
