//+------------------------------------------------------------------+
//|  MultiSymbol_TAI_Breakout_Panel.mq5                              |
//|  純觀察指標，不下單。在「任一張」圖表手動掛上（主控版），        |
//|  OnInit() 會自動掃描你已開啟的其他圖表分頁，只要商品在監控清單   |
//|  內，就用 ChartIndicatorAdd() 自動把「畫箭頭版」貼上去——不用你  |
//|  自己一張一張手動掛。                                            |
//|                                                                    |
//|  每張圖各自畫箭頭：TAI動能方向 + 關卡突破方向 同向時才畫，       |
//|  不顯示文字面板。                                                 |
//+------------------------------------------------------------------+
#property copyright "Multi-Symbol auto-deploy observation indicator — no trading actions"
#property version   "2.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "多方共振"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDeepSkyBlue
#property indicator_width1  2

#property indicator_label2  "空方共振"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrTomato
#property indicator_width2  2

// ⚠️ 這個一定要放第一個 input，才能用 iCustom() 傳參數關掉子版的自動部署，
// 避免子版自己又去掃描開新的、造成無限遞迴貼指標。
input bool   Inp_AutoDeploy      = true;   // 主控版=true；子版由程式自動帶入false，不要手動改

input group "=== 監控商品清單（用於判斷要不要自動部署到某張圖）==="
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
// ⚠️ MQL5 FileOpen() 沙盒限制，不能讀 D:\ 這種磁碟機絕對路徑！
// 只能讀 <終端機資料目錄>\MQL5\Files\ 底下的檔案（Inp_UseCommonFiles=false）
// 或 \MQL5\Files\Common\ 底下（Inp_UseCommonFiles=true）。
// 「檔案」→「開啟資料目錄」找到路徑，把 session_levels.csv 複製一份放進去。
input string Inp_LevelsCsvFile  = "session_levels.csv";
input bool   Inp_UseCommonFiles = false;

input group "=== TAI 參數（比照 TAI_Color_Panel_Optimized.mq5 預設）==="
input int    Inp_TaiPeriod     = 5;
input int    Inp_MaPeriod      = 28;
input double Inp_ResponseBoost = 0.35;
input int    Inp_FlPeriod      = 50;
input double Inp_FlLevelUp     = 80.0;
input double Inp_FlLevelDown   = 20.0;
input int    Inp_AtrPeriod     = 14;
input double Inp_AtrMultiplier = 1.0;

input group "=== 箭頭 ==="
input int    Inp_ArrowOffsetPoints = 30;
input bool   Inp_EnableAlert       = true;

input group "=== 關卡水平線 ==="
// 預設關閉：你已經有 YesterdayHiL_Autoadjust 在畫同樣的水平線，
// 兩個一起開會疊線。如果某些圖表沒裝那支，可以自己開這裡當替代。
input bool   Inp_ShowLevelLines  = false;
input int    Inp_LineRefreshSec  = 60;
input color  Inp_ColorPrevHigh   = clrRed;
input color  Inp_ColorPrevLow    = clrRed;
input color  Inp_ColorUsHigh     = clrOrange;
input color  Inp_ColorUsLow      = clrOrange;
input color  Inp_ColorEuroHigh   = clrYellow;
input color  Inp_ColorEuroLow    = clrYellow;
input color  Inp_ColorAsianHigh  = clrDodgerBlue;
input color  Inp_ColorAsianLow   = clrDodgerBlue;

#define SYM_COUNT 11
#define IND_SHORTNAME "MSTAI_ArrowSignal"

double BullBuffer[];
double BearBuffer[];

int    g_maHandle  = INVALID_HANDLE;
int    g_atrHandle = INVALID_HANDLE;
double g_val[];       // TAI 值序列（跟 rates_total 對齊）
double g_fastAvg[];
datetime g_lastAlertBull = 0;
datetime g_lastAlertBear = 0;

//+------------------------------------------------------------------+
//| 監控清單                                                          |
//+------------------------------------------------------------------+
bool IsWatchedSymbol(const string sym)
{
   string list[SYM_COUNT] = {Inp_Sym1,Inp_Sym2,Inp_Sym3,Inp_Sym4,Inp_Sym5,
                              Inp_Sym6,Inp_Sym7,Inp_Sym8,Inp_Sym9,Inp_Sym10,Inp_Sym11};
   for(int i=0;i<SYM_COUNT;i++)
      if(list[i] == sym) return true;
   return false;
}

