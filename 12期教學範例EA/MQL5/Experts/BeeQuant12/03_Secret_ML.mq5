//  ※ 本檔由 tools/build_single.py 自動產生 (已內嵌 BeeQuant 函式庫)，
//    可直接放在 MQL5\Experts\ 任何位置編譯；要修改請改 src/ 後重新產生。
//+------------------------------------------------------------------+
//| 03_Secret_ML.mq5 — 第三期 EA-Secret 修正優化 + 機器學習             |
//|   整合 Tester-Secret v6.0 Input (自訂參數) 與 Live-Secret v7.0       |
//|   (內建 36 組商品參數表)；以 InpParamMode 切換                       |
//|                                                                  |
//| 策略邏輯 (與原版相同)：                                            |
//|   以每日 T 點 (預設 06:00) 為日界，取前 24 根 H1 的高低點 HH/LL      |
//|   D1 MACD 在 0 軸下方且主線>訊號線 → 在 HH 掛 BuyStop               |
//|   D1 MACD 在 0 軸上方且主線<訊號線 → 在 LL 掛 SellStop              |
//|   TYPE 1：昨日收紅才做多/收黑才做空；TYPE 2 相反；TYPE 3 不看        |
//|   停損 = 區間另一端，停利 = 2 倍區間；到 1R 時平一半並移到保本       |
//|                                                                  |
//| 修正：                                                            |
//|   * 「進場價到停損價距離」同時掃多空單，只回傳最後一張 → 多空分開算   |
//|   * 多單出場條件函式體是空的 (沒有平倉動作) → 移除                   |
//|   * 手數硬湊偶數 (0.03→0.04…) 以便平半 → 改成對齊交易量步進          |
//|     並保證至少 2 倍最小手數；平半量不足最小手數時只移保本            |
//|   * 空單掛單刪除時沒檢查 T 點，與多單不一致 → 統一                   |
//|   * MagicNumber 在每個 tick 重新計算 → OnInit 算一次                 |
//|   * 回測用 v6 固定 10000 本金計算手數 → 可選 (InpRiskBase)           |
//+------------------------------------------------------------------+
//| ★ 掛在任何圖表皆可：依 InpSymbols / InpBaseTF 交易 (預設=原版商品與週期) |
//+------------------------------------------------------------------+
#property copyright "所有EA皆為教學範例，不保證未來獲利，任何參數請自行回測研究後再使用"
#property link      "https://beequant.soci.vip/"
#property version   "2.00"

//==================== 內嵌函式庫：BQ_Trade.mqh ====================
//+------------------------------------------------------------------+
//|  BQ_Trade.mqh                                                    |
//|  下單 / 平倉 / 改單 / 手數計算 共用函式庫                            |
//|                                                                  |
//|  修正原教學範例常見問題：                                          |
//|   * OrderSend 只檢查 bool，沒檢查 retcode，失敗也當成功              |
//|   * 未設定成交模式 (filling)，部分券商下單直接被拒                  |
//|   * 手數只 NormalizeDouble(x,2)，沒對齊 volume_step/min/max          |
//|   * 風險手數公式假設 tick size = point，貴金屬/指數算錯              |
//|   * 停損停利沒檢查 STOPS_LEVEL，被券商拒單                          |
//|   * 改單時沒帶入原本的 TP，追蹤停損一改 TP 就不見了                  |
//|   * 分批平倉 volume/2 沒對齊 step，0.01 手的單會出錯                 |
//|  買單 magic = magicBuy，賣單 magic = magicSell (沿用原本 +77 規則)   |
//+------------------------------------------------------------------+
#ifndef BQ_TRADE_MQH
#define BQ_TRADE_MQH

#include <Trade\Trade.mqh>

