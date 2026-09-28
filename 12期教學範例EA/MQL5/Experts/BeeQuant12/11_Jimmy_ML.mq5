//+------------------------------------------------------------------+
//| 11_Jimmy_ML.mq5 — 第十一期 EA-Jimmy 修正優化 + 機器學習             |
//|   原開發：GBPJPY H1 (作者 帥哥Jimmy，調整 CASH)                      |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   多：RSI(6)>50、快線(EMA)<慢線(SMA)，K棒開在快線下、收在慢線上      |
//|   空：RSI(6)<50、快線>慢線，K棒開在快線上、收在慢線下                |
//|   固定點數停損；獲利達觸發點數後，以「進場後最高點-拉回點數」追蹤     |
//|   多空用不同的均線參數                                              |
//|                                                                  |
//| 修正：                                                            |
//|   * 每個 tick 複製 100000 根 OHLC/時間/量 + 建 4 個 iMA handle        |
//|     (從不釋放) → 只取需要的值並快取 handle，回測速度提升數十倍        |
//|   * 追蹤停利的「觸發點數」是跟停損價比較，幾乎一定成立，觸發形同虛設  |
//|     → 改為「最大浮盈 >= 觸發點數」才開始追蹤 (可切回原版行為)         |
//|   * 停損出場後同一根K棒可立刻再進場 → 每根K棒最多進場一次             |
//|   * 改單沒帶 TP；進場時間點寫死 H1 → 用圖表週期                      |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include <BeeQuant/BQ_Trade.mqh>
#include <BeeQuant/BQ_Indicators.mqh>

input group "=== 多方參數 ==="
input int    InpFastLong   = 33;    // 多方快線 (EMA)
input int    InpSlowLong   = 69;    // 多方慢線 (SMA)
input double InpSLLong     = 700;   // 多單停損點數
input double InpTrigLong   = 500;   // 多單移動停利觸發點數
input double InpPullLong   = 1850;  // 多單移動停利拉回點數

input group "=== 空方參數 ==="
input int    InpFastShort  = 45;    // 空方快線 (EMA)
input int    InpSlowShort  = 102;   // 空方慢線 (SMA)
input double InpSLShort    = 1800;  // 空單停損點數
input double InpTrigShort  = 300;   // 空單移動停利觸發點數
input double InpPullShort  = 3100;  // 空單移動停利拉回點數

input group "=== 共用參數 ==="
input int    InpRSIPeriod  = 6;     // RSI 週期
input bool   InpLegacyTrail= false; // 使用原版追蹤觸發邏輯
input int    InpMaxTradesDay = 2;   // 每日下單次數上限
input int    InpDayReset   = 6;     // 每日次數歸零時間

input group "=== 資金 / 風控 ==="
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 固定手數 (原版：初始手數)
input double InpMaxLots    = 1.0;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 1491491; // MagicNumber (空單 = +1，沿用原版)

#include <BeeQuant/BQ_MLInputs.mqh>

CBQTrade        g_trade;
CBQBarGuard     g_guardBuy,g_guardSell;
CBQDailyCounter g_daily;

void Trail(const ENUM_POSITION_TYPE type)
  {
   if(g_trade.Count(type)==0) return;
   bool isBuy=(type==POSITION_TYPE_BUY);
   double pt=_Point;
   double open=g_trade.OpenPrice(type), sl=g_trade.PosSL(type);
   datetime t=g_trade.OpenTime(type);
   if(isBuy)
     {
      double hi=BQ_HighSince(_Symbol,_Period,t);
      if(!BQ_Ok(hi)) return;
      bool trig=(InpLegacyTrail ? hi-InpTrigLong*pt>sl : hi-open>=InpTrigLong*pt);
      double nsl=hi-InpPullLong*pt;
      if(trig && nsl>sl+2*pt) g_trade.ModifySL(type,nsl);
     }
   else
     {
      double lo=BQ_LowSince(_Symbol,_Period,t);
      if(!BQ_Ok(lo)) return;
      bool trig=(InpLegacyTrail ? lo+InpTrigShort*pt<sl : open-lo>=InpTrigShort*pt);
      double nsl=lo+InpPullShort*pt;
      if(trig && (sl<=0 || nsl<sl-2*pt)) g_trade.ModifySL(type,nsl);
     }
  }

int OnInit()
  {
   g_trade.Init(_Symbol,InpMagic,InpMagic+1,InpSlippage);
   g_daily.Init(InpDayReset);
   BQ_hMA(_Symbol,_Period,InpFastLong,0,MODE_EMA,PRICE_CLOSE);
   BQ_hMA(_Symbol,_Period,InpSlowLong,0,MODE_SMA,PRICE_CLOSE);
   BQ_hMA(_Symbol,_Period,InpFastShort,0,MODE_EMA,PRICE_CLOSE);
   BQ_hMA(_Symbol,_Period,InpSlowShort,0,MODE_SMA,PRICE_CLOSE);
   BQ_hRSI(_Symbol,_Period,InpRSIPeriod,PRICE_CLOSE);
   BQML_Setup("Jimmy",InpMagic);
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
   Trail(POSITION_TYPE_BUY);
   Trail(POSITION_TYPE_SELL);

   if(g_daily.Count()>=InpMaxTradesDay || !g_trade.SpreadOK(InpMaxSpread)) return;

   double rsi=BQ_RSI(_Symbol,_Period,InpRSIPeriod,PRICE_CLOSE,1);
   double fL=BQ_MA(_Symbol,_Period,InpFastLong,0,MODE_EMA,PRICE_CLOSE,1);
   double sL=BQ_MA(_Symbol,_Period,InpSlowLong,0,MODE_SMA,PRICE_CLOSE,1);
   double fS=BQ_MA(_Symbol,_Period,InpFastShort,0,MODE_EMA,PRICE_CLOSE,1);
   double sS=BQ_MA(_Symbol,_Period,InpSlowShort,0,MODE_SMA,PRICE_CLOSE,1);
   if(!BQ_Ok(rsi)||!BQ_Ok(fL)||!BQ_Ok(sL)||!BQ_Ok(fS)||!BQ_Ok(sS)) return;
   double o1=iOpen(_Symbol,_Period,1), c1=iClose(_Symbol,_Period,1);
   double ask=g_trade.Ask(), bid=g_trade.Bid();

   if(rsi>50 && fL<sL && o1<fL && c1>sL && g_trade.CountBuy()==0 && !g_guardBuy.Done(_Symbol,_Period))
     {
      double slD=InpSLLong*_Point;
      if(g_ml.Allow(1,slD,slD))
        {
         double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
         if(g_trade.Buy(lots,ask-slD,0,"Buy")) { g_daily.Inc(); g_guardBuy.Mark(_Symbol,_Period); }
        }
     }
   if(rsi<50 && fS>sS && o1>fS && c1<sS && g_trade.CountSell()==0 && !g_guardSell.Done(_Symbol,_Period))
     {
      double slD=InpSLShort*_Point;
      if(g_ml.Allow(-1,slD,slD))
        {
         double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*g_ml.LotFactor();
         if(g_trade.Sell(lots,bid+slD,0,"Short")) { g_daily.Inc(); g_guardSell.Mark(_Symbol,_Period); }
        }
     }
   BQ_Panel(StringFormat("Jimmy ML\nRSI %.1f\n今日下單 %d\n%s",rsi,g_daily.Count(),g_ml.Status()));
  }
//+------------------------------------------------------------------+
