//+------------------------------------------------------------------+
//|                                                 TrendlineMTF.mq5 |
//|  大週期（H1）自動畫壓力線/支撐線，小週期（M15）指標確認後進場          |
//|  規則與 ml/backtest_tl_mtf.py 完全相同：先回測選組合，再上模擬帳戶     |
//|    bounce 碰線反轉：碰壓力線 + 確認 → 做空；碰支撐線 + 確認 → 做多     |
//|    break  突破：    收盤突破壓力線 + 確認 → 做多（每條線只算第一次）    |
//|    確認：none / RSI 60-40 回落 / K 棒（吞噬、長影線）/ EMA9×21 交叉    |
//|  InpTradeEnabled=false 只顯示訊號；InpAllowReal=false 真實帳戶不下單  |
//|  預設 = 10 年回測最好的組合（H4 線 → H1 突破、順勢、RR3，主要貨幣+金屬 |
//|  PF 1.05，優勢很薄、統計不顯著）→ 建議只當畫線/提醒工具            |
//+------------------------------------------------------------------+
#property copyright "mt_ea"
#property version   "1.00"
#property description "多週期趨勢線：H1 畫線、M15 確認進場（先回測 backtest_tl_mtf.py）"

#include <Trade\Trade.mqh>

enum ENUM_TLM_MODE    { TLM_BOUNCE = 0,  // 碰線反轉
                        TLM_BREAK  = 1,  // 突破
                        TLM_BOTH   = 2 };// 兩種都做
enum ENUM_TLM_TRIGGER { TRG_NONE   = 0,  // 不用指標（只看 K 棒方向）
                        TRG_RSI    = 1,  // RSI
                        TRG_CANDLE = 2,  // K 棒型態
                        TRG_EMA    = 3 };// EMA9 / EMA21

input group "=== 安全 ==="
input bool   InpTradeEnabled = false;   // 允許下單（false = 只顯示訊號）
input bool   InpAllowReal    = false;   // 允許在真實帳戶下單
input long   InpLockAccount  = 0;       // 只在此帳號下單（0 = 不限）
input long   InpMagic        = 26100200;
input group "=== 商品 ==="
input string InpSymbols      = "EURUSD,GBPUSD,USDJPY,USDCHF,USDCAD,AUDUSD,NZDUSD,XAUUSD,XAGUSD"; // 掃描商品（空白 = 只用本圖表商品）
input group "=== 畫線（大週期）==="
input ENUM_TIMEFRAMES InpHTF = PERIOD_H4;
input int    InpPivot        = 5;       // 擺動高低點左右各幾根
input int    InpLineBars     = 400;     // 回看 K 棒數（>= 300）
input double InpZone         = 0.3;     // 碰線容許距離（大週期 ATR 倍數）
input bool   InpDraw         = true;    // 在本圖表畫線
input group "=== 進場（小週期）==="
input ENUM_TIMEFRAMES InpLTF = PERIOD_H1;
input ENUM_TLM_MODE    InpMode    = TLM_BREAK; // 回測：碰線反轉在所有週期都虧
input ENUM_TLM_TRIGGER InpTrigger = TRG_EMA;
input bool   InpTrend        = true;    // 只順大週期 EMA50 方向
input double InpRR           = 3.0;     // 止盈 = 幾倍止損距離
input int    InpMaxHoldBars  = 48;      // 最多持有幾根小週期 K 棒（H1×48 = 2 天）
input group "=== 風控 ==="
input double InpRiskPct      = 0.15;    // 每筆風險（帳戶餘額 %）
input double InpMaxLot       = 1.0;     // 單筆手數上限
input int    InpMaxPositions = 5;       // 同時持倉商品數上限
input group "=== 通知 ==="
input bool   InpPush         = true;    // 出現訊號時推播到手機

//--- 與回測相同的常數
#define BREAK_ATR  0.1
#define TOUCH_BARS 4
#define SL_BARS    6
#define SL_BUF     0.3
#define RSI_HI     60.0
#define RSI_LO     40.0
#define RSI_BULL   55.0
#define RSI_BEAR   45.0
#define TREND_EMA  50

