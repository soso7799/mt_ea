//+------------------------------------------------------------------+
//| X2_FiveMinMomentum_ML.mq5 — 額外贈送 五分鐘動量交易系統 修正 + ML    |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   多：最近 6 根內收盤由下往上穿越 EMA(20)，MACD 剛由負轉正，          |
//|       且價格 >= EMA + 突破讓點，限定時段 (預設 8~11 點)              |
//|   停損 = EMA - 預設讓點；到 1R 時平一半並把停損移到進場價            |
//|   價格回到 EMA - 預設讓點 以下則全部出場；空單對稱                   |
//|                                                                  |
//| 修正：                                                            |
//|   * 平半後移保本用 OrderModify 找 magic 5555/5556 (不存在的單)，      |
//|     保本從未生效 → 修正為實際持倉                                    |
//|   * 空單條件其中一段用圖表週期 iClose(Symbol(),0,5) 與設定週期不一致  |
//|   * 1R 目標價存在全域變數，EA 重啟後遺失 → 由持倉的進場價/停損推算    |
//|   * cash_v2.mqh 每 tick 建 7 個 iMA + 2 個 iMACD handle → 快取       |
//|   * 平半 volume/2 沒對齊步進，0.01 手會出錯                           |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"

input group "=== 策略參數 ==="
input ENUM_TIMEFRAMES InpTF = PERIOD_H1; // 時間週期
input int    InpMAPeriod   = 20;    // 均線參數 (EMA)
input int    InpStartHour  = 8;     // 起始時間
input int    InpEndHour    = 11;    // 結束時間
input int    InpBreakPts   = 100;   // 突破讓點 (點)
input int    InpStopPts    = 200;   // 預設讓點 (停損/出場，點)
input int    InpMaxTradesSide = 10; // 單日單邊交易次數

input group "=== 資金 / 風控 ==="
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 手數
input double InpMaxLots    = 1.0;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 100;   // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

CBQTrade        g_trade;
CBQBarGuard     g_guard;
CBQDailyCounter g_dayBuy,g_daySell;
bool            g_halfBuy=false,g_halfSell=false;

double EMA(const int shift) { return(BQ_MA(_Symbol,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE,shift)); }

// 最近 6 根內 收盤穿越 EMA；dir=1 向上，-1 向下
bool RecentCross(const int dir)
  {
   for(int i=1;i<=5;i++)
     {
      double ca=iClose(_Symbol,InpTF,i), cb=iClose(_Symbol,InpTF,i+1);
      double ma=EMA(i), mb=EMA(i+1);
      if(!BQ_Ok(ma) || !BQ_Ok(mb) || ca<=0 || cb<=0) return(false);
      if(dir>0 && ca>ma && cb<mb) return(true);
      if(dir<0 && ca<ma && cb>mb) return(true);
     }
   return(false);
  }

void ManageHalf(const ENUM_POSITION_TYPE type)
  {
   bool isBuy=(type==POSITION_TYPE_BUY);
   if(g_trade.Count(type)==0) { if(isBuy) g_halfBuy=false; else g_halfSell=false; return; }
   double open=g_trade.OpenPrice(type), sl=g_trade.PosSL(type);
   double risk=(isBuy ? open-sl : sl-open);
   if(sl<=0 || risk<=0) return;
   double px=(isBuy ? g_trade.Bid() : g_trade.Ask());
   if(isBuy ? px>=open+risk : px<=open-risk)
     {
      bool done=(isBuy ? g_halfBuy : g_halfSell);
      if(!done)
        {
         g_trade.ClosePartial(type,0.5);
         if(isBuy) g_halfBuy=true; else g_halfSell=true;
        }
      g_trade.ModifySL(type,open);
     }
  }

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+77,InpSlippage);
   g_dayBuy.Init(0);
   g_daySell.Init(0);
   BQ_hMA(_Symbol,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   BQ_hMACD(_Symbol,InpTF,12,26,9,PRICE_CLOSE);
   BQML_Setup("FiveMinMomentum",InpMagic);
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
   double ma=EMA(1);
   if(!BQ_Ok(ma)) return;
   double bid=g_trade.Bid(), ask=g_trade.Ask();
   double stop=InpStopPts*_Point;

   //=== 出場 / 平半保本 ===
   if(g_trade.CountBuy()>0  && bid<=ma-stop) g_trade.CloseBuy();
   if(g_trade.CountSell()>0 && bid>=ma+stop) g_trade.CloseSell();
   ManageHalf(POSITION_TYPE_BUY);
   ManageHalf(POSITION_TYPE_SELL);

   //=== 進場 (多空同時只能有一邊) ===
   if(g_trade.CountAll()>0 || g_guard.Done(_Symbol,InpTF) || !g_trade.SpreadOK(InpMaxSpread)) return;
   int h=BQ_Hour();
   if(h<InpStartHour || h>InpEndHour) return;
   double m1=BQ_MACD(_Symbol,InpTF,12,26,9,PRICE_CLOSE,0,1), m2=BQ_MACD(_Symbol,InpTF,12,26,9,PRICE_CLOSE,0,2);
   if(!BQ_Ok(m1) || !BQ_Ok(m2)) return;

   double lots=InpLots;
   if(g_dayBuy.Count()<InpMaxTradesSide && m1>=0 && m2<0 && bid>=ma+InpBreakPts*_Point && RecentCross(1))
     {
      double sl=ma-stop, slD=ask-sl;
      if(slD>0 && g_ml.Allow(1,slD,slD))
        {
         lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
         lots=MathMax(lots,2*g_trade.MinLot());
         if(g_trade.Buy(lots,sl,0,"5m B")) { g_dayBuy.Inc(); g_guard.Mark(_Symbol,InpTF); g_halfBuy=false; }
        }
     }
   else if(g_daySell.Count()<InpMaxTradesSide && m1<=0 && m2>0 && bid<=ma-InpBreakPts*_Point && RecentCross(-1))
     {
      double sl=ma+stop, slD=sl-bid;
      if(slD>0 && g_ml.Allow(-1,slD,slD))
        {
         lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
         lots=MathMax(lots,2*g_trade.MinLot());
         if(g_trade.Sell(lots,sl,0,"5m S")) { g_daySell.Inc(); g_guard.Mark(_Symbol,InpTF); g_halfSell=false; }
        }
     }
   BQ_Panel(StringFormat("5分鐘動量 ML\nEMA %.5f  MACD %.5f\n今日 多 %d / 空 %d\n%s",ma,m1,g_dayBuy.Count(),g_daySell.Count(),g_ml.Status()));
  }
//+------------------------------------------------------------------+