class CBQTrade
  {
private:
   CTrade            m_trade;
   string            m_sym;
   long              m_magicBuy;
   long              m_magicSell;
   int               m_dev;

   bool              IsMine(const long type,const long magic) const
     {
      if(type==POSITION_TYPE_BUY)  return(magic==m_magicBuy);
      if(type==POSITION_TYPE_SELL) return(magic==m_magicSell);
      return(false);
     }
   bool              ResultOK(const string what)
     {
      uint rc=m_trade.ResultRetcode();
      if(rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED || rc==TRADE_RETCODE_DONE_PARTIAL)
         return(true);
      PrintFormat("[%s] %s 失敗 retcode=%u %s",m_sym,what,rc,m_trade.ResultRetcodeDescription());
      return(false);
     }
   bool              Retryable() const
     {
      uint rc=m_trade.ResultRetcode();
      return(rc==TRADE_RETCODE_REQUOTE || rc==TRADE_RETCODE_PRICE_CHANGED ||
             rc==TRADE_RETCODE_PRICE_OFF || rc==TRADE_RETCODE_TIMEOUT);
     }

public:
                     CBQTrade():m_sym(""),m_magicBuy(0),m_magicSell(0),m_dev(30) {}

   void              Init(const string sym,const long magicBuy,const long magicSell,const int deviationPoints)
     {
      m_sym=sym;
      m_magicBuy=magicBuy;
      m_magicSell=magicSell;
      m_dev=deviationPoints;
      m_trade.SetDeviationInPoints(deviationPoints);
      m_trade.SetTypeFillingBySymbol(sym);
      m_trade.SetMarginMode();
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
      m_trade.SetAsyncMode(false);
     }

   long              MagicBuy()  const { return(m_magicBuy); }
   long              MagicSell() const { return(m_magicSell); }
   string            Sym()       const { return(m_sym); }

   //--- 報價
   double            Ask()    const { return(SymbolInfoDouble(m_sym,SYMBOL_ASK)); }
   double            Bid()    const { return(SymbolInfoDouble(m_sym,SYMBOL_BID)); }
   double            Pt()     const { return(SymbolInfoDouble(m_sym,SYMBOL_POINT)); }
   int               Dig()    const { return((int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS)); }
   int               SpreadPoints() const { return((int)SymbolInfoInteger(m_sym,SYMBOL_SPREAD)); }
   bool              SpreadOK(const int maxPoints) const { return(maxPoints<=0 || SpreadPoints()<=maxPoints); }

   double            NormPrice(const double p) const
     {
      double ts=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
      if(ts<=0) return(NormalizeDouble(p,Dig()));
      return(NormalizeDouble(MathRound(p/ts)*ts,Dig()));
     }

   //--- 手數
   int               VolDigits() const
     {
      double step=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
      int d=0;
      while(step>0 && step<1.0-1e-9 && d<8) { step*=10.0; d++; }
      return(d);
     }
   double            MinLot() const { return(SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN)); }

   double            NormLots(double lots) const
     {
      double step=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
      double mn  =SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
      double mx  =SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);
      if(step<=0) step=0.01;
      lots=MathFloor(lots/step+1e-7)*step;
      if(lots<mn) lots=mn;
      if(mx>0 && lots>mx) lots=mx;
      return(NormalizeDouble(lots,VolDigits()));
     }

   // 1 手在價格移動 dist 時的虧損金額 (帳戶幣別)
   double            LossPerLot(const double dist) const
     {
      double ts=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
      double tv=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv<=0) tv=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
      if(ts<=0 || tv<=0) return(0.0);
      return(dist/ts*tv);
     }

   // autoLots=true 時：以 (本金 x 風險%) / 停損金額 計算手數
   // riskBase<=0 用帳戶餘額，>0 用固定本金(回測比較用)
   double            CalcLots(const bool autoLots,const double riskPct,const double slDist,
                              const double fixedLots,const double maxLots,const double riskBase=0.0) const
     {
      double lots=fixedLots;
      if(autoLots && slDist>0)
        {
         double base=(riskBase>0 ? riskBase : AccountInfoDouble(ACCOUNT_BALANCE));
         double lpl=LossPerLot(slDist);
         if(lpl>0)
            lots=base*riskPct/100.0/lpl;
        }
      if(maxLots>0 && lots>maxLots) lots=maxLots;
      return(NormLots(lots));
     }

   //--- 停損停利距離檢查
   double            MinStopDist() const
     {
      long lvl=SymbolInfoInteger(m_sym,SYMBOL_TRADE_STOPS_LEVEL);
      long frz=SymbolInfoInteger(m_sym,SYMBOL_TRADE_FREEZE_LEVEL);
      return((double)MathMax(lvl,frz)*Pt());
     }

   // 把太靠近的 SL/TP 推到券商允許的最小距離；ref=成交參考價
   void              FixStops(const bool isBuy,const double ref,double &sl,double &tp) const
     {
      double d=MinStopDist()+Pt();
      if(sl>0)
        {
         if(isBuy  && ref-sl<d) sl=ref-d;
         if(!isBuy && sl-ref<d) sl=ref+d;
         sl=NormPrice(sl);
        }
      if(tp>0)
        {
         if(isBuy  && tp-ref<d) tp=ref+d;
         if(!isBuy && ref-tp<d) tp=ref-d;
         tp=NormPrice(tp);
        }
     }

   bool              MarginOK(const ENUM_ORDER_TYPE type,const double lots,const double price) const
     {
      double m=0;
      if(!OrderCalcMargin(type,m_sym,lots,price,m))
         return(true); // 無法計算時不擋單，交給伺服器判斷
      if(m>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
        {
         PrintFormat("[%s] 保證金不足：需要 %.2f 可用 %.2f",m_sym,m,AccountInfoDouble(ACCOUNT_MARGIN_FREE));
         return(false);
        }
      return(true);
     }

   //--- 市價單
   bool              Buy(double lots,double sl,double tp,const string cmt)
     {
      lots=NormLots(lots);
      if(!MarginOK(ORDER_TYPE_BUY,lots,Ask())) return(false);
      m_trade.SetExpertMagicNumber(m_magicBuy);
      for(int attempt=0;attempt<3;attempt++)
        {
         double s=sl,t=tp;
         FixStops(true,Bid(),s,t);
         m_trade.Buy(lots,m_sym,0.0,s,t,cmt);
         if(ResultOK("Buy")) return(true);
         if(!Retryable()) break;
         Sleep(200);
        }
      return(false);
     }

   bool              Sell(double lots,double sl,double tp,const string cmt)
     {
      lots=NormLots(lots);
      if(!MarginOK(ORDER_TYPE_SELL,lots,Bid())) return(false);
      m_trade.SetExpertMagicNumber(m_magicSell);
      for(int attempt=0;attempt<3;attempt++)
        {
         double s=sl,t=tp;
         FixStops(false,Ask(),s,t);
         m_trade.Sell(lots,m_sym,0.0,s,t,cmt);
         if(ResultOK("Sell")) return(true);
         if(!Retryable()) break;
         Sleep(200);
        }
      return(false);
     }

   //--- 掛單 (價格不合法時回傳 false，不送單)
   bool              Pending(const ENUM_ORDER_TYPE type,double price,double lots,double sl,double tp,
                             const string cmt,const datetime expiration=0)
     {
      bool isBuy=(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_LIMIT);
      price=NormPrice(price);
      double d=MinStopDist()+Pt();
      double ask=Ask(),bid=Bid();
      if(type==ORDER_TYPE_BUY_STOP   && price<ask+d) return(false);
      if(type==ORDER_TYPE_BUY_LIMIT  && price>ask-d) return(false);
      if(type==ORDER_TYPE_SELL_STOP  && price>bid-d) return(false);
      if(type==ORDER_TYPE_SELL_LIMIT && price<bid+d) return(false);
      FixStops(isBuy,price,sl,tp);
      lots=NormLots(lots);
      m_trade.SetExpertMagicNumber(isBuy ? m_magicBuy : m_magicSell);
      ENUM_ORDER_TYPE_TIME tt=(expiration>0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC);
      m_trade.OrderOpen(m_sym,type,lots,0.0,price,sl,tp,tt,expiration,cmt);
      return(ResultOK("Pending"));
     }

   //--- 持倉查詢
   int               Count(const ENUM_POSITION_TYPE type) const
     {
      int c=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_sym) continue;
         long pt=PositionGetInteger(POSITION_TYPE);
         if(pt!=type) continue;
         if(IsMine(pt,PositionGetInteger(POSITION_MAGIC))) c++;
        }
      return(c);
     }
   int               CountBuy()  const { return(Count(POSITION_TYPE_BUY)); }
   int               CountSell() const { return(Count(POSITION_TYPE_SELL)); }
   int               CountAll()  const { return(CountBuy()+CountSell()); }

   // 選取該方向第一張單，成功後可用 PositionGetXXX 讀取
   ulong             Select(const ENUM_POSITION_TYPE type) const
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_sym) continue;
         long pt=PositionGetInteger(POSITION_TYPE);
         if(pt!=type) continue;
         if(IsMine(pt,PositionGetInteger(POSITION_MAGIC))) return(tk);
        }
      return(0);
     }
   double            OpenPrice(const ENUM_POSITION_TYPE type) const { return(Select(type)>0 ? PositionGetDouble(POSITION_PRICE_OPEN) : 0.0); }
   double            PosSL(const ENUM_POSITION_TYPE type)     const { return(Select(type)>0 ? PositionGetDouble(POSITION_SL) : 0.0); }
   double            PosTP(const ENUM_POSITION_TYPE type)     const { return(Select(type)>0 ? PositionGetDouble(POSITION_TP) : 0.0); }
   double            PosVolume(const ENUM_POSITION_TYPE type) const { return(Select(type)>0 ? PositionGetDouble(POSITION_VOLUME) : 0.0); }
   datetime          OpenTime(const ENUM_POSITION_TYPE type)  const { return(Select(type)>0 ? (datetime)PositionGetInteger(POSITION_TIME) : 0); }

   //--- 平倉
   void              Close(const ENUM_POSITION_TYPE type)
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_sym) continue;
         long pt=PositionGetInteger(POSITION_TYPE);
         if(pt!=type) continue;
         if(!IsMine(pt,PositionGetInteger(POSITION_MAGIC))) continue;
         m_trade.SetExpertMagicNumber(PositionGetInteger(POSITION_MAGIC));
         m_trade.PositionClose(tk,m_dev);
         ResultOK("Close");
        }
     }
   void              CloseBuy()  { Close(POSITION_TYPE_BUY); }
   void              CloseSell() { Close(POSITION_TYPE_SELL); }
   void              CloseAll()  { Close(POSITION_TYPE_BUY); Close(POSITION_TYPE_SELL); }

   // 部分平倉 fraction(0~1)；平掉的量對齊 volume_step，不足最小手數則不動作
   bool              ClosePartial(const ENUM_POSITION_TYPE type,const double fraction)
     {
      bool any=false;
      double step=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
      double mn=MinLot();
      if(step<=0) step=0.01;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_sym) continue;
         long pt=PositionGetInteger(POSITION_TYPE);
         if(pt!=type) continue;
         if(!IsMine(pt,PositionGetInteger(POSITION_MAGIC))) continue;
         double vol=PositionGetDouble(POSITION_VOLUME);
         double part=MathFloor(vol*fraction/step+1e-7)*step;
         part=NormalizeDouble(part,VolDigits());
         if(part<mn || vol-part<mn-1e-9) continue;
         m_trade.SetExpertMagicNumber(PositionGetInteger(POSITION_MAGIC));
         m_trade.PositionClosePartial(tk,part,m_dev);
         if(ResultOK("ClosePartial")) any=true;
        }
      return(any);
     }

   // 修改停損 (保留原 TP)；onlyImprove=true 時只往有利方向移動
   bool              ModifySL(const ENUM_POSITION_TYPE type,double newSL,const bool onlyImprove=true)
     {
      bool any=false;
      newSL=NormPrice(newSL);
      double d=MinStopDist()+Pt();
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_sym) continue;
         long pt=PositionGetInteger(POSITION_TYPE);
         if(pt!=type) continue;
         if(!IsMine(pt,PositionGetInteger(POSITION_MAGIC))) continue;
         double cur=PositionGetDouble(POSITION_SL);
         double tp =PositionGetDouble(POSITION_TP);
         if(MathAbs(newSL-cur)<Pt()*0.5) continue;
         if(onlyImprove && cur>0)
           {
            if(pt==POSITION_TYPE_BUY  && newSL<=cur) continue;
            if(pt==POSITION_TYPE_SELL && newSL>=cur) continue;
           }
         if(pt==POSITION_TYPE_BUY  && Bid()-newSL<d) continue;
         if(pt==POSITION_TYPE_SELL && newSL-Ask()<d) continue;
         m_trade.SetExpertMagicNumber(PositionGetInteger(POSITION_MAGIC));
         m_trade.PositionModify(tk,newSL,tp);
         if(ResultOK("ModifySL")) any=true;
        }
      return(any);
     }

   //--- 掛單查詢/刪除 (buySide=true 為 BUY_STOP/BUY_LIMIT)
   int               PendingCount(const bool buySide) const
     {
      int c=0;
      for(int i=OrdersTotal()-1;i>=0;i--)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0) continue;
         if(OrderGetString(ORDER_SYMBOL)!=m_sym) continue;
         long ot=OrderGetInteger(ORDER_TYPE);
         long mg=OrderGetInteger(ORDER_MAGIC);
         bool isBuy=(ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_BUY_LIMIT || ot==ORDER_TYPE_BUY_STOP_LIMIT);
         bool isSell=(ot==ORDER_TYPE_SELL_STOP || ot==ORDER_TYPE_SELL_LIMIT || ot==ORDER_TYPE_SELL_STOP_LIMIT);
         if(buySide && isBuy && mg==m_magicBuy) c++;
         if(!buySide && isSell && mg==m_magicSell) c++;
        }
      return(c);
     }

   void              DeletePending(const bool buySide)
     {
      for(int i=OrdersTotal()-1;i>=0;i--)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0) continue;
         if(OrderGetString(ORDER_SYMBOL)!=m_sym) continue;
         long ot=OrderGetInteger(ORDER_TYPE);
         long mg=OrderGetInteger(ORDER_MAGIC);
         bool isBuy=(ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_BUY_LIMIT || ot==ORDER_TYPE_BUY_STOP_LIMIT);
         bool isSell=(ot==ORDER_TYPE_SELL_STOP || ot==ORDER_TYPE_SELL_LIMIT || ot==ORDER_TYPE_SELL_STOP_LIMIT);
         if((buySide && isBuy && mg==m_magicBuy) || (!buySide && isSell && mg==m_magicSell))
           {
            m_trade.OrderDelete(tk);
            ResultOK("DeletePending");
           }
        }
     }
  };

