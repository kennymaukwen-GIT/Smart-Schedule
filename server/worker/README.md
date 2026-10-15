# Smart Schedule Worker

Smart Schedule 的伺服器端（Cloudflare Worker，TypeScript，**零 runtime dependency**）：

- **Gemini proxy**：Gemini API key 只存在 Worker secret，App 不再內含 key。每個 request 都必須通過 **Apple App Attest**
  （或由 App 為其 extension 申請的 session token）驗證，body 原封不動（byte-for-byte）轉送。
- **Live Activity push-to-start**：iOS 18 無法排程 Live Activity，由 Worker 的 cron 在每個行程的 `triggerAt` 透過 APNs push-to-start 啟動。

| 路徑 | 驗證 | 用途 |
| --- | --- | --- |
| `GET /attest/challenge` | 無（依 IP rate limit） | 發一次性 challenge（32 bytes，standard base64，TTL 300 s） |
| `POST /attest` | 無（依 IP rate limit） | 驗證 App Attest attestation，記住 key |
| `POST /session` | App Attest assertion（或 dev token） | 發 session token 給 App 的 notification content extension |
| `ANY /v1beta/*` | App Attest assertion（或 dev token）；**Session token 只限 `POST /v1beta/models/<SESSION_MODELS>:generateContent`** | 轉送到 `https://generativelanguage.googleapis.com/v1beta/*` |
| `POST /devices/push-to-start` | App Attest assertion（或 dev token） | 存裝置的 push-to-start 註冊（整份取代） |
| cron `* * * * *` | — | 送出到期的 push-to-start |

---

## Apple App Attestation Root CA

`POST /attest` 唯一的 trust anchor 是 Apple 的 **Apple App Attestation Root CA**，已嵌在 `src/apple-root-ca.ts`。

- 來源：<https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem>
- **SHA-256 fingerprint：`1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32`**（notAfter 2045-03-15）。
- 取得方式：由 GitHub Actions runner 從上面的 Apple 網址下載（寫這個 Worker 的環境連不到 apple.com），以 OpenSSL 驗證 subject 與
  self-signature 後用 `PEM_FILE=… EXPECTED_SHA256=… npm run embed-root-ca` 嵌入。我們不會手打或從第三方複製憑證。
- **CI 逐位元組比對**：`.github/workflows/ios.yml` 的「Apple App Attestation Root CA matches Apple's」步驟每次都重新從 Apple 下載，
  與嵌入的憑證比對 DER 的 SHA-256，不同就失敗，所以被換掉或改過的憑證過不了 CI。
- 建議在自己的 Mac 上再核對一次：
  `curl -s https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem | openssl x509 -noout -fingerprint -sha256`

若 Apple 日後換發 root（CI 會失敗），用 `EXPECTED_SHA256=<新 fingerprint> npm run embed-root-ca` 重新嵌入並更新上方 fingerprint。
`scripts/embed-apple-root-ca.sh` 只接受 HTTPS 下載（或 `PEM_FILE=` 指定已從 Apple 下載的檔案），確認只有一張憑證、subject 是
`Apple App Attestation Root CA`、self-signed 且簽章有效，再寫入 `src/apple-root-ca.ts`。`npm run deploy` 會先執行
`scripts/check-root-ca.mjs` 確認憑證存在；萬一缺少，`POST /attest` 一律 fail closed（`500 server_misconfigured`）。

---

## 部署步驟

需要 Node.js ≥ 22.12 與 Cloudflare 帳號（**Workers Paid plan**，理由見「KV 讀寫量」）。

```sh
cd server/worker
npm i
npx wrangler login

# 1. Secrets
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put SS_DEV_TOKEN            # 只有 ALLOW_DEV_TOKEN="true" 的開發部署需要
npx wrangler secret put APNS_PRIVATE_KEY < AuthKey_XXXXXXXXXX.p8

# 2. 編輯 wrangler.toml [vars]：APPLE_TEAM_ID、APNS_KEY_ID、APNS_TEAM_ID、APP_ATTEST_ENV、APNS_ENV …

# 3. 部署（會先檢查 root CA 已嵌入）
npm run deploy
```

**KV namespace**：正式環境的 `[[kv_namespaces]]` 已寫上第一次部署自動建立的 namespace
（`smart-schedule-worker-ss-kv`）的 `id`；`[env.dev]` 只寫 `binding`，第一次 `npm run deploy:dev` 會另外建立一個。
fork 這個 repo 時把正式環境的 `id` 那行刪掉，第一次部署就會在你的帳號建立新的 namespace。

**workers.dev**：`workers_dev = true`（App 用 `https://<name>.<帳號子網域>.workers.dev`），`preview_urls = false`
（每個上傳的版本不會各有一個公開網址）。兩者都寫明，wrangler 就不會再跳警告。`npm run deploy` 會加 `--env=""`
指定部署正式環境（檔案裡有 `[env.dev]` 時，wrangler 不指定環境會警告）。

**驗證 Gemini 金鑰**：`npm run check-key` 會問金鑰（輸入時不顯示，也不會出現在指令列），用 Worker 相同的方式
（`x-goog-api-key` → `generativelanguage.googleapis.com`）打一次，只印 HTTP 狀態、Google 的錯誤代碼和回覆的開頭。
`AQ.` 開頭的新格式金鑰在部分帳號會被 Gemini API 拒絕（`401 ACCESS_TOKEN_TYPE_UNSUPPORTED`），所以部署前先跑一次；
被拒時腳本會再試 Bearer 和 Vertex AI express mode，看出是哪一種金鑰。
`npm run check-key -- --worker` 則經過開發用 Worker（X-Dev-Token）走完整條 App → Worker → Gemini。

