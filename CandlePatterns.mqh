//+------------------------------------------------------------------+
//|  CandlePatterns.mqh                                              |
//|  K線型態濾網：翻多十六種型態 + 翻空十八種型態                      |
//|                                                                  |
//|  依《翻多十六種型態》《翻空十八種型態》文字規則轉成程式：            |
//|   * 長紅/長黑/小K/十字(變盤線)/鎚子/反鎚 以 ATR 倍數判斷，           |
//|     不同商品、不同週期都適用                                       |
//|   * 「下跌趨勢中/上漲趨勢中」= 型態前 TrendBars 根收盤變動 >= TrendATR×ATR |
//|   * 外匯盤中幾乎沒有真正的跳空缺口，預設採「實體跳空」(本根實體與前根  |
//|     實體不重疊，容許 NearATR 誤差)；StrictGap=true 改用高低點跳空     |
//|   * 文件寫明「突破/跌破…才可確認」的型態 (needConfirm)，型態完成後   |
//|     要等下一根K棒收盤突破型態最高點(翻多)/跌破型態最低點(翻空)才發訊號 |
//|   * 只使用已收盤的K棒，沒有未來函數                                  |
//|                                                                  |
//|  型態代碼：B1~B16 = 翻多第1~16招，S1~S18 = 反空第1~18招             |
//+------------------------------------------------------------------+
#ifndef CANDLE_PATTERNS_MQH
#define CANDLE_PATTERNS_MQH

enum ENUM_CP_MODE
{
   CP_OFF     = 0,   // 關閉
   CP_VETO    = 1,   // 出現反向型態就不進場
   CP_REQUIRE = 2,   // 必須有同向型態才進場
   CP_SCORE   = 3    // 當作第6個指標加權計分
};

#define CP_COUNT 34

class CCandlePatterns
{
private:
   //--- 型態表
   string   m_code[CP_COUNT];
   string   m_name[CP_COUNT];
   int      m_dir[CP_COUNT];        // +1 翻多 / -1 翻空
   bool     m_needConfirm[CP_COUNT];
   bool     m_enabled[CP_COUNT];

   //--- ATR handle 快取 (key = 商品|週期)
   string   m_atrKey[];
   int      m_atrH[];

   //--- 目前計算中的K棒資料 (series：0 = 最近一根已收盤K棒)
   MqlRates m_r[];
   int      m_n;
   double   m_atr;

   //--- K棒基本量
   double O(int k)    { return m_r[k].open;  }
   double Hi(int k)   { return m_r[k].high;  }
   double Lo(int k)   { return m_r[k].low;   }
   double C(int k)    { return m_r[k].close; }
   double Body(int k) { return MathAbs(C(k) - O(k)); }
   double Rng(int k)  { return Hi(k) - Lo(k); }
   double BTop(int k) { return MathMax(O(k), C(k)); }
   double BBot(int k) { return MathMin(O(k), C(k)); }
   double UpSh(int k) { return Hi(k) - BTop(k); }
   double DnSh(int k) { return BBot(k) - Lo(k); }
   bool   Bull(int k) { return C(k) > O(k); }
   bool   Bear(int k) { return C(k) < O(k); }

   //--- K棒分類
   bool   Long(int k)      { return Body(k) >= LongATR  * m_atr; }
   bool   LongBull(int k)  { return Bull(k) && Long(k); }
   bool   LongBear(int k)  { return Bear(k) && Long(k); }
   bool   Small(int k)     { return Body(k) <= SmallATR * m_atr; }
   // 變盤線：十字線、電阻線 (實體很小)
   bool   Doji(int k)      { return Body(k) <= DojiATR * m_atr || (Rng(k) > 0 && Body(k) <= 0.1 * Rng(k)); }
   // 鎚子線/吊人線：長下影、幾乎沒有上影
   bool   Hammer(int k)    { return Rng(k) > 0 && DnSh(k) >= 0.6 * Rng(k) && UpSh(k) <= 0.15 * Rng(k); }
   // 反鎚線/墓碑線：長上影、幾乎沒有下影
   bool   InvHammer(int k) { return Rng(k) > 0 && UpSh(k) >= 0.6 * Rng(k) && DnSh(k) <= 0.15 * Rng(k); }
   bool   Near(double a, double b) { return MathAbs(a - b) <= NearATR * m_atr; }
   bool   Inside(int k, int m)     { return Hi(k) <= Hi(m) && Lo(k) >= Lo(m); }