#endif
//+------------------------------------------------------------------+

//==================== BQ_Trade.mqh 結束 ====================
//==================== 內嵌函式庫：BQ_Indicators.mqh ====================
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

//==================== BQ_Indicators.mqh 結束 ====================
//==================== 內嵌函式庫：BQ_Multi.mqh ====================
//+------------------------------------------------------------------+
//|  BQ_Multi.mqh — 多商品執行工具                                     |
//|  EA 掛在任何一張圖表都可以：交易商品與週期由參數決定，              |
//|  不再使用圖表的 _Symbol / _Period。                                |
//|   * BQ_ParseSymbols：解析「GBPJPY,EURJPY」清單，自動對應券商後綴    |
//|     (例如 GBPJPY → GBPJPY.m / GBPJPYpro)，並加入市場報價            |
//|   * 其他商品沒有 OnTick，所以 EA 另外用每秒 OnTimer 執行一次        |
//+------------------------------------------------------------------+
#ifndef BQ_MULTI_MQH
#define BQ_MULTI_MQH

//--- 策略週期：PERIOD_CURRENT = 圖表週期
ENUM_TIMEFRAMES BQ_TF(const ENUM_TIMEFRAMES tf)
  {
   return(tf==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : tf);
  }

//--- 找券商實際的商品名稱 (處理後綴 / 前綴)，找不到回傳 ""
string BQ_ResolveSymbol(string want)
  {
   StringTrimLeft(want);
   StringTrimRight(want);
   if(want=="") return("");
   string up=want;
   StringToUpper(up);
   if(up=="CHART" || up=="圖表") return(_Symbol);

   bool custom=false;
   if(SymbolExist(want,custom))
     {
      SymbolSelect(want,true);
      return(want);
     }
   //--- 圖表商品本身符合 (例如圖表是 GBPJPY.m)，優先使用
   string chart=_Symbol;
   StringToUpper(chart);
   if(StringFind(chart,up)==0) return(_Symbol);

   string best="";
   bool   bestSel=false;
   int total=SymbolsTotal(false);
   for(int i=0;i<total;i++)
     {
      string name=SymbolName(i,false);
      string u=name;
      StringToUpper(u);
      int pos=StringFind(u,up);
      if(pos<0) continue;
      if(pos>0 && pos>3) continue;                 // 只接受短前綴，例如 m.GBPJPY
      bool sel=(SymbolInfoInteger(name,SYMBOL_SELECT)!=0);
      //--- 優先：已在市場報價中 > 名稱較短
      if(best=="" || (sel && !bestSel) || (sel==bestSel && StringLen(name)<StringLen(best)))
        {
         best=name;
         bestSel=sel;
        }
     }
   if(best!="") SymbolSelect(best,true);
   return(best);
  }

