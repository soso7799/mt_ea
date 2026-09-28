//+------------------------------------------------------------------+
//| 09_Wellington_ML.mq5 — 第九期 Wellington 威靈頓 修正優化 + ML       |
//|   原開發：GBPJPY H1；可穿透 AUDNZD USDJPY NZDJPY GBPNZD AUDJPY NZDUSD |
//|                                                                  |
//| 策略邏輯 (與原版相同)：三均線回檔 + 突破掛單                         |
//|   EMA(N) < EMA(Nxratio) 且 EMA(N) > EMA(Nxratio²) (長多中的回檔)     |
//|   → 在最近 K 根高點掛 BuyStop (右邊交易)；空單對稱                   |
//|   停損/停利 = ATR x 倍數；新K棒時刪除未成交掛單重新評估              |
//|                                                                  |
//| 修正：                                                            |
//|   * 刪除掛單迴圈正向刪除會跳單 → 反向迴圈                            |
//|   * 掛單價位太靠近現價被拒單沒處理 → 送單前檢查 STOPS_LEVEL           |
//|   * 同一根K棒先嘗試下單後才刪舊單，新單要等下一個 tick → 先刪再下     |
//|   * cash.mqh iATR 每 tick 建 handle → 快取                          |
//|   * 手數對齊交易量步進；送單檢查 retcode                             |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include <BeeQuant/BQ_Trade.mqh>
#include <BeeQuant/BQ_Indicators.mqh>

input group "=== 策略參數 ==="
input ENUM_TIMEFRAMES InpTF   = PERIOD_H2;      // 均線/ATR 時間週期
input ENUM_TIMEFRAMES InpHLTF = PERIOD_CURRENT; // 高低點取值週期 (原版=圖表週期)
input int    InpMAPeriod   = 110;   // 短均線週期 (EMA)
input int    InpRatio      = 3;     // 中均=短均x倍數，長均=中均x倍數
input int    InpHLBars     = 25;    // 高低點根數
input double InpSLMult     = 2;     // 停損 ATR 倍數
input double InpTPMult     = 2;     // 停利 ATR 倍數

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 100;   // MagicNumber (空單 = +77)

#include <BeeQuant/BQ_MLInputs.mqh>

CBQTrade    g_trade;
CBQBarGuard g_guard;
CBQNewBar   g_newBar;

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   BQ_hMA(_Symbol,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   BQ_hMA(_Symbol,InpTF,InpMAPeriod*InpRatio,0,MODE_EMA,PRICE_CLOSE);
   BQ_hMA(_Symbol,InpTF,InpMAPeriod*InpRatio*InpRatio,0,MODE_EMA,PRICE_CLOSE);
   BQ_hATR(_Symbol,InpTF,InpMAPeriod);
   BQML_Setup("Wellington",InpMagic);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   g_ml.Deinit();
   BQ_ReleaseIndicators();
   Comment("");
  }

double OnTester() { return(BQ_TesterScore()); }

void OnTick()
  {
   g_ml.OnTick();
   if(AccountInfoDouble(ACCOUNT_BALANCE)<=InpMinBalance) return;

   //--- 均線週期新K棒：刪除上一根沒成交的掛單
   if(g_newBar.Check(_Symbol,InpTF))
     {
      g_trade.DeletePending(true);
      g_trade.DeletePending(false);
     }
   if(g_guard.Done(_Symbol,InpTF) || !g_trade.SpreadOK(InpMaxSpread)) return;

   double ma1=BQ_MA(_Symbol,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE,1);
   double ma2=BQ_MA(_Symbol,InpTF,InpMAPeriod*InpRatio,0,MODE_EMA,PRICE_CLOSE,1);
   double ma3=BQ_MA(_Symbol,InpTF,InpMAPeriod*InpRatio*InpRatio,0,MODE_EMA,PRICE_CLOSE,1);
   double atr=BQ_ATR(_Symbol,InpTF,InpMAPeriod,1);
   ENUM_TIMEFRAMES hlTF=(InpHLTF==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpHLTF);
   double hh=BQ_Highest(_Symbol,hlTF,InpHLBars,1);
   double ll=BQ_Lowest(_Symbol,hlTF,InpHLBars,1);
   if(!BQ_Ok(ma1)||!BQ_Ok(ma2)||!BQ_Ok(ma3)||!BQ_Ok(atr)||!BQ_Ok(hh)||!BQ_Ok(ll)) return;

   double ask=g_trade.Ask(), bid=g_trade.Bid();
   double slD=InpSLMult*atr, tpD=InpTPMult*atr;
   bool placed=false;

   if(ask<hh && ma1<ma2 && ma1>ma3 &&
      g_trade.CountBuy()==0 && g_trade.PendingCount(true)==0 && g_ml.Allow(1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Pending(ORDER_TYPE_BUY_STOP,hh,lots,hh-slD,hh+tpD,"3MA_PB Long")) placed=true;
     }
   if(bid>ll && ma1>ma2 && ma1<ma3 &&
      g_trade.CountSell()==0 && g_trade.PendingCount(false)==0 && g_ml.Allow(-1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Pending(ORDER_TYPE_SELL_STOP,ll,lots,ll+slD,ll-tpD,"3MA_PB Short")) placed=true;
     }
   if(placed) g_guard.Mark(_Symbol,InpTF);

   BQ_Panel(StringFormat("Wellington ML\nEMA %d/%d/%d\nHH %.5f LL %.5f\n%s",InpMAPeriod,InpMAPeriod*InpRatio,
                         InpMAPeriod*InpRatio*InpRatio,hh,ll,g_ml.Status()));
  }
//+------------------------------------------------------------------+
