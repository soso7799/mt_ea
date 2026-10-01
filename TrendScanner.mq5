//+------------------------------------------------------------------+
//|  TrendScanner.mq5  v2 — 多指標趨勢掃描 + 進出場計畫 + （可選）執行     |
//|                                                                  |
//|  ★ 預設只產生計畫，不下單（Inp_TradeEnabled=false）                  |
//|    開啟執行前請先在模擬帳戶驗證；Inp_AllowReal=false 時真實帳戶不執行 |
//|                                                                  |
//|  評分（8 票，5 類指標，各商品參數可在 params.csv 個別設定）：         |
//|   趨勢 4 票：均線排列 MA1>MA2>MA3>MA4、價格在 MA4 上/下、MA4 斜率、  |
//|              MACD 主線 vs 訊號線                                      |
//|   動能 1 票：RSI >= 多方門檻 / <= 空方門檻                            |
//|   方向 1 票：DMI +DI vs -DI                                           |
//|   波動 1 票：收盤在布林中軌上/下                                       |
//|   量能 1 票：近 N 根陽線量 vs 陰線量                                   |
//|  條件：H1 分數 >= min_score、H4 同方向且 >= InpConfirmMin、ADX >= adx_min |
//|                                                                  |
//|  進場：已回檔 38.2~61.8% → 現價；未回檔 → 38.2% 掛限價；>61.8% → 觀望 |
//|  止損/止盈：斐波位 + ATR 緩衝，RR >= InpMinRR                         |
//|  手數：每筆風險 InpRiskPct（預設 0.15%）                               |
//|  移動止損：保本 / ATR 追蹤 / 擺動高低點追蹤                           |
//|  加碼：最多 InpMaxUnits 單；最新一單獲利 >= InpAddAtR 倍 R 且趨勢仍成立 |
//|        才加，加碼前先把既有單止損移到保本 → 任何時刻最多一單的風險   |
//|                                                                  |
//|  安裝：與 MarketRegime.mqh、SymbolGroups.mqh 放同一資料夾，F7 編譯    |
//+------------------------------------------------------------------+
#property version   "2.00"
#property description "多指標趨勢掃描、進出場計畫、移動止損與加碼（預設不下單）"

#include "MarketRegime.mqh"
#include "SymbolGroups.mqh"
#include <Generic\HashMap.mqh>
#include <Trade\Trade.mqh>

enum ENUM_SCAN_SOURCE { SRC_MARKETWATCH = 0, /* 市場報價視窗的商品 */ SRC_ALL = 1 /* 券商全部商品 */ };
enum ENUM_TRAIL       { TRAIL_NONE = 0, /* 不移動 */ TRAIL_BE = 1, /* 只移到保本 */
                        TRAIL_ATR = 2, /* 保本後 ATR 追蹤 */ TRAIL_SWING = 3 /* 保本後擺動高低點追蹤 */ };

