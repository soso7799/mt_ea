//+------------------------------------------------------------------+
//|  EA_Report.mq5  —  帳戶內各 EA 成績統計（腳本，只讀，不交易）     |
//|                                                                  |
//|  放在 MQL5\Scripts\ 編譯後，拖到該帳戶任一圖表執行：              |
//|   * 依 Magic Number 分組統計歷史成交：淨利、交易數、勝率、          |
//|     獲利因子、最大回撤、最近 30/90 天損益、最後交易日、商品、註解   |
//|   * 列出目前各圖表掛著的 EA（名稱/商品/週期）                       |
//|   * 依統計給出初步建議：✅ 可考慮續用 / ⚠️ 觀察 / ❌ 建議停用         |
//|   * 匯出 CSV 到 Common\Files\EA_Report\                            |
//|  本腳本不送出任何交易指令，可安全在真實帳戶執行                     |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.01"

#include <Generic\HashMap.mqh>

input datetime InpFrom      = D'2025.01.01'; // 統計起始日
input int      InpMinTrades = 30;            // 至少幾筆交易才評估
input double   InpGoodPF    = 1.3;           // 獲利因子門檻（>= 才算可續用）

struct SEA
{
   long     magic;
   string   comment;     // 第一筆有內容的開倉註解（常含 EA 名稱）
   string   symbols;     // 以 ; 分隔
   int      trades;      // 平倉筆數
   int      wins;
   double   net;         // 含手續費/庫存費
   double   grossWin;
   double   grossLoss;   // 負值
   double   cum;         // 累計（算回撤用）
   double   peak;
   double   maxDD;
   int      lossStreak;
   int      maxLossStreak;
   double   pnl30;
   double   pnl90;
   datetime first;
   datetime last;
   int      openPos;
   double   floating;
};

SEA               g_ea[];
CHashMap<long,int> g_magicIdx;   // magic → g_ea 索引
CHashMap<long,long> g_posMagic;  // position id → magic（SL/TP 觸發的平倉用開倉時的 magic）

int EAIndex(const long magic)
{
   int idx;
   if(g_magicIdx.TryGetValue(magic, idx)) return idx;
   idx = ArraySize(g_ea);
   ArrayResize(g_ea, idx + 1);
   ZeroMemory(g_ea[idx]);
   g_ea[idx].magic   = magic;
   g_ea[idx].comment = "";
   g_ea[idx].symbols = ";";
   g_magicIdx.Add(magic, idx);
   return idx;
}

void AddSymbol(const int idx, const string sym)
{
   if(StringFind(g_ea[idx].symbols, ";" + sym + ";") < 0)
      g_ea[idx].symbols += sym + ";";
}

string Verdict(const SEA &e)
{
   double pf = (e.grossLoss < 0) ? e.grossWin / -e.grossLoss : (e.grossWin > 0 ? 99.0 : 0.0);
   if(e.trades < InpMinTrades)                 return "⚠️ 交易太少";
   if(e.net <= 0 || pf < 1.0)                  return "❌ 建議停用";
   if(e.pnl90 < 0)                             return "⚠️ 近90天虧損";
   if(pf >= InpGoodPF && e.maxDD < e.net)      return "✅ 可考慮續用";
   return "⚠️ 觀察";
}

