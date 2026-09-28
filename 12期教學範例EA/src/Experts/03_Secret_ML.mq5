//+------------------------------------------------------------------+
//| 03_Secret_ML.mq5 — 第三期 EA-Secret 修正優化 + 機器學習             |
//|   整合 Tester-Secret v6.0 Input (自訂參數) 與 Live-Secret v7.0       |
//|   (內建 36 組商品參數表)；以 InpParamMode 切換                       |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   以每日 T 點 (預設 06:00) 為日界，取前 24 根 H1 的高低點 HH/LL      |
//|   D1 MACD 在 0 軸下方且主線>訊號線 → 在 HH 掛 BuyStop               |
//|   D1 MACD 在 0 軸上方且主線<訊號線 → 在 LL 掛 SellStop              |
//|   TYPE 1：昨日收紅才做多/收黑才做空；TYPE 2 相反；TYPE 3 不看        |
//|   停損 = 區間另一端，停利 = 2 倍區間；到 1R 時平一半並移到保本       |
//|                                                                  |
//| 修正：                                                            |
//|   * 「進場價到停損價距離」同時掃多空單，只回傳最後一張 → 多空分開算   |
//|   * 多單出場條件函式體是空的 (沒有平倉動作) → 移除                   |
//|   * 手數硬湊偶數 (0.03→0.04…) 以便平半 → 改成對齊交易量步進          |
//|     並保證至少 2 倍最小手數；平半量不足最小手數時只移保本            |
//|   * 空單掛單刪除時沒檢查 T 點，與多單不一致 → 統一                   |
//|   * MagicNumber 在每個 tick 重新計算 → OnInit 算一次                 |
//|   * 回測用 v6 固定 10000 本金計算手數 → 可選 (InpRiskBase)           |
//+------------------------------------------------------------------+
//| ★ 掛在任何圖表皆可：依 InpSymbols / InpBaseTF 交易 (預設=原版商品與週期) |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include "BeeQuant/BQ_Trade.mqh"
#include "BeeQuant/BQ_Indicators.mqh"
#include "BeeQuant/BQ_Multi.mqh"

enum ENUM_SECRET_PARAM
  {
   SECRET_INPUT = 0, // 使用下方自訂 TYPE / MACD 參數 (v6)
   SECRET_TABLE = 1  // 使用 v7 內建商品參數表
  };

input group "=== 交易商品 / 週期 (掛在任何圖表皆可) ==="
input string          InpSymbols = "AUDCAD,AUDCHF,AUDNZD,GBPJPY,NZDCHF,USDJPY,AUDJPY,EURJPY,EURCAD,AUDUSD,EURUSD,NZDCAD,GBPAUD,NZDJPY,GBPUSD"; // 交易商品 (逗號分隔；v7 參數表全部商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_H1; // 策略週期 (原版圖表週期)

input group "=== 參數來源 ==="
input ENUM_SECRET_PARAM InpParamMode = SECRET_TABLE; // 參數來源
input string InpEAMagicNum = "0";   // EA 編號 (參數表模式 0=表中所有編號；也是 Magic 前綴)
input int    InpType       = 1;     // TYPE (自訂模式)
input int    InpFastEMA    = 12;    // MACD 快線 (自訂模式)
input int    InpSlowEMA    = 26;    // MACD 慢線 (自訂模式)
input int    InpSignal     = 9;     // MACD 訊號線 (自訂模式)

input group "=== 策略參數 ==="
input int    InpDayStart   = 6;     // 日界時間 T (伺服器時)
input bool   InpHalfClose  = true;  // 到 1R 平一半並移保本
input int    InpMaxTradesDay=2;     // 每日掛單次數上限
input ENUM_TIMEFRAMES InpMACDTF = PERIOD_D1; // MACD 週期

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 0.3;   // 每筆風險 %
input double InpRiskBase   = 0;     // 計算本金 (0=帳戶餘額, v6 回測用 10000)
input double InpLots       = 0.2;   // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)

#include "BeeQuant/BQ_MLInputs.mqh"