input group "=== 安全 ==="
input bool   InpTradeEnabled  = false;  // 允許下單（false = 只產生計畫）
input bool   InpAllowReal     = false;  // 允許在真實帳戶下單
input long   InpLockAccount   = 0;      // 只在此帳號下單（0 = 不限）
input long   InpMagic         = 26100100;
input group "=== 掃描範圍 ==="
input ENUM_SCAN_SOURCE InpSource = SRC_MARKETWATCH;
input string InpGroups        = "major,cross,metal,index,energy"; // 分組：major,cross,exotic,metal,energy,index,agri,crypto
input int    InpScanMinutes   = 60;     // 掃描間隔（分鐘），另外每根新 H1 K棒也掃
input ENUM_TIMEFRAMES InpTF        = PERIOD_H1;
input ENUM_TIMEFRAMES InpConfirmTF = PERIOD_H4;
input int    InpConfirmMin    = 4;      // 確認週期最低分數（同方向）
input group "=== 預設指標參數（params.csv 沒列的商品使用）==="
input int    InpMA1 = 5, InpMA2 = 10, InpMA3 = 20, InpMA4 = 34;  // 均線（SMA）
input int    InpMacdFast = 12, InpMacdSlow = 26, InpMacdSig = 9;
input int    InpRsiPeriod = 14;
input double InpRsiBull = 55, InpRsiBear = 45;
input int    InpAdxPeriod = 14;
input double InpAdxMin = 20;
input int    InpBBPeriod = 20;
input int    InpVolBars = 20;
input int    InpMinScore = 6;           // 8 票中至少幾票（同方向）
input group "=== 計畫 / 風控 ==="
input double InpMinRR         = 1.5;    // 最低報酬風險比
input double InpRiskPct       = 0.15;   // 每筆風險（帳戶餘額 %）
input double InpMaxLot        = 1.0;    // 單筆手數上限（配合 AccountGuard）
input int    InpLimitExpiryH  = 4;      // 限價單有效時間（小時）
input int    InpMaxSymbols    = 5;      // 同時持倉的商品數上限
input group "=== 移動止損 / 加碼 ==="
input ENUM_TRAIL InpTrail     = TRAIL_ATR;
input double InpBEAtR         = 1.0;    // 獲利幾 R 移到保本
input double InpTrailATRMult  = 2.0;    // ATR 追蹤倍數
input int    InpSwingBars     = 10;     // 擺動追蹤回看 K 棒數
input int    InpMaxUnits      = 3;      // 同商品最多幾單（含第一單）
input double InpAddAtR        = 1.0;    // 最新一單獲利幾 R 才加碼
input bool   InpExitOnReverse = true;   // 出現反向趨勢計畫時全部平倉
input group "=== 輸出 ==="
input int    InpTopN          = 10;
input bool   InpPush          = true;
input int    InpRepeatHours   = 4;

//--- 各商品參數
struct SParams
{
   int ma1, ma2, ma3, ma4, macdF, macdS, macdSig, rsiP, adxP, bbP, volBars, minScore;
   double rsiBull, rsiBear, adxMin;
};

struct SHandles { int ma1, ma2, ma3, ma4, macd, rsi, adx, bb, atr; };

struct SPlan
{
   string sym;
   int    idx, dir, score, scoreC;
   double adx;
   string mode, zone, votes;
   double entry, sl, tp, rr, lots, strength;
};

string           g_syms[];
SParams          g_par[];
SHandles         g_hm[], g_hc[];        // 主週期 / 確認週期
CMarketRegime    g_fib;                 // 斐波波段與止損止盈
CTrade           g_trade;
CHashMap<string,datetime> g_pushed;
SPlan            g_plans[];
datetime         g_lastScan = 0, g_lastBar = 0;
bool             g_canTrade = false;
string           g_panel = "";

//+------------------------------------------------------------------+
//| 參數檔 Common\Files\TrendScanner\params.csv                       |
//+------------------------------------------------------------------+
void DefaultParams(SParams &p)
{
   p.ma1 = InpMA1; p.ma2 = InpMA2; p.ma3 = InpMA3; p.ma4 = InpMA4;
   p.macdF = InpMacdFast; p.macdS = InpMacdSlow; p.macdSig = InpMacdSig;
   p.rsiP = InpRsiPeriod; p.rsiBull = InpRsiBull; p.rsiBear = InpRsiBear;
   p.adxP = InpAdxPeriod; p.adxMin = InpAdxMin; p.bbP = InpBBPeriod;
   p.volBars = InpVolBars; p.minScore = InpMinScore;
}

#define PARAM_FILE "TrendScanner\\params.csv"

