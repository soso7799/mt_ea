//+------------------------------------------------------------------+
//| 04_BBFF_ML.mq5 — 第四期 EA-BBFF v2.02 修正優化 + 機器學習           |
//|                                                                  |
//| 策略邏輯 (與原版相同)：夜盤 (預設 21:00~01:00) 布林通道逆勢         |
//|   價格碰到上軌附近 → 做空；碰到下軌附近 → 做多                      |
//|   已有多單又碰上軌 → 平多翻空；已有空單又碰下軌 → 平空翻多          |
//|   停損 = ATR x SL倍數，停利 = ATR x TP倍數；時段外全部平倉          |
//|                                                                  |
//| 修正：                                                            |
//|   * 每個 tick 重新建立 iATR / iBands handle (記憶體洩漏) → 快取       |
//|   * 用 trade.RequestType() (最後一次送單類型) 判斷持倉方向，         |
//|     平倉後就錯 → 改用實際持倉方向                                    |
//|   * 「23 點後每個 tick 都把次數歸零」使次數限制失效 → 交易日計數器    |
//|   * 手數對齊交易量步進；送單檢查 retcode                             |
//|   * 原版多空共用同一 MagicNumber → 保留 (相容舊單)                   |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 交易時段 ==="
input int    InpStartHour  = 21;    // 開始時間 (伺服器時)
input int    InpStopHour   = 1;     // 結束時間 (伺服器時)
input bool   InpMon        = true;  // 週一交易
input bool   InpTue        = true;  // 週二交易
input bool   InpWed        = true;  // 週三交易
input bool   InpThu        = false; // 週四交易
input bool   InpFri        = true;  // 週五交易

input group "=== 策略參數 ==="
input int    InpBandsPeriod = 7;    // 布林 / ATR 週期
input double InpBandsDev    = 1.5;  // 布林標準差
input int    InpTPMult      = 16;   // 停利 ATR 倍數
input int    InpSLMult      = 5;    // 停損 ATR 倍數
input double InpDivWork     = 20;   // 觸發區間 ± (點)
input double InpDivSignal   = 20;   // 價格偏移 (點)
input bool   InpWorkAlt     = true; // 反向訊號時翻單
input int    InpMaxTradesDay= 10;   // 每日下單次數上限
input int    InpDayReset    = 23;   // 每日次數歸零時間
input ENUM_TIMEFRAMES InpGuardTF = PERIOD_M5; // 每根K棒最多下一次單的週期

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 500;   // 餘額低於此值停止交易
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.2;   // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 123;   // MagicNumber (多空共用)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade        g_trade;
CBQBarGuard     g_guard;
CBQDailyCounter g_daily;

bool WorkDay()
  {
   switch(BQ_DayOfWeek())
     {
      case 1: return(InpMon);
      case 2: return(InpTue);
      case 3: return(InpWed);
      case 4: return(InpThu);
      case 5: return(InpFri);
     }
   return(false);
  }

bool InSession()
  {
   int h=BQ_Hour();
   if(InpStartHour<InpStopHour) return(h>=InpStartHour && h<InpStopHour);
   return(h>=InpStartHour || h<InpStopHour);
  }

bool OpenBuy(const double atr,const string cmt)
  {
   double ask=g_trade.Ask();
   double sl=ask-atr*InpSLMult, tp=ask+atr*InpTPMult;
   if(!g_ml.Allow(1,atr*InpSLMult,atr*InpTPMult)) return(false);
   double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,atr*InpSLMult,InpLots,InpMaxLots)*g_ml.LotFactor();
   return(g_trade.Buy(lots,sl,tp,cmt));
  }

bool OpenSell(const double atr,const string cmt)
  {
   double bid=g_trade.Bid();
   double sl=bid+atr*InpSLMult, tp=bid-atr*InpTPMult;
   if(!g_ml.Allow(-1,atr*InpSLMult,atr*InpTPMult)) return(false);
   double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,atr*InpSLMult,InpLots,InpMaxLots)*g_ml.LotFactor();
   return(g_trade.Sell(lots,sl,tp,cmt));
  }

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic,InpSlippage);
   g_daily.Init(InpDayReset);
   BQ_hATR(_Symbol,_Period,InpBandsPeriod);
   BQ_hBands(_Symbol,_Period,InpBandsPeriod,0,InpBandsDev,PRICE_CLOSE);
   BQML_Setup("BBFF",InpMagic);
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

   bool work=InSession() && WorkDay();
   if(!work)
     {
      if(g_trade.CountAll()>0) g_trade.CloseAll();
      return;
     }
   double atr=BQ_ATR(_Symbol,_Period,InpBandsPeriod,1);
   double up =BQ_Bands(_Symbol,_Period,InpBandsPeriod,InpBandsDev,PRICE_CLOSE,1,0);
   double lo =BQ_Bands(_Symbol,_Period,InpBandsPeriod,InpBandsDev,PRICE_CLOSE,2,0);
   if(!BQ_Ok(atr) || !BQ_Ok(up) || !BQ_Ok(lo) || atr<=0) return;
   if(g_guard.Done(_Symbol,InpGuardTF) || g_daily.Count()>=InpMaxTradesDay || !g_trade.SpreadOK(InpMaxSpread))
      return;

   double ask=g_trade.Ask(),bid=g_trade.Bid();
   double work_=InpDivWork*_Point, sig=InpDivSignal*_Point;
   bool nearUpper=(ask-sig>=up-work_ && ask-sig<=up+work_);
   bool nearLower=(bid+sig<=lo+work_ && bid+sig>=lo-work_);
   int nb=g_trade.CountBuy(), ns=g_trade.CountSell();

   if(nb+ns==0)
     {
      if(nearUpper && OpenSell(atr,"BBFF Sell")) { g_daily.Inc(); g_guard.Mark(_Symbol,InpGuardTF); }
      else if(nearLower && OpenBuy(atr,"BBFF Buy")) { g_daily.Inc(); g_guard.Mark(_Symbol,InpGuardTF); }
     }
   else if(InpWorkAlt)
     {
      if(nb>0 && nearUpper)
        {
         g_trade.CloseBuy();
         if(OpenSell(atr,"Turn Sell")) { g_daily.Inc(); g_guard.Mark(_Symbol,InpGuardTF); }
        }
      else if(ns>0 && nearLower)
        {
         g_trade.CloseSell();
         if(OpenBuy(atr,"Turn Buy")) { g_daily.Inc(); g_guard.Mark(_Symbol,InpGuardTF); }
        }
     }
   BQ_Panel(StringFormat("BBFF ML\n上軌 %.5f  下軌 %.5f\n今日下單 %d\n%s",up,lo,g_daily.Count(),g_ml.Status()));
  }
//+------------------------------------------------------------------+
