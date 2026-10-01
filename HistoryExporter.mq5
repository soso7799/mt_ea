//+------------------------------------------------------------------+
//|  HistoryExporter.mq5 — 從 FTMO（MT5 券商伺服器）匯出歷史 K 棒         |
//|                                                                  |
//|  ★ 只讀資料、不交易。建議掛在 FTMO 模擬帳戶的任一圖表               |
//|  ★ 先到「工具 → 選項 → 圖表 → 圖表最大K棒數」設為 Unlimited（無限）   |
//|                                                                  |
//|  每 InpEveryDays 天（預設 10）自動執行一次：                         |
//|   1. 所有符合分組的商品 × 各週期，只附加新K棒（第一次會補足歷史）    |
//|   2. 輸出 Common\Files\FTMO_Data\<週期>\<商品>.csv                   |
//|      格式 <DATE>,<TIME>,<OPEN>,<HIGH>,<LOW>,<CLOSE>,<TICKVOL>,<SPREAD> |
//|      時間 = FTMO 伺服器時間（與 MT5 圖表相同）                        |
//|   3. 總表 SUMMARY.md / SUMMARY.csv（商品、週期、起訖、筆數、更新時間）|
//|                                                                  |
//|  安裝：與 SymbolGroups.mqh 放同一資料夾，F7 編譯                     |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "FTMO 歷史資料匯出（只讀、不交易），每 10 天自動更新"

#include "SymbolGroups.mqh"

input string InpSymbols     = "";      // 指定商品（逗號分隔，空白 = 依分組自動抓券商全部商品）
input string InpGroups      = "major,cross,exotic,metal,energy,index,agri,crypto"; // 分組
input string InpTFs         = "M1,M3,M5,M10,M12,M15,M30,H1,H4,D1,W1,MN1";        // 週期
input int    InpMinuteYears = 3;       // M1~M30 保留幾年
input int    InpHourYears   = 10;      // H1~MN1 保留幾年（檔案很小，可多抓）
input int    InpEveryDays   = 10;      // 幾天更新一次
input string InpFolder      = "FTMO_Data";
input bool   InpRunNow      = true;    // 掛上時若距上次超過間隔就立刻執行
input int    InpMaxRetry    = 40;      // 歷史資料尚未下載完成時，每個商品最多重試次數

struct SJob   { string sym; int retry; };
struct SStat  { string key; datetime first, last; long rows; string status; datetime updated; };

string            g_tfName[];
ENUM_TIMEFRAMES   g_tf[];
SJob              g_queue[];
int               g_pos = 0;
bool              g_running = false;
datetime          g_lastRun = 0, g_runStart = 0;
SStat             g_stat[];
int               g_done = 0, g_partial = 0;

//+------------------------------------------------------------------+
//| 小工具                                                            |
//+------------------------------------------------------------------+
bool TfFromName(const string n, ENUM_TIMEFRAMES &tf)
{
   string names[] = {"M1","M2","M3","M4","M5","M6","M10","M12","M15","M20","M30","H1","H2","H3","H4","H6","H8","H12","D1","W1","MN1","MN"};
   ENUM_TIMEFRAMES tfs[] = {PERIOD_M1,PERIOD_M2,PERIOD_M3,PERIOD_M4,PERIOD_M5,PERIOD_M6,PERIOD_M10,PERIOD_M12,PERIOD_M15,PERIOD_M20,
                            PERIOD_M30,PERIOD_H1,PERIOD_H2,PERIOD_H3,PERIOD_H4,PERIOD_H6,PERIOD_H8,PERIOD_H12,PERIOD_D1,PERIOD_W1,PERIOD_MN1,PERIOD_MN1};
   for(int i = 0; i < ArraySize(names); i++) if(names[i] == n) { tf = tfs[i]; return true; }
   return false;
}

bool IsMinuteTF(const ENUM_TIMEFRAMES tf) { return PeriodSeconds(tf) < 3600; }

