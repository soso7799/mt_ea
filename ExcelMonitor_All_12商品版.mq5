//+------------------------------------------------------------------+
//| ExcelMonitor_All_12商品版.mq5  (整合版：CSV輸出 + 圖表視覺化 二合一) |
//|                                                                    |
//| 功能：                                                            |
//|  A. 背景幫12大商品寫 Excel_Monitor.csv 給 Excel 巨集讀取           |
//|  B. 在掛載的這張圖表上畫：Vegas雙通道、支撐壓力、成交量、進場箭頭    |
//|                                                                    |
//| 使用方式：只需要掛在「一張」圖表上，A功能就會自動跑全部12個商品      |
//|                                                                    |
//| 修正紀錄：                                                        |
//|  - PeriodToTFString() 新增支援 PERIOD_M5 → "M5"，讓 M5 也能跟      |
//|    D1/H4/H1/M15 一樣，從 VegasFilterParams.csv / VegasDualPath     |
//|    Params.csv 自動套用回測出來的最佳化參數(以前M5會被跳過，只能     |
//|    用經典預設值144/169/34/55/100)。                                |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property indicator_chart_window

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#property indicator_buffers 5
#property indicator_plots   3
#property indicator_label1  "長隧道(144/169)"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  clrDeepSkyBlue
#property indicator_label2  "短隧道(34/55)"
#property indicator_type2   DRAW_FILLING
#property indicator_color2  clrOrange
#property indicator_label3  "過濾線(HullMA)"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrYellow
#property indicator_width3  2
#property indicator_style3  STYLE_DASH

//================== 可調參數 ==================
input string ShortMAPeriods  = "9,9,9,9,9,9,9,9,9,9,9,9";      // 短MA週期(給後台趨勢判斷邏輯用，跟圖表視覺化無關)
input string LongMAPeriods   = "21,21,21,21,21,21,21,21,21,21,21,21"; // 長MA/EMA週期，同上
input string VegasLongTunnelA   = "144,144,144,144,144,144,144,144,144,144,144,144"; // 長隧道A週期(每商品一個，建議用VegasFilterParams.csv回測結果手動填入)
input string VegasLongTunnelB   = "169,169,169,169,169,169,169,169,169,169,169,169"; // 長隧道B週期
input string VegasShortTunnelA  = "34,34,34,34,34,34,34,34,34,34,34,34";             // 短隧道A週期
input string VegasShortTunnelB  = "55,55,55,55,55,55,55,55,55,55,55,55";             // 短隧道B週期
input string VegasFilterPeriods = "100,100,100,100,100,100,100,100,100,100,100,100"; // 過濾線週期(Hull MA，每商品一個，指數的建議用VegasFilterParams.csv裡回測出來的最佳值手動填入)

input group "--- 雙路徑進場訊號(路徑A拉回/路徑B轉折) ---"
input double VegasVolThresholdDefault  = 1.2;   // 帶量門檻預設值(找不到優化資料時使用)
input int    VegasVolAvgBarsDefault    = 20;    // 均量計算根數預設值
input int    VegasSlopeLookbackDefault = 5;     // 長隧道斜率判斷回看根數預設值
input int    VegasSignalLookback = 100;  // 每次檢查回看幾根K棒(避免補標記太舊的歷史訊號)

// 這三個是實際運算用的變數(非input，OnInit時先用上面的Default值初始化，
// 找得到VegasDualPathParams.csv優化結果的話會自動覆蓋成最佳值)
double VegasVolThreshold;
int    VegasVolAvgBars;
int    VegasSlopeLookback;
input int    ATRPeriod       = 14;     // 個人化SL用的ATR週期
input double ATRMultiplier   = 2.0;    // 個人化SL = ATR × 這個倍數
input int    RecentBars      = 20;     // 近期支撐/壓力回看根數(後台用，圖表已不畫)
input int    SlopeLookback   = 3;
input double TouchTolPoints  = 10;
input int    TouchLookback   = 20;
input int    VolumeAvgBars   = 20;
input int    UpdateSeconds   = 5;      // CSV與圖表都用這個頻率更新
input int    LabelFontSize   = 11;
input int    MinGapPixels    = 18;     // 支撐壓力文字防重疊間距(像素)
input int    VolPanelX       = 10;
input int    VolPanelY       = 90;     // 避開MT5內建倒數文字
input int    TunnelMinVisualPoints = 15; // 雙通道視覺最小寬度(點)：實際週期算出來太窄時，畫圖用強制撐開到這個寬度，方向不變，只影響顯示

#define SYMBOL_COUNT 12
string Symbols[SYMBOL_COUNT] = {"EURUSD","GBPUSD","USDJPY","USDCAD","AUDUSD","NZDUSD","USDCHF",
                                 "US30.cash","US500.cash","US100.cash","USDCNH","JP225.cash"};
string CsvFileName = "Excel_Monitor.csv";

string BTN_NAME;
string LastCsvUpdateTime = "尚未更新";
string LastCsvUpdateSource = "";     // 記錄上一次是「手動」還是「自動(M15收盤)」觸發的
int    CsvWriteCount = 0;            // 累計寫檔次數，讓你能確認背景真的有在跑(數字會一直增加)
datetime LastCsvBarTime = 0; // 上一次「自動」寫CSV對應的M15K棒時間，用來判斷是否收出新K棒

void MarkCsvUpdated(string source)
{
   CsvWriteCount++;
   LastCsvUpdateSource = source;
   LastCsvUpdateTime   = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   Print(source, "更新CSV完成：", LastCsvUpdateTime, "　(累計第", CsvWriteCount, "次)");
}

int ShortMAArr[SYMBOL_COUNT];   // 解析後的每商品短MA週期(後台用)
int LongMAArr[SYMBOL_COUNT];    // 解析後的每商品長MA/EMA週期(後台用)
int VegasFilterArr[SYMBOL_COUNT]; // 解析後的每商品Vegas過濾線週期(圖表視覺化用)
int VegasLongAArr[SYMBOL_COUNT];
int VegasLongBArr[SYMBOL_COUNT];
int VegasShortAArr[SYMBOL_COUNT];
int VegasShortBArr[SYMBOL_COUNT];
int ChartSymbolIdx = -1; // 這張圖表的商品在Symbols[]裡的index，找不到就用index0當預設

double Ema144Buf[];
double Ema169Buf[];
double Ema34Buf[];
double Ema55Buf[];
double FilterBuf[];
string PFX;

// (NLAB/LKey/LName/LColor已不需要，亞歐美盤標籤不再畫在圖表上)

//+------------------------------------------------------------------+
//| 把逗號分隔字串解析成8個整數；數量不足時，後面沒填的欄位沿用最後一個值|
//+------------------------------------------------------------------+
void ParsePeriods(string s, int &outArr[])
{
   string parts[];
   int n = StringSplit(s, ',', parts);
   int lastVal = 9;
   for(int i=0;i<SYMBOL_COUNT;i++)
   {
      if(i<n)
      {
         int v = (int)StringToInteger(parts[i]);
         if(v>0) lastVal = v;
      }
      outArr[i] = lastVal;
   }
}

