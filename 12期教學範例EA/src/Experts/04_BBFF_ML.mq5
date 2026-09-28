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
//| ★ 掛在任何圖表皆可：依 InpSymbols / InpBaseTF 交易 (預設=原版商品與週期) |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"
#include "BeeQuant/BQ_Multi.mqh"

input group "=== 交易商品 / 週期 (掛在任何圖表皆可) ==="
input string          InpSymbols = ""; // 交易商品 (逗號分隔；原版未指定商品；空白=圖表商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_CURRENT; // 策略週期 (原版圖表週期；目前=圖表週期)

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
   CBQBarGuard     m_guard;
   CBQDailyCounter m_daily;

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
      double ask=m_trade.Ask();
      double sl=ask-atr*InpSLMult, tp=ask+atr*InpTPMult;
      if(!m_ml.Allow(1,atr*InpSLMult,atr*InpTPMult)) return(false);
      double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,atr*InpSLMult,InpLots,InpMaxLots)*m_ml.LotFactor();
      return(m_trade.Buy(lots,sl,tp,cmt));
     }

   bool OpenSell(const double atr,const string cmt)
     {
      double bid=m_trade.Bid();
      double sl=bid+atr*InpSLMult, tp=bid-atr*InpTPMult;
      if(!m_ml.Allow(-1,atr*InpSLMult,atr*InpTPMult)) return(false);
      double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,atr*InpSLMult,InpLots,InpMaxLots)*m_ml.LotFactor();
      return(m_trade.Sell(lots,sl,tp,cmt));
     }

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic,InpSlippage);
      m_daily.Init(InpDayReset);
      BQ_hATR(m_sym,m_tf,InpBandsPeriod);
      BQ_hBands(m_sym,m_tf,InpBandsPeriod,0,InpBandsDev,PRICE_CLOSE);
      BQML_Setup(m_ml,"BBFF",m_sym,m_tf,InpMagic);
      return(INIT_SUCCEEDED);
     }

   void Shutdown()
     {
      m_ml.Deinit();
     }


   void Tick()
     {
      m_ml.OnTick();
      if(AccountInfoDouble(ACCOUNT_BALANCE)<=InpMinBalance) return;

      bool work=InSession() && WorkDay();
      if(!work)
        {
         if(m_trade.CountAll()>0) m_trade.CloseAll();
         return;
        }
      double atr=BQ_ATR(m_sym,m_tf,InpBandsPeriod,1);
      double up =BQ_Bands(m_sym,m_tf,InpBandsPeriod,InpBandsDev,PRICE_CLOSE,1,0);
      double lo =BQ_Bands(m_sym,m_tf,InpBandsPeriod,InpBandsDev,PRICE_CLOSE,2,0);
      if(!BQ_Ok(atr) || !BQ_Ok(up) || !BQ_Ok(lo) || atr<=0) return;
      if(m_guard.Done(m_sym,InpGuardTF) || m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread))
         return;

      double ask=m_trade.Ask(),bid=m_trade.Bid();
      double work_=InpDivWork*_Point, sig=InpDivSignal*_Point;
      bool nearUpper=(ask-sig>=up-work_ && ask-sig<=up+work_);
      bool nearLower=(bid+sig<=lo+work_ && bid+sig>=lo-work_);
      int nb=m_trade.CountBuy(), ns=m_trade.CountSell();

      if(nb+ns==0)
        {
         if(nearUpper && OpenSell(atr,"BBFF Sell")) { m_daily.Inc(); m_guard.Mark(m_sym,InpGuardTF); }
         else if(nearLower && OpenBuy(atr,"BBFF Buy")) { m_daily.Inc(); m_guard.Mark(m_sym,InpGuardTF); }
        }
      else if(InpWorkAlt)
        {
         if(nb>0 && nearUpper)
           {
            m_trade.CloseBuy();
            if(OpenSell(atr,"Turn Sell")) { m_daily.Inc(); m_guard.Mark(m_sym,InpGuardTF); }
           }
         else if(ns>0 && nearLower)
           {
            m_trade.CloseSell();
            if(OpenBuy(atr,"Turn Buy")) { m_daily.Inc(); m_guard.Mark(m_sym,InpGuardTF); }
           }
        }
      SetPanel(StringFormat("BBFF ML\n上軌 %.5f  下軌 %.5f\n今日下單 %d\n%s",up,lo,m_daily.Count(),m_ml.Status()));
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
      PrintFormat("BBFF：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("BBFF：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("BBFF：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("BBFF ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