   //--- 跳空：k 是較新的K棒，k+1 是前一根
   bool GapUp(int k)
   {
      if(StrictGap) return Lo(k) > Hi(k+1);
      return BBot(k) >= BTop(k+1) - NearATR * 0.5 * m_atr;
   }
   bool GapDown(int k)
   {
      if(StrictGap) return Hi(k) < Lo(k+1);
      return BTop(k) <= BBot(k+1) + NearATR * 0.5 * m_atr;
   }
   // 開盤跳空 (烏雲罩頂/跳空見鬼/一泄千里)：外匯開盤≈前收盤，非嚴格模式只要求不低於/不高於前收盤
   bool OpenGapUp(int k)   { return StrictGap ? O(k) > Hi(k+1) : O(k) >= C(k+1) - NearATR * 0.5 * m_atr; }
   bool OpenGapDown(int k) { return StrictGap ? O(k) < Lo(k+1) : O(k) <= C(k+1) + NearATR * 0.5 * m_atr; }

   //--- 趨勢：start = 型態最舊那根K棒，比較它前一根與再往前 TrendBars 根的收盤
   bool DownBefore(int start)
   {
      int a = start + 1, b = start + 1 + TrendBars;
      if(b >= m_n) return false;
      return C(b) - C(a) >= TrendATR * m_atr;
   }
   bool UpBefore(int start)
   {
      int a = start + 1, b = start + 1 + TrendBars;
      if(b >= m_n) return false;
      return C(a) - C(b) >= TrendATR * m_atr;
   }

   int FindCode(string code)
   {
      for(int i=0; i<CP_COUNT; i++)
         if(m_code[i] == code) return i;
      return -1;
   }

   void Def(int i, string code, string name, int dir, bool needConfirm)
   {
      m_code[i] = code; m_name[i] = name; m_dir[i] = dir;
      m_needConfirm[i] = needConfirm; m_enabled[i] = true;
   }

   int AtrHandle(string sym, ENUM_TIMEFRAMES tf)
   {
      string key = sym + "|" + IntegerToString((int)tf);
      for(int i=0; i<ArraySize(m_atrKey); i++)
         if(m_atrKey[i] == key) return m_atrH[i];

      int h = iATR(sym, tf, 14);
      if(h == INVALID_HANDLE) return INVALID_HANDLE;

      int n = ArraySize(m_atrKey);
      ArrayResize(m_atrKey, n+1);
      ArrayResize(m_atrH,   n+1);
      m_atrKey[n] = key;
      m_atrH[n]   = h;
      return h;
   }

