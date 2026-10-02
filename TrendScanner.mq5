//+------------------------------------------------------------------+
//|  TrendScanner.mq5  v2 — 多指標趨勢掃描 + 進出場計畫 + （可選）執行     |
//|                                                                  |
//|  ★ 預設只產生計畫，不下單（Inp_TradeEnabled=false）                  |
//|    開啟執行前請先在模擬帳戶驗證；Inp_AllowReal=false 時真實帳戶不執行 |
//|                                                                  |
//|  評分（8 票，5 類指標，各商品參數可在 params.csv 個別設定）：         |
//|   趨勢 4 票：均線排列 MA1>MA2>MA3>MA4、價格在 MA4 上/下、MA4 斜率、  |
//|              MACD 主線 vs 訊號線                                      |
//|   動能 1 票：RSI >= 多方門檻 / <= 空方門檻                            |
//|   方向 1 票：DMI +DI vs -DI                                           |
//|   波動 1 票：收盤在布林中軌上/下                                       |
//|   量能 1 票：近 N 根陽線量 vs 陰線量                                   |
//|  條件：H1 分數 >= min_score、H4 同方向且 >= InpConfirmMin、ADX >= adx_min |
//|                                                                  |
//|  進場：已回檔 38.2~61.8% → 現價；未回檔 → 38.2% 掛限價；>61.8% → 觀望 |
//|  止損/止盈：斐波位 + ATR 緩衝，RR >= InpMinRR                         |
//|  手數：每筆風險 InpRiskPct（預設 0.15%）                               |
//|  移動止損：保本 / ATR 追蹤 / 擺動高低點追蹤                           |
//|  加碼：最多 InpMaxUnits 單；最新一單獲利 >= InpAddAtR 倍 R 且趨勢仍成立 |
//|        才加，加碼前先把既有單止損移到保本 → 任何時刻最多一單的風險   |
//|                                                                  |
//|  安裝：單一檔案（已內含 MarketRegime / SymbolGroups），F7 編譯          |
//+------------------------------------------------------------------+
#property version   "2.10"
#property description "多指標趨勢掃描、進出場計畫、移動止損與加碼（預設不下單）"

//=== 內嵌 MarketRegime.mqh（單一檔案即可編譯）===
//+------------------------------------------------------------------+
//|  MarketRegime.mqh                                                |
//|  每小時市場行情判定 + 斐波納契(黃金切割)壓力支撐                    |
//|                                                                  |
//|  依《期貨當沖》操作期指切入點表：                                   |
//|   * 波段指標：三線合一 (均線 5/10/20/34 多頭/空頭排列)              |
//|   * 多空線：均線 34 (價在其上偏多、其下偏空；斜率判斷方向)          |
//|   * DIF 線與 MACD 線交叉                                          |
//|   * 領先指標：價乖離 (收盤與 MA34 的距離，ATR 倍數)                  |
//|   * RSI 3/6：「RSI 乖離 16 以上，低檔負乖離過大做多、高檔正乖離過大做空」 |
//|   * 大量：成交量 (tick volume) 相對 20 根均量的倍數                  |
//|   * 「算：黃金切割…預測壓力與支撐」：取最近 SwingBars 根的最高/最低點，  |
//|     依波段方向計算 23.6/38.2/50/61.8/78.6% 回檔(反彈)位，              |
//|     找出目前價格上方最近的壓力、下方最近的支撐                       |
//|                                                                  |
//|  判定：4 項趨勢分數 (三線合一、多空線、MA34斜率、DIF/MACD) 加總       |
//|        >= +3 多頭、<= -3 空頭，其餘為盤整                             |
//|  只使用已收盤的 K 棒 (shift>=1)                                     |
//+------------------------------------------------------------------+
#ifndef MARKET_REGIME_MQH
#define MARKET_REGIME_MQH

enum ENUM_MR_MODE
{
   MR_LOG_ONLY  = 0,  // 只收集記錄，不影響下單
   MR_TREND     = 1,  // 多頭只做多、空頭只做空 (盤整兩邊都可)
   MR_TREND_FIB = 2   // 同上，且買單不追在斐波壓力附近、賣單不殺在斐波支撐附近
};

#define MR_NFIB 7

struct SRegime
{
   datetime time;          // 判定所用的 H1 K棒時間 (最近一根已收盤)
   bool     valid;
   int      score;         // -4 ~ +4
   int      regime;        // +1 多頭 / -1 空頭 / 0 盤整
   string   label;

   double   close;
   double   barHigh, barLow;   // 判定所用 K棒的高低點 (統計腳本模擬止損止盈先後用)
   double   atr;
   double   ma5, ma10, ma20, ma34;
   int      maAlign;       // +1 多頭排列 / -1 空頭排列 / 0 糾結
   int      ma34Side;      // +1 價在 MA34 上 / -1 下
   int      ma34Slope;     // +1 上彎 / -1 下彎 / 0 走平
   int      macdSide;      // +1 DIF>MACD / -1 DIF<MACD
   bool     macdCross;     // 最近一根剛交叉
   double   rsi3, rsi6;
   int      rsiSignal;     // +1 低檔負乖離過大(做多訊號) / -1 高檔正乖離過大(做空訊號) / 0
   double   devATR;        // (收盤 - MA34) / ATR
   double   volRatio;      // 最近一根量 / 20 根均量

   // 斐波納契
   double   swingHi, swingLo;
   int      swingDir;      // +1 上升波段 (低點在前、高點在後) / -1 下降波段
   double   fibRatio;      // 目前回檔(反彈)比例 0~1 (可能超出)
   double   fib[MR_NFIB];  // 0, 23.6, 38.2, 50, 61.8, 78.6, 100 % 對應價格
   double   support;       // 價格下方最近的斐波位 (0 = 無)
   double   resistance;    // 價格上方最近的斐波位 (0 = 無)
   string   fibZone;       // 例如 "回檔38.2~61.8%(黃金買區)"

   // 斐波止損止盈建議 (以判定當時收盤價計算；0 = 無合適價位)
   double   longSL, longTP, longRR;
   double   shortSL, shortTP, shortRR;
};

enum ENUM_MR_STOPS
{
   MR_STOPS_RULES = 0,  // 用 fx_rules 固定止損止盈 (原本做法)
   MR_STOPS_FIB   = 1   // 用斐波止損止盈 (算不出合適價位時退回 fx_rules)
};

class CMarketRegime
{
private:
   string   m_sym[];
   int      m_hMA5[], m_hMA10[], m_hMA20[], m_hMA34[];
   int      m_hMACD[], m_hRSI3[], m_hRSI6[], m_hATR[];

   int Slot(string sym)
   {
      int n = ArraySize(m_sym);
      for(int i=0; i<n; i++)
         if(m_sym[i] == sym) return i;

      ArrayResize(m_sym,  n+1); ArrayResize(m_hMA5, n+1); ArrayResize(m_hMA10, n+1);
      ArrayResize(m_hMA20,n+1); ArrayResize(m_hMA34,n+1); ArrayResize(m_hMACD, n+1);
      ArrayResize(m_hRSI3,n+1); ArrayResize(m_hRSI6,n+1); ArrayResize(m_hATR,  n+1);

      m_sym[n]   = sym;
      m_hMA5[n]  = iMA(sym, TF, 5,  0, MODE_SMA, PRICE_CLOSE);
      m_hMA10[n] = iMA(sym, TF, 10, 0, MODE_SMA, PRICE_CLOSE);
      m_hMA20[n] = iMA(sym, TF, 20, 0, MODE_SMA, PRICE_CLOSE);
      m_hMA34[n] = iMA(sym, TF, 34, 0, MODE_SMA, PRICE_CLOSE);
      m_hMACD[n] = iMACD(sym, TF, 12, 26, 9, PRICE_CLOSE);
      m_hRSI3[n] = iRSI(sym, TF, 3, PRICE_CLOSE);
      m_hRSI6[n] = iRSI(sym, TF, 6, PRICE_CLOSE);
      m_hATR[n]  = iATR(sym, TF, 14);
      return n;
   }