struct SLine { bool ok; int i1, i2; double p1, p2; datetime t1, t2; };

CTrade   g_trade;
bool     g_canTrade = false;
string   g_syms[];
int      g_hRsi[], g_hEf[], g_hEs[], g_hAtr[];
datetime g_lastBar[];
string   g_status[];

double LineValue(const SLine &ln, const int x) { return ln.p2 + (ln.p2 - ln.p1) / (ln.i2 - ln.i1) * (x - ln.i2); }

//+------------------------------------------------------------------+
//| 大週期畫線：用時間 kTime 所在的大週期 K 棒 j，線只用 j 之前已收盤的 K 棒 |
//| 回傳 v 值 = 線在 j 的位置；ah = ATR(j-1)；trend = 收盤 vs EMA50(j-1)  |
//+------------------------------------------------------------------+
bool ComputeLines(const string s, const datetime kTime, const bool strict,
                  SLine &dn, SLine &up, double &vdn, double &vup, double &ah, int &trend, datetime &tj)
{
   dn.ok = false; up.ok = false;
   int n = InpPivot;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int L = CopyRates(s, InpHTF, 0, MathMax(InpLineBars, 300), r);   // 舊 → 新（含未收盤）
   if(L < 4 * n + 30) return false;
   int j = L - 1;
   while(j > 0 && r[j].time > kTime) j--;
   if(strict && !(r[j].time <= kTime && kTime < r[j].time + PeriodSeconds(InpHTF))) return false;
   if(j < 4 * n + 20) return false;
   tj = r[j].time;

   // ATR(14) = TR 的 SMA；EMA50
   double atr[];
   ArrayResize(atr, j);
   double trSum = 0;
   double tr[];
   ArrayResize(tr, j);
   double e = r[0].close, alpha = 2.0 / (TREND_EMA + 1);
   for(int i = 0; i < j; i++)
   {
      tr[i] = (i == 0) ? r[i].high - r[i].low
              : MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      trSum += tr[i];
      if(i >= 14) trSum -= tr[i - 14];
      atr[i] = (i >= 13) ? trSum / 14.0 : 0;
      if(i > 0) e += alpha * (r[i].close - e);
   }
   ah = atr[j - 1];
   trend = (r[j - 1].close > e) ? 1 : -1;
   if(ah <= 0) return false;

   // 擺動點與線：第 i 根收盤時確認 i-n 是否為擺動點；收盤突破 0.1 ATR 作廢
   int ph1 = -1, ph2 = -1, pl1 = -1, pl2 = -1;
   for(int i = 2 * n; i < j; i++)
   {
      int p = i - n;
      bool isH = true, isL = true;
      for(int k = p - n; k <= p + n; k++)
      {
         if(k == p) continue;
         if(r[k].high >= r[p].high) isH = false;
         if(r[k].low  <= r[p].low)  isL = false;
      }
      if(isH)
      {
         ph1 = ph2; ph2 = p;
         if(ph1 >= 0 && r[ph2].high < r[ph1].high)
         { dn.ok = true; dn.i1 = ph1; dn.i2 = ph2; dn.p1 = r[ph1].high; dn.p2 = r[ph2].high; dn.t1 = r[ph1].time; dn.t2 = r[ph2].time; }
      }
      if(isL)
      {
         pl1 = pl2; pl2 = p;
         if(pl1 >= 0 && r[pl2].low > r[pl1].low)
         { up.ok = true; up.i1 = pl1; up.i2 = pl2; up.p1 = r[pl1].low; up.p2 = r[pl2].low; up.t1 = r[pl1].time; up.t2 = r[pl2].time; }
      }
      if(atr[i] > 0)
      {
         if(dn.ok && r[i].close > LineValue(dn, i) + BREAK_ATR * atr[i]) dn.ok = false;
         if(up.ok && r[i].close < LineValue(up, i) - BREAK_ATR * atr[i]) up.ok = false;
      }
   }
   vdn = dn.ok ? LineValue(dn, j) : 0;
   vup = up.ok ? LineValue(up, j) : 0;
   return true;
}

