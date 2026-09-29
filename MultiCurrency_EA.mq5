//+------------------------------------------------------------------+
//  MultiCurrency_EA.mq5  v5.3
//  7幣別平等競爭，ATR動能排序
//  5個指標全部同向 → 訂單上限由FilterLib控制
//  風控全部由 FilterLib_v5.mqh 處理
//
//  v5.3（參考 BeeQuant12 共用函式庫的修正）
//   * 券商商品名稱自動對應後綴/前綴（USDJPY → USDJPY.m 等）；找不到的商品略過，不再整支 EA 啟動失敗
//   * 下單改走 filter.OpenMarket：成交模式、手數步進、最小停損距離、retcode 檢查與重試
//   * 每秒 OnTimer 檢查一次：其他商品不會觸發圖表的 OnTick，原本只有圖表商品跳動時才掃描
//   * 帳戶保護：可限定帳號、可禁止在真實帳戶執行
//   * 移除沒有使用、且每次呼叫都建立/釋放 ATR handle 的 GetAtrPips()
//
//  v5.4  K線型態濾網（CandlePatterns.mqh：翻多16招 + 翻空18招）
//   * Inp_CP_Mode：關閉 / 反向型態擋單 / 必須同向型態 / 當第6個指標加權
//   * Inp_CP_ExitOnReverse：持倉出現反向型態時主動平倉
//
//  v5.5  機器學習訊號過濾（移植 BeeQuant12 BQ_ML.mqh）
//   * 每個商品一個線上邏輯斯迴歸模型，估計訊號「先到停利」的機率
//   * 機率 >= 兩平勝率 + Inp_ML_Threshold 才放行；前 Inp_ML_MinSamples 個訊號只學習不過濾
//   * 每個訊號（含被擋掉、沒被選中的）都建立虛擬單追蹤標記，避免選擇偏誤
//   * 模型存在 Common\Files\BeeQuantML\，可匯出 CSV 用 ml/train_logit.py 離線訓練
//
//  v5.6  策略週期改為參數 Inp_TF（預設 M12，與原本相同）
//   * 進場指標、新K棒判斷、追蹤停損擺動點、F段反向信號平倉、K線型態、ML 全部使用同一週期
//     （原本 F段反向信號用的是 FilterLib 建構子預設的 H1，與進場的 M12 不一致）
//   * ⚠️ 各商品指標參數是在 M12 上調整的，改用其他週期請重新回測/最佳化
//------------------------------------------------------------------+
#property version "5.60"
#include <FilterLib_v5.mqh>
#include <CandlePatterns.mqh>
#include <BQ_ML.mqh>

input group "=== Basic ==="
input ENUM_TIMEFRAMES Inp_TF = PERIOD_M12; // 策略週期（進場/追蹤停損/反向平倉/型態/ML 共用）
input long Inp_Magic      = 20250101;
input int  Inp_MaxPos     = 3;
input int  Inp_MinConfirm = 3; // 普通信號最少幾個指標同向(1~3)

input group "=== Account Protection ==="
input bool Inp_AllowReal   = true; // 允許在真實帳戶執行（false = 只在模擬帳戶執行）
input long Inp_LockAccount = 0;    // 只允許此帳號執行（0 = 不限）

input group "=== K線型態濾網（翻多16招/翻空18招）==="
input ENUM_CP_MODE    Inp_CP_Mode          = CP_VETO;    // 濾網模式
input ENUM_TIMEFRAMES Inp_CP_TF            = PERIOD_CURRENT; // 型態判斷週期（目前=同策略週期）
input int             Inp_CP_Weight        = 2;          // 計分模式的權重
input bool            Inp_CP_ExitOnReverse = false;      // 持倉出現反向型態時平倉
input bool            Inp_CP_ConfirmAll    = false;      // 所有型態都要下一根K棒突破/跌破確認
input bool            Inp_CP_StrictGap     = false;      // 跳空用高低點判斷（false=實體跳空，外匯建議）
input int             Inp_CP_TrendBars     = 5;          // 趨勢回看K棒數
input double          Inp_CP_TrendATR      = 1.0;        // 趨勢最小幅度（ATR倍數）
input double          Inp_CP_LongATR       = 0.7;        // 長紅/長黑 實體 >= ATR倍數
input double          Inp_CP_SmallATR      = 0.35;       // 小K 實體 <= ATR倍數
input double          Inp_CP_DojiATR       = 0.12;       // 十字/變盤線 實體 <= ATR倍數
input double          Inp_CP_NearATR       = 0.15;       // 「相近」容許誤差（ATR倍數）
input string          Inp_CP_Disable       = "";         // 停用的型態代碼，例如 B5,S7