   bool Val(int h, int buf, int shift, double &v)
   {
      if(h == INVALID_HANDLE) return false;
      double b[1];
      if(CopyBuffer(h, buf, shift, 1, b) != 1) return false;
      if(b[0] == EMPTY_VALUE || !MathIsValidNumber(b[0])) return false;
      v = b[0];
      return true;
   }

public:
   ENUM_TIMEFRAMES TF;           // 判定週期 (預設 H1，每小時一次)
   int             SwingBars;    // 斐波波段回看根數
   int             SlopeBars;    // MA34 斜率回看根數
   double          RsiDevLimit;  // RSI3 與 RSI6 乖離門檻 (表中為 16)
   double          RsiLow;       // RSI 低檔區
   double          RsiHigh;      // RSI 高檔區
   double          FibNearATR;   // 「接近斐波位」的距離 (ATR 倍數)
   double          StopBufATR;   // 止損放在斐波位外側的緩衝 (ATR 倍數)
   double          MinSLATR;     // 止損最小距離 (ATR 倍數)
   double          MaxSLATR;     // 止損最大距離 (ATR 倍數)
   double          MinRR;        // 止盈至少要有的報酬風險比

   CMarketRegime()
   {
      TF = PERIOD_H1; SwingBars = 120; SlopeBars = 5;
      RsiDevLimit = 16; RsiLow = 30; RsiHigh = 70; FibNearATR = 0.3;
      StopBufATR = 0.2; MinSLATR = 0.5; MaxSLATR = 3.0; MinRR = 1.5;
   }

   ~CMarketRegime() { Release(); }

   void Release()
   {
      for(int i=0; i<ArraySize(m_sym); i++)
      {
         if(m_hMA5[i]  != INVALID_HANDLE) IndicatorRelease(m_hMA5[i]);
         if(m_hMA10[i] != INVALID_HANDLE) IndicatorRelease(m_hMA10[i]);
         if(m_hMA20[i] != INVALID_HANDLE) IndicatorRelease(m_hMA20[i]);
         if(m_hMA34[i] != INVALID_HANDLE) IndicatorRelease(m_hMA34[i]);
         if(m_hMACD[i] != INVALID_HANDLE) IndicatorRelease(m_hMACD[i]);
         if(m_hRSI3[i] != INVALID_HANDLE) IndicatorRelease(m_hRSI3[i]);
         if(m_hRSI6[i] != INVALID_HANDLE) IndicatorRelease(m_hRSI6[i]);
         if(m_hATR[i]  != INVALID_HANDLE) IndicatorRelease(m_hATR[i]);
      }
      ArrayResize(m_sym, 0);
   }

   // 預先建立指標 handle，讓指標提早開始計算
   void Prepare(string sym) { Slot(sym); }

   //-----------------------------------------------------------------
   // 計算行情判定；資料不足回傳 false
   //-----------------------------------------------------------------
   bool Evaluate(string sym, SRegime &r)
   {
      r.valid = false;
      int k = Slot(sym);

      double ma34Old, dif, sig, difPrev, sigPrev;
      if(!Val(m_hMA5[k],  0, 1, r.ma5))  return false;
      if(!Val(m_hMA10[k], 0, 1, r.ma10)) return false;
      if(!Val(m_hMA20[k], 0, 1, r.ma20)) return false;
      if(!Val(m_hMA34[k], 0, 1, r.ma34)) return false;
      if(!Val(m_hMA34[k], 0, 1 + SlopeBars, ma34Old)) return false;
      if(!Val(m_hMACD[k], 0, 1, dif))    return false;
      if(!Val(m_hMACD[k], 1, 1, sig))    return false;
      if(!Val(m_hMACD[k], 0, 2, difPrev)) return false;
      if(!Val(m_hMACD[k], 1, 2, sigPrev)) return false;
      if(!Val(m_hRSI3[k], 0, 1, r.rsi3)) return false;
      if(!Val(m_hRSI6[k], 0, 1, r.rsi6)) return false;
      if(!Val(m_hATR[k],  0, 1, r.atr) || r.atr <= 0) return false;

      MqlRates rt[];
      ArraySetAsSeries(rt, true);
      int need = MathMax(SwingBars, 21);
      if(CopyRates(sym, TF, 1, need, rt) != need) return false;

      r.time  = rt[0].time;
      r.close   = rt[0].close;
      r.barHigh = rt[0].high;
      r.barLow  = rt[0].low;

      //--- 三線合一
      if(r.ma5 > r.ma10 && r.ma10 > r.ma20 && r.ma20 > r.ma34)      r.maAlign =  1;
      else if(r.ma5 < r.ma10 && r.ma10 < r.ma20 && r.ma20 < r.ma34) r.maAlign = -1;
      else                                                          r.maAlign =  0;

      //--- 多空線 MA34
      r.ma34Side = (r.close >= r.ma34) ? 1 : -1;
      double slope = (r.ma34 - ma34Old) / r.atr;
      r.ma34Slope = (slope > 0.1) ? 1 : (slope < -0.1 ? -1 : 0);

      //--- DIF / MACD
      r.macdSide  = (dif >= sig) ? 1 : -1;
      r.macdCross = ((difPrev < sigPrev) != (dif < sig));

      //--- 價乖離
      r.devATR = (r.close - r.ma34) / r.atr;

      //--- RSI 3/6 乖離
      double rdev = r.rsi3 - r.rsi6;
      r.rsiSignal = 0;
      if(rdev <= -RsiDevLimit && r.rsi6 <= RsiLow)  r.rsiSignal =  1;
      if(rdev >=  RsiDevLimit && r.rsi6 >= RsiHigh) r.rsiSignal = -1;

      //--- 大量
      double avgVol = 0;
      for(int i=1; i<=20; i++) avgVol += (double)rt[i].tick_volume;
      avgVol /= 20.0;
      r.volRatio = (avgVol > 0) ? (double)rt[0].tick_volume / avgVol : 0;

      //--- 趨勢分數
      r.score = r.maAlign + r.ma34Side + r.ma34Slope + r.macdSide;
      if(r.score >= 3)       { r.regime =  1; r.label = "多頭"; }
      else if(r.score <= -3) { r.regime = -1; r.label = "空頭"; }
      else                   { r.regime =  0; r.label = "盤整"; }

      //--- 斐波納契：波段最高/最低點與其先後順序
      int iHi = 0, iLo = 0;
      for(int i=1; i<SwingBars; i++)
      {
         if(rt[i].high > rt[iHi].high) iHi = i;
         if(rt[i].low  < rt[iLo].low)  iLo = i;
      }
      r.swingHi = rt[iHi].high;
      r.swingLo = rt[iLo].low;
      double range = r.swingHi - r.swingLo;
      if(range <= 0) return false;

      // series 陣列索引越小越新：高點較新 → 上升波段 (由低到高)，量「回檔」
      r.swingDir = (iHi < iLo) ? 1 : -1;

      double ratios[MR_NFIB] = {0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0};
      for(int i=0; i<MR_NFIB; i++)
         r.fib[i] = (r.swingDir > 0) ? r.swingHi - ratios[i] * range    // 0% = 高點，100% = 低點
                                     : r.swingLo + ratios[i] * range;   // 0% = 低點，100% = 高點

      r.fibRatio = (r.swingDir > 0) ? (r.swingHi - r.close) / range
                                    : (r.close - r.swingLo) / range;

      r.support = 0; r.resistance = 0;
      for(int i=0; i<MR_NFIB; i++)
      {
         if(r.fib[i] < r.close && (r.support    == 0 || r.fib[i] > r.support))    r.support    = r.fib[i];
         if(r.fib[i] > r.close && (r.resistance == 0 || r.fib[i] < r.resistance)) r.resistance = r.fib[i];
      }

      string what = (r.swingDir > 0) ? "回檔" : "反彈";
      if(r.fibRatio < 0.236)       r.fibZone = what + "<23.6%(強勢)";
      else if(r.fibRatio < 0.382)  r.fibZone = what + "23.6~38.2%(淺)";
      else if(r.fibRatio <= 0.618) r.fibZone = what + "38.2~61.8%(黃金" + (r.swingDir > 0 ? "買區)" : "空區)");
      else if(r.fibRatio <= 0.786) r.fibZone = what + "61.8~78.6%(深)";
      else                         r.fibZone = what + ">78.6%(波段可能反轉)";

      r.valid = true;

      // 以判定當時收盤價計算多/空兩邊的斐波止損止盈建議
      if(!CalcStops(r,  1, r.close, r.longSL,  r.longTP,  r.longRR))  { r.longSL  = 0; r.longTP  = 0; r.longRR  = 0; }
      if(!CalcStops(r, -1, r.close, r.shortSL, r.shortTP, r.shortRR)) { r.shortSL = 0; r.shortTP = 0; r.shortRR = 0; }

      r.valid = true;
      return true;
   }

