//+------------------------------------------------------------------+
//|  BQ_MLInputs.mqh — 所有 EA 共用的 ML 參數與全域過濾器物件            |
//|  EA 只要 (每個商品一個 CBQMLFilter 物件 ml)：                        |
//|     初始化   : BQML_Setup(ml,"EA名稱",商品,週期,magic);             |
//|     每個 tick: ml.OnTick();                                        |
//|     下單前   : if(!ml.Allow(方向, 停損距離, 停利距離)) 不下單       |
//|     結束     : ml.Deinit();                                        |
//+------------------------------------------------------------------+
#ifndef BQ_MLINPUTS_MQH
#define BQ_MLINPUTS_MQH

#include "BQ_ML.mqh"

input group "=== 帳戶保護 ==="
input bool InpAllowReal   = false; // 允許在「真實帳戶」執行 (預設只在模擬帳戶執行)
input long InpLockAccount = 0;     // 只允許此帳號執行 (0=不限)

//--- MT5 切換登入帳號時，圖表上的 EA 會留著繼續跑到新帳號；
//    所以在 OnInit 檢查帳戶，不符合就不啟動 (EA 會自動從圖表移除)
bool BQ_AccountAllowed()
  {
   if(MQLInfoInteger(MQL_TESTER)) return(true);
   long login=AccountInfoInteger(ACCOUNT_LOGIN);
   ENUM_ACCOUNT_TRADE_MODE mode=(ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(InpLockAccount!=0 && login!=InpLockAccount)
     {
      PrintFormat("帳戶保護：目前帳號 %I64d 不是指定帳號 %I64d，EA 不啟動",login,InpLockAccount);
      return(false);
     }
   if(mode==ACCOUNT_TRADE_MODE_REAL && !InpAllowReal)
     {
      PrintFormat("帳戶保護：帳號 %I64d 是真實帳戶，InpAllowReal=false，EA 不啟動",login);
      Alert("EA 未啟動：這是真實帳戶 (要在真實帳戶執行請把 InpAllowReal 設為 true)");
      return(false);
     }
   return(true);
  }

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

//--- 每個商品各自一個過濾器 (模型檔名含商品/週期/magic，互不干擾)
//    baseTF = 該商品的策略週期；InpMLTimeframe=目前週期 時用 baseTF
bool BQML_Setup(CBQMLFilter &f,const string eaName,const string sym,const ENUM_TIMEFRAMES baseTF,const long magic)
  {
   ENUM_TIMEFRAMES tf=(InpMLTimeframe==PERIOD_CURRENT ? baseTF : InpMLTimeframe);
   if(tf==PERIOD_CURRENT) tf=(ENUM_TIMEFRAMES)_Period;
   return(f.Init(eaName,sym,tf,magic,InpMLMode,InpMLThreshold,InpMLMinSamples,
                    InpMLBarrierTP,InpMLBarrierSL,InpMLMaxBars,
                    InpMLLoadModel,InpMLSaveModel,InpMLExportCSV,InpMLScaleLots));
  }

#endif
//+------------------------------------------------------------------+