input group "=== 機器學習 (ML) 訊號過濾 ==="
input ENUM_BQML_MODE  Inp_ML_Mode       = BQML_FILTER; // ML 模式
input double          Inp_ML_Threshold  = 0.03;        // 放行門檻：預估勝率需高於兩平勝率多少
input int             Inp_ML_MinSamples = 40;          // 暖機樣本數（之前不過濾）
input double          Inp_ML_BarrierTP  = 0;           // 標記用停利 ATR 倍數（0=用 fx_rules 停利）
input double          Inp_ML_BarrierSL  = 0;           // 標記用停損 ATR 倍數（0=用 fx_rules 停損）
input int             Inp_ML_MaxBars    = 48;          // 虛擬單最長追蹤 K 棒數
input bool            Inp_ML_LoadModel  = true;        // 啟動時載入已存模型
input bool            Inp_ML_SaveModel  = true;        // 結束時儲存模型
input bool            Inp_ML_ExportCSV  = false;       // 匯出訓練資料 CSV（給 ml/train_logit.py）
input bool            Inp_ML_ScaleLots  = false;       // 依預估優勢調整手數（0.5~1.5倍）
input ENUM_TIMEFRAMES Inp_ML_TF         = PERIOD_CURRENT; // 特徵計算週期（目前=同策略週期）

input group "=== Symbols ==="
input string Inp_Sym1 = "USDJPY";
input string Inp_Sym2 = "AUDUSD";
input string Inp_Sym3 = "USDCAD";
input string Inp_Sym4 = "GBPUSD";
input string Inp_Sym5 = "EURUSD";
input string Inp_Sym6 = "USDCHF";
input string Inp_Sym7 = "NZDUSD";

input group "=== Sym1 (USDJPY) ==="
input int    S1_EMA_F=10;  input int    S1_EMA_S=30;
input int    S1_RSI_P=14; input int    S1_RSI_OS=42; input int S1_RSI_OB=58;
input int    S1_BB_P=14;  input double S1_BB_Std=2.25;
input int    S1_MF=10;    input int    S1_MS=24;      input int S1_MSig=7;
input int    S1_KP=9;     input int    S1_KK=3;       input int S1_KD=3;

input group "=== Sym2 (AUDUSD) ==="
input int    S2_EMA_F=9;  input int    S2_EMA_S=26;
input int    S2_RSI_P=14; input int    S2_RSI_OS=38; input int S2_RSI_OB=62;
input int    S2_BB_P=22;  input double S2_BB_Std=1.5;
input int    S2_MF=12;    input int    S2_MS=26;      input int S2_MSig=9;
input int    S2_KP=14;    input int    S2_KK=3;       input int S2_KD=3;

input group "=== Sym3 (USDCAD) ==="
input int    S3_EMA_F=12;  input int    S3_EMA_S=30;
input int    S3_RSI_P=14; input int    S3_RSI_OS=40; input int S3_RSI_OB=60;
input int    S3_BB_P=14;  input double S3_BB_Std=2.25;
input int    S3_MF=11;    input int    S3_MS=25;      input int S3_MSig=8;
input int    S3_KP=9;     input int    S3_KK=3;       input int S3_KD=3;

input group "=== Sym4 (GBPUSD) ==="
input int    S4_EMA_F=8;  input int    S4_EMA_S=21;
input int    S4_RSI_P=14; input int    S4_RSI_OS=35; input int S4_RSI_OB=65;
input int    S4_BB_P=24;  input double S4_BB_Std=1.5;
input int    S4_MF=8;    input int    S4_MS=21;      input int S4_MSig=5;
input int    S4_KP=14;    input int    S4_KK=3;       input int S4_KD=3;

input group "=== Sym5 (EURUSD) ==="
input int    S5_EMA_F=9;  input int    S5_EMA_S=26;
input int    S5_RSI_P=14; input int    S5_RSI_OS=40; input int S5_RSI_OB=60;
input int    S5_BB_P=14;  input double S5_BB_Std=1.75;
input int    S5_MF=12;    input int    S5_MS=26;      input int S5_MSig=9;
input int    S5_KP=9;     input int    S5_KK=3;       input int S5_KD=3;

input group "=== Sym6 (USDCHF) ==="
input int    S6_EMA_F=10;  input int    S6_EMA_S=30;
input int    S6_RSI_P=14; input int    S6_RSI_OS=42; input int S6_RSI_OB=58;
input int    S6_BB_P=18;  input double S6_BB_Std=2.5;
input int    S6_MF=12;    input int    S6_MS=28;      input int S6_MSig=9;
input int    S6_KP=9;     input int    S6_KK=3;       input int S6_KD=3;