const string SEC_SYM[]=
  {
   "AUDCAD","AUDCHF","AUDCHF","AUDNZD","AUDNZD","GBPJPY","GBPJPY","GBPJPY","GBPJPY",
   "NZDCHF","NZDCHF","USDJPY","USDJPY","USDJPY","USDJPY","AUDJPY","AUDJPY","EURJPY",
   "EURJPY","EURCAD","EURCAD","AUDUSD","AUDUSD","EURUSD","EURUSD","NZDCAD","NZDCAD",
   "GBPAUD","GBPAUD","GBPAUD","NZDJPY","NZDJPY","NZDJPY","NZDJPY","GBPUSD","GBPUSD"
  };
const int SEC_ID[]=
  {
   1,1,2,1,2,1,2,3,4,
   1,2,1,2,3,4,1,2,1,
   2,1,2,1,2,1,2,1,2,
   1,2,3,1,2,3,4,1,2
  };
const int SEC_TYPE[]=
  {
   1,1,3,1,3,1,1,3,1,
   1,3,2,3,2,3,2,3,1,
   3,2,3,2,3,2,2,1,2,
   3,1,3,3,2,3,3,1,1
  };
const int SEC_FAST[]=
  {
   20,2,3,2,22,30,2,2,2,
   7,6,2,23,4,2,9,21,2,
   5,55,43,32,4,14,14,57,7,
   12,15,18,12,3,10,20,56,70
  };
const int SEC_SLOW[]=
  {
   24,9,13,56,28,44,5,46,50,
   10,12,53,29,48,26,53,51,6,
   6,45,35,39,9,5,55,60,17,
   4,43,2,20,21,26,30,50,38
  };
const int SEC_SIG[]=
  {
   62,17,7,10,10,6,34,8,6,
   15,13,3,26,4,4,31,27,45,
   37,57,31,42,60,11,59,58,48,
   3,58,2,21,28,20,8,2,2
  };