void LoadParams()
{
   for(int i = 0; i < ArraySize(g_syms); i++) DefaultParams(g_par[i]);

   if(!FileIsExist(PARAM_FILE, FILE_COMMON))
   {
      // 產生範本：列出所有掃描商品與目前預設值，方便逐一修改
      FolderCreate("TrendScanner", FILE_COMMON);
      int w = FileOpen(PARAM_FILE, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(w != INVALID_HANDLE)
      {
         FileWrite(w, "symbol", "ma1", "ma2", "ma3", "ma4", "macd_fast", "macd_slow", "macd_signal",
                   "rsi_period", "rsi_bull", "rsi_bear", "adx_period", "adx_min", "bb_period", "vol_bars", "min_score");
         for(int i = 0; i < ArraySize(g_syms); i++)
         {
            SParams p = g_par[i];
            FileWrite(w, g_syms[i], p.ma1, p.ma2, p.ma3, p.ma4, p.macdF, p.macdS, p.macdSig,
                      p.rsiP, p.rsiBull, p.rsiBear, p.adxP, p.adxMin, p.bbP, p.volBars, p.minScore);
         }
         FileClose(w);
         PrintFormat("TrendScanner：已產生參數範本 Common\\Files\\%s，可依商品修改後重新掛上 EA", PARAM_FILE);
      }
      return;
   }

   int h = FileOpen(PARAM_FILE, FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE) return;
   for(int c = 0; c < 16 && !FileIsEnding(h); c++) FileReadString(h);   // 略過標題列
   int loaded = 0;
   while(!FileIsEnding(h))
   {
      string sym = FileReadString(h);
      if(sym == "") { if(FileIsLineEnding(h)) continue; else break; }
      SParams p;
      p.ma1 = (int)FileReadNumber(h); p.ma2 = (int)FileReadNumber(h); p.ma3 = (int)FileReadNumber(h); p.ma4 = (int)FileReadNumber(h);
      p.macdF = (int)FileReadNumber(h); p.macdS = (int)FileReadNumber(h); p.macdSig = (int)FileReadNumber(h);
      p.rsiP = (int)FileReadNumber(h); p.rsiBull = FileReadNumber(h); p.rsiBear = FileReadNumber(h);
      p.adxP = (int)FileReadNumber(h); p.adxMin = FileReadNumber(h); p.bbP = (int)FileReadNumber(h);
      p.volBars = (int)FileReadNumber(h); p.minScore = (int)FileReadNumber(h);
      for(int i = 0; i < ArraySize(g_syms); i++)
         if(g_syms[i] == sym && p.ma1 > 0 && p.ma4 > 0 && p.rsiP > 0 && p.adxP > 0 && p.bbP > 0)
         { g_par[i] = p; loaded++; }
   }
   FileClose(h);
   PrintFormat("TrendScanner：從 params.csv 載入 %d 個商品的個別參數", loaded);
}

//+------------------------------------------------------------------+
//| 指標                                                              |
//+------------------------------------------------------------------+
void MakeHandles(const string s, const ENUM_TIMEFRAMES tf, const SParams &p, SHandles &h)
{
   h.ma1  = iMA(s, tf, p.ma1, 0, MODE_SMA, PRICE_CLOSE);
   h.ma2  = iMA(s, tf, p.ma2, 0, MODE_SMA, PRICE_CLOSE);
   h.ma3  = iMA(s, tf, p.ma3, 0, MODE_SMA, PRICE_CLOSE);
   h.ma4  = iMA(s, tf, p.ma4, 0, MODE_SMA, PRICE_CLOSE);
   h.macd = iMACD(s, tf, p.macdF, p.macdS, p.macdSig, PRICE_CLOSE);
   h.rsi  = iRSI(s, tf, p.rsiP, PRICE_CLOSE);
   h.adx  = iADX(s, tf, p.adxP);
   h.bb   = iBands(s, tf, p.bbP, 0, 2.0, PRICE_CLOSE);
   h.atr  = iATR(s, tf, 14);
}

void FreeHandles(SHandles &h)
{
   int a[9];
   a[0] = h.ma1; a[1] = h.ma2; a[2] = h.ma3; a[3] = h.ma4; a[4] = h.macd;
   a[5] = h.rsi; a[6] = h.adx; a[7] = h.bb;  a[8] = h.atr;
   for(int i = 0; i < 9; i++) if(a[i] != INVALID_HANDLE) IndicatorRelease(a[i]);
}

bool Buf(const int h, const int b, const int shift, double &v)
{
   if(h == INVALID_HANDLE) return false;
   double x[1];
   if(CopyBuffer(h, b, shift, 1, x) != 1 || x[0] == EMPTY_VALUE || !MathIsValidNumber(x[0])) return false;
   v = x[0];
   return true;
}

// 8 票評分；回傳 false = 資料未備妥。votes 為各票明細，例如 "T+T+T+T+M+D+V+Q+"
bool Score(const string s, const ENUM_TIMEFRAMES tf, const SParams &p, const SHandles &h,
           int &score, double &adx, string &votes)
{
   double m1, m2, m3, m4, m4old, mac, sig, rsi, pdi, mdi, mid, atr;
   if(!Buf(h.ma1, 0, 1, m1) || !Buf(h.ma2, 0, 1, m2) || !Buf(h.ma3, 0, 1, m3) || !Buf(h.ma4, 0, 1, m4)) return false;
   if(!Buf(h.ma4, 0, 6, m4old) || !Buf(h.macd, 0, 1, mac) || !Buf(h.macd, 1, 1, sig)) return false;
   if(!Buf(h.rsi, 0, 1, rsi) || !Buf(h.adx, 0, 1, adx) || !Buf(h.adx, 1, 1, pdi) || !Buf(h.adx, 2, 1, mdi)) return false;
   if(!Buf(h.bb, 0, 1, mid) || !Buf(h.atr, 0, 1, atr) || atr <= 0) return false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = MathMax(p.volBars, 2);
   if(CopyRates(s, tf, 1, need, r) != need) return false;
   double c = r[0].close;

   int v[8];
   v[0] = (m1 > m2 && m2 > m3 && m3 > m4) ? 1 : ((m1 < m2 && m2 < m3 && m3 < m4) ? -1 : 0);   // 均線排列
   v[1] = (c > m4) ? 1 : -1;                                                                   // 價在 MA4 上/下
   double slope = (m4 - m4old) / atr;
   v[2] = (slope > 0.1) ? 1 : ((slope < -0.1) ? -1 : 0);                                       // MA4 斜率
   v[3] = (mac > sig) ? 1 : -1;                                                                // MACD
   v[4] = (rsi >= p.rsiBull) ? 1 : ((rsi <= p.rsiBear) ? -1 : 0);                             // RSI 動能
   v[5] = (pdi > mdi) ? 1 : -1;                                                                // DMI
   v[6] = (c > mid) ? 1 : -1;                                                                  // 布林中軌
   double up = 0, dn = 0;
   for(int i = 0; i < need; i++)
   {
      if(r[i].close > r[i].open) up += (double)r[i].tick_volume;
      else if(r[i].close < r[i].open) dn += (double)r[i].tick_volume;
   }
   v[7] = (up > dn) ? 1 : ((up < dn) ? -1 : 0);                                                // 量能

   string tag[8] = {"排", "MA", "斜", "MACD", "RSI", "DMI", "BB", "量"};
   score = 0; votes = "";
   for(int i = 0; i < 8; i++)
   {
      score += v[i];
      votes += tag[i] + (v[i] > 0 ? "+" : (v[i] < 0 ? "-" : "0")) + " ";
   }
   return true;
}

//+------------------------------------------------------------------+
//| 掃描                                                              |
//+------------------------------------------------------------------+
bool GroupWanted(const string code)
{
   string list = "," + InpGroups + ",";
   StringReplace(list, " ", "");
   return StringFind(list, "," + code + ",") >= 0;
}

void LoadSymbols()
{
   ArrayResize(g_syms, 0);
   bool mw = (InpSource == SRC_MARKETWATCH);
   for(int i = 0; i < SymbolsTotal(mw); i++)
   {
      string s = SymbolName(i, mw);
      if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) continue;
      if(!GroupWanted(GroupCode(SymbolGroup(s)))) continue;
      int n = ArraySize(g_syms);
      ArrayResize(g_syms, n + 1);
      g_syms[n] = s;
   }
   int n = ArraySize(g_syms);
   ArrayResize(g_par, n);
   ArrayResize(g_hm, n);
   ArrayResize(g_hc, n);
   LoadParams();
   for(int i = 0; i < n; i++)
   {
      MakeHandles(g_syms[i], InpTF, g_par[i], g_hm[i]);
      MakeHandles(g_syms[i], InpConfirmTF, g_par[i], g_hc[i]);
      g_fib.Prepare(g_syms[i]);
   }
   PrintFormat("TrendScanner：掃描 %d 個商品（%s，分組 %s）", n, mw ? "市場報價" : "全部商品", InpGroups);
}

