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
//| ★ 掛在任何圖表皆可：依 InpSymbols / InpBaseTF 交易 (預設=原版商品與週期) |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"
#include "BeeQuant/BQ_Multi.mqh"

input group "=== 交易商品 / 週期 (掛在任何圖表皆可) ==="
input string          InpSymbols = "GBPJPY"; // 交易商品 (逗號分隔；原版開發商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_H1; // 策略週期 (原版圖表週期)

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

#include "BeeQuant/BQ_MLInputs.mqh"

//+------------------------------------------------------------------+
//| 策略本體：每個交易商品一個物件 (m_sym / m_tf 取代 _Symbol / _Period) |
//+------------------------------------------------------------------+
class CStrat
  {
public:
   string          m_sym;    // 交易商品
   ENUM_TIMEFRAMES m_tf;     // 策略週期
   string          m_panel;  // 面板文字
   CBQMLFilter     m_ml;     // 此商品的 ML 過濾器

                     CStrat() {}
   void              SetPanel(const string s) { m_panel=s; }

   CBQTrade        m_trade;
   CBQBarGuard     m_guardBuy,m_guardSell;
   CBQDailyCounter m_daily;

   void Trail(const ENUM_POSITION_TYPE type)
     {
      if(m_trade.Count(type)==0) return;
      bool isBuy=(type==POSITION_TYPE_BUY);
      double pt=_Point;
      double open=m_trade.OpenPrice(type), sl=m_trade.PosSL(type);
      datetime t=m_trade.OpenTime(type);
      if(isBuy)
        {
         double hi=BQ_HighSince(m_sym,m_tf,t);
         if(!BQ_Ok(hi)) return;
         bool trig=(InpLegacyTrail ? hi-InpTrigLong*pt>sl : hi-open>=InpTrigLong*pt);
         double nsl=hi-InpPullLong*pt;
         if(trig && nsl>sl+2*pt) m_trade.ModifySL(type,nsl);
        }
      else
        {
         double lo=BQ_LowSince(m_sym,m_tf,t);
         if(!BQ_Ok(lo)) return;
         bool trig=(InpLegacyTrail ? lo+InpTrigShort*pt<sl : open-lo>=InpTrigShort*pt);
         double nsl=lo+InpPullShort*pt;
         if(trig && (sl<=0 || nsl<sl-2*pt)) m_trade.ModifySL(type,nsl);
        }
     }

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+1,InpSlippage);
      m_daily.Init(InpDayReset);
      BQ_hMA(m_sym,m_tf,InpFastLong,0,MODE_EMA,PRICE_CLOSE);
      BQ_hMA(m_sym,m_tf,InpSlowLong,0,MODE_SMA,PRICE_CLOSE);
      BQ_hMA(m_sym,m_tf,InpFastShort,0,MODE_EMA,PRICE_CLOSE);
      BQ_hMA(m_sym,m_tf,InpSlowShort,0,MODE_SMA,PRICE_CLOSE);
      BQ_hRSI(m_sym,m_tf,InpRSIPeriod,PRICE_CLOSE);
      BQML_Setup(m_ml,"Jimmy",m_sym,m_tf,InpMagic);
      return(INIT_SUCCEEDED);
     }

   void Shutdown()
     {
      m_ml.Deinit();
     }


   void Tick()
     {
      m_ml.OnTick();
      Trail(POSITION_TYPE_BUY);
      Trail(POSITION_TYPE_SELL);

      if(m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread)) return;

      double rsi=BQ_RSI(m_sym,m_tf,InpRSIPeriod,PRICE_CLOSE,1);
      double fL=BQ_MA(m_sym,m_tf,InpFastLong,0,MODE_EMA,PRICE_CLOSE,1);
      double sL=BQ_MA(m_sym,m_tf,InpSlowLong,0,MODE_SMA,PRICE_CLOSE,1);
      double fS=BQ_MA(m_sym,m_tf,InpFastShort,0,MODE_EMA,PRICE_CLOSE,1);
      double sS=BQ_MA(m_sym,m_tf,InpSlowShort,0,MODE_SMA,PRICE_CLOSE,1);
      if(!BQ_Ok(rsi)||!BQ_Ok(fL)||!BQ_Ok(sL)||!BQ_Ok(fS)||!BQ_Ok(sS)) return;
      double o1=iOpen(m_sym,m_tf,1), c1=iClose(m_sym,m_tf,1);
      double ask=m_trade.Ask(), bid=m_trade.Bid();

      if(rsi>50 && fL<sL && o1<fL && c1>sL && m_trade.CountBuy()==0 && !m_guardBuy.Done(m_sym,m_tf))
        {
         double slD=InpSLLong*_Point;
         if(m_ml.Allow(1,slD,slD))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Buy(lots,ask-slD,0,"Buy")) { m_daily.Inc(); m_guardBuy.Mark(m_sym,m_tf); }
           }
        }
      if(rsi<50 && fS>sS && o1>fS && c1<sS && m_trade.CountSell()==0 && !m_guardSell.Done(m_sym,m_tf))
        {
         double slD=InpSLShort*_Point;
         if(m_ml.Allow(-1,slD,slD))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Sell(lots,bid+slD,0,"Short")) { m_daily.Inc(); m_guardSell.Mark(m_sym,m_tf); }
           }
        }
      SetPanel(StringFormat("Jimmy ML\nRSI %.1f\n今日下單 %d\n%s",rsi,m_daily.Count(),m_ml.Status()));
     }
  };

//+------------------------------------------------------------------+
//| 多商品執行：OnTick (圖表商品報價) + OnTimer (每秒) 輪流執行每個商品  |
//+------------------------------------------------------------------+
CStrat *g_strats[];

bool AddStrat(CStrat *p)
  {
   if(p.Setup()!=INIT_SUCCEEDED)
     {
      PrintFormat("Jimmy：%s 初始化失敗，略過此商品",p.m_sym);
      delete p;
      return(false);
     }
   int k=ArraySize(g_strats);
   ArrayResize(g_strats,k+1);
   g_strats[k]=p;
   return(true);
  }

int OnInit()
  {
   string syms[];
   int n=BQ_ParseSymbols(InpSymbols,syms);
   for(int i=0;i<n;i++)
     {
      CStrat *p=new CStrat;
      p.m_sym=syms[i];
      p.m_tf=BQ_TF(InpBaseTF);
      AddStrat(p);
     }
   if(ArraySize(g_strats)==0)
     {
      Print("Jimmy：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("Jimmy：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
               EnumToString(BQ_TF(InpBaseTF)),_Symbol);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i=0;i<ArraySize(g_strats);i++)
     {
      g_strats[i].Shutdown();
      delete g_strats[i];
     }
   ArrayResize(g_strats,0);
   BQ_ReleaseIndicators();
   Comment("");
  }

double OnTester() { return(BQ_TesterScore()); }

void RunAll()
  {
   string body="";
   for(int i=0;i<ArraySize(g_strats);i++)
     {
      g_strats[i].Tick();
      body+=BQ_PanelLine(g_strats[i].m_sym,g_strats[i].m_panel);
     }
   BQ_PanelMulti("Jimmy ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
