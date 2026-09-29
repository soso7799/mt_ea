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

   CMarketRegime()
   {
      TF = PERIOD_H1; SwingBars = 120; SlopeBars = 5;
      RsiDevLimit = 16; RsiLow = 30; RsiHigh = 70; FibNearATR = 0.3;
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
      r.close = rt[0].close;

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
                          digits, r.support, digits, r.resistance);
   }
};

#endif // MARKET_REGIME_MQH
//+------------------------------------------------------------------+
