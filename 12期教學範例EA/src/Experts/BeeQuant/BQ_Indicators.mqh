//+------------------------------------------------------------------+
//|  BQ_Indicators.mqh                                               |
//|  取代 cash.mqh / cash_v2.mqh 的指標取值函式                        |
//|                                                                  |
//|  舊版 cash.mqh 每呼叫一次 cc.iATR()/cc.iMA() 就建立一個指標 handle，|
//|  從不釋放，且建立後立即 CopyBuffer 常常取不到值(回傳 EMPTY_VALUE)，|
//|  EA 仍拿去計算造成錯誤訊號。這裡改成：                             |
//|    1. handle 快取：同參數只建立一次，OnDeinit 統一釋放              |
//|    2. 取值失敗回傳 EMPTY_VALUE，EA 用 BQ_Ok() 檢查後再使用         |
//+------------------------------------------------------------------+
#ifndef BQ_INDICATORS_MQH
#define BQ_INDICATORS_MQH

//--- 指標 handle 快取
class CBQHandleCache
  {
private:
   string            m_keys[];
   int               m_handles[];
public:
   int               Find(const string key)
     {
      int n=ArraySize(m_keys);
      for(int i=0;i<n;i++)
         if(m_keys[i]==key)
            return(m_handles[i]);
      return(INVALID_HANDLE);
     }
   void              Add(const string key,const int handle)
     {
      int n=ArraySize(m_keys);
      ArrayResize(m_keys,n+1);
      ArrayResize(m_handles,n+1);
      m_keys[n]=key;
      m_handles[n]=handle;
     }
   void              ReleaseAll()
     {
      int n=ArraySize(m_handles);
      for(int i=0;i<n;i++)
         if(m_handles[i]!=INVALID_HANDLE)
            IndicatorRelease(m_handles[i]);
      ArrayResize(m_keys,0);
      ArrayResize(m_handles,0);
     }
  };

CBQHandleCache g_bqHandles;

void BQ_ReleaseIndicators() { g_bqHandles.ReleaseAll(); }

bool BQ_Ok(const double v) { return(v!=EMPTY_VALUE && MathIsValidNumber(v)); }

double BQ_Buffer(const int handle,const int buffer,const int shift)
  {
   if(handle==INVALID_HANDLE || shift<0)
      return(EMPTY_VALUE);
   double b[1];
   if(CopyBuffer(handle,buffer,shift,1,b)!=1)
      return(EMPTY_VALUE);
   return(b[0]);
  }

//--- 共用：建立或取回 handle
int BQ__Remember(const string key,const int h)
  {
   if(h!=INVALID_HANDLE)
      g_bqHandles.Add(key,h);
   else
      PrintFormat("BQ_Indicators: 建立指標失敗 %s err=%d",key,GetLastError());
   return(h);
  }

int BQ_hATR(const string s,const ENUM_TIMEFRAMES tf,const int period)
  {
   string k=StringFormat("ATR|%s|%d|%d",s,(int)tf,period);
   int h=g_bqHandles.Find(k);
   if(h!=INVALID_HANDLE) return(h);
   return(BQ__Remember(k,iATR(s,tf,period)));
  }

int BQ_hMA(const string s,const ENUM_TIMEFRAMES tf,const int period,const int maShift,
           const ENUM_MA_METHOD method,const ENUM_APPLIED_PRICE price)
  {
   string k=StringFormat("MA|%s|%d|%d|%d|%d|%d",s,(int)tf,period,maShift,(int)method,(int)price);
   int h=g_bqHandles.Find(k);
   if(h!=INVALID_HANDLE) return(h);
   return(BQ__Remember(k,iMA(s,tf,period,maShift,method,price)));
  }

int BQ_hRSI(const string s,const ENUM_TIMEFRAMES tf,const int period,const ENUM_APPLIED_PRICE price)
  {
   string k=StringFormat("RSI|%s|%d|%d|%d",s,(int)tf,period,(int)price);
   int h=g_bqHandles.Find(k);
   if(h!=INVALID_HANDLE) return(h);
   return(BQ__Remember(k,iRSI(s,tf,period,price)));
  }