double SuggestLots(const string s, const double dist)
{
   double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0 || dist <= 0) return 0;
   double lots = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0 / (dist / ts * tv);
   double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   if(step <= 0) step = 0.01;
   lots = MathFloor(MathMin(lots, InpMaxLot) / step + 1e-7) * step;
   return (lots < mn - 1e-9) ? 0 : NormalizeDouble(lots, 2);
}

void Scan()
{
   ArrayResize(g_plans, 0);
   int pending = 0;
   for(int i = 0; i < ArraySize(g_syms); i++)
   {
      string s = g_syms[i];
      SParams p = g_par[i];
      int sc, scC; double adx, adxC; string votes, votesC;
      if(!Score(s, InpTF, p, g_hm[i], sc, adx, votes) || !Score(s, InpConfirmTF, p, g_hc[i], scC, adxC, votesC))
      { pending++; continue; }
      if(MathAbs(sc) < p.minScore || adx < p.adxMin) continue;
      int dir = (sc > 0) ? 1 : -1;
      if(scC * dir < InpConfirmMin) continue;                        // 確認週期同方向且夠強

      SRegime r;
      if(!g_fib.Evaluate(s, r)) { pending++; continue; }
      if(r.swingDir != dir || r.fibRatio > 0.618) continue;          // 波段方向不符或回檔太深

      double price = (dir > 0) ? SymbolInfoDouble(s, SYMBOL_ASK) : SymbolInfoDouble(s, SYMBOL_BID);
      string mode; double entry;
      if(r.fibRatio >= 0.382) { mode = "現價"; entry = price; }
      else                    { mode = "限價"; entry = r.fib[2]; }

      double sl, tp, rr;
      if(!g_fib.CalcStops(r, dir, entry, sl, tp, rr) || rr < InpMinRR) continue;

      int n = ArraySize(g_plans);
      ArrayResize(g_plans, n + 1);
      g_plans[n].sym = s;  g_plans[n].idx = i;  g_plans[n].dir = dir;
      g_plans[n].score = sc; g_plans[n].scoreC = scC; g_plans[n].adx = adx;
      g_plans[n].mode = mode; g_plans[n].zone = r.fibZone; g_plans[n].votes = votes;
      g_plans[n].entry = entry; g_plans[n].sl = sl; g_plans[n].tp = tp; g_plans[n].rr = rr;
      g_plans[n].lots = SuggestLots(s, MathAbs(entry - sl));
      g_plans[n].strength = MathAbs(sc) + MathAbs(scC) / 2.0 + adx / 10.0 + rr;
   }

   int n = ArraySize(g_plans);
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
         if(g_plans[b].strength > g_plans[a].strength)
         { SPlan x = g_plans[a]; g_plans[a] = g_plans[b]; g_plans[b] = x; }

   Report(pending);
   if(g_canTrade) ExecutePlans();
}