input group "=== Sym7 (NZDUSD) ==="
input int    S7_EMA_F=9;  input int    S7_EMA_S=26;
input int    S7_RSI_P=14; input int    S7_RSI_OS=38; input int S7_RSI_OB=62;
input int    S7_BB_P=18;  input double S7_BB_Std=2.0;
input int    S7_MF=10;    input int    S7_MS=24;      input int S7_MSig=7;
input int    S7_KP=14;    input int    S7_KK=3;       input int S7_KD=3;

//------------------------------------------------------------------
CFilterLib_Pro filter(Inp_Magic);
ENUM_TIMEFRAMES g_tf   = PERIOD_M12;   // 實際策略週期（OnInit 由 Inp_TF 決定）
ENUM_TIMEFRAMES g_cpTF = PERIOD_M12;   // 實際型態週期
CTrade         trade;
CCandlePatterns cp;

#define SYM_COUNT 7
CBQMLFilter ml[SYM_COUNT];   // 每個商品一個 ML 模型（模型檔名含商品名稱，互不干擾）
#define IND_COUNT 5
int weight[IND_COUNT] = {3,2,1,2,1};

string   symbols[SYM_COUNT];
bool     symOk[SYM_COUNT];      // 券商有此商品且指標建立成功
datetime lastBarTime[SYM_COUNT];
int startIndex=0;

struct SHandles { int ef,es,rsi,bb,macd,stoch; };
SHandles H[SYM_COUNT];

int    g_ef[SYM_COUNT],g_es[SYM_COUNT],g_rp[SYM_COUNT],g_bp[SYM_COUNT];
double g_bs[SYM_COUNT];
int    g_mf[SYM_COUNT],g_ms[SYM_COUNT],g_mg[SYM_COUNT];
int    g_kp[SYM_COUNT],g_kk[SYM_COUNT],g_kd[SYM_COUNT];
int    g_ros[SYM_COUNT],g_rob[SYM_COUNT];

struct SCandidate { int si; int sig; double atr; int confirm; };

// K線型態結果快取：同一根型態週期K棒只計算一次
datetime cpBarTime[SYM_COUNT];
int      cpDir[SYM_COUNT];
string   cpNames[SYM_COUNT];
datetime cpExitBar[SYM_COUNT];   // 反向型態平倉：每根K棒只處理一次

// 回傳該商品最近完成的型態方向 (+1 翻多 / -1 翻空 / 0 無)
int GetPattern(int si)
{
   datetime t=iTime(symbols[si],g_cpTF,0);
   if(t==0) return 0;
   if(t!=cpBarTime[si])
   {
      string names="";
      cpDir[si]=cp.Detect(symbols[si],g_cpTF,names);
      cpNames[si]=names;
      cpBarTime[si]=t;
      if(names!="")
         PrintFormat("🕯 %s %s 型態：%s",symbols[si],EnumToString(g_cpTF),names);
   }
   return cpDir[si];
}

// 持倉出現反向K線型態時主動平倉
void CheckPatternExit()
{
   if(Inp_CP_Mode==CP_OFF || !Inp_CP_ExitOnReverse) return;

   for(int si=0;si<SYM_COUNT;si++)
   {
      if(!symOk[si]) continue;
      int pd=GetPattern(si);
      if(pd==0 || cpExitBar[si]==cpBarTime[si]) continue;
      cpExitBar[si]=cpBarTime[si];

      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=symbols[si]) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;

         int dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? 1 : -1;
         if(dir!=-pd) continue;

         trade.SetTypeFillingBySymbol(symbols[si]);
         if(trade.PositionClose(ticket) &&
            (trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_PLACED))
            PrintFormat("🕯 %s 反向型態 %s → 平倉 #%I64u",symbols[si],cpNames[si],ticket);
         else
            PrintFormat("❌ %s 反向型態平倉失敗 retcode=%u",symbols[si],trade.ResultRetcode());
      }
   }
}

//------------------------------------------------------------------
bool CheckNewBar(int idx)
{
   datetime cur=iTime(symbols[idx],g_tf,0);
   return (cur!=lastBarTime[idx]);
}

void MarkBarUsed(int idx)
{
   lastBarTime[idx]=iTime(symbols[idx],g_tf,0);
}

int CountPos()
{
   int n=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket>0)
      {
         if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic)
            n++;
      }
   }

   return n;
}

bool HasPos(string sym)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket>0)
      {
         if(PositionGetString(POSITION_SYMBOL)==sym &&
            PositionGetInteger(POSITION_MAGIC)==Inp_Magic)
            return true;
      }
   }

   return false;
}