int FindSymbolIndex(string sym)
{
   for(int i=0;i<SYMBOL_COUNT;i++) if(Symbols[i]==sym) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| 把目前圖表週期轉成跟VegasFilterParams.csv裡Symbol,TF欄位一致的字串  |
//| (新增M5支援：以前M5會回傳""被跳過，只能用經典預設值)                 |
//+------------------------------------------------------------------+
string PeriodToTFString(ENUM_TIMEFRAMES p)
{
   switch(p)
   {
      case PERIOD_D1:  return "D1";
      case PERIOD_H4:  return "H4";
      case PERIOD_H1:  return "H1";
      case PERIOD_M15: return "M15";
      case PERIOD_M5:  return "M5";
      default:         return "";
   }
}

//+------------------------------------------------------------------+
//| 讀取UTF-8檔案(共用資料夾)，回傳每行一個元素的字串陣列                |
//+------------------------------------------------------------------+
bool ReadUTF8FileLines(string path, string &outLines[])
{
   int handle = FileOpen(path, FILE_READ|FILE_BIN|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) return false;

   ulong size = FileSize(handle);
   uchar bytes[];
   ArrayResize(bytes, (int)size);
   FileReadArray(handle, bytes, 0, (int)size);
   FileClose(handle);

   string fullText = CharArrayToString(bytes, 0, -1, CP_UTF8);
   if(StringLen(fullText) > 0 && StringGetCharacter(fullText,0) == 0xFEFF)
      fullText = StringSubstr(fullText, 1);

   StringReplace(fullText, "\r\n", "\n");
   StringReplace(fullText, "\r", "\n");

   int n = StringSplit(fullText, '\n', outLines);
   return (n > 0);
}

//+------------------------------------------------------------------+
//| 自動讀取VegasFilterParams.csv(共用資料夾)，找出跟這張圖表商品+週期  |
//| 相符的那一列，把5條線的最佳化週期自動套用進來(覆蓋輸入參數的預設值)。|
//| 找不到對應資料就靜靜跳過，繼續用輸入參數/經典值當備援。              |
//+------------------------------------------------------------------+
void AutoLoadVegasParams()
{
   string tfStr = PeriodToTFString(_Period);
   if(tfStr == "") return; // 非D1/H4/H1/M15/M5週期沒有對應優化資料，跳過

   string lines[];
   if(!ReadUTF8FileLines("VegasFilterParams.csv", lines))
   {
      Print("提示：讀不到共用資料夾裡的VegasFilterParams.csv，Vegas系統維持用輸入參數/經典值");
      return;
   }

   for(int i=0;i<ArraySize(lines);i++)
   {
      string line = lines[i];
      if(StringLen(line)==0) continue;
      if(StringGetCharacter(line,0) == '#') continue;
      if(StringFind(line, "Symbol") >= 0 && StringFind(line, "LongTunnelA") >= 0) continue; // 標題列

      string parts[];
      int n = StringSplit(line, ',', parts);
      if(n < 7) continue;

      if(parts[0] == _Symbol && parts[1] == tfStr)
      {
         VegasLongAArr[ChartSymbolIdx]  = (int)StringToInteger(parts[2]);
         VegasLongBArr[ChartSymbolIdx]  = (int)StringToInteger(parts[3]);
         VegasShortAArr[ChartSymbolIdx] = (int)StringToInteger(parts[4]);
         VegasShortBArr[ChartSymbolIdx] = (int)StringToInteger(parts[5]);
         VegasFilterArr[ChartSymbolIdx] = (int)StringToInteger(parts[6]);
         Print("已自動套用 ", _Symbol, " ", tfStr, " 的Vegas最佳化週期：長隧道",
               VegasLongAArr[ChartSymbolIdx], "/", VegasLongBArr[ChartSymbolIdx],
               " 短隧道", VegasShortAArr[ChartSymbolIdx], "/", VegasShortBArr[ChartSymbolIdx],
               " 過濾線", VegasFilterArr[ChartSymbolIdx]);
         return;
      }
   }
   Print("提示：VegasFilterParams.csv裡沒有 ", _Symbol, " ", tfStr,
         " 的優化資料，維持用輸入參數/經典值(可能還沒針對這個週期跑過優化)");
}

//+------------------------------------------------------------------+
//| 自動讀取VegasDualPathParams.csv(共用資料夾)，找出跟這張圖表商品+     |
//| 週期相符的那一列，把雙路徑訊號的3個參數自動套用進來。                 |
//+------------------------------------------------------------------+
void AutoLoadDualPathParams()
{
   string tfStr = PeriodToTFString(_Period);
   if(tfStr == "") return;

   string lines[];
   if(!ReadUTF8FileLines("VegasDualPathParams.csv", lines))
   {
      Print("提示：讀不到共用資料夾裡的VegasDualPathParams.csv，雙路徑訊號維持用預設參數");
      return;
   }

   for(int i=0;i<ArraySize(lines);i++)
   {
      string line = lines[i];
      if(StringLen(line)==0) continue;
      if(StringGetCharacter(line,0) == '#') continue;
      if(StringFind(line, "Symbol") >= 0 && StringFind(line, "VolThreshold") >= 0) continue;

      string parts[];
      int n = StringSplit(line, ',', parts);
      if(n < 5) continue;

      if(parts[0] == _Symbol && parts[1] == tfStr)
      {
         VegasVolThreshold  = StringToDouble(parts[2]);
         VegasVolAvgBars    = (int)StringToInteger(parts[3]);
         VegasSlopeLookback = (int)StringToInteger(parts[4]);
         Print("已自動套用 ", _Symbol, " ", tfStr, " 的雙路徑訊號最佳化參數：放量門檻",
               VegasVolThreshold, " 均量根數", VegasVolAvgBars, " 斜率回看", VegasSlopeLookback);
         return;
      }
   }
   Print("提示：VegasDualPathParams.csv裡沒有 ", _Symbol, " ", tfStr, " 的優化資料，維持用預設參數");
}

//+------------------------------------------------------------------+
int OnInit()
{
   PFX = "EMALL_" + _Symbol + "_";
   ParsePeriods(ShortMAPeriods, ShortMAArr);
   ParsePeriods(LongMAPeriods,  LongMAArr);
   ParsePeriods(VegasFilterPeriods, VegasFilterArr);
   ParsePeriods(VegasLongTunnelA, VegasLongAArr);
   ParsePeriods(VegasLongTunnelB, VegasLongBArr);
   ParsePeriods(VegasShortTunnelA, VegasShortAArr);
   ParsePeriods(VegasShortTunnelB, VegasShortBArr);
   ChartSymbolIdx = FindSymbolIndex(_Symbol);
   if(ChartSymbolIdx < 0) ChartSymbolIdx = 0; // 掛在非8大商品圖表上時，預設用第一組週期
   VegasVolThreshold = VegasVolThresholdDefault;
   VegasVolAvgBars = VegasVolAvgBarsDefault;
   VegasSlopeLookback = VegasSlopeLookbackDefault;
   AutoLoadVegasParams(); // 自動用歷史回測出來的最佳週期覆蓋上面的手動輸入值(找不到才維持手動值)
   AutoLoadDualPathParams(); // 自動用歷史回測出來的雙路徑訊號參數覆蓋預設值
   LoadTAIParams();
   SetIndexBuffer(0, Ema144Buf, INDICATOR_DATA);
   SetIndexBuffer(1, Ema169Buf, INDICATOR_DATA);
   SetIndexBuffer(2, Ema34Buf,  INDICATOR_DATA);
   SetIndexBuffer(3, Ema55Buf,  INDICATOR_DATA);
   SetIndexBuffer(4, FilterBuf, INDICATOR_DATA);
   ArraySetAsSeries(Ema144Buf, false);
   ArraySetAsSeries(Ema169Buf, false);
   ArraySetAsSeries(Ema34Buf,  false);
   ArraySetAsSeries(Ema55Buf,  false);
   ArraySetAsSeries(FilterBuf, false);

   for(int i=0;i<SYMBOL_COUNT;i++) SymbolSelect(Symbols[i], true);

   BTN_NAME = PFX + "BtnUpdateCsv";
   CreateUpdateCsvButton();

   EventSetTimer(UpdateSeconds);
   UpdateChartVisuals(); // 圖表視覺化(均線/支撐壓力/成交量文字)照樣自動跑
   return(INIT_SUCCEEDED);
}

void CreateUpdateCsvButton()
{
   if(ObjectFind(0, BTN_NAME) < 0)
   {
      ObjectCreate(0, BTN_NAME, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_XDISTANCE, VolPanelX);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_YDISTANCE, VolPanelY + (LabelFontSize+8)*4 + 10);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_XSIZE, 260);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_YSIZE, 28);
      ObjectSetString(0, BTN_NAME, OBJPROP_TEXT, "立即更新一次CSV(平時M15收盤自動更新)"); // 字較長，按鈕已加寬到260px
      ObjectSetInteger(0, BTN_NAME, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_BGCOLOR, clrDarkGreen);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_SELECTABLE, false);
   }
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == BTN_NAME)
   {
      ObjectSetInteger(0, BTN_NAME, OBJPROP_STATE, false); // 按鈕彈回，不要保持按下狀態
      WriteAllSymbolsCsv();
      MarkCsvUpdated("手動");
      ChartRedraw(0);
   }
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
}

//+------------------------------------------------------------------+
//| Hull MA(HMA)用的輔助函式 —— 給OnCalculate()裡「時間順序由舊到新」  |
//| 的內建close[]陣列使用(index越大越新，跟MqlRates的序列順序相反)。    |
//| HMA(n) = WMA( 2*WMA(price,n/2) - WMA(price,n), sqrt(n) )           |
//+------------------------------------------------------------------+
double ChronoClose(const double &price[], int total, int idx)
{
   if(idx<0) idx=0;
   if(idx>=total) idx=total-1;
   return price[idx];
}

double WMAChrono(const double &price[], int total, int period, int idx)
{
   double sum=0, wsum=0;
   for(int k=0;k<period;k++)
   {
      double w = period-k; // idx本身(最新)權重最高，往回(idx-k)權重遞減
      sum  += ChronoClose(price, total, idx-k)*w;
      wsum += w;
   }
   return (wsum>0) ? sum/wsum : ChronoClose(price, total, idx);
}

double CalcHMAAt(const double &price[], int total, int period, int idx)
{
   int half  = MathMax(1, (int)MathRound(period/2.0));
   int sqrtP = MathMax(1, (int)MathRound(MathSqrt((double)period)));
   double sum=0, wsum=0;
   for(int j=0;j<sqrtP;j++)
   {
      double wmaHalf = WMAChrono(price, total, half,   idx-j);
      double wmaFull = WMAChrono(price, total, period, idx-j);
      double raw     = 2.0*wmaHalf - wmaFull;
      double w = sqrtP-j;
      sum  += raw*w;
      wsum += w;
   }
   return (wsum>0) ? sum/wsum : ChronoClose(price, total, idx);
}

