//+------------------------------------------------------------------+
//| 02_MarketReview_ML.mq5 — 第二期 EA-市場探測器 修正優化 + 機器學習   |
//|                                                                  |
//| 用途：用 12 種進場 x 3 種出場，快速探測一個商品適合                 |
//|       順勢 / 逆勢 / 箱型 哪一類策略 (請搭配最佳化 EntryType)         |
//|  Entry 1~4  順勢 (Stop 單)   5~8 逆勢 (Limit 單)   9~12 箱型          |
//|                                                                  |
//| 修正 (以原檔內附的 TradeStation 註解為規格)：                      |
//|   * Case1 均線命名顛倒 (EMA20 穿越 EMA5 當成黃金交叉) → 快線上穿慢線  |
//|   * Case6/7/8 多空方向與掛單價位寫反，Limit 單掛在錯的一側被拒單      |
//|   * Case9 用 BuyStop 掛在現價 (無效單) → 改為市價單，方向依規格       |
//|   * StochRSI 分母為 0 時除以零                                       |
//|   * H1 只複製 30 根卻取 72 根最高價 (陣列越界)                        |
//|   * BuyMarket/SellMarket 少大括號，永遠回傳 false                     |
//|   * 移動停損改單時沒帶 TP，TP 被清掉                                  |
//|   * 每個 tick 重算並重複掛單 → 每根新 K 棒才評估一次                  |
//+------------------------------------------------------------------+
//| ★ 掛在任何圖表皆可：依 InpSymbols / InpBaseTF 交易 (預設=原版商品與週期) |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"
#include "BeeQuant/BQ_Multi.mqh"

enum ENUM_MR_ENTRY
  {
   MR_E1_MA_CROSS    = 1,  // 1 順勢：均線黃金/死亡交叉 (Stop)
   MR_E2_MA_ATR      = 2,  // 2 順勢：均線方向 + 開盤價±ATR突破 (Stop)
   MR_E3_MACD_ZERO   = 3,  // 3 順勢：MACD 穿越 0 軸 (Stop)
   MR_E4_STOCHRSI    = 4,  // 4 順勢：StochRSI 穿越 (Stop)
   MR_E5_RSI_MA      = 5,  // 5 逆勢：RSI + 長均線 (Limit)
   MR_E6_WPR_MA      = 6,  // 6 逆勢：威廉 + 長均線 (Limit)
   MR_E7_MACD_MA     = 7,  // 7 逆勢：MACD + 長均線 (Limit)
   MR_E8_STOCHRSI_MA = 8,  // 8 逆勢：StochRSI + 長均線 (Limit)
   MR_E9_ADX_RSI     = 9,  // 9 箱型：ADX + RSI (市價)
   MR_E10_ADX_RANGE  = 10, // 10 箱型：ADX + 三日高低點 (Limit)
   MR_E11_ADX_MACD   = 11, // 11 箱型：ADX + MACD (市價)
   MR_E12_ADX_SRSI   = 12  // 12 箱型：ADX + StochRSI (市價)
  };

enum ENUM_MR_EXIT
  {
   MR_X1_PERCENT = 1,  // 1 固定百分比停損停利
   MR_X2_ATR     = 2,  // 2 ATR 倍數停損停利
   MR_X3_TRAIL   = 3   // 3 ATR 倍數 + 3ATR 移動停損
  };

input group "=== 交易商品 / 週期 (掛在任何圖表皆可) ==="
input string          InpSymbols = ""; // 交易商品 (逗號分隔；原版為掃描器，無指定商品；空白=圖表商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_H1; // 策略週期 (原版圖表週期)

input group "=== 策略選擇 ==="
input ENUM_MR_ENTRY InpEntry = MR_E1_MA_CROSS; // 進場類型
input ENUM_MR_EXIT  InpExit  = MR_X1_PERCENT;  // 出場類型
input double InpPF        = 1;     // 停利 (類型1=%, 類型2/3=ATR倍數)
input double InpPL        = 1;     // 停損 (類型1=%, 類型2/3=ATR倍數)

input group "=== 指標參數 ==="
input int    InpLevel     = 70;    // RSI / StochRSI / 威廉 門檻
input int    InpFastMA    = 5;     // 快均線 (EMA)
input int    InpSlowMA    = 20;    // 慢均線 (EMA)
input int    InpTrendMA   = 144;   // 逆勢濾網長均線 (EMA)
input int    InpRSIPeriod = 9;     // RSI 週期
input int    InpWPRPeriod = 6;     // 威廉週期
input int    InpADXPeriod = 14;    // ADX 週期
input int    InpATRBreak  = 6;     // Case2 ATR 週期
input double InpATRBreakK = 4;     // Case2 ATR 倍數
input int    InpTickOff   = 10;    // 掛單讓點 (點)