// 找券商實際的商品名稱（處理後綴/前綴，例如 USDJPY → USDJPY.m / USDJPYpro / m.USDJPY），
// 並加入 Market Watch；找不到回傳 ""（參考 BeeQuant12 BQ_Multi.mqh）
string ResolveSymbol(string want)
{
   StringTrimLeft(want);
   StringTrimRight(want);
   if(want=="") return "";

   bool custom=false;
   if(SymbolExist(want,custom))
   {
      SymbolSelect(want,true);
      return want;
   }

   string up=want;
   StringToUpper(up);
   string best="";
   bool   bestSel=false;

   for(int i=0;i<SymbolsTotal(false);i++)
   {
      string name=SymbolName(i,false);
      string u=name;
      StringToUpper(u);
      int p=StringFind(u,up);
      if(p<0 || p>3) continue;   // 只接受短前綴

      bool sel=(SymbolInfoInteger(name,SYMBOL_SELECT)!=0);
      if(best=="" || (sel && !bestSel) || (sel==bestSel && StringLen(name)<StringLen(best)))
      {
         best=name;
         bestSel=sel;
      }
   }

   if(best!="") SymbolSelect(best,true);
   return best;
}

bool AccountAllowed()
{
   long login=AccountInfoInteger(ACCOUNT_LOGIN);

   if(Inp_LockAccount!=0 && login!=Inp_LockAccount)
   {
      PrintFormat("帳戶保護：目前帳號 %I64d 不是指定帳號 %I64d，EA 不啟動",login,Inp_LockAccount);
      return false;
   }

   if(!Inp_AllowReal &&
      (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_REAL)
   {
      PrintFormat("帳戶保護：帳號 %I64d 是真實帳戶，Inp_AllowReal=false，EA 不啟動",login);
      Alert("EA 未啟動：這是真實帳戶（要在真實帳戶執行請把 Inp_AllowReal 設為 true）");
      return false;
   }

   return true;
}

void ReleaseHandles(int i)
{
   if(H[i].ef   !=INVALID_HANDLE) IndicatorRelease(H[i].ef);
   if(H[i].es   !=INVALID_HANDLE) IndicatorRelease(H[i].es);
   if(H[i].rsi  !=INVALID_HANDLE) IndicatorRelease(H[i].rsi);
   if(H[i].bb   !=INVALID_HANDLE) IndicatorRelease(H[i].bb);
   if(H[i].macd !=INVALID_HANDLE) IndicatorRelease(H[i].macd);
   if(H[i].stoch!=INVALID_HANDLE) IndicatorRelease(H[i].stoch);
   H[i].ef=INVALID_HANDLE;  H[i].es=INVALID_HANDLE;   H[i].rsi=INVALID_HANDLE;
   H[i].bb=INVALID_HANDLE;  H[i].macd=INVALID_HANDLE; H[i].stoch=INVALID_HANDLE;
}

//------------------------------------------------------------------
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER) && !AccountAllowed())
      return INIT_FAILED;

   trade.SetExpertMagicNumber(Inp_Magic);

   g_tf  =(Inp_TF==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : Inp_TF);
   g_cpTF=(Inp_CP_TF==PERIOD_CURRENT ? g_tf : Inp_CP_TF);
   filter.SetTimeframe(g_tf);

   cp.TrendBars =Inp_CP_TrendBars;
   cp.TrendATR  =Inp_CP_TrendATR;
   cp.LongATR   =Inp_CP_LongATR;
   cp.SmallATR  =Inp_CP_SmallATR;
   cp.DojiATR   =Inp_CP_DojiATR;
   cp.NearATR   =Inp_CP_NearATR;
   cp.StrictGap =Inp_CP_StrictGap;
   cp.ConfirmAll=Inp_CP_ConfirmAll;
   cp.SetDisabled(Inp_CP_Disable);

   ENUM_TIMEFRAMES mlTF=(Inp_ML_TF==PERIOD_CURRENT ? g_tf : Inp_ML_TF);

   if(!filter.InitIndicators())
      return INIT_FAILED;

   string want[SYM_COUNT];
   want[0]=Inp_Sym1; want[1]=Inp_Sym2; want[2]=Inp_Sym3;
   want[3]=Inp_Sym4; want[4]=Inp_Sym5; want[5]=Inp_Sym6;
   want[6]=Inp_Sym7;
   for(int i=0;i<SYM_COUNT;i++)
   {
      symbols[i]=ResolveSymbol(want[i]);
      if(symbols[i]!="" && symbols[i]!=want[i])
         PrintFormat("商品 %s → 券商名稱 %s",want[i],symbols[i]);
   }

   g_ef[0]=S1_EMA_F;   g_ef[1]=S2_EMA_F;   g_ef[2]=S3_EMA_F;   g_ef[3]=S4_EMA_F;   g_ef[4]=S5_EMA_F;   g_ef[5]=S6_EMA_F;   g_ef[6]=S7_EMA_F;
   g_es[0]=S1_EMA_S;   g_es[1]=S2_EMA_S;   g_es[2]=S3_EMA_S;   g_es[3]=S4_EMA_S;   g_es[4]=S5_EMA_S;   g_es[5]=S6_EMA_S;   g_es[6]=S7_EMA_S;
   g_rp[0]=S1_RSI_P;   g_rp[1]=S2_RSI_P;   g_rp[2]=S3_RSI_P;   g_rp[3]=S4_RSI_P;   g_rp[4]=S5_RSI_P;   g_rp[5]=S6_RSI_P;   g_rp[6]=S7_RSI_P;
   g_bp[0]=S1_BB_P;    g_bp[1]=S2_BB_P;    g_bp[2]=S3_BB_P;    g_bp[3]=S4_BB_P;    g_bp[4]=S5_BB_P;    g_bp[5]=S6_BB_P;    g_bp[6]=S7_BB_P;
   g_bs[0]=S1_BB_Std;  g_bs[1]=S2_BB_Std;  g_bs[2]=S3_BB_Std;  g_bs[3]=S4_BB_Std;  g_bs[4]=S5_BB_Std;  g_bs[5]=S6_BB_Std;  g_bs[6]=S7_BB_Std;
   g_mf[0]=S1_MF;      g_mf[1]=S2_MF;      g_mf[2]=S3_MF;      g_mf[3]=S4_MF;      g_mf[4]=S5_MF;      g_mf[5]=S6_MF;      g_mf[6]=S7_MF;
   g_ms[0]=S1_MS;      g_ms[1]=S2_MS;      g_ms[2]=S3_MS;      g_ms[3]=S4_MS;      g_ms[4]=S5_MS;      g_ms[5]=S6_MS;      g_ms[6]=S7_MS;
   g_mg[0]=S1_MSig;    g_mg[1]=S2_MSig;    g_mg[2]=S3_MSig;    g_mg[3]=S4_MSig;    g_mg[4]=S5_MSig;    g_mg[5]=S6_MSig;    g_mg[6]=S7_MSig;
   g_kp[0]=S1_KP;      g_kp[1]=S2_KP;      g_kp[2]=S3_KP;      g_kp[3]=S4_KP;      g_kp[4]=S5_KP;      g_kp[5]=S6_KP;      g_kp[6]=S7_KP;
   g_kk[0]=S1_KK;      g_kk[1]=S2_KK;      g_kk[2]=S3_KK;      g_kk[3]=S4_KK;      g_kk[4]=S5_KK;      g_kk[5]=S6_KK;      g_kk[6]=S7_KK;
   g_kd[0]=S1_KD;      g_kd[1]=S2_KD;      g_kd[2]=S3_KD;      g_kd[3]=S4_KD;      g_kd[4]=S5_KD;      g_kd[5]=S6_KD;      g_kd[6]=S7_KD;
   g_ros[0]=S1_RSI_OS; g_ros[1]=S2_RSI_OS; g_ros[2]=S3_RSI_OS; g_ros[3]=S4_RSI_OS; g_ros[4]=S5_RSI_OS; g_ros[5]=S6_RSI_OS; g_ros[6]=S7_RSI_OS;
   g_rob[0]=S1_RSI_OB; g_rob[1]=S2_RSI_OB; g_rob[2]=S3_RSI_OB; g_rob[3]=S4_RSI_OB; g_rob[4]=S5_RSI_OB; g_rob[5]=S6_RSI_OB; g_rob[6]=S7_RSI_OB;

   int okCount=0;
   for(int i=0;i<SYM_COUNT;i++)
   {
      string s=symbols[i];
      symOk[i]=false;
      lastBarTime[i]=0;
      cpBarTime[i]=0; cpDir[i]=0; cpNames[i]=""; cpExitBar[i]=0;
      H[i].ef=INVALID_HANDLE;  H[i].es=INVALID_HANDLE;   H[i].rsi=INVALID_HANDLE;
      H[i].bb=INVALID_HANDLE;  H[i].macd=INVALID_HANDLE; H[i].stoch=INVALID_HANDLE;

      if(s=="")
      {
         PrintFormat("⚠️ 商品 %s 在此券商找不到，略過",want[i]);
         continue;
      }

      H[i].ef   =iMA(s,g_tf,g_ef[i],0,MODE_EMA,PRICE_CLOSE);
      H[i].es   =iMA(s,g_tf,g_es[i],0,MODE_EMA,PRICE_CLOSE);
      H[i].rsi  =iRSI(s,g_tf,g_rp[i],PRICE_CLOSE);
      H[i].bb   =iBands(s,g_tf,g_bp[i],0,g_bs[i],PRICE_CLOSE);
      H[i].macd =iMACD(s,g_tf,g_mf[i],g_ms[i],g_mg[i],PRICE_CLOSE);
      H[i].stoch=iStochastic(s,g_tf,g_kp[i],g_kk[i],g_kd[i],MODE_SMA,STO_LOWHIGH);
      if(H[i].ef==INVALID_HANDLE||H[i].es==INVALID_HANDLE||
         H[i].rsi==INVALID_HANDLE||H[i].bb==INVALID_HANDLE||
         H[i].macd==INVALID_HANDLE||H[i].stoch==INVALID_HANDLE)
      {
         PrintFormat("⚠️ %s 指標建立失敗(err=%d)，略過此商品",s,GetLastError());
         ReleaseHandles(i);
         continue;
      }

      symOk[i]=true;
      okCount++;

      ml[i].Init("MultiCurrency",s,mlTF,Inp_Magic,Inp_ML_Mode,Inp_ML_Threshold,Inp_ML_MinSamples,
                 Inp_ML_BarrierTP,Inp_ML_BarrierSL,Inp_ML_MaxBars,
                 Inp_ML_LoadModel,Inp_ML_SaveModel,Inp_ML_ExportCSV,Inp_ML_ScaleLots);
   }

   if(okCount==0)
   {
      Print("Init failed: 沒有任何可交易的商品");
      return INIT_FAILED;
   }

   // 其他商品不會觸發這張圖表的 OnTick，每秒另外檢查一次
   EventSetTimer(1);

   PrintFormat("EA v5.6 started（週期 %s，%d/%d 個商品可交易）",EnumToString(g_tf),okCount,SYM_COUNT);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   // 儲存模型並印出「放行單勝率 vs 擋掉單勝率」與各特徵權重
   for(int i=0;i<SYM_COUNT;i++)
      if(symOk[i]) ml[i].Deinit();
   BQ_ReleaseIndicators();

   filter.DeinitIndicators();
   cp.Release();

   for(int i=0;i<SYM_COUNT;i++)
      ReleaseHandles(i);
}

