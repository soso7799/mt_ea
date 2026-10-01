//+------------------------------------------------------------------+
//|  TrendScanner.mq5 — 每小時掃描所有商品，找出已形成趨勢者並訂出進出場計畫 |
//|                                                                  |
//|  ★ 只產生計畫，絕不下單（程式裡沒有任何交易函式）                    |
//|                                                                  |
//|  判斷（沿用 MarketRegime.mqh：三線合一/MA34/斜率/MACD + 斐波納契）：  |
//|   1. H1 趨勢分數 >= MinScore（多頭 +3~+4 / 空頭 -3~-4）              |
//|   2. H4 方向一致（確認大週期）                                       |
//|   3. ADX(14) >= MinADX（排除盤整）                                   |
//|  進場計畫：                                                          |
//|   * 已回檔到 38.2~61.8%（黃金區）→ 現價進場                          |
//|   * 回檔 < 38.2%（還沒回）       → 掛限價在 38.2% 位                  |
//|   * 回檔 > 61.8%（太深）         → 觀望，不給計畫                     |
//|  止損/止盈：斐波位 + ATR 緩衝，RR >= MinRR；手數依 RiskPct 換算       |
//|                                                                  |
//|  輸出：圖表面板、專家日誌、手機推播（新出現的計畫）、                 |
//|        CSV：Common\Files\TrendScanner\plans_YYYYMMDD.csv            |
//|                                                                  |
//|  安裝：與 MarketRegime.mqh、SymbolGroups.mqh 放同一資料夾            |
//|        （例如 MQL5\Experts\MultiCurrency\），F7 編譯後掛任一圖表     |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "每小時掃描所有商品的趨勢，產生進出場計畫（不下單）"

#include "MarketRegime.mqh"
#include "SymbolGroups.mqh"
#include <Generic\HashMap.mqh>

enum ENUM_SCAN_SOURCE
{
   SRC_MARKETWATCH = 0, // 只掃「市場報價」視窗裡的商品
   SRC_ALL         = 1  // 掃券商全部商品（較慢）
};

input group "=== 掃描範圍 ==="
input ENUM_SCAN_SOURCE InpSource      = SRC_MARKETWATCH;
input string           InpGroups      = "major,cross,metal,index,energy"; // 要掃的分組（major,cross,exotic,metal,energy,index,agri,crypto）
input int              InpScanMinutes = 60;          // 掃描間隔（分鐘）；另外每根新 H1 K棒也會掃
input group "=== 趨勢條件 ==="
input ENUM_TIMEFRAMES  InpTF          = PERIOD_H1;   // 判定週期
input ENUM_TIMEFRAMES  InpConfirmTF   = PERIOD_H4;   // 確認週期（方向需一致）
input int              InpMinScore    = 3;           // 最低趨勢分數（3 或 4）
input double           InpMinADX      = 20;          // 最低 ADX
input group "=== 計畫 ==="
input double           InpMinRR       = 1.5;         // 最低報酬風險比
input double           InpRiskPct     = 0.5;         // 每筆風險（帳戶餘額 %），用來算建議手數
input double           InpMaxLot      = 1.0;         // 建議手數上限（配合 AccountGuard）
input int              InpTopN        = 10;          // 面板顯示前幾名
input bool             InpPush        = true;        // 新計畫推播到手機
input int              InpRepeatHours = 4;           // 同商品同方向幾小時內不重複推播

struct SPlan
{
   string sym;
   string group;
   int    dir;          // +1 多 / -1 空
   int    score;        // H1 分數
   int    scoreH4;
   double adx;
   string mode;         // 現價 / 限價
   double entry, sl, tp, rr, lots;
   string zone;
   double strength;     // 排序用
};

CMarketRegime        g_h1, g_h4;
CHashMap<string,int> g_adx;          // 商品 → ADX handle
CHashMap<string,datetime> g_pushed;  // 商品|方向 → 上次推播時間
string               g_syms[];
datetime             g_lastScan = 0, g_lastBar = 0;
SPlan                g_plans[];
string               g_panel = "";

