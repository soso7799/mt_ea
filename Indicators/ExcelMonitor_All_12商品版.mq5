//+------------------------------------------------------------------+
//| ExcelMonitor_All.mq5  (整合版：CSV輸出 + 圖表視覺化 二合一)       |
//|                                                                    |
//| 功能：                                                            |
//|  A. 背景幫12大商品寫 Excel_Monitor.csv 給 Excel 巨集讀取           |
//|  B. 在掛載的這張圖表上畫：Vegas雙通道、支撐壓力、成交量、進場箭頭    |
//|                                                                    |
//| 使用方式：只需要掛在「一張」圖表上，A功能就會自動跑全部12個商品      |
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
#property indicator_color1  clrDeepSkyBlue,clrDeepSkyBlue
#property indicator_label2  "短隧道(34/55)"
#property indicator_type2   DRAW_FILLING
#property indicator_color2  clrOrange,clrOrange
#property indicator_label3  "過濾線"
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
input string VegasFilterPeriods = "100,100,100,100,100,100,100,100,100,100,100,100"; // 過濾線週期(每商品一個，指數的建議用VegasFilterParams.csv裡回測出來的最佳值手動填入)

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

#define SYMBOL_COUNT 12
string Symbols[SYMBOL_COUNT] = {"EURUSD","GBPUSD","USDJPY","USDCAD","AUDUSD","NZDUSD","USDCHF",
                                 "US30.cash","US500.cash","US100.cash","USDCNH","JP225.cash"};
string CsvFileName = "Excel_Monitor.csv";

string BTN_NAME;
string LastCsvUpdateTime = "尚未更新";

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
//+------------------------------------------------------------------+
string PeriodToTFString(ENUM_TIMEFRAMES p)
{
   switch(p)
   {
      case PERIOD_D1:  return "D1";
      case PERIOD_H4:  return "H4";
      case PERIOD_H1:  return "H1";
      case PERIOD_M15: return "M15";
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
   if(tfStr == "") return; // 非D1/H4/H1/M15週期(例如M5)沒有對應優化資料，跳過

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
         " 的優化資料，維持用輸入參數/經典值(可能還沒針對這個週期跑過優化，或這不是4個交易指數之一)");
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
      ObjectSetInteger(0, BTN_NAME, OBJPROP_XSIZE, 200);
      ObjectSetInteger(0, BTN_NAME, OBJPROP_YSIZE, 28);
      ObjectSetString(0, BTN_NAME, OBJPROP_TEXT, "手動更新CSV給Excel");
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
      bool okLocal  = WriteAllSymbolsCsvTo(false);
      bool okCommon = WriteAllSymbolsCsvTo(true);
      if(okLocal || okCommon)
      {
         // 兩個資料夾都寫一份，只要其中一個成功就算完成；Experts記錄檔會分別
         // 顯示兩邊各自成功/失敗，方便對照Excel巨集實際連的是哪一個路徑。
         string where = (okLocal && okCommon) ? "終端機私有資料夾+共用資料夾"
                        : okLocal ? "僅終端機私有資料夾(共用資料夾失敗)"
                                  : "僅共用資料夾(終端機私有資料夾失敗)";
         LastCsvUpdateTime = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + " ["+where+"]";
         Print("手動更新CSV完成：", LastCsvUpdateTime);
      }
      else
      {
         // 之前這裡不管寫檔成功或失敗都照樣顯示「完成」，導致CSV其實沒更新
         // 卻誤以為已經更新。現在兩個資料夾都失敗才會顯示錯誤(常見原因：
         // Excel還開著那個CSV檔案，把它鎖住了，MT5沒辦法覆寫)。
         LastCsvUpdateTime = "更新失敗(錯誤:"+IntegerToString(GetLastError())+")";
         Print("手動更新CSV失敗！錯誤代碼：", GetLastError(), "（常見原因：Excel還開著Excel_Monitor.csv，請先關閉該檔案再試一次）");
      }
      UpdateChartVisuals(); // 立即刷新面板文字，不用等下一次Timer(最多5秒)才看得到結果
      ChartRedraw(0);
   }
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
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
   double aFilter = 2.0/(filterPeriod+1.0);

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
         FilterBuf[i] = close[i]*aFilter + FilterBuf[i-1]*(1-aFilter);
      }
   }
   return(rates_total);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateChartVisuals(); // 只有圖表線條/文字自動更新，CSV改成手動按按鈕才寫
   DetectVegasEntrySignals(); // 路徑A(順勢拉回)+路徑B(轉折啟動)訊號偵測與圖表標記
}