//--- 突破只算第一次：記錄已突破線的第二個擺動點時間（重開 EA 也記得）
string BrokenKey(const string s, const bool isDn) { return StringFormat("TLM_%I64d_%s_%s", InpMagic, s, isDn ? "dn" : "up"); }
bool   IsBroken(const string s, const bool isDn, const datetime t2)
{ return GlobalVariableCheck(BrokenKey(s, isDn)) && (datetime)GlobalVariableGet(BrokenKey(s, isDn)) == t2; }
void   SetBroken(const string s, const bool isDn, const datetime t2) { GlobalVariableSet(BrokenKey(s, isDn), (double)t2); }

//+------------------------------------------------------------------+
//| 確認訊號（與回測 triggered() 相同）；lr[0] = 剛收盤的小週期 K 棒      |
//+------------------------------------------------------------------+
bool Triggered(const MqlRates &lr[], const double &rs[], const double &ef[], const double &es[],
               const bool bounce, const int d)
{
   double o = lr[0].open, h = lr[0].high, l = lr[0].low, c = lr[0].close;
   double o1 = lr[1].open, c1 = lr[1].close;
   if(bounce)
   {
      switch(InpTrigger)
      {
         case TRG_NONE: return d < 0 ? c < o : c > o;
         case TRG_RSI:  return d < 0 ? (rs[1] >= RSI_HI && rs[0] < RSI_HI) : (rs[1] <= RSI_LO && rs[0] > RSI_LO);
         case TRG_EMA:  return d < 0 ? (ef[1] >= es[1] && ef[0] < es[0]) : (ef[1] <= es[1] && ef[0] > es[0]);
         case TRG_CANDLE:
         {
            double body = MathAbs(c - o), rng = h - l;
            if(rng <= 0) return false;
            if(d < 0)
               return (c < o && c1 > o1 && o >= c1 && c <= o1) ||
                      (h - MathMax(o, c) >= 2 * body && c <= l + 0.5 * rng);
            return (c > o && c1 < o1 && o <= c1 && c >= o1) ||
                   (MathMin(o, c) - l >= 2 * body && c >= l + 0.5 * rng);
         }
      }
   }
   else
   {
      switch(InpTrigger)
      {
         case TRG_NONE:   return d > 0 ? c > o : c < o;
         case TRG_RSI:    return d > 0 ? rs[0] >= RSI_BULL : rs[0] <= RSI_BEAR;
         case TRG_EMA:    return d > 0 ? ef[0] > es[0] : ef[0] < es[0];
         case TRG_CANDLE: { double rng = h - l; return rng > 0 && MathAbs(c - o) >= 0.6 * rng && ((c > o) == (d > 0)); }
      }
   }
   return false;
}

string TrigName()
{
   switch(InpTrigger)
   {
      case TRG_NONE:   return "K棒方向";
      case TRG_RSI:    return "RSI";
      case TRG_CANDLE: return "K棒型態";
      case TRG_EMA:    return "EMA9/21";
   }
   return "";
}

//+------------------------------------------------------------------+
//| 持倉工具                                                          |
//+------------------------------------------------------------------+
bool HasPosition(const string s)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == s) return true;
   }
   return false;
}

int SymbolsWithPositions()
{
   string seen = ",";
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      if(StringFind(seen, "," + s + ",") >= 0) continue;
      seen += s + ",";
      n++;
   }
   return n;
}

// 持有超過 InpMaxHoldBars 根小週期 K 棒就平倉（與回測相同）
void CloseExpired()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      int sh = iBarShift(s, InpLTF, (datetime)PositionGetInteger(POSITION_TIME));
      if(sh >= InpMaxHoldBars)
      {
         g_trade.SetTypeFillingBySymbol(s);
         if(g_trade.PositionClose(tk))
            PrintFormat("TrendlineMTF：%s 持有 %d 根 %s 到期平倉", s, sh, EnumToString(InpLTF));
      }
   }
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