   //-----------------------------------------------------------------
   // 斐波止損止盈：dir=+1 多 / -1 空，price = 進場價
   //  * 候選價位：0~100% 回檔位 + 波段兩端外的 127.2% / 161.8% 延伸位
   //  * 止損：進場價下方(多)/上方(空)最近的斐波位，再往外 StopBufATR×ATR；
   //          距離限制在 MinSLATR ~ MaxSLATR 倍 ATR 之間
   //  * 止盈：往獲利方向找「第一個」報酬風險比 >= MinRR 的斐波位
   //  找不到合適止盈回傳 false
   //-----------------------------------------------------------------
   bool CalcStops(const SRegime &r, int dir, double price, double &sl, double &tp, double &rr)
   {
      sl = 0; tp = 0; rr = 0;
      if(!r.valid || r.atr <= 0) return false;
      double range = r.swingHi - r.swingLo;
      if(range <= 0) return false;

      double lv[MR_NFIB + 4];
      for(int i=0; i<MR_NFIB; i++) lv[i] = r.fib[i];
      lv[MR_NFIB]     = r.swingLo - 0.272 * range;
      lv[MR_NFIB + 1] = r.swingLo - 0.618 * range;
      lv[MR_NFIB + 2] = r.swingHi + 0.272 * range;
      lv[MR_NFIB + 3] = r.swingHi + 0.618 * range;
      int n = MR_NFIB + 4;
      ArraySort(lv);                          // 由低到高

      double a   = r.atr;
      double gap = 0.1 * a;                   // 貼著進場價的斐波位不算
      double d;

      if(dir > 0)
      {
         double s = 0;
         for(int i=0; i<n; i++)
            if(lv[i] < price - gap) s = lv[i];      // 下方最近
         sl = (s > 0) ? s - StopBufATR * a : price - MaxSLATR * a;
         d  = price - sl;
         if(d < MinSLATR * a) { d = MinSLATR * a; sl = price - d; }
         if(d > MaxSLATR * a) { d = MaxSLATR * a; sl = price - d; }

         for(int i=0; i<n; i++)
            if(lv[i] - price >= MinRR * d) { tp = lv[i]; break; }
         if(tp <= 0) return false;
         rr = (tp - price) / d;
      }
      else
      {
         double s = 0;
         for(int i=n-1; i>=0; i--)
            if(lv[i] > price + gap) s = lv[i];      // 上方最近
         sl = (s > 0) ? s + StopBufATR * a : price + MaxSLATR * a;
         d  = sl - price;
         if(d < MinSLATR * a) { d = MinSLATR * a; sl = price + d; }
         if(d > MaxSLATR * a) { d = MaxSLATR * a; sl = price + d; }

         for(int i=n-1; i>=0; i--)
            if(price - lv[i] >= MinRR * d) { tp = lv[i]; break; }
         if(tp <= 0) return false;
         rr = (price - tp) / d;
      }
      return true;
   }

   //-----------------------------------------------------------------
   // 交易過濾：dir=+1 買 / -1 賣；reason 回傳擋單原因
   //-----------------------------------------------------------------
   bool Allow(const SRegime &r, ENUM_MR_MODE mode, int dir, double price, string &reason)
   {
      reason = "";
      if(mode == MR_LOG_ONLY || !r.valid) return true;

      if(r.regime != 0 && r.regime != dir)
      {
         reason = "行情" + r.label + "，不做" + (dir > 0 ? "多" : "空");
         return false;
      }

      if(mode == MR_TREND_FIB)
      {
         double near = FibNearATR * r.atr;
         if(dir > 0 && r.resistance > 0 && r.resistance - price < near)
         {
            reason = StringFormat("接近斐波壓力 %.5f", r.resistance);
            return false;
         }
         if(dir < 0 && r.support > 0 && price - r.support < near)
         {
            reason = StringFormat("接近斐波支撐 %.5f", r.support);
            return false;
         }
      }
      return true;
   }

   string Summary(const SRegime &r, int digits)
   {
      if(!r.valid) return "資料不足";
      string macd = (r.macdSide > 0) ? ">MACD" : "<MACD";
      if(r.macdCross) macd += "(剛交叉)";
      return StringFormat("%s(%+d) 三線%s MA34%s DIF%s RSI3/6=%.0f/%.0f%s 乖離%.1fATR 量%.1fx | 斐波%s 支撐%.*f 壓力%.*f",
                          r.label, r.score,
                          (r.maAlign > 0 ? "多排" : (r.maAlign < 0 ? "空排" : "糾結")),
                          (r.ma34Side > 0 ? "上" : "下"),
                          macd,
                          r.rsi3, r.rsi6,
                          (r.rsiSignal > 0 ? "(負乖離過大→多)" : (r.rsiSignal < 0 ? "(正乖離過大→空)" : "")),
                          r.devATR, r.volRatio, r.fibZone,
                          digits, r.support, digits, r.resistance)
             + " | " + StopsText(r, digits);
   }

   string StopsText(const SRegime &r, int digits)
   {
      string s = (r.longTP > 0)
                 ? StringFormat("多 SL%.*f TP%.*f RR%.1f", digits, r.longSL, digits, r.longTP, r.longRR)
                 : "多 無合適止盈";
      s += (r.shortTP > 0)
           ? StringFormat("  空 SL%.*f TP%.*f RR%.1f", digits, r.shortSL, digits, r.shortTP, r.shortRR)
           : "  空 無合適止盈";
      return s;
   }
};

#endif // MARKET_REGIME_MQH
//+------------------------------------------------------------------+

//=== 內嵌 SymbolGroups.mqh ===
//+------------------------------------------------------------------+
//|  SymbolGroups.mqh                                                |
//|  商品分組：主要貨幣 / 交叉貨幣 / 異國貨幣 / 金屬 / 能源 / 指數 /   |
//|            農產品 / 加密貨幣                                      |
//|                                                                  |
//|  先依商品名稱判斷（可處理 .cash / .c / .m 等後綴與短前綴），         |
//|  名稱判斷不出來時再看券商的商品資料夾 (SYMBOL_PATH)                 |
//+------------------------------------------------------------------+
#ifndef SYMBOL_GROUPS_MQH
#define SYMBOL_GROUPS_MQH

