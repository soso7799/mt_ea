//+------------------------------------------------------------------+
//| MomentumVolumePanel.mq5                                           |
//| 純觀察用指標(不下單、不影響EA邏輯)，參考TAI_Color_Panel的做法：     |
//|  - 零延遲修正的移動平均(降低轉折延遲)                              |
//|  - 自適應波動帶(帶寬隨ATR相對波動自動加寬/收窄)                    |
//|  - 突破+動能同向雙重確認(不是碰到帶就算，方向也要持續朝那邊走)      |
//|  - 連續K棒動能持續性判斷(剛啟動 vs 已延續)                        |
//| 新增：成交量是否突破均量，當作訊號的第三重確認，市場狀態文字會      |
//| 分別標示「有量能確認」或「量能不足，觀察」                          |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.00"
#property indicator_separate_window
#property indicator_buffers 10
#property indicator_plots   4
#property indicator_label1  "Up Level"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLimeGreen
#property indicator_style1  STYLE_DOT
#property indicator_label2  "Down Level"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_style2  STYLE_DOT
#property indicator_label3  "Momentum"
#property indicator_type3   DRAW_COLOR_LINE
#property indicator_color3  clrSilver,clrDeepSkyBlue,clrCrimson
#property indicator_width3  2
#property indicator_label4  "成交量"
#property indicator_type4   DRAW_COLOR_HISTOGRAM
#property indicator_color4  clrGray,clrDeepSkyBlue
#property indicator_width4  2

input group "--- 動能計算 ---"
input int                inpMomentumPeriodDefault = 5;      // 動能取樣期預設值(找不到優化資料時使用)
input ENUM_APPLIED_PRICE inpPrice          = PRICE_CLOSE;
input int                inpMaPeriodDefault       = 28;      // 底層均線週期預設值
input ENUM_MA_METHOD     inpMaMethod       = MODE_EMA;
input double             inpResponseBoost  = 0.35;    // 零延遲修正強度(0~1，越大延遲越低但越敏感)
input int                inpFilterPeriodDefault   = 50;      // 自適應波動帶取樣期預設值
input double             inpBandLevelUp    = 80.0;    // 基準上緣百分位
input double             inpBandLevelDown  = 20.0;    // 基準下緣百分位
input int                inpAtrPeriod      = 14;
input double             inpAtrMultiplier  = 1.0;

input group "--- 成交量確認 ---"
input int                inpVolAvgPeriod   = 20;      // 均量計算期
input double             inpVolUpThreshold = 1.2;     // 成交量超過均量這個倍數才算「放量確認」

input group "--- 面板顯示 ---"
input int                inpPanelFontSize  = 14;      // 市場狀態文字面板字體大小(想再調整直接改這個input即可)

// 實際運算用的變數(非input)，OnInit時先用上面Default值初始化，
// 找得到TAIParams.csv優化結果的話會自動覆蓋成該商品的最佳值
int MomentumPeriod, MaPeriod, FilterPeriod;

double levelUp[], levelDn[], val[], valc[];
double avg[], fastAvg[], atrBuffer[];
double volConfirm[]; // 1=放量, 0=正常/縮量(當作INDICATOR_CALCULATIONS用，不畫線)
double volumePlot[]; // 成交量柱狀圖(實際畫在副圖上的緩衝區)
double volumeColorIdx[]; // 成交量柱狀圖的顏色索引(0=正常灰色, 1=放量高亮)
int maHandle = INVALID_HANDLE, atrHandle = INVALID_HANDLE;

#define PFX2 "MOMVOL_"