//====================================================================
// A. CSV 輸出(8大商品)
//====================================================================
// 這支indicator讀TAIParams.csv/VegasFilterParams.csv/VegasDualPathParams.csv時都是
// 從FILE_COMMON(共用資料夾)讀的，但先前寫Excel_Monitor.csv卻只寫終端機自己的私有
// 資料夾(MQL5\Files)，兩邊路徑不一致。如果Excel巨集是連到共用資料夾(多帳號/多台
// 終端機共用同一份Excel檔時的常見作法)，MT5這裡其實每次都寫成功，只是Excel根本
// 沒看那個資料夾，才會一直「按了沒反應」。改成兩個資料夾都寫一份，不管Excel巨集
// 連的是哪一個路徑都吃得到最新資料：
//   終端機私有資料夾： (雙擊「檔案」→「開啟資料夾」)\MQL5\Files\Excel_Monitor.csv
//   共用資料夾：       %APPDATA%\MetaQuotes\Terminal\Common\Files\Excel_Monitor.csv
bool WriteAllSymbolsCsvTo(bool useCommon)
{
   // 加上FILE_SHARE_READ|FILE_SHARE_WRITE：如果Excel那邊用共用模式打開這個檔案在看，
   // MT5這裡還是能覆寫，不會因為檔案被Excel佔用就整個失敗。
   int flags = FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(useCommon) flags |= FILE_COMMON;

   int handle = FileOpen(CsvFileName, flags, ",");
   if(handle==INVALID_HANDLE)
   {
      Print("無法開啟檔案寫入(", useCommon?"共用資料夾":"終端機私有資料夾", "): ",
            CsvFileName, " 錯誤:", GetLastError());
      return false;
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
   return true;
}

void WriteSymbolRow(int handle, string sym, int shortPeriod, int longPeriod)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int needBars = MathMax(longPeriod*4, VolumeAvgBars) + SlopeLookback + 10;
   int copied = CopyRates(sym, PERIOD_M5, 0, needBars, rates);
   if(copied < longPeriod+SlopeLookback+2)
   {
      FileWrite(handle, sym, "", "", "", "", "", "", "", "", "", "", "", "", "", "",
                 "", "", "", "", "", "", "", "資料不足", "", "", "資料不足", "", "", "資料不足",
                 "", "觀望(資料不足)", "", "資料不足",
                 TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
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
   // 第一層貢獻：Bid若貼近「有效」的支撐/壓力位，給予對應方向的偏多/偏空加成；
   //            優先看近期支撐壓力(較即時)，貼不到才退而看週線支撐壓力。
   double srBias = 0;
   double srTol = TouchTolPoints * pt;
   if(MathAbs(bid - recentSupport) <= srTol*2 && supportValid=="有效")           srBias = 1.0;
   else if(MathAbs(bid - recentResistance) <= srTol*2 && resistanceValid=="有效") srBias = -1.0;
   else if(MathAbs(bid - weekSupport) <= srTol*2 && weekSupport>0)               srBias = 0.5;
   else if(MathAbs(bid - weekResistance) <= srTol*2 && weekResistance>0)         srBias = -0.5;

   // 第三層貢獻：用成交量狀態當作信心倍率，放量加強訊號、縮量打折扣
   double volMult = (volState=="放量") ? 1.3 : (volState=="縮量") ? 0.7 : 1.0;

   double combinedScore = (weightedScore + srBias*0.5) * volMult;

   string finalSignal;
   if(combinedScore >= 1.3)        finalSignal = "強勢多";
   else if(combinedScore >= 0.4)   finalSignal = "偏多";
   else if(combinedScore <= -1.3)  finalSignal = "強勢空";
   else if(combinedScore <= -0.4)  finalSignal = "偏空";
   else                            finalSignal = "震盪";

   //====================================================================
   // 作戰方式三個關鍵點：
   //  1. 價格貼近「2個以上關鍵位重疊」的位置 + 成交量不等於均量(放量/縮量) + 近3根K棒出現經典反轉型態
   //  2. 依三層合成的多空方向(finalSignal) + K棒型態，決定要不要進場
   //  3. EMA斜度優先判斷方向是否允許進場(逆勢不建議進場，只當觀望)
   //====================================================================
   string candlePattern = DetectCandlePattern(rates, copied);

   string zoneType = "";
   string signalStrength = ""; // "強信號"(有重疊) 或 "普通信號"(只貼近單一關鍵位)
   bool hasKeyLevel = CheckKeyLevelConfluence(bid, weekSupport, weekResistance, recentSupport, recentResistance,
                                                asiaLow, asiaHigh, euroLow, euroHigh, usLow, usHigh,
                                                srTol, zoneType, signalStrength);

   bool volAnomaly = (volState=="放量" || volState=="縮量");

   bool bullPattern = (candlePattern=="看漲吞噬" || candlePattern=="看漲針線" || candlePattern=="晨星(3根反轉)");
   bool bearPattern = (candlePattern=="看跌吞噬" || candlePattern=="看跌針線" || candlePattern=="昏星(3根反轉)");
   // 十字星本身不分方向，只代表猶豫/可能反轉，交由所在區位(支撐/壓力)決定要對應哪個方向

   bool triggerLong  = hasKeyLevel && zoneType=="支撐" && volAnomaly &&
                        (bullPattern || (candlePattern=="十字星"));
   bool triggerShort = hasKeyLevel && zoneType=="壓力" && volAnomaly &&
                        (bearPattern || (candlePattern=="十字星"));

   // 關鍵點3：EMA斜度優先判斷，逆勢不建議進場
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

   // 亞歐美盤高低已不在圖表上畫出來(GetSessionRange還是保留給後台WriteSymbolRow的
   // 支撐壓力關鍵位重疊判斷用，只是不在這裡拿來畫線/顯示文字)

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
   ObjectSetString(0, PFX+"CsvTime", OBJPROP_TEXT, "CSV上次更新: "+LastCsvUpdateTime);
   ObjectSetString(0, PFX+"VolCur",  OBJPROP_TEXT, "目前量: "+IntegerToString((int)curVol));
   ObjectSetString(0, PFX+"VolAvg",  OBJPROP_TEXT, "平均量: "+DoubleToString(avgVol,1));
   ObjectSetInteger(0, PFX+"VolStat", OBJPROP_COLOR, volColor);
   ObjectSetString(0, PFX+"VolStat", OBJPROP_TEXT, "量能: "+volState);

   UpdatePositionStatusPanel();
   UpdateTAIStatePanel();

   ChartRedraw(0);
}

//====================================================================
// 11大指標三分類加權評分(跟 gordon_full_analysis.py 的分類權重一致)
//   趨勢型(MA/MACD/布林/肯特納)      權重45%
//   震盪型(RSI/KD/威廉%R/CCI/MTM)   權重35%(組內先平均，避免5個高相關指標灌票)
//   其他(PSY/BIAS)                  權重20%
// 每個指標回傳 -2~+2 分級訊號，回傳值為加權後的總分(約-2.0~+2.0)
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

   // ---- 趨勢型 45% ----
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

   // ---- 震盪型 35% ----
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

   // ---- 其他 20% ----
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



//====================================================================
// K棒型態辨識(最近一根已收完的K棒 rates[1]，對照前一根 rates[2] 判斷吞噬)
// 回傳：看漲吞噬 / 看跌吞噬 / 看漲針線 / 看跌針線 / 十字星 / 無明顯型態
//====================================================================
string DetectCandlePattern(const MqlRates &rates[], int copied)
{
   if(copied < 6) return "資料不足";

   MqlRates c1 = rates[1]; // 最新已收完(第3根)
   MqlRates c2 = rates[2]; // 中間(第2根)
   MqlRates c3 = rates[3]; // 最早(第1根)

   double body1 = MathAbs(c1.close - c1.open);
   double body2 = MathAbs(c2.close - c2.open);
   double body3 = MathAbs(c3.close - c3.open);

   bool bull1 = c1.close > c1.open, bear1 = c1.close < c1.open;
   bool bull3 = c3.close > c3.open, bear3 = c3.close < c3.open;

   double mid3 = (c3.open + c3.close) / 2.0;

   // 晨星(看漲反轉，3根)：第1根長黑棒 → 第2根小實體(猶豫) → 第3根長紅棒收回第1根實體中點以上
   if(bear3 && body3 > 0 && body2 <= body3*0.35 && bull1 && c1.close > mid3)
      return "晨星(3根反轉)";

   // 昏星(看跌反轉，3根)：第1根長紅棒 → 第2根小實體 → 第3根長黑棒收到第1根實體中點以下
   if(bull3 && body3 > 0 && body2 <= body3*0.35 && bear1 && c1.close < mid3)
      return "昏星(3根反轉)";

   // 找不到3根排列時，退回2根/1根的備案判斷
   double range1 = c1.high - c1.low;
   if(range1 <= 0) return "無明顯型態";

   double upperWick1 = c1.high - MathMax(c1.open, c1.close);
   double lowerWick1 = MathMin(c1.open, c1.close) - c1.low;

   bool bull2 = c2.close > c2.open;
   bool bear2 = c2.close < c2.open;

   // 吞噬：目前這根實體完全包住前一根實體，且方向相反
   if(bear2 && bull1 && c1.open <= c2.close && c1.close >= c2.open)
      return "看漲吞噬";
   if(bull2 && bear1 && c1.open >= c2.close && c1.close <= c2.open)
      return "看跌吞噬";

   // 十字星：實體極小(不到全距的10%)，判斷優先於針線
   if(body1 <= range1*0.1)
      return "十字星";

   // 針線(Pin Bar)：長下影線+小實體在上緣=看漲；長上影線+小實體在下緣=看跌
   if(lowerWick1 >= body1*2.0 && lowerWick1 >= range1*0.5 && upperWick1 <= body1*0.5)
      return "看漲針線";
   if(upperWick1 >= body1*2.0 && upperWick1 >= range1*0.5 && lowerWick1 <= body1*0.5)
      return "看跌針線";

   return "無明顯型態";
}

//====================================================================
// 關鍵位判斷(分級版)：貼近任一關鍵位就算「普通信號」，
// 如果貼近的那個位置又跟另一個關鍵位彼此重疊，升級為「強信號」
// zoneOut 回傳 "支撐" 或 "壓力"，strengthOut 回傳 "強信號" 或 "普通信號"
//====================================================================
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


//====================================================================
// 純MA家族趨勢強度(第二層原始設計版)：只用短MA/長MA/EMA/交叉/斜度/排列/Bid位置，
// 不含RSI/KD等11指標。黃金死亡交叉權重加倍，因為代表「趨勢即將發動」。
// 回傳分數(-6~+6)，judgeOut回傳5級文字判定。
//====================================================================
double ComputeTrendStrengthMA(double bid, double shortMA, double ema, string crossState,
                                double shortAngle, double emaSlopePct, string &judgeOut)
{
   double s = 0;
   s += (bid > shortMA) ? 1 : -1;              // Bid相對短MA位置
   s += (shortMA > ema) ? 1 : -1;              // 均線排列(短MA vs EMA)
   if(crossState == "黃金交叉")      s += 2;    // 交叉權重加倍：趨勢即將發動
   else if(crossState == "死亡交叉") s -= 2;
   s += (shortAngle > 0) ? 1 : -1;             // 短MA角度方向
   s += (emaSlopePct > 0) ? 1 : -1;            // EMA角度方向

   if(s >= 4)       judgeOut = "強力多頭";
   else if(s >= 1)  judgeOut = "偏多";
   else if(s <= -4) judgeOut = "強力空頭";
   else if(s <= -1) judgeOut = "偏空";
   else             judgeOut = "多空不明";

   return s;
}


//====================================================================
// 雙路徑進場訊號偵測(純觀察用，畫在圖表上，不下單)
// 路徑A(順勢拉回)：大格局站穩長隧道一側 + 價格拉回碰到短隧道範圍 + 短期動能反轉 + 帶量
// 路徑B(轉折啟動)：過濾線帶量穿越長隧道(整組穿過，不是碰一下) + 長隧道本身轉為同向上揚/下彎
//====================================================================
datetime LastUnifiedCheckedBar = 0;

//+------------------------------------------------------------------+
//| 跟ExcelMonitor_TradingEA完全一致的方向計算(M5/M15/H1用Vegas路徑A/B，
//| 另外+TAI(H1))，只算「最新已收完那根K棒」，回傳+1多/-1空/0無訊號     |
//+------------------------------------------------------------------+
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
   if(CalcEMA(rates, copied, filterP, emaF)==0) return 0;

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

//+------------------------------------------------------------------+
//| TAI動能方向(跟EA的ComputeTAIDirectionForTF完全一致)，用H1當代表週期  |
//+------------------------------------------------------------------+
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
   for(int i=0;i<copied-1;i++)
      fastAvg[i] = emaMA[i] + responseBoost*(emaMA[i]-emaMA[i+1]);
   fastAvg[copied-1] = emaMA[copied-1];

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

//+------------------------------------------------------------------+
//| 跟EA完全一致的2/4投票判斷：M5+M15+H1(Vegas) + TAI(H1)，畫在圖表上   |
//+------------------------------------------------------------------+
void DetectVegasEntrySignals()
{
   datetime curH1Bar = iTime(_Symbol, PERIOD_H1, 0);
   if(curH1Bar == LastUnifiedCheckedBar) return; // H1還沒收出新K棒，不用重算(這套系統以H1步調為主)
   LastUnifiedCheckedBar = curH1Bar;

   int dirM5  = ComputeVegasDirectionForTF_Ind(_Symbol, PERIOD_M5);
   int dirM15 = ComputeVegasDirectionForTF_Ind(_Symbol, PERIOD_M15);
   int dirH1  = ComputeVegasDirectionForTF_Ind(_Symbol, PERIOD_H1);
   int dirTAI = ComputeTAIDirectionForTF_Ind(_Symbol, PERIOD_H1);

   int votesLong  = (dirM5==1?1:0)+(dirM15==1?1:0)+(dirH1==1?1:0)+(dirTAI==1?1:0);
   int votesShort = (dirM5==-1?1:0)+(dirM15==-1?1:0)+(dirH1==-1?1:0)+(dirTAI==-1?1:0);

   int finalDir = 0;
   if(votesLong>=2) finalDir=1;
   else if(votesShort>=2) finalDir=-1;
   if(finalDir==0) return; // 沒有湊到2/4，不畫箭頭(EA這輪也不會下單)

   MqlRates r0[];
   ArraySetAsSeries(r0, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 1, r0) != 1) return;

   string tag = StringFormat("M5=%d M15=%d H1=%d TAI=%d", dirM5, dirM15, dirH1, dirTAI);
   DrawEntryMarker(r0[0].time, finalDir>0 ? r0[0].low : r0[0].high, finalDir>0, tag);

   // 同步畫出這筆訊號的止損/止盈範圍(用M5的ATR，跟EA下單邏輯用的距離公式一致)
   MqlRates atrRates[];
   ArraySetAsSeries(atrRates, true);
   int atrCopied = CopyRates(_Symbol, PERIOD_M5, 0, ATRPeriod+5, atrRates);
   if(atrCopied >= ATRPeriod+2)
   {
      double atrNow = CalcATR(atrRates, atrCopied, ATRPeriod);
      double entry = r0[0].close;
      double slPrice = entry - finalDir*atrNow*ATRMultiplier;
      double tpPrice = entry + finalDir*atrNow*ATRMultiplier*2.0; // 維持1:2風報比(SL用ATRMultiplier、TP用2倍)
      DrawSLTPLines(entry, slPrice, tpPrice);
   }
}

//+------------------------------------------------------------------+
//| 畫出最新一筆訊號的進場/止損/止盈水平線(每次新訊號會覆蓋掉舊的)        |
//+------------------------------------------------------------------+
void DrawSLTPLines(double entry, double sl, double tp)
{
   CreateHLine(PFX+"SigEntry", clrWhite, STYLE_SOLID);
   CreateHLine(PFX+"SigSL",    clrRed,   STYLE_DASH);
   CreateHLine(PFX+"SigTP",    clrLime,  STYLE_DASH);
   MoveHLine(PFX+"SigEntry", entry);
   MoveHLine(PFX+"SigSL", sl);
   MoveHLine(PFX+"SigTP", tp);

   EnsureTextObj(PFX+"Txt_SigEntry", clrWhite);
   EnsureTextObj(PFX+"Txt_SigSL", clrRed);
   EnsureTextObj(PFX+"Txt_SigTP", clrLime);
   datetime labelT = TimeCurrent();
   ObjectSetString(0, PFX+"Txt_SigEntry", OBJPROP_TEXT, "進場 "+DoubleToString(entry,_Digits));
   ObjectSetString(0, PFX+"Txt_SigSL", OBJPROP_TEXT, "止損 "+DoubleToString(sl,_Digits));
   ObjectSetString(0, PFX+"Txt_SigTP", OBJPROP_TEXT, "止盈 "+DoubleToString(tp,_Digits));
   ObjectMove(0, PFX+"Txt_SigEntry", 0, labelT, entry);
   ObjectMove(0, PFX+"Txt_SigSL", 0, labelT, sl);
   ObjectMove(0, PFX+"Txt_SigTP", 0, labelT, tp);
}

//+------------------------------------------------------------------+
//| 在圖表上畫進場訊號箭頭+文字標記(用時間當物件名稱的一部分，避免重複畫)|
//+------------------------------------------------------------------+
void DrawEntryMarker(datetime t, double price, bool isBull, string voteTag)
{
   string name = PFX + "Sig_" + IntegerToString((long)t) + "_" + (isBull?"B":"S");
   if(ObjectFind(0, name) >= 0) return; // 已經畫過這根K棒的訊號，不重複畫

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

//+------------------------------------------------------------------+
//| 目前倉位狀態面板：顯示這個商品現在有沒有倉位、方向、進場價、浮動盈虧  |
//+------------------------------------------------------------------+
void UpdatePositionStatusPanel()
{
   string name1 = PFX+"PosStat1", name2 = PFX+"PosStat2";
   int y1 = VolPanelY+(LabelFontSize+8)*4+40;
   int y2 = y1 + LabelFontSize+8;

   if(!PositionSelect(_Symbol))
   {
      EnsureCornerLabel(name1, VolPanelX, y1, clrGray);
      ObjectSetString(0, name1, OBJPROP_TEXT, "目前倉位：無");
      if(ObjectFind(0,name2)>=0) ObjectDelete(0,name2);
      return;
   }

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double curPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   double profit = PositionGetDouble(POSITION_PROFIT);
   double lots = PositionGetDouble(POSITION_VOLUME);
   bool isBuy = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   color pnlColor = (profit>=0) ? clrLime : clrRed;

   EnsureCornerLabel(name1, VolPanelX, y1, isBuy?clrLime:clrRed);
   ObjectSetString(0, name1, OBJPROP_TEXT,
      "目前倉位："+(isBuy?"多":"空")+" "+DoubleToString(lots,2)+"手 進場價"+DoubleToString(entry,_Digits));

   EnsureCornerLabel(name2, VolPanelX, y2, pnlColor);
   ObjectSetInteger(0, name2, OBJPROP_COLOR, pnlColor);
   ObjectSetString(0, name2, OBJPROP_TEXT,
      "現價"+DoubleToString(curPrice,_Digits)+"  浮動盈虧："+DoubleToString(profit,2));
}

//+------------------------------------------------------------------+
//| TAI市場狀態文字(市場型態+建議)，整合進主圖面板，不用另外掛TAI指標    |
//+------------------------------------------------------------------+
void UpdateTAIStatePanel()
{
   int momentumPeriod=TaiMomentumP[ChartSymbolIdx], maPeriod=TaiMAP[ChartSymbolIdx], filterPeriod=TaiFilterP[ChartSymbolIdx];
   double responseBoost=0.35, bandLevelUp=80.0, bandLevelDown=20.0, atrMultiplier=1.0;
   int volAvgPeriod=20; double volUpThreshold=1.2;

   int needBars = maPeriod + momentumPeriod + filterPeriod + volAvgPeriod + 10;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_H1, 0, needBars, rates);

   string stateTxt = "TAI市場型態：資料不足";
   string adviceTxt = "";
   color stateColor = clrGray;

   if(copied >= needBars)
   {
      double emaMA[];
      if(CalcEMA(rates, copied, maPeriod, emaMA) > 0)
      {
         double fastAvg[];
         ArrayResize(fastAvg, copied);
         for(int i=0;i<copied-1;i++) fastAvg[i] = emaMA[i] + responseBoost*(emaMA[i]-emaMA[i+1]);
         fastAvg[copied-1] = emaMA[copied-1];

         int calcCount = filterPeriod + momentumPeriod + 6;
         double val[];
         ArrayResize(val, calcCount);
         for(int idx=0; idx<calcCount; idx++)
         {
            if(idx+momentumPeriod-1 >= copied) { val[idx]=0; continue; }
            double maxV=fastAvg[idx], minV=fastAvg[idx];
            for(int k=1;k<momentumPeriod;k++){ maxV=MathMax(maxV,fastAvg[idx+k]); minV=MathMin(minV,fastAvg[idx+k]); }
            double price = rates[idx].close;
            double direction = (fastAvg[idx]>=fastAvg[idx+1]) ? 1.0 : -1.0;
            val[idx] = (MathAbs(price)>0.0000001) ? 100.0*direction*(maxV-minV)/MathAbs(price) : 0.0;
         }

         int upBars=0, downBars=0;
         for(int b=0; b<5; b++)
         {
            int idx=b;
            if(idx+filterPeriod-1 >= calcCount) break;
            double valueMin=val[idx], valueMax=val[idx];
            for(int k=1;k<filterPeriod;k++){ valueMin=MathMin(valueMin,val[idx+k]); valueMax=MathMax(valueMax,val[idx+k]); }
            double range = MathMax(valueMax-valueMin, 0.0000001);
            double atrN = CalcATR(rates, copied, 14);
            double atrRatio = (MathAbs(rates[idx].close)>0.0000001) ? atrN/MathAbs(rates[idx].close) : 0;
            double volatility = MathMin(0.20, atrRatio*atrMultiplier*10.0);
            double upperPercent = MathMin(95.0, bandLevelUp+volatility*25.0);
            double lowerPercent = MathMax(5.0, bandLevelDown-volatility*25.0);
            double levelUp = valueMin+range*upperPercent*0.01;
            double levelDn = valueMin+range*lowerPercent*0.01;
            bool rising=(val[idx]>val[idx+1]), falling=(val[idx]<val[idx+1]);
            double valc;
            if(val[idx]>levelUp && rising) valc=1.0;
            else if(val[idx]<levelDn && falling) valc=2.0;
            else valc=0.0;
            if(valc==1.0 && downBars==0) upBars++;
            else if(valc==2.0 && upBars==0) downBars++;
            else break;
         }

         long curVol=rates[0].tick_volume; double sumVol=0; int volCount=0;
         for(int k=1;k<=volAvgPeriod && k<copied;k++){ sumVol+=(double)rates[k].tick_volume; volCount++; }
         double avgVol=(volCount>0)?sumVol/volCount:(double)curVol;
         bool volOk=(avgVol>0 && curVol>avgVol*volUpThreshold);
         string volTag = volOk ? "(有量能確認)" : "(量能不足)";

         if(upBars>=2){ stateTxt="TAI：多頭動能延續"+volTag; adviceTxt=volOk?"避免逆勢做空":"訊號打折"; stateColor=volOk?clrDeepSkyBlue:clrGray; }
         else if(downBars>=2){ stateTxt="TAI：空頭動能延續"+volTag; adviceTxt=volOk?"避免逆勢做多":"訊號打折"; stateColor=volOk?clrTomato:clrGray; }
         else if(upBars==1){ stateTxt="TAI：多頭動能啟動"+volTag; adviceTxt="等待收盤確認"; stateColor=volOk?clrLimeGreen:clrGray; }
         else if(downBars==1){ stateTxt="TAI：空頭動能啟動"+volTag; adviceTxt="等待收盤確認"; stateColor=volOk?clrOrange:clrGray; }
         else { stateTxt="TAI：橫盤震盪"; adviceTxt="等待方向與動能同步"; stateColor=clrSilver; }
      }
   }

   int y1 = VolPanelY+(LabelFontSize+8)*6+50;
   EnsureCornerLabel(PFX+"TaiState", VolPanelX, y1, stateColor);
   EnsureCornerLabel(PFX+"TaiAdvice", VolPanelX, y1+LabelFontSize+8, clrSilver);
   ObjectSetInteger(0, PFX+"TaiState", OBJPROP_COLOR, stateColor);
   ObjectSetString(0, PFX+"TaiState", OBJPROP_TEXT, stateTxt);
   ObjectSetString(0, PFX+"TaiAdvice", OBJPROP_TEXT, adviceTxt);
}