//--- 分組過濾
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
   int total = SymbolsTotal(mw);
   for(int i = 0; i < total; i++)
   {
      string s = SymbolName(i, mw);
      if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) continue;
      if(!GroupWanted(GroupCode(SymbolGroup(s)))) continue;
      int n = ArraySize(g_syms);
      ArrayResize(g_syms, n + 1);
      g_syms[n] = s;
      g_h1.Prepare(s);
      g_h4.Prepare(s);
   }
   PrintFormat("TrendScanner：掃描 %d 個商品（%s，分組 %s）", ArraySize(g_syms),
               mw ? "市場報價" : "全部商品", InpGroups);
}

double ADX(const string s)
{
   int h;
   if(!g_adx.TryGetValue(s, h))
   {
      h = iADX(s, InpTF, 14);
      g_adx.Add(s, h);
   }
   if(h == INVALID_HANDLE) return -1;
   double b[1];
   if(CopyBuffer(h, 0, 1, 1, b) != 1) return -1;
   return b[0];
}

// 建議手數：風險金額 / 每手在止損距離的虧損
double SuggestLots(const string s, const double dist)
{
   double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0 || dist <= 0) return 0;
   double lossPerLot = dist / ts * tv;
   double lots = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0 / lossPerLot;
   double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-7) * step;
   if(lots > InpMaxLot) lots = MathFloor(InpMaxLot / step + 1e-7) * step;
   if(lots < mn) lots = 0;     // 連最小手數都超過風險 → 不建議
   return lots;
}

void Scan()
{
   ArrayResize(g_plans, 0);
   int pending = 0;

   for(int i = 0; i < ArraySize(g_syms); i++)
   {
      string s = g_syms[i];
      SRegime r1, r4;
      if(!g_h1.Evaluate(s, r1) || !g_h4.Evaluate(s, r4)) { pending++; continue; }
      if(MathAbs(r1.score) < InpMinScore || r1.regime == 0) continue;
      if(r4.regime != r1.regime) continue;                       // H4 方向不一致
      double adx = ADX(s);
      if(adx < 0) { pending++; continue; }
      if(adx < InpMinADX) continue;

      int dir = r1.regime;
      // 依回檔位置決定進場方式（r1.fibRatio 以「目前波段」計算）
      bool swingWithTrend = (r1.swingDir == dir);
      double price = (dir > 0) ? SymbolInfoDouble(s, SYMBOL_ASK) : SymbolInfoDouble(s, SYMBOL_BID);
      string mode;
      double entry;
      if(!swingWithTrend)        continue;                       // 波段方向與趨勢相反，略過
      if(r1.fibRatio > 0.618)    continue;                       // 回檔太深，觀望
      if(r1.fibRatio >= 0.382)   { mode = "現價"; entry = price; }
      else                       { mode = "限價"; entry = r1.fib[2]; }   // 掛在 38.2% 回檔位

      double sl, tp, rr;
      if(!g_h1.CalcStops(r1, dir, entry, sl, tp, rr)) continue;
      if(rr < InpMinRR) continue;

      int n = ArraySize(g_plans);
      ArrayResize(g_plans, n + 1);
      g_plans[n].sym      = s;
      g_plans[n].group    = GroupName(SymbolGroup(s));
      g_plans[n].dir      = dir;
      g_plans[n].score    = r1.score;
      g_plans[n].scoreH4  = r4.score;
      g_plans[n].adx      = adx;
      g_plans[n].mode     = mode;
      g_plans[n].entry    = entry;
      g_plans[n].sl       = sl;
      g_plans[n].tp       = tp;
      g_plans[n].rr       = rr;
      g_plans[n].lots     = SuggestLots(s, MathAbs(entry - sl));
      g_plans[n].zone     = r1.fibZone;
      g_plans[n].strength = MathAbs(r1.score) + MathAbs(r4.score) + adx / 10.0 + rr;
   }

   //--- 依強度排序
   int n = ArraySize(g_plans);
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
         if(g_plans[b].strength > g_plans[a].strength)
         { SPlan x = g_plans[a]; g_plans[a] = g_plans[b]; g_plans[b] = x; }

   Report(pending);
}