//+------------------------------------------------------------------+
//| 讀取UTF-8檔案(共用資料夾)                                           |
//+------------------------------------------------------------------+
bool ReadUTF8FileLines_M(string path, string &outLines[])
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
//| 自動讀取TAIParams.csv，找這個商品的優化參數覆蓋預設值                 |
//+------------------------------------------------------------------+
void AutoLoadTAIParams()
{
   MomentumPeriod = inpMomentumPeriodDefault;
   MaPeriod = inpMaPeriodDefault;
   FilterPeriod = inpFilterPeriodDefault;

   string lines[];
   if(!ReadUTF8FileLines_M("TAIParams.csv", lines))
   {
      Print("提示：讀不到TAIParams.csv，維持用輸入參數預設值(", MomentumPeriod, "/", MaPeriod, "/", FilterPeriod, ")");
      return;
   }
   for(int i=0;i<ArraySize(lines);i++)
   {
      string line = lines[i];
      if(StringLen(line)==0 || StringGetCharacter(line,0)=='#') continue;
      if(StringFind(line,"Symbol")>=0 && StringFind(line,"MomentumPeriod")>=0) continue;
      string parts[];
      if(StringSplit(line, ',', parts) < 4) continue;
      if(parts[0] == _Symbol)
      {
         MomentumPeriod = (int)StringToInteger(parts[1]);
         MaPeriod = (int)StringToInteger(parts[2]);
         FilterPeriod = (int)StringToInteger(parts[3]);
         Print("已自動套用 ", _Symbol, " 的TAI最佳化參數：動能取樣期", MomentumPeriod,
               " 均線週期", MaPeriod, " 波動帶取樣期", FilterPeriod);
         return;
      }
   }
   Print("提示：TAIParams.csv裡沒有 ", _Symbol, " 的優化資料，維持用預設值");
}

//+------------------------------------------------------------------+
double GetPrice(const ENUM_APPLIED_PRICE priceType, const double &open[],
                const double &close[], const double &high[], const double &low[], const int i)
{
   switch(priceType)
   {
      case PRICE_OPEN:     return open[i];
      case PRICE_HIGH:     return high[i];
      case PRICE_LOW:      return low[i];
      case PRICE_MEDIAN:   return (high[i]+low[i])*0.5;
      case PRICE_TYPICAL:  return (high[i]+low[i]+close[i])/3.0;
      case PRICE_WEIGHTED: return (high[i]+low[i]+close[i]+close[i])*0.25;
      default:             return close[i];
   }
}

void DeletePanelObjects()
{
   string names[] = {PFX2+"T1", PFX2+"T2"};
   for(int i=0;i<ArraySize(names);i++) ObjectDelete(0, names[i]);
}

void CreateLabel(const string name, const int subWindow, const int y)
{
   int oldWindow = ObjectFind(0, name);
   if(oldWindow>=0 && oldWindow!=subWindow) ObjectDelete(0, name);

   if(ObjectFind(0, name) < 0)
      if(!ObjectCreate(0, name, OBJ_LABEL, subWindow, 0, 0)) return;

   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_FONT, "Microsoft JhengHei");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, inpPanelFontSize);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| 找出這個指標實際所在的子視窗，而不是硬寫死0(主圖表)。                |
