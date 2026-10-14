# Smart Schedule Worker

Smart Schedule 的伺服器端（Cloudflare Worker，TypeScript，**零 runtime dependency**）：

- **Gemini proxy**：Gemini API key 只存在 Worker secret，App 不再內含 key。每個 request 都必須通過 **Apple App Attest** 驗證，body 原封不動（byte-for-byte）轉送。
- **Live Activity push-to-start**：iOS 18 無法排程 Live Activity，由 Worker 的 cron 在每個行程的 `triggerAt` 透過 APNs push-to-start 啟動。

| 路徑 | 驗證 | 用途 |
| --- | --- | --- |
| `GET /attest/challenge` | 無（依 IP rate limit） | 發一次性 challenge（32 bytes，standard base64，TTL 300 s） |
| `POST /attest` | 無（依 IP rate limit） | 驗證 App Attest attestation，記住 key |
| `ANY /v1beta/*` | App Attest assertion | 轉送到 `https://generativelanguage.googleapis.com/v1beta/*` |
| `POST /devices/push-to-start` | App Attest assertion | 存裝置的 push-to-start 註冊（整份取代） |
| cron `* * * * *` | — | 送出到期的 push-to-start |

---

## ⚠️ Apple App Attestation Root CA（部署前必做）

`POST /attest` 唯一的 trust anchor 是 Apple 的 **Apple App Attestation Root CA**，必須嵌在原始碼中
（`src/apple-root-ca.ts`）。

- 來源：<https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem>
- **SHA-256 fingerprint：尚未記錄** ← 執行下面的 `npm run embed-root-ca` 後，把輸出的 fingerprint 填在這裡。

撰寫這個 Worker 的環境無法連到 `www.apple.com`（egress policy 拒絕連線），因此憑證**尚未嵌入**；我們不會手打或從第三方複製憑證。
在嵌入之前，`POST /attest` 一律 fail closed（`500 server_misconfigured`，不接受任何 attestation），`npm run deploy` 也會拒絕部署。

```sh
npm run embed-root-ca
# 建議：用另一個獨立來源（例如另一台電腦/網路下載的同一檔案）取得 fingerprint 後一併驗證：
EXPECTED_SHA256=AA:BB:... npm run embed-root-ca
```

`scripts/embed-apple-root-ca.sh` 會：以 HTTPS（`curl --proto =https`）從 Apple 下載 → 確認只有一張憑證、subject 是
`Apple App Attestation Root CA`、self-signed 且簽章有效 → 經 OpenSSL 重新輸出 PEM → 寫入 `src/apple-root-ca.ts`（註解內含來源、下載時間、subject、notAfter、SHA-256 fingerprint）→ 印出 fingerprint。
請把 fingerprint 記錄到上方，並 commit `src/apple-root-ca.ts`。

---

## 部署步驟

需要 Node.js ≥ 22.12 與 Cloudflare 帳號（**Workers Paid plan**，理由見「KV 寫入量」）。

```sh
cd server/worker
npm i
npx wrangler login

# 1. KV namespace（單一 namespace，以 key prefix 區分用途）
npx wrangler kv namespace create SS_KV
#    把輸出的 id 貼到 wrangler.toml 的 [[kv_namespaces]] id = "..."（空白時 wrangler 會拒絕載入設定）

# 2. Secrets
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put SS_DEV_TOKEN            # 只有 ALLOW_DEV_TOKEN="true" 的開發部署需要
npx wrangler secret put APNS_PRIVATE_KEY < AuthKey_XXXXXXXXXX.p8

# 3. 編輯 wrangler.toml [vars]：APPLE_TEAM_ID、APNS_KEY_ID、APNS_TEAM_ID、APP_ATTEST_ENV、APNS_ENV …

# 4. 嵌入 Apple root CA（見上一節）
npm run embed-root-ca

# 5. 部署（會先檢查 root CA 已嵌入）
npm run deploy
```

部署後，App 的 `SSGeminiBaseURL` 指向 `https://<你的 Worker 網域>/v1beta`，App Attest 與 push-to-start 也用同一個網域。
本 repo 不寫死任何網域或 Team ID。

