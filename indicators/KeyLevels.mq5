//+------------------------------------------------------------------+
//|  KeyLevels.mq5                                                   |
//|  昨日 亞/歐/美盤 與全日 高/低/收、上週 高/低/收 關卡              |
//|  與 analysis/levels_study.py 相同定義：                           |
//|    交易日 = MT5 伺服器日；時段以 UTC 劃分 亞 00-07、歐 07-13、美 13-21 |
//|    共振 = 0.3 ATR 內有其他（價位不同的）關卡                       |
//|    觸碰 = 價格進入關卡 ±0.1 ATR，每條關卡每天只提醒一次            |
//|  觸碰時顯示成交量比（本根 tick volume ÷ 前 20 根平均）與           |
//|  RSI(14)/KD(14,3,3)/CCI(20) 是否同向極端，供判斷突破或反轉。       |
//+------------------------------------------------------------------+
#property copyright "mt_ea"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input int    InpAtrPeriod   = 14;     // ATR 週期（用本圖週期）
input double InpTouchAtr    = 0.1;    // 觸碰範圍（ATR 倍數）
input double InpConflAtr    = 0.3;    // 共振範圍（ATR 倍數）
input bool   InpShowSession = true;   // 顯示昨日亞/歐/美盤關卡
input bool   InpShowWeek    = true;   // 顯示上週關卡
input bool   InpAlert       = true;   // 觸碰時跳出提醒
input color  InpHighColor   = clrTomato;
input color  InpLowColor    = clrMediumSeaGreen;
input color  InpCloseColor  = clrSilver;

#define PREFIX "KL_"
#define NLV 15

string g_name[NLV];
double g_price[NLV];
int    g_kind[NLV];          // 0=高 1=低 2=收
bool   g_week[NLV];
datetime g_alerted[NLV];
int    g_atr = INVALID_HANDLE, g_rsi = INVALID_HANDLE, g_sto = INVALID_HANDLE, g_cci = INVALID_HANDLE;
datetime g_levelsDay = 0;

int OnInit()
{
   g_atr = iATR(_Symbol, _Period, InpAtrPeriod);
   g_rsi = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   g_sto = iStochastic(_Symbol, _Period, 14, 3, 3, MODE_SMA, STO_LOWHIGH);
   g_cci = iCCI(_Symbol, _Period, 20, PRICE_TYPICAL);
   if(g_atr == INVALID_HANDLE || g_rsi == INVALID_HANDLE || g_sto == INVALID_HANDLE || g_cci == INVALID_HANDLE)
      return INIT_FAILED;
   ArrayInitialize(g_alerted, 0);
   EventSetTimer(30);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   IndicatorRelease(g_atr); IndicatorRelease(g_rsi); IndicatorRelease(g_sto); IndicatorRelease(g_cci);
}

double Buf(int h, int buf, int shift)
{
   double v[1];
   return (CopyBuffer(h, buf, shift, 1, v) == 1) ? v[0] : EMPTY_VALUE;
}

//--- 伺服器日開始時間
datetime DayStart(datetime t) { return (datetime)((long)t - (long)t % 86400); }

//--- 伺服器時間 → UTC 小時（用目前的伺服器時差）
int UtcHour(datetime serverTime)
{
   long offset = (long)(TimeTradeServer() - TimeGMT());
   offset = (long)MathRound(offset / 3600.0) * 3600;
   MqlDateTime d; TimeToStruct((datetime)((long)serverTime - offset), d);
   return d.hour;
}

//--- 用 M5 K 線計算某伺服器日的全日與各時段 高/低/收；成功回傳 true
bool DayStats(datetime dayStart, double &st[])   // st: [全日H,L,C, 亞H,L,C, 歐H,L,C, 美H,L,C]
{
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M5, dayStart, dayStart + 86400 - 1, r);
   if(n <= 0) return false;
   ArrayResize(st, 12);
   for(int k = 0; k < 12; k++) st[k] = EMPTY_VALUE;
   int sa[3] = {0, 7, 13}, sb[3] = {7, 13, 21};
   for(int i = 0; i < n; i++)
   {
      if(r[i].time < dayStart || r[i].time >= dayStart + 86400) continue;
      int base[2];
      base[0] = 0;
      base[1] = -1;
      int uh = UtcHour(r[i].time);
      for(int s = 0; s < 3; s++) if(uh >= sa[s] && uh < sb[s]) base[1] = 3 + s * 3;
      for(int b = 0; b < 2; b++)
      {
         int o = base[b];
         if(o < 0) continue;
         st[o]     = (st[o]     == EMPTY_VALUE) ? r[i].high : MathMax(st[o], r[i].high);
         st[o + 1] = (st[o + 1] == EMPTY_VALUE) ? r[i].low  : MathMin(st[o + 1], r[i].low);
         st[o + 2] = r[i].close;
      }
   }
   return st[0] != EMPTY_VALUE;
}