//| 這支指標是indicator_separate_window，本來就會另外開一個子視窗，      |
//| 之前把面板文字寫死畫在window 0會疊到主圖表上其他物件(例如MT5內建的   |
//| 倒數計時文字)，造成畫面上兩個指標的文字重疊在一起。                   |
//+------------------------------------------------------------------+
int GetPanelWindow()
{
   int w = ChartWindowFind();
   return (w >= 0) ? w : 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   AutoLoadTAIParams(); // 先載入這個商品的優化參數，覆蓋掉輸入參數的預設值

   if(MomentumPeriod<2 || MaPeriod<1 || FilterPeriod<5 ||
      inpAtrPeriod<1 || inpResponseBoost<0.0 || inpResponseBoost>1.0 ||
      inpBandLevelDown<0.0 || inpBandLevelUp>100.0 || inpBandLevelDown>=inpBandLevelUp ||
      inpAtrMultiplier<0.0 || inpVolAvgPeriod<2 || inpVolUpThreshold<=1.0)
      return INIT_PARAMETERS_INCORRECT;

   DeletePanelObjects();

   SetIndexBuffer(0, levelUp, INDICATOR_DATA);
   SetIndexBuffer(1, levelDn, INDICATOR_DATA);
   SetIndexBuffer(2, val, INDICATOR_DATA);
   SetIndexBuffer(3, valc, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(4, avg, INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, fastAvg, INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, atrBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, volConfirm, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, volumePlot, INDICATOR_DATA);
   SetIndexBuffer(9, volumeColorIdx, INDICATOR_COLOR_INDEX);

   ArraySetAsSeries(levelUp, false);
   ArraySetAsSeries(levelDn, false);
   ArraySetAsSeries(val, false);
   ArraySetAsSeries(valc, false);
   ArraySetAsSeries(avg, false);
   ArraySetAsSeries(fastAvg, false);
   ArraySetAsSeries(atrBuffer, false);
   ArraySetAsSeries(volConfirm, false);
   ArraySetAsSeries(volumePlot, false);
   ArraySetAsSeries(volumeColorIdx, false);

   maHandle = iMA(_Symbol, _Period, MaPeriod, 0, inpMaMethod, inpPrice);
   atrHandle = iATR(_Symbol, _Period, inpAtrPeriod);
   if(maHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE)
   {
      if(maHandle!=INVALID_HANDLE) IndicatorRelease(maHandle);
      if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle);
      return INIT_FAILED;
   }

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, MomentumPeriod+FilterPeriod);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, MomentumPeriod+FilterPeriod);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, MomentumPeriod);
   for(int i=0;i<3;i++) PlotIndexSetInteger(i, PLOT_SHOW_DATA, false);
   IndicatorSetString(INDICATOR_SHORTNAME, " ");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(maHandle!=INVALID_HANDLE) IndicatorRelease(maHandle);
   if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle);
   DeletePanelObjects();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   const int minimumBars = MomentumPeriod + FilterPeriod + 2;
   if(rates_total < minimumBars) return 0;

   if(BarsCalculated(maHandle)<rates_total || BarsCalculated(atrHandle)<rates_total)
      return prev_calculated;

   if(CopyBuffer(maHandle, 0, 0, rates_total, avg) != rates_total) return prev_calculated;

   double atrTmp[];
   ArrayResize(atrTmp, rates_total);
   ArraySetAsSeries(atrTmp, false);
   if(CopyBuffer(atrHandle, 0, 0, rates_total, atrTmp) != rates_total) return prev_calculated;
   ArrayCopy(atrBuffer, atrTmp);

   int start;
   if(prev_calculated<=0 || prev_calculated>rates_total)
   {
      ArrayInitialize(levelUp, EMPTY_VALUE);
      ArrayInitialize(levelDn, EMPTY_VALUE);
      ArrayInitialize(val, 0.0);
      ArrayInitialize(valc, 0.0);
      ArrayInitialize(fastAvg, 0.0);
      ArrayInitialize(volConfirm, 0.0);
      fastAvg[0] = avg[0];
      start = 1;
   }
   else
      start = MathMax(1, prev_calculated-1);

   for(int i=start; i<rates_total && !_StopFlag; i++)
   {
      // 零延遲修正：對MA加入受控的超前補償，降低轉折延遲
      fastAvg[i] = avg[i] + inpResponseBoost*(avg[i]-avg[i-1]);

      // 成交量確認：目前這根量是否超過均量的門檻倍數
      long curVol = tick_volume[i];
      double sumVol=0; int volCount=0;
      for(int k=1;k<=inpVolAvgPeriod && (i-k)>=0;k++){ sumVol += (double)tick_volume[i-k]; volCount++; }
      double avgVol = (volCount>0) ? sumVol/volCount : (double)curVol;
      volConfirm[i] = (avgVol>0 && curVol > avgVol*inpVolUpThreshold) ? 1.0 : 0.0;
      volumePlot[i] = (double)curVol;
      volumeColorIdx[i] = volConfirm[i];

      if(i < MomentumPeriod)
      {
         val[i]=0.0; valc[i]=0.0;
         continue;
      }

      int rangeStart = i - MomentumPeriod + 1;
      double maximum = fastAvg[rangeStart], minimum = fastAvg[rangeStart];
      for(int j=rangeStart+1;j<=i;j++)
      {
         maximum = MathMax(maximum, fastAvg[j]);
         minimum = MathMin(minimum, fastAvg[j]);
      }

      double price = GetPrice(inpPrice, open, close, high, low, i);
      double direction = (fastAvg[i] >= fastAvg[i-1]) ? 1.0 : -1.0;
      val[i] = (MathAbs(price)>DBL_EPSILON) ? 100.0*direction*(maximum-minimum)/MathAbs(price) : 0.0;

      if(i < MomentumPeriod+FilterPeriod)
      {
         levelUp[i]=EMPTY_VALUE; levelDn[i]=EMPTY_VALUE; valc[i]=0.0;
         continue;
      }

      int filterStart = i - FilterPeriod + 1;
      double valueMin = val[filterStart], valueMax = val[filterStart];
      for(int j=filterStart+1;j<=i;j++)
      {
         valueMin = MathMin(valueMin, val[j]);
         valueMax = MathMax(valueMax, val[j]);
      }

      double range = MathMax(valueMax-valueMin, DBL_EPSILON);
      double atrRatio = (MathAbs(close[i])>DBL_EPSILON) ? atrBuffer[i]/MathAbs(close[i]) : 0.0;
      double volatility = MathMin(0.20, atrRatio*inpAtrMultiplier*10.0);
      double upperPercent = MathMin(95.0, inpBandLevelUp + volatility*25.0);
      double lowerPercent = MathMax(5.0, inpBandLevelDown - volatility*25.0);

      levelUp[i] = valueMin + range*upperPercent*0.01;
      levelDn[i] = valueMin + range*lowerPercent*0.01;

      // 突破+動能同向雙重確認(不含成交量，成交量另外顯示在文字上)
      bool rising = (val[i] > val[i-1]);
      bool falling = (val[i] < val[i-1]);
      if(val[i] > levelUp[i] && rising)      valc[i] = 1.0;
      else if(val[i] < levelDn[i] && falling) valc[i] = 2.0;
      else                                     valc[i] = 0.0;
   }

   // ---- 市場狀態文字面板 ----
   int stateBar = rates_total - 2; // 用已收完那根
   int upBars=0, downBars=0;
   for(int k=stateBar; k>=MathMax(0, stateBar-4); k--)
   {
      if(valc[k]==1.0 && downBars==0) upBars++;
      else if(valc[k]==2.0 && upBars==0) downBars++;
      else break;
   }

   bool volOk = (stateBar>=0 && stateBar<rates_total) ? (volConfirm[stateBar] > 0.5) : false;
   string volTag = volOk ? "(有量能確認)" : "(量能不足，觀察)";

   string marketState = "市場型態：橫盤震盪";
   string advice = "提示：等待方向與動能同步";
   color stateColor = clrSilver;

   if(upBars>=2)
   {
      marketState = "市場型態：多頭動能延續" + volTag;
      advice = volOk ? "警示：避免逆勢做空" : "提示：動能持續但量能偏弱，訊號打折";
      stateColor = volOk ? clrDeepSkyBlue : clrSilver;
   }
   else if(downBars>=2)
   {
      marketState = "市場型態：空頭動能延續" + volTag;
      advice = volOk ? "警示：避免逆勢做多" : "提示：動能持續但量能偏弱，訊號打折";
      stateColor = volOk ? clrTomato : clrSilver;
   }
   else if(upBars==1)
   {
      marketState = "市場型態：多頭動能啟動" + volTag;
      advice = "觀察：等待收盤確認";
      stateColor = volOk ? clrLimeGreen : clrSilver;
   }
   else if(downBars==1)
   {
      marketState = "市場型態：空頭動能啟動" + volTag;
      advice = "觀察：等待收盤確認";
      stateColor = volOk ? clrOrange : clrSilver;
   }

   int panelWindow = GetPanelWindow();
   CreateLabel(PFX2+"T1", panelWindow, 5);
   CreateLabel(PFX2+"T2", panelWindow, 5 + inpPanelFontSize + 8); // 間距跟著字體大小走，字體變大不會疊行
   ObjectSetString(0, PFX2+"T1", OBJPROP_TEXT, marketState);
   ObjectSetInteger(0, PFX2+"T1", OBJPROP_COLOR, stateColor);
   ObjectSetString(0, PFX2+"T2", OBJPROP_TEXT, advice);
   ObjectSetInteger(0, PFX2+"T2", OBJPROP_COLOR, clrSilver);

   ChartRedraw(0);
   return rates_total;
}