//+------------------------------------------------------------------+
//| 自動部署：掃描已開啟的其他圖表，貼上「子版」（Inp_AutoDeploy=false）|
//+------------------------------------------------------------------+
void AutoDeployToOtherCharts()
{
   long thisChart = ChartID();
   long chart = ChartFirst();

   while(chart >= 0)
   {
      if(chart != thisChart)
      {
         string sym = ChartSymbol(chart);

         if(IsWatchedSymbol(sym))
         {
            // 檢查這張圖是不是已經掛過本指標了，避免重複貼
            bool already = false;
            int total = ChartIndicatorsTotal(chart, 0);
            for(int i=0;i<total;i++)
            {
               if(ChartIndicatorName(chart, 0, i) == IND_SHORTNAME)
               {
                  already = true;
                  break;
               }
            }

            if(!already)
            {
               // 注意：iCustom() 的 PERIOD_CURRENT 指的是「執行這段程式碼的圖表」
               // （也就是主控版所在的那張圖）的週期，不是目標圖表的週期！
               // 要用 ChartPeriod(chart) 明確取得目標圖表自己的週期，否則子版
               // 會全部套用主控版的週期，跟目標圖表顯示的K棒週期對不起來。
               ENUM_TIMEFRAMES targetTf = (ENUM_TIMEFRAMES)ChartPeriod(chart);
               int h = iCustom(sym, targetTf, "MultiSymbol_TAI_Breakout_Panel",
                                false, // Inp_AutoDeploy=false，子版不再往外部署
                                Inp_Sym1,Inp_Sym2,Inp_Sym3,Inp_Sym4,Inp_Sym5,
                                Inp_Sym6,Inp_Sym7,Inp_Sym8,Inp_Sym9,Inp_Sym10,Inp_Sym11,
                                Inp_LevelsCsvFile, Inp_UseCommonFiles,
                                Inp_TaiPeriod, Inp_MaPeriod, Inp_ResponseBoost,
                                Inp_FlPeriod, Inp_FlLevelUp, Inp_FlLevelDown,
                                Inp_AtrPeriod, Inp_AtrMultiplier,
                                Inp_ArrowOffsetPoints, Inp_EnableAlert);

               if(h != INVALID_HANDLE)
               {
                  ChartIndicatorAdd(chart, 0, h);
                  PrintFormat("MultiSymbol_TAI_Breakout_Panel: 自動部署到 %s", sym);
               }
               else
                  PrintFormat("MultiSymbol_TAI_Breakout_Panel: %s 自動部署失敗 err=%d", sym, GetLastError());
            }
         }
      }
      chart = ChartNext(chart);
   }
}

//+------------------------------------------------------------------+
//| 關卡資料                                                          |
//+------------------------------------------------------------------+
struct SessionLevels
{
   bool   found;
   double asianHigh, asianLow;
   double euroHigh,  euroLow;
   double usHigh,    usLow;
   double prevHigh,  prevLow;
};

bool LoadSessionLevels(const string sym, SessionLevels &out)
{
   out.found = false;

   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(Inp_UseCommonFiles)
      flags |= FILE_COMMON;

   int hh = FileOpen(Inp_LevelsCsvFile, flags);
   if(hh == INVALID_HANDLE)
      return false;

   bool first = true;
   while(!FileIsEnding(hh))
   {
      string line = FileReadString(hh);
      if(first) { first = false; continue; }
      if(StringLen(line) == 0) continue;

      string parts[];
      int n = StringSplit(line, ',', parts);
      if(n < 10) continue;
      if(parts[0] != sym) continue;

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
//| 畫關卡水平線（每張圖畫自己商品的線）                              |
//+------------------------------------------------------------------+
#define LINE_PREFIX "MSTAI_LV_"

void DrawLevelLine(const string name, const double price, const color clr, const string labelText)
{
   if(price <= 0.0)
   {
      ObjectDelete(0, name);
      return;
   }

   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);

   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, labelText);
}

