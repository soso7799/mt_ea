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
const int SYMBOL_COUNT = 37;

const string SYMBOLS[SYMBOL_COUNT] = {

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
   "USDTRY",
   "USDCNH",   // 離岸人民幣（v5.8 新增，fx_rules 為估計值）
   // ⚠️ 以下7個是預留（金屬/石油/天然氣），一勞永逸先擴充進來備用，
   // 目前 MultiCurrency_EA.mq5 沒有交易這些商品，加進來只是讓 F段
   // 背景監控涵蓋得到；要實際交易還是要去 fx_rules[] 校準SL/TP數字。
   "XAUUSD",
   "XAGUSD",
   "XPTUSD",
   "XPDUSD",
   "USOIL.cash",
   "UKOIL.cash",
   "NATGAS.cash",
   // ⚠️ 以下9個是預留的股指（美股三大指數/歐洲主要指數/亞太主要指數），
   // 同樣只擴充F段背景監控涵蓋範圍，要實際交易一樣要去 fx_rules[] 校準SL/TP數字。
   "US30.cash",
   "NAS100.cash",
   "SPX500.cash",
   "GER40.cash",
   "UK100.cash",
   "FRA40.cash",
   "JPN225.cash",
   "AUS200.cash",
   "HK50.cash"
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
   for(int i=0; i<SYMBOL_COUNT; i++)
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

   int      m_hEmaFast[SYMBOL_COUNT];
   int      m_hEmaSlow[SYMBOL_COUNT];
   int      m_hRSI[SYMBOL_COUNT];
   int      m_hBB[SYMBOL_COUNT];
   int      m_hMACD[SYMBOL_COUNT];
   int      m_hStoch[SYMBOL_COUNT];

   datetime m_lastBarTimeF[SYMBOL_COUNT];

   // SYMBOLS[] 對應到券商實際名稱（處理 GBPJPY.m / GBPJPYpro / m.GBPJPY 等後綴前綴），
   // 找不到則為 ""，F段背景監控會略過該商品
   string   m_symName[SYMBOL_COUNT];

   // ATR(M1,1) handle 快取：原本 IsVolatilityNormal / GetStatusReport 每次呼叫都
   // iATR() 建立新 handle 再立即釋放，新 handle 通常還沒算好，CopyBuffer 失敗就直接放行，
   // 等於波動過濾從未生效（參考 BeeQuant12 BQ_Indicators.mqh 的修正）
   string   m_atrSym[];
   int      m_atrH[];

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
   //-----------------------------------------------------------------
   // 排程時間 = 伺服器時間 + ScheduleOffsetHours（預設 6 = 冬令台灣時間）
   // 所有每日排程（交易日起點、強平、禁單時段、每日重置）都用這個時間，
   // 跟著 FTMO 伺服器自動切換冬令/夏令：夏令時 05:45 對應台灣 04:45，
   // 永遠在伺服器換日(00:00)前 15 分鐘強平。回測時伺服器時間照樣正確。
   //-----------------------------------------------------------------
   datetime SchedNow()
   {
      return (datetime)((long)TimeTradeServer() + (long)ScheduleOffsetHours * 3600);
   }

   MqlDateTime LocalNow()
   {
      MqlDateTime t;
      TimeToStruct(SchedNow(), t);
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

      // 逐一比對已知的核心幣別代碼（6碼），而不是抓「第一段連續6個字母」，
      // 否則像 "mUSDJPY" 這種帶前綴的券商命名，會先比對到錯誤的 "MUSDJP"。
      // 註：金屬/能源/指數代碼非6碼，本比對法本來就比不到，維持走 idx<0 分支即可。
      for(int i=0; i<=StringLen(s)-6; i++)
      {
         string part = StringSubstr(s, i, 6);
         for(int k=0; k<SYMBOL_COUNT; k++)
         {
            if(part == SYMBOLS[k])
               return part;
         }
      }

      return s;
   }

   //-----------------------------------------------------------------
   // 券商商品名稱對應（參考 BeeQuant12 BQ_Multi.mqh）
   //-----------------------------------------------------------------
   string _resolveName(string want)
   {
      bool custom = false;
      if(SymbolExist(want, custom))
      {
         SymbolSelect(want, true);
         return want;
      }

      string up = want;
      StringToUpper(up);
      string best    = "";
      bool   bestSel = false;

      for(int i=0; i<SymbolsTotal(false); i++)
      {
         string name = SymbolName(i, false);
         string u    = name;
         StringToUpper(u);
         int p = StringFind(u, up);
         if(p < 0 || p > 3) continue;          // 只接受短前綴，例如 m.GBPJPY

         bool sel = (SymbolInfoInteger(name, SYMBOL_SELECT) != 0);
         if(best == "" || (sel && !bestSel) || (sel == bestSel && StringLen(name) < StringLen(best)))
         {
            best    = name;
            bestSel = sel;
         }
      }

      if(best != "") SymbolSelect(best, true);
      return best;
   }

   // 依券商實際名稱找 SYMBOLS[] 索引
   int _idxOf(string sym)
   {
      for(int i=0; i<SYMBOL_COUNT; i++)
         if(m_symName[i] != "" && m_symName[i] == sym) return i;
      return SymIdx(sym);
   }

   int _atrHandle(string sym)
   {
      for(int i=0; i<ArraySize(m_atrSym); i++)
         if(m_atrSym[i] == sym) return m_atrH[i];

      int h = iATR(sym, PERIOD_M1, 1);
      if(h == INVALID_HANDLE) return INVALID_HANDLE;

      int n = ArraySize(m_atrSym);
      ArrayResize(m_atrSym, n+1);
      ArrayResize(m_atrH,   n+1);
      m_atrSym[n] = sym;
      m_atrH[n]   = h;
      return h;
   }

   // 取 ATR(M1,1) pips；取值失敗回傳 false（handle 剛建立尚未計算完成時常見）
   bool _atrPips(string sym, double &atrPips)
   {
      int h = _atrHandle(sym);
      if(h == INVALID_HANDLE) return false;

      double buf[1];
      if(CopyBuffer(h, 0, 0, 1, buf) != 1) return false;
      if(buf[0] == EMPTY_VALUE || !MathIsValidNumber(buf[0])) return false;

      atrPips = buf[0] / PipSize(sym);
      return true;
   }

   //-----------------------------------------------------------------
   // 下單安全工具（參考 BeeQuant12 BQ_Trade.mqh）
   //-----------------------------------------------------------------
   int _volDigits(string sym)
   {
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      int d = 0;
      while(step > 0 && step < 1.0-1e-9 && d < 8) { step *= 10.0; d++; }
      return d;
   }

   double _normPrice(string sym, double p)
   {
      int    dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(ts <= 0) return NormalizeDouble(p, dg);
      return NormalizeDouble(MathRound(p/ts)*ts, dg);
   }

   // 券商允許的最小 SL/TP 距離（STOPS_LEVEL 與 FREEZE_LEVEL 取大者）
   double _minStopDist(string sym)
   {
      long lvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      long frz = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
      return (double)MathMax(lvl, frz) * SymbolInfoDouble(sym, SYMBOL_POINT);
   }

   // 把太靠近的 SL/TP 推到最小距離之外；ref = 平倉參考價（買單用 Bid、賣單用 Ask）
   void _fixStops(string sym, bool isBuy, double ref, double &sl, double &tp)
   {
      double d = _minStopDist(sym) + SymbolInfoDouble(sym, SYMBOL_POINT);
      if(sl > 0)
      {
         if(isBuy  && ref-sl < d) sl = ref - d;
         if(!isBuy && sl-ref < d) sl = ref + d;
         sl = _normPrice(sym, sl);
      }
      if(tp > 0)
      {
         if(isBuy  && tp-ref < d) tp = ref + d;
         if(!isBuy && ref-tp < d) tp = ref - d;
         tp = _normPrice(sym, tp);
      }
   }

   bool _resultOK(string sym, string what)
   {
      uint rc = trade.ResultRetcode();
      if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL)
         return true;
      PrintFormat("❌ [%s] %s 失敗 retcode=%u %s", sym, what, rc, trade.ResultRetcodeDescription());
      return false;
   }

   bool _retryable()
   {
      uint rc = trade.ResultRetcode();
      return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
              rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TIMEOUT);
   }

   bool _closeTicket(ulong ticket, string sym)
   {
      if(!TradingEnabled) return false;   // 只統計模式：絕不平倉
      trade.SetTypeFillingBySymbol(sym);
      trade.PositionClose(ticket);
      return _resultOK(sym, "平倉");
   }

   int FindRule(string sym)
   {
      string core = GetCoreSymbol(sym);
      for(int i=0; i<ArraySize(fx_rules); i++)
         if(fx_rules[i].symbol == core) return i;
      return -1;
   }

   // 排程時間 - 伺服器時間。成交歷史是伺服器時間，交易日起點要換算後才能拿去 HistorySelect
   long ServerOffset()
   {
      return (long)ScheduleOffsetHours * 3600;
   }

   // 今日（排程時間 TradingStart 起）成交歷史，以伺服器時間查詢
   bool SelectTodayHistory()
   {
      datetime from = (datetime)((long)GetTradingDayStart() - ServerOffset());
      return HistorySelect(from, TimeTradeServer() + 60);
   }

   datetime GetTradingDayStart()
   {
      MqlDateTime t = LocalNow();
      t.hour = TradingStartHour;
      t.min  = TradingStartMin;
      t.sec  = 0;

      datetime start = StructToTime(t);
      if(SchedNow() < start)
         return start - 86400;

      return start;
   }

   //-----------------------------------------------------------------
   // F段專用新K棒偵測（獨立計時器）
   //-----------------------------------------------------------------
   bool _checkNewBarF(int idx)
   {
      if(m_symName[idx] == "") return false;

      datetime barTime[1];
      if(CopyTime(m_symName[idx], m_tf, 0, 1, barTime) != 1) return false;

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
      string sym = m_symName[idx];
      if(sym == "") return SIG_NONE;
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
      SelectTodayHistory();

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
      SelectTodayHistory();

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

         if(_closeTicket(ticket, sym))
            Print("✅ 全平 ", sym, " | ", reason);
      }
   }

   void CloseSymbol(string sym, string reason="")
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!pos.SelectByIndex(i) || pos.Magic() != magic || pos.Symbol() != sym) continue;

         ulong ticket = pos.Ticket();
         if(_closeTicket(ticket, sym))
            Print("✅ 平倉 ", sym, " | ", reason);
      }
   }