   //-----------------------------------------------------------------
   // 型態比對：e = 型態最後一根K棒的索引；成功時回傳型態最舊那根的索引 start，
   // 失敗回傳 -1。各型態規則對照文件原文。
   //-----------------------------------------------------------------
   int Match(int id, int e)
   {
      if(e + 6 >= m_n) return -1;

      switch(id)
      {
         //================ 翻多 ================
         case 0: // B1 一柱擎天：跳空下殺後長紅反撲，越過前兩日收盤
            if(DownBefore(e+2) && GapDown(e+1) && LongBull(e) &&
               C(e) > MathMax(C(e+1), C(e+2)))
               return e+2;
            return -1;

         case 1: // B2 一星二陽：紅K-變盤線-紅K，第三根低點與第一根高點相近或較高 (上漲中繼)
            if(UpBefore(e+2) && Bull(e+2) && Doji(e+1) && Bull(e) &&
               Lo(e+1) >= MathMin(Lo(e+2), Lo(e)) && Hi(e+1) <= MathMax(Hi(e+2), Hi(e)) &&
               Lo(e) >= Hi(e+2) - NearATR * m_atr)
               return e+2;
            return -1;

         case 2: // B3 上升三法：長紅-若干小K(不破第一根低點)-長紅反噬
         {
            for(int m=2; m<=4; m++)
            {
               int f = e + m + 1;
               if(f + 1 + TrendBars >= m_n) break;
               if(!LongBull(f) || !LongBull(e) || !UpBefore(f)) continue;
               bool ok = true;
               double midHi = 0;
               for(int k=e+1; k<f; k++)
               {
                  if(!Small(k) || Lo(k) <= Lo(f) || Hi(k) > Hi(f) + NearATR * m_atr) { ok = false; break; }
                  midHi = MathMax(midHi, Hi(k));
               }
               if(ok && C(e) > midHi && C(e) > C(f) && Hi(e) >= Hi(f) - NearATR * m_atr)
                  return f;
            }
            return -1;
         }

         case 3: // B4 內困三紅：長黑-小紅母子線-長紅突破長黑高點
            if(DownBefore(e+2) && LongBear(e+2) && Bull(e+1) && Small(e+1) && Inside(e+1, e+2) &&
               Bull(e) && C(e) > Hi(e+2))
               return e+2;
            return -1;

         case 4: // B5 三陽開泰：連三紅，開盤收盤一天比一天高，無長上影線
            if(Bull(e) && Bull(e+1) && Bull(e+2) &&
               O(e) > O(e+1) && O(e+1) > O(e+2) && C(e) > C(e+1) && C(e+1) > C(e+2) &&
               UpSh(e) < Body(e) && UpSh(e+1) < Body(e+1) && UpSh(e+2) < Body(e+2))
               return e+2;
            return -1;

         case 5: // B6 三線反紅：下跌中2~3根小紅小黑被長紅吞噬
         {
            for(int m=2; m<=3; m++)
            {
               int s = e + m;
               if(s + 1 + TrendBars >= m_n) break;
               if(!LongBull(e) || !DownBefore(s)) continue;
               bool ok = true;
               double maxHi = -DBL_MAX, minLo = DBL_MAX;
               for(int k=e+1; k<=s; k++)
               {
                  if(!Small(k)) { ok = false; break; }
                  maxHi = MathMax(maxHi, Hi(k));
                  minLo = MathMin(minLo, Lo(k));
               }
               if(ok && Hi(e) >= maxHi && Lo(e) <= minLo)
                  return s;
            }
            return -1;
         }

         case 6: // B7 外側三紅：黑K被長紅吞噬，第三根再突破長紅高點
            if(DownBefore(e+2) && Bear(e+2) && Bull(e+1) &&
               O(e+1) <= C(e+2) && C(e+1) >= O(e+2) && Body(e+1) > Body(e+2) &&
               Bull(e) && C(e) > Hi(e+1))
               return e+2;
            return -1;

         case 7: // B8 母子晨星：長黑-被環抱的變盤線-紅K突破長黑高點
            if(DownBefore(e+2) && LongBear(e+2) && Doji(e+1) && Inside(e+1, e+2) &&
               Bull(e) && C(e) > Hi(e+2))
               return e+2;
            return -1;

         case 8: // B9 晨星棄嬰：長黑-向下跳空變盤線-向上跳空長紅
            if(DownBefore(e+2) && LongBear(e+2) && Doji(e+1) && GapDown(e+1) &&
               LongBull(e) && GapUp(e))
               return e+2;
            return -1;

         case 9: // B10 破曉雙星：連兩根變盤線後長紅，越過雙星高點
            if(DownBefore(e+2) && Doji(e+2) && Doji(e+1) && LongBull(e) &&
               C(e) > MathMax(Hi(e+1), Hi(e+2)))
               return e+2;
            return -1;

         case 10: // B11 反鎚穿頂：長黑-反鎚/墓碑-長紅吞噬前兩日高點
            if(DownBefore(e+2) && LongBear(e+2) && InvHammer(e+1) && LongBull(e) &&
               C(e) > MathMax(Hi(e+1), Hi(e+2)))
               return e+2;
            return -1;

         case 11: // B12 起漲階梯：紅-黑(低點在紅K高點附近)-紅(低點在黑K高點附近)
            if(UpBefore(e+2) && Bull(e+2) && Bear(e+1) && Bull(e) &&
               Near(Lo(e+1), Hi(e+2)) && Near(Lo(e), Hi(e+1)))
               return e+2;
            return -1;

         case 12: // B13 閨中乳燕：兩黑-跌幅縮小的反鎚-長紅吞噬反鎚與前一黑K高點
            if(DownBefore(e+3) && Bear(e+3) && Bear(e+2) && InvHammer(e+1) &&
               Rng(e+1) < Rng(e+2) && LongBull(e) && C(e) > MathMax(Hi(e+1), Hi(e+2)))
               return e+3;
            return -1;

         case 13: // B14 飛鴿歸巢：兩黑-鎚子線-長紅越過鎚子高點
            if(DownBefore(e+3) && Bear(e+3) && Bear(e+2) && Hammer(e+1) &&
               LongBull(e) && C(e) > Hi(e+1))
               return e+3;
            return -1;

         case 14: // B15 雙鎚打樁：連兩根鎚子，第二根低點、收盤都較高
            if(DownBefore(e+1) && Hammer(e+1) && Hammer(e) && Lo(e) > Lo(e+1) && C(e) > C(e+1))
               return e+1;
            return -1;

         case 15: // B16 九生雙肩：連兩根紅K或帶下影線的盤堅K線，高低點幾乎一樣
            if(DownBefore(e+1) &&
               (Bull(e+1) || DnSh(e+1) >= Body(e+1)) && (Bull(e) || DnSh(e) >= Body(e)) &&
               Near(Hi(e), Hi(e+1)) && Near(Lo(e), Lo(e+1)))
               return e+1;
            return -1;

         //================ 翻空 ================
         case 16: // S1 一泄千里：跳空暴跌後的爆量長紅，低點被跌破
            if(DownBefore(e+1) && LongBull(e+1) && OpenGapDown(e+1) && C(e) < Lo(e+1))
               return e+1;
            return -1;

         case 17: // S2 一星二陰：黑K-變盤線-黑K，第二根黑K高點與第一根低點相近或較低 (下跌中繼)
            if(DownBefore(e+2) && Bear(e+2) && Doji(e+1) && Bear(e) &&
               Lo(e+1) >= MathMin(Lo(e+2), Lo(e)) && Hi(e+1) <= MathMax(Hi(e+2), Hi(e)) &&
               Hi(e) <= Lo(e+2) + NearATR * m_atr)
               return e+2;
            return -1;

         case 18: // S3 反錘二極：上漲中連兩根反錘，收盤與高點相近
            if(UpBefore(e+1) && InvHammer(e+1) && InvHammer(e) &&
               Near(C(e), C(e+1)) && Near(Hi(e), Hi(e+1)))
               return e+1;
            return -1;

         case 19: // S4 內困三黑：長紅-黑K母子線-黑K跌破長紅低點
            if(UpBefore(e+2) && LongBull(e+2) && Bear(e+1) && Inside(e+1, e+2) &&
               Bear(e) && C(e) < Lo(e+2))
               return e+2;
            return -1;

         case 20: // S5 外側三黑：中小紅被長黑環抱吞噬，隔日跌破長黑低點
            if(UpBefore(e+2) && Bull(e+2) && !Long(e+2) && LongBear(e+1) &&
               Hi(e+1) >= Hi(e+2) && Lo(e+1) <= Lo(e+2) && C(e) < Lo(e+1))
               return e+2;
            return -1;

         case 21: // S6 三線反黑：上漲中連續小紅被長黑吞噬
         {
            for(int m=2; m<=3; m++)
            {
               int s = e + m;
               if(s + 1 + TrendBars >= m_n) break;
               if(!LongBear(e) || !UpBefore(s)) continue;
               bool ok = true;
               double maxHi = -DBL_MAX, minLo = DBL_MAX;
               for(int k=e+1; k<=s; k++)
               {
                  if(!Bull(k) || !Small(k)) { ok = false; break; }
                  maxHi = MathMax(maxHi, Hi(k));
                  minLo = MathMin(minLo, Lo(k));
               }
               if(ok && Hi(e) >= maxHi && Lo(e) <= minLo)
                  return s;
            }
            return -1;
         }

         case 22: // S7 三鴉懸空：上漲中連三根黑K，收盤一根比一根低
            if(UpBefore(e+2) && Bear(e) && Bear(e+1) && Bear(e+2) &&
               C(e) < C(e+1) && C(e+1) < C(e+2) && Body(e) + Body(e+1) + Body(e+2) >= LongATR * m_atr * 1.5)
               return e+2;
            return -1;

         case 23: // S8 下降三法：長黑-若干小K(不過第一根高點)-長黑反噬
         {
            for(int m=2; m<=4; m++)
            {
               int f = e + m + 1;
               if(f + 1 + TrendBars >= m_n) break;
               if(!LongBear(f) || !LongBear(e) || !DownBefore(f)) continue;
               bool ok = true;
               double midLo = DBL_MAX;
               for(int k=e+1; k<f; k++)
               {
                  if(!Small(k) || Hi(k) >= Hi(f) || Lo(k) < Lo(f) - NearATR * m_atr) { ok = false; break; }
                  midLo = MathMin(midLo, Lo(k));
               }
               if(ok && C(e) < midLo && C(e) < C(f) && Lo(e) <= Lo(f) + NearATR * m_atr)
                  return f;
            }
            return -1;
         }

         case 24: // S9 九死雙肩：上漲中連兩根中長黑或長上影反錘，高低點幾乎一樣
            if(UpBefore(e+1) &&
               (Bear(e+1) || UpSh(e+1) >= Body(e+1)) && (Bear(e) || UpSh(e) >= Body(e)) &&
               Near(Hi(e), Hi(e+1)) && Near(Lo(e), Lo(e+1)))
               return e+1;
            return -1;

         case 25: // S10 母子夜星：長紅-被環抱的十字線-跌破長紅低點
            if(UpBefore(e+2) && LongBull(e+2) && Doji(e+1) && Inside(e+1, e+2) && C(e) < Lo(e+2))
               return e+2;
            return -1;

         case 26: // S11 夜星棄嬰：長紅-向上跳空變盤線-下跌K線
            if(UpBefore(e+2) && LongBull(e+2) && Doji(e+1) && GapUp(e+1) &&
               Bear(e) && (GapDown(e) || C(e) < Lo(e+1)))
               return e+2;
            return -1;

         case 27: // S12 夜空雙星：連兩根十字線後下跌K線
            if(UpBefore(e+2) && Doji(e+2) && Doji(e+1) && Bear(e) &&
               C(e) < MathMin(Lo(e+1), Lo(e+2)))
               return e+2;
            return -1;

         case 28: // S13 大敵當前：連三紅但都帶長上影線
            if(UpBefore(e+2) && Bull(e) && Bull(e+1) && Bull(e+2) &&
               C(e) > C(e+1) && C(e+1) > C(e+2) &&
               UpSh(e) >= Body(e) && UpSh(e+1) >= Body(e+1) && UpSh(e+2) >= Body(e+2))
               return e+2;
            return -1;

         case 29: // S14 烏雲罩頂：長紅後開高，收長黑落入前一根紅K實體一半以下
            if(UpBefore(e+1) && LongBull(e+1) && Bear(e) && OpenGapUp(e) &&
               C(e) < (O(e+1) + C(e+1)) / 2.0 && C(e) > O(e+1))
               return e+1;
            return -1;

         case 30: // S15 跳空見鬼：長紅後跳空開高，卻收在最低附近的長黑
            if(UpBefore(e+1) && LongBull(e+1) && OpenGapUp(e) && LongBear(e) &&
               Rng(e) > 0 && C(e) - Lo(e) <= 0.2 * Rng(e))
               return e+1;
            return -1;

         case 31: // S16 吊頸勒脖：連兩根吊人線，第二根收盤較低
            if(UpBefore(e+1) && Hammer(e+1) && Hammer(e) && C(e) < C(e+1))
               return e+1;
            return -1;

         case 32: // S17 上肩缺口：長紅-跳空長紅-長黑，但缺口尚未回補
            if(UpBefore(e+2) && LongBull(e+2) && LongBull(e+1) && GapUp(e+1) &&
               LongBear(e) && Hi(e) <= Hi(e+1) && Lo(e) > BTop(e+2))
               return e+2;
            return -1;

         case 33: // S18 走跌階梯：紅-黑(高點在紅K低點附近)-紅(高點在黑K低點附近)
            if(DownBefore(e+2) && Bull(e+2) && Bear(e+1) && Bull(e) &&
               Near(Hi(e+1), Lo(e+2)) && Near(Hi(e), Lo(e+1)))
               return e+2;
            return -1;
      }
      return -1;
   }

public:
   //--- 參數 (EA 在 OnInit 設定)
   int    TrendBars;     // 趨勢判斷回看K棒數
   double TrendATR;      // 趨勢最小幅度 (ATR 倍數)
   double LongATR;       // 長紅/長黑 實體 >= LongATR × ATR
   double SmallATR;      // 小K 實體 <= SmallATR × ATR
   double DojiATR;       // 十字/變盤線 實體 <= DojiATR × ATR
   double NearATR;       // 「相近」容許誤差 (ATR 倍數)
   bool   StrictGap;     // true = 高低點跳空；false = 實體跳空 (外匯建議)
   bool   ConfirmAll;    // true = 所有型態都要下一根K棒突破/跌破確認