**Rate Limiting binding**：`wrangler.toml` 的 `[[ratelimits]]`（`name = "SS_RATE_LIMITER"`、`simple = { limit = 30, period = 60 }`）
是 Cloudflare Workers Rate Limiting：不寫 KV、在同一據點內原子計數。`namespace_id` 是你自選、在帳號內唯一的正整數
（預設 `"1001"`，與其他 Worker 的 rate limiter 衝突時改掉）；`simple.limit` 請與 `RATE_LIMIT_PER_MIN` 保持相同。
沒有這個 binding 時 Worker 會改用 KV 計數（見「Rate limit」）。

部署後，App 的 `SSGeminiBaseURL` 指向 `https://<你的 Worker 網域>/v1beta`，App Attest、session 與 push-to-start 也用同一個網域。
本 repo 不寫死任何網域或 Team ID。

### 開發 / 正式環境

`APP_ATTEST_ENV` 必須對應 App 的 `com.apple.developer.devicecheck.appattest-environment` entitlement，
`APNS_ENV` 必須對應 App 的 `aps-environment`：

| App build | `APP_ATTEST_ENV` | `APNS_ENV` | `ALLOW_DEV_TOKEN` |
| --- | --- | --- | --- |
| Xcode 安裝（development） | `development` | `sandbox` | 可為 `"true"`（Simulator 沒有 App Attest） |
| TestFlight / App Store | `production` | `production` | **必須不是** `"true"` |

開發與正式是兩個不同的 Worker：`wrangler.toml` 的 `[env.dev]` 是 `smart-schedule-worker-dev`（自己的 KV namespace、
rate limiter 與 secrets，`ALLOW_DEV_TOKEN = "true"`、`APP_ATTEST_ENV = "development"`、`APNS_ENV = "sandbox"`、不跑 cron），
正式 Worker 永遠不接受 dev token（`test/config-sync.test.ts` 會檢查）。

### Simulator 用的開發版

Simulator 沒有 App Attest，Debug build 改送 `X-Dev-Token`，只有開發用 Worker 接受：

```sh
cd server/worker
npm run deploy:dev                                   # 建立 smart-schedule-worker-dev 與它的 KV
npx wrangler secret put GEMINI_API_KEY --env dev     # 貼上 Gemini 金鑰
openssl rand -hex 32                                 # 產生一組 dev token，複製起來
npx wrangler secret put SS_DEV_TOKEN --env dev       # 貼上剛才那組
npm run check-key -- --worker                        # 填開發版網址與 dev token，確認整條路通
```

App 端（`Config/Secrets.xcconfig`，git-ignored）只讓 Simulator 用開發版：

```
GEMINI_BASE_URL = https:/$()/smart-schedule-worker.<帳號子網域>.workers.dev/v1beta
GEMINI_BASE_URL[sdk=iphonesimulator*] = https:/$()/smart-schedule-worker-dev.<帳號子網域>.workers.dev/v1beta
SS_DEV_TOKEN[sdk=iphonesimulator*] = <同一組 dev token>
```

Release build 的 `SS_DEV_TOKEN` 一律是空的（`project.yml`），所以 dev token 不會出現在送審的 App 裡。

---

## APNs .p8 設定

1. Apple Developer › Certificates, Identifiers & Profiles › **Keys** › ＋，勾選 **Apple Push Notifications service (APNs)**，建立後下載 `AuthKey_<KEYID>.p8`（只能下載一次，請妥善保存，不要 commit；`.gitignore` 已排除 `*.p8`）。
2. `APNS_KEY_ID` = 該 key 的 Key ID（10 字元）；`APNS_TEAM_ID` = 擁有該 key 的 Team ID。
3. `npx wrangler secret put APNS_PRIVATE_KEY < AuthKey_<KEYID>.p8`（PEM `-----BEGIN PRIVATE KEY-----`，PKCS#8 P-256；若貼成一行含 `\n` 也可）。
4. App ID `com.smartschedule.app` 要啟用 Push Notifications；topic 為 `${APNS_BUNDLE_ID}.push-type.liveactivity`。

Provider token 是 ES256 JWT：header `{"alg":"ES256","kid":APNS_KEY_ID}`、claims `{"iss":APNS_TEAM_ID,"iat":…}`，以 WebCrypto 簽章。
同一個 token 最多重用 50 分鐘（module scope + KV `apns:jwt` 共用；每次 cron 最多產生一個），符合 Apple「20–60 分鐘內更新」的要求；
APNs 回 `ExpiredProviderToken` / `InvalidProviderToken` 時會丟棄快取。

### APNs 必須在已部署的 Worker 上測試

APNs 只接受 HTTP/2。本機 `wrangler dev` 無法可靠地連到 APNs；實務上回報部署到 Cloudflare 後的 `fetch` 可以正常送達。
請在部署後用實機測試 push-to-start（看 Workers Logs 的 `push_to_start_sent` / `apns_rejected` 事件）。
本 repo 的自動測試以 mock fetch 驗證 request 的 URL、headers、JWT 與 payload。

---

## 設定值