//+------------------------------------------------------------------+
//| 把兩條太接近的線，以中點為基準對稱撐開到最小寬度(純視覺用)。         |
//| 用傳址修改a/b，維持原本誰大誰小的相對位置，只有間距被拉開。         |
//+------------------------------------------------------------------+
void WidenForVisual(double &a, double &b, double minGap)
{
   double diff = a - b;
   if(MathAbs(diff) >= minGap) return; // 夠寬，不用處理
   double mid = (a + b) / 2.0;
   double sign = (diff >= 0) ? 1.0 : -1.0;
   a = mid + sign*minGap/2.0;
   b = mid - sign*minGap/2.0;
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   int start = (prev_calculated>1) ? prev_calculated-1 : 0;

   // 圖表上畫的雙通道，用跟訊號邏輯一樣的週期(會被VegasFilterParams.csv覆蓋成該周期
   // 回測出來的最佳化值)。如果算出來的線太貼近、視覺上看不出色塊，下面會強制撐開到
   // 最小可視寬度(TunnelMinVisualPoints)，只影響畫面顯示，不影響CSV/訊號判斷用的實際數值。
   int longA = VegasLongAArr[ChartSymbolIdx];   if(longA<=0) longA = 144;
   int longB = VegasLongBArr[ChartSymbolIdx];   if(longB<=0) longB = 169;
   int shortA = VegasShortAArr[ChartSymbolIdx]; if(shortA<=0) shortA = 34;
   int shortB = VegasShortBArr[ChartSymbolIdx]; if(shortB<=0) shortB = 55;
   int filterPeriod = VegasFilterArr[ChartSymbolIdx];
   if(filterPeriod<=0) filterPeriod = 100;

   double a144 = 2.0/(longA+1.0);
   double a169 = 2.0/(longB+1.0);
   double a34  = 2.0/(shortA+1.0);
   double a55  = 2.0/(shortB+1.0);
   double minGapPrice = TunnelMinVisualPoints * _Point;

   for(int i=start; i<rates_total; i++)
   {
      if(i==0)
      {
         Ema144Buf[i] = close[i];
         Ema169Buf[i] = close[i];
         Ema34Buf[i]  = close[i];
         Ema55Buf[i]  = close[i];
         FilterBuf[i] = close[i];
      }
      else
      {
         Ema144Buf[i] = close[i]*a144 + Ema144Buf[i-1]*(1-a144);
         Ema169Buf[i] = close[i]*a169 + Ema169Buf[i-1]*(1-a169);
         Ema34Buf[i]  = close[i]*a34  + Ema34Buf[i-1]*(1-a34);
         Ema55Buf[i]  = close[i]*a55  + Ema55Buf[i-1]*(1-a55);
      }
      // 過濾線改用Hull MA：不是遞迴公式，每根都直接依收盤價窗口重新計算
      FilterBuf[i] = CalcHMAAt(close, rates_total, filterPeriod, i);

      // 最小可視寬度：兩條線太近(週期彼此接近時常見)就以中點為基準對稱撐開，
      // 方向(誰在上誰在下)維持不變，純粹讓色塊肉眼看得見，不影響底層數值計算。
      WidenForVisual(Ema144Buf[i], Ema169Buf[i], minGapPrice);
      WidenForVisual(Ema34Buf[i],  Ema55Buf[i],  minGapPrice);
   }
   return(rates_total);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateChartVisuals(); // 圖表線條/文字照樣每UpdateSeconds秒自動更新
   DetectVegasEntrySignals(); // 路徑A(順勢拉回)+路徑B(轉折啟動)訊號偵測與圖表標記

   // CSV改成：只在「這張圖表所在時區」每根M15新K棒收盤時自動寫一次，
   // 不是每UpdateSeconds秒都寫；平常沒收出新K棒就不會動作。
   // 手動按鈕(OnChartEvent裡)仍然保留，可以隨時立即強制更新一次。
   datetime curM15Bar = iTime(_Symbol, PERIOD_M15, 0);
   if(curM15Bar != 0 && curM15Bar != LastCsvBarTime)
   {
      LastCsvBarTime = curM15Bar;
      WriteAllSymbolsCsv();
      MarkCsvUpdated("自動(M15收盤)");
   }
}

//====================================================================
// A. CSV 輸出(8大商品)
//====================================================================
void WriteAllSymbolsCsv()
{
   int handle = FileOpen(CsvFileName, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ",");
   if(handle==INVALID_HANDLE)
   {
      Print("無法開啟檔案寫入: ", CsvFileName, " 錯誤:", GetLastError());
      return;
   }

   FileWrite(handle,
      "Symbol","Bid","AsiaLow","AsiaHigh","EuropeLow","EuropeHigh","USLow","USHigh",
      "WeekSupport","WeekResistance","RecentSupport","RecentResistance",
      "SupportTouch","ResistanceTouch","SupportValid","ResistanceValid",
      "ShortMA","LongMA","EMA","ShortMAAngle","LongMAAngle","EMASlopePct",
      "MAAlignment","CrossState","TrendScore","TrendJudgment",
      "PersonalSL_ATR",
      "CurrentVolume","AverageVolume","VolumeState","FinalSignal",
      "CandlePattern","EntrySignal","Combined11Score","Combined11Judge",
      "UpdateTime");

   for(int s=0; s<SYMBOL_COUNT; s++) WriteSymbolRow(handle, Symbols[s], ShortMAArr[s], LongMAArr[s]);

   FileClose(handle);
}

