//+------------------------------------------------------------------+
//|  AccountGuard.mq5  —  帳戶守門員（不開倉，只平掉違規的單）          |
//|                                                                  |
//|  不管單是誰下的（手動、AI 工具、任何 EA、Python），只要違反規則，   |
//|  在成交後的下一個事件（通常 1 秒內）立刻平倉或刪除掛單：            |
//|   1. 單筆手數超過上限                → 整張平倉（防一次開 350 手）  |
//|   2. 同商品、同方向、同手數、短時間內重複開單 → 只留第一張（防連開10張）|
//|   3. 同商品持倉張數/總手數超過上限   → 平掉最新的                   |
//|   4. 全帳戶持倉張數超過上限          → 平掉最新的                   |
//|   5. 今日虧損（含浮動）達上限        → 全部平倉，當天再有新單立刻平掉 |
//|   6. 淨值跌破下限                    → 全部平倉並鎖住                |
//|   7. 掛單手數超過上限 / 鎖住期間的掛單 → 刪除                       |
//|                                                                  |
//|  注意：MT5 沒有「下單前攔截」的機制，守門員只能在成交後立刻處理，    |
//|        仍會付出點差/滑價成本，但能避免持倉擴大成大虧損。             |
//|  「演算法交易」按鈕必須開著，守門員才能平倉。要停其他 EA，請把它們   |
//|   從圖表移除，不要用關掉演算法交易的方式（那會連守門員一起停掉）。   |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "帳戶守門員：平掉手數過大、重複開單、超過持倉上限、觸發虧損上限的單（不分手動/EA/AI）"

#include <Trade\Trade.mqh>
#include <Generic\HashMap.mqh>

input group "=== 單筆與重複開單 ==="
input double InpMaxLotPerOrder   = 1.00; // 單筆最大手數（超過整張平倉）
input int    InpDupWindowSec     = 120;  // 重複開單判定時間（秒）：同商品同方向同手數，只留第一張
input group "=== 持倉上限 ==="
input int    InpMaxPosPerSymbol  = 3;    // 同一商品最多幾張
input double InpMaxLotsPerSymbol = 2.00; // 同一商品總手數上限
input int    InpMaxPositions     = 10;   // 全帳戶最多幾張
input group "=== 虧損上限（FTMO）==="
input double InpAccountSize      = 0;    // FTMO 帳戶初始資金（0 = 以今日起始餘額計算百分比）
input double InpDailyLossPct     = 3.0;  // 今日虧損上限 %（FTMO 規定 5%，留緩衝）
input double InpEquityFloor      = 0;    // 淨值下限金額（0 = 不使用）
input int    InpDayResetHour     = 1;    // 每日重置時間（伺服器時間；FTMO 於 CE(S)T 午夜重置 = 伺服器 01:00）
input group "=== 其他 ==="
input bool   InpAlertOnly        = false; // true = 只警告不平倉（測試用）
input bool   InpPush             = true;  // 發送手機推播（需在 MT5 設定 MetaQuotes ID）
input int    InpSlippage         = 50;    // 平倉允許滑點（points）

CTrade   g_trade;
string   g_lockKey;
datetime g_lastAlert = 0;
string   g_status  = "";
CHashMap<string,datetime> g_msgTime;   // 同一訊息 60 秒內不重複印

//--- 今日起點（伺服器時間）
datetime DayStart()
{
   datetime now = TimeTradeServer();
   MqlDateTime t;
   TimeToStruct(now, t);
   t.hour = InpDayResetHour; t.min = 0; t.sec = 0;
   datetime s = StructToTime(t);
   if(now < s) s -= 86400;
   return s;
}

//--- 今日已實現損益（全帳戶，不分 magic）
double TodayClosedPnL()
{
   if(!HistorySelect(DayStart(), TimeTradeServer() + 60)) return 0.0;
   double p = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      long type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      p += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
         + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_FEE);
   }
   return p;
}