### 開發 / 正式環境

`APP_ATTEST_ENV` 必須對應 App 的 `com.apple.developer.devicecheck.appattest-environment` entitlement，
`APNS_ENV` 必須對應 App 的 `aps-environment`：

| App build | `APP_ATTEST_ENV` | `APNS_ENV` | `ALLOW_DEV_TOKEN` |
| --- | --- | --- | --- |
| Xcode 安裝（development） | `development` | `sandbox` | 可為 `"true"`（Simulator 沒有 App Attest） |
| TestFlight / App Store | `production` | `production` | **必須不是** `"true"` |

建議開發與正式用兩個不同的 Worker（不同 `name`、不同 KV namespace、不同 secrets），不要在正式 Worker 開啟 dev token。

---

## APNs .p8 設定

1. Apple Developer › Certificates, Identifiers & Profiles › **Keys** › ＋，勾選 **Apple Push Notifications service (APNs)**，建立後下載 `AuthKey_<KEYID>.p8`（只能下載一次，請妥善保存，不要 commit；`.gitignore` 已排除 `*.p8`）。
2. `APNS_KEY_ID` = 該 key 的 Key ID（10 字元）；`APNS_TEAM_ID` = 擁有該 key 的 Team ID。
3. `npx wrangler secret put APNS_PRIVATE_KEY < AuthKey_<KEYID>.p8`（PEM `-----BEGIN PRIVATE KEY-----`，PKCS#8 P-256；若貼成一行含 `\n` 也可）。
4. App ID `com.smartschedule.app` 要啟用 Push Notifications；topic 為 `${APNS_BUNDLE_ID}.push-type.liveactivity`。

Provider token 是 ES256 JWT：header `{"alg":"ES256","kid":APNS_KEY_ID}`、claims `{"iss":APNS_TEAM_ID,"iat":…}`，以 WebCrypto 簽章。
同一個 token 最多重用 50 分鐘（module scope + KV `apns:jwt` 共用），符合 Apple「20–60 分鐘內更新」的要求；APNs 回
`ExpiredProviderToken` / `InvalidProviderToken` 時會丟棄快取。

### APNs 必須在已部署的 Worker 上測試

APNs 只接受 HTTP/2。本機 `wrangler dev` 無法可靠地連到 APNs；實務上回報部署到 Cloudflare 後的 `fetch` 可以正常送達。
請在部署後用實機測試 push-to-start（看 Workers Logs 的 `push_to_start_sent` / `apns_rejected` 事件）。
本 repo 的自動測試以 mock fetch 驗證 request 的 URL、headers、JWT 與 payload；另外在本機 workerd（`wrangler dev`）中以 stub 取代對外連線做過整條流程的 smoke test。

---

## 設定值

| 名稱 | 種類 | 說明 |
| --- | --- | --- |
| `SS_KV` | KV binding | 唯一的 KV namespace |
| `GEMINI_API_KEY` | secret | Gemini API key |
| `SS_DEV_TOKEN` | secret | 開發用 token（只有 `ALLOW_DEV_TOKEN === "true"` 才生效，constant-time 比對） |
| `APNS_PRIVATE_KEY` | secret | APNs `.p8` PEM 內容 |
| `APPLE_TEAM_ID` | var | 10 字元 Team ID；appId = `<APPLE_TEAM_ID>.<bundleId>`。空白時 `/attest` 回 500 |
| `BUNDLE_IDS` | var | 允許 attest 的 bundle ID（逗號分隔），預設 `com.smartschedule.app,com.smartschedule.app.notification-content` |
| `APP_ATTEST_ENV` | var | `development`（aaguid `appattestdevelop`）或 `production`（`appattest` + 7 個 0x00） |
| `ALLOW_DEV_TOKEN` | var | 只有字串 `"true"` 會啟用 `X-Dev-Token` |
| `RATE_LIMIT_PER_MIN` | var | 每個身分（attested key / `dev` / IP）每 UTC 分鐘的 request 數，預設 30 |
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
| bundleId 不在 `BUNDLE_IDS`、任何驗證失敗（Worker log 記錄具體原因） | `401 invalid_attestation` |
| body 不是預期的 JSON | `400 invalid_request` |
| root CA 未嵌入、`APPLE_TEAM_ID`/`APP_ATTEST_ENV` 設定錯誤 | `500 server_misconfigured` |