void WriteSymbolRow(int handle, string sym, int shortPeriod, int longPeriod)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int needBars = MathMax(longPeriod*4, VolumeAvgBars) + SlopeLookback + 10;
   int copied = CopyRates(sym, PERIOD_M5, 0, needBars, rates);
   if(copied < longPeriod+SlopeLookback+2)
   {
      // 注意：這裡務必跟 WriteAllSymbolsCsv() 的標題列(36欄)逐一對齊，
      // 缺一欄Excel那邊就會判定「欄位數不足」而整筆跳過不匯入。
      FileWrite(handle,
         sym,                 // 1  Symbol
         "", "", "", "", "", "", "",   // 2-8  Bid,AsiaLow,AsiaHigh,EuropeLow,EuropeHigh,USLow,USHigh
         "", "",               // 9-10 WeekSupport,WeekResistance
         "", "",               // 11-12 RecentSupport,RecentResistance
         "", "", "", "",        // 13-16 SupportTouch,ResistanceTouch,SupportValid,ResistanceValid
         "", "", "",            // 17-19 ShortMA,LongMA,EMA
         "", "", "",            // 20-22 ShortMAAngle,LongMAAngle,EMASlopePct
         "", "",                // 23-24 MAAlignment,CrossState
         "", "資料不足",         // 25-26 TrendScore,TrendJudgment
         "",                    // 27 PersonalSL_ATR
         "", "", "",             // 28-30 CurrentVolume,AverageVolume,VolumeState
         "資料不足",              // 31 FinalSignal
         "",                     // 32 CandlePattern
         "觀望(資料不足)",         // 33 EntrySignal
         "", "資料不足",           // 34-35 Combined11Score,Combined11Judge
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)  // 36 UpdateTime
      );
      return;
   }

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   MqlRates wk[]; ArraySetAsSeries(wk, true);
   double weekSupport=0, weekResistance=0;
   if(CopyRates(sym, PERIOD_W1, 1, 1, wk) == 1){ weekSupport=wk[0].low; weekResistance=wk[0].high; }

   // 近期支撐/壓力改用「昨天」(最近一次已完整收完的日線)當固定基準，
   // 不再用20根M5的滑動窗口(那種算法每5分鐘就會跟著飄動，不符合「支撐壓力」該有的穩定性)。
   // CopyRates用shift=1抓D1，遇到週末/假日沒有K棒時會自動跳到上一個真正有交易的日子，
   // 不需要額外寫回溯迴圈。
   MqlRates yd[]; ArraySetAsSeries(yd, true);
   double recentSupport=0, recentResistance=0;
   if(CopyRates(sym, PERIOD_D1, 1, 1, yd) == 1){ recentSupport=yd[0].low; recentResistance=yd[0].high; }
   if(recentSupport<=0 || recentResistance<=0)
   {
      // 極少數情況(例如商品剛上架、歷史資料不足)才會退回用M5滑動窗口當備援
      recentSupport = rates[1].low; recentResistance = rates[1].high;
      for(int i=1;i<=RecentBars && i<copied;i++)
      {
         if(rates[i].low  < recentSupport)    recentSupport = rates[i].low;
         if(rates[i].high > recentResistance) recentResistance = rates[i].high;
      }
   }

   double asiaLow, asiaHigh, euroLow, euroHigh, usLow, usHigh;
   GetSessionRange(sym, 0, 8,  asiaLow, asiaHigh);
   GetSessionRange(sym, 8, 16, euroLow, euroHigh);
   GetSessionRange(sym, 13,22, usLow,   usHigh);

   double tol = TouchTolPoints * pt;
   int supportTouch=0, resistanceTouch=0;
   for(int i=1;i<=TouchLookback && i<copied;i++)
   {
      if(MathAbs(rates[i].low  - recentSupport)    <= tol) supportTouch++;
      if(MathAbs(rates[i].high - recentResistance) <= tol) resistanceTouch++;
   }
   string supportValid    = (supportTouch    >= 2) ? "有效" : "待確認";
   string resistanceValid = (resistanceTouch >= 2) ? "有效" : "待確認";

   double shortMA_now  = SMA(rates, copied, shortPeriod, 0);
   double shortMA_prev = SMA(rates, copied, shortPeriod, SlopeLookback);
   double longMA_now   = SMA(rates, copied, longPeriod, 0);
   double longMA_prev  = SMA(rates, copied, longPeriod, SlopeLookback);

   double emaSeries[];
   int emaN = CalcEMA(rates, copied, longPeriod, emaSeries);
   double ema_now  = (emaN>0)             ? emaSeries[0] : longMA_now;
   double ema_prev = (emaN>SlopeLookback) ? emaSeries[SlopeLookback] : ema_now;

   double shortSlopePct = (shortMA_prev!=0) ? (shortMA_now-shortMA_prev)/shortMA_prev*100.0 : 0;
   double longSlopePct  = (longMA_prev!=0)  ? (longMA_now -longMA_prev )/longMA_prev *100.0 : 0;
   double emaSlopePct   = (ema_prev!=0)     ? (ema_now    -ema_prev    )/ema_prev    *100.0 : 0;

   // 把斜率換算成角度(度)：用ATR(每根K棒的典型波動)當基準正規化，
   // 「連續SlopeLookback根都以1倍ATR速度移動」對應約45度，這樣典型斜率才會落在
   // 有感的角度範圍(不會像直接用%算出來永遠接近0)。不影響任何交易判斷邏輯。
   double atrRaw = CalcATR(rates, copied, ATRPeriod);
   double slopeNormBase = (atrRaw > 0) ? atrRaw * SlopeLookback : 1;
   double shortSlopeAngle = MathArctan((shortMA_now - shortMA_prev) / slopeNormBase) * 180.0 / M_PI;
   double longSlopeAngle  = MathArctan((longMA_now  - longMA_prev ) / slopeNormBase) * 180.0 / M_PI;

   string maAlign;
   if(bid > shortMA_now && shortMA_now > ema_now)        maAlign = "多頭排列";
   else if(bid < shortMA_now && shortMA_now < ema_now)   maAlign = "空頭排列";
   else                                                  maAlign = "震盪糾結";

   double shortMA_1 = SMA(rates, copied, shortPeriod, 1);
   double ema_1     = (emaN>1) ? emaSeries[1] : ema_now;
   string crossState;
   if(shortMA_1 <= ema_1 && shortMA_now > ema_now)      crossState = "黃金交叉";
   else if(shortMA_1 >= ema_1 && shortMA_now < ema_now) crossState = "死亡交叉";
   else                                                 crossState = maAlign;

   string trendJudge;
   double maScore = ComputeTrendStrengthMA(bid, shortMA_now, ema_now, crossState, shortSlopeAngle, emaSlopePct, trendJudge);
   int score = (int)MathRound(maScore); // -6~+6整數尺度(純MA家族因子)

   // 11指標三分類加權綜合，改成獨立輸出的參考指標，不再是「趨勢強度」本身
   string combined11Judge;
   double combined11Score = ComputeWeighted11Score(rates, copied, shortPeriod, longPeriod, bid, combined11Judge);

   double weightedScore = maScore / 2.0; // 給下面「最後三層合成」用，維持原本-2~+2左右的尺度

   double atrSL = atrRaw * ATRMultiplier;

   long curVol = rates[0].tick_volume;
   double sumVol=0; int volCount=0;
   for(int i=1;i<=VolumeAvgBars && i<copied;i++){ sumVol += (double)rates[i].tick_volume; volCount++; }
   double avgVol = (volCount>0) ? sumVol/volCount : (double)curVol;

   string volState;
   if(avgVol<=0)                 volState = "正常";
   else if(curVol > avgVol*1.2)  volState = "放量";
   else if(curVol < avgVol*0.8)  volState = "縮量";
   else                          volState = "正常";

   //------------------ 最後：真正三層合成(支撐壓力 + 趨勢 + 成交量) ------------------
   double srBias = 0;
   double srTol = TouchTolPoints * pt;
   if(MathAbs(bid - recentSupport) <= srTol*2 && supportValid=="有效")           srBias = 1.0;
   else if(MathAbs(bid - recentResistance) <= srTol*2 && resistanceValid=="有效") srBias = -1.0;
   else if(MathAbs(bid - weekSupport) <= srTol*2 && weekSupport>0)               srBias = 0.5;
   else if(MathAbs(bid - weekResistance) <= srTol*2 && weekResistance>0)         srBias = -0.5;

   double volMult = (volState=="放量") ? 1.3 : (volState=="縮量") ? 0.7 : 1.0;

   double combinedScore = (weightedScore + srBias*0.5) * volMult;

   string finalSignal;
   if(combinedScore >= 1.3)        finalSignal = "強勢多";
   else if(combinedScore >= 0.4)   finalSignal = "偏多";
   else if(combinedScore <= -1.3)  finalSignal = "強勢空";
   else if(combinedScore <= -0.4)  finalSignal = "偏空";
   else                            finalSignal = "震盪";

   string candlePattern = DetectCandlePattern(rates, copied);

   string zoneType = "";
   string signalStrength = "";
   bool hasKeyLevel = CheckKeyLevelConfluence(bid, weekSupport, weekResistance, recentSupport, recentResistance,
                                                asiaLow, asiaHigh, euroLow, euroHigh, usLow, usHigh,
                                                srTol, zoneType, signalStrength);

   bool volAnomaly = (volState=="放量" || volState=="縮量");

   bool bullPattern = (candlePattern=="看漲吞噬" || candlePattern=="看漲針線" || candlePattern=="晨星(3根反轉)");
   bool bearPattern = (candlePattern=="看跌吞噬" || candlePattern=="看跌針線" || candlePattern=="昏星(3根反轉)");

   bool triggerLong  = hasKeyLevel && zoneType=="支撐" && volAnomaly &&
                        (bullPattern || (candlePattern=="十字星"));
   bool triggerShort = hasKeyLevel && zoneType=="壓力" && volAnomaly &&
                        (bearPattern || (candlePattern=="十字星"));

   bool emaGateLong  = (emaSlopePct > 0);
   bool emaGateShort = (emaSlopePct < 0);

   string entrySignal;
   bool finalBull = (finalSignal=="強勢多" || finalSignal=="偏多");
   bool finalBear = (finalSignal=="強勢空" || finalSignal=="偏空");

   if(triggerLong && finalBull && emaGateLong)
      entrySignal = "["+signalStrength+"]可考慮多單("+zoneType+"+"+candlePattern+")";
   else if(triggerShort && finalBear && emaGateShort)
      entrySignal = "["+signalStrength+"]可考慮空單("+zoneType+"+"+candlePattern+")";
   else if((triggerLong || triggerShort) && !((triggerLong&&emaGateLong)||(triggerShort&&emaGateShort)))
      entrySignal = "訊號出現但EMA斜度逆勢，觀望";
   else if(triggerLong || triggerShort)
      entrySignal = "關鍵位+K棒訊號出現但趨勢方向不一致，觀望";
   else
      entrySignal = "觀望";

   FileWrite(handle,
      sym,
      DoubleToString(bid, dg),
      DoubleToString(asiaLow, dg), DoubleToString(asiaHigh, dg),
      DoubleToString(euroLow, dg), DoubleToString(euroHigh, dg),
      DoubleToString(usLow, dg),   DoubleToString(usHigh, dg),
      DoubleToString(weekSupport, dg), DoubleToString(weekResistance, dg),
      DoubleToString(recentSupport, dg), DoubleToString(recentResistance, dg),
      supportTouch, resistanceTouch, supportValid, resistanceValid,
      DoubleToString(shortMA_now, dg), DoubleToString(longMA_now, dg), DoubleToString(ema_now, dg),
      DoubleToString(shortSlopeAngle,4), DoubleToString(longSlopeAngle,4), DoubleToString(emaSlopePct,4),
      maAlign, crossState, score, trendJudge,
      DoubleToString(atrSL, dg),
      (long)curVol, DoubleToString(avgVol,1), volState,
      finalSignal,
      candlePattern, entrySignal,
      DoubleToString(combined11Score,4), combined11Judge,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
   );
}