void Report(const int pending)
{
   datetime now = TimeTradeServer();
   int n = ArraySize(g_plans);
   PrintFormat("===== TrendScanner %s  掃描 %d 個商品，趨勢計畫 %d 個%s =====",
               TimeToString(now, TIME_DATE | TIME_MINUTES), ArraySize(g_syms), n,
               pending > 0 ? StringFormat("（%d 個資料未備妥，稍後重掃）", pending) : "");

   //--- CSV（每天一個檔，逐次累加）
   MqlDateTime t; TimeToStruct(now, t);
   FolderCreate("TrendScanner", FILE_COMMON);
   string file = StringFormat("TrendScanner\\plans_%04d%02d%02d.csv", t.year, t.mon, t.day);
   bool exists = FileIsExist(file, FILE_COMMON);
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      if(!exists)
         FileWrite(h, "scan_time", "symbol", "group", "dir", "score_h1", "score_h4", "adx",
                   "mode", "entry", "sl", "tp", "rr", "lots", "fib_zone");
   }

   g_panel = StringFormat("📈 TrendScanner  %s  （只產生計畫，不下單）\n掃描 %d 個 | 趨勢計畫 %d 個 | 每筆風險 %.2f%%\n",
                          TimeToString(now, TIME_DATE | TIME_MINUTES), ArraySize(g_syms), n, InpRiskPct);

   for(int i = 0; i < n; i++)
   {
      SPlan p = g_plans[i];
      int dg = (int)SymbolInfoInteger(p.sym, SYMBOL_DIGITS);
      string side = (p.dir > 0) ? "做多" : "做空";
      string line = StringFormat("%-12s %s %s 進場%.*f 止損%.*f 止盈%.*f RR%.1f 手數%.2f | H1%+d H4%+d ADX%.0f | %s",
                                 p.sym, side, p.mode, dg, p.entry, dg, p.sl, dg, p.tp, p.rr, p.lots,
                                 p.score, p.scoreH4, p.adx, p.zone);
      Print("  ", i + 1, ". ", line);
      if(i < InpTopN) g_panel += IntegerToString(i + 1) + ". " + line + "\n";

      if(h != INVALID_HANDLE)
         FileWrite(h, TimeToString(now, TIME_DATE | TIME_MINUTES), p.sym, p.group, p.dir > 0 ? "BUY" : "SELL",
                   p.score, p.scoreH4, DoubleToString(p.adx, 1), p.mode == "現價" ? "market" : "limit",
                   DoubleToString(p.entry, dg), DoubleToString(p.sl, dg), DoubleToString(p.tp, dg),
                   DoubleToString(p.rr, 2), DoubleToString(p.lots, 2), p.zone);

      //--- 新計畫推播（同商品同方向 InpRepeatHours 小時內不重複）
      if(InpPush && !MQLInfoInteger(MQL_TESTER))
      {
         string key = p.sym + "|" + IntegerToString(p.dir);
         datetime last;
         if(!g_pushed.TryGetValue(key, last) || now - last >= InpRepeatHours * 3600)
         {
            g_pushed.TrySetValue(key, now);
            SendNotification(StringFormat("TrendScanner %s %s %s 進%.*f 損%.*f 利%.*f RR%.1f %.2f手",
                                          p.sym, side, p.mode, dg, p.entry, dg, p.sl, dg, p.tp, p.rr, p.lots));
         }
      }
   }
   if(n == 0) g_panel += "目前沒有符合條件的趨勢商品\n";
   if(h != INVALID_HANDLE) FileClose(h);
   Comment(g_panel);
}

int OnInit()
{
   g_h1.TF = InpTF;
   g_h4.TF = InpConfirmTF;
   g_h1.MinRR = InpMinRR;
   g_h4.MinRR = InpMinRR;
   LoadSymbols();
   EventSetTimer(30);
   Comment("📈 TrendScanner 載入中，指標資料準備好後開始第一次掃描…");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   g_h1.Release();
   g_h4.Release();
   Comment("");
}

void OnTimer()
{
   datetime now = TimeTradeServer();
   datetime bar = iTime(_Symbol, InpTF, 0);
   bool due = (g_lastScan == 0) || (now - g_lastScan >= InpScanMinutes * 60) || (bar != 0 && bar != g_lastBar);
   if(!due) return;

   Scan();
   g_lastBar = bar;
   // 第一次掃描常有商品資料未備妥：2 分鐘後再掃一次，之後照間隔
   g_lastScan = (ArraySize(g_plans) == 0 && g_lastScan == 0) ? now - InpScanMinutes * 60 + 120 : now;
}
//+------------------------------------------------------------------+
