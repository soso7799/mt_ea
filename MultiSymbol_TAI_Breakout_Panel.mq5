//+------------------------------------------------------------------+
//|  MultiSymbol_TAI_Breakout_Panel.mq5                              |
//|  純觀察面板指標，不下單。只需掛在「任一張」圖表上一次，          |
//|  同時顯示監控商品清單裡全部商品的：                              |
//|    1) TAI 動能狀態（比照 TAI_Color_Panel_Optimized.mq5 的邏輯，  |
//|       但改成每個商品各自獨立計算，不依賴附掛圖表的商品）         |
//|    2) 關卡突破狀態（讀 session_levels.csv：亞/歐/美盤高低、      |
//|       前日高低，取代手畫趨勢線——多商品沒辦法手畫，這是替代方案）|
//|    3) 綜合建議：兩者同方向才提示「觀察XX」，否則「雜訊/觀望」    |
//+------------------------------------------------------------------+
#property copyright "Multi-Symbol observation panel — no trading actions"
#property version   "1.10"
#property indicator_chart_window
#property indicator_plots 0

input group "=== 監控商品（留空則跳過該欄）==="
input string Inp_Sym1  = "USDJPY";
input string Inp_Sym2  = "AUDUSD";
input string Inp_Sym3  = "USDCAD";
input string Inp_Sym4  = "GBPUSD";
input string Inp_Sym5  = "EURUSD";
input string Inp_Sym6  = "USDCHF";
input string Inp_Sym7  = "NZDUSD";
input string Inp_Sym8  = "US100.cash";
input string Inp_Sym9  = "US500.cash";
input string Inp_Sym10 = "US30.cash";
input string Inp_Sym11 = "JP225.cash";

input group "=== 關卡資料來源 ==="
// ⚠️ MQL5 FileOpen() 有沙盒限制，不能讀 D:\ 這種磁碟機絕對路徑！
// 只能讀 <終端機資料目錄>\MQL5\Files\ 底下的檔案（Inp_UseCommonFiles=false）
// 或 <終端機資料目錄>\MQL5\Files\Common\ 底下（Inp_UseCommonFiles=true）。
// 你本機產生 session_levels.csv 的 Python/VBA 流程，要改成同時也輸出一份到
// 這個資料夾（用「檔案」→「開啟資料目錄」找到路徑），這裡才讀得到。
// 檔案總管路徑範例（不是這裡填的東西，只是告訴你要把 csv 放哪）：
//   C:\Users\<你>\AppData\Roaming\MetaQuotes\Terminal\<終端機ID>\MQL5\Files\session_levels.csv
input string Inp_LevelsCsvFile   = "session_levels.csv"; // 相對於 MQL5\Files\ 的檔名
input bool   Inp_UseCommonFiles  = false;                 // true=改讀 MQL5\Files\Common\
input ENUM_TIMEFRAMES Inp_TAI_TF = PERIOD_CURRENT; // TAI 用哪個週期算（PERIOD_CURRENT=跟附掛圖表相同）

input group "=== TAI 參數（比照 TAI_Color_Panel_Optimized.mq5 預設）==="
input int    Inp_TaiPeriod     = 5;
input int    Inp_MaPeriod      = 28;
input double Inp_ResponseBoost = 0.35;
input int    Inp_FlPeriod      = 50;
input double Inp_FlLevelUp     = 80.0;
input double Inp_FlLevelDown   = 20.0;
input int    Inp_AtrPeriod     = 14;
input double Inp_AtrMultiplier = 1.0;

input group "=== 面板 ==="
input int    Inp_RefreshSeconds = 15;
input int    Inp_FontSize       = 9;
input string Inp_FontName       = "Microsoft JhengHei";
input int    Inp_PanelX         = 10;
input int    Inp_PanelY         = 30;
input int    Inp_RowHeight      = 18;

#define PANEL_PREFIX "MSTAI_"
#define SYM_COUNT 11

string g_symbols[SYM_COUNT];
int    g_maHandle[SYM_COUNT];
int    g_atrHandle[SYM_COUNT];
bool   g_handleOk[SYM_COUNT];

//+------------------------------------------------------------------+
//| 讀 session_levels.csv 進記憶體（Symbol -> 8個關卡值）             |
//+------------------------------------------------------------------+
struct SessionLevels
{
   bool   found;
   double asianHigh, asianLow;
   double euroHigh,  euroLow;
   double usHigh,    usLow;
   double prevHigh,  prevLow;
};

