//+------------------------------------------------------------------+
//|                                                  KDJ_J_MACD.mq5  |
//|  One subwindow: KDJ J line only + MACD histogram only.            |
//|  KDJ math follows KDJ_Averages.mq5 (SMA smoothing).               |
//|  MACD histogram = EMA(fast) - EMA(slow), same as MT5 built-in     |
//|  MACD bars; the signal line is not drawn.                         |
//|  The histogram is scaled onto the J scale around the 50 line:     |
//|  50 + Height * MACD / max|MACD| over the last ScaleBars bars.     |
//+------------------------------------------------------------------+
#property version     "1.00"
#property description "KDJ J line + MACD histogram (signal line hidden)"
#property indicator_separate_window
#property indicator_buffers 9
#property indicator_plots   2
//--- plot 1: MACD histogram drawn from the 50 line
#property indicator_label1  "MACD Hist base;MACD Hist"
#property indicator_type1   DRAW_HISTOGRAM2
#property indicator_color1  clrSilver
#property indicator_width1  2
//--- plot 2: J line
#property indicator_label2  "J"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrYellow
#property indicator_width2  2
#property indicator_level1  50.0
#property indicator_levelstyle STYLE_DOT
#property indicator_levelcolor clrGray

enum ENUM_J_FORMULA
  {
   J_3D_MINUS_2K = 0,   // J = 3D - 2K (same as KDJ_Averages.mq5)
   J_3K_MINUS_2D = 1    // J = 3K - 2D (standard KDJ)
  };

input group "=== KDJ ==="
input int            InpKDJPeriod  = 9;              // KDJ period
input int            InpKPeriod    = 3;              // K period (SMA)
input int            InpDPeriod    = 3;              // D period (SMA)
input ENUM_J_FORMULA InpJFormula   = J_3D_MINUS_2K;  // J formula
input group "=== MACD histogram ==="
input int            InpFastEMA    = 12;             // Fast EMA
input int            InpSlowEMA    = 26;             // Slow EMA
input int            InpScaleBars  = 200;            // Scale by max |MACD| over N bars
input double         InpHistHeight = 50.0;           // Histogram height at max (J units)

double HistBase[], HistVal[], JBuf[];
double RsvBuf[], KBuf[], DBuf[], MacdBuf[], EmaFBuf[], EmaSBuf[];

int g_n, g_k, g_d, g_scale;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_n     = MathMax(InpKDJPeriod, 1);
   g_k     = MathMax(InpKPeriod, 2);
   g_d     = MathMax(InpDPeriod, 2);
   g_scale = MathMax(InpScaleBars, 10);
   if(InpFastEMA < 1 || InpSlowEMA <= InpFastEMA)
     {
      Print("KDJ_J_MACD: slow EMA must be greater than fast EMA");
      return INIT_PARAMETERS_INCORRECT;
     }

   SetIndexBuffer(0, HistBase, INDICATOR_DATA);
   SetIndexBuffer(1, HistVal,  INDICATOR_DATA);
   SetIndexBuffer(2, JBuf,     INDICATOR_DATA);
   SetIndexBuffer(3, RsvBuf,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, KBuf,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, DBuf,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, MacdBuf,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, EmaFBuf,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, EmaSBuf,  INDICATOR_CALCULATIONS);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpSlowEMA);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, g_n + g_k + g_d);

   IndicatorSetInteger(INDICATOR_DIGITS, 2);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("KDJ J(%d,%d,%d) + MACD(%d,%d) hist",
                                   g_n, g_k, g_d, InpFastEMA, InpSlowEMA));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
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
   if(rates_total < g_n + g_k + g_d + 2)
      return 0;

   // arrays are oldest-first (index 0 = oldest bar)
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);

   const int rsvFrom = g_n - 1;
   const int kFrom   = rsvFrom + g_k - 1;
   const int dFrom   = kFrom + g_d - 1;
   const double af   = 2.0 / (InpFastEMA + 1.0);
   const double as_  = 2.0 / (InpSlowEMA + 1.0);

   int start = (prev_calculated > 1) ? prev_calculated - 1 : 0;
   for(int i = start; i < rates_total && !IsStopped(); i++)
     {
      //--- RSV (same as KDJ_Averages: range includes the close)
      RsvBuf[i] = 50.0;
      if(i >= rsvFrom)
        {
         double hh = close[i], ll = close[i];
         for(int k = 0; k < g_n; k++)
           {
            hh = MathMax(hh, high[i - k]);
            ll = MathMin(ll, low[i - k]);
           }
         RsvBuf[i] = (hh != ll) ? 100.0 * (close[i] - ll) / (hh - ll) : 50.0;
        }
      //--- K = SMA(RSV), D = SMA(K)
      KBuf[i] = 50.0;
      if(i >= kFrom)
        {
         double s = 0.0;
         for(int k = 0; k < g_k; k++) s += RsvBuf[i - k];
         KBuf[i] = s / g_k;
        }
      DBuf[i] = 50.0;
      JBuf[i] = EMPTY_VALUE;
      if(i >= dFrom)
        {
         double s = 0.0;
         for(int k = 0; k < g_d; k++) s += KBuf[i - k];
         DBuf[i] = s / g_d;
         JBuf[i] = (InpJFormula == J_3D_MINUS_2K) ? 3.0 * DBuf[i] - 2.0 * KBuf[i]
                                                   : 3.0 * KBuf[i] - 2.0 * DBuf[i];
        }

      //--- MACD main = EMA(fast) - EMA(slow)
      if(i == 0)
        {
         EmaFBuf[i] = close[i];
         EmaSBuf[i] = close[i];
        }
      else
        {
         EmaFBuf[i] = EmaFBuf[i - 1] + af  * (close[i] - EmaFBuf[i - 1]);
         EmaSBuf[i] = EmaSBuf[i - 1] + as_ * (close[i] - EmaSBuf[i - 1]);
        }
      MacdBuf[i] = EmaFBuf[i] - EmaSBuf[i];

      //--- histogram scaled onto the J scale around 50
      HistBase[i] = EMPTY_VALUE;
      HistVal[i]  = EMPTY_VALUE;
      if(i >= InpSlowEMA)
        {
         double mx = 0.0;
         for(int k = MathMax(0, i - g_scale + 1); k <= i; k++)
            mx = MathMax(mx, MathAbs(MacdBuf[k]));
         HistBase[i] = 50.0;
         HistVal[i]  = (mx > 0.0) ? 50.0 + InpHistHeight * MacdBuf[i] / mx : 50.0;
        }
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