void Notify(const string msg)
{
   datetime now = TimeLocal(), last;
   if(g_msgTime.TryGetValue(msg, last) && now - last < 60) return;   // 同一訊息 60 秒內只出現一次
   g_msgTime.TrySetValue(msg, now);

   Print("🛡 ", msg);
   if(now - g_lastAlert >= 10)              // 彈窗/推播最多 10 秒一次
   {
      g_lastAlert = now;
      Alert("AccountGuard: ", msg);
      if(InpPush) SendNotification("AccountGuard: " + msg);
   }
}

bool ClosePos(const ulong ticket, const string why)
{
   if(!PositionSelectByTicket(ticket)) return false;
   string sym = PositionGetString(POSITION_SYMBOL);
   double vol = PositionGetDouble(POSITION_VOLUME);
   if(InpAlertOnly)
   {
      Notify(StringFormat("[只警告] %s #%I64u %.2f 手：%s", sym, ticket, vol, why));
      return false;
   }
   g_trade.SetTypeFillingBySymbol(sym);
   bool ok = g_trade.PositionClose(ticket, InpSlippage) &&
             (g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED);
   Notify(StringFormat("%s %s #%I64u %.2f 手：%s", ok ? "已平倉" : "平倉失敗(下次重試)", sym, ticket, vol, why));
   return ok;
}

bool DeleteOrder(const ulong ticket, const string why)
{
   if(!OrderSelect(ticket)) return false;
   string sym = OrderGetString(ORDER_SYMBOL);
   double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
   if(InpAlertOnly)
   {
      Notify(StringFormat("[只警告] 掛單 %s #%I64u %.2f 手：%s", sym, ticket, vol, why));
      return false;
   }
   bool ok = g_trade.OrderDelete(ticket);
   Notify(StringFormat("%s 掛單 %s #%I64u %.2f 手：%s", ok ? "已刪除" : "刪除失敗", sym, ticket, vol, why));
   return ok;
}

void CloseAll(const string why)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0) ClosePos(t, why);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t > 0) DeleteOrder(t, why);
   }
}

bool IsLocked()
{
   return GlobalVariableCheck(g_lockKey) &&
          (datetime)GlobalVariableGet(g_lockKey) == DayStart();
}

void Lock(const string why)
{
   if(!IsLocked())
   {
      GlobalVariableSet(g_lockKey, (double)DayStart());
      Notify("⛔ 鎖住到下一個交易日：" + why);
   }
}

//--- 持倉快照（依開倉時間由舊到新）
struct SPos { ulong ticket; string sym; long type; double vol; datetime time; };

int Snapshot(SPos &p[])
{
   int n = 0;
   ArrayResize(p, PositionsTotal());
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      p[n].ticket = t;
      p[n].sym    = PositionGetString(POSITION_SYMBOL);
      p[n].type   = PositionGetInteger(POSITION_TYPE);
      p[n].vol    = PositionGetDouble(POSITION_VOLUME);
      p[n].time   = (datetime)(PositionGetInteger(POSITION_TIME_MSC) / 1000);
      n++;
   }
   ArrayResize(p, n);
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
         if(p[b].time < p[a].time || (p[b].time == p[a].time && p[b].ticket < p[a].ticket))
         { SPos x = p[a]; p[a] = p[b]; p[b] = x; }
   return n;
}