//--- 解析商品清單 (逗號、分號、空白分隔)；清單為空 = 圖表商品
int BQ_ParseSymbols(const string list,string &out[])
  {
   ArrayResize(out,0);
   string s=list;
   StringReplace(s,";",",");
   StringReplace(s," ",",");
   StringReplace(s,"，",",");
   string parts[];
   int n=StringSplit(s,',',parts);
   for(int i=0;i<n;i++)
     {
      string raw=parts[i];
      StringTrimLeft(raw);
      StringTrimRight(raw);
      if(raw=="") continue;
      string name=BQ_ResolveSymbol(raw);
      if(name=="")
        {
         PrintFormat("商品 %s 在此券商找不到，略過",raw);
         continue;
        }
      bool dup=false;
      for(int j=0;j<ArraySize(out);j++)
         if(out[j]==name) { dup=true; break; }
      if(dup) continue;
      int k=ArraySize(out);
      ArrayResize(out,k+1);
      out[k]=name;
     }
   if(ArraySize(out)==0 && StringLen(list)==0)
     {
      ArrayResize(out,1);
      out[0]=_Symbol;
     }
   return(ArraySize(out));
  }

//--- 多商品面板：每個商品一行，避免超過 Comment 長度上限
string BQ_PanelLine(const string sym,string text)
  {
   StringReplace(text,"\n","  ");
   return(sym+" | "+text+"\n");
  }

