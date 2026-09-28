//+------------------------------------------------------------------+
//| 06_iCOOL_ML.mq5 — 第六期 EA-iCOOL 修正優化 + 機器學習               |
//|                                                                  |
//| 策略邏輯 (與原版相同)：大週期布林通道強勢，小週期回檔進場            |
//|   多：小週期收盤 > 大週期布林上軌 且 > 中軌，                        |
//|       前一根收在大週期前K低點之上、這一根跌破該低點 (回檔)           |
//|   停損 = 布林中軌；出場：小週期收盤 >= 大週期前K高點 或 價格跌破中軌  |
//|   空單對稱；每日最多 5 次                                           |
//|                                                                  |
//| 修正：                                                            |
//|   * 布林通道寫死 H4，與「大時間週期」參數不一致 → 改用參數           |
//|   * cash.mqh 每 tick 建立 iBands handle → 快取                      |
//|   * 每日次數只在 6:00~6:05 有報價才歸零 → 交易日計數器               |
//|   * 風險手數用「價格與中軌距離」，對齊交易量步進                     |
//|   * 送單檢查 retcode；停損太近自動調整                               |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input int    InpBBPeriod   = 20;          // 布林週期
input double InpBBDev      = 1.5;         // 布林標準差
input ENUM_TIMEFRAMES InpSmallTF = PERIOD_M20; // 小時間週期 (進出場判斷)
input ENUM_TIMEFRAMES InpBigTF   = PERIOD_H4;  // 大時間週期 (布林與前K高低)
input int    InpMaxTradesDay = 5;         // 每日下單次數上限
input int    InpDayReset   = 6;           // 每日次數歸零時間

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.01;  // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 1000;  // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade        g_trade;
CBQBarGuard     g_guardBuy,g_guardSell,g_guardClose;
CBQDailyCounter g_daily;

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   g_daily.Init(InpDayReset);
   BQ_hBands(_Symbol,InpBigTF,InpBBPeriod,0,InpBBDev,PRICE_CLOSE);
   BQML_Setup("iCOOL",InpMagic);
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

   double mid=BQ_Bands(_Symbol,InpBigTF,InpBBPeriod,InpBBDev,PRICE_CLOSE,0,1);
   double up =BQ_Bands(_Symbol,InpBigTF,InpBBPeriod,InpBBDev,PRICE_CLOSE,1,1);
   double dn =BQ_Bands(_Symbol,InpBigTF,InpBBPeriod,InpBBDev,PRICE_CLOSE,2,1);
   if(!BQ_Ok(mid) || !BQ_Ok(up) || !BQ_Ok(dn)) return;
   double HH=iHigh(_Symbol,InpBigTF,1), LL=iLow(_Symbol,InpBigTF,1);
   double c1=iClose(_Symbol,InpSmallTF,1), c2=iClose(_Symbol,InpSmallTF,2);
   if(HH<=0 || LL<=0 || c1<=0 || c2<=0) return;
   double ask=g_trade.Ask(), bid=g_trade.Bid();
   int nb=g_trade.CountBuy(), ns=g_trade.CountSell();

   //=== 出場 (每根小週期K棒最多一次) ===
   if(!g_guardClose.Done(_Symbol,InpSmallTF))
     {
      if(nb>0 && (c1>=HH || bid<=mid)) { g_trade.CloseBuy();  g_guardClose.Mark(_Symbol,InpSmallTF); }
      if(ns>0 && (c1<=LL || ask>=mid)) { g_trade.CloseSell(); g_guardClose.Mark(_Symbol,InpSmallTF); }
     }

   //=== 進場 ===
   if(g_daily.Count()>=InpMaxTradesDay || !g_trade.SpreadOK(InpMaxSpread)) return;

   if(g_trade.CountBuy()==0 && !g_guardBuy.Done(_Symbol,InpSmallTF) &&
      c1>up && c2>LL && c1<LL && c1>mid)
     {
      double dist=ask-mid;
      if(dist>0 && g_ml.Allow(1,dist,0))
        {
         double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*g_ml.LotFactor();
         if(g_trade.Buy(lots,mid,0,"HunterC B")) { g_daily.Inc(); g_guardBuy.Mark(_Symbol,InpSmallTF); }
        }
     }
   if(g_trade.CountSell()==0 && !g_guardSell.Done(_Symbol,InpSmallTF) &&
      c1<dn && c2<HH && c1>HH && c1<mid)
     {
      double dist=mid-bid;
      if(dist>0 && g_ml.Allow(-1,dist,0))
        {
         double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*g_ml.LotFactor();
         if(g_trade.Sell(lots,mid,0,"HunterC S")) { g_daily.Inc(); g_guardSell.Mark(_Symbol,InpSmallTF); }
        }
     }
   BQ_Panel(StringFormat("iCOOL ML\n上 %.5f 中 %.5f 下 %.5f\n今日下單 %d\n%s",up,mid,dn,g_daily.Count(),g_ml.Status()));
  }
//+------------------------------------------------------------------+
