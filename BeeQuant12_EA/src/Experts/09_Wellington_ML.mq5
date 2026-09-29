//+------------------------------------------------------------------+
//| 09_Wellington_ML.mq5 — 第九期 Wellington 威靈頓 修正優化 + ML       |
//|   原開發：GBPJPY H1；可穿透 AUDNZD USDJPY NZDJPY GBPNZD AUDJPY NZDUSD |
//|                                                                  |
//| 策略邏輯 (與原版相同)：三均線回檔 + 突破掛單                         |
//|   EMA(N) < EMA(Nxratio) 且 EMA(N) > EMA(Nxratio²) (長多中的回檔)     |
//|   → 在最近 K 根高點掛 BuyStop (右邊交易)；空單對稱                   |
//|   停損/停利 = ATR x 倍數；新K棒時刪除未成交掛單重新評估              |
//|                                                                  |
//| 修正：                                                            |
//|   * 刪除掛單迴圈正向刪除會跳單 → 反向迴圈                            |
//|   * 掛單價位太靠近現價被拒單沒處理 → 送單前檢查 STOPS_LEVEL           |
//|   * 同一根K棒先嘗試下單後才刪舊單，新單要等下一個 tick → 先刪再下     |
//|   * cash.mqh iATR 每 tick 建 handle → 快取                          |
//|   * 手數對齊交易量步進；送單檢查 retcode                             |
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

input group "=== 策略參數 ==="
input ENUM_TIMEFRAMES InpTF   = PERIOD_H2;      // 均線/ATR 時間週期
input ENUM_TIMEFRAMES InpHLTF = PERIOD_CURRENT; // 高低點取值週期 (原版=圖表週期)
input int    InpMAPeriod   = 110;   // 短均線週期 (EMA)
input int    InpRatio      = 3;     // 中均=短均x倍數，長均=中均x倍數
input int    InpHLBars     = 25;    // 高低點根數
input double InpSLMult     = 2;     // 停損 ATR 倍數
input double InpTPMult     = 2;     // 停利 ATR 倍數

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

                     CStrat() {}
   void              SetPanel(const string s) { m_panel=s; }

   CBQTrade    m_trade;
   CBQBarGuard m_guard;
   CBQNewBar   m_newBar;

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      BQ_hMA(m_sym,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE);
      BQ_hMA(m_sym,InpTF,InpMAPeriod*InpRatio,0,MODE_EMA,PRICE_CLOSE);
      BQ_hMA(m_sym,InpTF,InpMAPeriod*InpRatio*InpRatio,0,MODE_EMA,PRICE_CLOSE);
      BQ_hATR(m_sym,InpTF,InpMAPeriod);
      BQML_Setup(m_ml,"Wellington",m_sym,m_tf,InpMagic);
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

      //--- 均線週期新K棒：刪除上一根沒成交的掛單
      if(m_newBar.Check(m_sym,InpTF))
        {
         m_trade.DeletePending(true);
         m_trade.DeletePending(false);
        }
      if(m_guard.Done(m_sym,InpTF) || !m_trade.SpreadOK(InpMaxSpread)) return;

      double ma1=BQ_MA(m_sym,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE,1);
      double ma2=BQ_MA(m_sym,InpTF,InpMAPeriod*InpRatio,0,MODE_EMA,PRICE_CLOSE,1);
      double ma3=BQ_MA(m_sym,InpTF,InpMAPeriod*InpRatio*InpRatio,0,MODE_EMA,PRICE_CLOSE,1);
      double atr=BQ_ATR(m_sym,InpTF,InpMAPeriod,1);
      ENUM_TIMEFRAMES hlTF=(InpHLTF==PERIOD_CURRENT ? m_tf : InpHLTF);
      double hh=BQ_Highest(m_sym,hlTF,InpHLBars,1);
      double ll=BQ_Lowest(m_sym,hlTF,InpHLBars,1);
      if(!BQ_Ok(ma1)||!BQ_Ok(ma2)||!BQ_Ok(ma3)||!BQ_Ok(atr)||!BQ_Ok(hh)||!BQ_Ok(ll)) return;

      double ask=m_trade.Ask(), bid=m_trade.Bid();
      double slD=InpSLMult*atr, tpD=InpTPMult*atr;
      bool placed=false;

      if(ask<hh && ma1<ma2 && ma1>ma3 &&
         m_trade.CountBuy()==0 && m_trade.PendingCount(true)==0 && m_ml.Allow(1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Pending(ORDER_TYPE_BUY_STOP,hh,lots,hh-slD,hh+tpD,"3MA_PB Long")) placed=true;
        }
      if(bid>ll && ma1>ma2 && ma1<ma3 &&
         m_trade.CountSell()==0 && m_trade.PendingCount(false)==0 && m_ml.Allow(-1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Pending(ORDER_TYPE_SELL_STOP,ll,lots,ll+slD,ll-tpD,"3MA_PB Short")) placed=true;
        }
      if(placed) m_guard.Mark(m_sym,InpTF);

      SetPanel(StringFormat("Wellington ML\nEMA %d/%d/%d\nHH %.5f LL %.5f\n%s",InpMAPeriod,InpMAPeriod*InpRatio,
                            InpMAPeriod*InpRatio*InpRatio,hh,ll,m_ml.Status()));
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
      PrintFormat("Wellington：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("Wellington：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("Wellington：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("Wellington ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
