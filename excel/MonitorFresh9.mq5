//+------------------------------------------------------------------+
//| ExcelMonitor_All.mq5                                              |
//| 【重建版】原檔案已遺失，本檔案依下列線索重新還原：                  |
//|  1. Module1_v3.bas 開頭註解中列出的 Excel_Monitor.csv 36欄規格     |
//|  2. ExcelMonitor_TradingEA.mq5 的 ComputeM5Signal()，              |
//|     其註解明確標示「核心邏輯跟 ExcelMonitor_All.mq5 同一套」        |
//|                                                                    |
//|  3. gordon_full_analysis.py 裡的 compute_signals_detailed() /      |
//|     compute_weighted_score() / status_from_score()，該檔案註解     |
//|     明確標示「跟 ExcelMonitor_All.mq5 M5 那邊同一套邏輯」，          |
//|     因此第33/34欄「11指標綜合分數/判定」已改用這套真實公式還原，     |
//|     不再是本檔案先前版本裡憑空設計的猜測值。                        |
//|                                                                    |
//| ⚠️ 仍需留意的地方：                                                |
//|  MQL5沒有pandas，RSI/KD/MACD/肯特納這幾個需要「指數平滑」的指標，    |
//|  在本檔案裡是用EMA的seed-then-iterate方式手動實作(seed=最舊的一筆   |
//|  資料，往新的方向遞迴平滑)，用來逼近pandas .ewm(adjust=False) 的算  |
//|  法。這在資料夠長(數百根K棒以上)時應該會非常接近，但不保證每個小數   |
//|  點都跟Python算出來的完全一致，建議拿實際輸出對照 MultiTF_Signals   |
//|  .csv 的M15/H1分數，抽查幾筆數字量級是否合理。                      |
//|                                                                    |
//| 功能：每個商品定期計算36欄監控資料，寫入 Excel_Monitor.csv           |
//| 供 Module1_v3.bas 的 ImportMT5Data() 讀取。                        |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "9.20（全新檔名版+今日漲跌%改用M5自算）"
#property strict

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

//====================================================================
// 輸入參數
//====================================================================
input string CsvFileName        = "Excel_Monitor.csv"; // 輸出檔名(MQL5\Files\下)
input int    UpdateSeconds      = 15;      // 每隔幾秒重新計算並寫檔一次
input string ShortMAPeriods     = "9,9,9,9,9,9,9,9,9,9,9,9";
input string LongMAPeriods      = "21,21,21,21,21,21,21,21,21,21,21,21";
input int    ATRPeriod          = 14;
input int    SlopeLookback      = 3;
input int    VolumeAvgBars      = 20;
input int    TouchLookbackBars  = 300;
input int    TouchTolPoints     = 10;

//====================================================================
// 全域變數
//====================================================================
#define SYMBOL_COUNT 12
string Symbols[SYMBOL_COUNT] = {"EURUSD","GBPUSD","USDJPY","USDCAD","AUDUSD","NZDUSD","USDCHF","XAUUSD",
                                  "US500.cash","US30.cash","US100.cash","JP225.cash"};
int ShortMAArr[SYMBOL_COUNT];
int LongMAArr[SYMBOL_COUNT];

//+------------------------------------------------------------------+
int OnInit()
{
   ParsePeriods(ShortMAPeriods, ShortMAArr);
   ParsePeriods(LongMAPeriods, LongMAArr);
   for(int i=0;i<SYMBOL_COUNT;i++) SymbolSelect(Symbols[i], true);

   EventSetTimer(UpdateSeconds);
   Print("ExcelMonitor_All（重建版）已啟動，每 ", UpdateSeconds, " 秒更新一次 ", CsvFileName);

   WriteAllRows(); // 啟動時先寫一次，不用等第一個timer
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   WriteAllRows();
}

void ParsePeriods(string s, int &outArr[])
{
   string parts[];
   int n = StringSplit(s, ',', parts);
   for(int i=0;i<SYMBOL_COUNT;i++)
   {
      if(i<n) outArr[i] = (int)StringToInteger(parts[i]);
      else outArr[i] = 20;
   }
}

