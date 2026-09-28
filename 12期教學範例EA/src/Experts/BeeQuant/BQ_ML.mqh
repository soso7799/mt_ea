//+------------------------------------------------------------------+
//|  BQ_ML.mqh — 教學範例EA 的機器學習過濾器 (純 MQL5，免安裝 Python)   |
//|                                                                  |
//|  運作方式                                                          |
//|  1. EA 的原始策略照舊產生進場訊號                                   |
//|  2. 下單前呼叫 g_ml.Allow(方向, 停損距離, 停利距離)：               |
//|       - 取 12 個市場特徵 (RSI、均線斜率、波動度、時段、點差…)        |
//|       - 線上邏輯斯迴歸模型估計「先到停利」的機率 p                    |
//|       - p >= 損益兩平勝率 + 優勢門檻 才放行；暖機前一律放行          |
//|  3. 不論有沒有被放行，每個訊號都會建立一筆「虛擬單」                 |
//|     之後追蹤它先碰到停利還是停損 (或逾時)，得到 1/0 標籤            |
//|     → 立刻更新模型 (online learning)                                |
//|     被擋掉的訊號也會學習，避免模型只看到自己放行的單 (選擇偏誤)      |
//|  4. 模型存在 Common\Files\BeeQuantML\ ，下次回測/實盤可接續使用      |
//|     也可匯出 CSV，用 ml/train_logit.py 離線訓練後再放回來           |
//+------------------------------------------------------------------+
#ifndef BQ_ML_MQH
#define BQ_ML_MQH

#include "BQ_Indicators.mqh"

#define BQML_NF        12          // 特徵數
#define BQML_MAXVIRT   500         // 同時追蹤的虛擬單上限
#define BQML_DIR       "BeeQuantML"

enum ENUM_BQML_MODE
  {
   BQML_OFF    = 0,  // 關閉 (完全等同原策略)
   BQML_LEARN  = 1,  // 只學習、不過濾 (收集資料 / 訓練模型)
   BQML_FILTER = 2   // 學習並過濾訊號
  };

string BQML_FeatureName(const int i)
  {
   switch(i)
     {
      case 0:  return("dir");
      case 1:  return("rsi14");
      case 2:  return("close_vs_ema20");
      case 3:  return("ema20_vs_ema50");
      case 4:  return("ema20_slope");
      case 5:  return("atr_regime");
      case 6:  return("spread_atr");
      case 7:  return("hour_sin");
      case 8:  return("hour_cos");
      case 9:  return("last_body");
      case 10: return("range_pos20");
      case 11: return("adx14");
     }
   return("f"+IntegerToString(i));
  }

