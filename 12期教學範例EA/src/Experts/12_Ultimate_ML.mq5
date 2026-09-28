//+------------------------------------------------------------------+
//| 12_Ultimate_ML.mq5 — 第十二期 EA-Ultimate 修正優化 + 機器學習       |
//|   可用商品：GBPCAD、GBPNZD、GBPJPY   週期：M15                        |
//|                                                                  |
//| 策略邏輯 (與原版相同)：價格破底做多 / 過頂做空 (假突破反轉)          |
//|   多：上一根開盤 > 前 N 根最低點，這一根開盤 < 最近 N 根最低點        |
//|   空：上一根開盤 < 前 N 根最高點，這一根開盤 > 最近 N 根最高點        |
//|   停損 = ATR(10) x 停損倍數；出場：開盤價穿越均線                    |
//|                                                                  |
//| 修正：                                                            |
//|   * cash_v2.mqh 的 iATR / iMA 每 tick 建 handle → 快取               |
//|   * 平倉/判斷都在每個 tick 重算，同一根K棒可反覆下單 → 每根K棒一次     |
//|   * 風險手數固定用 10000 本金 → 可選帳戶餘額 (InpRiskBase=0)          |
//|   * 手數沒有上限、沒對齊步進 → 修正                                 |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input int    InpRange      = 16;    // 高低點根數
input double InpSLATR      = 4.5;   // 停損 ATR 倍數
input double InpTPATR      = 0;     // 停利 ATR 倍數 (0=不設，原版)
input int    InpMALen      = 14;    // 出場均線 (SMA)
input int    InpATRPeriod  = 10;    // ATR 週期

input group "=== 資金 / 風控 ==="
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpRiskBase   = 10000; // 計算本金 (0=帳戶餘額，原版固定 10000)
input double InpLots       = 0.01;  // 固定手數
input double InpMaxLots    = 1.0;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 100;   // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade    g_trade;
CBQBarGuard g_guardOpen,g_guardBuyClose,g_guardSellClose;

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   BQ_hATR(_Symbol,_Period,InpATRPeriod);
   BQ_hMA(_Symbol,_Period,InpMALen,0,MODE_SMA,PRICE_CLOSE);
   BQML_Setup("Ultimate",InpMagic);
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
   double atr=BQ_ATR(_Symbol,_Period,InpATRPeriod,1);
   double l1=BQ_Lowest(_Symbol,_Period,InpRange,1),  h1=BQ_Highest(_Symbol,_Period,InpRange,1);
   double l2=BQ_Lowest(_Symbol,_Period,InpRange,2),  h2=BQ_Highest(_Symbol,_Period,InpRange,2);
   double ma1=BQ_MA(_Symbol,_Period,InpMALen,0,MODE_SMA,PRICE_CLOSE,1);
   double ma2=BQ_MA(_Symbol,_Period,InpMALen,0,MODE_SMA,PRICE_CLOSE,2);
   double o0=iOpen(_Symbol,_Period,0), o1=iOpen(_Symbol,_Period,1);
   if(!BQ_Ok(atr)||!BQ_Ok(l1)||!BQ_Ok(h1)||!BQ_Ok(l2)||!BQ_Ok(h2)||!BQ_Ok(ma1)||!BQ_Ok(ma2)||o0<=0||o1<=0) return;

   //=== 出場：開盤價穿越均線 ===
   if(g_trade.CountBuy()>0 && !g_guardBuyClose.Done(_Symbol,_Period) && o1<ma2 && o0>ma1)
     { g_trade.CloseBuy(); g_guardBuyClose.Mark(_Symbol,_Period); }
   if(g_trade.CountSell()>0 && !g_guardSellClose.Done(_Symbol,_Period) && o1>ma2 && o0<ma1)
     { g_trade.CloseSell(); g_guardSellClose.Mark(_Symbol,_Period); }

   //=== 進場 ===
   if(g_guardOpen.Done(_Symbol,_Period) || !g_trade.SpreadOK(InpMaxSpread)) return;
   double ask=g_trade.Ask(), bid=g_trade.Bid();
   double slD=InpSLATR*atr, tpD=InpTPATR*atr;

   if(o1>l2 && o0<l1 && g_trade.CountBuy()==0 && g_trade.PendingCount(true)==0 && g_ml.Allow(1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots,InpRiskBase)*g_ml.LotFactor();
      if(g_trade.Buy(lots,ask-slD,(tpD>0 ? ask+tpD : 0),"Ultimate Long")) g_guardOpen.Mark(_Symbol,_Period);
     }
   if(o1<h2 && o0>h1 && g_trade.CountSell()==0 && g_trade.PendingCount(false)==0 && g_ml.Allow(-1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots,InpRiskBase)*g_ml.LotFactor();
      if(g_trade.Sell(lots,bid+slD,(tpD>0 ? bid-tpD : 0),"Ultimate Short")) g_guardOpen.Mark(_Symbol,_Period);
     }
   BQ_Panel(StringFormat("Ultimate ML\n區間高 %.5f 低 %.5f\n%s",h1,l1,g_ml.Status()));
  }
//+------------------------------------------------------------------+
