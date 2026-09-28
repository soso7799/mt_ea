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
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

#include <BeeQuant/BQ_Trade.mqh>
#include <BeeQuant/BQ_Indicators.mqh>

enum ENUM_SECRET_PARAM
  {
   SECRET_INPUT = 0, // 使用下方自訂 TYPE / MACD 參數 (v6)
   SECRET_TABLE = 1  // 使用 v7 內建商品參數表
  };

input group "=== 參數來源 ==="
input ENUM_SECRET_PARAM InpParamMode = SECRET_TABLE; // 參數來源
input string InpEAMagicNum = "1";   // EA 編號 (參數表用，也是 Magic 前綴)
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

#include <BeeQuant/BQ_MLInputs.mqh>

//--- v7 內建參數表 (由 Live-Secret v7.0.mq5 轉出)
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

CBQTrade        g_trade;
CBQBarGuard     g_guardBuy,g_guardSell;
CBQDailyCounter g_daily;
int    g_type,g_fast,g_slow,g_sig;
long   g_magic;
double g_HH=0,g_LL=0,g_CC=0,g_OO=0;
bool   g_halfBuy=false,g_halfSell=false;

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
   switch(_Period)
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
   string s=InpEAMagicNum+CcyCode(StringSubstr(_Symbol,0,3))+CcyCode(StringSubstr(_Symbol,3,3))+PeriodCode();
   return(StringToInteger(s));
  }

//--- 以 T 點為日界，更新前一「交易日」的高低開收
void UpdateLevels()
  {
   int h=BQ_Hour();
   if(h<InpDayStart) return;          // T 點前沿用前值 (與原版相同)
   int s=1+h-InpDayStart;
   double hh=BQ_Highest(_Symbol,PERIOD_H1,24,s);
   double ll=BQ_Lowest(_Symbol,PERIOD_H1,24,s);
   double cc=iClose(_Symbol,PERIOD_H1,s);
   double oo=iOpen(_Symbol,PERIOD_H1,24+h-InpDayStart);
   if(BQ_Ok(hh) && BQ_Ok(ll) && cc>0 && oo>0)
     { g_HH=hh; g_LL=ll; g_CC=cc; g_OO=oo; }
  }

bool BuyCond(const double bid,const double macd,const double sig)
  {
   if(!(bid<g_HH && macd<0 && macd>sig)) return(false);
   if(g_type==1) return(g_CC>g_OO);
   if(g_type==2) return(g_CC<g_OO);
   return(g_type==3);
  }

bool SellCond(const double bid,const double macd,const double sig)
  {
   if(!(bid>g_LL && macd>0 && macd<sig)) return(false);
   if(g_type==1) return(g_CC<g_OO);
   if(g_type==2) return(g_CC>g_OO);
   return(g_type==3);
  }

//--- 到 1R：平一半 + 停損移到進場價
void ManageBreakEven(const ENUM_POSITION_TYPE type)
  {
   bool isBuy=(type==POSITION_TYPE_BUY);
   if(g_trade.Count(type)==0)
     {
      if(isBuy) g_halfBuy=false; else g_halfSell=false;
      return;
     }
   double open=g_trade.OpenPrice(type), sl=g_trade.PosSL(type);
   double risk=(isBuy ? open-sl : sl-open);
   if(sl<=0 || risk<=0) return;                       // 已經保本或沒有停損
   double px=(isBuy ? g_trade.Bid() : g_trade.Ask());
   bool reached=(isBuy ? px>=open+risk : px<=open-risk);
   if(!reached) return;
   bool done=(isBuy ? g_halfBuy : g_halfSell);
   if(InpHalfClose && !done)
     {
      g_trade.ClosePartial(type,0.5);
      if(isBuy) g_halfBuy=true; else g_halfSell=true;
     }
   g_trade.ModifySL(type,open);
  }