//+------------------------------------------------------------------+
//| 線上邏輯斯迴歸 (含 Welford 線上標準化)                              |
//+------------------------------------------------------------------+
class CBQOnlineLogit
  {
public:
   double            w[BQML_NF+1];   // 最後一個是截距
   double            mean[BQML_NF];
   double            m2[BQML_NF];
   long              n;              // 標準化統計的樣本數
   long              updates;        // 權重更新次數
   double            lr0;
   double            l2;

                     CBQOnlineLogit() { lr0=0.05; l2=0.001; Reset(); }

   void              Reset()
     {
      ArrayInitialize(w,0.0);
      ArrayInitialize(mean,0.0);
      ArrayInitialize(m2,0.0);
      n=0;
      updates=0;
     }

   void              Standardize(const double &x[],double &z[]) const
     {
      ArrayResize(z,BQML_NF);
      for(int i=0;i<BQML_NF;i++)
        {
         double v=x[i];
         if(n>1)
           {
            double sd=MathSqrt(m2[i]/(double)(n-1));
            if(sd<1e-9) sd=1.0;
            v=(x[i]-mean[i])/sd;
           }
         if(v>5.0)  v=5.0;
         if(v<-5.0) v=-5.0;
         z[i]=v;
        }
     }

   double            Score(const double &z[]) const
     {
      double s=w[BQML_NF];
      for(int i=0;i<BQML_NF;i++)
         s+=w[i]*z[i];
      if(s>30.0)  s=30.0;
      if(s<-30.0) s=-30.0;
      return(1.0/(1.0+MathExp(-s)));
     }

   double            Predict(const double &x[]) const
     {
      double z[];
      Standardize(x,z);
      return(Score(z));
     }

   void              Update(const double &x[],const int y)
     {
      //--- 1) 更新標準化統計
      n++;
      for(int i=0;i<BQML_NF;i++)
        {
         double d=x[i]-mean[i];
         mean[i]+=d/(double)n;
         m2[i]+=d*(x[i]-mean[i]);
        }
      //--- 2) 隨機梯度下降 (學習率隨樣本數遞減)
      double z[];
      Standardize(x,z);
      double p=Score(z);
      double g=p-(double)y;
      double lr=lr0/MathSqrt(1.0+(double)updates/50.0);
      for(int i=0;i<BQML_NF;i++)
         w[i]-=lr*(g*z[i]+l2*w[i]);
      w[BQML_NF]-=lr*g;
      updates++;
     }

   string            Join(const double &a[],const int cnt) const
     {
      string s="";
      for(int i=0;i<cnt;i++)
         s+=(i>0 ? "," : "")+DoubleToString(a[i],10);
      return(s);
     }

   bool              ParseTo(const string line,double &a[],const int cnt) const
     {
      string parts[];
      if(StringSplit(line,',',parts)!=cnt) return(false);
      for(int i=0;i<cnt;i++)
         a[i]=StringToDouble(parts[i]);
      return(true);
     }

   //--- 文字格式，Python 也能讀寫 (見 ml/train_logit.py)
   bool              Save(const string file) const
     {
      FolderCreate(BQML_DIR,FILE_COMMON);
      int h=FileOpen(file,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h==INVALID_HANDLE)
        {
         PrintFormat("BQ_ML: 無法寫入模型 %s err=%d",file,GetLastError());
         return(false);
        }
      FileWriteString(h,"BQML1\r\n");
      FileWriteString(h,IntegerToString(BQML_NF)+"\r\n");
      FileWriteString(h,IntegerToString(n)+"\r\n");
      FileWriteString(h,IntegerToString(updates)+"\r\n");
      FileWriteString(h,Join(w,BQML_NF+1)+"\r\n");
      FileWriteString(h,Join(mean,BQML_NF)+"\r\n");
      FileWriteString(h,Join(m2,BQML_NF)+"\r\n");
      FileClose(h);
      return(true);
     }

   bool              Load(const string file)
     {
      if(!FileIsExist(file,FILE_COMMON)) return(false);
      int h=FileOpen(file,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h==INVALID_HANDLE) return(false);
      string tag=FileReadString(h);
      StringTrimRight(tag);
      int nf=(int)StringToInteger(FileReadString(h));
      long nn=StringToInteger(FileReadString(h));
      long uu=StringToInteger(FileReadString(h));
      string lw=FileReadString(h), lm=FileReadString(h), ls=FileReadString(h);
      FileClose(h);
      if(tag!="BQML1" || nf!=BQML_NF)
        {
         PrintFormat("BQ_ML: 模型格式不符 %s (tag=%s nf=%d)，改用新模型",file,tag,nf);
         return(false);
        }
      double tw[BQML_NF+1],tm[BQML_NF],ts[BQML_NF];
      if(!ParseTo(lw,tw,BQML_NF+1) || !ParseTo(lm,tm,BQML_NF) || !ParseTo(ls,ts,BQML_NF))
        {
         PrintFormat("BQ_ML: 模型內容損壞 %s，改用新模型",file);
         return(false);
        }
      ArrayCopy(w,tw);
      ArrayCopy(mean,tm);
      ArrayCopy(m2,ts);
      n=nn;
      updates=uu;
      return(true);
     }
  };