double NormPrice(const string s, const double p) { return NormalizeDouble(p, (int)SymbolInfoInteger(s, SYMBOL_DIGITS)); }

void Notify(const string msg)
{
   Print(msg);
   if(InpPush && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED)) SendNotification(msg);
}

//+------------------------------------------------------------------+
//| 每根小週期 K 棒收盤：找訊號（與回測 candidates + run_combo 相同順序）  |
//+------------------------------------------------------------------+
bool Process(const int k)
{
   string s = g_syms[k];
   int digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   MqlRates lr[];
   ArraySetAsSeries(lr, true);
   if(CopyRates(s, InpLTF, 1, SL_BARS, lr) != SL_BARS) return false;
   double rs[], ef[], es[], al[];
   ArraySetAsSeries(rs, true); ArraySetAsSeries(ef, true); ArraySetAsSeries(es, true); ArraySetAsSeries(al, true);
   if(CopyBuffer(g_hRsi[k], 0, 1, 2, rs) != 2 || CopyBuffer(g_hEf[k], 0, 1, 2, ef) != 2 ||
      CopyBuffer(g_hEs[k], 0, 1, 2, es) != 2 || CopyBuffer(g_hAtr[k], 0, 1, 1, al) != 1) return false;

   SLine dn, up; double vdn, vup, ah; int trend; datetime tj;
   if(!ComputeLines(s, lr[0].time, true, dn, up, vdn, vup, ah, trend, tj))
   { g_status[k] = "大週期資料不足"; return true; }

   double c = lr[0].close;
   double hiT = lr[0].high, loT = lr[0].low;
   for(int i = 1; i < TOUCH_BARS; i++) { hiT = MathMax(hiT, lr[i].high); loT = MathMin(loT, lr[i].low); }
   double hiS = lr[0].high, loS = lr[0].low;
   for(int i = 1; i < SL_BARS; i++) { hiS = MathMax(hiS, lr[i].high); loS = MathMin(loS, lr[i].low); }

   // 候選（壓力線先、支撐線後）：kind 0 = 反轉、1 = 突破
   int    cKind[2], cDir[2]; double cV[2]; int nc = 0;
   string near = "";
   if(dn.ok)
   {
      if(c > vdn + BREAK_ATR * ah)
      {
         if(!IsBroken(s, true, dn.t2)) { SetBroken(s, true, dn.t2); cKind[nc] = 1; cDir[nc] = 1; cV[nc] = vdn; nc++; }
      }
      else if(c < vdn && hiT >= vdn - InpZone * ah) { cKind[nc] = 0; cDir[nc] = -1; cV[nc] = vdn; nc++; }
      near += StringFormat("壓 %s(%+.1fATR) ", DoubleToString(vdn, digits), (vdn - c) / ah);
   }
   if(up.ok)
   {
      if(c < vup - BREAK_ATR * ah)
      {
         if(!IsBroken(s, false, up.t2)) { SetBroken(s, false, up.t2); cKind[nc] = 1; cDir[nc] = -1; cV[nc] = vup; nc++; }
      }
      else if(c > vup && loT <= vup + InpZone * ah) { cKind[nc] = 0; cDir[nc] = 1; cV[nc] = vup; nc++; }
      near += StringFormat("撐 %s(%+.1fATR) ", DoubleToString(vup, digits), (c - vup) / ah);
   }
   if(near == "") near = "目前沒有有效趨勢線 ";

   if(HasPosition(s)) { g_status[k] = near + "| 持倉中"; return true; }

   string st = "等待碰線";
   for(int q = 0; q < nc; q++)
   {
      bool bounce = (cKind[q] == 0);
      int d = cDir[q];
      string what = bounce ? (d < 0 ? "碰壓力線" : "碰支撐線") : (d > 0 ? "突破壓力線" : "跌破支撐線");
      if((InpMode == TLM_BOUNCE && !bounce) || (InpMode == TLM_BREAK && bounce)) { st = what + "（非本模式）"; continue; }
      if(InpTrend && trend != d) { st = what + "，逆大週期 EMA50 不做"; continue; }
      if(!Triggered(lr, rs, ef, es, bounce, d)) { st = what + "，等 " + TrigName() + " 確認"; continue; }

      // 止損 / 止盈（與回測 simulate() 相同）
      double a = al[0];
      double sl = (d < 0) ? MathMax(hiS, bounce ? cV[q] : -DBL_MAX) + SL_BUF * a
                          : MathMin(loS, bounce ? cV[q] : DBL_MAX) - SL_BUF * a;
      double entry = (d > 0) ? SymbolInfoDouble(s, SYMBOL_ASK) : SymbolInfoDouble(s, SYMBOL_BID);
      double risk = (d > 0) ? entry - sl : sl - entry;
      if(a <= 0 || risk < 0.3 * a || risk > 10 * a) { st = what + "，止損距離不合理略過"; continue; }
      double tp = (d > 0) ? entry + InpRR * risk : entry - InpRR * risk;
      string msg = StringFormat("TrendlineMTF %s %s %s：%s 價 %s 損 %s 利 %s（RR %.1f）",
                                s, d > 0 ? "做多" : "做空", what, TrigName(),
                                DoubleToString(entry, digits), DoubleToString(sl, digits), DoubleToString(tp, digits), InpRR);
      st = "⚡ " + (d > 0 ? "做多" : "做空") + " " + what + " 損 " + DoubleToString(sl, digits) + " 利 " + DoubleToString(tp, digits);
      if(g_canTrade)
      {
         if(SymbolsWithPositions() >= InpMaxPositions) { st += "（持倉商品數已滿）"; Notify(msg + "，持倉商品數已滿未下單"); break; }
         double lots = SuggestLots(s, risk);
         if(lots <= 0) { st += "（手數太小）"; Notify(msg + "，手數太小未下單"); break; }
         g_trade.SetTypeFillingBySymbol(s);
         string cmt = "TLM " + (bounce ? "bounce" : "break");
         bool ok = (d > 0) ? g_trade.Buy(lots, s, 0, NormPrice(s, sl), NormPrice(s, tp), cmt)
                           : g_trade.Sell(lots, s, 0, NormPrice(s, sl), NormPrice(s, tp), cmt);
         Notify(msg + StringFormat("，%s %.2f 手 %s", ok ? "已下單" : "下單失敗", lots, ok ? "" : g_trade.ResultRetcodeDescription()));
      }
      else
         Notify(msg + "（只顯示訊號）");
      break;
   }
   g_status[k] = near + "| " + st;
   return true;
}