void Report(const int pending)
{
   datetime now = TimeTradeServer();
   int n = ArraySize(g_plans);
   PrintFormat("===== TrendScanner %s  掃描 %d 個，趨勢計畫 %d 個%s =====",
               TimeToString(now, TIME_DATE | TIME_MINUTES), ArraySize(g_syms), n,
               pending > 0 ? StringFormat("（%d 個資料未備妥）", pending) : "");

   MqlDateTime t; TimeToStruct(now, t);
   FolderCreate("TrendScanner", FILE_COMMON);
   string file = StringFormat("TrendScanner\\plans_%04d%02d%02d.csv", t.year, t.mon, t.day);
   bool exists = FileIsExist(file, FILE_COMMON);
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      if(!exists)
         FileWrite(h, "scan_time", "symbol", "dir", "score", "score_confirm", "adx", "mode",
                   "entry", "sl", "tp", "rr", "lots", "fib_zone", "votes");
   }

   g_panel = StringFormat("📈 TrendScanner v2  %s  %s\n掃描 %d 個 | 計畫 %d 個 | 每筆風險 %.2f%% | 加碼最多 %d 單\n",
                          TimeToString(now, TIME_DATE | TIME_MINUTES),
                          g_canTrade ? "⚠️ 執行模式" : "📝 只產生計畫",
                          ArraySize(g_syms), n, InpRiskPct, InpMaxUnits);

   for(int i = 0; i < n; i++)
   {
      SPlan p = g_plans[i];
      int dg = (int)SymbolInfoInteger(p.sym, SYMBOL_DIGITS);
      string side = (p.dir > 0) ? "做多" : "做空";
      string line = StringFormat("%-11s %s %s 進%.*f 損%.*f 利%.*f RR%.1f %.2f手 | %+d/%+d ADX%.0f | %s",
                                 p.sym, side, p.mode, dg, p.entry, dg, p.sl, dg, p.tp, p.rr, p.lots,
                                 p.score, p.scoreC, p.adx, p.zone);
      Print("  ", i + 1, ". ", line, " | ", p.votes);
      if(i < InpTopN) g_panel += IntegerToString(i + 1) + ". " + line + "\n";

      if(h != INVALID_HANDLE)
         FileWrite(h, TimeToString(now, TIME_DATE | TIME_MINUTES), p.sym, p.dir > 0 ? "BUY" : "SELL",
                   p.score, p.scoreC, DoubleToString(p.adx, 1), p.mode == "現價" ? "market" : "limit",
                   DoubleToString(p.entry, dg), DoubleToString(p.sl, dg), DoubleToString(p.tp, dg),
                   DoubleToString(p.rr, 2), DoubleToString(p.lots, 2), p.zone, p.votes);

      if(InpPush && !MQLInfoInteger(MQL_TESTER))
      {
         string key = p.sym + "|" + IntegerToString(p.dir);
         datetime last;
         if(!g_pushed.TryGetValue(key, last) || now - last >= InpRepeatHours * 3600)
         {
            g_pushed.TrySetValue(key, now);
            SendNotification(StringFormat("TrendScanner %s %s %s 進%.*f 損%.*f 利%.*f RR%.1f",
                                          p.sym, side, p.mode, dg, p.entry, dg, p.sl, dg, p.tp, p.rr));
         }
      }
   }
   if(n == 0) g_panel += "目前沒有符合條件的趨勢商品\n";
   if(h != INVALID_HANDLE) FileClose(h);
}

