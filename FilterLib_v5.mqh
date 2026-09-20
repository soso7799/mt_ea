//+------------------------------------------------------------------+
//|  FilterLib_v5.mqh                                                |
//|  整合 v4 完整風控 + v5 多指標信號架構                             |
//+------------------------------------------------------------------+
#ifndef FILTERLIB_V5_MQH
#define FILTERLIB_V5_MQH

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//--------------------------------------------------------------------
// 支援幣別
//--------------------------------------------------------------------
const string SYMBOLS[20] = {
   
   "AUDJPY",
   "AUDSGD",
   "AUDUSD",
   "CADJPY",
   "CHFJPY",
   "EURDKK",
   "EURGBP",
   "EURJPY",
   "GBPJPY",
   "GBPUSD",
   "NOKJPY",
   "NOKSEK",
   "NZDJPY",
   "NZDUSD",
   "SEKJPY",
   "USDCAD",
   "USDCHF",
   "USDJPY",
   "USDMXN",
   "USDTRY"
};

//--------------------------------------------------------------------
// v5 指標固定參數
//--------------------------------------------------------------------
const int    EMA_FAST           = 9;
const int    EMA_SLOW           = 21;
const int    RSI_PERIOD         = 14;
const double RSI_OS             = 30.0;
const double RSI_OB             = 70.0;
const int    BB_PERIOD_DEFAULT  = 20;
const double BB_DEV_DEFAULT     = 2.0;
const int    BB_PERIOD_USDJPY   = 14;
const double BB_DEV_USDJPY      = 1.5;
const int    MACD_FAST          = 12;
const int    MACD_SLOW          = 26;
const int    MACD_SIG           = 9;
const int    KDJ_KK             = 3;
const int    KDJ_KD             = 3;

//--------------------------------------------------------------------
// 信號枚舉
//--------------------------------------------------------------------
enum ENUM_SIG { SIG_NONE=0, SIG_BUY=1, SIG_SELL=-1 };

//--------------------------------------------------------------------
// 幣別規則結構（保留）
//--------------------------------------------------------------------
struct SymbolRule
{
   string symbol;
};

//--------------------------------------------------------------------
// 全域 Helper：幣別索引
//--------------------------------------------------------------------
int SymIdx(const string sym)
{
   for(int i=0; i<20; i++)
      if(SYMBOLS[i]==sym) return i;
   return -1;
}

int KdjPeriod(const string sym)
{
   if(sym=="GBPUSD" || sym=="AUDUSD" || sym=="NZDUSD") return 14;
   return 9;
}

//====================================================================
//  CFilterLib_Pro  v5
//====================================================================
class CFilterLib_Pro
{
private:
   CTrade           trade;
   CPositionInfo    pos;
   long             magic;
   ENUM_TIMEFRAMES  m_tf;

   int      m_hEmaFast[20];
   int      m_hEmaSlow[20];
   int      m_hRSI[20];
   int      m_hBB[20];
   int      m_hMACD[20];
   int      m_hStoch[20];

   datetime m_lastBarTime[20];
   bool     m_barUsed[20];
   datetime m_lastBarTimeF[20];

   datetime lastResetDay;
   bool     forceClosedToday;

   struct RuleItem
   {
      string symbol;
      double sl_pips;
      double tp_pips;
      double atr_threshold;
      double lot_size;
   };

   RuleItem fx_rules[];

   double sl_pips;
   double tp_pips;
   double atr_threshold;
   double lot_size;

   //-----------------------------------------------------------------
   // v4 私有工具
   //-----------------------------------------------------------------
   MqlDateTime LocalNow()
   {
      MqlDateTime t;
      TimeToStruct(TimeLocal(), t);
      return t;
   }

   double PipSize(string sym)
   {
      int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      return (d==2 || d==3) ? 0.01 : 0.0001;
   }

   string GetCoreSymbol(string sym)
   {
      string s = sym;
      StringToUpper(s);

      // 逐一比對已知的 20 個核心幣別代碼，而不是抓「第一段連續6個字母」，
      // 否則像 "mUSDJPY" 這種帶前綴的券商命名，會先比對到錯誤的 "MUSDJP"
      for(int i=0; i<=StringLen(s)-6; i++)
      {
         string part = StringSubstr(s, i, 6);
         for(int k=0; k<20; k++)
         {
            if(part == SYMBOLS[k])
               return part;
         }
      }

      return s;
   }

   int FindRule(string sym)
   {
      string core = GetCoreSymbol(sym);
      for(int i=0; i<ArraySize(fx_rules); i++)
         if(fx_rules[i].symbol == core) return i;
      return -1;
   }

   datetime GetTradingDayStart()
   {
      MqlDateTime t = LocalNow();
      t.hour = TradingStartHour;
      t.min  = TradingStartMin;
      t.sec  = 0;

      datetime start = StructToTime(t);
      if(TimeLocal() < start)
         return start - 86400;

      return start;
   }