enum ENUM_SYM_GROUP
{
   GRP_MAJOR  = 0,  // 主要貨幣
   GRP_CROSS  = 1,  // 交叉貨幣
   GRP_EXOTIC = 2,  // 異國貨幣
   GRP_METAL  = 3,  // 金屬
   GRP_ENERGY = 4,  // 能源
   GRP_INDEX  = 5,  // 指數
   GRP_AGRI   = 6,  // 農產品
   GRP_CRYPTO = 7,  // 加密貨幣
   GRP_OTHER  = 8   // 其他
};

#define GRP_COUNT 9

string GroupName(const ENUM_SYM_GROUP g)
{
   switch(g)
   {
      case GRP_MAJOR:  return "主要貨幣";
      case GRP_CROSS:  return "交叉貨幣";
      case GRP_EXOTIC: return "異國貨幣";
      case GRP_METAL:  return "金屬";
      case GRP_ENERGY: return "能源";
      case GRP_INDEX:  return "指數";
      case GRP_AGRI:   return "農產品";
      case GRP_CRYPTO: return "加密貨幣";
   }
   return "其他";
}

// CSV / 統計用英文代碼（避免中文編碼問題）
string GroupCode(const ENUM_SYM_GROUP g)
{
   switch(g)
   {
      case GRP_MAJOR:  return "major";
      case GRP_CROSS:  return "cross";
      case GRP_EXOTIC: return "exotic";
      case GRP_METAL:  return "metal";
      case GRP_ENERGY: return "energy";
      case GRP_INDEX:  return "index";
      case GRP_AGRI:   return "agri";
      case GRP_CRYPTO: return "crypto";
   }
   return "other";
}

// 名稱中是否含任一關鍵字（大寫比對）
bool _GrpHasAny(const string up, const string &keys[])
{
   for(int i=0; i<ArraySize(keys); i++)
      if(StringFind(up, keys[i]) >= 0) return true;
   return false;
}

bool _GrpIsMajorCcy(const string c)
{
   return (c=="USD" || c=="EUR" || c=="JPY" || c=="GBP" ||
           c=="CHF" || c=="AUD" || c=="CAD" || c=="NZD");
}

bool _GrpIsCcy(const string c)
{
   if(_GrpIsMajorCcy(c)) return true;
   string ex[] = {"CNH","CNY","MXN","TRY","ZAR","SGD","HKD","NOK","SEK","DKK","PLN","HUF",
                  "CZK","ILS","RUB","THB","INR","KRW","TWD","BRL","CLP","COP","IDR","PHP","MYR"};
   for(int i=0; i<ArraySize(ex); i++)
      if(ex[i] == c) return true;
   return false;
}

ENUM_SYM_GROUP SymbolGroup(const string sym)
{
   string up = sym;
   StringToUpper(up);

   string metal[]  = {"XAU","XAG","XPT","XPD","GOLD","SILVER","PLATINUM","PALLADIUM","COPPER","XCU"};
   string energy[] = {"OIL","BRENT","WTI","NATGAS","NGAS","GASOIL","HEATING"};
   string agri[]   = {"CORN","WHEAT","SOY","COFFEE","COCOA","SUGAR","COTTON","OJ","ORANGE","CATTLE","HOGS","RICE","OAT"};
   string crypto[] = {"BTC","ETH","LTC","XRP","BCH","SOL","DOGE","ADA","DOT","XLM","LINK","AVAX","BNB","UNI","XMR","DASH","NEO","ETC","ALGO","MATIC"};
   string index[]  = {"US30","US100","NAS100","USTEC","US500","SPX","SP500","US2000","RUSSELL","GER40","DE40","DAX",
                      "UK100","FTSE","FRA40","CAC","JP225","JPN225","NIKKEI","AUS200","HK50","HSI","EU50","STOXX",
                      "SPN35","IBEX","N25","AEX","CHN50","CN50","DXY","USDX","VIX","SWI20","ITA40","NETH25"};

   // 指數先於加密（NETH25 含 ETH），金屬先於外匯（XAUUSD 也是 6 碼）
   if(_GrpHasAny(up, metal))  return GRP_METAL;
   if(_GrpHasAny(up, index))  return GRP_INDEX;
   if(_GrpHasAny(up, crypto)) return GRP_CRYPTO;
   if(_GrpHasAny(up, energy)) return GRP_ENERGY;
   if(_GrpHasAny(up, agri))   return GRP_AGRI;

   // 外匯：找連續 6 個字母且前後 3 碼都是貨幣代碼
   int n = StringLen(up);
   for(int i=0; i+6<=n; i++)
   {
      string b = StringSubstr(up, i, 3);
      string q = StringSubstr(up, i+3, 3);
      if(!_GrpIsCcy(b) || !_GrpIsCcy(q)) continue;

      if(_GrpIsMajorCcy(b) && _GrpIsMajorCcy(q))
         return (b=="USD" || q=="USD") ? GRP_MAJOR : GRP_CROSS;
      return GRP_EXOTIC;
   }

   // 名稱判斷不出來：看券商商品資料夾
   string path = SymbolInfoString(sym, SYMBOL_PATH);
   StringToUpper(path);
   if(StringFind(path, "METAL")  >= 0) return GRP_METAL;
   if(StringFind(path, "CRYPTO") >= 0) return GRP_CRYPTO;
   if(StringFind(path, "ENERG")  >= 0) return GRP_ENERGY;
   if(StringFind(path, "AGRI")   >= 0 || StringFind(path, "SOFT") >= 0) return GRP_AGRI;
   if(StringFind(path, "INDIC")  >= 0 || StringFind(path, "INDEX") >= 0 || StringFind(path, "CASH") >= 0) return GRP_INDEX;
   if(StringFind(path, "FOREX")  >= 0 || StringFind(path, "FX") >= 0) return GRP_EXOTIC;
   return GRP_OTHER;
}

#endif // SYMBOL_GROUPS_MQH
//+------------------------------------------------------------------+

#include <Generic\HashMap.mqh>
#include <Trade\Trade.mqh>

enum ENUM_SCAN_SOURCE { SRC_MARKETWATCH = 0, /* 市場報價視窗的商品 */ SRC_ALL = 1 /* 券商全部商品 */ };
enum ENUM_TRAIL       { TRAIL_NONE = 0, /* 不移動 */ TRAIL_BE = 1, /* 只移到保本 */
                        TRAIL_ATR = 2, /* 保本後 ATR 追蹤 */ TRAIL_SWING = 3 /* 保本後擺動高低點追蹤 */ };

