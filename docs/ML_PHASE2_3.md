# ML 第 2、3 階段：訓練模型、放進 EA

前提：已依 [ML_PHASE1.md](ML_PHASE1.md) 用 `Inp_MLRecord=true` 回測，
`H:\ml\features\` 裡有 `features_tester_*.csv`。

## 第 2 階段：訓練

### 安裝 Python（只需一次）

1. 到 <https://www.python.org/downloads/> 下載 Python 3.10 以上版本。
2. 安裝時**勾選「Add python.exe to PATH」**。
3. 開新的命令提示字元輸入 `python --version`，看到版本號即完成。

### 執行訓練

```
G:\我的雲端硬碟\src\mt_ea\scripts\train_ml.bat
```

第一次會自動安裝需要的套件（numpy、pandas、scikit-learn、skl2onnx、onnxruntime）。

輸出：

| 檔案 | 位置 |
|------|------|
| `model.onnx` | `G:\我的雲端硬碟\releases\models\`（EA 讀這個） |
| `model.json` | 同上：特徵清單、建議門檻、驗證數據 |
| `report_<時間>.txt` | `H:\ml\reports\` |

### 看懂報告

```
Walk-forward AUC（0.5=沒有預測力）: 0.54, 0.56, ...   平均 0.55

樣本外（walk-forward 測試段）結果：
      門檻      筆數      勝率     期望值R  保留比例
     不過濾    5835   35.7%   +0.072   100%
    0.50    1398   40.2%   +0.207    24%
    ...
✅ 建議 Inp_MLThreshold = 0.50
```

- **全部數字都是樣本外**：每一段都是用「更早的資料」訓練、用「之後的資料」測試，
  中間還隔開 72 小時，避免結果重疊造成偷看。
- **AUC**：0.5 = 跟亂猜一樣；外匯信號能到 0.55 就算有用，超過 0.65 要懷疑資料有問題。
- **期望值R**：每筆平均賺幾個「SL 距離」。看過濾後是否比「不過濾」高，且筆數不要少太多。
- 報告最後會直接說**建議或不建議**啟用。出現 ❌ 就不要啟用 ML，模型沒有幫助。

其他選項：

| 參數 | 說明 |
|------|------|
| `--model logreg` | 改用邏輯迴歸（較簡單、較不易過度擬合，可比較兩者） |
| `--keep-timeout` | 逾時的信號當作失敗計入（預設排除） |
| `--gap-hours 72` | 訓練與測試的間隔，應 ≥ EA 的 `Inp_MLMaxHoldHours` |
| `--folds 5` | walk-forward 測試段數 |

例：`train_ml.bat --model logreg`

## 第 3 階段：放進 EA

1. 以系統管理員再執行一次 `setup_drives.bat <MT5資料夾ID>`，
   建立 `Common\Files\mt_ea_models` → `releases\models` 的連結（已有的連結會略過）。
2. `deploy.bat` → MetaEditor 按 F7（會一併部署 `MLFilter.mqh`）。
3. EA 參數：

   | 參數 | 值 |
   |------|----|
   | `Inp_UseML` | true |
   | `Inp_MLModel` | `mt_ea_models\model.onnx`（預設） |
   | `Inp_MLThreshold` | 報告建議的門檻 |

4. 「專家」分頁應出現 `MLFilter: 已載入模型 ...（26 個特徵）`。
   若出現「無法載入模型」或「特徵數不符」，EA 會**自動退回不過濾**繼續運作。

### 上線前一定要做的驗證

模型是用某段期間訓練的，**只能用那段期間之後的資料**來驗證。資料都到今天為止，
所以先保留最近 3 個月不訓練：

1. `train_ml.bat --holdout-months 3`：只用 3 個月前以前的資料訓練，報告會寫出保留期間的起始日。
2. MT5 策略測試器回測**那個日期到今天**，比較 `Inp_UseML=false` 與 `true`。
3. 有改善的話，再執行一次 `train_ml.bat`（不加參數，用到今天的全部資料）產生正式模型。
4. 上模擬帳戶跑至少一個月，再考慮實盤。

之後每季用最新資料重新回測、重新訓練一次。

## 運作方式

- EA 每根 M12 K 線，對通過原本所有條件的信號，用 `BuildMLFeatures()` 算出 26 個特徵，
  送進模型得到「先到 TP」的機率，低於門檻就放棄該信號。
- 每個商品每根 K 線只算一次（有快取）。
- 模型只會**減少**進場，不會新增信號、不改變 SL/TP 與風控。