//+------------------------------------------------------------------+
//| ATR(平均真實區間)：從已收完的K棒(index1起)算，period根平均TR       |
//+------------------------------------------------------------------+
double CalcATR(const MqlRates &rates[], int total, int period)
{
   int start=1; // 排除尚未收完的index0
   int end = start+period; // 需要 period+1 根才能算出 period 個TR
   if(end>=total) end = total-1;
   if(end<=start) return 0;

   double sumTR=0; int n=0;
   for(int i=start;i<end;i++)
   {
      double tr1 = rates[i].high - rates[i].low;
      double tr2 = MathAbs(rates[i].high - rates[i+1].close);
      double tr3 = MathAbs(rates[i].low  - rates[i+1].close);
      double tr  = MathMax(tr1, MathMax(tr2, tr3));
      sumTR += tr; n++;
   }
   return (n>0) ? sumTR/n : 0;
}

double SMA(const MqlRates &rates[], int total, int period, int offset)
{
   double sum=0; int start=1+offset;
   int end = start+period-1;
   if(end>=total) end = total-1;
   int n=0;
   for(int i=start;i<=end;i++){ sum+=rates[i].close; n++; }
   return (n>0) ? sum/n : 0;
}

int CalcEMA(const MqlRates &rates[], int total, int period, double &emaOut[])
{
   int usable = total-1;
   if(usable < period+5) return 0;
   double alpha = 2.0/(period+1);
   ArrayResize(emaOut, usable);
   double tmp[];
   ArrayResize(tmp, usable);
   double seed=0;
   int seedStart = usable;
   int seedN = MathMin(period, usable);
   for(int i=0;i<seedN;i++) seed += rates[seedStart-i].close;
   seed/=seedN;
   double prevEma = seed;
   int outIdx = usable-1;
   tmp[outIdx] = prevEma;
   for(int idx=seedStart-1; idx>=1; idx--)
   {
      double price = rates[idx].close;
      double e = price*alpha + prevEma*(1-alpha);
      outIdx--;
      tmp[outIdx] = e;
      prevEma = e;
   }
   for(int i=0;i<usable;i++) emaOut[i] = tmp[i];
   return usable;
}

//+------------------------------------------------------------------+
//| Hull MA(HMA)版本 —— 給「序列順序」的MqlRates陣列用(index0=最新，   |
//| index越大越舊，即ArraySetAsSeries(rates,true)那種)。介面跟CalcEMA  |
//| 完全一致(輸出陣列大小/位置對應方式相同)，呼叫端可以直接替換。       |
//| HMA(n) = WMA( 2*WMA(price,n/2) - WMA(price,n), sqrt(n) )           |
//+------------------------------------------------------------------+
double SeriesClose(const MqlRates &rates[], int total, int idx)
{
   if(idx<0) idx=0;
   if(idx>=total) idx=total-1;
   return rates[idx].close;
}

double WMASeries(const MqlRates &rates[], int total, int period, int idx)
{
   double sum=0, wsum=0;
   for(int k=0;k<period;k++)
   {
      double w = period-k; // idx本身權重最高，往後(idx+k，越舊)權重遞減
      sum  += SeriesClose(rates, total, idx+k)*w;
      wsum += w;
   }
   return (wsum>0) ? sum/wsum : SeriesClose(rates, total, idx);
}

int CalcHMA(const MqlRates &rates[], int total, int period, double &hmaOut[])
{
   int usable = total-1;
   int half   = MathMax(1, (int)MathRound(period/2.0));
   int sqrtP  = MathMax(1, (int)MathRound(MathSqrt((double)period)));
   if(usable < period+sqrtP+5) return 0;

   ArrayResize(hmaOut, usable);
   for(int k=0;k<usable;k++)
   {
      int idx = k+1; // 跟CalcEMA同樣的位置對應：hmaOut[k]對應rates[k+1]
      double sum=0, wsum=0;
      for(int j=0;j<sqrtP;j++)
      {
         double wmaHalf = WMASeries(rates, total, half,   idx+j);
         double wmaFull = WMASeries(rates, total, period, idx+j);
         double raw     = 2.0*wmaHalf - wmaFull;
         double w = sqrtP-j;
         sum  += raw*w;
         wsum += w;
      }
      hmaOut[k] = (wsum>0) ? sum/wsum : SeriesClose(rates, total, idx);
   }
   return usable;
}

// 依伺服器時間取「最近一次已完整結束」的時段高低；遇週末/假日自動往前找有資料的一天
void GetSessionRange(string sym, int startHour, int endHour, double &outLow, double &outHigh)
{
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime todayStart = StructToTime(dt);
   datetime sessStart = todayStart + startHour*3600;
   datetime sessEnd   = todayStart + endHour*3600;

   if(now < sessEnd){ sessStart -= 86400; sessEnd -= 86400; }

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int cnt = 0;
   for(int tryDay=0; tryDay<7; tryDay++)
   {
      cnt = CopyRates(sym, PERIOD_M5, sessStart, sessEnd, r);
      if(cnt>0) break;
      sessStart -= 86400;
      sessEnd   -= 86400;
   }
   if(cnt<=0){ outLow=0; outHigh=0; return; }

   outLow = r[0].low; outHigh = r[0].high;
   for(int i=1;i<cnt;i++)
   {
      if(r[i].low<outLow)   outLow=r[i].low;
      if(r[i].high>outHigh) outHigh=r[i].high;
   }
}

//====================================================================
// B. 圖表視覺化(只針對這張圖表所在的商品)
//====================================================================
void CreateHLine(string name, color clr, int style)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
}
void MoveHLine(string name, double price)
{
   if(price<=0) return;
   ObjectMove(0, name, 0, 0, price);
}

void EnsureTextObj(string name, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TEXT, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, LabelFontSize);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void EnsureCornerLabel(string name, int x, int y, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, LabelFontSize);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

double PixelsPerPrice()
{
   double pmax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   double pmin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   long   hpx  = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(pmax<=pmin || hpx<=0) return 0;
   return (double)hpx/(pmax-pmin);
}

double SimpleAvg2(const MqlRates &rates[], int startIdx, int period)
{
   double sum=0; int n=0;
   for(int i=startIdx;i<startIdx+period;i++){ sum+=rates[i].close; n++; }
   return (n>0) ? sum/n : 0;
}

void UpdateChartVisuals()
{
   CreateHLine(PFX+"RecSup",   clrLimeGreen,STYLE_DASH);
   CreateHLine(PFX+"RecRes",   clrTomato,   STYLE_DASH);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = MathMax(LongMAArr[ChartSymbolIdx]*4, RecentBars) + 10;
   int copied = CopyRates(_Symbol, PERIOD_M5, 0, need, rates);
   if(copied < RecentBars+2) return;

   MqlRates yd2[]; ArraySetAsSeries(yd2, true);
   double recSup=0, recRes=0;
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, yd2) == 1){ recSup=yd2[0].low; recRes=yd2[0].high; }
   if(recSup<=0 || recRes<=0)
   {
      recSup = rates[1].low; recRes = rates[1].high;
      for(int i=1;i<=RecentBars && i<copied;i++)
      {
         if(rates[i].low  < recSup) recSup = rates[i].low;
         if(rates[i].high > recRes) recRes = rates[i].high;
      }
   }
   MoveHLine(PFX+"RecSup", recSup);
   MoveHLine(PFX+"RecRes", recRes);

   int firstVisibleBar = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR, 0);
   int leftShift = MathMax(firstVisibleBar - 3, 0);
   datetime labelTime = iTime(_Symbol, PERIOD_M5, leftShift);
   if(labelTime == 0) labelTime = TimeCurrent();

   EnsureTextObj(PFX+"Txt_RecSup", clrLimeGreen);
   ObjectSetString(0, PFX+"Txt_RecSup", OBJPROP_TEXT, "近支撐 "+DoubleToString(recSup, _Digits));
   ObjectMove(0, PFX+"Txt_RecSup", 0, labelTime, recSup);

   EnsureTextObj(PFX+"Txt_RecRes", clrTomato);
   ObjectSetString(0, PFX+"Txt_RecRes", OBJPROP_TEXT, "近壓力 "+DoubleToString(recRes, _Digits));
   ObjectMove(0, PFX+"Txt_RecRes", 0, labelTime, recRes);

   long curVol = rates[0].tick_volume;
   double sumVol=0; int volCount=0;
   for(int i=1;i<=VolumeAvgBars && i<copied;i++){ sumVol += (double)rates[i].tick_volume; volCount++; }
   double avgVol = (volCount>0) ? sumVol/volCount : (double)curVol;

   string volState;
   if(avgVol<=0)                 volState = "正常";
   else if(curVol > avgVol*1.2)  volState = "放量";
   else if(curVol < avgVol*0.8)  volState = "縮量";
   else                          volState = "正常";
   color volColor = (volState=="放量") ? clrLime : (volState=="縮量") ? clrGray : clrWhite;

   EnsureCornerLabel(PFX+"VolCur",  VolPanelX, VolPanelY,                    clrSilver);
   EnsureCornerLabel(PFX+"VolAvg",  VolPanelX, VolPanelY+LabelFontSize+8,    clrSilver);
   EnsureCornerLabel(PFX+"VolStat", VolPanelX, VolPanelY+(LabelFontSize+8)*2,volColor);
   EnsureCornerLabel(PFX+"CsvTime", VolPanelX, VolPanelY+(LabelFontSize+8)*3-4, clrYellow);
   string csvTimeText = "CSV上次更新: "+LastCsvUpdateTime;
   if(CsvWriteCount>0) csvTimeText += "　["+LastCsvUpdateSource+"，累計第"+IntegerToString(CsvWriteCount)+"次]";
   ObjectSetString(0, PFX+"CsvTime", OBJPROP_TEXT, csvTimeText);
   ObjectSetString(0, PFX+"VolCur",  OBJPROP_TEXT, "目前量: "+IntegerToString((int)curVol));
   ObjectSetString(0, PFX+"VolAvg",  OBJPROP_TEXT, "平均量: "+DoubleToString(avgVol,1));
   ObjectSetInteger(0, PFX+"VolStat", OBJPROP_COLOR, volColor);
   ObjectSetString(0, PFX+"VolStat", OBJPROP_TEXT, "量能: "+volState);

   ChartRedraw(0);
}