//--- 由券商商品名稱取出 6 碼貨幣對 (處理 m.GBPJPY / GBPJPY.pro 等前後綴)
string SecretPair(const string sym)
  {
   string u=sym;
   StringToUpper(u);
   for(int r=0;r<ArraySize(SEC_SYM);r++)
      if(StringFind(u,SEC_SYM[r])>=0) return(SEC_SYM[r]);
   return(StringSubstr(u,0,6));
  }

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
   string          m_id;     // EA 編號 (參數表編號 / Magic 前綴)

                     CStrat() { m_HH=0; m_LL=0; m_CC=0; m_OO=0; m_halfBuy=false; m_halfSell=false; }
   void              SetPanel(const string s) { m_panel=s; }

   CBQTrade        m_trade;
   CBQBarGuard     m_guardBuy,m_guardSell;
   CBQDailyCounter m_daily;
   int    m_type,m_fast,m_slow,m_sig;
   long   m_magic;
   double m_HH,m_LL,m_CC,m_OO;
   bool m_halfBuy,m_halfSell;

   bool LookupTable(const string pair,const int id,int &type,int &fast,int &slow,int &sig)
     {
      for(int i=0;i<ArraySize(SEC_SYM);i++)
         if(SEC_SYM[i]==pair && SEC_ID[i]==id)
           {
            type=SEC_TYPE[i]; fast=SEC_FAST[i]; slow=SEC_SLOW[i]; sig=SEC_SIG[i];
            return(true);
           }
      return(false);
     }

   //--- 原版 getMagicNum：幣別代碼 + 週期代碼 (沿用，讓舊單仍可被管理)
   string CcyCode(const string c)
     {
      if(c=="USD") return("10"); if(c=="GBP") return("20"); if(c=="EUR") return("30");
      if(c=="AUD") return("40"); if(c=="NZD") return("50"); if(c=="JPY") return("60");
      if(c=="CAD") return("70"); if(c=="CNH") return("80"); if(c=="CHF") return("90");
      return("");
     }

   string PeriodCode()
     {
      switch(m_tf)
        {
         case PERIOD_M1: return("01");  case PERIOD_M2: return("02");  case PERIOD_M3: return("03");
         case PERIOD_M4: return("04");  case PERIOD_M6: return("05");  case PERIOD_M10: return("06");
         case PERIOD_M12: return("07"); case PERIOD_M15: return("08"); case PERIOD_M20: return("09");
         case PERIOD_M30: return("10"); case PERIOD_H1: return("11");  case PERIOD_H2: return("12");
         case PERIOD_H3: return("13");  case PERIOD_H4: return("14");  case PERIOD_H6: return("15");
         case PERIOD_H8: return("16");  case PERIOD_H12: return("17"); case PERIOD_D1: return("18");
         case PERIOD_W1: return("19");  case PERIOD_MN1: return("20");
        }
      return("00");
     }

   long CalcMagic()
     {
      string pr=SecretPair(m_sym);
      string s=m_id+CcyCode(StringSubstr(pr,0,3))+CcyCode(StringSubstr(pr,3,3))+PeriodCode();
      return(StringToInteger(s));
     }

   //--- 以 T 點為日界，更新前一「交易日」的高低開收
   void UpdateLevels()
     {
      int h=BQ_Hour();
      if(h<InpDayStart) return;          // T 點前沿用前值 (與原版相同)
      int s=1+h-InpDayStart;
      double hh=BQ_Highest(m_sym,PERIOD_H1,24,s);
      double ll=BQ_Lowest(m_sym,PERIOD_H1,24,s);
      double cc=iClose(m_sym,PERIOD_H1,s);
      double oo=iOpen(m_sym,PERIOD_H1,24+h-InpDayStart);
      if(BQ_Ok(hh) && BQ_Ok(ll) && cc>0 && oo>0)
        { m_HH=hh; m_LL=ll; m_CC=cc; m_OO=oo; }
     }

   bool BuyCond(const double bid,const double macd,const double sig)
     {
      if(!(bid<m_HH && macd<0 && macd>sig)) return(false);
      if(m_type==1) return(m_CC>m_OO);
      if(m_type==2) return(m_CC<m_OO);
      return(m_type==3);
     }

   bool SellCond(const double bid,const double macd,const double sig)
     {
      if(!(bid>m_LL && macd>0 && macd<sig)) return(false);
      if(m_type==1) return(m_CC<m_OO);
      if(m_type==2) return(m_CC>m_OO);
      return(m_type==3);
     }

   //--- 到 1R：平一半 + 停損移到進場價
   void ManageBreakEven(const ENUM_POSITION_TYPE type)
     {
      bool isBuy=(type==POSITION_TYPE_BUY);
      if(m_trade.Count(type)==0)
        {
         if(isBuy) m_halfBuy=false; else m_halfSell=false;
         return;
        }
      double open=m_trade.OpenPrice(type), sl=m_trade.PosSL(type);
      double risk=(isBuy ? open-sl : sl-open);
      if(sl<=0 || risk<=0) return;                       // 已經保本或沒有停損
      double px=(isBuy ? m_trade.Bid() : m_trade.Ask());
      bool reached=(isBuy ? px>=open+risk : px<=open-risk);
      if(!reached) return;
      bool done=(isBuy ? m_halfBuy : m_halfSell);
      if(InpHalfClose && !done)
        {
         m_trade.ClosePartial(type,0.5);
         if(isBuy) m_halfBuy=true; else m_halfSell=true;
        }
      m_trade.ModifySL(type,open);
     }

   int Setup()
     {
      string pair=SecretPair(m_sym);
      if(InpParamMode==SECRET_TABLE)
        {
         if(!LookupTable(pair,(int)StringToInteger(m_id),m_type,m_fast,m_slow,m_sig))
           {
            PrintFormat("Secret：參數表沒有 %s 編號 %s，請改用自訂參數模式或換編號",pair,m_id);
            return(INIT_PARAMETERS_INCORRECT);
           }
        }
      else
        {
         m_type=InpType; m_fast=InpFastEMA; m_slow=InpSlowEMA; m_sig=InpSignal;
        }
      if(m_type<1 || m_type>3)
        {
         Print("Secret：TYPE 必須是 1~3");
         return(INIT_PARAMETERS_INCORRECT);
        }
      m_magic=CalcMagic();
      m_trade.Init(m_sym,m_magic,m_magic+77,InpSlippage);
      m_daily.Init(InpDayStart);
      BQ_hMACD(m_sym,InpMACDTF,m_fast,m_slow,m_sig,PRICE_CLOSE);
      PrintFormat("Secret：%s TYPE=%d MACD(%d,%d,%d) Magic=%I64d",pair,m_type,m_fast,m_slow,m_sig,m_magic);
      BQML_Setup(m_ml,"Secret",m_sym,m_tf,m_magic);
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

      UpdateLevels();
      ManageBreakEven(POSITION_TYPE_BUY);
      ManageBreakEven(POSITION_TYPE_SELL);

      int hour=BQ_Hour();
      //--- 隔一個交易日仍未觸發的掛單作廢
      if(hour>=InpDayStart)
        {
         if(m_trade.PendingCount(true)>0  && !m_guardBuy.Done(m_sym,PERIOD_D1))  m_trade.DeletePending(true);
         if(m_trade.PendingCount(false)>0 && !m_guardSell.Done(m_sym,PERIOD_D1)) m_trade.DeletePending(false);
        }
      if(hour<InpDayStart || m_HH<=0 || m_LL<=0 || m_HH<=m_LL) return;
      if(m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread)) return;

      double macd=BQ_MACD(m_sym,InpMACDTF,m_fast,m_slow,m_sig,PRICE_CLOSE,0,1);
      double sig =BQ_MACD(m_sym,InpMACDTF,m_fast,m_slow,m_sig,PRICE_CLOSE,1,1);
      if(!BQ_Ok(macd) || !BQ_Ok(sig)) return;
      double bid=m_trade.Bid();
      double range=m_HH-m_LL;
      double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,range,InpLots,InpMaxLots,InpRiskBase);
      if(InpHalfClose) lots=MathMax(lots,2*m_trade.MinLot());

      if(m_trade.CountBuy()==0 && m_trade.PendingCount(true)==0 && !m_guardBuy.Done(m_sym,PERIOD_D1) &&
         BuyCond(bid,macd,sig) && m_ml.Allow(1,range,2*range))
        {
         if(m_trade.Pending(ORDER_TYPE_BUY_STOP,m_HH,lots*m_ml.LotFactor(),m_LL,m_HH+2*range,"Secret Buy"))
           {
            m_daily.Inc();
            m_guardBuy.Mark(m_sym,PERIOD_D1);
            m_halfBuy=false;
           }
        }
      if(m_trade.CountSell()==0 && m_trade.PendingCount(false)==0 && !m_guardSell.Done(m_sym,PERIOD_D1) &&
         SellCond(bid,macd,sig) && m_ml.Allow(-1,range,2*range))
        {
         if(m_trade.Pending(ORDER_TYPE_SELL_STOP,m_LL,lots*m_ml.LotFactor(),m_HH,m_LL-2*range,"Secret Sell"))
           {
            m_daily.Inc();
            m_guardSell.Mark(m_sym,PERIOD_D1);
            m_halfSell=false;
           }
        }
      SetPanel(StringFormat("Secret ML  TYPE %d  MACD(%d,%d,%d)\nHH %.5f  LL %.5f\n今日掛單 %d\n%s",
                            m_type,m_fast,m_slow,m_sig,m_HH,m_LL,m_daily.Count(),m_ml.Status()));
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
      PrintFormat("Secret：%s 初始化失敗，略過此商品",p.m_sym);
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
      bool allIds=(InpParamMode==SECRET_TABLE && StringToInteger(InpEAMagicNum)==0);
      if(!allIds)
        {
         CStrat *p=new CStrat;
         p.m_sym=syms[i];
         p.m_tf=BQ_TF(InpBaseTF);
         p.m_id=(StringToInteger(InpEAMagicNum)==0 ? "1" : InpEAMagicNum);
         AddStrat(p);
         continue;
        }
      //--- 參數表模式、編號 0：此商品在表中的每一組編號都各跑一個 (與原版每組開一張圖相同)
      string pair=SecretPair(syms[i]);
      int found=0;
      for(int r=0;r<ArraySize(SEC_SYM);r++)
        {
         if(SEC_SYM[r]!=pair) continue;
         CStrat *p=new CStrat;
         p.m_sym=syms[i];
         p.m_tf=BQ_TF(InpBaseTF);
         p.m_id=IntegerToString(SEC_ID[r]);
         if(AddStrat(p)) found++;
        }
      if(found==0)
         PrintFormat("Secret：%s 不在 v7 參數表，略過 (可改用自訂參數模式)",syms[i]);
     }
   if(ArraySize(g_strats)==0)
     {
      Print("Secret：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym+"#"+g_strats[i].m_id;
   PrintFormat("Secret：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
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
      body+=BQ_PanelLine(g_strats[i].m_sym+"#"+g_strats[i].m_id,g_strats[i].m_panel);
     }
   BQ_PanelMulti("Secret ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