//------------------------------------------------------------------
int GetOneSignal(int si,int indType)
{

  // ================= EMA =================
if(indType==0)
{
   double ef[3],es[3];
   double c0=iClose(symbols[si],g_tf,1);

   if(CopyBuffer(H[si].ef,0,1,3,ef)<3) return 0;
   if(CopyBuffer(H[si].es,0,1,3,es)<3) return 0;

   double ef0=ef[0];
   double ef1=ef[1];
   double ef2=ef[2];

   double es0=es[0];
   double es1=es[1];

   // ===== 黃金交叉 =====
   if(ef1<=es1 && ef0>es0)
      return 1;

   // ===== 死亡交叉 =====
   if(ef1>=es1 && ef0<es0)
      return -1;

   // ===== 趨勢延續 + 價格確認 =====
   if(ef0>es0 && ef1>es1 && ef0>ef1 && c0>ef0)
      return 1;

   if(ef0<es0 && ef1<es1 && ef0<ef1 && c0<ef0)
      return -1;

   // ===== 均線斜率 + 趨勢 =====
   if(ef0>ef1 && ef1>ef2 && ef0>es0 && c0>ef0)
      return 1;

   if(ef0<ef1 && ef1<ef2 && ef0<es0 && c0<ef0)
      return -1;

   return 0;
}
 // ================= RSI =================
if(indType==1)
{
   double r[3];

   if(CopyBuffer(H[si].rsi,0,1,3,r)<3)
      return 0;

   double r0=r[0];
   double r1=r[1];
   double r2=r[2];

   int os=g_ros[si];
   int ob=g_rob[si];

   // ===== 超賣反轉 =====
   if(r1<os && r0>os)
      return 1;

   // ===== 超買反轉 =====
   if(r1>ob && r0<ob)
      return -1;

   // ===== 中線趨勢 =====
   if(r1<=50 && r0>50)
      return 1;

   if(r1>=50 && r0<50)
      return -1;

   // ===== 動能加速 =====
   if(r0>r1 && r1>r2 && r0>55)
      return 1;

   if(r0<r1 && r1<r2 && r0<45)
      return -1;

   return 0;
}

// ================= BB =================
if(indType==2)
{
   double up[2],lo[2],mid[2];

   if(CopyBuffer(H[si].bb,0,1,2,mid)<2) return 0;
   if(CopyBuffer(H[si].bb,1,1,2,up)<2)  return 0;
   if(CopyBuffer(H[si].bb,2,1,2,lo)<2)  return 0;

   double c0=iClose(symbols[si],g_tf,1);
   double c1=iClose(symbols[si],g_tf,2);

   double bw0=up[0]-lo[0];
   double bw1=up[1]-lo[1];

   // ===== 張口過濾 =====
   if(bw0<bw1) return 0;

   // ===== 下軌反彈 =====
   if(c1<=lo[1] && c0>lo[0])
      return 1;

   // ===== 上軌反轉 =====
   if(c1>=up[1] && c0<up[0])
      return -1;

   // ===== 沿上軌走 =====
   if(c0>up[0])
      return 1;

   // ===== 沿下軌走 =====
   if(c0<lo[0])
      return -1;

   return 0;
}

   // ================= MACD =================
if(indType==3)
{
   double macd[3],signal[3],hist[3];

   if(CopyBuffer(H[si].macd,0,1,3,macd)<3) return 0;
   if(CopyBuffer(H[si].macd,1,1,3,signal)<3) return 0;
   if(CopyBuffer(H[si].macd,2,1,3,hist)<3) return 0;

   double m0=macd[0];
   double m1=macd[1];

   double s0=signal[0];
   double s1=signal[1];

   double h0=hist[0];
   double h1=hist[1];
   double h2=hist[2];

   // ===== MACD交叉 =====
   if(m1<=s1 && m0>s0)
      return 1;

   if(m1>=s1 && m0<s0)
      return -1;

   // ===== Histogram動量 =====
   if(h0>0 && h1>0 && h0>h1 && h1>h2)
      return 1;

   if(h0<0 && h1<0 && h0<h1 && h1<h2)
      return -1;

   // ===== Histogram反轉 =====
   if(h1<0 && h0>h1)
      return 1;

   if(h1>0 && h0<h1)
      return -1;

   // ===== 零軸趨勢 =====
   if(m0>0 && m0>m1)
      return 1;

   if(m0<0 && m0<m1)
      return -1;

   return 0;
}
   // ================= STOCH =================
   if(indType==4)
   {
      double kv[3],dv[3];

      if(CopyBuffer(H[si].stoch,MAIN_LINE,1,3,kv)<3) return 0;
      if(CopyBuffer(H[si].stoch,SIGNAL_LINE,1,3,dv)<3) return 0;

      if(
         kv[2]<=dv[2] &&
         kv[1]>dv[1] &&
         kv[1]<30 &&
         kv[1]>kv[2]
      )
         return 1;

      if(
         kv[2]>=dv[2] &&
         kv[1]<dv[1] &&
         kv[1]>70 &&
         kv[1]<kv[2]
      )
         return -1;

      return 0;
   }

   return 0;
}