void RefreshLevelLines()
{
   if(!Inp_ShowLevelLines)
      return;

   SessionLevels lv;
   if(!LoadSessionLevels(_Symbol, lv))
   {
      // 這張圖的商品在CSV裡找不到資料，把舊的線清掉避免顯示過期關卡
      string names[8] = {"PrevHigh","PrevLow","UsHigh","UsLow","EuroHigh","EuroLow","AsianHigh","AsianLow"};
      for(int i=0;i<8;i++) ObjectDelete(0, LINE_PREFIX+names[i]);
      return;
   }

   DrawLevelLine(LINE_PREFIX+"PrevHigh",  lv.prevHigh,  Inp_ColorPrevHigh,  "前日高點 "+DoubleToString(lv.prevHigh,_Digits));
   DrawLevelLine(LINE_PREFIX+"PrevLow",   lv.prevLow,   Inp_ColorPrevLow,   "前日低點 "+DoubleToString(lv.prevLow,_Digits));
   DrawLevelLine(LINE_PREFIX+"UsHigh",    lv.usHigh,    Inp_ColorUsHigh,    "美盤高點 "+DoubleToString(lv.usHigh,_Digits));
   DrawLevelLine(LINE_PREFIX+"UsLow",     lv.usLow,     Inp_ColorUsLow,     "美盤低點 "+DoubleToString(lv.usLow,_Digits));
   DrawLevelLine(LINE_PREFIX+"EuroHigh",  lv.euroHigh,  Inp_ColorEuroHigh,  "歐盤高點 "+DoubleToString(lv.euroHigh,_Digits));
   DrawLevelLine(LINE_PREFIX+"EuroLow",   lv.euroLow,   Inp_ColorEuroLow,   "歐盤低點 "+DoubleToString(lv.euroLow,_Digits));
   DrawLevelLine(LINE_PREFIX+"AsianHigh", lv.asianHigh, Inp_ColorAsianHigh, "亞盤高點 "+DoubleToString(lv.asianHigh,_Digits));
   DrawLevelLine(LINE_PREFIX+"AsianLow",  lv.asianLow,  Inp_ColorAsianLow,  "亞盤低點 "+DoubleToString(lv.asianLow,_Digits));

   ChartRedraw(0);
}

void DeleteLevelLines()
{
   ObjectsDeleteAll(0, LINE_PREFIX);
}

// 傳回 +1=突破(多), -1=跌破(空), 0=區間內/無資料
int GetLevelDirection(const double price)
{
   SessionLevels lv;
   if(!LoadSessionLevels(_Symbol, lv))
      return 0;

   if(lv.prevHigh > 0 && price > lv.prevHigh) return 1;
   if(lv.prevLow  > 0 && price < lv.prevLow)  return -1;
   if(lv.usHigh   > 0 && price > lv.usHigh)   return 1;
   if(lv.usLow    > 0 && price < lv.usLow)    return -1;
   if(lv.euroHigh > 0 && price > lv.euroHigh) return 1;
   if(lv.euroLow  > 0 && price < lv.euroLow)  return -1;
   if(lv.asianHigh> 0 && price > lv.asianHigh)return 1;
   if(lv.asianLow > 0 && price < lv.asianLow) return -1;
   return 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, BullBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, BearBuffer, INDICATOR_DATA);
   ArraySetAsSeries(BullBuffer, false);
   ArraySetAsSeries(BearBuffer, false);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   g_maHandle  = iMA(_Symbol, _Period, Inp_MaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle = iATR(_Symbol, _Period, Inp_AtrPeriod);
   if(g_maHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      PrintFormat("MultiSymbol_TAI_Breakout_Panel: %s 建立handle失敗 err=%d", _Symbol, GetLastError());
      return INIT_FAILED;
   }

   IndicatorSetString(INDICATOR_SHORTNAME, IND_SHORTNAME);

   if(Inp_AutoDeploy)
      AutoDeployToOtherCharts();

   RefreshLevelLines();
   EventSetTimer(MathMax(5, Inp_LineRefreshSec));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_maHandle  != INVALID_HANDLE) IndicatorRelease(g_maHandle);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   DeleteLevelLines();
   ChartRedraw(0);
}