//+------------------------------------------------------------------+
//| 畫線（本圖表商品）                                                |
//+------------------------------------------------------------------+
void DrawLines()
{
   ObjectDelete(0, "TLM_DN"); ObjectDelete(0, "TLM_UP");
   if(!InpDraw) return;
   SLine dn, up; double vdn, vup, ah; int trend; datetime tj;
   if(!ComputeLines(_Symbol, TimeCurrent(), false, dn, up, vdn, vup, ah, trend, tj)) return;
   if(dn.ok)
   {
      ObjectCreate(0, "TLM_DN", OBJ_TREND, 0, dn.t1, dn.p1, tj, vdn);
      ObjectSetInteger(0, "TLM_DN", OBJPROP_COLOR, clrTomato);
      ObjectSetInteger(0, "TLM_DN", OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, "TLM_DN", OBJPROP_WIDTH, 2);
      ObjectSetString(0, "TLM_DN", OBJPROP_TOOLTIP, "TrendlineMTF 壓力線（" + EnumToString(InpHTF) + "）");
   }
   if(up.ok)
   {
      ObjectCreate(0, "TLM_UP", OBJ_TREND, 0, up.t1, up.p1, tj, vup);
      ObjectSetInteger(0, "TLM_UP", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, "TLM_UP", OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, "TLM_UP", OBJPROP_WIDTH, 2);
      ObjectSetString(0, "TLM_UP", OBJPROP_TOOLTIP, "TrendlineMTF 支撐線（" + EnumToString(InpHTF) + "）");
   }
   ChartRedraw();
}

