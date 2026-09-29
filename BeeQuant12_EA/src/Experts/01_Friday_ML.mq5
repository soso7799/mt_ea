//+------------------------------------------------------------------+
//| 01_Friday_ML.mq5 — 第一期 EA-Friday (週末反轉) 修正優化 + 機器學習  |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   週一：上週五(+週六)收黑 → 做多；收紅 → 做空                        |
//|   停損：週五~週六低點(高點) 再加減 ATR(D1) x 倍數                    |
//|   出場：日K收紅且收盤高於進場價 (非週一) 或 週五 00:05 之後          |
//|                                                                  |
//| 修正：                                                            |
//|   * 每個 tick 複製 100000 根 K 棒 (完全沒用到) → 移除，速度大幅提升  |
//|   * 每個 tick 重建 10 個文字物件 → 改用 Comment 面板                |
//|   * ATR handle 每 tick 建立/釋放 → 快取                             |
//|   * 非商品表中的商品直接不交易 → 可改用自訂參數                      |
//|   * 手數以「實際停損距離」計算，並對齊交易量步進                      |
//|   * 下單檢查 retcode、點差過濾、每日次數以交易日歸零                 |
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
input string          InpSymbols = "EURGBP,EURCHF,AUDUSD,EURUSD"; // 交易商品 (逗號分隔；原版最終測試商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_D1; // 策略週期 (原版圖表週期)

input group "=== 資金 / 風控 ==="
input double InpMinBalance    = 3000;   // 餘額低於此值停止交易
input bool   InpAutoLots      = false;  // 自動計算手數
input double InpRiskPct       = 1.0;    // 每筆風險 %
input double InpLots          = 0.3;    // 固定手數
input double InpMaxLots       = 0.3;    // 手數上限
input int    InpMaxSpread     = 0;      // 最大點差 (點, 0=不限)
input int    InpSlippage      = 100;    // 滑價 (點)
input long   InpMagic         = 1234;   // MagicNumber (空單 = +77)

input group "=== 策略參數 ==="
input bool   InpUseSymbolTable = true;  // 使用原版最終測試商品參數表
input int    InpATRPeriod      = 20;    // ATR 週期 (商品不在表中時)
input double InpSLATRMult      = 1.3;   // 停損 ATR 倍數 (商品不在表中時)
input int    InpMaxTradesDay   = 5;     // 每日下單次數上限
input int    InpDayResetHour   = 6;     // 每日次數歸零時間 (伺服器時)

#include "BeeQuant/BQ_MLInputs.mqh"

struct SWeekend { double open,close,high,low; bool ok; };

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
   int             m_atrPeriod;
   double          m_slMult;

   //--- 原版「套用最終測試參數」
   bool SymbolParams(int &atrPeriod,double &slMult)
     {
      string s=m_sym;
      if(StringFind(s,"EURGBP")==0) { atrPeriod=7;  slMult=1.5; return(true); }
      if(StringFind(s,"EURCHF")==0) { atrPeriod=10; slMult=2.0; return(true); }
      if(StringFind(s,"AUDUSD")==0) { atrPeriod=7;  slMult=1.0; return(true); }
      if(StringFind(s,"EURUSD")==0) { atrPeriod=20; slMult=1.3; return(true); }
      return(false);
     }

   //--- 找上週五(+週六)的 開/收/高/低

   SWeekend FindWeekend()
     {
      SWeekend w; w.ok=false; w.open=0; w.close=0; w.high=0; w.low=0;
      MqlRates k[];
      ArraySetAsSeries(k,true);
      int n=CopyRates(m_sym,PERIOD_D1,0,6,k);
      if(n<=0) return(w);
      MqlDateTime now; TimeToStruct(TimeCurrent(),now);
      datetime today=StringToTime(StringFormat("%04d.%02d.%02d",now.year,now.mon,now.day));
      datetime fri=today-3*86400, sat=today-2*86400;
      // 由舊到新：週五先設開盤，週六(若有)覆蓋收盤
      for(int i=n-1;i>=0;i--)
        {
         if(k[i].time==fri || k[i].time==sat)
           {
            if(!w.ok) { w.high=k[i].high; w.low=k[i].low; w.ok=true; }
            w.high=MathMax(w.high,k[i].high);
            w.low =MathMin(w.low,k[i].low);
            if(k[i].time==fri) w.open=k[i].open;
            w.close=k[i].close;
           }
        }
      if(w.open==0) w.ok=false;
      return(w);
     }

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      m_daily.Init(InpDayResetHour);
      m_atrPeriod=InpATRPeriod;
      m_slMult=InpSLATRMult;
      if(InpUseSymbolTable && !SymbolParams(m_atrPeriod,m_slMult))
         PrintFormat("%s 不在原版參數表，改用自訂參數 ATR=%d 倍數=%.2f",m_sym,m_atrPeriod,m_slMult);
      BQ_hATR(m_sym,PERIOD_D1,m_atrPeriod);
      BQML_Setup(m_ml,"Friday",m_sym,m_tf,InpMagic);
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

      double atr=BQ_ATR(m_sym,PERIOD_D1,m_atrPeriod,1);
      if(!BQ_Ok(atr)) return;
      double slPad=atr*m_slMult;
      int dow=BQ_DayOfWeek();
      double ask=m_trade.Ask(),bid=m_trade.Bid();

      //=== 出場 ===
      double cD1=iClose(m_sym,PERIOD_D1,1), oD1=iOpen(m_sym,PERIOD_D1,1);
      bool friClose=(dow==5 && BQ_Hour()==0 && BQ_Minute()>=5);
      if(m_trade.CountBuy()>0)
        {
         if((cD1>oD1 && cD1>m_trade.OpenPrice(POSITION_TYPE_BUY) && dow!=1) || friClose)
            m_trade.CloseBuy();
        }
      if(m_trade.CountSell()>0)
        {
         if((cD1<oD1 && cD1<m_trade.OpenPrice(POSITION_TYPE_SELL) && dow!=1) || friClose)
            m_trade.CloseSell();
        }

      //=== 進場：只在週一 ===
      if(dow!=1 || m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread))
        {
         SetPanel(StringFormat("Friday ML\n點差 %d\n今日下單 %d\n%s",m_trade.SpreadPoints(),m_daily.Count(),m_ml.Status()));
         return;
        }
      SWeekend w=FindWeekend();
      if(!w.ok) return;

      if(m_trade.CountBuy()==0 && !m_guardBuy.Done(m_sym,PERIOD_D1) && w.close<w.open)
        {
         double sl=w.low-slPad;
         double dist=ask-sl;
         if(dist>0 && m_ml.Allow(1,dist,0))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Buy(lots,sl,0,"Friday Buy"))
              {
               m_daily.Inc();
               m_guardBuy.Mark(m_sym,PERIOD_D1);
              }
           }
        }
      if(m_trade.CountSell()==0 && !m_guardSell.Done(m_sym,PERIOD_D1) && w.close>w.open)
        {
         double sl=w.high+slPad;
         double dist=sl-bid;
         if(dist>0 && m_ml.Allow(-1,dist,0))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Sell(lots,sl,0,"Friday Sell"))
              {
               m_daily.Inc();
               m_guardSell.Mark(m_sym,PERIOD_D1);
              }
           }
        }
      SetPanel(StringFormat("Friday ML\nATR(D1,%d)=%.5f\n點差 %d\n今日下單 %d\n%s",m_atrPeriod,atr,
                            m_trade.SpreadPoints(),m_daily.Count(),m_ml.Status()));
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
      PrintFormat("Friday：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("Friday：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("Friday：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("Friday ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
