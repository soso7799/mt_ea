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
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_H1; // 策略週期 (原版圖表週期)

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

                     CStrat() { m_ah=0; m_al=0; m_levelsOK=false; }
   void              SetPanel(const string s) { m_panel=s; }

   CBQTrade    m_trade;
   CBQBarGuard m_guard;       // 原版多空共用同一個「避免同根重複下單」
   CBQNewBar   m_newBar;
   double m_ah,m_al; // 上關價 / 下關價
   bool m_levelsOK;

   //--- 找最近一根小時 = InpCalcHour 的 K 棒，以其前 N 根計算關價
   void CalcLevels()
     {
      m_levelsOK=false;
      MqlRates r[];
      ArraySetAsSeries(r,true);
      int n=CopyRates(m_sym,m_tf,0,InpLookBars+200,r);
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
         m_ah=lo+range*InpLevelK;
         m_al=hi-range*InpLevelK;
         m_levelsOK=true;
         return;
        }
     }

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      BQ_hATR(m_sym,PERIOD_H1,InpATRPeriod);
      BQML_Setup(m_ml,"Spaghetti",m_sym,m_tf,InpMagic);
      if(PeriodSeconds(m_tf)!=PeriodSeconds(PERIOD_H1))
         Print("Spaghetti：原策略設計在 H1，其他週期請重新回測參數");
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
      if(m_newBar.Check(m_sym,m_tf) || !m_levelsOK) CalcLevels();
      if(!m_levelsOK) return;

      double atr=BQ_ATR(m_sym,PERIOD_H1,InpATRPeriod,1);
      double c1=iClose(m_sym,m_tf,1);
      if(!BQ_Ok(atr) || c1<=0) return;
      int h=BQ_Hour();
      bool session=(h>InpCalcHour || h<InpEndHour);
      bool buyCond =(c1>m_ah && session);
      bool sellCond=(c1<m_al && session);
      double ask=m_trade.Ask(), bid=m_trade.Bid();
      double slD=InpSLATR*atr, tpD=InpTPATR*atr;

      if(m_guard.Done(m_sym,m_tf) || !m_trade.SpreadOK(InpMaxSpread)) return;

      if(m_trade.CountBuy()==0 && buyCond && m_ml.Allow(1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Buy(lots,ask-slD,ask+tpD,"3Stages Long")) m_guard.Mark(m_sym,m_tf);
        }
      if(m_trade.CountSell()==0 && sellCond && m_ml.Allow(-1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Sell(lots,bid+slD,bid-tpD,"3Stages Short")) m_guard.Mark(m_sym,m_tf);
        }
      SetPanel(StringFormat("Spaghetti ML\n上關價 %.5f\n下關價 %.5f\n%s",m_ah,m_al,m_ml.Status()));
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
      PrintFormat("Spaghetti：%s 初始化失敗，略過此商品",p.m_sym);
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
   if(!BQ_AccountAllowed()) return(INIT_FAILED);
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
      Print("Spaghetti：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("Spaghetti：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("Spaghetti ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