//====================================================================
// 11大指標三分類加權評分(跟 gordon_full_analysis.py 的分類權重一致)
//====================================================================
double SigStrength(double value, double strongHi, double mildHi, double mildLo, double strongLo)
{
   if(value >= strongHi) return 2;
   if(value >= mildHi)   return 1;
   if(value <= strongLo) return -2;
   if(value <= mildLo)   return -1;
   return (value >= (mildHi+mildLo)/2.0) ? 1 : -1;
}

double AvgArr(const double &arr[], int idx, int period)
{
   double sum=0; int cnt=0;
   for(int i=idx-period+1;i<=idx;i++){ if(i<0) continue; sum+=arr[i]; cnt++; }
   return (cnt>0) ? sum/cnt : 0;
}

double StdArr(const double &arr[], int idx, int period, double mean)
{
   double sum=0; int cnt=0;
   for(int i=idx-period+1;i<=idx;i++){ if(i<0) continue; sum+=(arr[i]-mean)*(arr[i]-mean); cnt++; }
   return (cnt>0) ? MathSqrt(sum/cnt) : 0;
}

double EmaArr(const double &arr[], int idx, int period)
{
   int start = idx-period*3;
   if(start<0) start=0;
   double alpha = 2.0/(period+1);
   double ema = AvgArr(arr, start+period-1, period);
   for(int i=start+period;i<=idx;i++) ema = arr[i]*alpha + ema*(1-alpha);
   return ema;
}

double RSI_Arr(const double &close[], int idx, int period)
{
   int start = idx-period*3;
   if(start<period) start=period;
   double avgGain=0, avgLoss=0;
   for(int i=start-period+1;i<=start;i++)
   {
      double diff = close[i]-close[i-1];
      if(diff>0) avgGain+=diff; else avgLoss+=-diff;
   }
   avgGain/=period; avgLoss/=period;
   for(int i=start+1;i<=idx;i++)
   {
      double diff = close[i]-close[i-1];
      double gain=(diff>0)?diff:0, loss=(diff<0)?-diff:0;
      avgGain=(avgGain*(period-1)+gain)/period;
      avgLoss=(avgLoss*(period-1)+loss)/period;
   }
   if(avgLoss==0) return 100;
   double rs=avgGain/avgLoss;
   return 100-100/(1+rs);
}

void KD_Arr(const double &high[], const double &low[], const double &close[],
            int idx, int kPeriod, int dPeriod, int smooth, double &kOut, double &dOut)
{
   int start = idx-kPeriod*3;
   if(start<kPeriod) start=kPeriod;
   double k=50, d=50;
   for(int i=start;i<=idx;i++)
   {
      double hh=high[i], ll=low[i];
      for(int j=i-kPeriod+1;j<=i;j++){ if(high[j]>hh) hh=high[j]; if(low[j]<ll) ll=low[j]; }
      double rsv=(hh-ll!=0)?(close[i]-ll)/(hh-ll)*100.0:50;
      k=(k*(smooth-1)+rsv)/smooth;
      d=(d*(dPeriod-1)+k)/dPeriod;
   }
   kOut=k; dOut=d;
}

double PSY_Arr(const double &close[], int idx, int period)
{
   int up=0;
   for(int i=idx-period+1;i<=idx;i++){ if(i<1) continue; if(close[i]>close[i-1]) up++; }
   return (double)up/period*100.0;
}

double WR_Arr(const double &high[], const double &low[], const double &close[], int idx, int period)
{
   double hh=high[idx], ll=low[idx];
   for(int i=idx-period+1;i<=idx;i++){ if(i<0) continue; if(high[i]>hh) hh=high[i]; if(low[i]<ll) ll=low[i]; }
   return (hh-ll!=0) ? (hh-close[idx])/(hh-ll)*(-100.0) : -50;
}

void MACD_Arr(const double &close[], int idx, int fast, int slow, int signal, double &macdOut, double &sigOut)
{
   int start = idx-slow*3;
   if(start<slow) start=slow;
   double emaFast=AvgArr(close,start,fast), emaSlow=AvgArr(close,start,slow);
   double aFast=2.0/(fast+1), aSlow=2.0/(slow+1), aSig=2.0/(signal+1);
   double macdLine=0, sigLine=0; bool first=true;
   for(int i=start+1;i<=idx;i++)
   {
      emaFast = close[i]*aFast + emaFast*(1-aFast);
      emaSlow = close[i]*aSlow + emaSlow*(1-aSlow);
      macdLine = emaFast-emaSlow;
      if(first){ sigLine=macdLine; first=false; }
      else sigLine = macdLine*aSig + sigLine*(1-aSig);
   }
   macdOut=macdLine; sigOut=sigLine;
}

double CCI_Arr(const double &high[], const double &low[], const double &close[], int idx, int period)
{
   double sumTp=0;
   for(int i=idx-period+1;i<=idx;i++){ if(i<0) continue; sumTp += (high[i]+low[i]+close[i])/3.0; }
   double smaTp = sumTp/period;
   double curTp = (high[idx]+low[idx]+close[idx])/3.0;
   double mad=0;
   for(int i=idx-period+1;i<=idx;i++){ if(i<0) continue; mad += MathAbs((high[i]+low[i]+close[i])/3.0 - smaTp); }
   mad/=period;
   return (mad!=0) ? (curTp-smaTp)/(0.015*mad) : 0;
}

double ComputeWeighted11Score(const MqlRates &rates[], int copied, int shortPeriod, int longPeriod,
                                double bid, string &judgeOut)
{
   int n = copied-1;
   if(n < 45){ judgeOut="資料不足"; return 0; }

   double close[], high[], low[];
   ArrayResize(close,n); ArrayResize(high,n); ArrayResize(low,n);
   for(int i=0;i<n;i++)
   {
      close[i]=rates[n-i].close;
      high[i]=rates[n-i].high;
      low[i]=rates[n-i].low;
   }
   int last=n-1;

   double maS = AvgArr(close,last,shortPeriod);
   double maL = AvgArr(close,last,longPeriod);
   double maDiffPct = (maL!=0)?(maS-maL)/maL*100.0:0;
   double sMA = SigStrength(maDiffPct, 0.15,0,0,-0.15);

   double macdLine, macdSig;
   MACD_Arr(close,last,12,26,9,macdLine,macdSig);
   double histPct = (bid!=0)?(macdLine-macdSig)/bid*100.0:0;
   double sMACD = SigStrength(histPct, 0.05,0,0,-0.05);

   double bollMid = AvgArr(close,last,20);
   double bollStd = StdArr(close,last,20,bollMid);
   double bollHalf = (bollStd!=0)?2*bollStd:1;
   double sBOLL = SigStrength((bid-bollMid)/bollHalf, 0.5,0,0,-0.5);

   double keltMid = EmaArr(close,last,20);
   double keltAtr = CalcATR(rates, copied, 20);
   double keltHalf = (keltAtr!=0)?2*keltAtr:1;
   double sKELT = SigStrength((bid-keltMid)/keltHalf, 0.5,0,0,-0.5);

   double trendAvg = (sMA+sMACD+sBOLL+sKELT)/4.0;

   double rsi = RSI_Arr(close,last,14);
   double sRSI = SigStrength(rsi, 60,50,50,40);

   double kk,dd; KD_Arr(high,low,close,last,9,3,3,kk,dd);
   double sKD = (kk>dd && kk<20) ? 2 : (kk>dd) ? 1 : (kk<dd && kk>80) ? -2 : -1;

   double wr = WR_Arr(high,low,close,last,14);
   double sWR = SigStrength(wr, -30,-50,-50,-70);

   double cci = CCI_Arr(high,low,close,last,14);
   double sCCI = SigStrength(cci, 100,0,0,-100);

   double mtmPct = (bid!=0 && last-10>=0)?(close[last]-close[last-10])/bid*100.0:0;
   double sMTM = SigStrength(mtmPct, 0.15,0,0,-0.15);

   double momentumAvg = (sRSI+sKD+sWR+sCCI+sMTM)/5.0;

   double psy = PSY_Arr(close,last,12);
   double sPSY = SigStrength(psy, 60,50,50,40);

   double biasSma = AvgArr(close,last,20);
   double biasPct = (biasSma!=0)?(bid-biasSma)/biasSma*100.0:0;
   double sBIAS = SigStrength(biasPct, 1.0,0,0,-1.0);

   double otherAvg = (sPSY+sBIAS)/2.0;

   double finalScore = trendAvg*0.45 + momentumAvg*0.35 + otherAvg*0.20;

   if(finalScore >= 1.0)        judgeOut = "強力多頭";
   else if(finalScore >= 0.3)   judgeOut = "偏多";
   else if(finalScore <= -1.0)  judgeOut = "強力空頭";
   else if(finalScore <= -0.3)  judgeOut = "偏空";
   else                         judgeOut = "多空不明";

   return finalScore;
}