void SetLevel(int k, string name, double price, int kind, bool week)
{
   g_name[k] = name; g_price[k] = price; g_kind[k] = kind; g_week[k] = week;
}

//--- 找前一個有資料的交易日並計算 15 條關卡
bool BuildLevels()
{
   datetime today = DayStart(TimeTradeServer());
   double st[];
   datetime d = today - 86400;
   bool ok = false;
   for(int tries = 0; tries < 7 && !ok; tries++, d -= 86400)
      ok = DayStats(d, st);
   if(!ok) return false;
   SetLevel(0, "昨高", st[0], 0, false); SetLevel(1, "昨低", st[1], 1, false); SetLevel(2, "昨收", st[2], 2, false);
   string sn[3] = {"亞", "歐", "美"};
   for(int s = 0; s < 3; s++)
   {
      SetLevel(3 + s * 3, "昨" + sn[s] + "高", st[3 + s * 3], 0, false);
      SetLevel(4 + s * 3, "昨" + sn[s] + "低", st[4 + s * 3], 1, false);
      SetLevel(5 + s * 3, "昨" + sn[s] + "收", st[5 + s * 3], 2, false);
   }
   SetLevel(12, "上週高", iHigh(_Symbol, PERIOD_W1, 1), 0, true);
   SetLevel(13, "上週低", iLow(_Symbol, PERIOD_W1, 1), 1, true);
   SetLevel(14, "上週收", iClose(_Symbol, PERIOD_W1, 1), 2, true);
   g_levelsDay = today;
   ArrayInitialize(g_alerted, 0);
   return true;
}

bool Visible(int k)
{
   if(g_price[k] == EMPTY_VALUE || g_price[k] <= 0) return false;
   if(g_week[k]) return InpShowWeek;
   if(k >= 3) return InpShowSession;
   return true;
}

int Confluence(int k, double atr)
{
   int n = 0;
   for(int j = 0; j < NLV; j++)
   {
      if(j == k || !Visible(j)) continue;
      double d = MathAbs(g_price[j] - g_price[k]);
      if(d > 1e-9 && d <= InpConflAtr * atr) n++;
   }
   return n;
}

void Draw(double atr)
{
   datetime t0 = DayStart(TimeTradeServer());
   datetime t1 = t0 + 86400;
   for(int k = 0; k < NLV; k++)
   {
      string ln = PREFIX + "L" + IntegerToString(k), lb = PREFIX + "T" + IntegerToString(k);
      if(!Visible(k)) { ObjectDelete(0, ln); ObjectDelete(0, lb); continue; }
      color c = g_kind[k] == 0 ? InpHighColor : (g_kind[k] == 1 ? InpLowColor : InpCloseColor);
      int cf = Confluence(k, atr);
      if(ObjectFind(0, ln) < 0) ObjectCreate(0, ln, OBJ_TREND, 0, t0, g_price[k], t1, g_price[k]);
      ObjectSetInteger(0, ln, OBJPROP_TIME, 0, t0);
      ObjectSetInteger(0, ln, OBJPROP_TIME, 1, t1);
      ObjectSetDouble(0, ln, OBJPROP_PRICE, 0, g_price[k]);
      ObjectSetDouble(0, ln, OBJPROP_PRICE, 1, g_price[k]);
      ObjectSetInteger(0, ln, OBJPROP_COLOR, c);
      ObjectSetInteger(0, ln, OBJPROP_WIDTH, (g_week[k] || cf > 0) ? 3 : 1);
      ObjectSetInteger(0, ln, OBJPROP_STYLE, g_kind[k] == 2 ? STYLE_DOT : STYLE_SOLID);
      ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, ln, OBJPROP_BACK, true);
      string txt = g_name[k] + " " + DoubleToString(g_price[k], _Digits) + (cf > 0 ? " ◆共振" : "");
      if(ObjectFind(0, lb) < 0) ObjectCreate(0, lb, OBJ_TEXT, 0, t1, g_price[k]);
      ObjectSetInteger(0, lb, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, lb, OBJPROP_PRICE, 0, g_price[k]);
      ObjectSetString(0, lb, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, lb, OBJPROP_COLOR, c);
      ObjectSetInteger(0, lb, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, lb, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, lb, OBJPROP_SELECTABLE, false);
   }
}