   CCandlePatterns()
   {
      TrendBars = 5;  TrendATR = 1.0;
      LongATR   = 0.7; SmallATR = 0.35; DojiATR = 0.12; NearATR = 0.15;
      StrictGap = false; ConfirmAll = false;
      m_n = 0; m_atr = 0;

      //    代碼   名稱            方向  需確認
      Def(0,  "B1",  "一柱擎天",  1, false);
      Def(1,  "B2",  "一星二陽",  1, false);
      Def(2,  "B3",  "上升三法",  1, false);
      Def(3,  "B4",  "內困三紅",  1, false);
      Def(4,  "B5",  "三陽開泰",  1, false);
      Def(5,  "B6",  "三線反紅",  1, true);   // 長紅高點被突破時確認
      Def(6,  "B7",  "外側三紅",  1, false);
      Def(7,  "B8",  "母子晨星",  1, false);
      Def(8,  "B9",  "晨星棄嬰",  1, false);
      Def(9,  "B10", "破曉雙星",  1, false);
      Def(10, "B11", "反鎚穿頂",  1, false);
      Def(11, "B12", "起漲階梯",  1, true);   // 第三根紅K高點被突破時確認
      Def(12, "B13", "閨中乳燕",  1, false);
      Def(13, "B14", "飛鴿歸巢",  1, false);
      Def(14, "B15", "雙鎚打樁",  1, true);   // 爾後出現盤堅或上漲K線確認
      Def(15, "B16", "九生雙肩",  1, true);   // 脫離九生雙肩高點確認

      Def(16, "S1",  "一泄千里", -1, false);
      Def(17, "S2",  "一星二陰", -1, false);
      Def(18, "S3",  "反錘二極", -1, true);   // 第二根反錘低點被跌破
      Def(19, "S4",  "內困三黑", -1, false);
      Def(20, "S5",  "外側三黑", -1, false);
      Def(21, "S6",  "三線反黑", -1, true);   // 長黑低點被跌破時確認
      Def(22, "S7",  "三鴉懸空", -1, false);
      Def(23, "S8",  "下降三法", -1, false);
      Def(24, "S9",  "九死雙肩", -1, true);   // 跌破九死雙肩低點確認
      Def(25, "S10", "母子夜星", -1, false);
      Def(26, "S11", "夜星棄嬰", -1, false);
      Def(27, "S12", "夜空雙星", -1, false);
      Def(28, "S13", "大敵當前", -1, true);   // 跌破紅K低點確認
      Def(29, "S14", "烏雲罩頂", -1, true);   // 跌破長紅低點/再出現下跌K線確認
      Def(30, "S15", "跳空見鬼", -1, true);   // 再出現下跌K線或缺口回補確認
      Def(31, "S16", "吊頸勒脖", -1, true);   // 跌破第二根吊人線低點確認
      Def(32, "S17", "上肩缺口", -1, true);   // 缺口回補並跌破第一根長紅低點確認
      Def(33, "S18", "走跌階梯", -1, true);   // 第二根紅K低點被跌破時確認
   }