string SafeName(string s)
{
   string bad[] = {"/","\\",":","*","?","\"","<",">","|"};
   for(int i = 0; i < ArraySize(bad); i++) StringReplace(s, bad[i], "_");
   return s;
}

string FilePath(const string sym, const int k) { return InpFolder + "\\" + g_tfName[k] + "\\" + SafeName(sym) + ".csv"; }

string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }

datetime ParseLineTime(const string ln)
{
   string c[];
   if(StringSplit(ln, ',', c) < 2 || StringGetCharacter(ln, 0) == '<') return 0;
   return StringToTime(c[0] + " " + c[1]);
}

// 讀檔案第一根與最後一根K棒時間
bool FileRange(const string file, datetime &first, datetime &last)
{
   first = 0; last = 0;
   if(!FileIsExist(file, FILE_COMMON)) return false;
   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return false;
   while(!FileIsEnding(h) && first == 0) first = ParseLineTime(FileReadString(h));
   ulong size = FileSize(h);
   if(size > 400) FileSeek(h, (long)size - 400, SEEK_SET);
   string ln, lastLn = "";
   while(!FileIsEnding(h)) { ln = FileReadString(h); if(StringLen(ln) > 10) lastLn = ln; }
   FileClose(h);
   last = ParseLineTime(lastLn);
   return first > 0 && last > 0;
}

long CountRows(const string file)
{
   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return 0;
   long n = 0;
   while(!FileIsEnding(h)) { string ln = FileReadString(h); if(StringLen(ln) > 10 && StringGetCharacter(ln, 0) != '<') n++; }
   FileClose(h);
   return n;
}

//+------------------------------------------------------------------+
//| 統計（state.csv 保存，避免每次重數整個檔案）                         |
//+------------------------------------------------------------------+
int StatIndex(const string key, const bool create)
{
   for(int i = 0; i < ArraySize(g_stat); i++) if(g_stat[i].key == key) return i;
   if(!create) return -1;
   int n = ArraySize(g_stat);
   ArrayResize(g_stat, n + 1);
   g_stat[n].key = key; g_stat[n].first = 0; g_stat[n].last = 0; g_stat[n].rows = 0; g_stat[n].status = ""; g_stat[n].updated = 0;
   return n;
}

void LoadState()
{
   ArrayResize(g_stat, 0);
   string f = InpFolder + "\\state.csv";
   int h = FileOpen(f, FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE) return;
   while(!FileIsEnding(h))
   {
      string key = FileReadString(h);
      if(key == "") continue;
      if(key == "last_run") { g_lastRun = (datetime)StringToInteger(FileReadString(h)); continue; }
      int i = StatIndex(key, true);
      g_stat[i].first   = (datetime)StringToInteger(FileReadString(h));
      g_stat[i].last    = (datetime)StringToInteger(FileReadString(h));
      g_stat[i].rows    = StringToInteger(FileReadString(h));
      g_stat[i].status  = FileReadString(h);
      g_stat[i].updated = (datetime)StringToInteger(FileReadString(h));
   }
   FileClose(h);
}