### 驗證（其餘路由）

- `Authorization: Bearer <base64(keyId 32 bytes ‖ assertion CBOR)>`：
  assertion `{signature, authenticatorData}`；clientDataHash = SHA256(原始 request body bytes，空 body 即 SHA256("")）；
  nonce = SHA256(authenticatorData ‖ clientDataHash)；以儲存的 P-256 公鑰驗證 DER ECDSA/SHA-256 簽章；
  rpIdHash == SHA256(appId)；counter（bytes 33–36，big-endian）必須大於儲存值，通過後先寫回 counter 才處理 request。
- `X-Dev-Token`：只有 `ALLOW_DEV_TOKEN === "true"` 且等於 `SS_DEV_TOKEN` 才接受（身分 `dev`），否則忽略、改看 Bearer。
- 沒帶憑證或 key 不存在時，**不會讀取 body** 就拒絕。

| 狀況 | 回應 |
| --- | --- |
| 沒有可用的憑證 | `401 attestation_required` |
| `key:<keyId>` 不存在（client 應重新 attest） | `401 unknown_key` |
| 簽章 / rpId / 格式錯誤 | `401 invalid_assertion` |
| counter 沒有大於儲存值 | `401 stale_counter` |
| counter 無法寫回 KV（重試一次仍失敗） | `503 server_busy` |
| 超過 `RATE_LIMIT_PER_MIN` | `429 rate_limited` + `Retry-After` |
| body 過大（Gemini 32 MB、push-to-start 1 MB、attest 64 KB） | `413 payload_too_large` |

### `ANY /v1beta/*`
轉送到 `https://generativelanguage.googleapis.com/v1beta/*`：保留 path 與 query（移除所有 `key` 參數，其餘逐字保留）、
同一 method、**與驗證時雜湊的完全相同的 body bytes**（不解析、不修改 `generationConfig` 或任何欄位）、保留 content-type，
加上 `x-goog-api-key`；移除 `Authorization`、`X-Dev-Token`、`Cookie`、client 帶來的 `x-goog-api-key`，以及 hop-by-hop 與
Cloudflare 的 client IP headers（`cf-connecting-ip`、`x-forwarded-for` 等，不把使用者 IP 傳給 Google）。
回傳 upstream 的 status、body（串流，SSE 可用）與 content-type。上游連不到時 `502 upstream_unavailable`。

### `POST /devices/push-to-start`
Body（Swift `JSONEncoder` `.iso8601` + `.sortedKeys`）：
`{"deviceID","token":"<hex>"|null,"events":[{"eventID","title","eventStart","leadTime","triggerAt","attributesJSON","contentStateJSON"}]}`

驗證（失敗 → `400 invalid_registration`）：deviceID ≤ 64 個 `[A-Za-z0-9-]`；token 為 null（**或省略**：Swift 會省略 nil Optional）或 ≤ 200 hex；
≤ 50 events；title ≤ 200 字；`attributesJSON` / `contentStateJSON` 各 ≤ 4096 bytes 且是 JSON object；
`triggerAt` 在 [now − 1 h, now + 49 h]；eventID 非空、≤ 256 bytes、不含控制字元；leadTime 為 0–1440 的整數。

整份取代：`p2s:<deviceID>` = `{token, keyId, events, updatedAt}`（TTL 3 天，只存上列欄位，不存 notes / locations）。
第一次註冊的身分（keyId 或 `dev`）綁定該 deviceID，之後其他身分寫入 → `403 forbidden`。
每個 event 一個索引 `due:<YYYYMMDDHHmm>:<deviceID>:<eventID>`（TTL 到 triggerAt + 1 h，最少 60 s；同一 (eventID, triggerAt) 已索引過就不重寫）。
成功 `200 {"ok":true,"events":n}`；KV 拒絕寫入（例如同一裝置一秒內上傳兩次）→ `503 server_busy`，client 稍後重送即可。

> Client 注意：若 App 換了 App Attest key（例如從備份還原到新手機後重新 attest），舊 deviceID 會在 3 天內回 `403 forbidden`；client 收到 403 時應產生新的 deviceID。

### Cron（每分鐘）
對 now − 2 min 到 now + 1 min 的每一分鐘 m，列出 `due:<m>:`，對每筆重新讀取目前的 `p2s:<deviceID>`，只處理 eventID 相同且 `triggerAt` 落在 m 的 event（否則代表已刪除或移動，略過）；
`triggerAt ≤ now + 60 s` 才送；`sent:<deviceID>:<eventID>:<triggerAt epoch s>` 已存在或 token 為 null/無效則略過。

- APNs 200 → 寫 sent marker（TTL 3 天；與註冊分開存，所以覆寫註冊不會遺失）。
- 410 Unregistered 或 400 BadDeviceToken → 註冊的 token 設為 null 並記 `tokenInvalidAt`（只在 KV 中的 token 仍是失敗的那個時）。
- 其他失敗 → 記 log，之後每分鐘重試直到該分鐘離開視窗。
- Payload 超過 4096 bytes → 記 log 並略過。

APNs request：`POST https://<host>/3/device/<token>`，headers `authorization: bearer <JWT>`、`apns-push-type: liveactivity`、
`apns-topic: <APNS_BUNDLE_ID>.push-type.liveactivity`、`apns-priority: 10`、`content-type: application/json`。Payload：

```json
{"aps":{"timestamp":<now s>,"event":"start","attributes-type":"ScheduleActivityAttributes",
 "attributes":<attributesJSON>,"content-state":<contentStateJSON>,"stale-date":<eventStart epoch s>,
 "alert":{"title":<title>,"body":{"loc-key":"Starts in %@ min","loc-args":["<leadTime>"]}}}}
```

`attributes` 與 `content-state` 是 client 送來的 JSON **逐字嵌入**（已驗證為單一 JSON object），不經 parse/re-encode，
所以日期維持 Swift 預設 `JSONEncoder` 的格式（自 2001-01-01 起的秒數），數字格式也不會改變。

---

## KV 資料配置、一致性與寫入量

| Key | 內容 | TTL |
| --- | --- | --- |
| `chal:<challenge>` | 一次性 challenge | 300 s |
| `key:<keyId>` | 公鑰、counter、appId、createdAt | 無 |
| `rl:<id>:<epochMinute>` | rate limit 計數（id = keyId / `dev` / `ip:<addr>`） | 120 s |
| `p2s:<deviceID>` | push-to-start 註冊 | 3 天 |
| `due:<YYYYMMDDHHmm>:<deviceID>:<eventID>` | cron 索引 | triggerAt + 1 h |
| `sent:<deviceID>:<eventID>:<triggerAt s>` | 已送出標記 | 3 天 |
| `apns:jwt` | 共用的 APNs provider token | ≤ 50 min |

### 一致性（eventually consistent）

Workers KV 是 eventually consistent：寫入在其他 Cloudflare 據點可能要 60 秒（或更久）才看得到。因此：

- **Assertion counter**：同一 key 的兩個並行 request，或在另一個據點重放同一個 assertion，可能在傳播期間都被接受；counter 防重放是 best-effort。
- **Challenge 單次使用**：刪除也需要傳播，極短時間內在不同據點重用同一 challenge 理論上可能。
- **Rate limit**：計數是 read-modify-write，並行與跨據點時會少算，是近似值。
- **Sent marker**：cron 每次可能在不同機器執行；若 marker 尚未傳播到下一分鐘執行的據點，同一事件可能被送兩次（罕見）。
- KV 同一個 key 每秒最多寫一次：同一 key 的連續 request 若太密集，counter 寫入會重試一次（約 1 s 後），仍失敗回 `503 server_busy`；rate limit 計數寫入失敗則忽略。

需要嚴格一致（counter 嚴格遞增、challenge 嚴格單次、精確 rate limit、確保只送一次）時，應改用 **Durable Objects**
（例如每個 keyId / deviceID 一個 object），它提供單一執行緒、strongly consistent 的儲存。

### 寫入量與方案

- 每個通過驗證的 request 至少 **2 次 KV 寫入**（`key:` counter + `rl:` 計數）與 2 次讀取；`/attest/challenge` 2 次寫入；`/attest` 2 次寫入 + 1 次刪除。
- 每次 push-to-start 註冊：1 次寫入 `p2s:`，加上每個「新的」(eventID, triggerAt) 1 次 `due:` 寫入（最多 50）。
- 每次成功推播 1 次 `sent:` 寫入；JWT 每 50 分鐘 1 次寫入。
- Cron 每分鐘 **4 次 KV list**（約 5,760 次/天），外加每個到期事件數次讀取。

Workers Free plan 的 KV 額度是每天 1,000 次寫入、1,000 次 list，**光是 cron 的 list 就超過**，請使用 Workers Paid plan
（含每月百萬次等級的讀寫/list 額度）。上線前請依實際使用者數估算費用。

---

## 安全設計重點

- 不含任何 runtime dependency；CBOR（`src/cbor.ts`）與 DER/X.509（`src/der.ts`、`src/x509.ts`）為小型手寫、嚴格的 parser，方便稽核。
- Trust anchor 只有內嵌的 Apple root，client 送來的憑證鏈只用於被驗證；沒有任何「略過驗證」的路徑。
- App Attest 驗證失敗只回通用錯誤碼，具體原因只寫進 Worker log；log 不含 secrets、push token、event 標題或 request body。
- `X-Dev-Token` 只有 `ALLOW_DEV_TOKEN` 恰為 `"true"` 且 `SS_DEV_TOKEN` 非空時才有效，以 SHA-256 digest 做 constant-time 比對。
- 已知限制：若 Apple 未來在 App Attest 憑證加入本 verifier 不認得的 critical extension，驗證會 fail closed（log 會寫出 OID）。
- Gemini proxy 依合約開放整個 `/v1beta/*`；若只需要 `models/*:generateContent` / `streamGenerateContent`，可再收窄路徑。

---

## 開發

```sh
npm test          # node:test（Node 內建 type stripping，免額外 test runner）
npm run typecheck # tsc：src 對 @cloudflare/workers-types、tests 另加 @types/node
npm run dev       # wrangler dev（需先填 KV id；本機連不到 APNs）
```

測試涵蓋：CBOR（RFC 8949 範例、以獨立 encoder `cborg` 交叉驗證、各種錯誤輸入）；DER/X.509（與 OpenSSL `node:crypto` 交叉比對）；
以測試中產生的 root/intermediate/leaf 憑證鏈（`@peculiar/x509`，注入 verifier 取代 Apple root）做完整 attestation 成功案例，
以及 nonce、appId、keyId、counter、aaguid、credentialId 錯誤、指向其他 root、冒名 intermediate、過期/尚未生效憑證等失敗案例；
assertion（成功、簽章錯誤、stale counter、錯誤 rpId）；dev token；rate limit 429；Gemini proxy（body bytes 完全相同、加 key、移除認證 headers 與 `key` 參數）；
push-to-start 驗證、整份取代、sent marker 在覆寫後仍保留、身分綁定；cron（只送一次、略過刪除/移動的事件、410/BadDeviceToken 清 token、重試視窗）；
APNs payload 與 headers；JWT ES256 以公鑰驗證。

## 檔案結構

```
src/
  index.ts            router、fetch/scheduled 入口、可注入的 deps（clock、fetch、root CA）
  env.ts              Env 型別與設定解析
  http.ts             JSON 回應、錯誤、body 大小限制、log
  encoding.ts         base64 / hex / SHA-256 / constant-time 比較
  cbor.ts             CBOR decoder
  der.ts              DER reader、ECDSA DER → raw
  x509.ts             X.509 parsing 與 chain 驗證
  apple-root-ca.ts    內嵌的 Apple App Attestation Root CA（由 scripts/embed-apple-root-ca.sh 產生）
  attestation.ts      App Attest attestation 驗證
  assertion.ts        App Attest assertion 驗證
  attest-routes.ts    /attest/challenge、/attest
  auth.ts             驗證（assertion / dev token）與 rate limit
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