public:
   //-----------------------------------------------------------------
   // v4 公開參數
   //-----------------------------------------------------------------
   // 目前在新聞時段的商品，格式 ";USDJPY;EURUSD;"（由 EA 每個循環更新）
   // false = 只統計模式：OpenMarket 不下單、不平倉、不改單、不做持倉管理
   bool   TradingEnabled;

   string NewsBlocked;
   bool   IsNewsBlocked(string sym) { return StringFind(NewsBlocked, ";" + sym + ";") >= 0; }

   // 全部平倉（週五收盤前等 EA 端規則使用）
   void   CloseAllPositions(string reason) { CloseAll(reason); }

   double DayLossLimit;
   double AccountEquityFloor;
   double VolatilityMultiplier;
   int    MaxSymbolStopLoss;

   int MinBarBodyPips;
   int MaxSwingBars;
   int StepProfitPips;
   int StepLockPips;

   int ScheduleOffsetHours;   // 排程時間 = 伺服器時間 + N 小時（FTMO + 台灣 = 6，冬夏令自動跟隨伺服器）

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
      ArrayResize(fx_rules, 22);

      // ⚠️ EURUSD 為估計值，不是像其他 20 筆一樣回測校準出來的數字——
      // sl_pips 用同為 XXXUSD 報價、波動相近的 GBPUSD/AUDUSD/USDCAD 內插，
      // tp_pips=2×sl_pips、atr_threshold=(2/3)×sl_pips 沿用其餘各列的固定比例，
      // lot_size 依「每筆風險金額≈GBPUSD/AUDUSD/NZDUSD 三者的平均值」反推。
      // 正式交易前請自行用實際回測數據覆蓋這一列。
      // ⚠️ USDCNH 同樣是估計值：日均波幅約 300~400 pips(0.0001)，依 EURUSD「止損≈日均波幅 28%」
      // 的比例推得 sl≈100 pips；tp=2×sl、atr_threshold=(2/3)×sl 沿用固定比例；
      // 1 手每 pip 約 $1.39(=10/7.2)，lot 依每筆風險≈$107(同 EURUSD) 反推。正式交易前請用回測數據覆蓋。
      fx_rules[21].symbol="USDCNH"; fx_rules[21].sl_pips=100.00; fx_rules[21].tp_pips=200.00; fx_rules[21].atr_threshold=66.67; fx_rules[21].lot_size=0.77;

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

      ScheduleOffsetHours = 6;
      TradingStartHour = 7;  TradingStartMin = 15;
      NoTradeStartHour = 4;  NoTradeStartMin = 45;
      NoTradeEndHour   = 7;  NoTradeEndMin   = 15;
      ForceCloseHour   = 5;  ForceCloseMin   = 45;

      NoTrade2StartHour = 17; NoTrade2StartMin = 50;
      NoTrade2EndHour   = 18; NoTrade2EndMin   = 10;

      lastResetDay     = 0;
      forceClosedToday = false;
      NewsBlocked      = "";
      TradingEnabled   = true;

      InitRules();

      for(int i=0; i<SYMBOL_COUNT; i++)
      {
         m_hEmaFast[i]     = INVALID_HANDLE;
         m_hEmaSlow[i]     = INVALID_HANDLE;
         m_hRSI[i]         = INVALID_HANDLE;
         m_hBB[i]          = INVALID_HANDLE;
         m_hMACD[i]        = INVALID_HANDLE;
         m_hStoch[i]       = INVALID_HANDLE;
         m_lastBarTimeF[i] = 0;
         m_symName[i]      = "";
      }
   }

   // 策略週期：F段反向信號、追蹤停損擺動點都用這個週期，需在 InitIndicators 之前呼叫
   void SetTimeframe(ENUM_TIMEFRAMES tf)
   {
      m_tf = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : tf;
   }

   ENUM_TIMEFRAMES Timeframe() { return m_tf; }

   //-----------------------------------------------------------------
   // InitIndicators / DeinitIndicators（供EA OnInit/OnDeinit）
   //-----------------------------------------------------------------
   bool InitIndicators()
   {
      int failCount = 0;

      for(int i=0; i<SYMBOL_COUNT; i++)
      {
         // 對應券商實際名稱（含後綴/前綴），並自動加入 Market Watch；
         // 券商沒有這個商品就整個跳過，不影響其餘商品。
         string sym = _resolveName(SYMBOLS[i]);
         m_symName[i] = sym;
         if(sym == "")
         {
            failCount++;
            continue;
         }

         m_hEmaFast[i] = iMA(sym, m_tf, EMA_FAST, 0, MODE_EMA, PRICE_CLOSE);
         m_hEmaSlow[i] = iMA(sym, m_tf, EMA_SLOW, 0, MODE_EMA, PRICE_CLOSE);
         m_hRSI[i]     = iRSI(sym, m_tf, RSI_PERIOD, PRICE_CLOSE);

         if(SYMBOLS[i] == "USDJPY")
            m_hBB[i] = iBands(sym, m_tf, BB_PERIOD_USDJPY, 0, BB_DEV_USDJPY, PRICE_CLOSE);
         else
            m_hBB[i] = iBands(sym, m_tf, BB_PERIOD_DEFAULT, 0, BB_DEV_DEFAULT, PRICE_CLOSE);

         m_hMACD[i]  = iMACD(sym, m_tf, MACD_FAST, MACD_SLOW, MACD_SIG, PRICE_CLOSE);
         m_hStoch[i] = iStochastic(sym, m_tf, KdjPeriod(SYMBOLS[i]), KDJ_KD, KDJ_KK, MODE_SMA, STO_LOWHIGH);

         if(m_hEmaFast[i] == INVALID_HANDLE || m_hEmaSlow[i] == INVALID_HANDLE ||
            m_hRSI[i]     == INVALID_HANDLE || m_hBB[i]      == INVALID_HANDLE ||
            m_hMACD[i]    == INVALID_HANDLE || m_hStoch[i]   == INVALID_HANDLE)
         {
            // 該商品券商不支援/沒報價，釋放已建立的handle，整個標記跳過，
            // 不影響其餘商品——只有真正在用的貨幣對才需要InitIndicators 100%成功。
            PrintFormat("⚠️ FilterLib v5: %s 指標handle建立失敗(err=%d)，跳過此商品", sym, GetLastError());

            if(m_hEmaFast[i] != INVALID_HANDLE) { IndicatorRelease(m_hEmaFast[i]); m_hEmaFast[i] = INVALID_HANDLE; }
            if(m_hEmaSlow[i] != INVALID_HANDLE) { IndicatorRelease(m_hEmaSlow[i]); m_hEmaSlow[i] = INVALID_HANDLE; }
            if(m_hRSI[i]     != INVALID_HANDLE) { IndicatorRelease(m_hRSI[i]);     m_hRSI[i]     = INVALID_HANDLE; }
            if(m_hBB[i]      != INVALID_HANDLE) { IndicatorRelease(m_hBB[i]);      m_hBB[i]      = INVALID_HANDLE; }
            if(m_hMACD[i]    != INVALID_HANDLE) { IndicatorRelease(m_hMACD[i]);    m_hMACD[i]    = INVALID_HANDLE; }
            if(m_hStoch[i]   != INVALID_HANDLE) { IndicatorRelease(m_hStoch[i]);   m_hStoch[i]   = INVALID_HANDLE; }

            m_symName[i] = "";
            failCount++;
            continue;
         }
      }

      if(failCount > 0)
         PrintFormat("FilterLib v5: 指標handle建立完成，%d/%d 個商品被跳過", failCount, SYMBOL_COUNT);
      else
         Print("FilterLib v5: 全部指標handle建立完成");

      return true;
   }

   void DeinitIndicators()
   {
      for(int i=0; i<SYMBOL_COUNT; i++)
      {
         if(m_hEmaFast[i] != INVALID_HANDLE) { IndicatorRelease(m_hEmaFast[i]); m_hEmaFast[i] = INVALID_HANDLE; }
         if(m_hEmaSlow[i] != INVALID_HANDLE) { IndicatorRelease(m_hEmaSlow[i]); m_hEmaSlow[i] = INVALID_HANDLE; }
         if(m_hRSI[i]     != INVALID_HANDLE) { IndicatorRelease(m_hRSI[i]);     m_hRSI[i]     = INVALID_HANDLE; }
         if(m_hBB[i]      != INVALID_HANDLE) { IndicatorRelease(m_hBB[i]);      m_hBB[i]      = INVALID_HANDLE; }
         if(m_hMACD[i]    != INVALID_HANDLE) { IndicatorRelease(m_hMACD[i]);    m_hMACD[i]    = INVALID_HANDLE; }
         if(m_hStoch[i]   != INVALID_HANDLE) { IndicatorRelease(m_hStoch[i]);   m_hStoch[i]   = INVALID_HANDLE; }
      }

      for(int i=0; i<ArraySize(m_atrH); i++)
         if(m_atrH[i] != INVALID_HANDLE) IndicatorRelease(m_atrH[i]);
      ArrayResize(m_atrSym, 0);
      ArrayResize(m_atrH,   0);

      Print("FilterLib v5: 所有指標handle已釋放");
   }

   //-----------------------------------------------------------------
   // v4 公開方法
   //-----------------------------------------------------------------
   // 該商品規則的停損/停利距離（價格單位），供 ML 虛擬單標記使用；無規則回傳 false
   bool GetStopDistances(string sym, double &slDist, double &tpDist)
   {
      int idx = FindRule(sym);
      if(idx < 0) { slDist = 0; tpDist = 0; return false; }
      double pip = PipSize(sym);
      slDist = fx_rules[idx].sl_pips * pip;
      tpDist = fx_rules[idx].tp_pips * pip;
      return true;
   }

   double GetLotSize(string sym)
   {
      int idx = FindRule(sym);
      return (idx < 0) ? 0.01 : fx_rules[idx].lot_size;
   }

   //-----------------------------------------------------------------
   // 市價下單（參考 BeeQuant12 BQ_Trade.mqh）：
   //  * 依商品設定成交模式 (filling)，避免部分券商直接拒單
   //  * 手數對齊 volume_step / min / max
   //  * SL/TP 太近時推到券商最小距離
   //  * 檢查 retcode（不是只看 bool），遇到重新報價/價格變動自動重試 3 次
   //-----------------------------------------------------------------
   double NormalizeLots(string sym, double lots)
   {
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      if(step <= 0) step = 0.01;
      lots = MathFloor(lots/step + 1e-7) * step;
      if(lots < mn) lots = mn;
      if(mx > 0 && lots > mx) lots = mx;
      return NormalizeDouble(lots, _volDigits(sym));
   }

   bool OpenMarket(string sym, int direction, double lots, double sl, double tp, string cmt)
   {
      if(!TradingEnabled)
      {
         PrintFormat("📝 [只統計] %s %s 不下單", sym, direction > 0 ? "BUY" : "SELL");
         return false;
      }
      bool isBuy = (direction > 0);
      lots = NormalizeLots(sym, lots);

      double price = isBuy ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
      double margin = 0.0;
      if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, lots, price, margin) &&
         margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      {
         PrintFormat("❌ [%s] 保證金不足：需要 %.2f 可用 %.2f", sym, margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
         return false;
      }

      trade.SetTypeFillingBySymbol(sym);

      for(int attempt=0; attempt<3; attempt++)
      {
         double s = sl, t = tp;
         if(isBuy)
         {
            _fixStops(sym, true, SymbolInfoDouble(sym, SYMBOL_BID), s, t);
            trade.Buy(lots, sym, 0.0, s, t, cmt);
         }
         else
         {
            _fixStops(sym, false, SymbolInfoDouble(sym, SYMBOL_ASK), s, t);
            trade.Sell(lots, sym, 0.0, s, t, cmt);
         }

         if(_resultOK(sym, isBuy ? "Buy" : "Sell")) return true;
         if(!_retryable()) break;
         Sleep(200);
      }
      return false;
   }

   bool IsVolatilityNormal(string sym)
   {
      int idx = FindRule(sym);
      if(idx < 0) return true;

      // 取不到值（handle 剛建立/歷史未同步）時沿用原本行為：不擋單
      double atrPips = 0.0;
      if(!_atrPips(sym, atrPips)) return true;

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

         lastResetDay = SchedNow();
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

         lastResetDay     = SchedNow();
         forceClosedToday = false;
         Print("✅ 每日重置完成");
      }
   }

   void CheckForceClose()
   {
      MqlDateTime t = LocalNow();
      int nowMin   = t.hour * 60 + t.min;
      int closeMin = ForceCloseHour * 60 + ForceCloseMin;
      int startMin = TradingStartHour * 60 + TradingStartMin;

      // 強平時段 = 強平時間 ~ 下一個交易日起點（預設 05:45 ~ 07:15）。
      // 原本只判斷「現在 >= 強平時間」，而 forceClosedToday 要到 07:15 換日才重置：
      // 結果是 07:15 一換日就把倉位全平，隔天 05:45 反而因旗標未重置而不平；
      // EA 白天啟動時也會立刻全平。改成只在強平時段內動作，平不完就持續重試。
      bool inWin = (closeMin <= startMin) ? (nowMin >= closeMin && nowMin < startMin)
                                          : (nowMin >= closeMin || nowMin < startMin);
      if(!inWin)
      {
         forceClosedToday = false;
         return;
      }
      if(forceClosedToday) return;

      // 休市時平倉會失敗：每分鐘最多重試一次，避免洗版
      static datetime lastTry = 0;
      if(TimeLocal() - lastTry < 60) return;
      lastTry = TimeLocal();

      CloseAll(StringFormat("%02d:%02d強平", ForceCloseHour, ForceCloseMin));

      bool left = false;
      for(int i=PositionsTotal()-1; i>=0; i--)
         if(pos.SelectByIndex(i) && pos.Magic() == magic) { left = true; break; }
      forceClosedToday = !left;
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
      int gotHigh  = CopyHigh(sym, m_tf, 1, bars, highBuf);
      int gotLow   = CopyLow(sym, m_tf, 1, bars, lowBuf);
      int gotOpen  = CopyOpen(sym, m_tf, 1, bars, openBuf);
      int gotClose = CopyClose(sym, m_tf, 1, bars, closeBuf);

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
      if(!TradingEnabled) return;   // 只統計模式：不動任何持倉

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
         int    sidx   = _idxOf(sym);

         if(IsSymbolLocked(sym)) continue;

         if(GetSymbolStopLossCount(sym) >= MaxSymbolStopLoss)
         {
            Print("⛔ ", sym, " 當日止損達上限，鎖幣今日不再開倉");
            LockSymbol(sym);
            continue;
         }

         // 新聞時段：不做主動平倉（ATR異常平倉、反向信號平倉）也不收緊追蹤停損，
         // 避免在 FTMO 禁止成交的新聞前後產生成交；淨值/每日虧損的風控平倉不受影響
         if(IsNewsBlocked(sym)) continue;

         if(!IsVolatilityNormal(sym))
         {
            CloseSymbol(sym, "ATR波動異常");
            LockSymbol(sym);
            continue;
         }

         double newSL = CalcTrailingStop(sym, dir, entry, curSL);
         if(MathAbs(newSL - curSL) > point * 2)
         {
            // 新SL離現價太近會被券商拒絕（STOPS_LEVEL/FREEZE_LEVEL），這種情況本次先不改
            double minD = _minStopDist(sym) + point;
            bool tooClose = (dir == 1) ? (SymbolInfoDouble(sym, SYMBOL_BID) - newSL < minD)
                                       : (newSL - SymbolInfoDouble(sym, SYMBOL_ASK) < minD);
            if(!tooClose)
            {
               newSL = _normPrice(sym, newSL);
               trade.PositionModify(ticket, newSL, curTP);
               if(_resultOK(sym, "改SL"))
                  Print("📐 SL ", sym, " ", DoubleToString(curSL,digits), " -> ", DoubleToString(newSL,digits), " [追蹤]");
            }
         }

         if(sidx >= 0 && _checkNewBarF(sidx))
         {
            ENUM_SIG sig = _calcSignalShift(sidx, 1);
            if((dir == 1 && sig == SIG_SELL) || (dir == -1 && sig == SIG_BUY))
            {
               Print("🔄 [F] 反向信號 ", sym, " ticket=", ticket, " → 主動平倉");
               _closeTicket(ticket, sym);
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
         _atrPips(sym, atrPips);

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
      r += StringFormat("⏰ 排程 %02d:%02d:%02d  淨值:$%.2f(警戒$%.0f)\n",
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