void SaveState()
{
   int h = FileOpen(InpFolder + "\\state.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "last_run", (long)g_lastRun);
   for(int i = 0; i < ArraySize(g_stat); i++)
      FileWrite(h, g_stat[i].key, (long)g_stat[i].first, (long)g_stat[i].last, g_stat[i].rows, g_stat[i].status, (long)g_stat[i].updated);
   FileClose(h);
}

//+------------------------------------------------------------------+
//| 匯出一個商品的一個週期：1 = 完成，0 = 歷史資料還在下載，-1 = 錯誤     |
//+------------------------------------------------------------------+
int ExportTF(const string sym, const int k, const bool lastTry)
{
   ENUM_TIMEFRAMES tf = g_tf[k];
   string file = FilePath(sym, k);
   datetime now = TimeCurrent();
   datetime want = now - (datetime)((IsMinuteTF(tf) ? InpMinuteYears : InpHourYears) * 365 * 86400);

   // 伺服器有、終端機還沒下載的歷史 → 觸發下載，稍後重試
   datetime srvFirst  = (datetime)SeriesInfoInteger(sym, tf, SERIES_SERVER_FIRSTDATE);
   datetime termFirst = (datetime)SeriesInfoInteger(sym, tf, SERIES_TERMINAL_FIRSTDATE);
   datetime need = (srvFirst > want) ? srvFirst : want;
   if(!lastTry && (termFirst == 0 || termFirst > need + 3 * 86400))
   {
      datetime tmp[];
      CopyTime(sym, tf, need, now, tmp);
      return 0;
   }

   datetime fFirst, fLast;
   bool has = FileRange(file, fFirst, fLast);
   // 檔案起點比應有的晚，而且現在終端機已有更早的資料 → 重建（只往後附加，不裁掉舊資料，雲端同步比較省）
   bool rebuild = !has || (fFirst > need + 7 * 86400 && termFirst > 0 && termFirst < fFirst - 7 * 86400);
   datetime from = rebuild ? need : fLast + 1;
   if(from >= now) return 1;

   MqlRates r[];
   ResetLastError();
   int n = CopyRates(sym, tf, from, now, r);
   if(n < 0)
   {
      int err = GetLastError();
      if(!lastTry && err == ERR_HISTORY_NOT_FOUND) return 0;               // 還在下載
      if(!has) PrintFormat("HistoryExporter：%s %s 沒有資料（錯誤 %d）", sym, g_tfName[k], err);
      n = 0;
   }
   if(rebuild && has && n <= 0) return 1;                                  // 拿不到資料時不要清掉舊檔

   int si = StatIndex(sym + "|" + g_tfName[k], true);
   if(!rebuild && g_stat[si].rows == 0) { g_stat[si].rows = CountRows(file); g_stat[si].first = fFirst; }

   int h;
   if(rebuild)
   {
      h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h == INVALID_HANDLE) return -1;
      FileWriteString(h, "<DATE>,<TIME>,<OPEN>,<HIGH>,<LOW>,<CLOSE>,<TICKVOL>,<SPREAD>\r\n");
      g_stat[si].rows = 0; g_stat[si].first = 0;
   }
   else
   {
      h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h == INVALID_HANDLE) return -1;
      FileSeek(h, 0, SEEK_END);
   }

   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   int ps = PeriodSeconds(tf);
   datetime lastWritten = rebuild ? 0 : fLast;
   string buf = "";
   int cnt = 0;
   for(int i = 0; i < n; i++)
   {
      if(r[i].time <= lastWritten) continue;
      if(r[i].time + ps > now) continue;                     // 尚未收完的K棒
      buf += TimeToString(r[i].time, TIME_DATE) + "," + TimeToString(r[i].time, TIME_MINUTES) + "," +
             DoubleToString(r[i].open, dg) + "," + DoubleToString(r[i].high, dg) + "," +
             DoubleToString(r[i].low, dg) + "," + DoubleToString(r[i].close, dg) + "," +
             IntegerToString(r[i].tick_volume) + "," + IntegerToString(r[i].spread) + "\r\n";
      lastWritten = r[i].time;
      if(g_stat[si].first == 0) g_stat[si].first = r[i].time;
      cnt++;
      if(cnt % 2000 == 0) { FileWriteString(h, buf); buf = ""; }
   }
   if(buf != "") FileWriteString(h, buf);
   FileClose(h);
   g_stat[si].rows += cnt;

   if(lastWritten > 0) g_stat[si].last = lastWritten;
   g_stat[si].updated = now;
   g_stat[si].status = (termFirst == 0 || termFirst > need + 3 * 86400) ? "partial" : "ok";
   return 1;
}