//+------------------------------------------------------------------+
//| 主流程：算完8個商品的36欄資料，整批寫入CSV(含標題列)                 |
//+------------------------------------------------------------------+
void WriteAllRows()
{
   int handle = FileOpen(CsvFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("寫入 ", CsvFileName, " 失敗，錯誤代碼：", GetLastError());
      return;
   }

   // 標題列(39欄，僅供人工檢視用，VBA匯入時會跳過這一行)
   // v9：TodayChangePct 移到 Bid 後面(第3欄)，方便一眼看到現價+今日漲跌%
   FileWrite(handle,
      "Symbol","Bid","TodayChangePct","AsiaLow","AsiaHigh","EuropeLow","EuropeHigh","USLow","USHigh",
      "WeekSupport","WeekResistance","RecentSupport","RecentResistance",
      "SupportTouch","ResistanceTouch","SupportValid","ResistanceValid",
      "ShortMA","LongMA","EMA","ShortMASlopePct","LongMASlopePct","EMASlopePct",
      "MAAlignment","CrossState","TrendScore","TrendJudgment","PersonalSL_ATR",
      "CurrentVolume","AverageVolume","VolumeState","FinalSignal",
      "CandlePattern","EntrySignal","CompositeScore","CompositeJudgment","UpdateTime",
      "SessionLevelTest","SessionBreakoutJudge");

   for(int i=0;i<SYMBOL_COUNT;i++)
   {
      WriteSymbolRow(handle, Symbols[i], ShortMAArr[i], LongMAArr[i]);
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| 計算單一商品的資料並寫入一行                                        |
//| 對應 Module1_v3.bas 開頭註解的欄位順序(0-based)：                   |
//|  0 Symbol .. 35 UpdateTime, 36 TodayChangePct(今日開盤至現在漲跌%)  |
//|  37 SessionLevelTest、38 SessionBreakoutJudge                     |
//|  (新增：用量能狀態判斷歐亞美盤高低點是否會突破)                      |
//+------------------------------------------------------------------+
void WriteSymbolRow(int handle, string sym, int shortPeriod, int longPeriod)
{
   int needBars = MathMax(longPeriod, TouchLookbackBars) + SlopeLookback + 50;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(sym, PERIOD_M5, 0, needBars, rates);
   if(copied < longPeriod+SlopeLookback+2)
   {
      // 資料不足也要寫滿39欄，避免VBA那邊又出現「欄位不足」錯誤
      FileWrite(handle, sym,0,0,0,0,0,0,0,0,0,0,0,0,0,0,"待確認","待確認",
                 0,0,0,0,0,0,"資料不足","資料不足",0,"資料不足",0,0,0,"正常",
                 "資料不足","資料不足","資料不足",0,"資料不足",
                 TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                 "","資料不足");
      return;
   }

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);

   //---------------- 1. 亞歐美盤區間 (欄2~7) ----------------
   double asiaLow, asiaHigh, euroLow, euroHigh, usLow, usHigh;
   GetSessionRange(sym, 0, 8, asiaLow, asiaHigh);
   GetSessionRange(sym, 8, 16, euroLow, euroHigh);
   GetSessionRange(sym, 13, 22, usLow, usHigh);

   //---------------- 2. 週線+近期支撐壓力 (欄8~15) ----------------
   double weekSupport=0, weekResistance=0;
   GetWeekRange(sym, weekSupport, weekResistance);

   int recentBars = MathMin(TouchLookbackBars, copied-1);
   double recentSupport = rates[1].low, recentResistance = rates[1].high;
   for(int i=1;i<=recentBars;i++)
   {
      if(rates[i].low  < recentSupport)    recentSupport = rates[i].low;
      if(rates[i].high > recentResistance) recentResistance = rates[i].high;
   }

   double srTol = TouchTolPoints * pt;
   int supportTouch=0, resistanceTouch=0;
   for(int i=1;i<=recentBars;i++)
   {
      if(MathAbs(rates[i].low - recentSupport) <= srTol) supportTouch++;
      if(MathAbs(rates[i].high - recentResistance) <= srTol) resistanceTouch++;
   }
   string supportValid = (supportTouch>=2) ? "有效" : "待確認";
   string resistanceValid = (resistanceTouch>=2) ? "有效" : "待確認";

   //---------------- 3. MA/EMA與斜率 (欄16~23) ----------------
   double shortMA_now  = SMA(rates, copied, shortPeriod, 0);
   double shortMA_prev = SMA(rates, copied, shortPeriod, SlopeLookback);
   double longMA_now   = SMA(rates, copied, longPeriod, 0);
   double longMA_prev  = SMA(rates, copied, longPeriod, SlopeLookback);

   double emaSeries[];
   int emaN = CalcEMA(rates, copied, longPeriod, emaSeries);
   double ema_now  = (emaN>0) ? emaSeries[0] : bid;
   double ema_prev = (emaN>SlopeLookback) ? emaSeries[SlopeLookback] : ema_now;
   double ema_1    = (emaN>1) ? emaSeries[1] : ema_now;
   double shortMA_1 = SMA(rates, copied, shortPeriod, 1);

   double shortSlopePct = (shortMA_prev!=0) ? (shortMA_now - shortMA_prev)/shortMA_prev*100.0 : 0;
   double longSlopePct  = (longMA_prev!=0)  ? (longMA_now  - longMA_prev )/longMA_prev*100.0  : 0;
   double emaSlopePct   = (ema_prev!=0)     ? (ema_now - ema_prev)/ema_prev*100.0             : 0;

   string maAlign;
   if(bid > shortMA_now && shortMA_now > ema_now)        maAlign = "多頭排列";
   else if(bid < shortMA_now && shortMA_now < ema_now)   maAlign = "空頭排列";
   else                                                  maAlign = "震盪糾結";

   string crossState;
   if(shortMA_1 <= ema_1 && shortMA_now > ema_now)      crossState = "黃金交叉";
   else if(shortMA_1 >= ema_1 && shortMA_now < ema_now) crossState = "死亡交叉";
   else                                                 crossState = maAlign;

   //---------------- 4. 趨勢分數/判定 (欄24~25，純MA家族邏輯) ----------------
   double shortAngle;
   {
      double atrRawTmp = CalcATR(rates, copied, ATRPeriod);
      double slopeNormBase = (atrRawTmp > 0) ? atrRawTmp * SlopeLookback : 1;
      shortAngle = MathArctan((shortMA_now - shortMA_prev) / slopeNormBase) * 180.0 / M_PI;
   }
   string trendJudge;
   double trendScore = ComputeTrendStrengthMA(bid, shortMA_now, ema_now, crossState, shortAngle, emaSlopePct, trendJudge);

   //---------------- 5. 個人化SL(ATR) (欄26) ----------------
   double atrRaw = CalcATR(rates, copied, ATRPeriod);
   double personalSL = atrRaw * 1.5;

   //---------------- 6. 量能 (欄27~29) ----------------
   long curVol = rates[0].tick_volume;
   double sumVol=0; int volCount=0;
   for(int i=1;i<=VolumeAvgBars && i<copied;i++){ sumVol += (double)rates[i].tick_volume; volCount++; }
   double avgVol = (volCount>0) ? sumVol/volCount : (double)curVol;

   string volState;
   if(avgVol<=0)                 volState = "正常";
   else if(curVol > avgVol*1.2)  volState = "放量";
   else if(curVol < avgVol*0.8)  volState = "縮量";
   else                          volState = "正常";

   //---------------- 7. 最終訊號 (欄30) ----------------
   double srBias = 0;
   if(MathAbs(bid - recentSupport) <= srTol*2 && supportValid=="有效")           srBias = 1.0;
   else if(MathAbs(bid - recentResistance) <= srTol*2 && resistanceValid=="有效") srBias = -1.0;
   else if(MathAbs(bid - weekSupport) <= srTol*2 && weekSupport>0)               srBias = 0.5;
   else if(MathAbs(bid - weekResistance) <= srTol*2 && weekResistance>0)         srBias = -0.5;

   double volMult = (volState=="放量") ? 1.3 : (volState=="縮量") ? 0.7 : 1.0;
   double weightedScore = trendScore / 2.0;
   double combinedScore = (weightedScore + srBias*0.5) * volMult;

   string finalSignal;
   if(combinedScore >= 1.3)        finalSignal = "強勢多";
   else if(combinedScore >= 0.4)   finalSignal = "偏多";
   else if(combinedScore <= -1.3)  finalSignal = "強勢空";
   else if(combinedScore <= -0.4)  finalSignal = "偏空";
   else                            finalSignal = "震盪";

   //---------------- 8. K棒型態 (欄31) ----------------
   string candlePattern = DetectCandlePattern(rates, copied);

   //---------------- 9. 進場建議 (欄32) ----------------
   string zoneType="", signalStrength="";
   bool hasKeyLevel = CheckKeyLevelConfluence(bid, weekSupport, weekResistance, recentSupport, recentResistance,
                                                asiaLow, asiaHigh, euroLow, euroHigh, usLow, usHigh,
                                                srTol, zoneType, signalStrength);

   bool volAnomaly = (volState=="放量" || volState=="縮量");
   bool bullPattern = (candlePattern=="看漲吞噬" || candlePattern=="看漲針線" || candlePattern=="晨星(3根反轉)");
   bool bearPattern = (candlePattern=="看跌吞噬" || candlePattern=="看跌針線" || candlePattern=="昏星(3根反轉)");

   bool triggerLong  = hasKeyLevel && zoneType=="支撐" && volAnomaly && (bullPattern || candlePattern=="十字星");
   bool triggerShort = hasKeyLevel && zoneType=="壓力" && volAnomaly && (bearPattern || candlePattern=="十字星");

   bool emaGateLong  = (emaSlopePct > 0);
   bool emaGateShort = (emaSlopePct < 0);
   bool finalBull = (finalSignal=="強勢多" || finalSignal=="偏多");
   bool finalBear = (finalSignal=="強勢空" || finalSignal=="偏空");

   string entrySignal;
   if(triggerLong && finalBull && emaGateLong)
      entrySignal = "["+signalStrength+"]可考慮多單("+zoneType+"+"+candlePattern+")";
   else if(triggerShort && finalBear && emaGateShort)
      entrySignal = "["+signalStrength+"]可考慮空單("+zoneType+"+"+candlePattern+")";
   else
      entrySignal = "觀望";

   //---------------- 10. 11指標綜合分數/判定 (欄33~34) ----------------
   // 對應 gordon_full_analysis.py 的 compute_votes_latest()/status_from_score()
   string compositeJudge;
   double compositeScore = ComputeComposite11(rates, copied, compositeJudge);

   //---------------- 11. 今日開盤至現在漲跌% (欄36) ----------------
   // 修正：iOpen(sym,PERIOD_D1,0)、CopyRates(sym,PERIOD_D1,...) 這兩種抓
   // D1資料的方式，實測在這個環境下對非圖表商品都可能傳回過期/錯誤的
   // 快取K棒(不會失敗、也不會回傳0，只是open價格本身就是錯的)。
   // 改成完全不碰D1，直接用本函式最上面已經抓到、確定可靠的M5陣列
   // (rates[]，週支撐/近支撐等其他欄位都是靠它算出來的，數值一直正常)，
   // 自己往回找「今天第一根M5 K棒」的開盤價當作今日開盤價。
   double dailyOpen = 0;
   {
      MqlDateTime dtNow;
      TimeToStruct(rates[0].time, dtNow);
      dtNow.hour=0; dtNow.min=0; dtNow.sec=0;
      datetime todayStart = StructToTime(dtNow);
      for(int i=copied-1;i>=0;i--)   // 從最舊的bar往新找，第一根落在今天範圍內的就是今日開盤
      {
         if(rates[i].time >= todayStart)
         {
            dailyOpen = rates[i].open;
            break;
         }
      }
   }
   double todayChangePct = (dailyOpen > 0) ? (bid - dailyOpen) / dailyOpen * 100.0 : 0;
   // 保留合理性檢查當最後一道保險：外匯主要貨幣對/主要指數單日漲跌正常
   // 不會超過±20%，超過就視為資料異常、回傳0，不要顯示離譜數字。
   if(MathAbs(todayChangePct) > 20.0)
      todayChangePct = 0;
   if(MathAbs(todayChangePct) > 20.0)
      todayChangePct = 0;

   //---------------- 12. 歐亞美盤高低點：用量能判斷是否會突破 (欄38~39，新增) ----------------
   string sessionLevelTest="", sessionBreakoutJudge="";
   CheckSessionBreakoutByVolume(bid, asiaLow, asiaHigh, euroLow, euroHigh, usLow, usHigh,
                                  srTol, volState, sessionLevelTest, sessionBreakoutJudge);

   //---------------- 寫入一行 ----------------
   FileWrite(handle,
      sym, bid, todayChangePct, asiaLow, asiaHigh, euroLow, euroHigh, usLow, usHigh,
      weekSupport, weekResistance, recentSupport, recentResistance,
      supportTouch, resistanceTouch, supportValid, resistanceValid,
      shortMA_now, longMA_now, ema_now, shortSlopePct, longSlopePct, emaSlopePct,
      maAlign, crossState, trendScore, trendJudge, personalSL,
      curVol, avgVol, volState, finalSignal,
      candlePattern, entrySignal, compositeScore, compositeJudge,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      sessionLevelTest, sessionBreakoutJudge);
}

//+------------------------------------------------------------------+
//| 用量能判斷歐亞美盤高低點(支撐/壓力)目前是否會被突破                  |
//| 做法：先找出報價目前最靠近的一個歐亞美關鍵位(容忍範圍抓寬一點，       |
//| srTol*3，才能在價格「靠近但還沒真正測到」時就先示警)，               |
//| 再用該關鍵位是否已被價格穿越 + 現有的量能狀態(放量/縮量/正常，        |
//| 沿用 WriteSymbolRow 裡 curVol vs avgVol 的判斷)交叉出結論：          |
//|  放量 + 已穿越關鍵位 → 確認突破                                     |
//|  放量 + 尚未穿越(逼近中)→ 醞釀突破                                  |
//|  縮量/正常量 + 貼近關鍵位 → 假突破機率高(關鍵位可能有效防守)         |
//+------------------------------------------------------------------+
void CheckSessionBreakoutByVolume(double bid,
                                    double asiaLow, double asiaHigh,
                                    double euroLow, double euroHigh,
                                    double usLow, double usHigh,
                                    double srTol, string volState,
                                    string &levelOut, string &judgeOut)
{
   double levels[6] = {asiaLow, euroLow, usLow, asiaHigh, euroHigh, usHigh};
   string names[6]  = {"亞盤低","歐盤低","美盤低","亞盤高","歐盤高","美盤高"};
   bool   isLow[6]  = {true,true,true,false,false,false};

   int bestIdx=-1; double bestDist=-1;
   for(int i=0;i<6;i++)
   {
      if(levels[i]<=0) continue;
      double d = MathAbs(bid-levels[i]);
      if(d > srTol*3) continue;
      if(bestIdx<0 || d<bestDist) { bestIdx=i; bestDist=d; }
   }

   if(bestIdx<0)
   {
      levelOut = "";
      judgeOut = "無測試關鍵位";
      return;
   }

   levelOut = names[bestIdx];
   bool broken = isLow[bestIdx] ? (bid < levels[bestIdx]-srTol) : (bid > levels[bestIdx]+srTol);

   if(volState=="放量" && broken)        judgeOut = "確認突破";
   else if(volState=="放量" && !broken)  judgeOut = "醞釀突破";
   else                                   judgeOut = "假突破機率高";
}

//+------------------------------------------------------------------+
//| 【還原版】11指標綜合分數 — 忠實對應 gordon_full_analysis.py 裡的     |
//| compute_signals_detailed() / compute_weighted_score() /            |
//| status_from_score()，該檔案註解明確指出這套邏輯「跟ExcelMonitor_    |
//| All.mq5 M5那邊同一套」。11個指標分三組加權：                        |
//|  趨勢組(45%)：MA(5/20)、MACD(12/26/9)、BOLL(20,2)、KELTNER(20,2)   |
//|  動能組(35%)：RSI(14)、KD(9,3,3)、WR(14)、CCI(14)、MTM(10)         |
//|  其他組(20%)：PSY(12)、BIAS(20)                                   |
//| 每個指標先轉成 -2~2 的分級訊號，組內平均，再跨組加權合併。            |
//+------------------------------------------------------------------+
double SignalStrength(double value, double strongHi, double mildHi, double mildLo, double strongLo)
{
   if(value >= strongHi) return 2;
   else if(value >= mildHi) return 1;
   else if(value <= strongLo) return -2;
   else if(value <= mildLo) return -1;
   else return (value >= (mildHi+mildLo)/2.0) ? 1 : -1;
}

// 通用EMA(adjust=False風格)：out[i]為時間點i的EMA值，index0=最新。
// 種子＝陣列裡最舊的一筆(index total-1)，往新的方向逐步遞迴平滑。
void CalcEMASeries(const double &vals[], int total, double alpha, double &out[])
{
   ArrayResize(out, total);
   out[total-1] = vals[total-1];
   for(int i=total-2;i>=0;i--)
      out[i] = vals[i]*alpha + out[i+1]*(1-alpha);
}

double Composite_MA(const double &close[])
{
   double shortSum=0, longSum=0;
   for(int i=0;i<5;i++)  shortSum += close[i];
   for(int i=0;i<20;i++) longSum  += close[i];
   double maShort = shortSum/5.0;
   double maLong  = longSum/20.0;
   double diffPct = (maLong!=0) ? (maShort-maLong)/maLong*100.0 : 0;
   return SignalStrength(diffPct, 0.15, 0, 0, -0.15);
}

double Composite_RSI(const double &close[], int total, int period=14)
{
   int n = total-1;
   if(n<period) return 0;
   double gain[], loss[];
   ArrayResize(gain,n); ArrayResize(loss,n);
   for(int i=0;i<n;i++)
   {
      double diff = close[i]-close[i+1];
      gain[i] = (diff>0)?diff:0;
      loss[i] = (diff<0)?-diff:0;
   }
   double gEma[], lEma[];
   CalcEMASeries(gain, n, 1.0/period, gEma);
   CalcEMASeries(loss, n, 1.0/period, lEma);
   double avgGain = gEma[0], avgLoss = lEma[0];
   double rsi;
   if(avgLoss<=0) rsi = (avgGain>0) ? 100 : 50;
   else { double rs = avgGain/avgLoss; rsi = 100 - 100/(1+rs); }
   return SignalStrength(rsi, 60, 50, 50, 40);
}

double Composite_KD(const double &close[], const double &high[], const double &low[], int total,
                     int kPeriod=9, int dPeriod=3, int smooth=3)
{
   int n = total-kPeriod+1;
   if(n<2) return -1;
   double rsv[];
   ArrayResize(rsv,n);
   for(int idx=0; idx<n; idx++)
   {
      double hh=-DBL_MAX, ll=DBL_MAX;
      for(int j=idx;j<idx+kPeriod;j++)
      {
         if(high[j]>hh) hh=high[j];
         if(low[j]<ll)  ll=low[j];
      }
      double rng = hh-ll;
      rsv[idx] = (rng>0) ? (close[idx]-ll)/rng*100.0 : 50.0;
   }
   double kSeries[];
   CalcEMASeries(rsv, n, 1.0/smooth, kSeries);
   double dSeries[];
   CalcEMASeries(kSeries, n, 1.0/dPeriod, dSeries);
   double kNow = kSeries[0], dNow = dSeries[0];
   double kdDiff = kNow-dNow;
   if(kdDiff>0 && kNow<20) return 2;
   else if(kdDiff>0)       return 1;
   else if(kdDiff<0 && kNow>80) return -2;
   else return -1;
}

double Composite_PSY(const double &close[], int period=12)
{
   int upCount=0;
   for(int i=0;i<period;i++)
      if(close[i]-close[i+1] > 0) upCount++;
   double psy = (double)upCount/period*100.0;
   return SignalStrength(psy, 60, 50, 50, 40);
}

double Composite_WR(const double &close[], const double &high[], const double &low[], int period=14)
{
   double hh=-DBL_MAX, ll=DBL_MAX;
   for(int i=0;i<period;i++)
   {
      if(high[i]>hh) hh=high[i];
      if(low[i]<ll)  ll=low[i];
   }
   double wr = (hh-ll>0) ? (hh-close[0])/(hh-ll)*-100.0 : -50.0;
   return SignalStrength(wr, -30, -50, -50, -70);
}

double Composite_MTM(const double &close[], int period=10)
{
   double mtmPct = (close[0]!=0) ? (close[0]-close[period])/close[0]*100.0 : 0;
   return SignalStrength(mtmPct, 0.15, 0, 0, -0.15);
}

double Composite_MACD(const double &close[], int total, int fast=12, int slow=26, int signalP=9)
{
   double emaFast[], emaSlow[];
   CalcEMASeries(close, total, 2.0/(fast+1), emaFast);
   CalcEMASeries(close, total, 2.0/(slow+1), emaSlow);
   double macdLine[];
   ArrayResize(macdLine, total);
   for(int i=0;i<total;i++) macdLine[i] = emaFast[i]-emaSlow[i];
   double macdSignal[];
   CalcEMASeries(macdLine, total, 2.0/(signalP+1), macdSignal);
   double hist = macdLine[0]-macdSignal[0];
   double histPct = (close[0]!=0) ? hist/close[0]*100.0 : 0;
   return SignalStrength(histPct, 0.05, 0, 0, -0.05);
}

double Composite_BOLL(const double &close[], int period=20, double numStd=2.0)
{
   double sum=0;
   for(int i=0;i<period;i++) sum+=close[i];
   double mid = sum/period;
   double varSum=0;
   for(int i=0;i<period;i++) varSum += MathPow(close[i]-mid, 2);
   double std = (period>1) ? MathSqrt(varSum/(period-1)) : 0; // 對齊pandas預設 ddof=1
   double bandHalf = (numStd*std!=0) ? numStd*std : 1;
   double bollPos = (close[0]-mid)/bandHalf;
   return SignalStrength(bollPos, 0.5, 0, 0, -0.5);
}

double Composite_CCI(const double &close[], const double &high[], const double &low[], int period=14)
{
   double tp[];
   ArrayResize(tp, period);
   for(int i=0;i<period;i++) tp[i] = (high[i]+low[i]+close[i])/3.0;
   double sma=0;
   for(int i=0;i<period;i++) sma+=tp[i];
   sma/=period;
   double mad=0;
   for(int i=0;i<period;i++) mad+=MathAbs(tp[i]-sma);
   mad/=period;
   double cci = (mad>0) ? (tp[0]-sma)/(0.015*mad) : 0;
   return SignalStrength(cci, 100, 0, 0, -100);
}

double Composite_BIAS(const double &close[], int period=20)
{
   double sum=0;
   for(int i=0;i<period;i++) sum+=close[i];
   double sma = sum/period;
   double bias = (sma!=0) ? (close[0]-sma)/sma*100.0 : 0;
   return SignalStrength(bias, 1.0, 0, 0, -1.0);
}

double Composite_KELTNER(const double &close[], const double &high[], const double &low[], int total,
                           int period=20, double mult=2.0)
{
   double emaMid[];
   CalcEMASeries(close, total, 2.0/(period+1), emaMid);

   double tr[];
   ArrayResize(tr, total-1);
   for(int i=0;i<total-1;i++)
   {
      double a = high[i]-low[i];
      double b = MathAbs(high[i]-close[i+1]);
      double c = MathAbs(low[i]-close[i+1]);
      tr[i] = MathMax(a, MathMax(b,c));
   }
   double emaAtr[];
   CalcEMASeries(tr, total-1, 2.0/(period+1), emaAtr);

   double mid = emaMid[0];
   double atrV = emaAtr[0];
   double keltHalf = (mult*atrV!=0) ? mult*atrV : 1;
   double keltPos = (close[0]-mid)/keltHalf;
   return SignalStrength(keltPos, 0.5, 0, 0, -0.5);
}

// 分組與權重：跟 gordon_full_analysis.py 的 GROUP_TREND/GROUP_MOMENTUM/GROUP_OTHER 完全一致
double ComputeComposite11(const MqlRates &rates[], int copied, string &judgeOut)
{
   // 把 rates 拆成純 close/high/low 陣列(index0=最新)，方便各指標函式使用
   double close[], high[], low[];
   ArrayResize(close, copied); ArrayResize(high, copied); ArrayResize(low, copied);
   for(int i=0;i<copied;i++)
   {
      close[i] = rates[i].close;
      high[i]  = rates[i].high;
      low[i]   = rates[i].low;
   }

   // 各指標所需的最小長度都要能滿足，不足就直接回傳「資料不足」
   int minNeeded = 45; // 對應python版 compute_votes_latest 的 min_needed
   if(copied < minNeeded)
   {
      judgeOut = "資料不足";
      return 0;
   }

   double sMA   = Composite_MA(close);
   double sMACD = Composite_MACD(close, copied);
   double sBOLL = Composite_BOLL(close);
   double sKELT = Composite_KELTNER(close, high, low, copied);

   double sRSI  = Composite_RSI(close, copied);
   double sKD   = Composite_KD(close, high, low, copied);
   double sWR   = Composite_WR(close, high, low);
   double sCCI  = Composite_CCI(close, high, low);
   double sMTM  = Composite_MTM(close);

   double sPSY  = Composite_PSY(close);
   double sBIAS = Composite_BIAS(close);

   double trendAvg    = (sMA + sMACD + sBOLL + sKELT) / 4.0;
   double momentumAvg = (sRSI + sKD + sWR + sCCI + sMTM) / 5.0;
   double otherAvg    = (sPSY + sBIAS) / 2.0;

   double score = trendAvg*0.45 + momentumAvg*0.35 + otherAvg*0.20;

   if(score >= 1.0)        judgeOut = "強力多頭";
   else if(score >= 0.3)   judgeOut = "偏多";
   else if(score <= -1.0)  judgeOut = "強力空頭";
   else if(score <= -0.3)  judgeOut = "偏空";
   else                    judgeOut = "多空不明";

   return score;
}

//+------------------------------------------------------------------+
//| 以下函式與 ExcelMonitor_TradingEA.mq5 的 ComputeM5Signal() 共用邏輯  |
//+------------------------------------------------------------------+
void GetWeekRange(string sym, double &outLow, double &outHigh)
{
   MqlRates wRates[];
   ArraySetAsSeries(wRates, true);
   int copied = CopyRates(sym, PERIOD_W1, 0, 3, wRates);
   if(copied >= 2)
   {
      outLow = wRates[1].low;
      outHigh = wRates[1].high;
   }
   else
   {
      outLow = 0; outHigh = 0;
   }
}

void GetSessionRange(string sym, int startHour, int endHour, double &outLow, double &outHigh)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(sym, PERIOD_M5, 0, 2000, rates);
   if(copied <= 0) { outLow=0; outHigh=0; return; }

   datetime now = rates[0].time;
   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);

   for(int dayBack=0; dayBack<=7; dayBack++)
   {
      MqlDateTime dtBase = dtNow;
      dtBase.hour=0; dtBase.min=0; dtBase.sec=0;
      datetime baseDay = StructToTime(dtBase) - dayBack*86400;
      datetime sessStart = baseDay + startHour*3600;
      datetime sessEnd   = baseDay + endHour*3600;
      if(dayBack==0 && now < sessEnd) continue;

      double lo=0, hi=0; bool found=false;
      for(int i=0;i<copied;i++)
      {
         if(rates[i].time>=sessStart && rates[i].time<=sessEnd)
         {
            if(!found){ lo=rates[i].low; hi=rates[i].high; found=true; }
            else { if(rates[i].low<lo) lo=rates[i].low; if(rates[i].high>hi) hi=rates[i].high; }
         }
      }
      if(found){ outLow=lo; outHigh=hi; return; }
   }
   outLow=0; outHigh=0;
}

double SMA(const MqlRates &rates[], int total, int period, int offset)
{
   double sum=0; int cnt=0;
   for(int i=offset;i<offset+period && i<total;i++){ sum+=rates[i].close; cnt++; }
   return (cnt>0) ? sum/cnt : 0;
}

int CalcEMA(const MqlRates &rates[], int total, int period, double &emaOut[])
{
   if(total<period) return 0;
   ArrayResize(emaOut, total);
   double sum=0;
   for(int i=total-period;i<total;i++) sum += rates[i].close;
   double ema = sum/period;
   double alpha = 2.0/(period+1);
   emaOut[total-1] = ema;
   for(int i=total-2;i>=0;i--)
   {
      ema = rates[i].close*alpha + ema*(1-alpha);
      emaOut[i] = ema;
   }
   return total;
}

double CalcATR(const MqlRates &rates[], int total, int period)
{
   if(total < period+2) return 0;
   double sum=0;
   for(int i=1;i<=period;i++)
   {
      double tr = MathMax(rates[i].high-rates[i].low,
                  MathMax(MathAbs(rates[i].high-rates[i+1].close), MathAbs(rates[i].low-rates[i+1].close)));
      sum += tr;
   }
   return sum/period;
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
