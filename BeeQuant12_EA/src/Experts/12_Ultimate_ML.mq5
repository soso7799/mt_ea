//+------------------------------------------------------------------+
//| 12_Ultimate_ML.mq5 — 第十二期 EA-Ultimate 修正優化 + 機器學習       |
//|   可用商品：GBPCAD、GBPNZD、GBPJPY   週期：M15                        |
//|                                                                  |
//| 策略邏輯 (與原版相同)：價格破底做多 / 過頂做空 (假突破反轉)          |
//|   多：上一根開盤 > 前 N 根最低點，這一根開盤 < 最近 N 根最低點        |
//|   空：上一根開盤 < 前 N 根最高點，這一根開盤 > 最近 N 根最高點        |
//|   停損 = ATR(10) x 停損倍數；出場：開盤價穿越均線                    |
//|                                                                  |
//| 修正：                                                            |
//|   * cash_v2.mqh 的 iATR / iMA 每 tick 建 handle → 快取               |
//|   * 平倉/判斷都在每個 tick 重算，同一根K棒可反覆下單 → 每根K棒一次     |
//|   * 風險手數固定用 10000 本金 → 可選帳戶餘額 (InpRiskBase=0)          |
//|   * 手數沒有上限、沒對齊步進 → 修正                                 |
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
input string          InpSymbols = "GBPCAD,GBPNZD,GBPJPY"; // 交易商品 (逗號分隔；原版開發商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_M15; // 策略週期 (原版圖表週期)

input group "=== 策略參數 ==="
input int    InpRange      = 16;    // 高低點根數
input double InpSLATR      = 4.5;   // 停損 ATR 倍數
input double InpTPATR      = 0;     // 停利 ATR 倍數 (0=不設，原版)
input int    InpMALen      = 14;    // 出場均線 (SMA)
input int    InpATRPeriod  = 10;    // ATR 週期

input group "=== 資金 / 風控 ==="
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpRiskBase   = 10000; // 計算本金 (0=帳戶餘額，原版固定 10000)
input double InpLots       = 0.01;  // 固定手數
input double InpMaxLots    = 1.0;   // 手數上限
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
   CBQBarGuard m_guardOpen,m_guardBuyClose,m_guardSellClose;

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      BQ_hATR(m_sym,m_tf,InpATRPeriod);
      BQ_hMA(m_sym,m_tf,InpMALen,0,MODE_SMA,PRICE_CLOSE);
      BQML_Setup(m_ml,"Ultimate",m_sym,m_tf,InpMagic);
      return(INIT_SUCCEEDED);
     }

   void Shutdown()
     {
      m_ml.Deinit();
     }


   void Tick()
     {
      m_ml.OnTick();
      double atr=BQ_ATR(m_sym,m_tf,InpATRPeriod,1);
      double l1=BQ_Lowest(m_sym,m_tf,InpRange,1),  h1=BQ_Highest(m_sym,m_tf,InpRange,1);
      double l2=BQ_Lowest(m_sym,m_tf,InpRange,2),  h2=BQ_Highest(m_sym,m_tf,InpRange,2);
      double ma1=BQ_MA(m_sym,m_tf,InpMALen,0,MODE_SMA,PRICE_CLOSE,1);
      double ma2=BQ_MA(m_sym,m_tf,InpMALen,0,MODE_SMA,PRICE_CLOSE,2);
      double o0=iOpen(m_sym,m_tf,0), o1=iOpen(m_sym,m_tf,1);
      if(!BQ_Ok(atr)||!BQ_Ok(l1)||!BQ_Ok(h1)||!BQ_Ok(l2)||!BQ_Ok(h2)||!BQ_Ok(ma1)||!BQ_Ok(ma2)||o0<=0||o1<=0) return;

      //=== 出場：開盤價穿越均線 ===
      if(m_trade.CountBuy()>0 && !m_guardBuyClose.Done(m_sym,m_tf) && o1<ma2 && o0>ma1)
        { m_trade.CloseBuy(); m_guardBuyClose.Mark(m_sym,m_tf); }
      if(m_trade.CountSell()>0 && !m_guardSellClose.Done(m_sym,m_tf) && o1>ma2 && o0<ma1)
        { m_trade.CloseSell(); m_guardSellClose.Mark(m_sym,m_tf); }

      //=== 進場 ===
      if(m_guardOpen.Done(m_sym,m_tf) || !m_trade.SpreadOK(InpMaxSpread)) return;
      double ask=m_trade.Ask(), bid=m_trade.Bid();
      double slD=InpSLATR*atr, tpD=InpTPATR*atr;

      if(o1>l2 && o0<l1 && m_trade.CountBuy()==0 && m_trade.PendingCount(true)==0 && m_ml.Allow(1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots,InpRiskBase)*m_ml.LotFactor();
         if(m_trade.Buy(lots,ask-slD,(tpD>0 ? ask+tpD : 0),"Ultimate Long")) m_guardOpen.Mark(m_sym,m_tf);
        }
      if(o1<h2 && o0>h1 && m_trade.CountSell()==0 && m_trade.PendingCount(false)==0 && m_ml.Allow(-1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots,InpRiskBase)*m_ml.LotFactor();
         if(m_trade.Sell(lots,bid+slD,(tpD>0 ? bid-tpD : 0),"Ultimate Short")) m_guardOpen.Mark(m_sym,m_tf);
        }
      SetPanel(StringFormat("Ultimate ML\n區間高 %.5f 低 %.5f\n%s",h1,l1,m_ml.Status()));
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
      PrintFormat("Ultimate：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("Ultimate：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("Ultimate：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("Ultimate ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