   //-----------------------------------------------------------------
   // F段專用新K棒偵測（獨立計時器）
   //-----------------------------------------------------------------
   bool _checkNewBarF(int idx)
   {
      datetime barTime[1];
      if(CopyTime(SYMBOLS[idx], m_tf, 0, 1, barTime) != 1) return false;

      if(barTime[0] != m_lastBarTimeF[idx])
      {
         m_lastBarTimeF[idx] = barTime[0];
         return true;
      }
      return false;
   }

   bool _getDouble(int handle, int bufIdx, int shift, double &val)
   {
      double buf[1];
      if(CopyBuffer(handle, bufIdx, shift, 1, buf) != 1) return false;
      val = buf[0];
      return true;
   }

   ENUM_SIG _calcSignalShift(int idx, int shift)
   {
      string sym = SYMBOLS[idx];
      double emaFast, emaSlow, rsi, bbUpper, bbLower, bbMid;
      double macdMain, macdSigVal, stochK, stochD;

      if(!_getDouble(m_hEmaFast[idx],0,shift,emaFast))    return SIG_NONE;
      if(!_getDouble(m_hEmaSlow[idx],0,shift,emaSlow))    return SIG_NONE;
      if(!_getDouble(m_hRSI[idx],0,shift,rsi))            return SIG_NONE;
      if(!_getDouble(m_hBB[idx],1,shift,bbUpper))         return SIG_NONE;
      if(!_getDouble(m_hBB[idx],2,shift,bbLower))         return SIG_NONE;
      if(!_getDouble(m_hBB[idx],0,shift,bbMid))           return SIG_NONE;
      if(!_getDouble(m_hMACD[idx],0,shift,macdMain))      return SIG_NONE;
      if(!_getDouble(m_hMACD[idx],1,shift,macdSigVal))    return SIG_NONE;
      if(!_getDouble(m_hStoch[idx],0,shift,stochK))       return SIG_NONE;
      if(!_getDouble(m_hStoch[idx],1,shift,stochD))       return SIG_NONE;

      double close[];
      if(CopyClose(sym, m_tf, shift, 1, close) != 1) return SIG_NONE;
      double price = close[0];

      int buyScore = 0;
      if(emaFast  > emaSlow)                 buyScore++;
      if(rsi      > RSI_OS && rsi < RSI_OB)  buyScore++;
      if(price    > bbMid)                   buyScore++;
      if(macdMain > macdSigVal)              buyScore++;
      if(stochK   > stochD && stochK < 80)   buyScore++;

      int sellScore = 0;
      if(emaFast  < emaSlow)                 sellScore++;
      if(rsi      < RSI_OB && rsi > RSI_OS)  sellScore++;
      if(price    < bbMid)                   sellScore++;
      if(macdMain < macdSigVal)              sellScore++;
      if(stochK   < stochD && stochK > 20)   sellScore++;

      if(buyScore  >= 4) return SIG_BUY;
      if(sellScore >= 4) return SIG_SELL;
      return SIG_NONE;
   }

   //-----------------------------------------------------------------
   // v4 歷史 / 鎖定 / 關倉工具
   //-----------------------------------------------------------------
   int GetSymbolStopLossCount(string sym)
   {
      int cnt = 0;
      HistorySelect(GetTradingDayStart(), TimeLocal());

      for(int i=HistoryDealsTotal()-1; i>=0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;

         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != sym) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         // 只算真正被 SL 觸發平倉的單，手動平倉/反向訊號平倉即使虧損也不算「止損」
         if(HistoryDealGetInteger(ticket, DEAL_REASON) != DEAL_REASON_SL) continue;

         cnt++;
      }
      return cnt;
   }

   double GetTodayClosedProfit()
   {
      double p = 0.0;
      HistorySelect(GetTradingDayStart(), TimeLocal());

      for(int i=HistoryDealsTotal()-1; i>=0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

         p += HistoryDealGetDouble(ticket, DEAL_PROFIT)
            + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
            + HistoryDealGetDouble(ticket, DEAL_SWAP);
      }

      return p;
   }

   double GetFloatingProfit()
   {
      double p = 0.0;

      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(pos.SelectByIndex(i) && pos.Magic() == magic)
            p += pos.Profit() + pos.Swap();
      }

      return p;
   }

   double GetTotalDayPnL()
   {
      return GetTodayClosedProfit() + GetFloatingProfit();
   }

   bool IsDayLocked()
   {
      return GlobalVariableCheck("PRO_DAY_LOCK");
   }

   void LockDay()
   {
      GlobalVariableSet("PRO_DAY_LOCK", (double)TimeLocal());
      Print("⛔ 全局鎖日");
   }

   bool IsSymbolLocked(string sym)
   {
      return GlobalVariableCheck("PRO_LOCK_" + sym);
   }

   void LockSymbol(string sym)
   {
      GlobalVariableSet("PRO_LOCK_" + sym, (double)TimeLocal());
      Print("⛔ ", sym, " 已鎖定");
   }

   void CloseAll(string reason="")
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!pos.SelectByIndex(i) || pos.Magic() != magic) continue;

         ulong ticket = pos.Ticket();
         string sym   = pos.Symbol();

         if(trade.PositionClose(ticket))
            Print("✅ 全平 ", sym, " | ", reason);
      }
   }

   void CloseSymbol(string sym, string reason="")
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!pos.SelectByIndex(i) || pos.Magic() != magic || pos.Symbol() != sym) continue;

         ulong ticket = pos.Ticket();
         if(trade.PositionClose(ticket))
            Print("✅ 平倉 ", sym, " | ", reason);
      }
   }