| 名稱 | 種類 | 說明 |
| --- | --- | --- |
| `SS_KV` | KV binding | 唯一的 KV namespace |
| `SS_RATE_LIMITER` | Rate Limiting binding | `[[ratelimits]]`，原子計數、不寫 KV；沒有時退回 KV 計數 |
| `GEMINI_API_KEY` | secret | Gemini API key |
| `SS_DEV_TOKEN` | secret | 開發用 token（只有 `ALLOW_DEV_TOKEN === "true"` 才生效，constant-time 比對） |
| `APNS_PRIVATE_KEY` | secret | APNs `.p8` PEM 內容 |
| `APPLE_TEAM_ID` | var | 10 字元 Team ID；appId = `<APPLE_TEAM_ID>.<bundleId>`。空白時 `/attest` 回 500 |
| `BUNDLE_IDS` | var | 允許 attest 的 bundle ID（逗號分隔），預設 `com.smartschedule.app,com.smartschedule.app.notification-content` |
| `APP_ATTEST_ENV` | var | `development`（aaguid `appattestdevelop`）或 `production`（`appattest` + 7 個 0x00） |
| `ALLOW_DEV_TOKEN` | var | 只有字串 `"true"` 會啟用 `X-Dev-Token`（以及 dev 身分申請的 session） |
| `RATE_LIMIT_PER_MIN` | var | 每個身分（attested key / `dev`；session 算在申請它的 key）每分鐘的 request 數，也是 `/attest*` 每個 IP（IPv6 以 /64 計）與每個 (IP, key) 的 Bearer body 讀取上限；須與 `[[ratelimits]]` 的 `simple.limit` 相同；預設 30 |
| `SESSION_TTL_SECONDS` | var | `POST /session` 發出的 token 壽命（秒，≥ 60），預設 `604800`（7 天） |
| `SESSION_MODELS` | var | Session token 可呼叫的模型（逗號分隔，完整 ID，不接受 prefix），預設 `gemini-3.5-flash`。**必須包含所有仍在使用的 App 版本的 `GEMINI_MODEL_ID`**（`Config/Base.xcconfig`）：新 ID 要在送審使用它的 build 之前加入並部署 Worker（App Review 會測 notification extension）；舊 ID 等到沒有受支援的 build 再送它、或 Google 已關閉它時才移除。`test/config-sync.test.ts` 會檢查目前的 `GEMINI_MODEL_ID` 有列在這裡 |
| `SESSION_DAILY_LIMIT` | var | 每個身分每 UTC 日以 session 呼叫 generateContent 的上限，預設 `200`（extension 每次回覆 1–3 次）；Bearer 不受影響 |
| `ATTEST_DAILY_PER_IP` | var | 每個 IP bucket（IPv6 以 /64 計）每 UTC 日**成功** attest 的上限（= 新身分數），預設 `200`（行動網路常有許多使用者共用一個 IPv4） |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | var | APNs token auth |
| `APNS_BUNDLE_ID` | var | 預設 `com.smartschedule.app` |
| `APNS_ENV` | var | `sandbox` → `api.sandbox.push.apple.com`；`production` → `api.push.apple.com` |

---

## HTTP API

錯誤一律是 JSON `{"error":"<code>"}`。

### `GET /attest/challenge`
`200 {"challenge":"<base64 32 bytes>"}`；KV `chal:<challenge>`（TTL 300 s）。

### `POST /attest`
Body `{"keyId","attestation","challenge","bundleId"}`（皆為字串，base64 為 standard base64）。
依 Apple〈Validating apps that connect to your server〉完整驗證：

1. CBOR `{fmt:"apple-appattest", attStmt:{x5c:[credCert, intermediate], receipt}, authData}`；
   credCert → intermediate → 內嵌 Apple root：issuer/subject 串接、ECDSA 簽章（P-256/P-384，SHA-256/SHA-384）、
   有效期間（notBefore 容許 60 s 時鐘誤差）、CA basicConstraints/keyUsage、未處理的 critical extension 一律拒絕。
2. clientDataHash = SHA256(challenge bytes)；nonce = SHA256(authData ‖ clientDataHash)，
   必須等於 credCert extension `1.2.840.113635.100.8.2`（`SEQUENCE { [1] EXPLICIT OCTET STRING }`）。
3. SHA256(credCert 公鑰 65-byte uncompressed point) == keyId。
4. authData rpIdHash == SHA256(appId)；sign count == 0；aaguid 依 `APP_ATTEST_ENV`；credentialId == keyId。

成功：KV `key:<keyId>` = `{publicKey:<base64 65-byte point>, counter:0, appId, createdAt}`（無 TTL）→ `200 {"ok":true}`。
（若同一 keyId 已有紀錄，保留較大的 counter，避免舊 assertion 重新有效。）

| 狀況 | 回應 |
| --- | --- |
| challenge 不存在 / 過期 / 已用過（用一次即刪） | `401 invalid_challenge` |
| bundleId 不在 `BUNDLE_IDS`、任何驗證失敗、任何無法解析的輸入（Worker log 記錄具體原因） | `401 invalid_attestation`（不會是 500） |
| body 不是預期的 JSON | `400 invalid_request` |
| root CA 缺少、`APPLE_TEAM_ID`/`APP_ATTEST_ENV` 設定錯誤 | `500 server_misconfigured` |

### 驗證（其餘路由）

可用的憑證：