//+------------------------------------------------------------------+
//| 執行（只在 g_canTrade 時）                                          |
//+------------------------------------------------------------------+
// 本 EA 在該商品的持倉（依開倉時間排序，舊→新）
int MyPositions(const string s, ulong &tk[])
{
   ArrayResize(tk, 0);
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != s) continue;
      int n = ArraySize(tk);
      ArrayResize(tk, n + 1);
      tk[n] = t;
   }
   int n = ArraySize(tk);
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
      {
         PositionSelectByTicket(tk[a]); long ta = PositionGetInteger(POSITION_TIME_MSC);
         PositionSelectByTicket(tk[b]); long tb = PositionGetInteger(POSITION_TIME_MSC);
         if(tb < ta) { ulong x = tk[a]; tk[a] = tk[b]; tk[b] = x; }
      }
   return n;
}

int MyPendingCount(const string s)
{
   int c = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic && OrderGetString(ORDER_SYMBOL) == s) c++;
   }
   return c;
}

int SymbolsWithPositions()
{
   string seen = ";";
   int c = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      if(StringFind(seen, ";" + s + ";") < 0) { seen += s + ";"; c++; }
   }
   return c;
}

// 初始風險（價格距離）寫在註解裡：「TS u1 r=0.00123」
double InitRisk(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0;
   string c = PositionGetString(POSITION_COMMENT);
   int p = StringFind(c, "r=");
   double r = (p >= 0) ? StringToDouble(StringSubstr(c, p + 2)) : 0;
   if(r > 0) return r;
   // 註解被券商改掉時：止損仍在虧損側就用開倉價到止損的距離
   double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL);
   if(sl <= 0) return 0;
   double d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? open - sl : sl - open;
   return (d > 0) ? d : 0;
}

double ProfitR(const ulong ticket)
{
   double r = InitRisk(ticket);
   if(r <= 0 || !PositionSelectByTicket(ticket)) return 0;
   string s = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double px = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(s, SYMBOL_BID) : SymbolInfoDouble(s, SYMBOL_ASK);
   return ((type == POSITION_TYPE_BUY) ? px - open : open - px) / r;
}

double NormPrice(const string s, const double p)
{
   double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   return (ts > 0) ? NormalizeDouble(MathRound(p / ts) * ts, dg) : NormalizeDouble(p, dg);
}

bool StopTooClose(const string s, const bool isBuy, const double sl)
{
   double d = (double)MathMax(SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(s, SYMBOL_TRADE_FREEZE_LEVEL))
              * SymbolInfoDouble(s, SYMBOL_POINT);
   return isBuy ? (SymbolInfoDouble(s, SYMBOL_BID) - sl <= d) : (sl - SymbolInfoDouble(s, SYMBOL_ASK) <= d);
}

