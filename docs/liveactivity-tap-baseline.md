# Live Activity tap baseline（Step 0 盤點，之後的 diff 不得與此不一致）

基準 commit：`22474d0`（iOS CI run 38646401174 綠燈，Executed 597 tests, 0 failures）。

Live Activity 的畫面全部在 `Widgets/ScheduleLiveActivity.swift`；`Shared/LiveActivity/` 只有資料（`ScheduleActivityAttributes`、`LiveActivityStateBuilder`、`LiveActivityManager`、`DemoActivityState`），**沒有任何** `widgetURL`、`Link` 或 `Button(intent:)`。

Deep link 定義（`Shared/Core/AppConstants.swift`）：

| 常數 | URL |
|---|---|
| `DeepLink.compose` | `smartschedule://compose` |
| `DeepLink.composeVoice` | `smartschedule://compose?mode=voice` |

## 點擊目標

| # | 位置 | 元件 | 呈現 | 目標 |
|---|---|---|---|---|
| T1 | `Widgets/ScheduleLiveActivity.swift` `ActivityConfiguration` 的 Lock Screen 閉包 | `.widgetURL(DeepLink.compose)` | 鎖定畫面（及沒有動態島的機型）整張卡片 | `smartschedule://compose` |
| T2 | `Widgets/ScheduleLiveActivity.swift` `DynamicIsland { … }` 之後 | `.widgetURL(DeepLink.compose)` | 動態島 compact / minimal / expanded 的空白處 | `smartschedule://compose` |
| T3 | `IslandInputPill`（展開的動態島底部輸入列） | `Link(destination: DeepLink.compose)` 包「Type in any plan to add or change」 | 展開的動態島 | `smartschedule://compose` |
| T4 | `IslandInputPill` | `Link(destination: DeepLink.composeVoice)` 包麥克風圖示 | 展開的動態島 | `smartschedule://compose?mode=voice` |
| T5 | `IslandInputPill` | `Link(destination: DeepLink.compose)` 包紙飛機圖示 | 展開的動態島 | `smartschedule://compose` |

**2026-10-16 更新：** 展開的動態島底部不再有輸入列。T3–T5 三個 `Link`（文字、麥克風、紙飛機）換成一個全寬的「編輯」按鈕 `IslandEditButton`：`Link(destination: DeepLink.compose)` 包 `Text("Edit")`（繁體中文「編輯」），整個膠囊都能點，打開快速輸入、鍵盤已叫出，目標 `smartschedule://compose`。動態島上不再有麥克風，Live Activity 也不再用 `DeepLink.composeVoice`；這個常數留在 `AppConstants`（Shared 的公開 API 不變，測試也用到）；App 拿掉語音輸入之後（同一天），`?mode=voice` 和 `smartschedule://compose` 一樣只打開快速輸入、鍵盤已叫出，不會開始收音。**2026-10-18 起** App 的語音輸入加回來（只在 iPhone 上辨識）：`?mode=voice` 打開快速輸入，已經授權且這支 iPhone 能在裝置上辨識該語言時直接開始收音，否則和 `compose` 一樣叫出鍵盤，不會跳權限提示（`DeepLink.startsVoiceInput`）。動態島仍然沒有麥克風。上表 T3–T5 保留 Step 0 的原樣作為紀錄。

| # | 位置 | 元件 | 呈現 | 目標 |
|---|---|---|---|---|
| T3′ | `IslandEditButton`（展開的動態島底部「編輯」按鈕，取代 T3–T5） | `Link(destination: DeepLink.compose)` 包 `Text("Edit")` | 展開的動態島 | `smartschedule://compose` |

**2026-10-17 更新（高度）：** 展開的動態島最高 160 pt，iPhone 上底部區域約從 60 pt 開始，只剩約 98 pt。原本週曆一天最多三行（兩個行程＋「+N」）約 71 pt，加上 36 pt 的按鈕會超過，底部被截掉（實機截圖）。現在一天最多兩行（兩個行程，或一個行程＋「+N」，`DayDigest.visibleRows(2)`，有單元測試），週曆約 51 pt，「編輯」按鈕 30 pt，間距 5 pt，底部留約 12 pt。

**2026-10-18 更新（「編輯」移到左上角）：** 實機截圖裡底部全寬的「編輯」膠囊兩端被島的圓角切到，所以拿掉了；「編輯」改成左上角、鏡頭旁的小膠囊 `IslandEditPill`（取代原本的時鐘圖示）：`Link(destination: DeepLink.compose)` 包鉛筆圖示和 `Text("Edit")`（繁體中文「編輯」），目標不變，打開快速輸入、鍵盤已叫出。它是展開的動態島上唯一的控制項（HIG：互動最好只有一個元件），島上其他地方照樣由 T2 的 `widgetURL` 打開快速輸入。底部改顯示「接下來」的行程，沒有任何點擊目標。高度與圓角的計算寫在 `Widgets/ScheduleLiveActivity.swift` 開頭：最高的情況約 147–150 pt（上限 160），內容離島的左右 16 pt、底部 12 pt（`contentMargins`），左上「編輯」和右上倒數再往內 4 pt、往下 2 pt，外框畫在膠囊內側（`strokeBorder`）。

| # | 位置 | 元件 | 呈現 | 目標 |
|---|---|---|---|---|
| T3″ | `IslandEditPill`（展開的動態島左上角「編輯」，取代 T3′） | `Link(destination: DeepLink.compose)` 包鉛筆圖示和 `Text("Edit")` | 展開的動態島 | `smartschedule://compose` |

`Button(intent:)`：**0 個**。`DismissScheduleIntent`（Step 0 時在 `Shared/Intents/SummonScheduleIntent.swift`，Step 2 起移到 `Shared/Intents/DismissScheduleIntent.swift`）有定義，但沒有任何畫面使用它。

驗證方式：每個改動 Live Activity 的 commit 之後執行

```sh
grep -rn "widgetURL\|Link(destination\|Button(intent" Widgets Shared
```

輸出必須是 T1、T2 和 T3″ 這三行（行號可以變，元件與目標不能變；2026-10-16 之前是 T1–T5 五行，2026-10-18 之前第三行是 T3′），且沒有新增 `Button(intent:)`。