string DetectCandlePattern(const MqlRates &rates[], int copied)
{
   if(copied < 6) return "資料不足";

   MqlRates c1 = rates[1];
   MqlRates c2 = rates[2];
   MqlRates c3 = rates[3];

   double body1 = MathAbs(c1.close - c1.open);
   double body2 = MathAbs(c2.close - c2.open);
   double body3 = MathAbs(c3.close - c3.open);

   bool bull1 = c1.close > c1.open, bear1 = c1.close < c1.open;
   bool bull3 = c3.close > c3.open, bear3 = c3.close < c3.open;

   double mid3 = (c3.open + c3.close) / 2.0;

   if(bear3 && body3 > 0 && body2 <= body3*0.35 && bull1 && c1.close > mid3)
      return "晨星(3根反轉)";
   if(bull3 && body3 > 0 && body2 <= body3*0.35 && bear1 && c1.close < mid3)
      return "昏星(3根反轉)";

   double range1 = c1.high - c1.low;
   if(range1 <= 0) return "無明顯型態";

   double upperWick1 = c1.high - MathMax(c1.open, c1.close);
   double lowerWick1 = MathMin(c1.open, c1.close) - c1.low;

   bool bull2 = c2.close > c2.open;
   bool bear2 = c2.close < c2.open;

   if(bear2 && bull1 && c1.open <= c2.close && c1.close >= c2.open)
      return "看漲吞噬";
   if(bull2 && bear1 && c1.open >= c2.close && c1.close <= c2.open)
      return "看跌吞噬";

   if(body1 <= range1*0.1)
      return "十字星";

   if(lowerWick1 >= body1*2.0 && lowerWick1 >= range1*0.5 && upperWick1 <= body1*0.5)
      return "看漲針線";
   if(upperWick1 >= body1*2.0 && upperWick1 >= range1*0.5 && lowerWick1 <= body1*0.5)
      return "看跌針線";

   return "無明顯型態";
}

bool CheckKeyLevelConfluence(double bid,
                               double weekSup, double weekRes, double recSup, double recRes,
                               double asiaLow, double asiaHigh, double euroLow, double euroHigh,
                               double usLow, double usHigh,
                               double tol, string &zoneOut, string &strengthOut)
{
   double levels[10] = {weekSup, recSup, asiaLow, euroLow, usLow,
                         weekRes, recRes, asiaHigh, euroHigh, usHigh};
   string types[10]   = {"支撐","支撐","支撐","支撐","支撐",
                          "壓力","壓力","壓力","壓力","壓力"};

   int bestIdx = -1;
   double bestDist = -1;

   for(int i=0;i<10;i++)
   {
      if(levels[i]<=0) continue;
      double d = MathAbs(bid - levels[i]);
      if(d > tol) continue;
      if(bestIdx<0 || d<bestDist) { bestIdx=i; bestDist=d; }
   }

   if(bestIdx<0)
   {
      zoneOut=""; strengthOut="";
      return false;
   }

   bool overlap=false;
   for(int j=0;j<10;j++)
   {
      if(j==bestIdx || levels[j]<=0) continue;
      if(MathAbs(levels[bestIdx]-levels[j]) <= tol) { overlap=true; break; }
   }

   zoneOut = types[bestIdx];
   strengthOut = overlap ? "強信號" : "普通信號";
   return true;
}

double ComputeTrendStrengthMA(double bid, double shortMA, double ema, string crossState,
                                double shortAngle, double emaSlopePct, string &judgeOut)
{
   double s = 0;
   s += (bid > shortMA) ? 1 : -1;
   s += (shortMA > ema) ? 1 : -1;
   if(crossState == "黃金交叉")      s += 2;
   else if(crossState == "死亡交叉") s -= 2;
   s += (shortAngle > 0) ? 1 : -1;
   s += (emaSlopePct > 0) ? 1 : -1;

   if(s >= 4)       judgeOut = "強力多頭";
   else if(s >= 1)  judgeOut = "偏多";
   else if(s <= -4) judgeOut = "強力空頭";
   else if(s <= -1) judgeOut = "偏空";
   else             judgeOut = "多空不明";

   return s;
}

datetime LastUnifiedCheckedBar = 0;

int ComputeVegasDirectionForTF_Ind(string sym, ENUM_TIMEFRAMES period)
{
   int longA=VegasLongAArr[ChartSymbolIdx], longB=VegasLongBArr[ChartSymbolIdx];
   int shortA=VegasShortAArr[ChartSymbolIdx], shortB=VegasShortBArr[ChartSymbolIdx];
   int filterP=VegasFilterArr[ChartSymbolIdx];
   double volTh=VegasVolThreshold;
   int volBars=VegasVolAvgBars, slopeLB=VegasSlopeLookback;

   int needBars = MathMax(longA,longB) + slopeLB + volBars + 10;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(sym, period, 0, needBars, rates);
   if(copied < needBars) return 0;

   double emaLA[], emaLB[], emaSA[], emaSB[], emaF[];
   if(CalcEMA(rates, copied, longA, emaLA)==0) return 0;
   if(CalcEMA(rates, copied, longB, emaLB)==0) return 0;
   if(CalcEMA(rates, copied, shortA, emaSA)==0) return 0;
   if(CalcEMA(rates, copied, shortB, emaSB)==0) return 0;
   if(CalcHMA(rates, copied, filterP, emaF)==0) return 0;

   int i = 1;
   if(i+slopeLB >= copied) return 0;

   double longUpperNow = MathMax(emaLA[i], emaLB[i]);
   double longLowerNow = MathMin(emaLA[i], emaLB[i]);
   double longUpperPrev = MathMax(emaLA[i+1], emaLB[i+1]);
   double longLowerPrev = MathMin(emaLA[i+1], emaLB[i+1]);
   double shortUpperNow = MathMax(emaSA[i], emaSB[i]);
   double shortLowerNow = MathMin(emaSA[i], emaSB[i]);

   double sumVol=0; int volCount=0;
   for(int k=1;k<=volBars && (i+k)<copied;k++){ sumVol += (double)rates[i+k].tick_volume; volCount++; }
   double avgVol = (volCount>0) ? sumVol/volCount : (double)rates[i].tick_volume;
   bool volOk = (avgVol>0 && rates[i].tick_volume > avgVol*volTh);

   double closeI = rates[i].close;

   double longUpperOld = MathMax(emaLA[i+slopeLB], emaLB[i+slopeLB]);
   double longLowerOld = MathMin(emaLA[i+slopeLB], emaLB[i+slopeLB]);
   bool crossUp   = (emaF[i+1] <= longLowerPrev) && (emaF[i] > longUpperNow);
   bool crossDown = (emaF[i+1] >= longUpperPrev) && (emaF[i] < longLowerNow);
   bool tunnelSlopeUp   = (longUpperNow-longUpperOld > 0) && (longLowerNow-longLowerOld > 0);
   bool tunnelSlopeDown = (longUpperNow-longUpperOld < 0) && (longLowerNow-longLowerOld < 0);
   bool pathB_bull = crossUp   && tunnelSlopeUp   && volOk;
   bool pathB_bear = crossDown && tunnelSlopeDown && volOk;

   bool longBullEst = closeI > longUpperNow;
   bool longBearEst = closeI < longLowerNow;
   bool touchedShort = false;
   for(int k=0;k<=2 && (i+k)<copied;k++)
   {
      double c = rates[i+k].close;
      double su = MathMax(emaSA[i+k], emaSB[i+k]);
      double sl = MathMin(emaSA[i+k], emaSB[i+k]);
      if(c<=su && c>=sl){ touchedShort=true; break; }
   }
   bool bounceUp   = (rates[i].close > rates[i+1].close) && (rates[i+1].close <= rates[i+2].close);
   bool bounceDown = (rates[i].close < rates[i+1].close) && (rates[i+1].close >= rates[i+2].close);
   bool pathA_bull = longBullEst && touchedShort && bounceUp   && volOk;
   bool pathA_bear = longBearEst && touchedShort && bounceDown && volOk;

   if(pathA_bull || pathB_bull) return 1;
   if(pathA_bear || pathB_bear) return -1;
   return 0;
}