int OnInit()
  {
   string pair=StringSubstr(_Symbol,0,6);
   if(InpParamMode==SECRET_TABLE)
     {
      if(!LookupTable(pair,(int)StringToInteger(InpEAMagicNum),g_type,g_fast,g_slow,g_sig))
        {
         PrintFormat("Secret：參數表沒有 %s 編號 %s，請改用自訂參數模式或換編號",pair,InpEAMagicNum);
         return(INIT_PARAMETERS_INCORRECT);
        }
     }
   else
     {
      g_type=InpType; g_fast=InpFastEMA; g_slow=InpSlowEMA; g_sig=InpSignal;
     }
   if(g_type<1 || g_type>3)
     {
      Print("Secret：TYPE 必須是 1~3");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_magic=CalcMagic();
   g_trade.Init(_Symbol,g_magic,g_magic+77,InpSlippage);
   g_daily.Init(InpDayStart);
   BQ_hMACD(_Symbol,InpMACDTF,g_fast,g_slow,g_sig,PRICE_CLOSE);
   PrintFormat("Secret：%s TYPE=%d MACD(%d,%d,%d) Magic=%I64d",pair,g_type,g_fast,g_slow,g_sig,g_magic);
   BQML_Setup("Secret",g_magic);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   g_ml.Deinit();
   BQ_ReleaseIndicators();
   Comment("");
  }

double OnTester() { return(BQ_TesterScore()); }

void OnTick()
  {
   g_ml.OnTick();
   if(AccountInfoDouble(ACCOUNT_BALANCE)<=InpMinBalance) return;

   UpdateLevels();
   ManageBreakEven(POSITION_TYPE_BUY);
   ManageBreakEven(POSITION_TYPE_SELL);

   int hour=BQ_Hour();
   //--- 隔一個交易日仍未觸發的掛單作廢
   if(hour>=InpDayStart)
     {
      if(g_trade.PendingCount(true)>0  && !g_guardBuy.Done(_Symbol,PERIOD_D1))  g_trade.DeletePending(true);
      if(g_trade.PendingCount(false)>0 && !g_guardSell.Done(_Symbol,PERIOD_D1)) g_trade.DeletePending(false);
     }
   if(hour<InpDayStart || g_HH<=0 || g_LL<=0 || g_HH<=g_LL) return;
   if(g_daily.Count()>=InpMaxTradesDay || !g_trade.SpreadOK(InpMaxSpread)) return;

   double macd=BQ_MACD(_Symbol,InpMACDTF,g_fast,g_slow,g_sig,PRICE_CLOSE,0,1);
   double sig =BQ_MACD(_Symbol,InpMACDTF,g_fast,g_slow,g_sig,PRICE_CLOSE,1,1);
   if(!BQ_Ok(macd) || !BQ_Ok(sig)) return;
   double bid=g_trade.Bid();
   double range=g_HH-g_LL;
   double lots=g_trade.CalcLots(InpAutoLots,InpRiskPct,range,InpLots,InpMaxLots,InpRiskBase);
   if(InpHalfClose) lots=MathMax(lots,2*g_trade.MinLot());

   if(g_trade.CountBuy()==0 && g_trade.PendingCount(true)==0 && !g_guardBuy.Done(_Symbol,PERIOD_D1) &&
      BuyCond(bid,macd,sig) && g_ml.Allow(1,range,2*range))
     {
      if(g_trade.Pending(ORDER_TYPE_BUY_STOP,g_HH,lots*g_ml.LotFactor(),g_LL,g_HH+2*range,"Secret Buy"))
        {
         g_daily.Inc();
         g_guardBuy.Mark(_Symbol,PERIOD_D1);
         g_halfBuy=false;
        }
     }
   if(g_trade.CountSell()==0 && g_trade.PendingCount(false)==0 && !g_guardSell.Done(_Symbol,PERIOD_D1) &&
      SellCond(bid,macd,sig) && g_ml.Allow(-1,range,2*range))
     {
      if(g_trade.Pending(ORDER_TYPE_SELL_STOP,g_LL,lots*g_ml.LotFactor(),g_HH,g_LL-2*range,"Secret Sell"))
        {
         g_daily.Inc();
         g_guardSell.Mark(_Symbol,PERIOD_D1);
         g_halfSell=false;
        }
     }
   BQ_Panel(StringFormat("Secret ML  TYPE %d  MACD(%d,%d,%d)\nHH %.5f  LL %.5f\n今日掛單 %d\n%s",
                         g_type,g_fast,g_slow,g_sig,g_HH,g_LL,g_daily.Count(),g_ml.Status()));
  }
//+------------------------------------------------------------------+
