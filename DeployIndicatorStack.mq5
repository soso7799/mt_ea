//+------------------------------------------------------------------+
//|  DeployIndicatorStack.mq5                                        |
//|  「腳本」而非指標——執行一次，把你在目前圖表上手動配置好的整套    |
//|  指標，複製部署到你已開啟的其他商品分頁，不用一張一張手動拖。    |
//|                                                                    |
//|  用法：在你已經手動裝好完整指標組合的那張圖（例如截圖那張         |
//|  US100.cash,M5），把這個腳本拖上去執行一次即可。                  |
//|                                                                    |
//|  已知限制：Trendline_Signal_Indicator_MT5 依賴你手動畫的4條趨勢   |
//|  線，複製到其他圖表上沒有那些線，不會有任何訊號——這是它本身的    |
//|  設計限制，沒辦法用程式自動複製手畫的線，其他商品要用這支還是要  |
//|  自己手動畫線。腳本仍會嘗試附掛它（萬一你已經在該圖畫過線），    |
//|  但預設關閉，需要你手動開啟 Inp_IncludeTrendlineSignal。          |
//+------------------------------------------------------------------+
#property copyright "Deploy your indicator stack to other charts — no trading actions"
#property version   "1.00"
#property script_show_inputs

input group "=== 監控商品清單（部署到這些商品的已開圖表）==="
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

input group "=== 要複製的指標（打勾才會部署）==="
input bool Inp_IncludeMA1               = true;
input int  Inp_MA1_Period               = 20;   // 短均線週期（截圖裡的青色線）
input ENUM_MA_METHOD Inp_MA1_Method     = MODE_EMA;

input bool Inp_IncludeMA2               = true;
input int  Inp_MA2_Period               = 50;   // 長均線週期（截圖裡的橘色線）
input ENUM_MA_METHOD Inp_MA2_Method     = MODE_EMA;

input bool Inp_IncludeYesterdayHiL      = true;  // YesterdayHiL_Autoadjust
input bool Inp_IncludeTAI               = true;  // TAI_Color_Panel_Optimized
input bool Inp_IncludeVolumePanel       = true;  // ExcelMonitor_VolumePanel
input bool Inp_IncludeRemainingTime     = true;  // Remaining time indicator_
input bool Inp_IncludeTrendlineSignal   = false; // 見上方限制說明，預設關閉

input group "=== TAI_Color_Panel_Optimized 參數（跟你手動設定的要一致）==="
input int    Inp_TAI_TaiPeriod     = 5;
input ENUM_APPLIED_PRICE Inp_TAI_Price = PRICE_CLOSE;
input int    Inp_TAI_MaPeriod      = 28;
input ENUM_MA_METHOD Inp_TAI_MaMethod = MODE_EMA;
input double Inp_TAI_ResponseBoost = 0.35;
input int    Inp_TAI_FlPeriod      = 50;
input double Inp_TAI_FlLevelUp     = 80.0;
input double Inp_TAI_FlLevelDown   = 20.0;
input int    Inp_TAI_AtrPeriod     = 14;
input double Inp_TAI_AtrMultiplier = 1.0;
input bool   Inp_TAI_ClosedBarState = true;

#define SYM_COUNT 11

bool IsWatchedSymbol(const string sym)
{
   string list[SYM_COUNT] = {Inp_Sym1,Inp_Sym2,Inp_Sym3,Inp_Sym4,Inp_Sym5,
                              Inp_Sym6,Inp_Sym7,Inp_Sym8,Inp_Sym9,Inp_Sym10,Inp_Sym11};
   for(int i=0;i<SYM_COUNT;i++)
      if(list[i] == sym) return true;
   return false;
}

bool HasIndicator(const long chart, const int subwin, const string name)
{
   int total = ChartIndicatorsTotal(chart, subwin);
   for(int i=0;i<total;i++)
      if(ChartIndicatorName(chart, subwin, i) == name)
         return true;
   return false;
}