//+------------------------------------------------------------------+
//| 排程 / 佇列                                                        |
//+------------------------------------------------------------------+
void BuildQueue()
{
   ArrayResize(g_queue, 0);
   string list[];
   int n = 0;
   if(Trim(InpSymbols) != "")
   {
      string p[];
      int m = StringSplit(InpSymbols, ',', p);
      for(int i = 0; i < m; i++) { string s = Trim(p[i]); if(s != "") { ArrayResize(list, n + 1); list[n++] = s; } }
   }
   else
   {
      string groups = "," + InpGroups + ",";
      StringReplace(groups, " ", "");
      for(int i = 0; i < SymbolsTotal(false); i++)
      {
         string s = SymbolName(i, false);
         if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) continue;
         if(StringFind(groups, "," + GroupCode(SymbolGroup(s)) + ",") < 0) continue;
         ArrayResize(list, n + 1); list[n++] = s;
      }
   }
   ArrayResize(g_queue, n);
   for(int i = 0; i < n; i++) { g_queue[i].sym = list[i]; g_queue[i].retry = 0; SymbolSelect(list[i], true); }
   g_pos = 0; g_done = 0; g_partial = 0;
}

void StartRun()
{
   BuildQueue();
   for(int k = 0; k < ArraySize(g_tfName); k++) FolderCreate(InpFolder + "\\" + g_tfName[k], FILE_COMMON);
   g_running = true;
   g_runStart = TimeCurrent();
   PrintFormat("HistoryExporter：開始匯出 %d 個商品 × %d 個週期", ArraySize(g_queue), ArraySize(g_tf));
}

void ProcessOne()
{
   if(g_pos >= ArraySize(g_queue)) { FinishRun(); return; }
   SJob job = g_queue[g_pos];
   bool lastTry = job.retry >= InpMaxRetry;
   bool notReady = false;
   for(int k = 0; k < ArraySize(g_tf); k++)
   {
      int r = ExportTF(job.sym, k, lastTry);
      if(r == 0) notReady = true;
   }
   if(notReady && !lastTry)
   {
      // 放到佇列最後，等終端機下載歷史
      g_queue[g_pos].retry++;
      int n = ArraySize(g_queue);
      ArrayResize(g_queue, n + 1);
      g_queue[n] = g_queue[g_pos];
   }
   else
   {
      g_done++;
      if(notReady) g_partial++;
   }
   g_pos++;
   SaveState();
}

void FinishRun()
{
   g_running = false;
   g_lastRun = TimeCurrent();
   SaveState();
   WriteSummary();
   PrintFormat("HistoryExporter：完成 %d 個商品（%d 個資料不完整），耗時 %d 分。下次 %s",
               g_done, g_partial, (int)((TimeCurrent() - g_runStart) / 60),
               TimeToString(g_lastRun + InpEveryDays * 86400, TIME_DATE | TIME_MINUTES));
}

//+------------------------------------------------------------------+
//| 總表                                                              |
//+------------------------------------------------------------------+
string T(const datetime t) { return t > 0 ? TimeToString(t, TIME_DATE | TIME_MINUTES) : ""; }

