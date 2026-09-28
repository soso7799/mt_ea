//+------------------------------------------------------------------+
//| 05_Kris_ML.mq5 — 第五期 EA-Kris 修正優化 + 機器學習                 |
//|                                                                  |
//| 策略邏輯 (與原版相同)：雙均線回檔進場                               |
//|   多：短均>=長均，收盤回落到兩均線之間，且離長均線 >= 縫隙           |
//|   停損 = 長均線，停利 = (進場價-長均線) x 停利倍數                   |
//|   出場：收盤跌破長均線且連續兩根收黑                                  |
//|                                                                  |
//| 修正：                                                            |
//|   * cash.mqh 每 tick 建立均線 handle → 快取                         |
//|   * 平倉函式檢查 MagicNumber+11 (不存在的單) → 移除                  |
//|   * 每日次數只在 6:00~6:05 有報價才歸零 → 交易日計數器               |
//|   * 停損距離太近被拒單 → 自動推到券商最小距離                        |
//|   * 手數對齊交易量步進；送單檢查 retcode                             |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input int    InpShortMA    = 10;    // 短均線 (SMA)
input int    InpLongMA     = 40;    // 長均線 (SMA)
input double InpTPMult     = 3;     // 停利倍數 (x 停損距離)
input int    InpGap        = 350;   // 收盤與長均線最小縫隙 (點)
input int    InpMinDist    = 100;   // 現價與長均線最小距離 (點)
input int    InpMaxTradesDay=1;     // 每日下單次數上限
input int    InpDayReset   = 6;     // 每日次數歸零時間
input ENUM_TIMEFRAMES InpGuardTF = PERIOD_H4; // 每根K棒最多進出一次的週期

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 9999;  // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade        g_trade;
CBQBarGuard     g_guardOpen,g_guardClose;
CBQDailyCounter g_daily;

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   g_daily.Init(InpDayReset);
   BQ_hMA(_Symbol,_Period,InpShortMA,0,MODE_SMA,PRICE_CLOSE);
   BQ_hMA(_Symbol,_Period,InpLongMA,0,MODE_SMA,PRICE_CLOSE);
   BQML_Setup("Kris",InpMagic);
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

   double pro  =BQ_MA(_Symbol,_Period,InpShortMA,0,MODE_SMA,PRICE_CLOSE,1);
   double trend=BQ_MA(_Symbol,_Period,InpLongMA,0,MODE_SMA,PRICE_CLOSE,1);
   if(!BQ_Ok(pro) || !BQ_Ok(trend)) return;
   double c1=iClose(_Symbol,_Period,1), o1=iOpen(_Symbol,_Period,1);
   double c2=iClose(_Symbol,_Period,2), o2=iOpen(_Symbol,_Period,2);
   double ask=g_trade.Ask(), bid=g_trade.Bid();
   int nb=g_trade.CountBuy(), ns=g_trade.CountSell();

   //=== 出場 ===
   if(!g_guardClose.Done(_Symbol,InpGuardTF))
     {
      if(nb>0 && c1<trend && c1<o1 && c2<o2) { g_trade.CloseBuy();  g_guardClose.Mark(_Symbol,InpGuardTF); }
      if(ns>0 && c1>trend && c1>o1 && c2>o2) { g_trade.CloseSell(); g_guardClose.Mark(_Symbol,InpGuardTF); }
     }

   //=== 進場 ===
   if(nb+ns>0 || g_guardOpen.Done(_Symbol,InpGuardTF) || g_daily.Count()>=InpMaxTradesDay) return;
   if(BQ_Hour()==0 || !g_trade.SpreadOK(InpMaxSpread)) return;

   bool buyCond =(pro>=trend && c1>trend && c1<pro && c1-trend>=InpGap*_Point && bid>=trend+InpMinDist*_Point);
   bool sellCond=(pro<=trend && c1<trend && c1>pro && trend-c1>=InpGap*_Point && bid<=trend-InpMinDist*_Point);

   if(buyCond)
     {
      double dist=ask-trend, tp=ask+dist*InpTPMult;
      if(dist>0 && g_ml.Allow(1,dist,dist*InpTPMult))
        {
         double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*g_ml.LotFactor();
         if(g_trade.Buy(lots,trend,tp,"Kris B")) { g_daily.Inc(); g_guardOpen.Mark(_Symbol,InpGuardTF); }
        }
     }
   else if(sellCond)
     {
      double dist=trend-bid, tp=bid-dist*InpTPMult;
      if(dist>0 && g_ml.Allow(-1,dist,dist*InpTPMult))
        {
         double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*g_ml.LotFactor();
         if(g_trade.Sell(lots,trend,tp,"Kris S")) { g_daily.Inc(); g_guardOpen.Mark(_Symbol,InpGuardTF); }
        }
     }
   BQ_Panel(StringFormat("Kris ML\n短均 %.5f  長均 %.5f\n今日下單 %d\n%s",pro,trend,g_daily.Count(),g_ml.Status()));
  }
//+------------------------------------------------------------------+
