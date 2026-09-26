//+------------------------------------------------------------------+
//|  MLRecorder.mqh                                                  |
//|  ML 第1階段：記錄每個信號的特徵，並用 M1 K 線往後追蹤              |
//|  先到 TP / 先到 SL / 逾時，標上結果後寫成 CSV（訓練資料）          |
//|  輸出：Common\Files\mt_ea_ml\ （setup_drives.bat 連結到 H:\ml）    |
//+------------------------------------------------------------------+
#ifndef MLRECORDER_MQH
#define MLRECORDER_MQH

#define ML_LABEL_SL      0
#define ML_LABEL_TP      1
#define ML_LABEL_TIMEOUT 2
#define ML_LABEL_OPEN   -1   // EA 結束時仍未有結果

struct SMLPending
{
   string   sym;
   int      dir;
   datetime sigTime;
   datetime checkFrom;   // 下一根要檢查的 M1 K 線開盤時間
   double   entry;
   double   sl;
   double   tp;
   double   slDist;
   double   mfe;         // 最大有利 (價格)
   double   mae;         // 最大不利 (價格)
   int      bars;
   string   features;
};

class CMLRecorder
{
private:
   bool       m_enabled;
   string     m_file;
   int        m_maxHoldMin;
   datetime   m_lastM1;
   SMLPending m_pend[];

   string Header()
   {
      return "signal_time,symbol,dir,entry,sl,tp,spread_pips,score,buy_score,sell_score,"
             "s_ema,s_rsi,s_bb,s_macd,s_stoch,atr_pips,ema_gap,ema_slope,close_ema,"
             "rsi,rsi_chg,bb_pos,bb_width,bb_width_chg,macd,macd_hist,macd_hist_chg,"
             "stoch_k,stoch_d,hour,dow,has_pos,vol_ok,"
             "label,outcome_time,bars_held,mfe_r,mae_r";
   }

   void WriteRow(const SMLPending &p, int label, datetime outTime)
   {
      int h = FileOpen(m_file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_COMMON);
      if(h == INVALID_HANDLE)
      {
         PrintFormat("⚠️ MLRecorder: 無法寫入 Common\\Files\\%s (err=%d)", m_file, GetLastError());
         return;
      }
      if(FileSize(h) == 0) FileWriteString(h, Header() + "\r\n");
      FileSeek(h, 0, SEEK_END);

      int digits = (int)SymbolInfoInteger(p.sym, SYMBOL_DIGITS);
      string row = StringFormat("%s,%s,%d,%s,%s,%s,%s,%d,%s,%d,%.3f,%.3f",
         TimeToString(p.sigTime, TIME_DATE|TIME_SECONDS), p.sym, p.dir,
         DoubleToString(p.entry, digits), DoubleToString(p.sl, digits), DoubleToString(p.tp, digits),
         p.features,
         label,
         (outTime > 0 ? TimeToString(outTime, TIME_DATE|TIME_MINUTES) : ""),
         p.bars,
         p.mfe / p.slDist,
         p.mae / p.slDist);
      FileWriteString(h, row + "\r\n");
      FileClose(h);
   }