void GetSignalWithConfirm(int si, int &sig, int &confirm)
{
   sig=0;
   confirm=0;

   int buyScore=0;
   int sellScore=0;

   for(int t=0;t<IND_COUNT;t++)
   {
      int s=GetOneSignal(si,t);

      if(s==1)
         buyScore+=weight[t];

      if(s==-1)
         sellScore+=weight[t];
   }

   int pd=(Inp_CP_Mode==CP_OFF) ? 0 : GetPattern(si);

   // 計分模式：K線型態當作第6個指標
   if(Inp_CP_Mode==CP_SCORE)
   {
      if(pd== 1) buyScore +=Inp_CP_Weight;
      if(pd==-1) sellScore+=Inp_CP_Weight;
   }

   if(buyScore>=Inp_MinConfirm && buyScore>sellScore)
   {
      sig=1;
      confirm=buyScore;
   }
   else if(sellScore>=Inp_MinConfirm && sellScore>buyScore)
   {
      sig=-1;
      confirm=sellScore;
   }

   if(sig==0) return;

   // 擋單模式：出現反向型態不進場；必須模式：沒有同向型態不進場
   if((Inp_CP_Mode==CP_VETO    && pd==-sig) ||
      (Inp_CP_Mode==CP_REQUIRE && pd!= sig))
   {
      sig=0;
      confirm=0;
   }
}