// 只往有利方向移動止損
bool MoveSL(const ulong ticket, double newSL, const string why)
{
   if(!PositionSelectByTicket(ticket)) return false;
   string s = PositionGetString(POSITION_SYMBOL);
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double cur = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
   newSL = NormPrice(s, newSL);
   if(cur > 0 && (isBuy ? newSL <= cur + SymbolInfoDouble(s, SYMBOL_POINT) : newSL >= cur - SymbolInfoDouble(s, SYMBOL_POINT))) return false;
   if(StopTooClose(s, isBuy, newSL)) return false;
   bool ok = g_trade.PositionModify(ticket, newSL, tp) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE;
   if(ok) PrintFormat("📐 %s #%I64u 止損 → %s（%s）", s, ticket, DoubleToString(newSL, (int)SymbolInfoInteger(s, SYMBOL_DIGITS)), why);
   return ok;
}

bool OpenUnit(const SPlan &p, const int unit, const bool market, const double entry, const double sl)
{
   string s = p.sym;
   double lots = SuggestLots(s, MathAbs(entry - sl));
   if(lots <= 0) { PrintFormat("TrendScanner：%s 以 %.2f%% 風險算出手數低於最小手數，略過", s, InpRiskPct); return false; }
   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   string cmt = StringFormat("TS u%d r=%s", unit, DoubleToString(MathAbs(entry - sl), dg));
   g_trade.SetTypeFillingBySymbol(s);
   bool ok;
   if(market)
      ok = (p.dir > 0) ? g_trade.Buy(lots, s, 0, NormPrice(s, sl), NormPrice(s, p.tp), cmt)
                       : g_trade.Sell(lots, s, 0, NormPrice(s, sl), NormPrice(s, p.tp), cmt);
   else
   {
      datetime exp = TimeTradeServer() + InpLimitExpiryH * 3600;
      ok = (p.dir > 0) ? g_trade.BuyLimit(lots, NormPrice(s, entry), s, NormPrice(s, sl), NormPrice(s, p.tp), ORDER_TIME_SPECIFIED, exp, cmt)
                       : g_trade.SellLimit(lots, NormPrice(s, entry), s, NormPrice(s, sl), NormPrice(s, p.tp), ORDER_TIME_SPECIFIED, exp, cmt);
   }
   uint rc = g_trade.ResultRetcode();
   ok = ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
   PrintFormat("%s %s %s 第%d單 %s %.2f手 進%.*f 損%.*f 利%.*f %s", ok ? "✅" : "❌", s, p.dir > 0 ? "做多" : "做空",
               unit, market ? "市價" : "限價", lots, dg, entry, dg, sl, dg, p.tp,
               ok ? "" : g_trade.ResultRetcodeDescription());
   return ok;
}

void ExecutePlans()
{
   for(int i = 0; i < ArraySize(g_plans); i++)
   {
      SPlan p = g_plans[i];
      ulong tk[];
      int units = MyPositions(p.sym, tk);

      //--- 反向：持有方向與新計畫相反 → 全部平倉
      if(units > 0)
      {
         PositionSelectByTicket(tk[0]);
         int held = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(held != p.dir)
         {
            if(InpExitOnReverse)
               for(int k = 0; k < units; k++)
               {
                  g_trade.SetTypeFillingBySymbol(p.sym);
                  g_trade.PositionClose(tk[k]);
                  PrintFormat("🔄 %s 出現反向趨勢計畫，平倉 #%I64u", p.sym, tk[k]);
               }
            continue;
         }
      }

      //--- 第一單
      if(units == 0)
      {
         if(MyPendingCount(p.sym) > 0) continue;
         if(SymbolsWithPositions() >= InpMaxSymbols) continue;
         OpenUnit(p, 1, p.mode == "現價", p.entry, p.sl);
         continue;
      }

      //--- 加碼：最新一單獲利 >= InpAddAtR，且未達上限
      if(units >= InpMaxUnits) continue;
      if(ProfitR(tk[units - 1]) < InpAddAtR) continue;

      // 先把所有既有單移到保本（之後只剩新單有風險）
      bool allBE = true;
      for(int k = 0; k < units; k++)
      {
         PositionSelectByTicket(tk[k]);
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double cur  = PositionGetDouble(POSITION_SL);
         bool isBuy  = (p.dir > 0);
         bool atBE   = cur > 0 && (isBuy ? cur >= open : cur <= open);
         if(!atBE && !MoveSL(tk[k], open, "加碼前移到保本")) allBE = false;
      }
      if(!allBE) continue;

      // 新單：現價進場，止損用目前斐波結構重新計算
      SRegime r;
      if(!g_fib.Evaluate(p.sym, r)) continue;
      double px = (p.dir > 0) ? SymbolInfoDouble(p.sym, SYMBOL_ASK) : SymbolInfoDouble(p.sym, SYMBOL_BID);
      double sl, tp, rr;
      if(!g_fib.CalcStops(r, p.dir, px, sl, tp, rr)) continue;
      OpenUnit(p, units + 1, true, px, sl);
   }
}

