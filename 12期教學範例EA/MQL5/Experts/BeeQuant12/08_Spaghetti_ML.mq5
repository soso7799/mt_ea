//+------------------------------------------------------------------+
//| 08_Spaghetti_ML.mq5 — 第八期 EA-Spaghetti (三關價) 修正優化 + ML     |
//|   建議：H1 圖表                                                     |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   每天 16:00 取前 24 根K棒高低點 H/L，區間 R = H-L                  |
//|   上關價 = L + R x 1.318，下關價 = H - R x 1.318                    |
//|   16:00 之後 ~ 隔日 02:00 前，收盤突破上關價做多、跌破下關價做空     |
//|   停損 = ATR(H1,10) x 5，停利 = ATR x 7                             |
//|                                                                  |
//| 修正：                                                            |
//|   * 關價只在 16:00 那根K棒計算，EA 若在 16:00 之後才啟動，           |
//|     關價=0 → 任何價格都 > 0，一啟動就亂買 → 改為每根K棒回溯最近的     |
//|     16:00 K棒重新計算，啟動時間不影響                                |
//|   * cash.mqh iATR 每 tick 建 handle → 快取                          |
//|   * CopyXXX 沒檢查回傳值                                             |
//|   * 手數上限寫死 0.3、沒對齊步進 → 參數化並對齊                      |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input int    InpCalcHour   = 16;    // 計算關價的時間 (伺服器時)
input int    InpEndHour    = 2;     // 隔日停止進場時間
input int    InpLookBars   = 24;    // 回看K棒數
input double InpLevelK     = 1.318; // 關價倍數
input double InpSLATR      = 5;     // 停損 ATR 倍數
input double InpTPATR      = 7;     // 停利 ATR 倍數
input int    InpATRPeriod  = 10;    // ATR 週期 (H1)

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 100;   // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade    g_trade;
CBQBarGuard g_guard;       // 原版多空共用同一個「避免同根重複下單」
CBQNewBar   g_newBar;
double      g_ah=0,g_al=0; // 上關價 / 下關價
bool        g_levelsOK=false;

//--- 找最近一根小時 = InpCalcHour 的 K 棒，以其前 N 根計算關價
void CalcLevels()
  {
   g_levelsOK=false;
   MqlRates r[];
   ArraySetAsSeries(r,true);
   int n=CopyRates(_Symbol,_Period,0,InpLookBars+200,r);
   if(n<InpLookBars+2) return;
   for(int i=0;i<n-InpLookBars-1;i++)
     {
      MqlDateTime t;
      TimeToStruct(r[i].time,t);
      if(t.hour!=InpCalcHour) continue;
      double hi=r[i+1].high,lo=r[i+1].low;
      for(int j=i+1;j<=i+InpLookBars;j++)
        {
         hi=MathMax(hi,r[j].high);
         lo=MathMin(lo,r[j].low);
        }
      double range=hi-lo;
      if(range<=0) return;
      g_ah=lo+range*InpLevelK;
      g_al=hi-range*InpLevelK;
      g_levelsOK=true;
      return;
     }
  }

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   BQ_hATR(_Symbol,PERIOD_H1,InpATRPeriod);
   BQML_Setup("Spaghetti",InpMagic);
   if(PeriodSeconds(_Period)!=PeriodSeconds(PERIOD_H1))
      Print("Spaghetti：原策略設計在 H1，其他週期請重新回測參數");
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
   if(g_newBar.Check(_Symbol,_Period) || !g_levelsOK) CalcLevels();
   if(!g_levelsOK) return;

   double atr=BQ_ATR(_Symbol,PERIOD_H1,InpATRPeriod,1);
   double c1=iClose(_Symbol,_Period,1);
   if(!BQ_Ok(atr) || c1<=0) return;
   int h=BQ_Hour();
   bool session=(h>InpCalcHour || h<InpEndHour);
   bool buyCond =(c1>g_ah && session);
   bool sellCond=(c1<g_al && session);
   double ask=g_trade.Ask(), bid=g_trade.Bid();
   double slD=InpSLATR*atr, tpD=InpTPATR*atr;

   if(g_guard.Done(_Symbol,_Period) || !g_trade.SpreadOK(InpMaxSpread)) return;

   if(g_trade.CountBuy()==0 && buyCond && g_ml.Allow(1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Buy(lots,ask-slD,ask+tpD,"3Stages Long")) g_guard.Mark(_Symbol,_Period);
     }
   if(g_trade.CountSell()==0 && sellCond && g_ml.Allow(-1,slD,tpD))
     {
      double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
      if(g_trade.Sell(lots,bid+slD,bid-tpD,"3Stages Short")) g_guard.Mark(_Symbol,_Period);
     }
   BQ_Panel(StringFormat("Spaghetti ML\n上關價 %.5f\n下關價 %.5f\n%s",g_ah,g_al,g_ml.Status()));
  }
//+------------------------------------------------------------------+
