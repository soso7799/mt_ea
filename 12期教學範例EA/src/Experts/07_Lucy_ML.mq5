//+------------------------------------------------------------------+
//| 07_Lucy_ML.mq5 — 第七期 週末EA-Lucy 修正優化 + 機器學習             |
//|   原開發：EURJPY H1                                                 |
//|                                                                  |
//| 策略邏輯 (與原版相同)：波動收斂時，在區間低點附近做多/高點附近做空   |
//|   多：收盤距 N 根最低點 <= 距離，且 ATR20 < 22 根前 ATR20 x 小於倍數 |
//|   停損 = ATR40 x 停損倍數，停利 = 停損 x 獲利倍數                    |
//|   獲利中啟動 ATR 追蹤停損；出現反向訊號時平倉                        |
//|                                                                  |
//| 修正：                                                            |
//|   * 每個 tick 建立 2 個 iATR handle 從不釋放 → 快取                  |
//|   * 空單追蹤停損用 CopyHigh 取「最低點」(複製錯陣列) → 修正           |
//|   * 追蹤用「上一根 M1 高點若高於前一根」並非進場後最高點 → 修正       |
//|   * MagicNumber 不是參數 → 改為可調                                  |
//|   * 手數對齊交易量步進；送單檢查 retcode；改單保留 TP                |
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
input string          InpSymbols = "EURJPY"; // 交易商品 (逗號分隔；原版開發商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_H1; // 策略週期 (原版圖表週期)

input group "=== 策略參數 ==="
input double InpSLMult     = 7;     // 停損倍數 (x ATR40)
input double InpTPMult     = 3;     // 獲利倍數 (x 停損)
input int    InpLookback   = 50;    // 高低點回看根數
input int    InpDistance   = 150;   // 距高低點距離 (點)
input double InpShrink     = 0.7;   // 波動收斂倍數 (ATR20 < 前期 x 此值)
input bool   InpTrailing   = true;  // 獲利中啟用追蹤停損
input int    InpMaxTradesDay = 5;   // 每日下單次數上限
input int    InpDayReset   = 0;     // 每日次數歸零時間
input ENUM_TIMEFRAMES InpATRTF = PERIOD_H1; // ATR 週期 / 每根K棒最多一單

input group "=== 資金 / 風控 ==="
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 固定手數
input double InpMaxLots    = 0.1;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 278;   // MagicNumber (空單 = +77)

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

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      m_daily.Init(InpDayReset);
      BQ_hATR(m_sym,InpATRTF,40);
      BQ_hATR(m_sym,InpATRTF,20);
      BQML_Setup(m_ml,"Lucy",m_sym,m_tf,InpMagic);
      return(INIT_SUCCEEDED);
     }

   void Shutdown()
     {
      m_ml.Deinit();
     }


   void Tick()
     {
      m_ml.OnTick();
      double atr =BQ_ATR(m_sym,InpATRTF,40,1);
      double atr0=BQ_ATR(m_sym,InpATRTF,20,1);
      double atr1=BQ_ATR(m_sym,InpATRTF,20,22);
      double hi  =BQ_Highest(m_sym,m_tf,InpLookback,1);
      double lo  =BQ_Lowest(m_sym,m_tf,InpLookback,1);
      double c1  =iClose(m_sym,m_tf,1);
      if(!BQ_Ok(atr)||!BQ_Ok(atr0)||!BQ_Ok(atr1)||!BQ_Ok(hi)||!BQ_Ok(lo)||c1<=0) return;

      bool quiet=(atr0<atr1*InpShrink);
      bool buyCond =(MathAbs(c1-lo)<=InpDistance*_Point && quiet && c1>lo);
      bool sellCond=(MathAbs(c1-hi)<=InpDistance*_Point && quiet && c1<hi);
      double slD=atr*InpSLMult, tpD=slD*InpTPMult;
      double ask=m_trade.Ask(), bid=m_trade.Bid();

      //=== 追蹤停損 (價格在進場價之上才啟動) ===
      if(InpTrailing)
        {
         if(m_trade.CountBuy()>0 && bid>m_trade.OpenPrice(POSITION_TYPE_BUY))
           {
            double h=BQ_HighSince(m_sym,PERIOD_M1,m_trade.OpenTime(POSITION_TYPE_BUY));
            if(BQ_Ok(h)) m_trade.ModifySL(POSITION_TYPE_BUY,h-slD);
           }
         if(m_trade.CountSell()>0 && ask<m_trade.OpenPrice(POSITION_TYPE_SELL))
           {
            double l=BQ_LowSince(m_sym,PERIOD_M1,m_trade.OpenTime(POSITION_TYPE_SELL));
            if(BQ_Ok(l)) m_trade.ModifySL(POSITION_TYPE_SELL,l+slD);
           }
        }

      //=== 反向訊號平倉 ===
      if(m_trade.CountBuy()>0  && sellCond) m_trade.CloseBuy();
      if(m_trade.CountSell()>0 && buyCond)  m_trade.CloseSell();

      //=== 進場 ===
      if(m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread)) return;
      if(buyCond && !sellCond && m_trade.CountBuy()==0 && !m_guardBuy.Done(m_sym,InpATRTF) && m_ml.Allow(1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Buy(lots,ask-slD,ask+tpD,"Lucy_BUY")) { m_daily.Inc(); m_guardBuy.Mark(m_sym,InpATRTF); }
        }
      if(sellCond && !buyCond && m_trade.CountSell()==0 && !m_guardSell.Done(m_sym,InpATRTF) && m_ml.Allow(-1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Sell(lots,bid+slD,bid-tpD,"Lucy_SELL")) { m_daily.Inc(); m_guardSell.Mark(m_sym,InpATRTF); }
        }
      SetPanel(StringFormat("Lucy ML\nATR40 %.5f  收斂 %s\n今日下單 %d\n%s",atr,(quiet?"是":"否"),m_daily.Count(),m_ml.Status()));
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
      PrintFormat("Lucy：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("Lucy：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("Lucy：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("Lucy ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