input group "=== 資金 / 風控 ==="
input double InpLots      = 0.1;   // 固定手數
input bool   InpAutoLots  = false; // 自動計算手數
input double InpRiskPct   = 1.0;   // 每筆風險 %
input double InpMaxLots   = 1.0;   // 手數上限
input int    InpMaxSpread = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage  = 100;   // 滑價 (點)
input long   InpMagic     = 100;   // MagicNumber (空單 = +77)

#include "BeeQuant/BQ_MLInputs.mqh"

#define K_NONE   0
#define K_MARKET 1
#define K_STOP   2
#define K_LIMIT  3

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

   CBQTrade  m_trade;
   CBQNewBar m_newBar;


   //--- StochRSI(shift) = RSI 在最近 20 根 RSI 高低區間中的位置
   double StochRSI(const int shift)
     {
      double r[];
      if(CopyBuffer(BQ_hRSI(m_sym,m_tf,InpRSIPeriod,PRICE_CLOSE),0,shift,20,r)!=20) return(EMPTY_VALUE);
      double hi=r[ArrayMaximum(r)],lo=r[ArrayMinimum(r)];
      // CopyBuffer 非時間序列：r[19] = shift 那一根
      if(hi-lo<1e-9) return(50.0);
      return(100.0*(r[19]-lo)/(hi-lo));
     }

   double ADXAvg()
     {
      double a[];
      if(CopyBuffer(BQ_hADX(m_sym,m_tf,InpADXPeriod),0,1,20,a)!=20) return(EMPTY_VALUE);
      return((a[ArrayMaximum(a)]+a[ArrayMinimum(a)])/2.0);
     }

   bool CrossUp(const double now,const double prev,const double lvl)   { return(prev<=lvl && now>lvl); }
   bool CrossDown(const double now,const double prev,const double lvl) { return(prev>=lvl && now<lvl); }

   //--- 計算訊號：回傳 多/空 的 掛單種類與價位
   bool Signals(int &bk,double &bp,int &sk,double &sp)
     {
      bk=K_NONE; sk=K_NONE; bp=0; sp=0;
      double off=InpTickOff*_Point;
      double h1=iHigh(m_sym,m_tf,1), l1=iLow(m_sym,m_tf,1), c1=iClose(m_sym,m_tf,1);
      double lv=InpLevel, lvL=100-InpLevel;
      double trendMA=BQ_MA(m_sym,m_tf,InpTrendMA,0,MODE_EMA,PRICE_CLOSE,1);

      switch(InpEntry)
        {
         case MR_E1_MA_CROSS:
           {
            double f1=BQ_MA(m_sym,m_tf,InpFastMA,0,MODE_EMA,PRICE_CLOSE,1), f2=BQ_MA(m_sym,m_tf,InpFastMA,0,MODE_EMA,PRICE_CLOSE,2);
            double s1=BQ_MA(m_sym,m_tf,InpSlowMA,0,MODE_EMA,PRICE_CLOSE,1), s2=BQ_MA(m_sym,m_tf,InpSlowMA,0,MODE_EMA,PRICE_CLOSE,2);
            if(!BQ_Ok(f1)||!BQ_Ok(f2)||!BQ_Ok(s1)||!BQ_Ok(s2)) return(false);
            if(f2<=s2 && f1>s1) { bk=K_STOP; bp=h1+off; }
            if(f2>=s2 && f1<s1) { sk=K_STOP; sp=l1-off; }
            break;
           }
         case MR_E2_MA_ATR:
           {
            double f1=BQ_MA(m_sym,m_tf,InpFastMA,0,MODE_EMA,PRICE_CLOSE,1);
            double s1=BQ_MA(m_sym,m_tf,InpSlowMA,0,MODE_EMA,PRICE_CLOSE,1);
            double atr=BQ_ATR(m_sym,m_tf,InpATRBreak,1);
            if(!BQ_Ok(f1)||!BQ_Ok(s1)||!BQ_Ok(atr)) return(false);
            double ref=(PeriodSeconds(m_tf)<PeriodSeconds(PERIOD_D1) ? iOpen(m_sym,PERIOD_D1,0) : iOpen(m_sym,m_tf,0));
            if(f1>s1) { bk=K_STOP; bp=ref+InpATRBreakK*atr; }
            if(f1<s1) { sk=K_STOP; sp=ref-InpATRBreakK*atr; }
            break;
           }
         case MR_E3_MACD_ZERO:
         case MR_E7_MACD_MA:
         case MR_E11_ADX_MACD:
           {
            double m1=BQ_MACD(m_sym,m_tf,12,26,9,PRICE_CLOSE,0,1), m2=BQ_MACD(m_sym,m_tf,12,26,9,PRICE_CLOSE,0,2);
            if(!BQ_Ok(m1)||!BQ_Ok(m2)) return(false);
            bool up=CrossUp(m1,m2,0), dn=CrossDown(m1,m2,0);
            if(InpEntry==MR_E3_MACD_ZERO)
              {
               if(up) { bk=K_STOP; bp=h1+off; }
               if(dn) { sk=K_STOP; sp=l1-off; }
              }
            else if(InpEntry==MR_E7_MACD_MA)
              {
               if(!BQ_Ok(trendMA)) return(false);
               if(up && c1<trendMA) { sk=K_LIMIT; sp=h1+off; }
               if(dn && c1>trendMA) { bk=K_LIMIT; bp=l1-off; }
              }
            else
              {
               double adx=BQ_ADX(m_sym,m_tf,InpADXPeriod,0,1), avg=ADXAvg();
               if(!BQ_Ok(adx)||!BQ_Ok(avg)) return(false);
               if(adx<avg)
                 {
                  if(up) sk=K_MARKET;
                  if(dn) bk=K_MARKET;
                 }
              }
            break;
           }
         case MR_E4_STOCHRSI:
         case MR_E8_STOCHRSI_MA:
         case MR_E12_ADX_SRSI:
           {
            double k1=StochRSI(1), k2=StochRSI(2);
            if(!BQ_Ok(k1)||!BQ_Ok(k2)) return(false);
            if(InpEntry==MR_E4_STOCHRSI)
              {
               if(CrossUp(k1,k2,lv))    { bk=K_STOP; bp=h1+off; }
               if(CrossDown(k1,k2,lvL)) { sk=K_STOP; sp=l1-off; }
              }
            else if(InpEntry==MR_E8_STOCHRSI_MA)
              {
               if(!BQ_Ok(trendMA)) return(false);
               if(CrossUp(k1,k2,lv) && c1<trendMA)    { sk=K_LIMIT; sp=h1+off; }
               if(CrossDown(k1,k2,lvL) && c1>trendMA) { bk=K_LIMIT; bp=l1-off; }
              }
            else
              {
               double adx=BQ_ADX(m_sym,m_tf,InpADXPeriod,0,1), avg=ADXAvg();
               if(!BQ_Ok(adx)||!BQ_Ok(avg)) return(false);
               if(adx<30 && adx<avg)
                 {
                  if(CrossUp(k1,k2,lv))    sk=K_MARKET;
                  if(CrossDown(k1,k2,lvL)) bk=K_MARKET;
                 }
              }
            break;
           }
         case MR_E5_RSI_MA:
         case MR_E9_ADX_RSI:
           {
            double r1=BQ_RSI(m_sym,m_tf,InpRSIPeriod,PRICE_CLOSE,1), r2=BQ_RSI(m_sym,m_tf,InpRSIPeriod,PRICE_CLOSE,2);
            if(!BQ_Ok(r1)||!BQ_Ok(r2)) return(false);
            if(InpEntry==MR_E5_RSI_MA)
              {
               if(!BQ_Ok(trendMA)) return(false);
               if(CrossUp(r1,r2,lv) && c1<trendMA)    { sk=K_LIMIT; sp=h1+off; }
               if(CrossDown(r1,r2,lvL) && c1>trendMA) { bk=K_LIMIT; bp=l1-off; }
              }
            else
              {
               double adx=BQ_ADX(m_sym,m_tf,InpADXPeriod,0,1), avg=ADXAvg();
               if(!BQ_Ok(adx)||!BQ_Ok(avg)) return(false);
               if(adx<avg)
                 {
                  if(CrossUp(r1,r2,lv))    sk=K_MARKET;
                  if(CrossDown(r1,r2,lvL)) bk=K_MARKET;
                 }
              }
            break;
           }
         case MR_E6_WPR_MA:
           {
            // TradeStation PercentR(0~100) = MT5 WPR(-100~0) + 100
            double w1=BQ_WPR(m_sym,m_tf,InpWPRPeriod,1), w2=BQ_WPR(m_sym,m_tf,InpWPRPeriod,2);
            if(!BQ_Ok(w1)||!BQ_Ok(w2)||!BQ_Ok(trendMA)) return(false);
            w1+=100; w2+=100;
            if(CrossUp(w1,w2,lv) && c1<trendMA)    { sk=K_LIMIT; sp=h1+off; }
            if(CrossDown(w1,w2,lvL) && c1>trendMA) { bk=K_LIMIT; bp=l1-off; }
            break;
           }
         case MR_E10_ADX_RANGE:
           {
            double adx=BQ_ADX(m_sym,m_tf,InpADXPeriod,0,1), avg=ADXAvg();
            if(!BQ_Ok(adx)||!BQ_Ok(avg)) return(false);
            if(adx<30 && adx<avg)
              {
               ENUM_TIMEFRAMES tf=(PeriodSeconds(m_tf)<PeriodSeconds(PERIOD_D1) ? PERIOD_D1 : m_tf);
               double hh=BQ_Highest(m_sym,tf,3,0), ll=BQ_Lowest(m_sym,tf,3,0);
               if(!BQ_Ok(hh)||!BQ_Ok(ll)) return(false);
               sk=K_LIMIT; sp=hh+off;
               bk=K_LIMIT; bp=ll-off;
              }
            break;
           }
        }
      return(true);
     }

   void CalcStops(const int dir,const double entry,double &sl,double &tp)
     {
      if(InpExit==MR_X1_PERCENT)
        {
         tp=entry*(1.0+dir*InpPF/100.0);
         sl=entry*(1.0-dir*InpPL/100.0);
        }
      else
        {
         double atr=BQ_ATR(m_sym,m_tf,14,1);
         if(!BQ_Ok(atr)) { sl=0; tp=0; return; }
         tp=entry+dir*InpPF*atr;
         sl=entry-dir*InpPL*atr;
        }
     }

   void Place(const int dir,const int kind,double price)
     {
      if(kind==K_MARKET) price=(dir>0 ? m_trade.Ask() : m_trade.Bid());
      double sl,tp;
      CalcStops(dir,price,sl,tp);
      if(sl<=0) return;
      double slD=MathAbs(price-sl), tpD=MathAbs(tp-price);
      if(!m_ml.Allow(dir,slD,tpD)) return;
      double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
      string cmt=StringFormat("MR E%d X%d",(int)InpEntry,(int)InpExit);
      if(kind==K_MARKET)
        {
         if(dir>0) m_trade.Buy(lots,sl,tp,cmt); else m_trade.Sell(lots,sl,tp,cmt);
        }
      else
        {
         ENUM_ORDER_TYPE t;
         if(kind==K_STOP) t=(dir>0 ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
         else             t=(dir>0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
         m_trade.Pending(t,price,lots,sl,tp,cmt);
        }
     }

   void Trail()
     {
      double atr=BQ_ATR(m_sym,m_tf,14,1);
      if(!BQ_Ok(atr)) return;
      if(m_trade.CountBuy()>0)
        {
         double hi=BQ_HighSince(m_sym,m_tf,m_trade.OpenTime(POSITION_TYPE_BUY));
         if(BQ_Ok(hi)) m_trade.ModifySL(POSITION_TYPE_BUY,hi-3*atr);
        }
      if(m_trade.CountSell()>0)
        {
         double lo=BQ_LowSince(m_sym,m_tf,m_trade.OpenTime(POSITION_TYPE_SELL));
         if(BQ_Ok(lo)) m_trade.ModifySL(POSITION_TYPE_SELL,lo+3*atr);
        }
     }

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      BQML_Setup(m_ml,StringFormat("MarketReview_E%d_X%d",(int)InpEntry,(int)InpExit),m_sym,m_tf,InpMagic);
      return(INIT_SUCCEEDED);
     }

   void Shutdown()
     {
      m_ml.Deinit();
     }


   void Tick()
     {
      m_ml.OnTick();
      if(InpExit==MR_X3_TRAIL) Trail();

      //--- 避免鎖單：多空同時存在時平掉較早的那一張
      if(m_trade.CountBuy()>0 && m_trade.CountSell()>0)
        {
         if(m_trade.OpenTime(POSITION_TYPE_BUY)<m_trade.OpenTime(POSITION_TYPE_SELL)) m_trade.CloseBuy();
         else m_trade.CloseSell();
        }

      if(!m_newBar.Check(m_sym,m_tf)) return;

      //--- 新 K 棒：上一根沒成交的掛單作廢 (TradeStation "next bar" 語意)
      m_trade.DeletePending(true);
      m_trade.DeletePending(false);
      if(!m_trade.SpreadOK(InpMaxSpread)) return;

      int bk,sk; double bp,sp;
      if(!Signals(bk,bp,sk,sp)) return;
      if(bk!=K_NONE && m_trade.CountBuy()==0)  Place(1,bk,bp);
      if(sk!=K_NONE && m_trade.CountSell()==0) Place(-1,sk,sp);

      SetPanel(StringFormat("MarketReview ML  Entry %d / Exit %d\n%s",(int)InpEntry,(int)InpExit,m_ml.Status()));
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
      PrintFormat("MarketReview：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("MarketReview：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("MarketReview：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("MarketReview ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