void AddChartWindowIndicator(const long chart, const string sym, const ENUM_TIMEFRAMES tf,
                              const string name, const int handle)
{
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("%s: %s 建立handle失敗 err=%d", name, sym, GetLastError());
      return;
   }
   if(HasIndicator(chart, 0, name))
   {
      IndicatorRelease(handle);
      return;
   }
   if(!ChartIndicatorAdd(chart, 0, handle))
      PrintFormat("%s: %s 貼上主圖失敗 err=%d", name, sym, GetLastError());
}

void AddSubWindowIndicator(const long chart, const string sym, const string name, const int handle)
{
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("%s: %s 建立handle失敗 err=%d", name, sym, GetLastError());
      return;
   }

   // 副視窗指標先檢查各個既有視窗有沒有重複
   int winTotal = (int)ChartGetInteger(chart, CHART_WINDOWS_TOTAL);
   for(int w=1; w<winTotal; w++)
   {
      if(HasIndicator(chart, w, name))
      {
         IndicatorRelease(handle);
         return;
      }
   }

   if(!ChartIndicatorAdd(chart, winTotal, handle))
      PrintFormat("%s: %s 貼上副視窗失敗 err=%d", name, sym, GetLastError());
}

void DeployToChart(const long chart)
{
   string sym = ChartSymbol(chart);
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)ChartPeriod(chart);

   if(Inp_IncludeMA1)
   {
      int h = iMA(sym, tf, Inp_MA1_Period, 0, Inp_MA1_Method, PRICE_CLOSE);
      AddChartWindowIndicator(chart, sym, tf, "Moving Average", h);
   }
   if(Inp_IncludeMA2)
   {
      int h = iMA(sym, tf, Inp_MA2_Period, 0, Inp_MA2_Method, PRICE_CLOSE);
      AddChartWindowIndicator(chart, sym, tf, "Moving Average", h);
   }
   if(Inp_IncludeYesterdayHiL)
   {
      int h = iCustom(sym, tf, "YesterdayHiL_Autoadjust");
      AddChartWindowIndicator(chart, sym, tf, "YesterdayHiL_Autoadjust", h);
   }
   if(Inp_IncludeTrendlineSignal)
   {
      int h = iCustom(sym, tf, "Trendline_Signal_Indicator_MT5");
      AddChartWindowIndicator(chart, sym, tf, "Trendline_Signal_Indicator_MT5", h);
   }
   if(Inp_IncludeTAI)
   {
      int h = iCustom(sym, tf, "TAI_Color_Panel_Optimized",
                       Inp_TAI_TaiPeriod, Inp_TAI_Price, Inp_TAI_MaPeriod, Inp_TAI_MaMethod,
                       Inp_TAI_ResponseBoost, Inp_TAI_FlPeriod, Inp_TAI_FlLevelUp, Inp_TAI_FlLevelDown,
                       Inp_TAI_AtrPeriod, Inp_TAI_AtrMultiplier, Inp_TAI_ClosedBarState);
      AddSubWindowIndicator(chart, sym, "TAI_Color_Panel_Optimized", h);
   }
   if(Inp_IncludeVolumePanel)
   {
      int h = iCustom(sym, tf, "ExcelMonitor_VolumePanel");
      AddSubWindowIndicator(chart, sym, "ExcelMonitor_VolumePanel", h);
   }
   if(Inp_IncludeRemainingTime)
   {
      int h = iCustom(sym, tf, "Remaining time indicator_");
      AddChartWindowIndicator(chart, sym, tf, "Remaining time indicator_", h);
   }

   ChartRedraw(chart);
   PrintFormat("DeployIndicatorStack: %s 部署完成", sym);
}

void OnStart()
{
   long thisChart = ChartID();
   long chart = ChartFirst();
   int deployed = 0;

   while(chart >= 0)
   {
      if(chart != thisChart)
      {
         string sym = ChartSymbol(chart);
         if(IsWatchedSymbol(sym))
         {
            DeployToChart(chart);
            deployed++;
         }
      }
      chart = ChartNext(chart);
   }

   PrintFormat("DeployIndicatorStack: 共部署到 %d 張圖表", deployed);
   if(!Inp_IncludeTrendlineSignal)
      Print("提醒：Trendline_Signal_Indicator_MT5 未部署（需要在各圖手動畫趨勢線才有意義，見腳本開頭說明）");
}
//+------------------------------------------------------------------+