   // 回傳 true 表示已有結果（已寫出）
   bool Advance(SMLPending &p, datetime curM1)
   {
      if(p.checkFrom >= curM1) return false;

      MqlRates r[];
      int n = CopyRates(p.sym, PERIOD_M1, p.checkFrom, curM1 - 1, r);
      if(n <= 0) return false;

      double point = SymbolInfoDouble(p.sym, SYMBOL_POINT);
      for(int k = 0; k < n; k++)
      {
         if(r[k].time < p.checkFrom) continue;
         p.checkFrom = r[k].time + 60;
         p.bars++;

         // K 線是 Bid；賣單出場看 Ask = Bid + 點差
         double adj  = (p.dir < 0) ? r[k].spread * point : 0.0;
         double hi   = r[k].high + adj;
         double lo   = r[k].low  + adj;

         bool hitSL, hitTP;
         if(p.dir > 0)
         {
            hitSL = (lo <= p.sl);
            hitTP = (hi >= p.tp);
            p.mfe = MathMax(p.mfe, hi - p.entry);
            p.mae = MathMax(p.mae, p.entry - lo);
         }
         else
         {
            hitSL = (hi >= p.sl);
            hitTP = (lo <= p.tp);
            p.mfe = MathMax(p.mfe, p.entry - lo);
            p.mae = MathMax(p.mae, hi - p.entry);
         }

         // 同一根 M1 同時碰到 SL 與 TP：無法判斷先後，保守視為 SL
         if(hitSL) { WriteRow(p, ML_LABEL_SL, r[k].time); return true; }
         if(hitTP) { WriteRow(p, ML_LABEL_TP, r[k].time); return true; }

         if(r[k].time - p.sigTime >= m_maxHoldMin * 60)
         {
            WriteRow(p, ML_LABEL_TIMEOUT, r[k].time);
            return true;
         }
      }
      return false;
   }

public:
   CMLRecorder() : m_enabled(false), m_maxHoldMin(72*60), m_lastM1(0) {}

   void Init(bool enabled, int maxHoldHours)
   {
      m_enabled    = enabled;
      m_maxHoldMin = MathMax(1, maxHoldHours) * 60;
      ArrayResize(m_pend, 0);
      if(!m_enabled) return;

      MqlDateTime d; TimeToStruct(TimeLocal(), d);
      string stamp = StringFormat("%04d%02d%02d_%02d%02d%02d", d.year, d.mon, d.day, d.hour, d.min, d.sec);
      if(MQLInfoInteger(MQL_TESTER))
      {
         // 回測中 TimeLocal() 是模擬時間：同一段期間重跑會得到相同檔名，先刪掉舊檔避免混在一起
         m_file = "mt_ea_ml\\features_tester_" + stamp + ".csv";
         FileDelete(m_file, FILE_COMMON);
      }
      else
         m_file = StringFormat("mt_ea_ml\\features_live_%I64d_%s.csv", AccountInfoInteger(ACCOUNT_LOGIN), stamp);
      Print("MLRecorder: 訓練資料輸出到 Common\\Files\\", m_file);
   }

   bool Enabled() { return m_enabled; }

   void Add(string sym, int dir, double entry, double slDist, double tpDist,
            datetime sigTime, string features)
   {
      if(!m_enabled || slDist <= 0) return;
      int k = ArraySize(m_pend);
      ArrayResize(m_pend, k + 1);
      m_pend[k].sym       = sym;
      m_pend[k].dir       = dir;
      m_pend[k].sigTime   = sigTime;
      m_pend[k].checkFrom = (datetime)((long)sigTime - (long)sigTime % 60 + 60);
      m_pend[k].entry     = entry;
      m_pend[k].sl        = (dir > 0) ? entry - slDist : entry + slDist;
      m_pend[k].tp        = (dir > 0) ? entry + tpDist : entry - tpDist;
      m_pend[k].slDist    = slDist;
      m_pend[k].mfe       = 0;
      m_pend[k].mae       = 0;
      m_pend[k].bars      = 0;
      m_pend[k].features  = features;
   }

   // 每個 tick 呼叫；每分鐘只實際檢查一次
   void Update()
   {
      if(!m_enabled || ArraySize(m_pend) == 0) return;
      datetime now   = TimeCurrent();
      datetime curM1 = (datetime)((long)now - (long)now % 60);
      if(curM1 == m_lastM1) return;
      m_lastM1 = curM1;

      for(int i = ArraySize(m_pend) - 1; i >= 0; i--)
         if(Advance(m_pend[i], curM1))
            ArrayRemove(m_pend, i, 1);
   }

   // EA 結束時把尚未有結果的也寫出（label=-1），訓練時會被排除
   void Flush()
   {
      if(!m_enabled) return;
      for(int i = 0; i < ArraySize(m_pend); i++)
         WriteRow(m_pend[i], ML_LABEL_OPEN, 0);
      ArrayResize(m_pend, 0);
   }
};

#endif
