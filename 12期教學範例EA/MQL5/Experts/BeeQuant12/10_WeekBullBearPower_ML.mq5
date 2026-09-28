//+------------------------------------------------------------------+
//| 10_WeekBullBearPower_ML.mq5 — 第十期 WeekBullBear 周天成 修正 + ML |
//|   原開發：GBPJPY D1 (作者 Mar/TINA，調整 CASH)                        |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   牛力 = 收盤 - 最低，熊力 = 最高 - 收盤                             |
//|   上週牛力 > 熊力 (趨勢偏多) 且 昨日牛力 > 熊力 → 每日開盤做多       |
//|   空單對稱；停損 ATR(D1,3) x 2，停利 ATR x 6；當日 23:50 平倉         |
//|                                                                  |
//| 修正：                                                            |
//|   * 進場寫死 00:00~00:05 → 改以「日K開盤後 N 分鐘內」判斷，           |
//|     日K不是從 0 點開始的券商也能正確運作                              |
//|   * 每日次數在 23:55 後才歸零、只靠有無報價 → 交易日計數器           |
//|   * cash.mqh iATR 每 tick 建 handle → 快取                          |
//|   * 手數對齊交易量步進；送單檢查 retcode                             |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input ENUM_TIMEFRAMES InpSmallTF = PERIOD_D1; // 小時間週期 (日)
input ENUM_TIMEFRAMES InpBigTF   = PERIOD_W1; // 大時間週期 (週)
input int    InpATRPeriod  = 3;     // ATR 週期
input double InpSLMult     = 2;     // 停損 ATR 倍數
input double InpTPMult     = 6;     // 停利 ATR 倍數
input int    InpEntryMinutes = 5;   // 開盤後幾分鐘內可進場
input int    InpExitHour   = 23;    // 當日平倉時
input int    InpExitMinute = 50;    // 當日平倉分
input int    InpMaxTradesDay = 1;   // 每日僅下單次數

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.01;  // 固定手數
input double InpMaxLots    = 0.5;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 1234;  // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade        g_trade;
CBQBarGuard     g_guard;
CBQDailyCounter g_daily;

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   g_daily.Init(0);
   BQ_hATR(_Symbol,InpSmallTF,InpATRPeriod);
   BQML_Setup("WeekBullBear",InpMagic);
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

   int h=BQ_Hour(), m=BQ_Minute();

   //=== 當日收盤前平倉 ===
   if(h==InpExitHour && m>=InpExitMinute)
     {
      if(g_trade.CountBuy()>0)  g_trade.CloseBuy();
      if(g_trade.CountSell()>0) g_trade.CloseSell();
      return;
     }

   //=== 進場：日K開盤後 N 分鐘內，週一~週五 ===
   datetime dayOpen=iTime(_Symbol,InpSmallTF,0);
   if(dayOpen==0 || TimeCurrent()-dayOpen>InpEntryMinutes*60) return;
   int dow=BQ_DayOfWeek();
   if(dow<1 || dow>5) return;
   if(g_guard.Done(_Symbol,InpSmallTF) || g_daily.Count()>=InpMaxTradesDay || !g_trade.SpreadOK(InpMaxSpread)) return;
   if(g_trade.CountAll()>0) return;

   double atr=BQ_ATR(_Symbol,InpSmallTF,InpATRPeriod,1);
   double dO=iOpen(_Symbol,InpSmallTF,1), dC=iClose(_Symbol,InpSmallTF,1), dH=iHigh(_Symbol,InpSmallTF,1), dL=iLow(_Symbol,InpSmallTF,1);
   double wC=iClose(_Symbol,InpBigTF,1), wH=iHigh(_Symbol,InpBigTF,1), wL=iLow(_Symbol,InpBigTF,1);
   if(!BQ_Ok(atr) || dO<=0 || wC<=0) return;

   double weekBull=MathAbs(wC-wL), weekBear=MathAbs(wH-wC);   // 先看趨勢
   double dayBull =MathAbs(dC-dL), dayBear =MathAbs(dH-dC);   // 再看多空
   double slD=atr*InpSLMult, tpD=atr*InpTPMult;
   double ask=g_trade.Ask(), bid=g_trade.Bid();

   if(weekBull>weekBear && dayBull>dayBear && g_ml.Allow(1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Buy(lots,ask-slD,ask+tpD,"Week Bull-Buy")) { g_daily.Inc(); g_guard.Mark(_Symbol,InpSmallTF); }
     }
   else if(weekBull<weekBear && dayBull<dayBear && g_ml.Allow(-1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Sell(lots,bid+slD,bid-tpD,"Week Bear-Sell")) { g_daily.Inc(); g_guard.Mark(_Symbol,InpSmallTF); }
     }
   BQ_Panel(StringFormat("WeekBullBear ML\n週牛力 %.5f 週熊力 %.5f\n日牛力 %.5f 日熊力 %.5f\n%s",
                         weekBull,weekBear,dayBull,dayBear,g_ml.Status()));
  }
//+------------------------------------------------------------------+