input group "=== 安全 ==="
input bool   InpTradeEnabled  = false;  // 允許下單（false = 只產生計畫）
input bool   InpAllowReal     = false;  // 允許在真實帳戶下單
input long   InpLockAccount   = 0;      // 只在此帳號下單（0 = 不限）
input long   InpMagic         = 26100100;
input group "=== 掃描範圍 ==="
input string InpSymbols       = "USDJPY,CADJPY,GBPJPY,CHFJPY,USOIL.cash,UKOIL.cash,JP225.cash"; // 只掃這些商品（空白 = 依下面來源/分組）；預設為 3年+10年回測都賺的 7 檔
input ENUM_SCAN_SOURCE InpSource = SRC_MARKETWATCH;
input string InpGroups        = "major,cross,metal,index,energy"; // 分組：major,cross,exotic,metal,energy,index,agri,crypto
input int    InpScanMinutes   = 60;     // 掃描間隔（分鐘），另外每根新 H1 K棒也掃
input ENUM_TIMEFRAMES InpTF        = PERIOD_H1;
input ENUM_TIMEFRAMES InpConfirmTF = PERIOD_H4;
input int    InpConfirmMin    = 4;      // 確認週期最低分數（同方向）
input group "=== 預設指標參數（params.csv 沒列的商品使用）==="
input int    InpMA1 = 5, InpMA2 = 10, InpMA3 = 20, InpMA4 = 34;  // 均線（SMA）
input int    InpMacdFast = 12, InpMacdSlow = 26, InpMacdSig = 9;
input int    InpRsiPeriod = 14;
input double InpRsiBull = 55, InpRsiBear = 45;
input int    InpAdxPeriod = 14;
input double InpAdxMin = 20;
input int    InpBBPeriod = 20;
input int    InpVolBars = 20;
input int    InpMinScore = 6;           // 8 票中至少幾票（同方向）
input group "=== 計畫 / 風控 ==="
input double InpMinRR         = 1.5;    // 最低報酬風險比
input double InpRiskPct       = 0.15;   // 每筆風險（帳戶餘額 %）
input double InpMaxLot        = 1.0;    // 單筆手數上限（配合 AccountGuard）
input int    InpLimitExpiryH  = 4;      // 限價單有效時間（小時）
input int    InpMaxSymbols    = 5;      // 同時持倉的商品數上限
input group "=== 移動止損 / 加碼 ==="
input ENUM_TRAIL InpTrail     = TRAIL_ATR;
input double InpBEAtR         = 1.0;    // 獲利幾 R 移到保本
input double InpTrailATRMult  = 2.0;    // ATR 追蹤倍數
input int    InpSwingBars     = 10;     // 擺動追蹤回看 K 棒數
input int    InpMaxUnits      = 3;      // 同商品最多幾單（含第一單）
input double InpAddAtR        = 1.0;    // 最新一單獲利幾 R 才加碼
input bool   InpExitOnReverse = true;   // 出現反向趨勢計畫時全部平倉
input group "=== 輸出 ==="
input int    InpTopN          = 10;
input bool   InpPush          = true;
input int    InpRepeatHours   = 4;

//--- 各商品參數
struct SParams
{
   int ma1, ma2, ma3, ma4, macdF, macdS, macdSig, rsiP, adxP, bbP, volBars, minScore;
   double rsiBull, rsiBear, adxMin;
};

struct SHandles { int ma1, ma2, ma3, ma4, macd, rsi, adx, bb, atr; };

struct SPlan
{
   string sym;
   int    idx, dir, score, scoreC;
   double adx;
   string mode, zone, votes;
   double entry, sl, tp, rr, lots, strength;
};

string           g_syms[];
SParams          g_par[];
SHandles         g_hm[], g_hc[];        // 主週期 / 確認週期
CMarketRegime    g_fib;                 // 斐波波段與止損止盈
CTrade           g_trade;
CHashMap<string,datetime> g_pushed;
SPlan            g_plans[];
datetime         g_lastScan = 0, g_lastBar = 0;
bool             g_canTrade = false;
string           g_panel = "";

//+------------------------------------------------------------------+
//| 參數檔 Common\Files\TrendScanner\params.csv                       |
//+------------------------------------------------------------------+
void DefaultParams(SParams &p)
{
   p.ma1 = InpMA1; p.ma2 = InpMA2; p.ma3 = InpMA3; p.ma4 = InpMA4;
   p.macdF = InpMacdFast; p.macdS = InpMacdSlow; p.macdSig = InpMacdSig;
   p.rsiP = InpRsiPeriod; p.rsiBull = InpRsiBull; p.rsiBear = InpRsiBear;
   p.adxP = InpAdxPeriod; p.adxMin = InpAdxMin; p.bbP = InpBBPeriod;
   p.volBars = InpVolBars; p.minScore = InpMinScore;
}

#define PARAM_FILE "TrendScanner\\params.csv"