string OscState(int dir)   // dir=+1 碰壓力（看超買）/ -1 碰支撐（看超賣）
{
   double r = Buf(g_rsi, 0, 1), k = Buf(g_sto, MAIN_LINE, 1), c = Buf(g_cci, 0, 1);
   int ob = (r > 70 ? 1 : 0) + (k > 80 ? 1 : 0) + (c > 100 ? 1 : 0);
   int os = (r < 30 ? 1 : 0) + (k < 20 ? 1 : 0) + (c < -100 ? 1 : 0);
   string s = StringFormat("RSI %.0f K %.0f CCI %.0f", r, k, c);
   if(dir > 0 && ob >= 2) return s + "（同向極端：超買）";
   if(dir < 0 && os >= 2) return s + "（同向極端：超賣）";
   return s;
}

double VolRatio()
{
   long v[21];
   if(CopyTickVolume(_Symbol, _Period, 1, 21, v) != 21) return EMPTY_VALUE;
   double avg = 0;
   for(int i = 0; i < 20; i++) avg += (double)v[i];
   avg /= 20.0;
   return avg > 0 ? (double)v[20] / avg : EMPTY_VALUE;     // v[20] = 最近收盤 K 線
}

void Panel(double atr)
{
   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int up = -1, dn = -1;
   for(int k = 0; k < NLV; k++)
   {
      if(!Visible(k)) continue;
      if(g_price[k] > px && (up < 0 || g_price[k] < g_price[up])) up = k;
      if(g_price[k] < px && (dn < 0 || g_price[k] > g_price[dn])) dn = k;
   }
   double vr = VolRatio();
   string s = "【關卡】ATR(" + IntegerToString(InpAtrPeriod) + ") = " + DoubleToString(atr, _Digits) + "\n";
   if(up >= 0) s += StringFormat("上方壓力 %s %s（%.2f ATR）\n", g_name[up], DoubleToString(g_price[up], _Digits), (g_price[up] - px) / atr);
   if(dn >= 0) s += StringFormat("下方支撐 %s %s（%.2f ATR）\n", g_name[dn], DoubleToString(g_price[dn], _Digits), (px - g_price[dn]) / atr);
   s += "成交量比 " + (vr == EMPTY_VALUE ? "—" : DoubleToString(vr, 2));
   Comment(s);
}

void CheckTouch(double atr)
{
   double hi = iHigh(_Symbol, _Period, 0), lo = iLow(_Symbol, _Period, 0), prevC = iClose(_Symbol, _Period, 1);
   for(int k = 0; k < NLV; k++)
   {
      if(!Visible(k) || g_alerted[k] == g_levelsDay) continue;
      double lv = g_price[k], tol = InpTouchAtr * atr;
      if(!(hi >= lv - tol && lo <= lv + tol)) continue;
      int dir;
      if(prevC < lv - tol) dir = 1;          // 由下往上碰 → 壓力
      else if(prevC > lv + tol) dir = -1;    // 由上往下碰 → 支撐
      else continue;
      g_alerted[k] = g_levelsDay;
      double vr = VolRatio();
      string msg = StringFormat("%s 觸碰%s %s %s｜成交量比 %s｜%s｜共振 %d",
                                _Symbol, dir > 0 ? "壓力" : "支撐", g_name[k], DoubleToString(lv, _Digits),
                                vr == EMPTY_VALUE ? "—" : DoubleToString(vr, 2), OscState(dir), Confluence(k, atr));
      Print(msg);
      if(InpAlert) Alert(msg);
   }
}

void Refresh()
{
   datetime today = DayStart(TimeTradeServer());
   if(g_levelsDay != today && !BuildLevels()) return;
   double atr = Buf(g_atr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;
   Draw(atr);
   Panel(atr);
   CheckTouch(atr);
   ChartRedraw(0);
}

void OnTimer() { Refresh(); }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   Refresh();
   return rates_total;
}
//+------------------------------------------------------------------+
