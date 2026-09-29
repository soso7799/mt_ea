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

                     CStrat() { m_halfBuy=false; m_halfSell=false; }
   void              SetPanel(const string s) { m_panel=s; }

   CBQTrade        m_trade;
   CBQBarGuard     m_guard;
   CBQDailyCounter m_dayBuy,m_daySell;
   bool m_halfBuy,m_halfSell;

   double EMA(const int shift) { return(BQ_MA(m_sym,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE,shift)); }

   // 最近 6 根內 收盤穿越 EMA；dir=1 向上，-1 向下
   bool RecentCross(const int dir)
     {
      for(int i=1;i<=5;i++)
        {
         double ca=iClose(m_sym,InpTF,i), cb=iClose(m_sym,InpTF,i+1);
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
      if(m_trade.Count(type)==0) { if(isBuy) m_halfBuy=false; else m_halfSell=false; return; }
      double open=m_trade.OpenPrice(type), sl=m_trade.PosSL(type);
      double risk=(isBuy ? open-sl : sl-open);
      if(sl<=0 || risk<=0) return;
      double px=(isBuy ? m_trade.Bid() : m_trade.Ask());
      if(isBuy ? px>=open+risk : px<=open-risk)
        {
         bool done=(isBuy ? m_halfBuy : m_halfSell);
         if(!done)
           {
            m_trade.ClosePartial(type,0.5);
            if(isBuy) m_halfBuy=true; else m_halfSell=true;
           }
         m_trade.ModifySL(type,open);
        }
     }

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      m_dayBuy.Init(0);
      m_daySell.Init(0);
      BQ_hMA(m_sym,InpTF,InpMAPeriod,0,MODE_EMA,PRICE_CLOSE);
      BQ_hMACD(m_sym,InpTF,12,26,9,PRICE_CLOSE);
      BQML_Setup(m_ml,"FiveMinMomentum",m_sym,m_tf,InpMagic);
      return(INIT_SUCCEEDED);
     }

   void Shutdown()
     {
      m_ml.Deinit();
     }


   void Tick()
     {
      m_ml.OnTick();
      double ma=EMA(1);
      if(!BQ_Ok(ma)) return;
      double bid=m_trade.Bid(), ask=m_trade.Ask();
      double stop=InpStopPts*_Point;

      //=== 出場 / 平半保本 ===
      if(m_trade.CountBuy()>0  && bid<=ma-stop) m_trade.CloseBuy();
      if(m_trade.CountSell()>0 && bid>=ma+stop) m_trade.CloseSell();
      ManageHalf(POSITION_TYPE_BUY);
      ManageHalf(POSITION_TYPE_SELL);

      //=== 進場 (多空同時只能有一邊) ===
      if(m_trade.CountAll()>0 || m_guard.Done(m_sym,InpTF) || !m_trade.SpreadOK(InpMaxSpread)) return;
      int h=BQ_Hour();
      if(h<InpStartHour || h>InpEndHour) return;
      double m1=BQ_MACD(m_sym,InpTF,12,26,9,PRICE_CLOSE,0,1), m2=BQ_MACD(m_sym,InpTF,12,26,9,PRICE_CLOSE,0,2);
      if(!BQ_Ok(m1) || !BQ_Ok(m2)) return;

      double lots=InpLots;
      if(m_dayBuy.Count()<InpMaxTradesSide && m1>=0 && m2<0 && bid>=ma+InpBreakPts*_Point && RecentCross(1))
        {
         double sl=ma-stop, slD=ask-sl;
         if(slD>0 && m_ml.Allow(1,slD,slD))
           {
            lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
            lots=MathMax(lots,2*m_trade.MinLot());
            if(m_trade.Buy(lots,sl,0,"5m B")) { m_dayBuy.Inc(); m_guard.Mark(m_sym,InpTF); m_halfBuy=false; }
           }
        }
      else if(m_daySell.Count()<InpMaxTradesSide && m1<=0 && m2>0 && bid<=ma-InpBreakPts*_Point && RecentCross(-1))
        {
         double sl=ma+stop, slD=sl-bid;
         if(slD>0 && m_ml.Allow(-1,slD,slD))
           {
            lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
            lots=MathMax(lots,2*m_trade.MinLot());
            if(m_trade.Sell(lots,sl,0,"5m S")) { m_daySell.Inc(); m_guard.Mark(m_sym,InpTF); m_halfSell=false; }
           }
        }
      SetPanel(StringFormat("5分鐘動量 ML\nEMA %.5f  MACD %.5f\n今日 多 %d / 空 %d\n%s",ma,m1,m_dayBuy.Count(),m_daySell.Count(),m_ml.Status()));
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
      PrintFormat("FiveMin：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("FiveMin：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("FiveMin：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("FiveMin ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