void Check()
{
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayBal = bal - TodayClosedPnL();                       // 今日起始餘額
   double base   = (InpAccountSize > 0) ? InpAccountSize : dayBal;
   double limit  = base * InpDailyLossPct / 100.0;
   double dayPnL = equity - dayBal;                              // 今日損益（含浮動）

   g_status = StringFormat("今日損益 %.2f / 上限 -%.2f  淨值 %.2f%s", dayPnL, limit, equity,
                           IsLocked() ? "  ⛔已鎖住" : "");

   //--- 5/6 虧損上限、淨值下限
   if(!IsLocked() && InpDailyLossPct > 0 && dayPnL <= -limit)
      Lock(StringFormat("今日虧損 %.2f 達上限 %.2f", dayPnL, -limit));
   if(!IsLocked() && InpEquityFloor > 0 && equity <= InpEquityFloor)
      Lock(StringFormat("淨值 %.2f 跌破下限 %.2f", equity, InpEquityFloor));
   if(IsLocked())
   {
      if(PositionsTotal() > 0 || OrdersTotal() > 0)
         CloseAll("今日已鎖住，不允許持倉");
      return;
   }

   //--- 7 掛單手數
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetDouble(ORDER_VOLUME_CURRENT) > InpMaxLotPerOrder + 1e-9)
         DeleteOrder(t, StringFormat("掛單手數 > %.2f", InpMaxLotPerOrder));
   }

   SPos p[];
   int n = Snapshot(p);
   bool closed[];
   ArrayResize(closed, n);
   ArrayInitialize(closed, false);

   //--- 1 單筆手數
   for(int i = 0; i < n; i++)
      if(p[i].vol > InpMaxLotPerOrder + 1e-9)
         closed[i] = ClosePos(p[i].ticket, StringFormat("單筆手數 %.2f > 上限 %.2f", p[i].vol, InpMaxLotPerOrder)) || InpAlertOnly;

   //--- 2 重複開單：同商品同方向同手數，在第一張之後 InpDupWindowSec 秒內的都平掉
   for(int i = 0; i < n; i++)
   {
      if(closed[i]) continue;
      for(int j = i + 1; j < n; j++)
      {
         if(closed[j]) continue;
         if(p[j].sym == p[i].sym && p[j].type == p[i].type && MathAbs(p[j].vol - p[i].vol) < 1e-9 &&
            p[j].time - p[i].time <= InpDupWindowSec)
            closed[j] = ClosePos(p[j].ticket, StringFormat("重複開單（%d 秒內同商品同方向同手數）", InpDupWindowSec)) || InpAlertOnly;
      }
   }

   //--- 3 同商品張數/手數：由舊到新累計，超過的平掉
   for(int i = 0; i < n; i++)
   {
      if(closed[i]) continue;
      int cnt = 0; double lots = 0;
      for(int j = 0; j <= i; j++)
         if(!closed[j] && p[j].sym == p[i].sym) { cnt++; lots += p[j].vol; }
      if(cnt > InpMaxPosPerSymbol)
         closed[i] = ClosePos(p[i].ticket, StringFormat("%s 超過 %d 張", p[i].sym, InpMaxPosPerSymbol)) || InpAlertOnly;
      else if(lots > InpMaxLotsPerSymbol + 1e-9)
         closed[i] = ClosePos(p[i].ticket, StringFormat("%s 總手數 %.2f > %.2f", p[i].sym, lots, InpMaxLotsPerSymbol)) || InpAlertOnly;
   }

   //--- 4 全帳戶張數
   int kept = 0;
   for(int i = 0; i < n; i++)
   {
      if(closed[i]) continue;
      kept++;
      if(kept > InpMaxPositions)
         closed[i] = ClosePos(p[i].ticket, StringFormat("全帳戶超過 %d 張", InpMaxPositions)) || InpAlertOnly;
   }
}

int OnInit()
{
   g_lockKey = "GUARD_LOCK_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   EventSetTimer(1);
   PrintFormat("🛡 AccountGuard 啟動：單筆≤%.2f手、同商品≤%d張/%.2f手、全帳戶≤%d張、重複開單%d秒、今日虧損上限%.1f%%%s",
               InpMaxLotPerOrder, InpMaxPosPerSymbol, InpMaxLotsPerSymbol, InpMaxPositions,
               InpDupWindowSec, InpDailyLossPct, InpAlertOnly ? "（只警告模式）" : "");
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      Alert("AccountGuard：「演算法交易」未開啟，守門員無法平倉！");
   Check();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTimer() { Check(); Panel(); }
void OnTick()  { Check(); }

// 有新成交或新掛單時立即檢查（比計時器快）
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_ORDER_ADD)
      Check();
}

void Panel()
{
   Comment(StringFormat("🛡 AccountGuard%s\n單筆≤%.2f手 | 同商品≤%d張/%.2f手 | 全帳戶≤%d張 | 重複%d秒\n%s",
                        InpAlertOnly ? "（只警告）" : "", InpMaxLotPerOrder, InpMaxPosPerSymbol, InpMaxLotsPerSymbol,
                        InpMaxPositions, InpDupWindowSec, g_status));
}
//+------------------------------------------------------------------+