void BQ_PanelMulti(const string title,string body)
  {
   if(StringLen(body)>1900)
      body=StringSubstr(body,0,1900)+"\n...";
   BQ_Panel(title+"\n"+body);
  }

#endif
//+------------------------------------------------------------------+

//==================== BQ_Multi.mqh 結束 ====================

enum ENUM_SECRET_PARAM
  {
   SECRET_INPUT = 0, // 使用下方自訂 TYPE / MACD 參數 (v6)
   SECRET_TABLE = 1  // 使用 v7 內建商品參數表
  };

input group "=== 交易商品 / 週期 (掛在任何圖表皆可) ==="
input string          InpSymbols = "AUDCAD,AUDCHF,AUDNZD,GBPJPY,NZDCHF,USDJPY,AUDJPY,EURJPY,EURCAD,AUDUSD,EURUSD,NZDCAD,GBPAUD,NZDJPY,GBPUSD"; // 交易商品 (逗號分隔；v7 參數表全部商品)
input ENUM_TIMEFRAMES InpBaseTF  = PERIOD_H1; // 策略週期 (原版圖表週期)

input group "=== 參數來源 ==="
input ENUM_SECRET_PARAM InpParamMode = SECRET_TABLE; // 參數來源
input string InpEAMagicNum = "0";   // EA 編號 (參數表模式 0=表中所有編號；也是 Magic 前綴)
input int    InpType       = 1;     // TYPE (自訂模式)
input int    InpFastEMA    = 12;    // MACD 快線 (自訂模式)
input int    InpSlowEMA    = 26;    // MACD 慢線 (自訂模式)
input int    InpSignal     = 9;     // MACD 訊號線 (自訂模式)

input group "=== 策略參數 ==="
input int    InpDayStart   = 6;     // 日界時間 T (伺服器時)
input bool   InpHalfClose  = true;  // 到 1R 平一半並移保本
input int    InpMaxTradesDay=2;     // 每日掛單次數上限
input ENUM_TIMEFRAMES InpMACDTF = PERIOD_D1; // MACD 週期

input group "=== 資金 / 風控 ==="
input double InpMinBalance = 5000;  // 餘額低於此值停止交易
input bool   InpAutoLots   = true;  // 自動計算手數
input double InpRiskPct    = 0.3;   // 每筆風險 %
input double InpRiskBase   = 0;     // 計算本金 (0=帳戶餘額, v6 回測用 10000)
input double InpLots       = 0.2;   // 固定手數
input double InpMaxLots    = 0.3;   // 手數上限
input int    InpMaxSpread  = 0;     // 最大點差 (點, 0=不限)
input int    InpSlippage   = 100;   // 滑價 (點)

//==================== 內嵌函式庫：BQ_MLInputs.mqh ====================
//+------------------------------------------------------------------+
//|  BQ_MLInputs.mqh — 所有 EA 共用的 ML 參數與全域過濾器物件            |
//|  EA 只要 (每個商品一個 CBQMLFilter 物件 ml)：                        |
//|     初始化   : BQML_Setup(ml,"EA名稱",商品,週期,magic);             |
//|     每個 tick: ml.OnTick();                                        |
//|     下單前   : if(!ml.Allow(方向, 停損距離, 停利距離)) 不下單       |
//|     結束     : ml.Deinit();                                        |
//+------------------------------------------------------------------+
#ifndef BQ_MLINPUTS_MQH
#define BQ_MLINPUTS_MQH

//==================== 內嵌函式庫：BQ_ML.mqh ====================
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

//==================== BQ_ML.mqh 結束 ====================

input group "=== 帳戶保護 ==="
input bool InpAllowReal   = false; // 允許在「真實帳戶」執行 (預設只在模擬帳戶執行)
input long InpLockAccount = 0;     // 只允許此帳號執行 (0=不限)