string g_csvLastError = "";

bool LoadSessionLevels(const string sym, SessionLevels &out)
{
   out.found = false;

   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(Inp_UseCommonFiles)
      flags |= FILE_COMMON;

   int hh = FileOpen(Inp_LevelsCsvFile, flags);
   if(hh == INVALID_HANDLE)
   {
      g_csvLastError = StringFormat("開不到檔案 err=%d（確認檔案在 MQL5\\Files%s\\ 底下）",
                                     GetLastError(), Inp_UseCommonFiles ? "\\Common" : "");
      return false;
   }
   g_csvLastError = "";

   bool first = true;
   while(!FileIsEnding(hh))
   {
      string line = FileReadString(hh);
      if(first) { first = false; continue; } // 跳過表頭
      if(StringLen(line) == 0) continue;

      string parts[];
      int n = StringSplit(line, ',', parts);
      if(n < 10) continue;
      if(parts[0] != sym) continue;

      // Symbol,PrevDate,Asian_High,Asian_Low,European_High,European_Low,US_High,US_Low,PrevDay_High,PrevDay_Low,CurrentPrice
      out.asianHigh = StringToDouble(parts[2]);
      out.asianLow  = StringToDouble(parts[3]);
      out.euroHigh  = StringToDouble(parts[4]);
      out.euroLow   = StringToDouble(parts[5]);
      out.usHigh    = StringToDouble(parts[6]);
      out.usLow     = StringToDouble(parts[7]);
      out.prevHigh  = StringToDouble(parts[8]);
      out.prevLow   = StringToDouble(parts[9]);
      out.found = true;
      break;
   }
   FileClose(hh);
   return out.found;
}

//+------------------------------------------------------------------+
//| 關卡突破狀態                                                      |
//+------------------------------------------------------------------+
string GetLevelStatus(const string sym, color &outColor)
{
   SessionLevels lv;
   outColor = clrSilver;

   if(!LoadSessionLevels(sym, lv))
      return (g_csvLastError != "") ? g_csvLastError : "CSV裡找不到此代碼";

   double price = SymbolInfoDouble(sym, SYMBOL_BID);
   if(price <= 0.0)
      return "無報價";

   // 由近到遠依序比對：前日高低 > 美盤高低 > 歐盤高低 > 亞盤高低
   if(price > lv.prevHigh && lv.prevHigh > 0)
   {
      outColor = clrDeepSkyBlue;
      return StringFormat("突破前日高點(%s)", DoubleToString(lv.prevHigh, _Digits));
   }
   if(price < lv.prevLow && lv.prevLow > 0)
   {
      outColor = clrTomato;
      return StringFormat("跌破前日低點(%s)", DoubleToString(lv.prevLow, _Digits));
   }
   if(price > lv.usHigh && lv.usHigh > 0)
   {
      outColor = clrDeepSkyBlue;
      return "突破美盤高點";
   }
   if(price < lv.usLow && lv.usLow > 0)
   {
      outColor = clrTomato;
      return "跌破美盤低點";
   }
   if(price > lv.euroHigh && lv.euroHigh > 0)
   {
      outColor = clrLimeGreen;
      return "突破歐盤高點";
   }
   if(price < lv.euroLow && lv.euroLow > 0)
   {
      outColor = clrOrange;
      return "跌破歐盤低點";
   }
   if(price > lv.asianHigh && lv.asianHigh > 0)
   {
      outColor = clrLimeGreen;
      return "突破亞盤高點";
   }
   if(price < lv.asianLow && lv.asianLow > 0)
   {
      outColor = clrOrange;
      return "跌破亞盤低點";
   }

   return "區間內(未突破)";
}