int BQ_hMACD(const string s,const ENUM_TIMEFRAMES tf,const int fast,const int slow,const int sig,
             const ENUM_APPLIED_PRICE price)
  {
   string k=StringFormat("MACD|%s|%d|%d|%d|%d|%d",s,(int)tf,fast,slow,sig,(int)price);
   int h=g_bqHandles.Find(k);
   if(h!=INVALID_HANDLE) return(h);
   return(BQ__Remember(k,iMACD(s,tf,fast,slow,sig,price)));
  }

int BQ_hBands(const string s,const ENUM_TIMEFRAMES tf,const int period,const int bShift,
              const double dev,const ENUM_APPLIED_PRICE price)
  {
   string k=StringFormat("BB|%s|%d|%d|%d|%.4f|%d",s,(int)tf,period,bShift,dev,(int)price);
   int h=g_bqHandles.Find(k);
   if(h!=INVALID_HANDLE) return(h);
   return(BQ__Remember(k,iBands(s,tf,period,bShift,dev,price)));
  }

int BQ_hADX(const string s,const ENUM_TIMEFRAMES tf,const int period)
  {
   string k=StringFormat("ADX|%s|%d|%d",s,(int)tf,period);
   int h=g_bqHandles.Find(k);
   if(h!=INVALID_HANDLE) return(h);
   return(BQ__Remember(k,iADX(s,tf,period)));
  }

int BQ_hWPR(const string s,const ENUM_TIMEFRAMES tf,const int period)
  {
   string k=StringFormat("WPR|%s|%d|%d",s,(int)tf,period);
   int h=g_bqHandles.Find(k);
   if(h!=INVALID_HANDLE) return(h);
   return(BQ__Remember(k,iWPR(s,tf,period)));
  }

//--- 取值函式 (shift=0 為目前K棒, 1 為上一根已收盤K棒)
double BQ_ATR(const string s,const ENUM_TIMEFRAMES tf,const int period,const int shift)
  { return(BQ_Buffer(BQ_hATR(s,tf,period),0,shift)); }

double BQ_MA(const string s,const ENUM_TIMEFRAMES tf,const int period,const int maShift,
             const ENUM_MA_METHOD method,const ENUM_APPLIED_PRICE price,const int shift)
  { return(BQ_Buffer(BQ_hMA(s,tf,period,maShift,method,price),0,shift)); }

double BQ_RSI(const string s,const ENUM_TIMEFRAMES tf,const int period,const ENUM_APPLIED_PRICE price,const int shift)
  { return(BQ_Buffer(BQ_hRSI(s,tf,period,price),0,shift)); }

// buffer: 0=MAIN 1=SIGNAL
double BQ_MACD(const string s,const ENUM_TIMEFRAMES tf,const int fast,const int slow,const int sig,
               const ENUM_APPLIED_PRICE price,const int buffer,const int shift)
  { return(BQ_Buffer(BQ_hMACD(s,tf,fast,slow,sig,price),buffer,shift)); }

// buffer: 0=BASE(中軌) 1=UPPER 2=LOWER
double BQ_Bands(const string s,const ENUM_TIMEFRAMES tf,const int period,const double dev,
                const ENUM_APPLIED_PRICE price,const int buffer,const int shift)
  { return(BQ_Buffer(BQ_hBands(s,tf,period,0,dev,price),buffer,shift)); }

// buffer: 0=ADX 1=+DI 2=-DI
double BQ_ADX(const string s,const ENUM_TIMEFRAMES tf,const int period,const int buffer,const int shift)
  { return(BQ_Buffer(BQ_hADX(s,tf,period),buffer,shift)); }

double BQ_WPR(const string s,const ENUM_TIMEFRAMES tf,const int period,const int shift)
  { return(BQ_Buffer(BQ_hWPR(s,tf,period),0,shift)); }

//--- 區間最高/最低 (shift 起算, count 根)
double BQ_Highest(const string s,const ENUM_TIMEFRAMES tf,const int count,const int start)
  {
   if(count<=0) return(EMPTY_VALUE);
   double a[];
   if(CopyHigh(s,tf,start,count,a)!=count) return(EMPTY_VALUE);
   return(a[ArrayMaximum(a,0,count)]);
  }