//+------------------------------------------------------------------+
//| 特徵計算 (皆使用已收盤的 K 棒 shift=1，避免未來函數)                |
//| 有方向性的特徵都乘上 dir：正值 = 對這筆單有利，多空共用同一模型     |
//+------------------------------------------------------------------+
class CBQFeatures
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
public:
   void              Init(const string sym,const ENUM_TIMEFRAMES tf)
     {
      m_sym=sym;
      m_tf=tf;
      // 預先建立 handle，讓指標提早開始計算
      BQ_hATR(m_sym,m_tf,14);
      BQ_hATR(m_sym,m_tf,100);
      BQ_hRSI(m_sym,m_tf,14,PRICE_CLOSE);
      BQ_hMA(m_sym,m_tf,20,0,MODE_EMA,PRICE_CLOSE);
      BQ_hMA(m_sym,m_tf,50,0,MODE_EMA,PRICE_CLOSE);
      BQ_hADX(m_sym,m_tf,14);
     }

   double            ATR() const { return(BQ_ATR(m_sym,m_tf,14,1)); }

   bool              Build(const int dir,double &x[]) const
     {
      ArrayResize(x,BQML_NF);
      double atr =BQ_ATR(m_sym,m_tf,14,1);
      double atrL=BQ_ATR(m_sym,m_tf,100,1);
      double rsi =BQ_RSI(m_sym,m_tf,14,PRICE_CLOSE,1);
      double e20 =BQ_MA(m_sym,m_tf,20,0,MODE_EMA,PRICE_CLOSE,1);
      double e20b=BQ_MA(m_sym,m_tf,20,0,MODE_EMA,PRICE_CLOSE,6);
      double e50 =BQ_MA(m_sym,m_tf,50,0,MODE_EMA,PRICE_CLOSE,1);
      double adx =BQ_ADX(m_sym,m_tf,14,0,1);
      if(!BQ_Ok(atr) || !BQ_Ok(atrL) || !BQ_Ok(rsi) || !BQ_Ok(e20) || !BQ_Ok(e20b) ||
         !BQ_Ok(e50) || !BQ_Ok(adx) || atr<=0 || atrL<=0)
         return(false);

      MqlRates r[];
      ArraySetAsSeries(r,true);
      if(CopyRates(m_sym,m_tf,1,20,r)!=20)
         return(false);
      double hi=r[0].high,lo=r[0].low;
      for(int i=1;i<20;i++)
        {
         if(r[i].high>hi) hi=r[i].high;
         if(r[i].low<lo)  lo=r[i].low;
        }
      double spread=SymbolInfoDouble(m_sym,SYMBOL_ASK)-SymbolInfoDouble(m_sym,SYMBOL_BID);
      MqlDateTime t;
      TimeToStruct(TimeCurrent(),t);
      double hr=t.hour+t.min/60.0;
      double d=(dir>0 ? 1.0 : -1.0);

      x[0] =d;
      x[1] =(rsi-50.0)/50.0*d;
      x[2] =(r[0].close-e20)/atr*d;
      x[3] =(e20-e50)/atr*d;
      x[4] =(e20-e20b)/atr*d;
      x[5] =atr/atrL-1.0;
      x[6] =spread/atr;
      x[7] =MathSin(2.0*M_PI*hr/24.0);
      x[8] =MathCos(2.0*M_PI*hr/24.0);
      x[9] =(r[0].close-r[0].open)/atr*d;
      x[10]=(hi>lo ? ((r[0].close-lo)/(hi-lo)-0.5)*2.0*d : 0.0);
      x[11]=adx/50.0-0.5;
      for(int i=0;i<BQML_NF;i++)
        {
         if(!MathIsValidNumber(x[i])) return(false);
         if(x[i]>10.0)  x[i]=10.0;
         if(x[i]<-10.0) x[i]=-10.0;
        }
      return(true);
     }
  };

//--- 追蹤中的虛擬單
struct SBQVirtual
  {
   int               dir;
   double            entry;
   double            tp;
   double            sl;
   datetime          opened;
   datetime          lastBar;
   int               barsLeft;
   double            prob;
   double            be;          // 損益兩平勝率 (停損/(停損+停利))
   bool              scored;      // 當時模型是否已暖機 (用來算準確率)
   bool              allowed;
   double            x[BQML_NF];
  };

