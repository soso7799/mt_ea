//+------------------------------------------------------------------+
//| X1_Trendline_ML.mq5 — 額外贈送 Trendline EA 修正優化 + 機器學習     |
//|                                                                  |
//| 使用方式 (與原版相同)：在圖上手動畫「趨勢線」並設定顏色               |
//|   黃色 Yellow  = 突破買進線：價格由下往上突破 → 做多                 |
//|   淺藍 Aqua    = 跌破賣出線：價格由上往下跌破 → 做空                 |
//|   洋紅 Magenta = 反彈買進線：價格碰到後反彈 → 做多                   |
//|   萊姆 Lime    = 拉回賣出線：價格碰到後拉回 → 做空                   |
//|   每種顏色只取第一條；停損/停利為固定點數                             |
//|                                                                  |
//| 修正：                                                            |
//|   * 每日下單次數從不歸零，跑幾天後就永遠不再下單 → 每日歸零          |
//|   * 空單停損停利用 Ask 計算 → 改用 Bid                               |
//|   * 趨勢線價位取 shift 0 (ObjectGetValueByShift) 在新K棒剛開時常為 0 |
//|     → 改以目前時間取值 (ObjectGetValueByTime)                        |
//|   * 每 tick 重建 4 個文字物件 → Comment 面板                         |
//|   * 送單檢查 retcode；手數對齊步進                                   |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input double InpLots       = 0.1;   // 交易手數
input int    InpSLPoints   = 200;   // 停損點數
input int    InpTPPoints   = 300;   // 停利點數
input int    InpMaxTradesDay = 10;  // 每日下單限制
input int    InpDayReset   = 0;     // 每日次數歸零時間
input color  InpBreakBuyClr  = clrYellow;  // 突破買進線顏色
input color  InpBreakSellClr = clrAqua;    // 跌破賣出線顏色
input color  InpTurnBuyClr   = clrMagenta; // 反彈買進線顏色
input color  InpTurnSellClr  = clrLime;    // 拉回賣出線顏色

input group "=== 資金 / 風控 ==="
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpMaxLots    = 1.0;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 168;   // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade        g_trade;
CBQBarGuard     g_guardBuy,g_guardSell;
CBQDailyCounter g_daily;

//--- 取指定顏色的第一條趨勢線在目前時間的價位，沒有回傳 0
double LineValue(const color clr)
  {
   int n=ObjectsTotal(0,0,OBJ_TREND);
   for(int i=0;i<n;i++)
     {
      string name=ObjectName(0,i,0,OBJ_TREND);
      if((color)ObjectGetInteger(0,name,OBJPROP_COLOR)!=clr) continue;
      double v=ObjectGetValueByTime(0,name,TimeCurrent(),0);
      if(v>0) return(v);
     }
   return(0.0);
  }

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   g_daily.Init(InpDayReset);
   BQML_Setup("Trendline",InpMagic);
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
   double buyLine =LineValue(InpBreakBuyClr);
   double sellLine=LineValue(InpBreakSellClr);
   double turnBuy =LineValue(InpTurnBuyClr);
   double turnSell=LineValue(InpTurnSellClr);
   BQ_Panel(StringFormat("Trendline ML\n突破買進線 %.5f\n跌破賣出線 %.5f\n反彈買進線 %.5f\n拉回賣出線 %.5f\n今日下單 %d\n%s",
                         buyLine,sellLine,turnBuy,turnSell,g_daily.Count(),g_ml.Status()));

   if(g_daily.Count()>=InpMaxTradesDay || !g_trade.SpreadOK(InpMaxSpread)) return;
   double bid=g_trade.Bid(), ask=g_trade.Ask();
   double l1=iLow(_Symbol,_Period,1), h1=iHigh(_Symbol,_Period,1);
   double slD=InpSLPoints*_Point, tpD=InpTPPoints*_Point;

   bool breakBuy =(buyLine>0  && bid>buyLine  && l1<=buyLine);
   bool turnBuyC =(turnBuy>0  && l1<=turnBuy  && bid>turnBuy);
   bool breakSell=(sellLine>0 && bid<sellLine && h1>=sellLine);
   bool turnSellC=(turnSell>0 && h1>=turnSell && bid<turnSell);

   if((breakBuy || turnBuyC) && g_trade.CountBuy()==0 && !g_guardBuy.Done(_Symbol,_Period) && g_ml.Allow(1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Buy(lots,ask-slD,ask+tpD,"TLBuy")) { g_daily.Inc(); g_guardBuy.Mark(_Symbol,_Period); }
     }
   if((breakSell || turnSellC) && g_trade.CountSell()==0 && !g_guardSell.Done(_Symbol,_Period) && g_ml.Allow(-1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Sell(lots,bid+slD,bid-tpD,"TLSell")) { g_daily.Inc(); g_guardSell.Mark(_Symbol,_Period); }
     }
  }
//+------------------------------------------------------------------+