//+------------------------------------------------------------------+
//| TAI 動能狀態（單一商品，只算最新狀態，不畫線）                    |
//| handle 是 OnInit() 建好、長期重複使用的，不在這裡重新建立         |
//+------------------------------------------------------------------+
string GetTaiState(const int idx, color &outColor)
{
   outColor = clrSilver;
   string sym = g_symbols[idx];

   if(!g_handleOk[idx])
      return "指標建立失敗";

   ENUM_TIMEFRAMES tf = (Inp_TAI_TF == PERIOD_CURRENT) ? _Period : Inp_TAI_TF;
   int maH  = g_maHandle[idx];
   int atrH = g_atrHandle[idx];

   int need = Inp_TaiPeriod + Inp_FlPeriod + 10;

   int calcMa  = BarsCalculated(maH);
   int calcAtr = BarsCalculated(atrH);
   if(calcMa < need || calcAtr < need)
      return StringFormat("資料載入中(%d/%d)", MathMin(calcMa, calcAtr), need);

   double avg[], atrBuf[], closeArr[];
   ArraySetAsSeries(avg, false);
   ArraySetAsSeries(atrBuf, false);
   ArraySetAsSeries(closeArr, false);

   if(CopyBuffer(maH, 0, 0, need, avg) != need ||
      CopyBuffer(atrH, 0, 0, need, atrBuf) != need ||
      CopyClose(sym, tf, 0, need, closeArr) != need)
      return "資料讀取失敗";

   double fastAvg[]; ArrayResize(fastAvg, need);
   fastAvg[0] = avg[0];
   for(int i = 1; i < need; i++)
      fastAvg[i] = avg[i] + Inp_ResponseBoost * (avg[i] - avg[i-1]);

   double val[]; ArrayResize(val, need);
   ArrayInitialize(val, 0.0);
   for(int i = Inp_TaiPeriod; i < need; i++)
   {
      int rs = i - Inp_TaiPeriod + 1;
      double mx = fastAvg[rs], mn = fastAvg[rs];
      for(int j = rs+1; j <= i; j++) { mx = MathMax(mx, fastAvg[j]); mn = MathMin(mn, fastAvg[j]); }

      double price = closeArr[i];
      double dir = (fastAvg[i] >= fastAvg[i-1]) ? 1.0 : -1.0;
      val[i] = (MathAbs(price) > DBL_EPSILON) ? 100.0*dir*(mx-mn)/MathAbs(price) : 0.0;
   }

   int valc[]; ArrayResize(valc, need);
   ArrayInitialize(valc, 0);
   int startFl = Inp_TaiPeriod + Inp_FlPeriod;
   for(int i = startFl; i < need; i++)
   {
      int fs = i - Inp_FlPeriod + 1;
      double vmin = val[fs], vmax = val[fs];
      for(int j = fs+1; j <= i; j++) { vmin = MathMin(vmin, val[j]); vmax = MathMax(vmax, val[j]); }

      double range = MathMax(vmax - vmin, DBL_EPSILON);
      double atrRatio = (MathAbs(closeArr[i]) > DBL_EPSILON) ? atrBuf[i]/MathAbs(closeArr[i]) : 0.0;
      double volatility = MathMin(0.20, atrRatio * Inp_AtrMultiplier * 10.0);
      double upperPct = MathMin(95.0, Inp_FlLevelUp + volatility*25.0);
      double lowerPct = MathMax(5.0,  Inp_FlLevelDown - volatility*25.0);

      double levelUp = vmin + range*upperPct*0.01;
      double levelDn = vmin + range*lowerPct*0.01;

      bool rising  = (val[i] > val[i-1]);
      bool falling = (val[i] < val[i-1]);

      if(val[i] > levelUp && rising)       valc[i] = 1;
      else if(val[i] < levelDn && falling) valc[i] = 2;
      else                                 valc[i] = 0;
   }

   int stateBar = need - 2; // 比照原指標用已收盤K棒
   int upBars = 0, downBars = 0;
   for(int k = stateBar; k >= MathMax(startFl, stateBar-4); k--)
   {
      if(valc[k] == 1 && downBars == 0) upBars++;
      else if(valc[k] == 2 && upBars == 0) downBars++;
      else break;
   }

   if(upBars >= 2)   { outColor = clrDeepSkyBlue; return "多頭動能延續"; }
   if(downBars >= 2) { outColor = clrTomato;      return "空頭動能延續"; }
   if(upBars == 1)   { outColor = clrLimeGreen;   return "多頭動能啟動"; }
   if(downBars == 1) { outColor = clrOrange;      return "空頭動能啟動"; }
   return "橫盤震盪";
}