//------------------------------------------------------------------
//  TryOpenPositions
//  第一輪：5/5最強信號 → 波動正常即進場，訂單上限由FilterLib控制
//  第二輪：普通信號 → ATR排序，訂單上限由FilterLib控制，每K棒1單
//------------------------------------------------------------------


void TryOpenPositions()
{
  
  
   int sigArr[SYM_COUNT];
   int confArr[SYM_COUNT];

   // ===== 第一階段：收集信號 =====
   for(int i=0;i<SYM_COUNT;i++)
   {
     
      sigArr[i] = 0;
      confArr[i] = 0;

      if(!symOk[i])
         continue;

      if(!CheckNewBar(i))
         continue;

      if(HasPos(symbols[i]))
         continue;

      if(!filter.IsVolatilityNormal(symbols[i]))
         continue;

      int sig = 0;
      int confirm = 0;

      GetSignalWithConfirm(i,sig,confirm);

      // ML 過濾：每個訊號（不論最後有沒有被選中下單）都會建立虛擬單學習；
      // 同一根K棒同方向重複詢問會回傳第一次的結果，不會重複建立
      if(sig!=0 && Inp_ML_Mode!=BQML_OFF)
      {
         double slD=0, tpD=0;
         filter.GetStopDistances(symbols[i], slD, tpD);
         if(!ml[i].Allow(sig, slD, tpD))
         {
            sig=0;
            confirm=0;
         }
      }

      sigArr[i]  = sig;
      confArr[i] = confirm;
   }

   // ===== 第二階段：選最高confirm =====
   int bestIndex=-1;
   int bestScore=0;

   for(int i=0;i<SYM_COUNT;i++)
   {
      if(sigArr[i]==0)
         continue;

      if(confArr[i] > bestScore)
      {
         bestScore = confArr[i];
         bestIndex = i;
      }
   }

   if(bestIndex==-1)
      return;

   string sym = symbols[bestIndex];
   int sig    = sigArr[bestIndex];

   // ★ 持倉上限由 EA 自行控制（FilterLib_v5.mqh 的 AllowTrading 不含此參數）
   int curRiskPos = CountPos(); // 用 magic 計算較準（PositionsTotal()會含其他EA/手動單）
   if(curRiskPos >= Inp_MaxPos)
      return;

   // ★ 其餘開倉條件與 SL/TP 由 FilterLib 統一決定
   double sl=0, tp=0;

   if(!filter.AllowTrading(sym, sig, sl, tp))
      return;
   double lot = filter.GetLotSize(sym) * ml[bestIndex].LotFactor();

   // 成交模式、手數步進、最小停損距離、retcode 檢查與重試都在 OpenMarket 處理，失敗原因會印在日誌
   if(filter.OpenMarket(sym, sig, lot, sl, tp, sig>0 ? "MC BUY" : "MC SELL"))
      MarkBarUsed(bestIndex);
}