public:
   //-----------------------------------------------------------------
   // v4 公開參數
   //-----------------------------------------------------------------
   double DayLossLimit;
   double AccountEquityFloor;
   double VolatilityMultiplier;
   int    MaxSymbolStopLoss;

   int MinBarBodyPips;
   int MaxSwingBars;
   int StepProfitPips;
   int StepLockPips;

   int TradingStartHour; int TradingStartMin;
   int NoTradeStartHour; int NoTradeStartMin;
   int NoTradeEndHour;   int NoTradeEndMin;
   int ForceCloseHour;   int ForceCloseMin;

   int NoTrade2StartHour; int NoTrade2StartMin;
   int NoTrade2EndHour;   int NoTrade2EndMin;

   //-----------------------------------------------------------------
   // 規則初始化
   //-----------------------------------------------------------------
   void InitRules()
   {
      ArrayResize(fx_rules, 25);

      // ⚠️⚠️⚠️ PLACEHOLDER — 以下 4 筆指數 CFD 規則完全沒有經過回測校準 ⚠️⚠️⚠️
      // SL/TP/ATR門檻是保守估計值，lot_size 固定用最小 0.01，
      // 純粹是為了讓 US100.cash/US500.cash/US30.cash/JP225.cash 能被 FindRule()
      // 正確辨識、可以下單而不是直接被 AllowTrading() 擋掉。
      // 正式交易前，務必用實際回測數據（backtest_session_breakout.py 或其他）
      // 覆蓋這 4 筆的 sl_pips / tp_pips / atr_threshold / lot_size。
      // symbol 欄位要跟 GetCoreSymbol() 轉大寫後的broker代碼完全一致
      // （broker 若用 "US100.cash" 這種寫法，轉大寫後會是 "US100.CASH"）。
      //
      // ⚠️ 重要：PipSize() 是為外匯設計的（2/3位小數→0.01，其餘→0.0001），
      // 底下 sl_pips/tp_pips/atr_threshold 是「假設這幾個指數 SYMBOL_DIGITS=2
      // （即 PipSize=0.01）」反推出來的點數，換算成實際價格距離大約是：
      // US100.cash ≈80點、US500.cash ≈25點、US30.cash ≈150點、JP225.cash ≈180點。
      // 如果你的 broker 這幾個商品的小數位數不是2位，這組數字會整個跑掉
      // （例如變成離現價幾百倍遠或近到瞬間停損），上線前務必先用
      // Print(SymbolInfoInteger("US100.cash",SYMBOL_DIGITS)) 之類的方式
      // 確認實際小數位數，再校正這裡的數字。
      fx_rules[21].symbol="US100.CASH"; fx_rules[21].sl_pips=8000.00;  fx_rules[21].tp_pips=16000.00; fx_rules[21].atr_threshold=6000.00;  fx_rules[21].lot_size=0.01;
      fx_rules[22].symbol="US500.CASH"; fx_rules[22].sl_pips=2500.00;  fx_rules[22].tp_pips=5000.00;  fx_rules[22].atr_threshold=1800.00;  fx_rules[22].lot_size=0.01;
      fx_rules[23].symbol="US30.CASH";  fx_rules[23].sl_pips=15000.00; fx_rules[23].tp_pips=30000.00; fx_rules[23].atr_threshold=11000.00; fx_rules[23].lot_size=0.01;
      fx_rules[24].symbol="JP225.CASH"; fx_rules[24].sl_pips=18000.00; fx_rules[24].tp_pips=36000.00; fx_rules[24].atr_threshold=13000.00; fx_rules[24].lot_size=0.01;

      // ⚠️ EURUSD 為估計值，不是像其他 20 筆一樣回測校準出來的數字——
      // sl_pips 用同為 XXXUSD 報價、波動相近的 GBPUSD/AUDUSD/USDCAD 內插，
      // tp_pips=2×sl_pips、atr_threshold=(2/3)×sl_pips 沿用其餘各列的固定比例，
      // lot_size 依「每筆風險金額≈GBPUSD/AUDUSD/NZDUSD 三者的平均值」反推。
      // 正式交易前請自行用實際回測數據覆蓋這一列。
      fx_rules[20].symbol="EURUSD"; fx_rules[20].sl_pips=21.00; fx_rules[20].tp_pips=42.00;  fx_rules[20].atr_threshold=14.00;  fx_rules[20].lot_size=0.51;

      fx_rules[0].symbol="AUDJPY";  fx_rules[0].sl_pips=34.41;  fx_rules[0].tp_pips=68.82;   fx_rules[0].atr_threshold=22.94;   fx_rules[0].lot_size=0.49;
      fx_rules[1].symbol="AUDSGD";  fx_rules[1].sl_pips=22.51;  fx_rules[1].tp_pips=45.01;   fx_rules[1].atr_threshold=15.00;   fx_rules[1].lot_size=0.61;
      fx_rules[2].symbol="AUDUSD";  fx_rules[2].sl_pips=22.68;  fx_rules[2].tp_pips=45.36;   fx_rules[2].atr_threshold=15.12;   fx_rules[2].lot_size=0.48;
      fx_rules[3].symbol="CADJPY";  fx_rules[3].sl_pips=28.30;  fx_rules[3].tp_pips=56.60;   fx_rules[3].atr_threshold=18.87;   fx_rules[3].lot_size=0.61;
      fx_rules[4].symbol="CHFJPY";  fx_rules[4].sl_pips=44.36;  fx_rules[4].tp_pips=88.73;   fx_rules[4].atr_threshold=29.58;   fx_rules[4].lot_size=0.37;
      fx_rules[5].symbol="EURDKK";  fx_rules[5].sl_pips=21.20;  fx_rules[5].tp_pips=42.41;   fx_rules[5].atr_threshold=14.14;   fx_rules[5].lot_size=4.05;
      fx_rules[6].symbol="EURGBP";  fx_rules[6].sl_pips=12.88;  fx_rules[6].tp_pips=25.76;   fx_rules[6].atr_threshold=8.59;    fx_rules[6].lot_size=0.64;
      fx_rules[7].symbol="EURJPY";  fx_rules[7].sl_pips=38.52;  fx_rules[7].tp_pips=77.05;   fx_rules[7].atr_threshold=25.68;   fx_rules[7].lot_size=0.45;
      fx_rules[8].symbol="GBPJPY";  fx_rules[8].sl_pips=48.27;  fx_rules[8].tp_pips=96.53;   fx_rules[8].atr_threshold=32.18;   fx_rules[8].lot_size=0.36;
      fx_rules[9].symbol="GBPUSD";  fx_rules[9].sl_pips=29.70;  fx_rules[9].tp_pips=59.41;   fx_rules[9].atr_threshold=19.80;   fx_rules[9].lot_size=0.35;
      fx_rules[10].symbol="NOKJPY"; fx_rules[10].sl_pips=6.03;  fx_rules[10].tp_pips=12.06;  fx_rules[10].atr_threshold=4.02;   fx_rules[10].lot_size=2.75;
      fx_rules[11].symbol="NOKSEK"; fx_rules[11].sl_pips=31.87; fx_rules[11].tp_pips=63.75;  fx_rules[11].atr_threshold=21.25;  fx_rules[11].lot_size=3.08;
      fx_rules[12].symbol="NZDJPY"; fx_rules[12].sl_pips=26.79; fx_rules[12].tp_pips=53.59;  fx_rules[12].atr_threshold=17.86;  fx_rules[12].lot_size=0.64;
      fx_rules[13].symbol="NZDUSD"; fx_rules[13].sl_pips=17.77; fx_rules[13].tp_pips=35.54;  fx_rules[13].atr_threshold=11.85;  fx_rules[13].lot_size=0.61;
      fx_rules[14].symbol="SEKJPY"; fx_rules[14].sl_pips=6.25;  fx_rules[14].tp_pips=12.51;  fx_rules[14].atr_threshold=4.17;   fx_rules[14].lot_size=2.64;
      fx_rules[15].symbol="USDCAD"; fx_rules[15].sl_pips=22.26; fx_rules[15].tp_pips=44.52;  fx_rules[15].atr_threshold=14.84;  fx_rules[15].lot_size=0.68;
      fx_rules[16].symbol="USDCHF"; fx_rules[16].sl_pips=19.38; fx_rules[16].tp_pips=38.77;  fx_rules[16].atr_threshold=12.92;  fx_rules[16].lot_size=0.44;
      fx_rules[17].symbol="USDJPY"; fx_rules[17].sl_pips=36.01; fx_rules[17].tp_pips=72.02;  fx_rules[17].atr_threshold=24.01;  fx_rules[17].lot_size=0.48;
      fx_rules[18].symbol="USDMXN"; fx_rules[18].sl_pips=543.57;fx_rules[18].tp_pips=1087.15;fx_rules[18].atr_threshold=362.38; fx_rules[18].lot_size=0.37;
      fx_rules[19].symbol="USDTRY"; fx_rules[19].sl_pips=544.20;fx_rules[19].tp_pips=1088.39;fx_rules[19].atr_threshold=362.80; fx_rules[19].lot_size=1.07;
   }

   bool ApplyRuleBySymbol(string chart_symbol)
   {
      int idx = FindRule(chart_symbol);
      if(idx < 0) return false;

      sl_pips       = fx_rules[idx].sl_pips;
      tp_pips       = fx_rules[idx].tp_pips;
      atr_threshold = fx_rules[idx].atr_threshold;
      lot_size      = fx_rules[idx].lot_size;
      return true;
   }

   //-----------------------------------------------------------------
   // 建構子
   //-----------------------------------------------------------------
   CFilterLib_Pro(long mg, ENUM_TIMEFRAMES tf=PERIOD_H1)
   {
      magic = mg;
      m_tf  = tf;
      trade.SetExpertMagicNumber(magic);

      DayLossLimit         = -350.0;
      AccountEquityFloor   = 9600.0;
      VolatilityMultiplier = 2.0;
      MaxSymbolStopLoss    = 3;

      MinBarBodyPips = 8;
      MaxSwingBars = 5;
      StepProfitPips = 30;
      StepLockPips = 15;

      TradingStartHour = 7;  TradingStartMin = 15;
      NoTradeStartHour = 4;  NoTradeStartMin = 45;
      NoTradeEndHour   = 7;  NoTradeEndMin   = 15;
      ForceCloseHour   = 5;  ForceCloseMin   = 50;

      NoTrade2StartHour = 17; NoTrade2StartMin = 50;
      NoTrade2EndHour   = 18; NoTrade2EndMin   = 10;

      lastResetDay     = 0;
      forceClosedToday = false;

      InitRules();

      for(int i=0; i<20; i++)
      {
         m_hEmaFast[i]     = INVALID_HANDLE;
         m_hEmaSlow[i]     = INVALID_HANDLE;
         m_hRSI[i]         = INVALID_HANDLE;
         m_hBB[i]          = INVALID_HANDLE;
         m_hMACD[i]        = INVALID_HANDLE;
         m_hStoch[i]       = INVALID_HANDLE;
         m_lastBarTime[i]  = 0;
         m_barUsed[i]      = false;
         m_lastBarTimeF[i] = 0;
      }
   }

   //-----------------------------------------------------------------
   // InitIndicators / DeinitIndicators（供EA OnInit/OnDeinit）
   //-----------------------------------------------------------------
   bool InitIndicators()
   {
      for(int i=0; i<20; i++)
      {
         string sym = SYMBOLS[i];
         m_hEmaFast[i] = iMA(sym, m_tf, EMA_FAST, 0, MODE_EMA, PRICE_CLOSE);
         m_hEmaSlow[i] = iMA(sym, m_tf, EMA_SLOW, 0, MODE_EMA, PRICE_CLOSE);
         m_hRSI[i]     = iRSI(sym, m_tf, RSI_PERIOD, PRICE_CLOSE);

         if(sym == "USDJPY")
            m_hBB[i] = iBands(sym, m_tf, BB_PERIOD_USDJPY, 0, BB_DEV_USDJPY, PRICE_CLOSE);
         else
            m_hBB[i] = iBands(sym, m_tf, BB_PERIOD_DEFAULT, 0, BB_DEV_DEFAULT, PRICE_CLOSE);

         m_hMACD[i]  = iMACD(sym, m_tf, MACD_FAST, MACD_SLOW, MACD_SIG, PRICE_CLOSE);
         m_hStoch[i] = iStochastic(sym, m_tf, KdjPeriod(sym), KDJ_KD, KDJ_KK, MODE_SMA, STO_LOWHIGH);

         if(m_hEmaFast[i] == INVALID_HANDLE || m_hEmaSlow[i] == INVALID_HANDLE ||
            m_hRSI[i]     == INVALID_HANDLE || m_hBB[i]      == INVALID_HANDLE ||
            m_hMACD[i]    == INVALID_HANDLE || m_hStoch[i]   == INVALID_HANDLE)
         {
            PrintFormat("FilterLib v5: handle建立失敗 %s (err=%d)", sym, GetLastError());
            return false;
         }
      }

      Print("FilterLib v5: 全部指標handle建立完成");
      return true;
   }

   void DeinitIndicators()
   {
      for(int i=0; i<20; i++)
      {
         if(m_hEmaFast[i] != INVALID_HANDLE) { IndicatorRelease(m_hEmaFast[i]); m_hEmaFast[i] = INVALID_HANDLE; }
         if(m_hEmaSlow[i] != INVALID_HANDLE) { IndicatorRelease(m_hEmaSlow[i]); m_hEmaSlow[i] = INVALID_HANDLE; }
         if(m_hRSI[i]     != INVALID_HANDLE) { IndicatorRelease(m_hRSI[i]);     m_hRSI[i]     = INVALID_HANDLE; }
         if(m_hBB[i]      != INVALID_HANDLE) { IndicatorRelease(m_hBB[i]);      m_hBB[i]      = INVALID_HANDLE; }
         if(m_hMACD[i]    != INVALID_HANDLE) { IndicatorRelease(m_hMACD[i]);    m_hMACD[i]    = INVALID_HANDLE; }
         if(m_hStoch[i]   != INVALID_HANDLE) { IndicatorRelease(m_hStoch[i]);   m_hStoch[i]   = INVALID_HANDLE; }
      }

      Print("FilterLib v5: 所有指標handle已釋放");
   }

   //-----------------------------------------------------------------
   // GetSignal（供EA TryOpenPositions）
   //-----------------------------------------------------------------
   ENUM_SIG GetSignal(const string sym, bool confirm=true)
   {
      int idx = SymIdx(sym);
      if(idx < 0) return SIG_NONE;
      return _calcSignalShift(idx, confirm ? 1 : 0);
   }

   //-----------------------------------------------------------------
   // CheckNewBar / MarkBarUsed / IsBarUsed（供EA開倉邏輯）
   //-----------------------------------------------------------------
   bool CheckNewBar(const string sym)
   {
      int idx = SymIdx(sym);
      if(idx < 0) return false;

      datetime barTime[1];
      if(CopyTime(sym, m_tf, 0, 1, barTime) != 1) return false;

      if(barTime[0] != m_lastBarTime[idx])
      {
         m_lastBarTime[idx] = barTime[0];
         m_barUsed[idx]     = false;
         return true;
      }
      return false;
   }

   void MarkBarUsed(const string sym)
   {
      int idx = SymIdx(sym);
      if(idx >= 0) m_barUsed[idx] = true;
   }

   bool IsBarUsed(const string sym)
   {
      int idx = SymIdx(sym);
      if(idx < 0) return true;
      return m_barUsed[idx];
   }

   //-----------------------------------------------------------------
   // v4 公開方法
   //-----------------------------------------------------------------
   double GetLotSize(string sym)
   {
      int idx = FindRule(sym);
      return (idx < 0) ? 0.01 : fx_rules[idx].lot_size;
   }

   bool IsVolatilityNormal(string sym)
   {
      int idx = FindRule(sym);
      if(idx < 0) return true;

      int h = iATR(sym, PERIOD_M1, 1);
      if(h == INVALID_HANDLE) return true;

      double buf[];
      ArraySetAsSeries(buf, true);
      bool ok = (CopyBuffer(h, 0, 0, 1, buf) > 0);
      IndicatorRelease(h);
      if(!ok) return true;

      double atrPips = buf[0] / PipSize(sym);
      double limit   = fx_rules[idx].atr_threshold * VolatilityMultiplier;
      bool normal    = (atrPips < limit);

      if(!normal)
         Print("🚫 ", sym, " ATR=", DoubleToString(atrPips,1), " > ", DoubleToString(limit,1), " pips");

      return normal;
   }

   void CheckDailyReset()
   {
      MqlDateTime now = LocalNow();
      bool past = (now.hour > TradingStartHour || (now.hour == TradingStartHour && now.min >= TradingStartMin));

      if(lastResetDay == 0)
      {
         // EA/終端機重啟時，若已過當日交易起始時間，視為需要重置，
         // 避免沿用重啟前殘留的全局鎖（否則要等到隔天才會解鎖）
         if(past)
         {
            if(GlobalVariableCheck("PRO_DAY_LOCK"))
               GlobalVariableDel("PRO_DAY_LOCK");

            for(int i=SymbolsTotal(true)-1; i>=0; i--)
            {
               string s = SymbolName(i, true);
               string key = "PRO_LOCK_" + s;
               if(GlobalVariableCheck(key))
                  GlobalVariableDel(key);
            }
            Print("✅ 啟動時重置完成");
         }

         lastResetDay = TimeLocal();
         return;
      }

      MqlDateTime last;
      TimeToStruct(lastResetDay, last);

      bool newDay = (now.year != last.year || now.mon != last.mon || now.day != last.day);

      if(newDay && past)
      {
         if(GlobalVariableCheck("PRO_DAY_LOCK"))
            GlobalVariableDel("PRO_DAY_LOCK");

         for(int i=SymbolsTotal(true)-1; i>=0; i--)
         {
            string s = SymbolName(i, true);
            string key = "PRO_LOCK_" + s;
            if(GlobalVariableCheck(key))
               GlobalVariableDel(key);
         }

         lastResetDay     = TimeLocal();
         forceClosedToday = false;
         Print("✅ 每日重置完成");
      }
   }

   void CheckForceClose()
   {
      if(forceClosedToday) return;

      MqlDateTime t = LocalNow();
      int nowMin   = t.hour * 60 + t.min;
      int closeMin = ForceCloseHour * 60 + ForceCloseMin;

      // 用「分鐘數是否已過強平時間」取代「小時剛好相等」，
      // 避免錯過該小時內唯一一次 tick 就導致當天永遠不強平
      if(nowMin >= closeMin)
      {
         CloseAll("05:50強平");
         forceClosedToday = true;
      }
   }

   bool IsInNoTradeWindow()
   {
      MqlDateTime t = LocalNow();
      int now = t.hour * 60 + t.min;

      int s1 = NoTradeStartHour * 60 + NoTradeStartMin;
      int e1 = NoTradeEndHour   * 60 + NoTradeEndMin;
      if(now >= s1 && now < e1) return true;

      int s2 = NoTrade2StartHour * 60 + NoTrade2StartMin;
      int e2 = NoTrade2EndHour   * 60 + NoTrade2EndMin;
      if(now >= s2 && now < e2) return true;

      return false;
   }

   double CalcTrailingStop(string sym, int direction, double entryPrice, double currentSL)
   {
      double pip = PipSize(sym);
      double newSL = currentSL;

      double highBuf[], lowBuf[], openBuf[], closeBuf[];
      ArraySetAsSeries(highBuf, true);
      ArraySetAsSeries(lowBuf, true);
      ArraySetAsSeries(openBuf, true);
      ArraySetAsSeries(closeBuf, true);

      int bars = 30;
      int gotHigh  = CopyHigh(sym, PERIOD_M12, 1, bars, highBuf);
      int gotLow   = CopyLow(sym, PERIOD_M12, 1, bars, lowBuf);
      int gotOpen  = CopyOpen(sym, PERIOD_M12, 1, bars, openBuf);
      int gotClose = CopyClose(sym, PERIOD_M12, 1, bars, closeBuf);

      // 剛訂閱/歷史資料尚未補齊時，Copy* 可能回傳少於 bars 根，
      // 迴圈只能掃到實際回傳的最小根數，避免陣列越界
      int available = MathMin(MathMin(gotHigh, gotLow), MathMin(gotOpen, gotClose));
      if(available < 0) available = 0;

      int    validCount = 0;
      double swingLevel = 0.0;

      for(int i=0; i<available && validCount<MaxSwingBars; i++)
      {
         double bodyPips = MathAbs(closeBuf[i] - openBuf[i]) / pip;
         if(bodyPips < MinBarBodyPips) continue;

         validCount++;

         if(direction == 1)
         {
            if(swingLevel == 0.0 || lowBuf[i] < swingLevel)
               swingLevel = lowBuf[i];
         }
         else
         {
            if(swingLevel == 0.0 || highBuf[i] > swingLevel)
               swingLevel = highBuf[i];
         }
      }

      if(validCount > 0 && swingLevel > 0.0)
      {
         if(direction == 1 && swingLevel > currentSL)
            newSL = swingLevel;

         if(direction == -1 && (currentSL <= 0.0 || swingLevel < currentSL))
            newSL = swingLevel;

         return newSL;
      }

      double currentPrice = (direction == 1) ? SymbolInfoDouble(sym, SYMBOL_BID)
                                             : SymbolInfoDouble(sym, SYMBOL_ASK);

      double profitPips = (direction == 1) ? (currentPrice - entryPrice) / pip
                                           : (entryPrice - currentPrice) / pip;

      if(profitPips >= StepProfitPips)
      {
         int    steps    = (int)(profitPips / StepProfitPips);
         double lockDist = steps * StepLockPips * pip;
         double stepSL   = (direction == 1) ? entryPrice + lockDist
                                            : entryPrice - lockDist;

         if(direction == 1 && stepSL > currentSL) newSL = stepSL;
         if(direction == -1 && stepSL < currentSL) newSL = stepSL;
      }

      return newSL;
   }

   void MonitorPositions()
   {
      CheckDailyReset();
      CheckForceClose();

      if(AccountInfoDouble(ACCOUNT_EQUITY) <= AccountEquityFloor)
      {
         CloseAll("淨值跌破$" + DoubleToString(AccountEquityFloor,0));
         LockDay();
         return;
      }

      if(GetTotalDayPnL() <= DayLossLimit)
      {
         CloseAll("總虧損" + DoubleToString(DayLossLimit,0));
         LockDay();
         return;
      }

      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!pos.SelectByIndex(i) || pos.Magic() != magic) continue;

         string sym    = pos.Symbol();
         ulong  ticket = pos.Ticket();
         int    dir    = (pos.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
         double entry  = pos.PriceOpen();
         double curSL  = pos.StopLoss();
         double curTP  = pos.TakeProfit();
         double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
         int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         int    sidx   = SymIdx(sym);

         if(IsSymbolLocked(sym)) continue;

         if(GetSymbolStopLossCount(sym) >= MaxSymbolStopLoss)
         {
            Print("⛔ ", sym, " 當日止損達上限，鎖幣今日不再開倉");
            LockSymbol(sym);
            continue;
         }

         if(!IsVolatilityNormal(sym))
         {
            CloseSymbol(sym, "ATR波動異常");
            LockSymbol(sym);
            continue;
         }

         double newSL = CalcTrailingStop(sym, dir, entry, curSL);
         if(MathAbs(newSL - curSL) > point * 2)
         {
            trade.PositionModify(ticket, NormalizeDouble(newSL, digits), curTP);
            Print("📐 SL ", sym, " ", DoubleToString(curSL,5), " -> ", DoubleToString(newSL,5), " [追蹤]");
         }

         if(sidx >= 0 && _checkNewBarF(sidx))
         {
            ENUM_SIG sig = _calcSignalShift(sidx, 1);
            if((dir == 1 && sig == SIG_SELL) || (dir == -1 && sig == SIG_BUY))
            {
               Print("🔄 [F] 反向信號 ", sym, " ticket=", ticket, " → 主動平倉");
               trade.PositionClose(ticket);
            }
         }
      }
   }

   bool AllowTrading(string sym, int direction, double &sl, double &tp)
   {
      if(IsDayLocked())                                           return false;
      if(IsSymbolLocked(sym))                                     return false;
      if(IsInNoTradeWindow())                                     return false;
      if(!IsVolatilityNormal(sym))                                return false;
      if(AccountInfoDouble(ACCOUNT_EQUITY) <= AccountEquityFloor) return false;
      if(GetTotalDayPnL() <= DayLossLimit)                        return false;

      if(GetSymbolStopLossCount(sym) >= MaxSymbolStopLoss)
      {
         Print("⛔ ", sym, " 當日止損已達上限，禁止開倉");
         return false;
      }

      int idx = FindRule(sym);
      if(idx < 0)
      {
         Print("⚠️ ", sym, " 無規則");
         return false;
      }

      double pip = PipSize(sym);
      double slD = fx_rules[idx].sl_pips * pip;
      double tpD = fx_rules[idx].tp_pips * pip;

      if(direction == 1)
      {
         double a = SymbolInfoDouble(sym, SYMBOL_ASK);
         sl = a - slD;
         tp = a + tpD;
      }
      else
      {
         double b = SymbolInfoDouble(sym, SYMBOL_BID);
         sl = b + slD;
         tp = b - tpD;
      }

      return true;
   }

   string GetStatusReport(string sym)
   {
      MqlDateTime t = LocalNow();
      double atrPips = 0.0, atrLimit = 0.0;
      int idx = FindRule(sym);

      if(idx >= 0)
      {
         int h = iATR(sym, PERIOD_M1, 1);
         if(h != INVALID_HANDLE)
         {
            double buf[];
            ArraySetAsSeries(buf, true);
            if(CopyBuffer(h, 0, 0, 1, buf) > 0)
               atrPips = buf[0] / PipSize(sym);
            IndicatorRelease(h);
         }

         atrLimit = fx_rules[idx].atr_threshold * VolatilityMultiplier;
      }

      int slCount = GetSymbolStopLossCount(sym);
      string slInfo = "";

      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!pos.SelectByIndex(i) || pos.Symbol() != sym || pos.Magic() != magic) continue;

         int dir = (pos.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
         double nSL = CalcTrailingStop(sym, dir, pos.PriceOpen(), pos.StopLoss());
         int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

         slInfo += StringFormat("  #%d %s  入場=%.*f  SL=%.*f->%.*f  TP=%.*f\n",
                                pos.Ticket(), (dir==1 ? "BUY" : "SELL"),
                                dg, pos.PriceOpen(),
                                dg, pos.StopLoss(), dg, nSL,
                                dg, pos.TakeProfit());
      }

      string w1 = StringFormat("%02d:%02d~%02d:%02d", NoTradeStartHour, NoTradeStartMin, NoTradeEndHour, NoTradeEndMin);
      string w2 = StringFormat("%02d:%02d~%02d:%02d", NoTrade2StartHour, NoTrade2StartMin, NoTrade2EndHour, NoTrade2EndMin);

      string r = "━━━━━━━━━━━━━━━━━━━━━━━━\n";
      r += StringFormat("⏰ %02d:%02d:%02d  淨值:$%.2f(警戒$%.0f)\n",
                        t.hour, t.min, t.sec,
                        AccountInfoDouble(ACCOUNT_EQUITY), AccountEquityFloor);
      r += StringFormat("📊 總PnL:$%.2f(限$%.0f)\n", GetTotalDayPnL(), DayLossLimit);
      r += StringFormat("📈 ATR:%.1f pips  上限:%.1f pips  %s\n",
                        atrPips, atrLimit, (atrPips < atrLimit) ? "✅正常" : "🚫異常");
      r += StringFormat("🔒 全局:%s  貨幣:%s\n",
                        IsDayLocked() ? "鎖" : "開",
                        IsSymbolLocked(sym) ? "鎖" : "開");
      r += StringFormat("🚫 禁單時段1:%s  時段2:%s(MT5結算)  現在:%s\n",
                        w1, w2, IsInNoTradeWindow() ? "⛔禁單中" : "✅正常");
      r += StringFormat("⛔ %s 今日止損:%d/%d次\n", sym, slCount, MaxSymbolStopLoss);
      r += StringFormat("📐 追蹤SL: 有效K棒>=%dpips 最多%d根 | 階梯:+%d->鎖%dpips\n",
                        MinBarBodyPips, MaxSwingBars, StepProfitPips, StepLockPips);

      if(idx >= 0)
         r += StringFormat("📋 %s  SL=%.2f  TP=%.2f  lot=%.2f\n",
                           sym, fx_rules[idx].sl_pips, fx_rules[idx].tp_pips, fx_rules[idx].lot_size);

      if(slInfo != "")
         r += slInfo;

      r += "━━━━━━━━━━━━━━━━━━━━━━━━\n";
      return r;
   }
};

#endif // FILTERLIB_V5_MQH
//+------------------------------------------------------------------+