//+------------------------------------------------------------------+
//| ML 過濾器主體                                                      |
//+------------------------------------------------------------------+
class CBQMLFilter
  {
private:
   ENUM_BQML_MODE    m_mode;
   double            m_thr;
   int               m_minSamples;
   double            m_bTP;
   double            m_bSL;
   int               m_maxBars;
   bool              m_save;
   bool              m_scale;
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   string            m_file;
   int               m_csv;

   CBQOnlineLogit    m_model;
   CBQFeatures       m_feat;
   SBQVirtual        m_v[];

   datetime          m_sigBar[2];
   bool              m_sigDecision[2];
   double            m_lastProb;
   double            m_lastBE;

   int               m_signals,m_allowed,m_blocked;
   int               m_resolved,m_wins,m_scoredN,m_correct;
   int               m_allowedWins,m_allowedN,m_blockedWins,m_blockedN;

   void              Resolve(const int idx,const int y)
     {
      double xx[];
      ArrayResize(xx,BQML_NF);
      for(int i=0;i<BQML_NF;i++) xx[i]=m_v[idx].x[i];
      m_model.Update(xx,y);

      m_resolved++;
      if(y==1) m_wins++;
      if(m_v[idx].scored)
        {
         m_scoredN++;
         if((m_v[idx].prob>=0.5 ? 1 : 0)==y) m_correct++;
        }
      if(m_v[idx].allowed) { m_allowedN++; if(y==1) m_allowedWins++; }
      else                 { m_blockedN++; if(y==1) m_blockedWins++; }

      if(m_csv!=INVALID_HANDLE)
        {
         FileWrite(m_csv,TimeToString(m_v[idx].opened,TIME_DATE|TIME_MINUTES),m_v[idx].dir,
                   DoubleToString(m_v[idx].prob,4),(int)m_v[idx].allowed,DoubleToString(m_v[idx].be,4),
                   m_v[idx].x[0],m_v[idx].x[1],m_v[idx].x[2],m_v[idx].x[3],m_v[idx].x[4],m_v[idx].x[5],
                   m_v[idx].x[6],m_v[idx].x[7],m_v[idx].x[8],m_v[idx].x[9],m_v[idx].x[10],m_v[idx].x[11],y);
        }
      //--- 從陣列移除
      int n=ArraySize(m_v);
      for(int j=idx;j<n-1;j++)
         m_v[j]=m_v[j+1];
      ArrayResize(m_v,n-1);
     }

public:
                     CBQMLFilter():m_mode(BQML_OFF),m_csv(INVALID_HANDLE),m_lastProb(0.5),m_lastBE(0.5) {}

   bool              Init(const string eaName,const string sym,const ENUM_TIMEFRAMES tf,const long magic,
                          const ENUM_BQML_MODE mode,const double threshold,const int minSamples,
                          const double barrierTP,const double barrierSL,const int maxBars,
                          const bool load,const bool save,const bool exportCsv,const bool scaleLots)
     {
      m_mode=mode;
      m_thr=threshold;
      m_minSamples=minSamples;
      m_bTP=barrierTP;
      m_bSL=barrierSL;
      m_maxBars=(maxBars>0 ? maxBars : 48);
      m_scale=scaleLots;
      m_sym=sym;
      m_tf=tf;
      m_sigBar[0]=0; m_sigBar[1]=0;
      m_sigDecision[0]=true; m_sigDecision[1]=true;
      m_signals=m_allowed=m_blocked=m_resolved=m_wins=m_scoredN=m_correct=0;
      m_allowedWins=m_allowedN=m_blockedWins=m_blockedN=0;
      ArrayResize(m_v,0);
      m_model.Reset();
      if(m_mode==BQML_OFF)
         return(true);

      bool opt=(MQLInfoInteger(MQL_OPTIMIZATION)!=0);
      m_save=(save && !opt);        // 最佳化時多個 agent 同時寫檔會互相覆蓋
      m_file=StringFormat("%s\\%s_%s_%s_%I64d.model",BQML_DIR,eaName,sym,EnumToString(tf),magic);
      StringReplace(m_file,"PERIOD_","");
      m_feat.Init(sym,tf);

      if(load && m_model.Load(m_file))
         PrintFormat("[%s] BQ_ML: 已載入模型 %s (已學習 %I64d 筆)",m_sym,m_file,m_model.updates);
      else
         PrintFormat("[%s] BQ_ML: 使用新模型，前 %d 個訊號不過濾 (暖機)",m_sym,m_minSamples);

      m_csv=INVALID_HANDLE;
      if(exportCsv && !opt)
        {
         FolderCreate(BQML_DIR,FILE_COMMON);
         string cf=StringFormat("%s\\%s_%s_%s_%I64d_%s.csv",BQML_DIR,eaName,sym,EnumToString(tf),magic,
                                (MQLInfoInteger(MQL_TESTER) ? "tester" : "live"));
         StringReplace(cf,"PERIOD_","");
         m_csv=FileOpen(cf,FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',');
         if(m_csv!=INVALID_HANDLE)
           {
            FileWrite(m_csv,"time","dir","prob","allowed","be",BQML_FeatureName(0),BQML_FeatureName(1),BQML_FeatureName(2),
                      BQML_FeatureName(3),BQML_FeatureName(4),BQML_FeatureName(5),BQML_FeatureName(6),
                      BQML_FeatureName(7),BQML_FeatureName(8),BQML_FeatureName(9),BQML_FeatureName(10),
                      BQML_FeatureName(11),"label");
            PrintFormat("[%s] BQ_ML: 訓練資料輸出至 Common\\Files\\%s",m_sym,cf);
           }
        }
      return(true);
     }

   bool              Enabled() const { return(m_mode!=BQML_OFF); }

   //+---------------------------------------------------------------+
   //| 進場前詢問：dir=1 多單 / -1 空單                                  |
   //| slDist/tpDist：EA 本身的停損/停利距離(價格單位)，0 表示沒有        |
   //| 同一根K棒同方向重複詢問，回傳第一次的結果，不重複建立虛擬單         |
   //+---------------------------------------------------------------+
   bool              Allow(const int dir,const double slDist=0.0,const double tpDist=0.0)
     {
      if(m_mode==BQML_OFF) return(true);
      int k=(dir>0 ? 0 : 1);
      datetime bar=iTime(m_sym,m_tf,0);
      if(bar!=0 && m_sigBar[k]==bar)
         return(m_sigDecision[k]);

      double x[];
      if(!m_feat.Build(dir,x))
         return(true);                  // 資料不足時不擋單

      bool warm=(m_model.updates>=m_minSamples);
      double p=(m_model.updates>0 ? m_model.Predict(x) : 0.5);

      //--- 虛擬單的停利/停損距離 (標記用)
      double atr=m_feat.ATR();
      if(!BQ_Ok(atr) || atr<=0) atr=SymbolInfoDouble(m_sym,SYMBOL_POINT)*100;
      double tpD=(m_bTP>0 ? m_bTP*atr : (tpDist>0 ? tpDist : 2.0*atr));
      double slD=(m_bSL>0 ? m_bSL*atr : (slDist>0 ? slDist : 1.0*atr));
      double entry=(dir>0 ? SymbolInfoDouble(m_sym,SYMBOL_ASK) : SymbolInfoDouble(m_sym,SYMBOL_BID));

      //--- 損益兩平勝率：停利 3 倍停損時只要 25% 勝率就打平
      //    門檻 = 兩平勝率 + 優勢(edge)，讓不同盈虧比的策略都能用同一套設定
      double be=slD/(slD+tpD);
      bool ok=true;
      if(m_mode==BQML_FILTER && warm)
         ok=(p>=be+m_thr);

      int n=ArraySize(m_v);
      if(n>=BQML_MAXVIRT)
        {
         //--- 超過上限時以目前損益標記最舊的一筆
         double px=(m_v[0].dir>0 ? SymbolInfoDouble(m_sym,SYMBOL_BID) : SymbolInfoDouble(m_sym,SYMBOL_ASK));
         Resolve(0,((px-m_v[0].entry)*m_v[0].dir>0 ? 1 : 0));
         n=ArraySize(m_v);
        }
      ArrayResize(m_v,n+1);
      m_v[n].dir=(dir>0 ? 1 : -1);
      m_v[n].entry=entry;
      m_v[n].tp=entry+m_v[n].dir*tpD;
      m_v[n].sl=entry-m_v[n].dir*slD;
      m_v[n].opened=TimeCurrent();
      m_v[n].lastBar=bar;
      m_v[n].barsLeft=m_maxBars;
      m_v[n].prob=p;
      m_v[n].be=be;
      m_v[n].scored=warm;
      m_v[n].allowed=ok;
      for(int i=0;i<BQML_NF;i++) m_v[n].x[i]=x[i];

      m_signals++;
      if(ok) m_allowed++; else m_blocked++;
      m_lastProb=p;
      m_lastBE=be;
      m_sigBar[k]=bar;
      m_sigDecision[k]=ok;
      if(!ok && !MQLInfoInteger(MQL_OPTIMIZATION))
         PrintFormat("[%s] BQ_ML: 擋掉%s訊號 預估勝率 %.3f < 兩平 %.3f + 優勢 %.2f",m_sym,(dir>0 ? "多單" : "空單"),p,be,m_thr);
      return(ok);
     }

   // 依「預估勝率 - 兩平勝率」調整手數 (0.5 ~ 1.5 倍)，未啟用時回傳 1
   double            LotFactor() const
     {
      if(!m_scale || m_mode!=BQML_FILTER || m_model.updates<m_minSamples) return(1.0);
      double f=1.0+(m_lastProb-m_lastBE)*2.0;
      if(f<0.5) f=0.5;
      if(f>1.5) f=1.5;
      return(f);
     }

   double            LastProb() const { return(m_lastProb); }

   //--- 每個 tick 呼叫：推進虛擬單並學習
   void              OnTick()
     {
      if(m_mode==BQML_OFF) return;
      int n=ArraySize(m_v);
      if(n==0) return;
      double bid=SymbolInfoDouble(m_sym,SYMBOL_BID);
      double ask=SymbolInfoDouble(m_sym,SYMBOL_ASK);
      datetime bar=iTime(m_sym,m_tf,0);
      for(int i=n-1;i>=0;i--)
        {
         double px=(m_v[i].dir>0 ? bid : ask);
         int y=-1;
         if(m_v[i].dir>0)
           {
            if(px>=m_v[i].tp) y=1;
            else if(px<=m_v[i].sl) y=0;
           }
         else
           {
            if(px<=m_v[i].tp) y=1;
            else if(px>=m_v[i].sl) y=0;
           }
         if(y<0 && bar!=0 && bar!=m_v[i].lastBar)
           {
            m_v[i].lastBar=bar;
            m_v[i].barsLeft--;
            if(m_v[i].barsLeft<=0)
               y=((px-m_v[i].entry)*m_v[i].dir>0 ? 1 : 0);   // 逾時：以損益正負標記
           }
         if(y>=0)
            Resolve(i,y);
        }
     }

   string            Status() const
     {
      if(m_mode==BQML_OFF) return("ML: 關閉");
      return(StringFormat("ML: %s  已學習 %I64d  訊號 %d  放行 %d  擋掉 %d  最近機率 %.3f",
                          (m_mode==BQML_FILTER ? "過濾" : "學習"),m_model.updates,m_signals,m_allowed,m_blocked,m_lastProb));
     }

   void              Deinit()
     {
      if(m_mode==BQML_OFF) return;
      if(m_save && m_model.updates>0)
        {
         if(m_model.Save(m_file))
            PrintFormat("[%s] BQ_ML: 模型已儲存 Common\\Files\\%s",m_sym,m_file);
        }
      if(m_csv!=INVALID_HANDLE)
        {
         FileClose(m_csv);
         m_csv=INVALID_HANDLE;
        }
      if(!MQLInfoInteger(MQL_OPTIMIZATION))
        {
         PrintFormat("[%s] BQ_ML 統計: 訊號 %d | 放行 %d | 擋掉 %d | 已標記 %d (勝 %d, %.1f%%)",m_sym,
                     m_signals,m_allowed,m_blocked,m_resolved,m_wins,
                     (m_resolved>0 ? 100.0*m_wins/m_resolved : 0.0));
         if(m_allowedN>0 || m_blockedN>0)
            PrintFormat("[%s] BQ_ML 過濾效果: 放行單勝率 %.1f%% (%d 筆) vs 擋掉單勝率 %.1f%% (%d 筆)",m_sym,
                        (m_allowedN>0 ? 100.0*m_allowedWins/m_allowedN : 0.0),m_allowedN,
                        (m_blockedN>0 ? 100.0*m_blockedWins/m_blockedN : 0.0),m_blockedN);
         if(m_scoredN>0)
            PrintFormat("[%s] BQ_ML 暖機後預測準確率: %.1f%% (%d 筆)",m_sym,100.0*m_correct/m_scoredN,m_scoredN);
         for(int i=0;i<BQML_NF;i++)
            PrintFormat("[%s] BQ_ML 權重 %-16s %+.4f",m_sym,BQML_FeatureName(i),m_model.w[i]);
        }
     }
  };

#endif
//+------------------------------------------------------------------+