//------------------------------------------------------------------
void RunCycle()
{
   // 推進各商品的 ML 虛擬單（先到停利=1 / 先到停損=0），並即時更新模型
   for(int i=0;i<SYM_COUNT;i++)
      if(symOk[i]) ml[i].OnTick();

   filter.MonitorPositions();
   CheckPatternExit();
   TryOpenPositions();

   // 回測不繪製面板，節省時間
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;

   string posInfo="";
   string symList="";
   string cpInfo="";
   string mlInfo="";
   for(int i=0;i<SYM_COUNT;i++)
   {
      if(!symOk[i]) continue;
      if(HasPos(symbols[i])) posInfo+=symbols[i]+" ";
      symList+=(symList=="" ? "" : "/")+symbols[i];
      if(cpNames[i]!="") cpInfo+=symbols[i]+": "+cpNames[i]+"\n";
      if(Inp_ML_Mode!=BQML_OFF) mlInfo+=StringFormat("%s p=%.2f  ",symbols[i],ml[i].LastProb());
   }
   string reportSym=Inp_Sym1;
   for(int i=0;i<SYM_COUNT;i++)
      if(symOk[i]) { reportSym=symbols[i]; break; }

   Comment(
      "MultiCurrency EA v5.6  週期="+EnumToString(g_tf)+"\n",
      "MinConfirm=",IntegerToString(Inp_MinConfirm)," | 5/5訂單上限由FilterLib控制\n",
      symList+"\n",
     "持倉("+IntegerToString(CountPos())+"/"+IntegerToString(Inp_MaxPos)+"): "+posInfo+"\n",
      "K線型態("+EnumToString(Inp_CP_Mode)+"):\n"+(cpInfo=="" ? "  無\n" : cpInfo),
      "ML("+EnumToString(Inp_ML_Mode)+"): "+(mlInfo=="" ? "關閉" : mlInfo)+"\n\n",
      filter.GetStatusReport(reportSym)
   );
}

void OnTick()  { RunCycle(); }
void OnTimer() { RunCycle(); }
//+------------------------------------------------------------------+
