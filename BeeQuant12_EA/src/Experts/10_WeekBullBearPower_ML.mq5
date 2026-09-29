//+------------------------------------------------------------------+
//| 10_WeekBullBearPower_ML.mq5 — 第十期 WeekBullBear 周天成 修正 + ML |
//|   原開發：GBPJPY D1 (作者 Mar/TINA，調整 CASH)                        |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   牛力 = 收盤 - 最低，熊力 = 最高 - 收盤                             |
//|   上週牛力 > 熊力 (趨勢偏多) 且 昨日牛力 > 熊力 → 每日開盤做多       |
//|   空單對稱；停損 ATR(D1,3) x 2，停利 ATR x 6；當日 23:50 平倉         |
//|                                                                  |
//| 修正：                                                            |
//|   * 進場寫死 00:00~00:05 → 改以「日K開盤後 N 分鐘內」判斷，           |
//|     日K不是從 0 點開始的券商也能正確運作                              |
//|   * 每日次數在 23:55 後才歸零、只靠有無報價 → 交易日計數器           |
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
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_D1; // 策略週期 (原版圖表週期)

input group "=== 策略參數 ==="
input ENUM_TIMEFRAMES InpSmallTF = PERIOD_D1; // 小時間週期 (日)
input ENUM_TIMEFRAMES InpBigTF   = PERIOD_W1; // 大時間週期 (週)
input int    InpATRPeriod  = 3;     // ATR 週期
input double InpSLMult     = 2;     // 停損 ATR 倍數
input double InpTPMult     = 6;     // 停利 ATR 倍數
input int    InpEntryMinutes = 5;   // 開盤後幾分鐘內可進場
input int    InpExitHour   = 23;    // 當日平倉時
input int    InpExitMinute = 50;    // 當日平倉分
input int    InpMaxTradesDay = 1;   // 每日僅下單次數

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.01;  // 固定手數
input double InpMaxLots    = 0.5;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 1234;  // MagicNumber (空單 = +77)

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

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      m_daily.Init(0);
      BQ_hATR(m_sym,InpSmallTF,InpATRPeriod);
      BQML_Setup(m_ml,"WeekBullBear",m_sym,m_tf,InpMagic);
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

      int h=BQ_Hour(), m=BQ_Minute();

      //=== 當日收盤前平倉 ===
      if(h==InpExitHour && m>=InpExitMinute)
        {
         if(m_trade.CountBuy()>0)  m_trade.CloseBuy();
         if(m_trade.CountSell()>0) m_trade.CloseSell();
         return;
        }

      //=== 進場：日K開盤後 N 分鐘內，週一~週五 ===
      datetime dayOpen=iTime(m_sym,InpSmallTF,0);
      if(dayOpen==0 || TimeCurrent()-dayOpen>InpEntryMinutes*60) return;
      int dow=BQ_DayOfWeek();
      if(dow<1 || dow>5) return;
      if(m_guard.Done(m_sym,InpSmallTF) || m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread)) return;
      if(m_trade.CountAll()>0) return;

      double atr=BQ_ATR(m_sym,InpSmallTF,InpATRPeriod,1);
      double dO=iOpen(m_sym,InpSmallTF,1), dC=iClose(m_sym,InpSmallTF,1), dH=iHigh(m_sym,InpSmallTF,1), dL=iLow(m_sym,InpSmallTF,1);
      double wC=iClose(m_sym,InpBigTF,1), wH=iHigh(m_sym,InpBigTF,1), wL=iLow(m_sym,InpBigTF,1);
      if(!BQ_Ok(atr) || dO<=0 || wC<=0) return;

      double weekBull=MathAbs(wC-wL), weekBear=MathAbs(wH-wC);   // 先看趨勢
      double dayBull =MathAbs(dC-dL), dayBear =MathAbs(dH-dC);   // 再看多空
      double slD=atr*InpSLMult, tpD=atr*InpTPMult;
      double ask=m_trade.Ask(), bid=m_trade.Bid();

      if(weekBull>weekBear && dayBull>dayBear && m_ml.Allow(1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Buy(lots,ask-slD,ask+tpD,"Week Bull-Buy")) { m_daily.Inc(); m_guard.Mark(m_sym,InpSmallTF); }
        }
      else if(weekBull<weekBear && dayBull<dayBear && m_ml.Allow(-1,slD,tpD))
        {
         double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,slD,InpLots,InpMaxLots)*m_ml.LotFactor();
         if(m_trade.Sell(lots,bid+slD,bid-tpD,"Week Bear-Sell")) { m_daily.Inc(); m_guard.Mark(m_sym,InpSmallTF); }
        }
      SetPanel(StringFormat("WeekBullBear ML\n週牛力 %.5f 週熊力 %.5f\n日牛力 %.5f 日熊力 %.5f\n%s",
                            weekBull,weekBear,dayBull,dayBear,m_ml.Status()));
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
      PrintFormat("WeekBullBear：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("WeekBullBear：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("WeekBullBear：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("WeekBullBear ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