void LoadParams()
{
   for(int i = 0; i < ArraySize(g_syms); i++) DefaultParams(g_par[i]);

   if(!FileIsExist(PARAM_FILE, FILE_COMMON))
   {
      // 產生範本：列出所有掃描商品與目前預設值，方便逐一修改
      FolderCreate("TrendScanner", FILE_COMMON);
      int w = FileOpen(PARAM_FILE, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(w != INVALID_HANDLE)
      {
         FileWrite(w, "symbol", "ma1", "ma2", "ma3", "ma4", "macd_fast", "macd_slow", "macd_signal",
                   "rsi_period", "rsi_bull", "rsi_bear", "adx_period", "adx_min", "bb_period", "vol_bars", "min_score");
         for(int i = 0; i < ArraySize(g_syms); i++)
         {
            SParams p = g_par[i];
            FileWrite(w, g_syms[i], p.ma1, p.ma2, p.ma3, p.ma4, p.macdF, p.macdS, p.macdSig,
                      p.rsiP, p.rsiBull, p.rsiBear, p.adxP, p.adxMin, p.bbP, p.volBars, p.minScore);
         }
         FileClose(w);
         PrintFormat("TrendScanner：已產生參數範本 Common\\Files\\%s，可依商品修改後重新掛上 EA", PARAM_FILE);
      }
      return;
   }

   int h = FileOpen(PARAM_FILE, FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE) return;
   for(int c = 0; c < 16 && !FileIsEnding(h); c++) FileReadString(h);   // 略過標題列
   int loaded = 0;
   while(!FileIsEnding(h))
   {
      string sym = FileReadString(h);
      if(sym == "") { if(FileIsLineEnding(h)) continue; else break; }
      SParams p;
      p.ma1 = (int)FileReadNumber(h); p.ma2 = (int)FileReadNumber(h); p.ma3 = (int)FileReadNumber(h); p.ma4 = (int)FileReadNumber(h);
      p.macdF = (int)FileReadNumber(h); p.macdS = (int)FileReadNumber(h); p.macdSig = (int)FileReadNumber(h);
      p.rsiP = (int)FileReadNumber(h); p.rsiBull = FileReadNumber(h); p.rsiBear = FileReadNumber(h);
      p.adxP = (int)FileReadNumber(h); p.adxMin = FileReadNumber(h); p.bbP = (int)FileReadNumber(h);
      p.volBars = (int)FileReadNumber(h); p.minScore = (int)FileReadNumber(h);
      for(int i = 0; i < ArraySize(g_syms); i++)
         if(g_syms[i] == sym && p.ma1 > 0 && p.ma4 > 0 && p.rsiP > 0 && p.adxP > 0 && p.bbP > 0)
         { g_par[i] = p; loaded++; }
   }
   FileClose(h);
   PrintFormat("TrendScanner：從 params.csv 載入 %d 個商品的個別參數", loaded);
}

//+------------------------------------------------------------------+
//| 指標                                                              |
//+------------------------------------------------------------------+
void MakeHandles(const string s, const ENUM_TIMEFRAMES tf, const SParams &p, SHandles &h)
{
   h.ma1  = iMA(s, tf, p.ma1, 0, MODE_SMA, PRICE_CLOSE);
   h.ma2  = iMA(s, tf, p.ma2, 0, MODE_SMA, PRICE_CLOSE);
   h.ma3  = iMA(s, tf, p.ma3, 0, MODE_SMA, PRICE_CLOSE);
   h.ma4  = iMA(s, tf, p.ma4, 0, MODE_SMA, PRICE_CLOSE);
   h.macd = iMACD(s, tf, p.macdF, p.macdS, p.macdSig, PRICE_CLOSE);
   h.rsi  = iRSI(s, tf, p.rsiP, PRICE_CLOSE);
   h.adx  = iADX(s, tf, p.adxP);
   h.bb   = iBands(s, tf, p.bbP, 0, 2.0, PRICE_CLOSE);
   h.atr  = iATR(s, tf, 14);
}

void FreeHandles(SHandles &h)
{
   int a[9];
   a[0] = h.ma1; a[1] = h.ma2; a[2] = h.ma3; a[3] = h.ma4; a[4] = h.macd;
   a[5] = h.rsi; a[6] = h.adx; a[7] = h.bb;  a[8] = h.atr;
   for(int i = 0; i < 9; i++) if(a[i] != INVALID_HANDLE) IndicatorRelease(a[i]);
}

bool Buf(const int h, const int b, const int shift, double &v)
{
   if(h == INVALID_HANDLE) return false;
   double x[1];
   if(CopyBuffer(h, b, shift, 1, x) != 1 || x[0] == EMPTY_VALUE || !MathIsValidNumber(x[0])) return false;
   v = x[0];
   return true;
}

// 8 票評分；回傳 false = 資料未備妥。votes 為各票明細，例如 "T+T+T+T+M+D+V+Q+"
bool Score(const string s, const ENUM_TIMEFRAMES tf, const SParams &p, const SHandles &h,
           int &score, double &adx, string &votes)
{
   double m1, m2, m3, m4, m4old, mac, sig, rsi, pdi, mdi, mid, atr;
   if(!Buf(h.ma1, 0, 1, m1) || !Buf(h.ma2, 0, 1, m2) || !Buf(h.ma3, 0, 1, m3) || !Buf(h.ma4, 0, 1, m4)) return false;
   if(!Buf(h.ma4, 0, 6, m4old) || !Buf(h.macd, 0, 1, mac) || !Buf(h.macd, 1, 1, sig)) return false;
   if(!Buf(h.rsi, 0, 1, rsi) || !Buf(h.adx, 0, 1, adx) || !Buf(h.adx, 1, 1, pdi) || !Buf(h.adx, 2, 1, mdi)) return false;
   if(!Buf(h.bb, 0, 1, mid) || !Buf(h.atr, 0, 1, atr) || atr <= 0) return false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = MathMax(p.volBars, 2);
   if(CopyRates(s, tf, 1, need, r) != need) return false;
   double c = r[0].close;

   int v[8];
   v[0] = (m1 > m2 && m2 > m3 && m3 > m4) ? 1 : ((m1 < m2 && m2 < m3 && m3 < m4) ? -1 : 0);   // 均線排列
   v[1] = (c > m4) ? 1 : -1;                                                                   // 價在 MA4 上/下
   double slope = (m4 - m4old) / atr;
   v[2] = (slope > 0.1) ? 1 : ((slope < -0.1) ? -1 : 0);                                       // MA4 斜率
   v[3] = (mac > sig) ? 1 : -1;                                                                // MACD
   v[4] = (rsi >= p.rsiBull) ? 1 : ((rsi <= p.rsiBear) ? -1 : 0);                             // RSI 動能
   v[5] = (pdi > mdi) ? 1 : -1;                                                                // DMI
   v[6] = (c > mid) ? 1 : -1;                                                                  // 布林中軌
   double up = 0, dn = 0;
   for(int i = 0; i < need; i++)
   {
      if(r[i].close > r[i].open) up += (double)r[i].tick_volume;
      else if(r[i].close < r[i].open) dn += (double)r[i].tick_volume;
   }
   v[7] = (up > dn) ? 1 : ((up < dn) ? -1 : 0);                                                // 量能

   string tag[8] = {"排", "MA", "斜", "MACD", "RSI", "DMI", "BB", "量"};
   score = 0; votes = "";
   for(int i = 0; i < 8; i++)
   {
      score += v[i];
      votes += tag[i] + (v[i] > 0 ? "+" : (v[i] < 0 ? "-" : "0")) + " ";
   }
   return true;
}

//+------------------------------------------------------------------+
//| 掃描                                                              |
//+------------------------------------------------------------------+
bool GroupWanted(const string code)
{
   string list = "," + InpGroups + ",";
   StringReplace(list, " ", "");
   return StringFind(list, "," + code + ",") >= 0;
}

void LoadSymbols()
{
   ArrayResize(g_syms, 0);
   bool mw = (InpSource == SRC_MARKETWATCH);
   string wl = InpSymbols;
   StringReplace(wl, " ", "");
   if(wl != "")
   {
      string p[];
      int m = StringSplit(wl, ',', p);
      for(int i = 0; i < m; i++)
      {
         if(p[i] == "" || !SymbolSelect(p[i], true)) { if(p[i] != "") PrintFormat("TrendScanner：找不到商品 %s，略過", p[i]); continue; }
         int n = ArraySize(g_syms);
         ArrayResize(g_syms, n + 1);
         g_syms[n] = p[i];
      }
   }
   else
   for(int i = 0; i < SymbolsTotal(mw); i++)
   {
      string s = SymbolName(i, mw);
      if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) continue;
      if(!GroupWanted(GroupCode(SymbolGroup(s)))) continue;
      int n = ArraySize(g_syms);
      ArrayResize(g_syms, n + 1);
      g_syms[n] = s;
   }
   int n = ArraySize(g_syms);
   ArrayResize(g_par, n);
   ArrayResize(g_hm, n);
   ArrayResize(g_hc, n);
   LoadParams();
   for(int i = 0; i < n; i++)
   {
      MakeHandles(g_syms[i], InpTF, g_par[i], g_hm[i]);
      MakeHandles(g_syms[i], InpConfirmTF, g_par[i], g_hc[i]);
      g_fib.Prepare(g_syms[i]);
   }
   PrintFormat("TrendScanner：掃描 %d 個商品（%s）", n, wl != "" ? "指定清單" : (mw ? "市場報價，分組 " + InpGroups : "全部商品，分組 " + InpGroups));
}

double SuggestLots(const string s, const double dist)
{
   double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0 || dist <= 0) return 0;
   double lots = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0 / (dist / ts * tv);
   double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   if(step <= 0) step = 0.01;
   lots = MathFloor(MathMin(lots, InpMaxLot) / step + 1e-7) * step;
   return (lots < mn - 1e-9) ? 0 : NormalizeDouble(lots, 2);
}

void Scan()
{
   ArrayResize(g_plans, 0);
   int pending = 0;
   for(int i = 0; i < ArraySize(g_syms); i++)
   {
      string s = g_syms[i];
      SParams p = g_par[i];
      int sc, scC; double adx, adxC; string votes, votesC;
      if(!Score(s, InpTF, p, g_hm[i], sc, adx, votes) || !Score(s, InpConfirmTF, p, g_hc[i], scC, adxC, votesC))
      { pending++; continue; }
      if(MathAbs(sc) < p.minScore || adx < p.adxMin) continue;
      int dir = (sc > 0) ? 1 : -1;
      if(scC * dir < InpConfirmMin) continue;                        // 確認週期同方向且夠強

      SRegime r;
      if(!g_fib.Evaluate(s, r)) { pending++; continue; }
      if(r.swingDir != dir || r.fibRatio > 0.618) continue;          // 波段方向不符或回檔太深

      double price = (dir > 0) ? SymbolInfoDouble(s, SYMBOL_ASK) : SymbolInfoDouble(s, SYMBOL_BID);
      string mode; double entry;
      if(r.fibRatio >= 0.382) { mode = "現價"; entry = price; }
      else                    { mode = "限價"; entry = r.fib[2]; }

      double sl, tp, rr;
      if(!g_fib.CalcStops(r, dir, entry, sl, tp, rr) || rr < InpMinRR) continue;

      int n = ArraySize(g_plans);
      ArrayResize(g_plans, n + 1);
      g_plans[n].sym = s;  g_plans[n].idx = i;  g_plans[n].dir = dir;
      g_plans[n].score = sc; g_plans[n].scoreC = scC; g_plans[n].adx = adx;
      g_plans[n].mode = mode; g_plans[n].zone = r.fibZone; g_plans[n].votes = votes;
      g_plans[n].entry = entry; g_plans[n].sl = sl; g_plans[n].tp = tp; g_plans[n].rr = rr;
      g_plans[n].lots = SuggestLots(s, MathAbs(entry - sl));
      g_plans[n].strength = MathAbs(sc) + MathAbs(scC) / 2.0 + adx / 10.0 + rr;
   }

   int n = ArraySize(g_plans);
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
         if(g_plans[b].strength > g_plans[a].strength)
         { SPlan x = g_plans[a]; g_plans[a] = g_plans[b]; g_plans[b] = x; }

   Report(pending);
   if(g_canTrade) ExecutePlans();
}