void WriteSummary()
{
   // 長表：每商品每週期一列
   int h = FileOpen(InpFolder + "\\SUMMARY.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h != INVALID_HANDLE)
   {
      FileWrite(h, "symbol", "group", "timeframe", "first_bar", "last_bar", "rows", "status", "updated");
      for(int i = 0; i < ArraySize(g_stat); i++)
      {
         string p[];
         if(StringSplit(g_stat[i].key, '|', p) != 2) continue;
         FileWrite(h, p[0], GroupCode(SymbolGroup(p[0])), p[1], T(g_stat[i].first), T(g_stat[i].last),
                   g_stat[i].rows, g_stat[i].status, T(g_stat[i].updated));
      }
      FileClose(h);
   }

   // Markdown：每商品一列，每個週期一欄（筆數），加起訖與更新時間
   h = FileOpen(InpFolder + "\\SUMMARY.md", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   if(h == INVALID_HANDLE) return;
   long acc = AccountInfoInteger(ACCOUNT_LOGIN);
   FileWriteString(h, "# FTMO 歷史資料總表\n\n");
   FileWriteString(h, StringFormat("- 來源：%s（帳號 %I64d）\n- 最後更新：**%s**（伺服器時間），每 %d 天更新\n- M1~M30 保留 %d 年，H1~MN1 保留 %d 年；時間皆為 FTMO 伺服器時間\n\n",
                                   AccountInfoString(ACCOUNT_SERVER), acc, T(g_lastRun), InpEveryDays, InpMinuteYears, InpHourYears));
   string head = "| 商品 | 分組 | 起 (M1) | 至 | ";
   string sep  = "|---|---|---|---|";
   for(int k = 0; k < ArraySize(g_tfName); k++) { head += g_tfName[k] + " | "; sep += "--:|"; }
   FileWriteString(h, head + "狀態 |\n" + sep + "---|\n");

   string done = ";";
   for(int i = 0; i < ArraySize(g_stat); i++)
   {
      string p[];
      if(StringSplit(g_stat[i].key, '|', p) != 2 || StringFind(done, ";" + p[0] + ";") >= 0) continue;
      done += p[0] + ";";
      string row = "| " + p[0] + " | " + GroupCode(SymbolGroup(p[0])) + " | ";
      datetime first = 0, last = 0;
      string cells = "", status = "✅";
      for(int k = 0; k < ArraySize(g_tfName); k++)
      {
         int j = StatIndex(p[0] + "|" + g_tfName[k], false);
         if(j < 0) { cells += " | "; continue; }
         cells += IntegerToString(g_stat[j].rows) + " | ";
         if(k == 0) first = g_stat[j].first;
         if(g_stat[j].last > last) last = g_stat[j].last;
         if(g_stat[j].status == "partial") status = "⏳ 不完整";
         if(g_stat[j].status == "error") status = "❌";
      }
      FileWriteString(h, row + T(first) + " | " + T(last) + " | " + cells + status + " |\n");
   }
   FileClose(h);
}

//+------------------------------------------------------------------+
int OnInit()
{
   string p[];
   int m = StringSplit(InpTFs, ',', p);
   ArrayResize(g_tf, 0); ArrayResize(g_tfName, 0);
   for(int i = 0; i < m; i++)
   {
      string n = Trim(p[i]);
      ENUM_TIMEFRAMES tf;
      if(!TfFromName(n, tf)) { PrintFormat("HistoryExporter：未知週期 %s，略過", n); continue; }
      int k = ArraySize(g_tf);
      ArrayResize(g_tf, k + 1); ArrayResize(g_tfName, k + 1);
      g_tf[k] = tf; g_tfName[k] = (n == "MN") ? "MN1" : n;
   }
   FolderCreate(InpFolder, FILE_COMMON);
   LoadState();

   int maxBars = TerminalInfoInteger(TERMINAL_MAXBARS);
   if(maxBars < 2000000)
      PrintFormat("⚠️ HistoryExporter：「圖表最大K棒數」= %d，M1 %d 年約需 %d 根。請到 工具→選項→圖表 設為 Unlimited 後重啟 MT5",
                  maxBars, InpMinuteYears, InpMinuteYears * 380000);

   PrintFormat("HistoryExporter：週期 %s；上次執行 %s；每 %d 天更新", InpTFs, T(g_lastRun), InpEveryDays);
   EventSetTimer(2);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); SaveState(); Comment(""); }

void OnTimer()
{
   if(!g_running)
   {
      bool due = (g_lastRun == 0) || (TimeCurrent() - g_lastRun >= InpEveryDays * 86400);
      if(due && (InpRunNow || g_lastRun > 0)) StartRun();
      Comment(StringFormat("📦 HistoryExporter  上次 %s  下次 %s", T(g_lastRun),
                           g_lastRun > 0 ? T(g_lastRun + InpEveryDays * 86400) : "掛上後立即"));
      return;
   }
   ProcessOne();
   int total = ArraySize(g_queue);
   Comment(StringFormat("📦 HistoryExporter 匯出中 %d / %d（完成 %d 個商品）\n%s",
                        MathMin(g_pos, total), total, g_done,
                        g_pos < total ? "下一個：" + g_queue[g_pos].sym : ""));
}
//+------------------------------------------------------------------+
