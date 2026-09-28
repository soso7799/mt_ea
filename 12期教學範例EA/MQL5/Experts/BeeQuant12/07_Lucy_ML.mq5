//+------------------------------------------------------------------+
//| 07_Lucy_ML.mq5 — 第七期 週末EA-Lucy 修正優化 + 機器學習             |
//|   原開發：EURJPY H1                                                 |
//|                                                                  |
//| 策略邏輯 (與原版相同)：波動收斂時，在區間低點附近做多/高點附近做空   |
//|   多：收盤距 N 根最低點 <= 距離，且 ATR20 < 22 根前 ATR20 x 小於倍數 |
//|   停損 = ATR40 x 停損倍數，停利 = 停損 x 獲利倍數                    |
//|   獲利中啟動 ATR 追蹤停損；出現反向訊號時平倉                        |
//|                                                                  |
//| 修正：                                                            |
//|   * 每個 tick 建立 2 個 iATR handle 從不釋放 → 快取                  |
//|   * 空單追蹤停損用 CopyHigh 取「最低點」(複製錯陣列) → 修正           |
//|   * 追蹤用「上一根 M1 高點若高於前一根」並非進場後最高點 → 修正       |
//|   * MagicNumber 不是參數 → 改為可調                                  |
//|   * 手數對齊交易量步進；送單檢查 retcode；改單保留 TP                |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input double InpSLMult     = 7;     // 停損倍數 (x ATR40)
input double InpTPMult     = 3;     // 獲利倍數 (x 停損)
input int    InpLookback   = 50;    // 高低點回看根數
input int    InpDistance   = 150;   // 距高低點距離 (點)
input double InpShrink     = 0.7;   // 波動收斂倍數 (ATR20 < 前期 x 此值)
input bool   InpTrailing   = true;  // 獲利中啟用追蹤停損
input int    InpMaxTradesDay = 5;   // 每日下單次數上限
input int    InpDayReset   = 0;     // 每日次數歸零時間
input ENUM_TIMEFRAMES InpATRTF = PERIOD_H1; // ATR 週期 / 每根K棒最多一單

input group "=== 資金 / 風控 ==="
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 固定手數
input double InpMaxLots    = 0.1;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 278;   // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade        g_trade;
CBQBarGuard     g_guardBuy,g_guardSell;
CBQDailyCounter g_daily;

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   g_daily.Init(InpDayReset);
   BQ_hATR(_Symbol,InpATRTF,40);
   BQ_hATR(_Symbol,InpATRTF,20);
   BQML_Setup("Lucy",InpMagic);
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
   double atr =BQ_ATR(_Symbol,InpATRTF,40,1);
   double atr0=BQ_ATR(_Symbol,InpATRTF,20,1);
   double atr1=BQ_ATR(_Symbol,InpATRTF,20,22);
   double hi  =BQ_Highest(_Symbol,_Period,InpLookback,1);
   double lo  =BQ_Lowest(_Symbol,_Period,InpLookback,1);
   double c1  =iClose(_Symbol,_Period,1);
   if(!BQ_Ok(atr)||!BQ_Ok(atr0)||!BQ_Ok(atr1)||!BQ_Ok(hi)||!BQ_Ok(lo)||c1<=0) return;

   bool quiet=(atr0<atr1*InpShrink);
   bool buyCond =(MathAbs(c1-lo)<=InpDistance*_Point && quiet && c1>lo);
   bool sellCond=(MathAbs(c1-hi)<=InpDistance*_Point && quiet && c1<hi);
   double slD=atr*InpSLMult, tpD=slD*InpTPMult;
   double ask=g_trade.Ask(), bid=g_trade.Bid();

   //=== 追蹤停損 (價格在進場價之上才啟動) ===
   if(InpTrailing)
     {
      if(g_trade.CountBuy()>0 && bid>g_trade.OpenPrice(POSITION_TYPE_BUY))
        {
         double h=BQ_HighSince(_Symbol,PERIOD_M1,g_trade.OpenTime(POSITION_TYPE_BUY));
         if(BQ_Ok(h)) g_trade.ModifySL(POSITION_TYPE_BUY,h-slD);
        }
      if(g_trade.CountSell()>0 && ask<g_trade.OpenPrice(POSITION_TYPE_SELL))
        {
         double l=BQ_LowSince(_Symbol,PERIOD_M1,g_trade.OpenTime(POSITION_TYPE_SELL));
         if(BQ_Ok(l)) g_trade.ModifySL(POSITION_TYPE_SELL,l+slD);
        }
     }

   //=== 反向訊號平倉 ===
   if(g_trade.CountBuy()>0  && sellCond) g_trade.CloseBuy();
   if(g_trade.CountSell()>0 && buyCond)  g_trade.CloseSell();

   //=== 進場 ===
   if(g_daily.Count()>=InpMaxTradesDay || !g_trade.SpreadOK(InpMaxSpread)) return;
   if(buyCond && !sellCond && g_trade.CountBuy()==0 && !g_guardBuy.Done(_Symbol,InpATRTF) && g_ml.Allow(1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Buy(lots,ask-slD,ask+tpD,"Lucy_BUY")) { g_daily.Inc(); g_guardBuy.Mark(_Symbol,InpATRTF); }
     }
   if(sellCond && !buyCond && g_trade.CountSell()==0 && !g_guardSell.Done(_Symbol,InpATRTF) && g_ml.Allow(-1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Sell(lots,bid+slD,bid-tpD,"Lucy_SELL")) { g_daily.Inc(); g_guardSell.Mark(_Symbol,InpATRTF); }
     }
   BQ_Panel(StringFormat("Lucy ML\nATR40 %.5f  收斂 %s\n今日下單 %d\n%s",atr,(quiet?"是":"否"),g_daily.Count(),g_ml.Status()));
  }
//+------------------------------------------------------------------+