//+------------------------------------------------------------------+
//| 綜合結論                                                          |
//+------------------------------------------------------------------+
string Combine(const string taiState, const string levelState, color &outColor)
{
   bool taiBull  = (taiState == "多頭動能延續" || taiState == "多頭動能啟動");
   bool taiBear  = (taiState == "空頭動能延續" || taiState == "空頭動能啟動");
   bool lvlBull  = (StringFind(levelState, "突破") == 0);
   bool lvlBear  = (StringFind(levelState, "跌破") == 0);

   if(taiBull && lvlBull) { outColor = clrLimeGreen; return "多方共振，觀察多單"; }
   if(taiBear && lvlBear) { outColor = clrTomato;     return "空方共振，觀察空單"; }
   outColor = clrGray;
   return "方向不一致，觀望";
}

//+------------------------------------------------------------------+
//| 面板繪製                                                          |
//+------------------------------------------------------------------+
void CreatePanelLabel(const string name, const int x, const int y,
                       const string text, const color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, Inp_FontName);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, Inp_FontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

void DeletePanel()
{
   ObjectsDeleteAll(0, PANEL_PREFIX);
}

void RefreshPanel()
{
   int y = Inp_PanelY;

   CreatePanelLabel(PANEL_PREFIX+"HDR", Inp_PanelX, y,
      StringFormat("== 多商品觀察面板  更新:%s ==", TimeToString(TimeLocal(), TIME_MINUTES|TIME_SECONDS)),
      clrWhite);
   y += Inp_RowHeight;

   CreatePanelLabel(PANEL_PREFIX+"COLHDR", Inp_PanelX, y,
      StringFormat("%-12s %-16s %-22s %s", "Symbol", "TAI動能", "關卡狀態", "綜合結論"),
      clrSilver);
   y += Inp_RowHeight;

   for(int i = 0; i < SYM_COUNT; i++)
   {
      string sym = g_symbols[i];
      if(StringLen(sym) == 0) continue;

      color taiColor, lvlColor, combColor;
      string taiState   = GetTaiState(i, taiColor);
      string levelState = GetLevelStatus(sym, lvlColor);
      string combined   = Combine(taiState, levelState, combColor);

      string line = StringFormat("%-12s %-16s %-22s %s", sym, taiState, levelState, combined);
      CreatePanelLabel(PANEL_PREFIX+"ROW"+IntegerToString(i), Inp_PanelX, y, line, combColor);
      y += Inp_RowHeight;
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbols[0]=Inp_Sym1;  g_symbols[1]=Inp_Sym2;  g_symbols[2]=Inp_Sym3;
   g_symbols[3]=Inp_Sym4;  g_symbols[4]=Inp_Sym5;  g_symbols[5]=Inp_Sym6;
   g_symbols[6]=Inp_Sym7;  g_symbols[7]=Inp_Sym8;  g_symbols[8]=Inp_Sym9;
   g_symbols[9]=Inp_Sym10; g_symbols[10]=Inp_Sym11;

   ENUM_TIMEFRAMES tf = (Inp_TAI_TF == PERIOD_CURRENT) ? _Period : Inp_TAI_TF;

   for(int i = 0; i < SYM_COUNT; i++)
   {
      g_maHandle[i]  = INVALID_HANDLE;
      g_atrHandle[i] = INVALID_HANDLE;
      g_handleOk[i]  = false;

      if(StringLen(g_symbols[i]) == 0)
         continue;

      // 確保商品在市場報價視窗裡（否則MT5可能不會抓歷史資料）
      SymbolSelect(g_symbols[i], true);

      g_maHandle[i]  = iMA(g_symbols[i], tf, Inp_MaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_atrHandle[i] = iATR(g_symbols[i], tf, Inp_AtrPeriod);

      if(g_maHandle[i] == INVALID_HANDLE || g_atrHandle[i] == INVALID_HANDLE)
         PrintFormat("MultiSymbol_TAI_Breakout_Panel: %s 建立handle失敗 err=%d", g_symbols[i], GetLastError());
      else
         g_handleOk[i] = true;
   }

   EventSetTimer(MathMax(5, Inp_RefreshSeconds));
   RefreshPanel();

   IndicatorSetString(INDICATOR_SHORTNAME, "多商品觀察面板");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   for(int i = 0; i < SYM_COUNT; i++)
   {
      if(g_maHandle[i]  != INVALID_HANDLE) IndicatorRelease(g_maHandle[i]);
      if(g_atrHandle[i] != INVALID_HANDLE) IndicatorRelease(g_atrHandle[i]);
   }

   DeletePanel();
   ChartRedraw(0);
}

void OnTimer()
{
   RefreshPanel();
}

int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   return rates_total;
}
//+------------------------------------------------------------------+