void OnStart()
{
   datetime now = TimeCurrent();
   if(!HistorySelect(InpFrom, now + 86400))
   {
      Print("HistorySelect 失敗");
      return;
   }

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;

      long type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;   // 略過入金/出金/信用等

      long     entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      long     posId = HistoryDealGetInteger(t, DEAL_POSITION_ID);
      long     magic = HistoryDealGetInteger(t, DEAL_MAGIC);
      string   sym   = HistoryDealGetString(t, DEAL_SYMBOL);
      string   cmt   = HistoryDealGetString(t, DEAL_COMMENT);
      datetime tm    = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      double   pnl   = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
                     + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_FEE);

      if(entry == DEAL_ENTRY_IN)
      {
         g_posMagic.TrySetValue(posId, magic);
      }
      else
      {
         long m;
         if(g_posMagic.TryGetValue(posId, m)) magic = m;   // 用開倉時的 magic
      }

      int k = EAIndex(magic);
      AddSymbol(k, sym);
      if(g_ea[k].comment == "" && entry == DEAL_ENTRY_IN && cmt != "")
         g_ea[k].comment = cmt;
      if(g_ea[k].first == 0) g_ea[k].first = tm;
      g_ea[k].last = tm;
      g_ea[k].net += pnl;
      if(tm >= now - 30 * 86400) g_ea[k].pnl30 += pnl;
      if(tm >= now - 90 * 86400) g_ea[k].pnl90 += pnl;

      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      {
         g_ea[k].trades++;
         if(pnl > 0) { g_ea[k].wins++; g_ea[k].grossWin += pnl; g_ea[k].lossStreak = 0; }
         else
         {
            g_ea[k].grossLoss += pnl;
            g_ea[k].lossStreak++;
            if(g_ea[k].lossStreak > g_ea[k].maxLossStreak) g_ea[k].maxLossStreak = g_ea[k].lossStreak;
         }
      }

      g_ea[k].cum += pnl;
      if(g_ea[k].cum > g_ea[k].peak) g_ea[k].peak = g_ea[k].cum;
      if(g_ea[k].peak - g_ea[k].cum > g_ea[k].maxDD) g_ea[k].maxDD = g_ea[k].peak - g_ea[k].cum;
   }

   //--- 目前持倉
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      int k = EAIndex(PositionGetInteger(POSITION_MAGIC));
      AddSymbol(k, PositionGetString(POSITION_SYMBOL));
      g_ea[k].openPos++;
      g_ea[k].floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   //--- 依淨利排序（由高到低）
   int n = ArraySize(g_ea);
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
         if(g_ea[b].net > g_ea[a].net)
         {
            SEA tmp = g_ea[a];
            g_ea[a] = g_ea[b];
            g_ea[b] = tmp;
         }

   long   login = AccountInfoInteger(ACCOUNT_LOGIN);
   string mode  = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL) ? "真實" : "模擬/競賽";
   PrintFormat("===== EA 成績報告  帳號 %I64d（%s）%s  %s ~ %s =====",
               login, mode, AccountInfoString(ACCOUNT_SERVER),
               TimeToString(InpFrom, TIME_DATE), TimeToString(now, TIME_DATE));

   //--- CSV
   FolderCreate("EA_Report", FILE_COMMON);
   string file = StringFormat("EA_Report\\EA_Report_%I64d.csv", login);
   int h = FileOpen(file, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h != INVALID_HANDLE)
      FileWrite(h, "magic", "comment", "verdict", "trades", "win_rate", "net", "profit_factor",
                "max_dd", "max_loss_streak", "pnl_30d", "pnl_90d", "first", "last",
                "open_pos", "floating", "symbols");

   for(int i = 0; i < n; i++)
   {
      SEA e = g_ea[i];
      double pf  = (e.grossLoss < 0) ? e.grossWin / -e.grossLoss : (e.grossWin > 0 ? 99.0 : 0.0);
      double wr  = (e.trades > 0) ? 100.0 * e.wins / e.trades : 0.0;
      string sy  = e.symbols;
      StringReplace(sy, ";", " ");
      StringTrimLeft(sy); StringTrimRight(sy);
      string who = (e.magic == 0) ? "手動單" : ("Magic " + IntegerToString(e.magic));
      string v   = Verdict(e);

      PrintFormat("%s %-18s %-20s 筆數%4d 勝率%5.1f%% 淨利%10.2f PF%5.2f 回撤%9.2f 連虧%2d 近30天%9.2f 近90天%9.2f 最後%s 持倉%d(%.2f) [%s]",
                  v, who, e.comment, e.trades, wr, e.net, pf, e.maxDD, e.maxLossStreak,
                  e.pnl30, e.pnl90, TimeToString(e.last, TIME_DATE), e.openPos, e.floating, sy);

      if(h != INVALID_HANDLE)
         FileWrite(h, e.magic, e.comment, v, e.trades, DoubleToString(wr, 1), DoubleToString(e.net, 2),
                   DoubleToString(pf, 2), DoubleToString(e.maxDD, 2), e.maxLossStreak,
                   DoubleToString(e.pnl30, 2), DoubleToString(e.pnl90, 2),
                   TimeToString(e.first, TIME_DATE), TimeToString(e.last, TIME_DATE),
                   e.openPos, DoubleToString(e.floating, 2), sy);
   }

   //--- 目前圖表上的 EA
   Print("----- 目前掛在圖表上的 EA -----");
   int cnt = 0;
   for(long c = ChartFirst(); c >= 0; c = ChartNext(c))
   {
      string ea = ChartGetString(c, CHART_EXPERT_NAME);
      if(StringLen(ea) == 0) continue;   // 沒掛 EA 的圖表會回傳 NULL，不能只比對 ""
      cnt++;
      PrintFormat("  %s  %s %s", ea, ChartSymbol(c), EnumToString(ChartPeriod(c)));
   }
   if(cnt == 0) Print("  （沒有圖表掛 EA）");

   if(h != INVALID_HANDLE)
   {
      FileClose(h);
      PrintFormat("CSV 已輸出：%%APPDATA%%\\MetaQuotes\\Terminal\\Common\\Files\\%s", file);
   }
   Print("判斷規則：筆數 < ", InpMinTrades, " → 交易太少；淨利 <= 0 或 PF < 1 → 建議停用；近90天虧損 → 觀察；",
         "PF >= ", DoubleToString(InpGoodPF, 1), " 且最大回撤 < 淨利 → 可考慮續用；其餘 → 觀察");
}
//+------------------------------------------------------------------+