- `Authorization: Bearer <base64(keyId 32 bytes ‖ assertion CBOR)>`（所有需驗證的路由）。
  assertion `{signature, authenticatorData}`；clientDataHash = SHA256(原始 request body bytes，空 body 即 SHA256("")）；
  nonce = SHA256(authenticatorData ‖ clientDataHash)；以儲存的 P-256 公鑰驗證 DER ECDSA/SHA-256 簽章；
  rpIdHash == SHA256(appId)；counter（bytes 33–36，big-endian）必須大於儲存值。
- `Authorization: Session <token>`：**只接受 `POST /v1beta/models/<SESSION_MODELS 之一>:generateContent`**（見 `POST /session`）。
  `/v1beta` 下的其他 method / path / model 一律 `403 session_scope`（在查 session、讀 body 之前就決定，不會呼叫 Google）；
  在 `/session`、`/devices/push-to-start` 一律 `401 attestation_required`。
- `X-Dev-Token`：只有 `ALLOW_DEV_TOKEN === "true"` 且等於 `SS_DEV_TOKEN` 才接受（身分 `dev`），否則忽略、改看 `Authorization`。

檢查順序（先做便宜的；未驗證的呼叫者幾乎不花成本，也影響不到別人）：

- **Bearer**：token 格式 → `key:<keyId>` 存在 → assertion 的 CBOR 結構、authenticatorData 長度與 rpIdHash（不需要 body）
  → **body 預算**（見下）→ 讀 body → 簽章與 counter → 寫回 counter，才處理 request。
- **Session**：scope（method、path、model）→ `sess:` 存在且未過期（dev session 另需 dev token 指紋相符）→ 讀 body（上限 512 KB）。
- **Dev**：token 相符 → 讀 body。

讀 body：有 `Content-Length` 時先檢查上限、只配置一次，實際收到的 bytes 比宣告多或少都回 `413`；沒有時（chunked）邊讀邊檢查上限。

**Body 預算（只保護 Bearer 讀 body 這一步）**：以 (client IP bucket, keyId) 為 key，只有 key 存在且 assertion 結構與 rpIdHash 都正確的
Bearer request 才會走到這裡。有 `SS_RATE_LIMITER` 時，每個走到這裡的 request 都算一次（binding 無法「只查不算」，且不寫 KV）；
沒有 binding 時改用 KV `rl:authfail:<ip>:<keyId>:<minute>`，只記讀完 body 後的 401（簽章錯誤、stale counter）。
達到 `RATE_LIMIT_PER_MIN` 後，同一 (IP, key) 本分鐘的 request 在讀 body 前就回 `429`。便宜的拒絕（沒有憑證、格式錯誤、
unknown_key、unknown session）不計數，所以同一個公共 IP（CGNAT、校園、飯店 Wi-Fi）上的垃圾 request 不會把其他使用者鎖在外面；
Session 與 dev 在讀 body 前就已驗證，不經過這個預算。

**Counter 寫回**：寫入前一定重新讀取 `key:<keyId>`（重試時也一樣），只寫入**嚴格大於**目前儲存值的 counter；
若另一個 request 已記錄了相同或更大的 counter，這個 request 回 `401 stale_counter`（client 用新的 assertion 重送即可），
所以 counter 不會倒退。KV 同一個 key 每秒最多寫一次：寫入失敗時約 1.1 s 後重讀再試一次，仍失敗回 `503 server_busy`。
**仍存在的窗口**：KV 沒有交易、也是 eventually consistent，兩個 request 可能在對方寫入前都通過重讀，
或在還沒看到對方寫入的不同據點（最多約 60 s）被處理，所以在這些情況下重放仍可能成功一次。
每個 key 一個 **Durable Object** 才能做到嚴格。

| 狀況 | 回應 |
| --- | --- |
| 沒有可用的憑證（或在不接受 session 的路由用 session） | `401 attestation_required` |
| `key:<keyId>` 不存在（client 應重新 attest） | `401 unknown_key` |
| 簽章 / rpId / 格式錯誤 | `401 invalid_assertion` |
| counter 沒有大於儲存值（含寫回時發現已被其他 request 推進） | `401 stale_counter` |
| Session token 用在 extension 那一個呼叫以外的地方 | `403 session_scope` |
| session token 不存在、格式不對、已過期；dev session 而 dev token 已關閉、換掉或移除 | `401 invalid_session` |
| counter / session / 註冊無法寫入 KV；session / dev 的 KV rate limit 計數寫不進去（`Retry-After: 1`，App 會在 0.8 s、1.6 s 後重試） | `503 server_busy` |
| 身分超過 rate limit、`/attest*` 的 IP 超過、(IP, key) 的 body 預算用完、session 的每日上限、IP 的每日 attest 上限 | `429 rate_limited` + `Retry-After` |
| body 過大或與 `Content-Length` 不符（Bearer / dev 的 Gemini 2 MB、session 的 Gemini 512 KB、push-to-start 1 MB、/session 1 KB、attest 64 KB） | `413 payload_too_large` |

### Rate limit

- **每個身分**（keyId、`dev`；session 算在申請它的 keyId）：先問 `SS_RATE_LIMITER`（key `id:<identity>`，同一據點內原子計數），
  再加上全域的 KV 計數 `rl:<id>:<minute>`。**Session 與 dev 的 KV 寫入是必要的**（即使 binding 已綁定：binding 只在單一據點內計數，
  KV 是唯一的全域上限）：寫不進去（例如 KV 每個 key 每秒一次的限制）就回 `503 server_busy`（`Retry-After: 1`），不會放行未計數的 request，
  所以平行的 burst 在 KV 這層每秒只過得了約一個。用 503 而不是 429，是因為這通常只是同一秒內的寫入碰撞（例如 App 的 Bearer request
  與 extension 的 session request 寫同一個 key，或 Google 回 503 後 0.8 s 的重試），App 會在 0.8 s、1.6 s 後重試，而 429 對 App 是最終錯誤。
  Bearer 的 KV 計數寫入失敗則放行（它本來就被自己的 `key:` counter 寫入限制在約每秒一個）。
- **`/attest/challenge`、`/attest`**：每個 IP bucket（IPv4 為位址本身；**IPv6 為其 /64**，例如 `v6:2001:db8:1:2::/64`，
  因為一台主機至少控制一個 /64）。有 binding 時只用 binding（key `ip:<bucket>`），未驗證的呼叫者不會產生任何 KV 計數寫入；
  沒有 binding 時退回 KV `rl:ip:<bucket>:<minute>`。
- 限制：Rate Limiting binding 依 Cloudflare 文件是每個據點各自計數、允許些許超量；拿到 /48 或 /56 的攻擊者仍可輪換 /64。
  需要更嚴格時，可在 Cloudflare 加上 WAF rate limiting rule（`/attest*` 與 401 回應），或改用每個身分一個 Durable Object。

### `POST /session`（給 notification content extension）

App Attest 在 iOS app extension 中無法使用（`DCAppAttestService.generateKey` 在 extension 會失敗），所以由能 attest 的 App 申請
token，再交給自己的 extension：

1. App 以 Bearer assertion（或 dev token）呼叫 `POST /session`，body 為任意 ≤ 1 KB 的 JSON object（通常是 `{}`）。
2. 回應 `200 {"token":"<base64url 32 random bytes>","expiresAt":"2026-10-22T03:00:00Z"}`（ISO 8601 UTC，壽命 `SESSION_TTL_SECONDS`）。
3. App 把 token 存到 App Group 共用的 Keychain；extension 呼叫 Gemini 時送 `Authorization: Session <token>`。
4. **Scope**：session 只能用於 `POST /v1beta/models/<SESSION_MODELS 之一>:generateContent`（extension 唯一的呼叫），body ≤ 512 KB；
   其他 method、path（files、cachedContents、tunedModels …）、model 或動作（`:predict`、`:predictLongRunning`、`:streamGenerateContent` …）
   一律 `403 session_scope`，不會呼叫 Google（log `session_scope_refused` 會記下被拒的 model，方便發現還在送舊 model 的舊版 App）。
   `SESSION_MODELS` 必須包含**所有仍在使用的 App 版本**的 `GEMINI_MODEL_ID`（逗號分隔）：新 ID 要在送審使用它的 build 之前加入並部署 Worker
   （App Review 會測 notification extension）；舊 ID 等到沒有受支援的 build 再送它、或 Google 已關閉它時才移除。只用完整 ID，不要改成 prefix
   （prefix 會讓外洩的 token 能呼叫任何、包括更貴的模型）。
7. 每個身分每 UTC 日以 session 呼叫的次數上限為 `SESSION_DAILY_LIMIT`（預設 200），超過回 `429 rate_limited`（`Retry-After` = 到下一個 UTC 日的秒數）。
5. rate limit 與申請它的 keyId **共用同一個桶**；轉送給 Google 前移除 `Authorization`。
6. token 失效（`401 invalid_session`）時 extension 無法自行更新，App 在剩不到 3 天時重新申請（`AppAttestClient.sessionRenewal`）。

伺服器只存 token 的雜湊：`sess:<hex SHA-256(token)>` = `{id, appId, expiresAt, devKey?}`（`id` 為 keyId 或 `dev`、`appId` 對 dev 為 null；KV TTL = 壽命），
查詢時也會檢查 `expiresAt`（不依賴 KV 何時真正清除）。

**誰拿得到 token**：App 沒有做 certificate pinning，裝置的擁有者裝上自己的 root CA（Proxyman、Charles）就能從 extension 的 request
讀到 session token，不需要 jailbreak，而且 App 會自動續期。所以 token 的 scope 才限縮到上面那一個呼叫：每個 token 剩下的曝險是
**以其身分、在該身分的 rate limit（每分鐘 `RATE_LIMIT_PER_MIN`、每日 `SESSION_DAILY_LIMIT`）之內，對允許的模型呼叫 `generateContent`**（body ≤ 512 KB）。
Bearer 不受影響：它綁定單一 body 與只能用一次的 counter。要提早作廢可刪除對應的 `sess:` key；每次 `/session` 都產生新的 token，舊的照常到期。

**每個身分的上限並不限制一台裝置**：裝置擁有者可以自己產生更多身分（重裝 App、「清除所有資料」、或用 proxy 偽造 `401 unknown_key`
讓 App 重新 attest），每個新身分都能拿到新的 7 天 session 與自己的額度；伺服器無法把不同的 key 連到同一台裝置。目前的緩解：

- 每個身分每日的 session 上限（`SESSION_DAILY_LIMIT`）。
- 每個 IP bucket 每日成功 attest 的上限（`ATTEST_DAILY_PER_IP`），提高大量產生身分的成本（換 IP 仍可繞過）。
- **營運端**：在 Gemini 的 Google Cloud 專案設定 quota 與預算上限，並對 Worker log 中 `key_attested`、`session_issued` 的速率設警示。
- **真正的解法（尚未實作）**：Apple 的 App Attest receipt **risk metric**（該裝置 30 天內為此 App attest 的 key 數），用 DeviceCheck key
  向 Apple 取得，對 key 數過多的裝置拒絕 `/session`（或 `/attest`）。需要新的 secret，屬於部署決策。

**Dev session**：記錄中存 dev token 的指紋（`devKey` = SHA-256(SS_DEV_TOKEN) 的前 16 個 hex）。`ALLOW_DEV_TOKEN` 不是 `"true"`、
`SS_DEV_TOKEN` 換掉或移除時，既有的 dev session 立即失效；沒有指紋的 dev 記錄一律拒絕。注意：若之後以**同一個** token 重新開啟，
尚未到期的 dev session 會再度有效，要永久作廢請換 token。

### `ANY /v1beta/*`
轉送到 `https://generativelanguage.googleapis.com/v1beta/*`：保留 path 與 query（移除所有 `key` 參數，其餘逐字保留）、
同一 method、**與驗證時雜湊的完全相同的 body bytes**（不解析、不修改 `generationConfig` 或任何欄位）、保留 content-type，
加上 `x-goog-api-key`；移除 `Authorization`（Bearer 與 Session）、`X-Dev-Token`、`Cookie`、client 帶來的 `x-goog-api-key`、
hop-by-hop headers、**所有 `cf-*` headers**（`cf-connecting-ip`、`cf-ipcountry`、`cf-ray` …）與 `x-forwarded-for` 等，不把使用者 IP 或位置傳給 Google。
回傳 upstream 的 status、body（串流，SSE 可用）與 content-type。上游連不到時 `502 upstream_unavailable`。
Bearer 與 dev 依合約是完整的 `/v1beta/*` passthrough（body 上限 2 MB；App 送的是文字 prompt）；Session 只限上面的 scope（512 KB）。

### `POST /devices/push-to-start`
Body（Swift `JSONEncoder` `.iso8601` + `.sortedKeys`）：
`{"deviceID","token":"<hex>"|null,"events":[{"eventID","title","eventStart","leadTime","triggerAt","attributesJSON","contentStateJSON"}]}`

**整份 body 的問題** → `400 invalid_registration`：不是 JSON object；deviceID 不是 ≤ 64 個 `[A-Za-z0-9-]`；
token 不是 null（**或省略**：Swift 會省略 nil Optional）也不是 ≤ 200 hex；events 不是陣列或超過 50 個。

**單一 event 的問題只會略過那個 event**（log 記錄 index 與原因，不記內容），其他照常儲存，所以一個奇怪的行事曆項目不會擋住整次上傳：
eventID 須為非空、≤ 1024 bytes、不含控制字元；`attributesJSON` / `contentStateJSON` 各 ≤ 4096 bytes 且是 JSON object；
`eventStart` / `triggerAt` 為 ISO 8601，`triggerAt` 在 [now − 1 h, now + 49 h]；leadTime 為 0–1440 的整數。
（接受過去一小時內的 triggerAt，所以 iOS 18 client 重新上傳時保留「trigger 剛過、App 沒有自己啟動」的 event，cron 在 m+1 / m+2 仍會重試它們。）
**title 超過 200 個 code points 時在伺服器端截斷**，不會被拒絕。

整份取代：`p2s:<deviceID>` = `{token, keyId, appId, events, updatedAt}`（TTL 3 天，只存上列欄位，不存 notes / locations；
`keyId`/`appId` 是最後寫入者，供 log 與下面的檢查）。每個 event 一個索引
`due:<YYYYMMDDHHmm>:<deviceID>:<eventHash>`（`eventHash` = eventID 的 SHA-256 hex，所以長的、含 `:` 的 EventKit / Google ID 都可以；
真正的 eventID 留在註冊內容裡；TTL 到 triggerAt + 1 h，最少 60 s；同一 (eventID, triggerAt) 已索引過就不重寫）。
成功 `200 {"ok":true,"events":<實際儲存的數量>}`；KV 拒絕寫入（例如同一裝置一秒內上傳兩次）→ `503 server_busy`，client 稍後重送即可。

**誰可以覆寫一個 deviceID**：隨機產生的 122-bit deviceID 本身就是 capability。同一個 App（相同 appId）的任何 attested key
都可以覆寫 `p2s:<deviceID>`，所以 App Attest key 輪替、或從備份還原到新手機後重新 attest，都不會把裝置鎖在外面（log `registration_rebound`）。
只有在 dev 身分與 attested 身分互相覆寫、或 appId 不同時才回 `403 forbidden`。

> Client 注意：deviceID 要長期保留；不要因為換了 App Attest key 或收到錯誤就換 deviceID。只有在 client 自己的還原 / 遺失 key 流程中
> （例如 App Group 裡的 deviceID 已不存在）才產生新的 deviceID。`403` 代表 dev / attested 或 App 不符，是設定問題。

### Cron（每分鐘）
對 now − 2 min 到 now 的每一分鐘 m，列出 `due:<m>:`（之後的分鐘不可能已到期，所以不列），對每筆重新讀取目前的 `p2s:<deviceID>`，
只處理 eventID 雜湊相同且 `triggerAt` 落在 m 的 event（否則代表已刪除或移動，略過）。**`triggerAt ≤ now` 才送**（不會提早），
所以實際送出時間是 triggerAt 之後的第一次 cron（最多晚約 60 s）。以下情況略過：token 為 null / 無效 / 等於 `p2sdead:<deviceID>`；
`sent:<deviceID>:<eventHash>:<triggerAt s>` 已存在；`claim:<deviceID>:<eventHash>:<triggerAt s>` 已存在（另一個 cron 正在送）。

- 送出前寫入 claim（**TTL 300 s**，比整個視窗長：最後一次重新檢查 minute m 的是 m+2 那次 cron），最多 **10 個 APNs request 同時進行**，
  叢集在同一分鐘的大量事件也能在 60 s 內送完。
- APNs 200 → 寫 sent marker（TTL 3 天；與註冊分開存，所以覆寫註冊不會遺失）並刪除 claim；若 sent marker 寫入失敗則保留 claim，
  它會一直擋到視窗結束，不會在 m+1 或 m+2 重送。
- 寫了 claim 之後才中斷的 cron（或 claim 刪除失敗）在這個視窗內**不會重試**：設計上是「最多一次」，寧可漏送也不重送。
- 410 Unregistered 或 400 BadDeviceToken → 寫 `p2sdead:<deviceID>` = 失敗的 token（TTL 3 天）。cron **從不改寫 `p2s:`**，
  所以不會蓋掉裝置剛上傳的新註冊；之後帶相同 token 的註冊會被略過，換了新 token 就恢復。
- 其他失敗（含網路錯誤）→ 刪除 claim、記 log，之後每分鐘重試直到該分鐘離開視窗。
- 每個事件各自 try/catch：一筆的 KV 錯誤或網路錯誤不會中斷整個 cron。
- Payload 超過 4096 bytes → 記 log 並略過。

**仍存在的競爭**：claim 與 sent marker 都在 eventually consistent 的 KV，兩個重疊、且在不同據點執行的 cron 可能還看不到對方的 claim 而都送出（罕見）。
每個裝置一個 **Durable Object** 才能嚴格保證只送一次。

APNs request：`POST https://<host>/3/device/<token>`，headers `authorization: bearer <JWT>`、`apns-push-type: liveactivity`、
`apns-topic: <APNS_BUNDLE_ID>.push-type.liveactivity`、`apns-priority: 10`、**`apns-expiration: <eventStart epoch s>`**
（裝置離線時 APNs 最多保留到行程開始，之後丟棄）、`content-type: application/json`。Payload：

```json
{"aps":{"timestamp":<now s>,"event":"start","attributes-type":"ScheduleActivityAttributes",
 "attributes":<attributesJSON>,"content-state":<contentStateJSON>,"stale-date":<eventStart epoch s>,
 "alert":{"title":<title>,"body":{"loc-key":"Starts in %@ min","loc-args":["<leadTime>"]}}}}
```

`attributes` 與 `content-state` 是 client 送來的 JSON **逐字嵌入**（已驗證為單一 JSON object），不經 parse/re-encode，
所以日期維持 Swift 預設 `JSONEncoder` 的格式（自 2001-01-01 起的秒數），數字格式也不會改變。

---

## KV 資料配置、一致性與讀寫量

| Key | 內容 | TTL |
| --- | --- | --- |
| `chal:<challenge>` | 一次性 challenge | 300 s |
| `key:<keyId>` | 公鑰、counter、appId、createdAt | 無 |
| `sess:<hex SHA-256(token)>` | session：id、appId、expiresAt、dev 的 devKey | session 壽命 |
| `rl:<id>:<epochMinute>` | 每個身分的 rate limit 計數（id = keyId / `dev`） | 120 s |
| `rl:ip:<bucket>:<epochMinute>` | `/attest*` 的 IP 計數（**只在沒有 `SS_RATE_LIMITER` 時**） | 120 s |
| `rl:authfail:<bucket>:<keyId>:<epochMinute>` | Bearer 讀 body 後的失敗次數（**只在沒有 `SS_RATE_LIMITER` 時**） | 120 s |
| `rl:sday:<id>:<YYYYMMDD>` | 該身分當日以 session 呼叫的次數 | 2 天 |
| `rl:attestday:<bucket>:<YYYYMMDD>` | 該 IP bucket 當日成功 attest 的次數 | 2 天 |
| `p2s:<deviceID>` | push-to-start 註冊 | 3 天 |
| `p2sdead:<deviceID>` | APNs 拒絕的 push token | 3 天 |
| `due:<YYYYMMDDHHmm>:<deviceID>:<eventHash>` | cron 索引 | triggerAt + 1 h |
| `claim:<deviceID>:<eventHash>:<triggerAt s>` | 送出中的標記 | 300 s |
| `sent:<deviceID>:<eventHash>:<triggerAt s>` | 已送出標記 | 3 天 |
| `apns:jwt` | 共用的 APNs provider token | ≤ 50 min |

### 一致性（eventually consistent）

Workers KV 是 eventually consistent：寫入在其他 Cloudflare 據點可能要 60 秒（或更久）才看得到，而且沒有交易。因此：

- **Assertion counter**：寫入前重讀並拒絕不前進的 counter，counter 不會倒退；但兩個並行 request 或跨據點的重放，在上述窗口內仍可能各被接受一次。
- **Challenge 單次使用**：刪除也需要傳播，極短時間內在不同據點重用同一 challenge 理論上可能。
- **KV 的 rate limit 計數**：read-modify-write，並行與跨據點時會少算，是近似值；所以前面還有原子計數的 Rate Limiting binding，
  而且 session / dev 的計數寫入失敗時直接拒絕。binding 本身則是每個據點各自計數。
- **推播只送一次**：靠 claim 與 sent marker，跨據點重疊的 cron 仍可能重複送出（罕見）。
- KV 同一個 key 每秒最多寫一次：counter 寫入會重試一次，註冊、session 寫入失敗回 `503 server_busy`；session / dev 的 rate limit 計數寫入失敗也回 `503 server_busy`（`Retry-After: 1`），Bearer 的則忽略。

需要嚴格一致（counter 嚴格遞增、challenge 嚴格單次、精確 rate limit、確保只送一次）時，應改用 **Durable Objects**
（例如每個 keyId / deviceID 一個 object），它提供單一執行緒、strongly consistent 的儲存。

### 讀寫量與方案

- Assertion 驗證的 request：**2 次寫入**（`key:` counter + `rl:` 計數）、3 次讀取（`key:` 兩次、`rl:`）；沒有 binding 時再加 1 次讀取（body 預算）。
- Session 驗證的 request：2 次寫入（`rl:`、`rl:sday:`）、3 次讀取（`sess:`、`rl:`、`rl:sday:`）。`/session` 另加 1 次 `sess:` 寫入。
- 失敗的 request：便宜的拒絕只有 1 次讀取、不寫入；沒有 binding 時，讀完 body 才失敗的 Bearer 另加 1 讀 1 寫（`rl:authfail:`）。
- `/attest/challenge` 1 次寫入（`chal:`）＋ 1 次讀取（每日 attest 計數）；`/attest` 1 次寫入 + 1 次刪除，成功時再加 1 讀 1 寫（`rl:attestday:`）；
  沒有 binding 時各再加 1 次 `rl:ip:` 寫入。
- Rate Limiting binding 的呼叫不算 KV 讀寫。
- 每次 push-to-start 註冊：1 次寫入 `p2s:`，加上每個「新的」(eventID, triggerAt) 1 次 `due:` 寫入（最多 50）。
- 每則送出的推播：claim 寫入 + sent 寫入 + claim 刪除，另有數次讀取；JWT 每 50 分鐘 1 次寫入。
- Cron 每分鐘 **3 次 KV list**（約 4,320 次/天）。

Workers Free plan 的 KV 額度是每天 1,000 次寫入、1,000 次 list，**光是 cron 的 list 就超過**，請使用 Workers Paid plan
（含每月百萬次等級的讀寫/list 額度）。上線前請依實際使用者數估算費用。

---

## 安全設計重點

- 不含任何 runtime dependency；CBOR（`src/cbor.ts`）與 DER/X.509（`src/der.ts`、`src/x509.ts`）為小型手寫、嚴格的 parser，方便稽核。
- Trust anchor 只有內嵌、CI 逐位元組比對過的 Apple root，client 送來的憑證鏈只用於被驗證；沒有任何「略過驗證」的路徑。
  解析 attestation 時任何非預期的例外都轉成 `401 invalid_attestation`，惡意輸入不會造成 500。
- 未驗證的呼叫者在讀 body 之前就會被擋下（憑證、key、assertion 結構與 rpId 先檢查；Bearer 讀 body 另有每個 (IP, key) 的預算），
  而且影響不到同一 IP 上的其他使用者；有 Rate Limiting binding 時，未驗證的呼叫者不會造成 KV 計數寫入。
- App Attest 驗證失敗只回通用錯誤碼，具體原因只寫進 Worker log；log 不含 secrets、push token、session token、event 標題、request body 或 client IP。
- `X-Dev-Token` 只有 `ALLOW_DEV_TOKEN` 恰為 `"true"` 且 `SS_DEV_TOKEN` 非空時才有效，以 SHA-256 digest 做 constant-time 比對。
- Session token 只存雜湊；裝置擁有者讀得到它，所以只限 extension 那一個呼叫（`POST …/models/<SESSION_MODELS>:generateContent`、≤ 512 KB），
  並與申請者共用 rate limit（binding + 寫入必要的 KV 計數）與每日上限。這些都是**每個身分**的上限；裝置擁有者能自己產生新身分，
  所以還需要營運端的 Gemini quota / 預算上限與警示（見 `POST /session`）。dev session 綁定目前的 dev token。
- 已知限制：若 Apple 未來在 App Attest 憑證加入本 verifier 不認得的 critical extension，驗證會 fail closed（log 會寫出 OID）。
- Gemini proxy 對 Bearer / dev 依合約開放整個 `/v1beta/*`（濫用需要 jailbreak 才能產生 assertion）；若只需要
  `models/*:generateContent`，也可以把 Bearer 收窄到同樣的範圍（屬於合約變更）。

---

## 開發

```sh
npm test          # node:test（Node 內建 type stripping，免額外 test runner）
npm run typecheck # tsc：src 對 @cloudflare/workers-types、tests 另加 @types/node
npm run dev       # wrangler dev（本機 KV；本機連不到 APNs）
```

測試涵蓋：CBOR（RFC 8949 範例、以獨立 encoder `cborg` 交叉驗證、各種錯誤輸入）；DER/X.509（與 OpenSSL `node:crypto` 交叉比對、截斷的憑證）；
以測試中產生的 root/intermediate/leaf 憑證鏈（`@peculiar/x509`，注入 verifier 取代 Apple root）做完整 attestation 成功案例，
以及 nonce、appId、keyId、counter、aaguid、credentialId 錯誤、指向其他 root、冒名 intermediate、**由其他 key 簽的 credential certificate**、
過期/尚未生效憑證、非預期例外等失敗案例；assertion（成功、簽章錯誤、stale counter、錯誤 rpId）與 counter 不倒退（含重試）；
body 上限與 `Content-Length` 不符、讀 body 前就拒絕；每個 (IP, key) 的 body 預算（binding 與 KV 兩種）、共用 IP 上的垃圾不影響合法使用者；
IPv6 /64 bucket；dev token；rate limit 429（含 100 個平行 session request 的 burst，binding 與 KV 兩種）；KV 寫入碰撞回 503 而非 429
（與 App 的 Bearer 寫入、Google 503 後的重試）；session 每日上限；每個 IP bucket 每日 attest 上限；`GEMINI_MODEL_ID` 必須列在 `SESSION_MODELS`
（`test/config-sync.test.ts` 讀 `Config/Base.xcconfig`）；session（發放、scope：其他模型、
`:predict` / `:predictLongRunning`、files、cachedContents、GET /v1beta/models 皆 403 且不呼叫上游、512 KB 上限、其他路由拒絕、過期、
未知 token、與 keyId 共用 rate limit、dev session 隨 dev token 輪替或關閉而失效）；Gemini proxy（body bytes 完全相同、加 key、移除認證 headers、`cf-*` 與 `key` 參數）；
push-to-start 驗證（整份 vs 單一 event、title 截斷、長 eventID）、整份取代、sent marker 在覆寫後仍保留、同 App 換 key 可接手、dev / 不同 App 回 403；
cron（triggerAt 才送、只送一次、claim（含 m+2 不重送）、略過刪除/移動的事件、`p2sdead`、不覆寫新註冊、重試視窗、單筆失敗隔離、最多 10 個並行）；
APNs payload 與 headers（含 `apns-expiration`）；JWT ES256 以公鑰驗證。

## 檔案結構

```
src/
  index.ts            router、fetch/scheduled 入口、可注入的 deps（clock、fetch、root CA）
  env.ts              Env 型別與設定解析
  http.ts             JSON 回應、錯誤、body 讀取與大小限制、log
  encoding.ts         base64 / hex / SHA-256 / constant-time 比較
  cbor.ts             CBOR decoder
  der.ts              DER reader、ECDSA DER → raw
  x509.ts             X.509 parsing 與 chain 驗證
  apple-root-ca.ts    內嵌的 Apple App Attestation Root CA（由 scripts/embed-apple-root-ca.sh 產生）
  attestation.ts      App Attest attestation 驗證
  assertion.ts        App Attest assertion 驗證（結構/rpId 與簽章/counter 分兩步）
  attest-routes.ts    /attest/challenge、/attest
  auth.ts             驗證（assertion / session scope / dev token）與 counter 寫回
  ratelimit.ts        rate limit（Rate Limiting binding + KV）、IPv6 /64 bucket、Bearer body 預算
  session.ts          /session 與 session token 查詢
  gemini.ts           Gemini proxy
  registration.ts     /devices/push-to-start
  cron.ts             每分鐘的 push-to-start 排程
  apns.ts             APNs request 與 payload
  jwt.ts              APNs provider JWT（ES256）
scripts/
  embed-apple-root-ca.sh   從 Apple 下載並嵌入 root CA
  check-root-ca.mjs        部署前檢查 root CA 已嵌入
test/                      node:test 測試與 helpers
```