void Report(const int pending)
{
   datetime now = TimeTradeServer();
   int n = ArraySize(g_plans);
   PrintFormat("===== TrendScanner %s  掃描 %d 個，趨勢計畫 %d 個%s =====",
               TimeToString(now, TIME_DATE | TIME_MINUTES), ArraySize(g_syms), n,
               pending > 0 ? StringFormat("（%d 個資料未備妥）", pending) : "");

   MqlDateTime t; TimeToStruct(now, t);
   FolderCreate("TrendScanner", FILE_COMMON);
   string file = StringFormat("TrendScanner\\plans_%04d%02d%02d.csv", t.year, t.mon, t.day);
   bool exists = FileIsExist(file, FILE_COMMON);
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      if(!exists)
         FileWrite(h, "scan_time", "symbol", "dir", "score", "score_confirm", "adx", "mode",
                   "entry", "sl", "tp", "rr", "lots", "fib_zone", "votes");
   }

   g_panel = StringFormat("📈 TrendScanner v2  %s  %s\n掃描 %d 個 | 計畫 %d 個 | 每筆風險 %.2f%% | 加碼最多 %d 單\n",
                          TimeToString(now, TIME_DATE | TIME_MINUTES),
                          g_canTrade ? "⚠️ 執行模式" : "📝 只產生計畫",
                          ArraySize(g_syms), n, InpRiskPct, InpMaxUnits);

   for(int i = 0; i < n; i++)
   {
      SPlan p = g_plans[i];
      int dg = (int)SymbolInfoInteger(p.sym, SYMBOL_DIGITS);
      string side = (p.dir > 0) ? "做多" : "做空";
      string line = StringFormat("%-11s %s %s 進%.*f 損%.*f 利%.*f RR%.1f %.2f手 | %+d/%+d ADX%.0f | %s",
                                 p.sym, side, p.mode, dg, p.entry, dg, p.sl, dg, p.tp, p.rr, p.lots,
                                 p.score, p.scoreC, p.adx, p.zone);
      Print("  ", i + 1, ". ", line, " | ", p.votes);
      if(i < InpTopN) g_panel += IntegerToString(i + 1) + ". " + line + "\n";

      if(h != INVALID_HANDLE)
         FileWrite(h, TimeToString(now, TIME_DATE | TIME_MINUTES), p.sym, p.dir > 0 ? "BUY" : "SELL",
                   p.score, p.scoreC, DoubleToString(p.adx, 1), p.mode == "現價" ? "market" : "limit",
                   DoubleToString(p.entry, dg), DoubleToString(p.sl, dg), DoubleToString(p.tp, dg),
                   DoubleToString(p.rr, 2), DoubleToString(p.lots, 2), p.zone, p.votes);

      if(InpPush && !MQLInfoInteger(MQL_TESTER))
      {
         string key = p.sym + "|" + IntegerToString(p.dir);
         datetime last;
         if(!g_pushed.TryGetValue(key, last) || now - last >= InpRepeatHours * 3600)
         {
            g_pushed.TrySetValue(key, now);
            SendNotification(StringFormat("TrendScanner %s %s %s 進%.*f 損%.*f 利%.*f RR%.1f",
                                          p.sym, side, p.mode, dg, p.entry, dg, p.sl, dg, p.tp, p.rr));
         }
      }
   }
   if(n == 0) g_panel += "目前沒有符合條件的趨勢商品\n";
   if(h != INVALID_HANDLE) FileClose(h);
}

//+------------------------------------------------------------------+
//| 執行（只在 g_canTrade 時）                                          |
//+------------------------------------------------------------------+
// 本 EA 在該商品的持倉（依開倉時間排序，舊→新）
int MyPositions(const string s, ulong &tk[])
{
   ArrayResize(tk, 0);
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != s) continue;
      int n = ArraySize(tk);
      ArrayResize(tk, n + 1);
      tk[n] = t;
   }
   int n = ArraySize(tk);
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
      {
         PositionSelectByTicket(tk[a]); long ta = PositionGetInteger(POSITION_TIME_MSC);
         PositionSelectByTicket(tk[b]); long tb = PositionGetInteger(POSITION_TIME_MSC);
         if(tb < ta) { ulong x = tk[a]; tk[a] = tk[b]; tk[b] = x; }
      }
   return n;
}

int MyPendingCount(const string s)
{
   int c = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic && OrderGetString(ORDER_SYMBOL) == s) c++;
   }
   return c;
}

int SymbolsWithPositions()
{
   string seen = ";";
   int c = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      if(StringFind(seen, ";" + s + ";") < 0) { seen += s + ";"; c++; }
   }
   return c;
}

// 初始風險（價格距離）寫在註解裡：「TS u1 r=0.00123」
double InitRisk(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0;
   string c = PositionGetString(POSITION_COMMENT);
   int p = StringFind(c, "r=");
   double r = (p >= 0) ? StringToDouble(StringSubstr(c, p + 2)) : 0;
   if(r > 0) return r;
   // 註解被券商改掉時：止損仍在虧損側就用開倉價到止損的距離
   double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL);
   if(sl <= 0) return 0;
   double d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? open - sl : sl - open;
   return (d > 0) ? d : 0;
}

double ProfitR(const ulong ticket)
{
   double r = InitRisk(ticket);
   if(r <= 0 || !PositionSelectByTicket(ticket)) return 0;
   string s = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double px = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(s, SYMBOL_BID) : SymbolInfoDouble(s, SYMBOL_ASK);
   return ((type == POSITION_TYPE_BUY) ? px - open : open - px) / r;
}

double NormPrice(const string s, const double p)
{
   double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   return (ts > 0) ? NormalizeDouble(MathRound(p / ts) * ts, dg) : NormalizeDouble(p, dg);
}

bool StopTooClose(const string s, const bool isBuy, const double sl)
{
   double d = (double)MathMax(SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(s, SYMBOL_TRADE_FREEZE_LEVEL))
              * SymbolInfoDouble(s, SYMBOL_POINT);
   return isBuy ? (SymbolInfoDouble(s, SYMBOL_BID) - sl <= d) : (sl - SymbolInfoDouble(s, SYMBOL_ASK) <= d);
}

// 只往有利方向移動止損
bool MoveSL(const ulong ticket, double newSL, const string why)
{
   if(!PositionSelectByTicket(ticket)) return false;
   string s = PositionGetString(POSITION_SYMBOL);
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double cur = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
   newSL = NormPrice(s, newSL);
   if(cur > 0 && (isBuy ? newSL <= cur + SymbolInfoDouble(s, SYMBOL_POINT) : newSL >= cur - SymbolInfoDouble(s, SYMBOL_POINT))) return false;
   if(StopTooClose(s, isBuy, newSL)) return false;
   bool ok = g_trade.PositionModify(ticket, newSL, tp) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE;
   if(ok) PrintFormat("📐 %s #%I64u 止損 → %s（%s）", s, ticket, DoubleToString(newSL, (int)SymbolInfoInteger(s, SYMBOL_DIGITS)), why);
   return ok;
}