double BQ_Lowest(const string s,const ENUM_TIMEFRAMES tf,const int count,const int start)
  {
   if(count<=0) return(EMPTY_VALUE);
   double a[];
   if(CopyLow(s,tf,start,count,a)!=count) return(EMPTY_VALUE);
   return(a[ArrayMinimum(a,0,count)]);
  }

//--- 某時間之後的最高價/最低價 (追蹤停損用)
double BQ_HighSince(const string s,const ENUM_TIMEFRAMES tf,const datetime from)
  {
   double a[];
   int n=CopyHigh(s,tf,from,TimeCurrent(),a);
   if(n<=0) return(EMPTY_VALUE);
   return(a[ArrayMaximum(a,0,n)]);
  }

double BQ_LowSince(const string s,const ENUM_TIMEFRAMES tf,const datetime from)
  {
   double a[];
   int n=CopyLow(s,tf,from,TimeCurrent(),a);
   if(n<=0) return(EMPTY_VALUE);
   return(a[ArrayMinimum(a,0,n)]);
  }

//+------------------------------------------------------------------+
//| 新K棒偵測 (取代 避免同根重複下單 = iBars 的寫法)                   |
//+------------------------------------------------------------------+
class CBQBarGuard
  {
private:
   datetime          m_mark;
public:
                     CBQBarGuard():m_mark(0) {}
   // 這一根K棒是否已經做過動作
   bool              Done(const string s,const ENUM_TIMEFRAMES tf) const { return(m_mark!=0 && m_mark==iTime(s,tf,0)); }
   void              Mark(const string s,const ENUM_TIMEFRAMES tf)       { m_mark=iTime(s,tf,0); }
   void              Reset()                                             { m_mark=0; }
  };

class CBQNewBar
  {
private:
   datetime          m_last;
public:
                     CBQNewBar():m_last(0) {}
   bool              Check(const string s,const ENUM_TIMEFRAMES tf)
     {
      datetime t=iTime(s,tf,0);
      if(t==0) return(false);
      if(t!=m_last) { m_last=t; return(true); }
      return(false);
     }
  };

//+------------------------------------------------------------------+
//| 每日下單次數計數器                                                 |
//| 舊寫法「在 6:00~6:05 之間有報價才歸零」，若該時段沒有 tick 就不會   |
//| 歸零。這裡以「交易日」切換判斷，保證每天歸零一次。                 |
//+------------------------------------------------------------------+
class CBQDailyCounter
  {
private:
   int               m_key;
   int               m_count;
   int               m_resetHour;
   void              Update()
     {
      MqlDateTime d;
      TimeToStruct(TimeCurrent()-(datetime)(m_resetHour*3600),d);
      int key=d.year*1000+d.day_of_year;
      if(key!=m_key) { m_key=key; m_count=0; }
     }
public:
                     CBQDailyCounter():m_key(-1),m_count(0),m_resetHour(0) {}
   void              Init(const int resetHour) { m_resetHour=resetHour; m_key=-1; m_count=0; }
   int               Count() { Update(); return(m_count); }
   void              Inc()   { Update(); m_count++; }
  };

//--- 時間小工具 (伺服器時間)
int BQ_Hour()      { MqlDateTime t; TimeToStruct(TimeCurrent(),t); return(t.hour); }
int BQ_Minute()    { MqlDateTime t; TimeToStruct(TimeCurrent(),t); return(t.min); }
int BQ_DayOfWeek() { MqlDateTime t; TimeToStruct(TimeCurrent(),t); return(t.day_of_week); }

//--- 回測最佳化自訂分數：淨利 / 最大淨值回撤 (Recovery Factor)
double BQ_TesterScore()
  {
   double profit=TesterStatistics(STAT_PROFIT);
   double dd=TesterStatistics(STAT_EQUITY_DD);
   double trades=TesterStatistics(STAT_TRADES);
   if(trades<10) return(0.0);
   if(dd<=0) return(profit);
   return(profit/dd);
  }

//--- 圖表資訊 (取代每個 tick 重建十幾個 OBJ_LABEL 的寫法)
void BQ_Panel(const string text)
  {
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   static uint last=0;
   uint now=GetTickCount();
   if(now-last<500) return;
   last=now;
   Comment(text);
  }

#endif
//+------------------------------------------------------------------+
