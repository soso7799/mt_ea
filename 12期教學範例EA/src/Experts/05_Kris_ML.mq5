//+------------------------------------------------------------------+
//| 05_Kris_ML.mq5 — 第五期 EA-Kris 修正優化 + 機器學習                 |
//|                                                                  |
//| 策略邏輯 (與原版相同)：雙均線回檔進場                               |
//|   多：短均>=長均，收盤回落到兩均線之間，且離長均線 >= 縫隙           |
//|   停損 = 長均線，停利 = (進場價-長均線) x 停利倍數                   |
//|   出場：收盤跌破長均線且連續兩根收黑                                  |
//|                                                                  |
//| 修正：                                                            |
//|   * cash.mqh 每 tick 建立均線 handle → 快取                         |
//|   * 平倉函式檢查 MagicNumber+11 (不存在的單) → 移除                  |
//|   * 每日次數只在 6:00~6:05 有報價才歸零 → 交易日計數器               |
//|   * 停損距離太近被拒單 → 自動推到券商最小距離                        |
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
input string          InpSymbols = "GBPJPY,EURJPY,GBPCHF,EURGBP,EURAUD,USDJPY,AUDUSD"; // 交易商品 (逗號分隔；原版穿透測試全數獲利商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_H4; // 策略週期 (原版圖表週期)

input group "=== 策略參數 ==="
input int    InpShortMA    = 10;    // 短均線 (SMA)
input int    InpLongMA     = 40;    // 長均線 (SMA)
input double InpTPMult     = 3;     // 停利倍數 (x 停損距離)
input int    InpGap        = 350;   // 收盤與長均線最小縫隙 (點)
input int    InpMinDist    = 100;   // 現價與長均線最小距離 (點)
input int    InpMaxTradesDay=1;     // 每日下單次數上限
input int    InpDayReset   = 6;     // 每日次數歸零時間
input ENUM_TIMEFRAMES InpGuardTF = PERIOD_H4; // 每根K棒最多進出一次的週期

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = false; // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.1;   // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 9999;  // MagicNumber (空單 = +77)

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
   CBQBarGuard     m_guardOpen,m_guardClose;
   CBQDailyCounter m_daily;

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      m_daily.Init(InpDayReset);
      BQ_hMA(m_sym,m_tf,InpShortMA,0,MODE_SMA,PRICE_CLOSE);
      BQ_hMA(m_sym,m_tf,InpLongMA,0,MODE_SMA,PRICE_CLOSE);
      BQML_Setup(m_ml,"Kris",m_sym,m_tf,InpMagic);
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

      double pro  =BQ_MA(m_sym,m_tf,InpShortMA,0,MODE_SMA,PRICE_CLOSE,1);
      double trend=BQ_MA(m_sym,m_tf,InpLongMA,0,MODE_SMA,PRICE_CLOSE,1);
      if(!BQ_Ok(pro) || !BQ_Ok(trend)) return;
      double c1=iClose(m_sym,m_tf,1), o1=iOpen(m_sym,m_tf,1);
      double c2=iClose(m_sym,m_tf,2), o2=iOpen(m_sym,m_tf,2);
      double ask=m_trade.Ask(), bid=m_trade.Bid();
      int nb=m_trade.CountBuy(), ns=m_trade.CountSell();

      //=== 出場 ===
      if(!m_guardClose.Done(m_sym,InpGuardTF))
        {
         if(nb>0 && c1<trend && c1<o1 && c2<o2) { m_trade.CloseBuy();  m_guardClose.Mark(m_sym,InpGuardTF); }
         if(ns>0 && c1>trend && c1>o1 && c2>o2) { m_trade.CloseSell(); m_guardClose.Mark(m_sym,InpGuardTF); }
        }

      //=== 進場 ===
      if(nb+ns>0 || m_guardOpen.Done(m_sym,InpGuardTF) || m_daily.Count()>=InpMaxTradesDay) return;
      if(BQ_Hour()==0 || !m_trade.SpreadOK(InpMaxSpread)) return;

      bool buyCond =(pro>=trend && c1>trend && c1<pro && c1-trend>=InpGap*_Point && bid>=trend+InpMinDist*_Point);
      bool sellCond=(pro<=trend && c1<trend && c1>pro && trend-c1>=InpGap*_Point && bid<=trend-InpMinDist*_Point);

      if(buyCond)
        {
         double dist=ask-trend, tp=ask+dist*InpTPMult;
         if(dist>0 && m_ml.Allow(1,dist,dist*InpTPMult))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Buy(lots,trend,tp,"Kris B")) { m_daily.Inc(); m_guardOpen.Mark(m_sym,InpGuardTF); }
           }
        }
      else if(sellCond)
        {
         double dist=trend-bid, tp=bid-dist*InpTPMult;
         if(dist>0 && m_ml.Allow(-1,dist,dist*InpTPMult))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Sell(lots,trend,tp,"Kris S")) { m_daily.Inc(); m_guardOpen.Mark(m_sym,InpGuardTF); }
           }
        }
      SetPanel(StringFormat("Kris ML\n短均 %.5f  長均 %.5f\n今日下單 %d\n%s",pro,trend,m_daily.Count(),m_ml.Status()));
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
      PrintFormat("Kris：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("Kris：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("Kris：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("Kris ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