//--- MT5 切換登入帳號時，圖表上的 EA 會留著繼續跑到新帳號；
//    所以在 OnInit 檢查帳戶，不符合就不啟動 (EA 會自動從圖表移除)
bool BQ_AccountAllowed()
  {
   if(MQLInfoInteger(MQL_TESTER)) return(true);
   long login=AccountInfoInteger(ACCOUNT_LOGIN);
   ENUM_ACCOUNT_TRADE_MODE mode=(ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(InpLockAccount!=0 && login!=InpLockAccount)
     {
      PrintFormat("帳戶保護：目前帳號 %I64d 不是指定帳號 %I64d，EA 不啟動",login,InpLockAccount);
      return(false);
     }
   if(mode==ACCOUNT_TRADE_MODE_REAL && !InpAllowReal)
     {
      PrintFormat("帳戶保護：帳號 %I64d 是真實帳戶，InpAllowReal=false，EA 不啟動",login);
      Alert("EA 未啟動：這是真實帳戶 (要在真實帳戶執行請把 InpAllowReal 設為 true)");
      return(false);
     }
   return(true);
  }

input group "=== 機器學習 (ML) 訊號過濾 ==="
input ENUM_BQML_MODE  InpMLMode       = BQML_FILTER;    // ML 模式
input double          InpMLThreshold  = 0.03;           // 放行門檻：預估勝率需高於兩平勝率多少
input int             InpMLMinSamples = 40;             // 暖機樣本數 (之前不過濾)
input double          InpMLBarrierTP  = 0;              // 標記用停利 ATR 倍數 (0=用 EA 停利)
input double          InpMLBarrierSL  = 0;              // 標記用停損 ATR 倍數 (0=用 EA 停損)
input int             InpMLMaxBars    = 48;             // 標記最長追蹤 K 棒數
input bool            InpMLLoadModel  = true;           // 啟動時載入已存模型
input bool            InpMLSaveModel  = true;           // 結束時儲存模型
input bool            InpMLExportCSV  = false;          // 匯出訓練資料 CSV
input bool            InpMLScaleLots  = false;          // 依預估勝率調整手數 (0.5~1.5倍)
input ENUM_TIMEFRAMES InpMLTimeframe  = PERIOD_CURRENT; // 特徵計算週期

//--- 每個商品各自一個過濾器 (模型檔名含商品/週期/magic，互不干擾)
//    baseTF = 該商品的策略週期；InpMLTimeframe=目前週期 時用 baseTF
bool BQML_Setup(CBQMLFilter &f,const string eaName,const string sym,const ENUM_TIMEFRAMES baseTF,const long magic)
  {
   ENUM_TIMEFRAMES tf=(InpMLTimeframe==PERIOD_CURRENT ? baseTF : InpMLTimeframe);
   if(tf==PERIOD_CURRENT) tf=(ENUM_TIMEFRAMES)_Period;
   return(f.Init(eaName,sym,tf,magic,InpMLMode,InpMLThreshold,InpMLMinSamples,
                    InpMLBarrierTP,InpMLBarrierSL,InpMLMaxBars,
                    InpMLLoadModel,InpMLSaveModel,InpMLExportCSV,InpMLScaleLots));
  }

#endif
//+------------------------------------------------------------------+

//==================== BQ_MLInputs.mqh 結束 ====================

const string SEC_SYM[]=
  {
   "AUDCAD","AUDCHF","AUDCHF","AUDNZD","AUDNZD","GBPJPY","GBPJPY","GBPJPY","GBPJPY",
   "NZDCHF","NZDCHF","USDJPY","USDJPY","USDJPY","USDJPY","AUDJPY","AUDJPY","EURJPY",
   "EURJPY","EURCAD","EURCAD","AUDUSD","AUDUSD","EURUSD","EURUSD","NZDCAD","NZDCAD",
   "GBPAUD","GBPAUD","GBPAUD","NZDJPY","NZDJPY","NZDJPY","NZDJPY","GBPUSD","GBPUSD"
  };
const int SEC_ID[]=
  {
   1,1,2,1,2,1,2,3,4,
   1,2,1,2,3,4,1,2,1,
   2,1,2,1,2,1,2,1,2,
   1,2,3,1,2,3,4,1,2
  };
const int SEC_TYPE[]=
  {
   1,1,3,1,3,1,1,3,1,
   1,3,2,3,2,3,2,3,1,
   3,2,3,2,3,2,2,1,2,
   3,1,3,3,2,3,3,1,1
  };
const int SEC_FAST[]=
  {
   20,2,3,2,22,30,2,2,2,
   7,6,2,23,4,2,9,21,2,
   5,55,43,32,4,14,14,57,7,
   12,15,18,12,3,10,20,56,70
  };
const int SEC_SLOW[]=
  {
   24,9,13,56,28,44,5,46,50,
   10,12,53,29,48,26,53,51,6,
   6,45,35,39,9,5,55,60,17,
   4,43,2,20,21,26,30,50,38
  };
const int SEC_SIG[]=
  {
   62,17,7,10,10,6,34,8,6,
   15,13,3,26,4,4,31,27,45,
   37,57,31,42,60,11,59,58,48,
   3,58,2,21,28,20,8,2,2
  };

//--- 由券商商品名稱取出 6 碼貨幣對 (處理 m.GBPJPY / GBPJPY.pro 等前後綴)
string SecretPair(const string sym)
  {
   string u=sym;
   StringToUpper(u);
   for(int r=0;r<ArraySize(SEC_SYM);r++)
      if(StringFind(u,SEC_SYM[r])>=0) return(SEC_SYM[r]);
   return(StringSubstr(u,0,6));
  }

//+------------------------------------------------------------------+
//| 策略本體：每個交易商品一個物件 (m_sym / m_tf 取代 _Symbol / _Period) |
//+------------------------------------------------------------------+
class CStrat
  {
public:
   string          m_sym;    // 交易商品
   ENUM_TIMEFRAMES m_tf;     // 策略週期
   string          m_panel;  // 面板文字
   CBQMLFilter     m_ml;     // 此商品的 ML 過濾器
   string          m_id;     // EA 編號 (參數表編號 / Magic 前綴)

                     CStrat() { m_HH=0; m_LL=0; m_CC=0; m_OO=0; m_halfBuy=false; m_halfSell=false; }
   void              SetPanel(const string s) { m_panel=s; }

   CBQTrade        m_trade;
   CBQBarGuard     m_guardBuy,m_guardSell;
   CBQDailyCounter m_daily;
   int    m_type,m_fast,m_slow,m_sig;
   long   m_magic;
   double m_HH,m_LL,m_CC,m_OO;
   bool m_halfBuy,m_halfSell;

   bool LookupTable(const string pair,const int id,int &type,int &fast,int &slow,int &sig)
     {
      for(int i=0;i<ArraySize(SEC_SYM);i++)
         if(SEC_SYM[i]==pair && SEC_ID[i]==id)
           {
            type=SEC_TYPE[i]; fast=SEC_FAST[i]; slow=SEC_SLOW[i]; sig=SEC_SIG[i];
            return(true);
           }
      return(false);
     }

   //--- 原版 getMagicNum：幣別代碼 + 週期代碼 (沿用，讓舊單仍可被管理)
   string CcyCode(const string c)
     {
      if(c=="USD") return("10"); if(c=="GBP") return("20"); if(c=="EUR") return("30");
      if(c=="AUD") return("40"); if(c=="NZD") return("50"); if(c=="JPY") return("60");
      if(c=="CAD") return("70"); if(c=="CNH") return("80"); if(c=="CHF") return("90");
      return("");
     }

   string PeriodCode()
     {
      switch(m_tf)
        {
         case PERIOD_M1: return("01");  case PERIOD_M2: return("02");  case PERIOD_M3: return("03");
         case PERIOD_M4: return("04");  case PERIOD_M6: return("05");  case PERIOD_M10: return("06");
         case PERIOD_M12: return("07"); case PERIOD_M15: return("08"); case PERIOD_M20: return("09");
         case PERIOD_M30: return("10"); case PERIOD_H1: return("11");  case PERIOD_H2: return("12");
         case PERIOD_H3: return("13");  case PERIOD_H4: return("14");  case PERIOD_H6: return("15");
         case PERIOD_H8: return("16");  case PERIOD_H12: return("17"); case PERIOD_D1: return("18");
         case PERIOD_W1: return("19");  case PERIOD_MN1: return("20");
        }
      return("00");
     }

   long CalcMagic()
     {
      string pr=SecretPair(m_sym);
      string s=m_id+CcyCode(StringSubstr(pr,0,3))+CcyCode(StringSubstr(pr,3,3))+PeriodCode();
      return(StringToInteger(s));
     }

   //--- 以 T 點為日界，更新前一「交易日」的高低開收
   void UpdateLevels()
     {
      int h=BQ_Hour();
      if(h<InpDayStart) return;          // T 點前沿用前值 (與原版相同)
      int s=1+h-InpDayStart;
      double hh=BQ_Highest(m_sym,PERIOD_H1,24,s);
      double ll=BQ_Lowest(m_sym,PERIOD_H1,24,s);
      double cc=iClose(m_sym,PERIOD_H1,s);
      double oo=iOpen(m_sym,PERIOD_H1,24+h-InpDayStart);
      if(BQ_Ok(hh) && BQ_Ok(ll) && cc>0 && oo>0)
        { m_HH=hh; m_LL=ll; m_CC=cc; m_OO=oo; }
     }

   bool BuyCond(const double bid,const double macd,const double sig)
     {
      if(!(bid<m_HH && macd<0 && macd>sig)) return(false);
      if(m_type==1) return(m_CC>m_OO);
      if(m_type==2) return(m_CC<m_OO);
      return(m_type==3);
     }

   bool SellCond(const double bid,const double macd,const double sig)
     {
      if(!(bid>m_LL && macd>0 && macd<sig)) return(false);
      if(m_type==1) return(m_CC<m_OO);
      if(m_type==2) return(m_CC>m_OO);
      return(m_type==3);
     }

   //--- 到 1R：平一半 + 停損移到進場價
   void ManageBreakEven(const ENUM_POSITION_TYPE type)
     {
      bool isBuy=(type==POSITION_TYPE_BUY);
      if(m_trade.Count(type)==0)
        {
         if(isBuy) m_halfBuy=false; else m_halfSell=false;
         return;
        }
      double open=m_trade.OpenPrice(type), sl=m_trade.PosSL(type);
      double risk=(isBuy ? open-sl : sl-open);
      if(sl<=0 || risk<=0) return;                       // 已經保本或沒有停損
      double px=(isBuy ? m_trade.Bid() : m_trade.Ask());
      bool reached=(isBuy ? px>=open+risk : px<=open-risk);
      if(!reached) return;
      bool done=(isBuy ? m_halfBuy : m_halfSell);
      if(InpHalfClose && !done)
        {
         m_trade.ClosePartial(type,0.5);
         if(isBuy) m_halfBuy=true; else m_halfSell=true;
        }
      m_trade.ModifySL(type,open);
     }

   int Setup()
     {
      string pair=SecretPair(m_sym);
      if(InpParamMode==SECRET_TABLE)
        {
         if(!LookupTable(pair,(int)StringToInteger(m_id),m_type,m_fast,m_slow,m_sig))
           {
            PrintFormat("Secret：參數表沒有 %s 編號 %s，請改用自訂參數模式或換編號",pair,m_id);
            return(INIT_PARAMETERS_INCORRECT);
           }
        }
      else
        {
         m_type=InpType; m_fast=InpFastEMA; m_slow=InpSlowEMA; m_sig=InpSignal;
        }
      if(m_type<1 || m_type>3)
        {
         Print("Secret：TYPE 必須是 1~3");
         return(INIT_PARAMETERS_INCORRECT);
        }
      m_magic=CalcMagic();
      m_trade.Init(m_sym,m_magic,m_magic+77,InpSlippage);
      m_daily.Init(InpDayStart);
      BQ_hMACD(m_sym,InpMACDTF,m_fast,m_slow,m_sig,PRICE_CLOSE);
      PrintFormat("Secret：%s TYPE=%d MACD(%d,%d,%d) Magic=%I64d",pair,m_type,m_fast,m_slow,m_sig,m_magic);
      BQML_Setup(m_ml,"Secret",m_sym,m_tf,m_magic);
      return(INIT_SUCCEEDED);
     }

   void Shutdown()
     {
      m_ml.Deinit();
     }


   void Tick()
     {
      m_ml.OnTick();
      if(AccountInfoDouble(ACCOUNT_BALANCE)<=InpMinBalance) return;

      UpdateLevels();
      ManageBreakEven(POSITION_TYPE_BUY);
      ManageBreakEven(POSITION_TYPE_SELL);

      int hour=BQ_Hour();
      //--- 隔一個交易日仍未觸發的掛單作廢
      if(hour>=InpDayStart)
        {
         if(m_trade.PendingCount(true)>0  && !m_guardBuy.Done(m_sym,PERIOD_D1))  m_trade.DeletePending(true);
         if(m_trade.PendingCount(false)>0 && !m_guardSell.Done(m_sym,PERIOD_D1)) m_trade.DeletePending(false);
        }
      if(hour<InpDayStart || m_HH<=0 || m_LL<=0 || m_HH<=m_LL) return;
      if(m_daily.Count()>=InpMaxTradesDay || !m_trade.SpreadOK(InpMaxSpread)) return;

      double macd=BQ_MACD(m_sym,InpMACDTF,m_fast,m_slow,m_sig,PRICE_CLOSE,0,1);
      double sig =BQ_MACD(m_sym,InpMACDTF,m_fast,m_slow,m_sig,PRICE_CLOSE,1,1);
      if(!BQ_Ok(macd) || !BQ_Ok(sig)) return;
      double bid=m_trade.Bid();
      double range=m_HH-m_LL;
      double lots=m_trade.CalcLots(InpAutoLots,InpRiskPct,range,InpLots,InpMaxLots,InpRiskBase);
      if(InpHalfClose) lots=MathMax(lots,2*m_trade.MinLot());

      if(m_trade.CountBuy()==0 && m_trade.PendingCount(true)==0 && !m_guardBuy.Done(m_sym,PERIOD_D1) &&
         BuyCond(bid,macd,sig) && m_ml.Allow(1,range,2*range))
        {
         if(m_trade.Pending(ORDER_TYPE_BUY_STOP,m_HH,lots*m_ml.LotFactor(),m_LL,m_HH+2*range,"Secret Buy"))
           {
            m_daily.Inc();
            m_guardBuy.Mark(m_sym,PERIOD_D1);
            m_halfBuy=false;
           }
        }
      if(m_trade.CountSell()==0 && m_trade.PendingCount(false)==0 && !m_guardSell.Done(m_sym,PERIOD_D1) &&
         SellCond(bid,macd,sig) && m_ml.Allow(-1,range,2*range))
        {
         if(m_trade.Pending(ORDER_TYPE_SELL_STOP,m_LL,lots*m_ml.LotFactor(),m_HH,m_LL-2*range,"Secret Sell"))
           {
            m_daily.Inc();
            m_guardSell.Mark(m_sym,PERIOD_D1);
            m_halfSell=false;
           }
        }
      SetPanel(StringFormat("Secret ML  TYPE %d  MACD(%d,%d,%d)\nHH %.5f  LL %.5f\n今日掛單 %d\n%s",
                            m_type,m_fast,m_slow,m_sig,m_HH,m_LL,m_daily.Count(),m_ml.Status()));
     }
  };

//+------------------------------------------------------------------+
//| 多商品執行：OnTick (圖表商品報價) + OnTimer (每秒) 輪流執行每個商品  |
//+------------------------------------------------------------------+
CStrat *g_strats[];

bool AddStrat(CStrat *p)
  {
   if(p.Setup()!=INIT_SUCCEEDED)
     {
      PrintFormat("Secret：%s 初始化失敗，略過此商品",p.m_sym);
      delete p;
      return(false);
     }
   int k=ArraySize(g_strats);
   ArrayResize(g_strats,k+1);
   g_strats[k]=p;
   return(true);
  }

int OnInit()
  {
   if(!BQ_AccountAllowed()) return(INIT_FAILED);
   string syms[];
   int n=BQ_ParseSymbols(InpSymbols,syms);
   for(int i=0;i<n;i++)
     {
      bool allIds=(InpParamMode==SECRET_TABLE && StringToInteger(InpEAMagicNum)==0);
      if(!allIds)
        {
         CStrat *p=new CStrat;
         p.m_sym=syms[i];
         p.m_tf=BQ_TF(InpBaseTF);
         p.m_id=(StringToInteger(InpEAMagicNum)==0 ? "1" : InpEAMagicNum);
         AddStrat(p);
         continue;
        }
      //--- 參數表模式、編號 0：此商品在表中的每一組編號都各跑一個 (與原版每組開一張圖相同)
      string pair=SecretPair(syms[i]);
      int found=0;
      for(int r=0;r<ArraySize(SEC_SYM);r++)
        {
         if(SEC_SYM[r]!=pair) continue;
         CStrat *p=new CStrat;
         p.m_sym=syms[i];
         p.m_tf=BQ_TF(InpBaseTF);
         p.m_id=IntegerToString(SEC_ID[r]);
         if(AddStrat(p)) found++;
        }
      if(found==0)
         PrintFormat("Secret：%s 不在 v7 參數表，略過 (可改用自訂參數模式)",syms[i]);
     }
   if(ArraySize(g_strats)==0)
     {
      Print("Secret：沒有可交易的商品，請檢查 InpSymbols");
      return(INIT_FAILED);
     }
   string list="";
   for(int i=0;i<ArraySize(g_strats);i++)
      list+=(i>0 ? "," : "")+g_strats[i].m_sym+"#"+g_strats[i].m_id;
   PrintFormat("Secret：執行 %d 個商品 [%s] 週期 %s (圖表 %s 只是載體)",ArraySize(g_strats),list,
               EnumToString(BQ_TF(InpBaseTF)),_Symbol);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i=0;i<ArraySize(g_strats);i++)
     {
      g_strats[i].Shutdown();
      delete g_strats[i];
     }
   ArrayResize(g_strats,0);
   BQ_ReleaseIndicators();
   Comment("");
  }

double OnTester() { return(BQ_TesterScore()); }

void RunAll()
  {
   string body="";
   for(int i=0;i<ArraySize(g_strats);i++)
     {
      g_strats[i].Tick();
      body+=BQ_PanelLine(g_strats[i].m_sym+"#"+g_strats[i].m_id,g_strats[i].m_panel);
     }
   BQ_PanelMulti("Secret ML  (商品 "+IntegerToString(ArraySize(g_strats))+")",body);
  }

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }
//+------------------------------------------------------------------+
