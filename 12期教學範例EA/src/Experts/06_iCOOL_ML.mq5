//+------------------------------------------------------------------+
//| 06_iCOOL_ML.mq5 — 第六期 EA-iCOOL 修正優化 + 機器學習               |
//|                                                                  |
//| 策略邏輯 (與原版相同)：大週期布林通道強勢，小週期回檔進場            |
//|   多：小週期收盤 > 大週期布林上軌 且 > 中軌，                        |
//|       前一根收在大週期前K低點之上、這一根跌破該低點 (回檔)           |
//|   停損 = 布林中軌；出場：小週期收盤 >= 大週期前K高點 或 價格跌破中軌  |
//|   空單對稱；每日最多 5 次                                           |
//|                                                                  |
//| 修正：                                                            |
//|   * 布林通道寫死 H4，與「大時間週期」參數不一致 → 改用參數           |
//|   * cash.mqh 每 tick 建立 iBands handle → 快取                      |
//|   * 每日次數只在 6:00~6:05 有報價才歸零 → 交易日計數器               |
//|   * 風險手數用「價格與中軌距離」，對齊交易量步進                     |
//|   * 送單檢查 retcode；停損太近自動調整                               |
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
input string          InpSymbols = "GBPUSD,GBPJPY,EURUSD,EURCAD,NZDUSD,USDCAD,USDJPY,CADJPY,AUDCHF,EURAUD,GBPCAD,EURNZD,AUDCAD,EURJPY"; // 交易商品 (逗號分隔；iCOOL全商品.xml 獲利商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_M20; // 策略週期 (原版圖表週期)

input group "=== 策略參數 ==="
input int    InpBBPeriod   = 20;          // 布林週期
input double InpBBDev      = 1.5;         // 布林標準差
input ENUM_TIMEFRAMES InpSmallTF = PERIOD_M20; // 小時間週期 (進出場判斷)
input ENUM_TIMEFRAMES InpBigTF   = PERIOD_H4;  // 大時間週期 (布林與前K高低)
input int    InpMaxTradesDay = 5;         // 每日下單次數上限
input int    InpDayReset   = 6;           // 每日次數歸零時間

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 1.0;   // 每筆風險 %
input double InpLots       = 0.01;  // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)
input long   InpMagic      = 1000;  // MagicNumber (空單 = +77)

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
   CBQBarGuard     m_guardBuy,m_guardSell,m_guardClose;
   CBQDailyCounter m_daily;

   int Setup()
     {
      m_trade.Init(m_sym,InpMagic,InpMagic+77,InpSlippage);
      m_daily.Init(InpDayReset);
      BQ_hBands(m_sym,InpBigTF,InpBBPeriod,0,InpBBDev,PRICE_CLOSE);
      BQML_Setup(m_ml,"iCOOL",m_sym,m_tf,InpMagic);
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

      double mid=BQ_Bands(m_sym,InpBigTF,InpBBPeriod,InpBBDev,PRICE_CLOSE,0,1);
      double up =BQ_Bands(m_sym,InpBigTF,InpBBPeriod,InpBBDev,PRICE_CLOSE,1,1);
      double dn =BQ_Bands(m_sym,InpBigTF,InpBBPeriod,InpBBDev,PRICE_CLOSE,2,1);
      if(!BQ_Ok(mid) || !BQ_Ok(up) || !BQ_Ok(dn)) return;
      double HH=iHigh(m_sym,InpBigTF,1), LL=iLow(m_sym,InpBigTF,1);
      double c1=iClose(m_sym,InpSmallTF,1), c2=iClose(m_sym,InpSmallTF,2);
      if(HH<=0 || LL<=0 || c1<=0 || c2<=0) return;
      double ask=m_trade.Ask(), bid=m_trade.Bid();
      int nb=m_trade.CountBuy(), ns=m_trade.CountSell();

      //=== 出場 (每根小週期K棒最多一次) ===
      if(!m_guardClose.Done(m_sym,InpSmallTF))
        {
         if(nb>0 && (c1>=HH || bid<=mid)) { m_trade.CloseBuy();  m_guardClose.Mark(m_sym,InpSmallTF); }
         if(ns>0 && (c1<=LL || ask>=mid)) { m_trade.CloseSell(); m_guardClose.Mark(m_sym,InpSmallTF); }
        }

      //=== 進場 ===
      if(m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread)) return;

      if(m_trade.CountBuy()==0 && !m_guardBuy.Done(m_sym,InpSmallTF) &&
         c1>up && c2>LL && c1<LL && c1>mid)
        {
         double dist=ask-mid;
         if(dist>0 && m_ml.Allow(1,dist,0))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Buy(lots,mid,0,"HunterC B")) { m_daily.Inc(); m_guardBuy.Mark(m_sym,InpSmallTF); }
           }
        }
      if(m_trade.CountSell()==0 && !m_guardSell.Done(m_sym,InpSmallTF) &&
         c1<dn && c2<HH && c1>HH && c1<mid)
        {
         double dist=mid-bid;
         if(dist>0 && m_ml.Allow(-1,dist,0))
           {
            double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,dist,InpLots,InpMaxLots)*m_ml.LotFactor();
            if(m_trade.Sell(lots,mid,0,"HunterC S")) { m_daily.Inc(); m_guardSell.Mark(m_sym,InpSmallTF); }
           }
        }
      SetPanel(StringFormat("iCOOL ML\n上 %.5f 中 %.5f 下 %.5f\n今日下單 %d\n%s",up,mid,dn,m_daily.Count(),m_ml.Status()));
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
      PrintFormat("iCOOL：%s 初始化失敗，略過此商品",p.m_sym);
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
      Print("iCOOL：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym;
   PrintFormat("iCOOL：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
   BQ_PanelMulti("iCOOL ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