void OnTimer()
{
   RefreshLevelLines();
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   int need = Inp_TaiPeriod + Inp_FlPeriod + 5;
   if(rates_total < need)
      return 0;

   if(BarsCalculated(g_maHandle) < rates_total || BarsCalculated(g_atrHandle) < rates_total)
      return prev_calculated;

   double avg[], atrBuf[];
   ArraySetAsSeries(avg, false);
   ArraySetAsSeries(atrBuf, false);
   if(CopyBuffer(g_maHandle, 0, 0, rates_total, avg) != rates_total ||
      CopyBuffer(g_atrHandle, 0, 0, rates_total, atrBuf) != rates_total)
      return prev_calculated;

   ArrayResize(g_fastAvg, rates_total);
   ArrayResize(g_val, rates_total);

   int start = (prev_calculated <= 1) ? 1 : prev_calculated - 1;
   if(prev_calculated <= 1)
   {
      g_fastAvg[0] = avg[0];
      g_val[0] = 0.0;
      BullBuffer[0] = EMPTY_VALUE;
      BearBuffer[0] = EMPTY_VALUE;
   }

   // 只需要算到 rates_total-1 這根，用最新2根判斷是否觸發箭頭
   for(int i = start; i < rates_total; i++)
   {
      g_fastAvg[i] = avg[i] + Inp_ResponseBoost * (avg[i] - avg[i-1]);
      BullBuffer[i] = EMPTY_VALUE;
      BearBuffer[i] = EMPTY_VALUE;

      if(i < Inp_TaiPeriod) { g_val[i] = 0.0; continue; }

      int rs = i - Inp_TaiPeriod + 1;
      double mx = g_fastAvg[rs], mn = g_fastAvg[rs];
      for(int j = rs+1; j <= i; j++) { mx = MathMax(mx, g_fastAvg[j]); mn = MathMin(mn, g_fastAvg[j]); }

      double dir = (g_fastAvg[i] >= g_fastAvg[i-1]) ? 1.0 : -1.0;
      g_val[i] = (MathAbs(close[i]) > DBL_EPSILON) ? 100.0*dir*(mx-mn)/MathAbs(close[i]) : 0.0;

      if(i < Inp_TaiPeriod + Inp_FlPeriod) continue;

      int fs = i - Inp_FlPeriod + 1;
      double vmin = g_val[fs], vmax = g_val[fs];
      for(int j = fs+1; j <= i; j++) { vmin = MathMin(vmin, g_val[j]); vmax = MathMax(vmax, g_val[j]); }

      double range = MathMax(vmax - vmin, DBL_EPSILON);
      double atrRatio = (MathAbs(close[i]) > DBL_EPSILON) ? atrBuf[i]/MathAbs(close[i]) : 0.0;
      double volatility = MathMin(0.20, atrRatio * Inp_AtrMultiplier * 10.0);
      double upperPct = MathMin(95.0, Inp_FlLevelUp + volatility*25.0);
      double lowerPct = MathMax(5.0,  Inp_FlLevelDown - volatility*25.0);

      double levelUp = vmin + range*upperPct*0.01;
      double levelDn = vmin + range*lowerPct*0.01;

      bool rising  = (g_val[i] > g_val[i-1]);
      bool falling = (g_val[i] < g_val[i-1]);

      int taiDir = 0;
      if(g_val[i] > levelUp && rising)       taiDir = 1;
      else if(g_val[i] < levelDn && falling) taiDir = -1;

      // 只在「最新這根」判斷關卡突破（關卡是即時Session資料，歷史K棒套用意義不大）
      if(i == rates_total - 1 && taiDir != 0)
      {
         double price = close[i];
         int lvlDir = GetLevelDirection(price);
         double offset = Inp_ArrowOffsetPoints * _Point;

         if(taiDir == 1 && lvlDir == 1)
         {
            BullBuffer[i] = low[i] - offset;
            if(Inp_EnableAlert && g_lastAlertBull != time[i])
            {
               g_lastAlertBull = time[i];
               Alert(_Symbol, " ", EnumToString(_Period), " 多方共振(TAI+關卡突破) @ ", TimeToString(time[i]));
            }
         }
         else if(taiDir == -1 && lvlDir == -1)
         {
            BearBuffer[i] = high[i] + offset;
            if(Inp_EnableAlert && g_lastAlertBear != time[i])
            {
               g_lastAlertBear = time[i];
               Alert(_Symbol, " ", EnumToString(_Period), " 空方共振(TAI+關卡跌破) @ ", TimeToString(time[i]));
            }
         }
      }
   }

   return rates_total;
}
//+------------------------------------------------------------------+
