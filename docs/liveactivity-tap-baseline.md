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

**2026-10-16 更新：** 展開的動態島底部不再有輸入列。T3–T5 三個 `Link`（文字、麥克風、紙飛機）換成一個全寬的「編輯」按鈕 `IslandEditButton`：`Link(destination: DeepLink.compose)` 包 `Text("Edit")`（繁體中文「編輯」），整個膠囊都能點，打開快速輸入、鍵盤已叫出，目標 `smartschedule://compose`。動態島上不再有麥克風，Live Activity 也不再用 `DeepLink.composeVoice`；這個常數留在 `AppConstants`（Shared 的公開 API 不變，測試也用到）；App 拿掉語音輸入之後（同一天），`?mode=voice` 和 `smartschedule://compose` 一樣只打開快速輸入、鍵盤已叫出，不會開始收音。上表 T3–T5 保留 Step 0 的原樣作為紀錄。

| # | 位置 | 元件 | 呈現 | 目標 |
|---|---|---|---|---|
| T3′ | `IslandEditButton`（展開的動態島底部「編輯」按鈕，取代 T3–T5） | `Link(destination: DeepLink.compose)` 包 `Text("Edit")` | 展開的動態島 | `smartschedule://compose` |

`Button(intent:)`：**0 個**。`DismissScheduleIntent`（Step 0 時在 `Shared/Intents/SummonScheduleIntent.swift`，Step 2 起移到 `Shared/Intents/DismissScheduleIntent.swift`）有定義，但沒有任何畫面使用它。

驗證方式：每個改動 Live Activity 的 commit 之後執行

```sh
grep -rn "widgetURL\|Link(destination\|Button(intent" Widgets Shared
```

輸出必須是 T1、T2 和 T3′ 這三行（行號可以變，元件與目標不能變；2026-10-16 之前是 T1–T5 五行），且沒有新增 `Button(intent:)`。