void ShowPanel()
{
   string modeName = (InpMode == TLM_BOUNCE) ? "碰線反轉" : ((InpMode == TLM_BREAK) ? "突破" : "反轉+突破");
   string txt = StringFormat("📐 TrendlineMTF  %s 畫線 → %s 進場｜%s｜確認 %s｜RR %.1f%s｜%s\n",
                             EnumToString(InpHTF), EnumToString(InpLTF), modeName, TrigName(), InpRR,
                             InpTrend ? "｜順勢" : "", g_canTrade ? "⚠️ 下單模式" : "📝 只顯示訊號");
   for(int i = 0; i < ArraySize(g_syms); i++)
      txt += StringFormat("%-11s %s\n", g_syms[i], g_status[i]);
   Comment(txt);
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
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_canTrade = InpTradeEnabled && AccountAllowed();
   if(InpTradeEnabled && !g_canTrade)
      Print("TrendlineMTF：此帳號不允許下單（真實帳戶或非指定帳號），改為只顯示訊號");
   if(PeriodSeconds(InpLTF) >= PeriodSeconds(InpHTF))
   { Print("TrendlineMTF：進場週期必須小於畫線週期"); return INIT_PARAMETERS_INCORRECT; }

   string list[];
   int n = StringSplit(InpSymbols, ',', list);
   ArrayResize(g_syms, 0);
   for(int i = 0; i < n; i++)
   {
      string s = list[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s == "") continue;
      if(!SymbolSelect(s, true)) { PrintFormat("TrendlineMTF：找不到商品 %s，略過", s); continue; }
      int m = ArraySize(g_syms);
      ArrayResize(g_syms, m + 1);
      g_syms[m] = s;
   }
   if(ArraySize(g_syms) == 0) { ArrayResize(g_syms, 1); g_syms[0] = _Symbol; }

   n = ArraySize(g_syms);
   ArrayResize(g_hRsi, n); ArrayResize(g_hEf, n); ArrayResize(g_hEs, n); ArrayResize(g_hAtr, n);
   ArrayResize(g_lastBar, n); ArrayResize(g_status, n);
   for(int i = 0; i < n; i++)
   {
      g_hRsi[i] = iRSI(g_syms[i], InpLTF, 14, PRICE_CLOSE);
      g_hEf[i]  = iMA(g_syms[i], InpLTF, 9, 0, MODE_EMA, PRICE_CLOSE);
      g_hEs[i]  = iMA(g_syms[i], InpLTF, 21, 0, MODE_EMA, PRICE_CLOSE);
      g_hAtr[i] = iATR(g_syms[i], InpLTF, 14);
      g_lastBar[i] = 0;
      g_status[i] = "載入中…";
   }
   PrintFormat("TrendlineMTF：%d 個商品，%s，每筆風險 %.2f%%", n, g_canTrade ? "⚠️ 下單模式" : "📝 只顯示訊號", InpRiskPct);
   EventSetTimer(5);
   ShowPanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_syms); i++)
   {
      IndicatorRelease(g_hRsi[i]); IndicatorRelease(g_hEf[i]);
      IndicatorRelease(g_hEs[i]);  IndicatorRelease(g_hAtr[i]);
   }
   ObjectDelete(0, "TLM_DN"); ObjectDelete(0, "TLM_UP");
   Comment("");
}

void OnTimer()
{
   if(g_canTrade) CloseExpired();
   bool changed = false;
   for(int i = 0; i < ArraySize(g_syms); i++)
   {
      datetime bar = iTime(g_syms[i], InpLTF, 1);
      if(bar == 0 || bar == g_lastBar[i]) continue;
      if(Process(i)) { g_lastBar[i] = bar; changed = true; }    // 資料沒備妥就下次再試
   }
   if(changed) { DrawLines(); ShowPanel(); }
}
//+------------------------------------------------------------------+