bool OpenUnit(const SPlan &p, const int unit, const bool market, const double entry, const double sl)
{
   string s = p.sym;
   double lots = SuggestLots(s, MathAbs(entry - sl));
   if(lots <= 0) { PrintFormat("TrendScanner：%s 以 %.2f%% 風險算出手數低於最小手數，略過", s, InpRiskPct); return false; }
   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   string cmt = StringFormat("TS u%d r=%s", unit, DoubleToString(MathAbs(entry - sl), dg));
   g_trade.SetTypeFillingBySymbol(s);
   bool ok;
   if(market)
      ok = (p.dir > 0) ? g_trade.Buy(lots, s, 0, NormPrice(s, sl), NormPrice(s, p.tp), cmt)
                       : g_trade.Sell(lots, s, 0, NormPrice(s, sl), NormPrice(s, p.tp), cmt);
   else
   {
      datetime exp = TimeTradeServer() + InpLimitExpiryH * 3600;
      ok = (p.dir > 0) ? g_trade.BuyLimit(lots, NormPrice(s, entry), s, NormPrice(s, sl), NormPrice(s, p.tp), ORDER_TIME_SPECIFIED, exp, cmt)
                       : g_trade.SellLimit(lots, NormPrice(s, entry), s, NormPrice(s, sl), NormPrice(s, p.tp), ORDER_TIME_SPECIFIED, exp, cmt);
   }
   uint rc = g_trade.ResultRetcode();
   ok = ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
   PrintFormat("%s %s %s 第%d單 %s %.2f手 進%.*f 損%.*f 利%.*f %s", ok ? "✅" : "❌", s, p.dir > 0 ? "做多" : "做空",
               unit, market ? "市價" : "限價", lots, dg, entry, dg, sl, dg, p.tp,
               ok ? "" : g_trade.ResultRetcodeDescription());
   return ok;
}

void ExecutePlans()
{
   for(int i = 0; i < ArraySize(g_plans); i++)
   {
      SPlan p = g_plans[i];
      ulong tk[];
      int units = MyPositions(p.sym, tk);

      //--- 反向：持有方向與新計畫相反 → 全部平倉
      if(units > 0)
      {
         PositionSelectByTicket(tk[0]);
         int held = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(held != p.dir)
         {
            if(InpExitOnReverse)
               for(int k = 0; k < units; k++)
               {
                  g_trade.SetTypeFillingBySymbol(p.sym);
                  g_trade.PositionClose(tk[k]);
                  PrintFormat("🔄 %s 出現反向趨勢計畫，平倉 #%I64u", p.sym, tk[k]);
               }
            continue;
         }
      }

      //--- 第一單
      if(units == 0)
      {
         if(MyPendingCount(p.sym) > 0) continue;
         if(SymbolsWithPositions() >= InpMaxSymbols) continue;
         OpenUnit(p, 1, p.mode == "現價", p.entry, p.sl);
         continue;
      }

      //--- 加碼：最新一單獲利 >= InpAddAtR，且未達上限
      if(units >= InpMaxUnits) continue;
      if(ProfitR(tk[units - 1]) < InpAddAtR) continue;

      // 先把所有既有單移到保本（之後只剩新單有風險）
      bool allBE = true;
      for(int k = 0; k < units; k++)
      {
         PositionSelectByTicket(tk[k]);
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double cur  = PositionGetDouble(POSITION_SL);
         bool isBuy  = (p.dir > 0);
         bool atBE   = cur > 0 && (isBuy ? cur >= open : cur <= open);
         if(!atBE && !MoveSL(tk[k], open, "加碼前移到保本")) allBE = false;
      }
      if(!allBE) continue;

      // 新單：現價進場，止損用目前斐波結構重新計算
      SRegime r;
      if(!g_fib.Evaluate(p.sym, r)) continue;
      double px = (p.dir > 0) ? SymbolInfoDouble(p.sym, SYMBOL_ASK) : SymbolInfoDouble(p.sym, SYMBOL_BID);
      double sl, tp, rr;
      if(!g_fib.CalcStops(r, p.dir, px, sl, tp, rr)) continue;
      OpenUnit(p, units + 1, true, px, sl);
   }
}

int SymIndex(const string s)
{
   for(int i = 0; i < ArraySize(g_syms); i++) if(g_syms[i] == s) return i;
   return -1;
}

//--- 移動止損
void ManageTrailing()
{
   if(InpTrail == TRAIL_NONE) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double r = ProfitR(t);
      if(r < InpBEAtR) continue;

      double target = open;                                     // 至少保本
      if(InpTrail == TRAIL_ATR)
      {
         double atr;
         int k = SymIndex(s);
         if(k >= 0 && Buf(g_hm[k].atr, 0, 1, atr) && atr > 0)
         {
            double px = isBuy ? SymbolInfoDouble(s, SYMBOL_BID) : SymbolInfoDouble(s, SYMBOL_ASK);
            double trail = isBuy ? px - InpTrailATRMult * atr : px + InpTrailATRMult * atr;
            target = isBuy ? MathMax(target, trail) : MathMin(target, trail);
         }
      }
      else if(InpTrail == TRAIL_SWING)
      {
         double hl[];
         int got = isBuy ? CopyLow(s, InpTF, 1, InpSwingBars, hl) : CopyHigh(s, InpTF, 1, InpSwingBars, hl);
         if(got == InpSwingBars)
         {
            double sw = isBuy ? hl[ArrayMinimum(hl)] : hl[ArrayMaximum(hl)];
            target = isBuy ? MathMax(target, sw) : MathMin(target, sw);
         }
      }
      MoveSL(t, target, InpTrail == TRAIL_BE ? "保本" : (InpTrail == TRAIL_ATR ? "ATR 追蹤" : "擺動追蹤"));
   }
}

//+------------------------------------------------------------------+
bool AccountAllowed()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(InpLockAccount != 0 && login != InpLockAccount) return false;
   if(!InpAllowReal && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL) return false;
   return true;
}

int OnInit()
{
   g_fib.TF = InpTF;
   g_fib.MinRR = InpMinRR;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_canTrade = InpTradeEnabled && AccountAllowed();
   if(InpTradeEnabled && !g_canTrade)
      Print("TrendScanner：此帳號不允許下單（真實帳戶或非指定帳號），改為只產生計畫");
   PrintFormat("TrendScanner v2：%s，每筆風險 %.2f%%，移動止損 %s，加碼最多 %d 單",
               g_canTrade ? "⚠️ 執行模式" : "📝 只產生計畫", InpRiskPct, EnumToString(InpTrail), InpMaxUnits);
   LoadSymbols();
   EventSetTimer(5);
   Comment("📈 TrendScanner 載入中，指標資料準備好後開始第一次掃描…");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_syms); i++) { FreeHandles(g_hm[i]); FreeHandles(g_hc[i]); }
   g_fib.Release();
   Comment("");
}

void OnTimer()
{
   if(g_canTrade) ManageTrailing();

   datetime now = TimeTradeServer();
   datetime bar = iTime(_Symbol, InpTF, 0);
   bool due = (g_lastScan == 0) || (now - g_lastScan >= InpScanMinutes * 60) || (bar != 0 && bar != g_lastBar);
   if(due)
   {
      Scan();
      g_lastBar = bar;
      // 第一次常有資料未備妥：沒有計畫時 2 分鐘後再掃一次
      g_lastScan = (ArraySize(g_plans) == 0 && g_lastScan == 0) ? now - InpScanMinutes * 60 + 120 : now;
   }
   Comment(g_panel);
}
//+------------------------------------------------------------------+
