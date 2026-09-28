//+------------------------------------------------------------------+
//|  BQ_MLInputs.mqh — 所有 EA 共用的 ML 參數與全域過濾器物件            |
//|  EA 只要：                                                         |
//|     #include <BeeQuant/BQ_MLInputs.mqh>                            |
//|     OnInit   : BQML_Setup("EA名稱", magic);                        |
//|     OnTick   : g_ml.OnTick();                                      |
//|     下單前   : if(!g_ml.Allow(方向, 停損距離, 停利距離)) 不下單     |
//|     OnDeinit : g_ml.Deinit();                                      |
//+------------------------------------------------------------------+
#ifndef BQ_MLINPUTS_MQH
#define BQ_MLINPUTS_MQH

#include "BQ_ML.mqh"

input group "=== 機器學習 (ML) 訊號過濾 ==="
input ENUM_BQML_MODE  InpMLMode       = BQML_FILTER;    // ML 模式
input double          InpMLThreshold  = 0.03;           // 放行門檻：預估勝率需高於兩平勝率多少
input int             InpMLMinSamples = 40;             // 暖機樣本數 (之前不過濾)
input double          InpMLBarrierTP  = 0;              // 標記用停利 ATR 倍數 (0=用 EA 停利)
input double          InpMLBarrierSL  = 0;              // 標記用停損 ATR 倍數 (0=用 EA 停損)
input int             InpMLMaxBars    = 48;             // 標記最長追蹤 K 棒數
input bool            InpMLLoadModel  = true;           // 啟動時載入已存模型
input bool            InpMLSaveModel  = true;           // 結束時儲存模型
input bool            InpMLExportCSV  = false;          // 匯出訓練資料 CSV
input bool            InpMLScaleLots  = false;          // 依預估勝率調整手數 (0.5~1.5倍)
input ENUM_TIMEFRAMES InpMLTimeframe  = PERIOD_CURRENT; // 特徵計算週期

CBQMLFilter g_ml;

bool BQML_Setup(const string eaName,const long magic)
  {
   ENUM_TIMEFRAMES tf=(InpMLTimeframe==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpMLTimeframe);
   return(g_ml.Init(eaName,_Symbol,tf,magic,InpMLMode,InpMLThreshold,InpMLMinSamples,
                    InpMLBarrierTP,InpMLBarrierSL,InpMLMaxBars,
                    InpMLLoadModel,InpMLSaveModel,InpMLExportCSV,InpMLScaleLots));
  }

#endif
//+------------------------------------------------------------------+
