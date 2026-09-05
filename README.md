# Leash

> AI agent 的鏈上花錢韁繩。額度規則存在 ENS 名字底下,agent 自己改不了;
> 放寬規則要真人刷臉,收緊隨時可做。

**ETHGlobal ETHOnline 2026** · Sepolia · 單人參賽

---

## 現況

🚧 開發中(9/4 – 9/14)。進度見 [`docs/sprint.md`](docs/sprint.md)。

## 文件

| | |
|---|---|
| [`docs/PLAN.md`](docs/PLAN.md) | 專案總覽、架構、金鑰模型、Demo 腳本 |
| [`docs/events.md`](docs/events.md) | **事件 schema(先凍結再寫合約)** |
| [`docs/ensv2-sepolia.md`](docs/ensv2-sepolia.md) | ENSv2 Sepolia 鏈上實測紀錄(ABI 是反推出來的) |
| [`docs/sprint.md`](docs/sprint.md) | 11 天計畫、產能、砍單順序 |
| [`docs/prizes.md`](docs/prizes.md) | 三個賽道的條件對照 |
| [`docs/world-feedback.md`](docs/world-feedback.md) | World 獎項要求的開發者回饋文件 |

## 關於「從零開始」

`docs/` 底下的規劃與設計文件寫於賽事開始前,內容是規劃、獎項條件整理,
以及對 ENSv2 Sepolia 既有合約的鏈上探測紀錄。

**所有專案程式碼自 2026-09-04 起從零寫成**,commit 歷史即為紀錄。

## 開始

```bash
cp .env.example .env   # 填入你自己的三把鑰匙
forge build
forge test
```

> `.env` 已被 gitignore。三把鑰匙為什麼要分開,見 `docs/PLAN.md`「金鑰模型」。