int SymIndex(const string s)
{
   for(int i = 0; i < ArraySize(g_syms); i++) if(g_syms[i] == s) return i;
   return -1;
}

//--- 移動止損
void ManageTrailing()
{
   if(InpTrail == TRAIL_NONE) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double r = ProfitR(t);
      if(r < InpBEAtR) continue;

      double target = open;                                     // 至少保本
      if(InpTrail == TRAIL_ATR)
      {
         double atr;
         int k = SymIndex(s);
         if(k >= 0 && Buf(g_hm[k].atr, 0, 1, atr) && atr > 0)
         {
            double px = isBuy ? SymbolInfoDouble(s, SYMBOL_BID) : SymbolInfoDouble(s, SYMBOL_ASK);
            double trail = isBuy ? px - InpTrailATRMult * atr : px + InpTrailATRMult * atr;
            target = isBuy ? MathMax(target, trail) : MathMin(target, trail);
         }
      }
      else if(InpTrail == TRAIL_SWING)
      {
         double hl[];
         int got = isBuy ? CopyLow(s, InpTF, 1, InpSwingBars, hl) : CopyHigh(s, InpTF, 1, InpSwingBars, hl);
         if(got == InpSwingBars)
         {
            double sw = isBuy ? hl[ArrayMinimum(hl)] : hl[ArrayMaximum(hl)];
            target = isBuy ? MathMax(target, sw) : MathMin(target, sw);
         }
      }
      MoveSL(t, target, InpTrail == TRAIL_BE ? "保本" : (InpTrail == TRAIL_ATR ? "ATR 追蹤" : "擺動追蹤"));
   }
}

//+------------------------------------------------------------------+
bool AccountAllowed()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(InpLockAccount != 0 && login != InpLockAccount) return false;
   if(!InpAllowReal && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL) return false;
   return true;
}

int OnInit()
{
   g_fib.TF = InpTF;
   g_fib.MinRR = InpMinRR;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_canTrade = InpTradeEnabled && AccountAllowed();
   if(InpTradeEnabled && !g_canTrade)
      Print("TrendScanner：此帳號不允許下單（真實帳戶或非指定帳號），改為只產生計畫");
   PrintFormat("TrendScanner v2：%s，每筆風險 %.2f%%，移動止損 %s，加碼最多 %d 單",
               g_canTrade ? "⚠️ 執行模式" : "📝 只產生計畫", InpRiskPct, EnumToString(InpTrail), InpMaxUnits);
   LoadSymbols();
   EventSetTimer(5);
   Comment("📈 TrendScanner 載入中，指標資料準備好後開始第一次掃描…");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_syms); i++) { FreeHandles(g_hm[i]); FreeHandles(g_hc[i]); }
   g_fib.Release();
   Comment("");
}

void OnTimer()
{
   if(g_canTrade) ManageTrailing();

   datetime now = TimeTradeServer();
   datetime bar = iTime(_Symbol, InpTF, 0);
   bool due = (g_lastScan == 0) || (now - g_lastScan >= InpScanMinutes * 60) || (bar != 0 && bar != g_lastBar);
   if(due)
   {
      Scan();
      g_lastBar = bar;
      // 第一次常有資料未備妥：沒有計畫時 2 分鐘後再掃一次
      g_lastScan = (ArraySize(g_plans) == 0 && g_lastScan == 0) ? now - InpScanMinutes * 60 + 120 : now;
   }
   Comment(g_panel);
}
//+------------------------------------------------------------------+