int TaiMomentumP[SYMBOL_COUNT], TaiMAP[SYMBOL_COUNT], TaiFilterP[SYMBOL_COUNT];

void LoadTAIParams()
{
   for(int i=0;i<SYMBOL_COUNT;i++) { TaiMomentumP[i]=5; TaiMAP[i]=28; TaiFilterP[i]=50; }

   string lines[];
   if(!ReadUTF8FileLines("TAIParams.csv", lines))
   {
      Print("警告：讀不到TAIParams.csv，TAI暫用預設參數(5/28/50)");
      return;
   }
   for(int i=0;i<ArraySize(lines);i++)
   {
      string line = lines[i];
      if(StringLen(line)==0 || StringGetCharacter(line,0)=='#') continue;
      if(StringFind(line,"Symbol")>=0 && StringFind(line,"MomentumPeriod")>=0) continue;
      string parts[];
      if(StringSplit(line, ',', parts) < 4) continue;
      int idx=-1;
      for(int k=0;k<SYMBOL_COUNT;k++) if(Symbols[k]==parts[0]) { idx=k; break; }
      if(idx<0) continue;
      TaiMomentumP[idx]=(int)StringToInteger(parts[1]);
      TaiMAP[idx]=(int)StringToInteger(parts[2]);
      TaiFilterP[idx]=(int)StringToInteger(parts[3]);
   }
}

int ComputeTAIDirectionForTF_Ind(string sym, ENUM_TIMEFRAMES period)
{
   int momentumPeriod=TaiMomentumP[ChartSymbolIdx], maPeriod=TaiMAP[ChartSymbolIdx], filterPeriod=TaiFilterP[ChartSymbolIdx];
   int atrPeriod=14, volAvgPeriod=20;
   double responseBoost=0.35, bandLevelUp=80.0, bandLevelDown=20.0, atrMultiplier=1.0, volUpThreshold=1.2;

   int needBars = maPeriod + momentumPeriod + filterPeriod + volAvgPeriod + 10;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(sym, period, 0, needBars, rates);
   if(copied < needBars) return 0;

   double emaMA[];
   if(CalcEMA(rates, copied, maPeriod, emaMA)==0) return 0;

   double atrSeries[];
   ArrayResize(atrSeries, copied);
   double atrArr[];
   ArrayResize(atrArr, copied);
   for(int i=0;i<copied-1;i++)
   {
      double tr1 = rates[i].high-rates[i].low;
      double tr2 = MathAbs(rates[i].high-rates[i+1].close);
      double tr3 = MathAbs(rates[i].low-rates[i+1].close);
      atrArr[i] = MathMax(tr1, MathMax(tr2, tr3));
   }
   for(int i=0;i<copied;i++)
   {
      double s=0; int n=0;
      for(int k=0;k<atrPeriod && (i+k)<copied-1;k++){ s+=atrArr[i+k]; n++; }
      atrSeries[i] = (n>0) ? s/n : 0;
   }

   double fastAvg[];
   ArrayResize(fastAvg, copied);
   int emaMASize = ArraySize(emaMA);
   for(int i=0;i<copied-1;i++)
   {
      int i1 = (i<emaMASize)   ? i   : emaMASize-1;
      int i2 = (i+1<emaMASize) ? i+1 : emaMASize-1;
      fastAvg[i] = emaMA[i1] + responseBoost*(emaMA[i1]-emaMA[i2]);
   }
   fastAvg[copied-1] = emaMA[(copied-1<emaMASize) ? (copied-1) : (emaMASize-1)];

   int calcCount = filterPeriod + momentumPeriod + 6;
   double val[];
   ArrayResize(val, calcCount);
   for(int idx=0; idx<calcCount; idx++)
   {
      if(idx+momentumPeriod-1 >= copied) { val[idx]=0; continue; }
      double maxV=fastAvg[idx], minV=fastAvg[idx];
      for(int k=1;k<momentumPeriod;k++)
      {
         maxV = MathMax(maxV, fastAvg[idx+k]);
         minV = MathMin(minV, fastAvg[idx+k]);
      }
      double price = rates[idx].close;
      double direction = (fastAvg[idx] >= fastAvg[idx+1]) ? 1.0 : -1.0;
      val[idx] = (MathAbs(price)>0.0000001) ? 100.0*direction*(maxV-minV)/MathAbs(price) : 0.0;
   }

   int upBars=0, downBars=0;
   for(int b=0; b<5; b++)
   {
      int idx = b;
      if(idx+filterPeriod-1 >= calcCount) break;

      double valueMin=val[idx], valueMax=val[idx];
      for(int k=1;k<filterPeriod;k++)
      {
         valueMin = MathMin(valueMin, val[idx+k]);
         valueMax = MathMax(valueMax, val[idx+k]);
      }
      double range = MathMax(valueMax-valueMin, 0.0000001);
      double closeIdx = rates[idx].close;
      double atrRatio = (MathAbs(closeIdx)>0.0000001) ? atrSeries[idx]/MathAbs(closeIdx) : 0;
      double volatility = MathMin(0.20, atrRatio*atrMultiplier*10.0);
      double upperPercent = MathMin(95.0, bandLevelUp + volatility*25.0);
      double lowerPercent = MathMax(5.0, bandLevelDown - volatility*25.0);
      double levelUp = valueMin + range*upperPercent*0.01;
      double levelDn = valueMin + range*lowerPercent*0.01;

      bool rising = (val[idx] > val[idx+1]);
      bool falling = (val[idx] < val[idx+1]);
      double valcNow;
      if(val[idx]>levelUp && rising) valcNow=1.0;
      else if(val[idx]<levelDn && falling) valcNow=2.0;
      else valcNow=0.0;

      if(valcNow==1.0 && downBars==0) upBars++;
      else if(valcNow==2.0 && upBars==0) downBars++;
      else break;
   }

   long curVol = rates[0].tick_volume;
   double sumVol=0; int volCount=0;
   for(int k=1;k<=volAvgPeriod && k<copied;k++){ sumVol += (double)rates[k].tick_volume; volCount++; }
   double avgVol = (volCount>0) ? sumVol/volCount : (double)curVol;
   bool volOk = (avgVol>0 && curVol > avgVol*volUpThreshold);

   if(upBars>=1 && volOk) return 1;
   if(downBars>=1 && volOk) return -1;
   return 0;
}

void DetectVegasEntrySignals()
{
   datetime curH1Bar = iTime(_Symbol, PERIOD_H1, 0);
   if(curH1Bar == LastUnifiedCheckedBar) return;
   LastUnifiedCheckedBar = curH1Bar;

   int dirM5  = ComputeVegasDirectionForTF_Ind(_Symbol, PERIOD_M5);
   int dirM15 = ComputeVegasDirectionForTF_Ind(_Symbol, PERIOD_M15);
   int dirH1  = ComputeVegasDirectionForTF_Ind(_Symbol, PERIOD_H1);
   int dirTAI = ComputeTAIDirectionForTF_Ind(_Symbol, PERIOD_H1);
   GlobalVariableSet("EMALL_TAI_"+_Symbol, (double)dirTAI);

   int votesLong  = (dirM5==1?1:0)+(dirM15==1?1:0)+(dirH1==1?1:0)+(dirTAI==1?1:0);
   int votesShort = (dirM5==-1?1:0)+(dirM15==-1?1:0)+(dirH1==-1?1:0)+(dirTAI==-1?1:0);

   int finalDir = 0;
   if(votesLong>=2) finalDir=1;
   else if(votesShort>=2) finalDir=-1;
   if(finalDir==0) return;

   MqlRates r0[];
   ArraySetAsSeries(r0, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 1, r0) != 1) return;

   string tag = StringFormat("M5=%d M15=%d H1=%d TAI=%d", dirM5, dirM15, dirH1, dirTAI);
   DrawEntryMarker(r0[0].time, finalDir>0 ? r0[0].low : r0[0].high, finalDir>0, tag);
}

void DrawEntryMarker(datetime t, double price, bool isBull, string voteTag)
{
   string name = PFX + "Sig_" + IntegerToString((long)t) + "_" + (isBull?"B":"S");
   if(ObjectFind(0, name) >= 0) return;

   ObjectCreate(0, name, isBull ? OBJ_ARROW_UP : OBJ_ARROW_DOWN, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBull ? clrLime : clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   string txtName = name + "_Txt";
   double txtPrice = isBull ? price - (SymbolInfoDouble(_Symbol,SYMBOL_POINT)*300) : price + (SymbolInfoDouble(_Symbol,SYMBOL_POINT)*300);
   if(ObjectFind(0, txtName) < 0)
   {
      ObjectCreate(0, txtName, OBJ_TEXT, 0, t, txtPrice);
      ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, txtName, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, txtName, OBJPROP_FONT, "Arial Bold");
   }
   ObjectSetString(0, txtName, OBJPROP_TEXT, voteTag);
   ObjectSetInteger(0, txtName, OBJPROP_COLOR, isBull ? clrLime : clrRed);
}
