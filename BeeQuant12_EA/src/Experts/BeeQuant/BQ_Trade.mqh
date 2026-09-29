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