   ~CCandlePatterns() { Release(); }

   void Release()
   {
      for(int i=0; i<ArraySize(m_atrH); i++)
         if(m_atrH[i] != INVALID_HANDLE) IndicatorRelease(m_atrH[i]);
      ArrayResize(m_atrKey, 0);
      ArrayResize(m_atrH,   0);
   }

   // 停用型態，例如 "B5,S7,S14"（逗號/分號/空白分隔）
   void SetDisabled(string list)
   {
      for(int i=0; i<CP_COUNT; i++) m_enabled[i] = true;

      StringReplace(list, ";", ",");
      StringReplace(list, " ", ",");
      StringToUpper(list);
      string parts[];
      int n = StringSplit(list, ',', parts);
      for(int i=0; i<n; i++)
      {
         string c = parts[i];
         StringTrimLeft(c);
         StringTrimRight(c);
         if(c == "") continue;
         int id = FindCode(c);
         if(id >= 0) m_enabled[id] = false;
         else        PrintFormat("CandlePatterns: 未知的型態代碼 %s", c);
      }
   }

   //-----------------------------------------------------------------
   // 偵測最近完成的型態
   //   回傳 +1 = 只有翻多型態、-1 = 只有翻空型態、0 = 沒有或多空同時出現
   //   names 回傳所有符合的型態，例如 "B4內困三紅 S7三鴉懸空"
   //-----------------------------------------------------------------
   int Detect(string sym, ENUM_TIMEFRAMES tf, string &names)
   {
      names = "";

      int h = AtrHandle(sym, tf);
      if(h == INVALID_HANDLE) return 0;

      double a[1];
      if(CopyBuffer(h, 0, 1, 1, a) != 1 || a[0] == EMPTY_VALUE || a[0] <= 0) return 0;
      m_atr = a[0];

      ArraySetAsSeries(m_r, true);
      m_n = CopyRates(sym, tf, 1, 7 + 4 + TrendBars + 4, m_r);
      if(m_n < 8 + TrendBars) return 0;

      int bull = 0, bear = 0;

      for(int id=0; id<CP_COUNT; id++)
      {
         if(!m_enabled[id]) continue;

         bool confirm = (ConfirmAll || m_needConfirm[id]);
         int  e       = confirm ? 1 : 0;
         int  s       = Match(id, e);
         if(s < 0) continue;

         if(confirm)
         {
            // 最近一根已收盤K棒 (索引0) 要突破型態最高點 / 跌破型態最低點
            double hh = -DBL_MAX, ll = DBL_MAX;
            for(int k=e; k<=s; k++) { hh = MathMax(hh, Hi(k)); ll = MathMin(ll, Lo(k)); }
            if(m_dir[id] > 0 && C(0) <= hh) continue;
            if(m_dir[id] < 0 && C(0) >= ll) continue;
         }

         if(m_dir[id] > 0) bull++; else bear++;
         names += (names == "" ? "" : " ") + m_code[id] + m_name[id];
      }

      if(bull > 0 && bear == 0) return  1;
      if(bear > 0 && bull == 0) return -1;
      return 0;
   }
};

#endif // CANDLE_PATTERNS_MQH
//+------------------------------------------------------------------+
