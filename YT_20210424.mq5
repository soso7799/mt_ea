//+------------------------------------------------------------------+
//|                                                  YT_20210424.mq5 |
//|                        Copyright 2020, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2020, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//|              第一步驟                                            |
//+------------------------------------------------------------------+

#include <cash.mqh>
#include <Trade\Trade.mqh>
cash cc;
CTrade mytrade;

MqlDateTime Time;

//+------------------------------------------------------------------+
//|              第二步驟                                            |
//+------------------------------------------------------------------+

double Ask,Bid,AccountBalance,Tickvalue;

//內部宣告---------------------------------------------------------------

int 買單單號,賣單單號;
int B避免同根重複下單的風控變數=0;
int S避免同根重複下單的風控變數=0;
int 每日下單筆數=0;

int MagicNumber;
int 多單獲利根數 = 0,空單獲利根數 = 0;

double 多單出場價 = 0,空單出場價 = 0;
double 方向線_1,MA144_1,MA169_1,MA576_1,MA676_1;
double 方向線_2,MA144_2,MA169_2,MA576_2,MA676_2;
double 方向線_3,MA144_3,MA169_3,MA576_3,MA676_3;
double ATR_1;


bool 買進條件1,買進條件2;
bool 賣出條件1,賣出條件2;
bool 多頭排列,空頭排列;

bool 多單出場條件1,空單出場條件1;

bool 多單移動出場條件 = false;
bool 空單移動出場條件 = false;

int bar = 0;

//指標 handle (MQL5 指標需先建立 handle，再用 CopyBuffer 取值)
int h方向線 = INVALID_HANDLE;
int hMA144  = INVALID_HANDLE;
int hMA169  = INVALID_HANDLE;
int hMA576  = INVALID_HANDLE;
int hMA676  = INVALID_HANDLE;
int hATR    = INVALID_HANDLE;


//外部宣告---------------------------------------------------------------

input double 資金風控=6500;
input double 初始手數=0.1;

input ENUM_TIMEFRAMES 時間週期=PERIOD_H1;
input int inC1 = 1;
input int inO1 = 1;
input int ATRP = 20;
input int 獲利幾倍ATR =3;
input int 停損幾倍ATR =5;
input int 獲利根數 = 2;
input int O4A =5;
input int O4B =40;


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   h方向線 = iMA(Symbol(),時間週期,12,0,MODE_EMA,PRICE_CLOSE);
   hMA144  = iMA(Symbol(),時間週期,144,0,MODE_EMA,PRICE_CLOSE);
   hMA169  = iMA(Symbol(),時間週期,169,0,MODE_EMA,PRICE_CLOSE);
   hMA576  = iMA(Symbol(),時間週期,576,0,MODE_EMA,PRICE_CLOSE);
   hMA676  = iMA(Symbol(),時間週期,676,0,MODE_EMA,PRICE_CLOSE);
   hATR    = iATR(Symbol(),時間週期,ATRP);

   if(h方向線==INVALID_HANDLE || hMA144==INVALID_HANDLE || hMA169==INVALID_HANDLE ||
      hMA576==INVALID_HANDLE || hMA676==INVALID_HANDLE || hATR==INVALID_HANDLE)
     {
      PrintFormat("建立指標 handle 失敗, error %d",GetLastError());
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(h方向線);
   IndicatorRelease(hMA144);
   IndicatorRelease(hMA169);
   IndicatorRelease(hMA576);
   IndicatorRelease(hMA676);
   IndicatorRelease(hATR);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double OnTester()
  {
   double  profit2=TesterStatistics(STAT_PROFIT);//取淨利
   double  max_dd=TesterStatistics(STAT_BALANCE_DD);//取最大虧損 MDD
   double rec_factor=0;

   if(max_dd != 0 && TesterStatistics(STAT_TRADES)>=50)
     {
      rec_factor=profit2/max_dd;
     }

   return(rec_factor);
  }
//+------------------------------------------------------------------+
//| 從指標 handle 取得指定 shift 的數值                              |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle,int shift,int buffer=0)
  {
   double buf[1];
   if(CopyBuffer(handle,buffer,shift,1,buf)!=1)
      return(EMPTY_VALUE);
   return(buf[0]);
  }
//+------------------------------------------------------------------+
//|                      以下啟動交易程式碼                          |
//+------------------------------------------------------------------+
void OnTick()
  {

   TimeToStruct((datetime)TimeCurrent(),Time);

   if(!NewBar())
      return;


   string f1=StringSubstr(Symbol(),0,3);
   string f2=StringSubstr(Symbol(),3,3);

//+------------------------------------------------------------------+
//|                      以下資金風控                                |
//+------------------------------------------------------------------+

   MagicNumber=getMagicNum(Symbol());
   MagicNumber=(int)StringToInteger("6"+IntegerToString(MagicNumber));


   if(AccountInfoDouble(ACCOUNT_BALANCE)<=資金風控)
     {
      Alert("No Enough Money!!");
      return;  //資金風控
     }
   if(cc.TimeHour(TimeCurrent())<=2 && cc.TimeMinute(TimeCurrent())<=5)
      每日下單筆數=0;


//+------------------------------------------------------------------+
//|                      以下參數設定                                |
//+------------------------------------------------------------------+

   Ask=SymbolInfoDouble(Symbol(),SYMBOL_ASK);
   Bid=SymbolInfoDouble(Symbol(),SYMBOL_BID);

   /*
   //169 676判斷主要方向
   進場1: 方向線向上穿越144 169 (多頭排列時)
   進場2: 方向線第一次穿越676,(空頭排列時)
   進場3: U型 (多頭排列時)

   出場1: C>MA N點
   出場2: ㄇ形
   出場3: 獲利N根出場
   出場4: 獲利時，過去一段時間 區間低點<MA144 但 現在價格往上走 立刻出場
   */

   方向線_1 = GetIndicatorValue(h方向線,1);
   MA144_1 = GetIndicatorValue(hMA144,1);
   MA169_1 = GetIndicatorValue(hMA169,1);
   MA576_1 = GetIndicatorValue(hMA576,1);
   MA676_1 = GetIndicatorValue(hMA676,1);

   方向線_2 = GetIndicatorValue(h方向線,2);
   MA144_2 = GetIndicatorValue(hMA144,2);
   MA169_2 = GetIndicatorValue(hMA169,2);
   MA576_2 = GetIndicatorValue(hMA576,2);
   MA676_2 = GetIndicatorValue(hMA676,2);

   方向線_3 = GetIndicatorValue(h方向線,3);
   MA144_3 = GetIndicatorValue(hMA144,3);
   MA169_3 = GetIndicatorValue(hMA169,3);
   MA576_3 = GetIndicatorValue(hMA576,3);
   MA676_3 = GetIndicatorValue(hMA676,3);

   ATR_1 = GetIndicatorValue(hATR,1);

//指標資料尚未準備好時，本根先跳過 (下一根重新判斷)
   if(方向線_1==EMPTY_VALUE || 方向線_2==EMPTY_VALUE || 方向線_3==EMPTY_VALUE ||
      MA144_1==EMPTY_VALUE || MA144_2==EMPTY_VALUE ||
      MA169_1==EMPTY_VALUE || MA169_2==EMPTY_VALUE ||
      MA676_1==EMPTY_VALUE || MA676_2==EMPTY_VALUE ||
      ATR_1==EMPTY_VALUE)
     {
      bar = 0;
      return;
     }

   多頭排列 = MA169_1>MA676_1;
   空頭排列 = MA169_1<MA676_1;

//進場模組
   if(inC1==1)
     {
      買進條件1 = 方向線_1>MA144_1 && 方向線_1>MA169_1 && 方向線_2<MA144_2 && 方向線_2<MA169_2 && 多頭排列 ;

      賣出條件1 = 方向線_1<MA144_1 && 方向線_1<MA169_1 && 方向線_2>MA144_2 && 方向線_2>MA169_2 && 空頭排列 ;

     }
   else
      if(inC1==2)
        {
         買進條件1 = 方向線_1>MA676_1 && 方向線_2<MA676_2 && 空頭排列;
         賣出條件1 = 方向線_1<MA676_1 && 方向線_2>MA676_2 && 多頭排列;
        }
      else
         if(inC1==3)
           {
            買進條件1 = 方向線_1 > 方向線_2 && 方向線_1 > 方向線_3 && 方向線_3 > 方向線_2 && 多頭排列;
            賣出條件1 = 方向線_1 < 方向線_2 && 方向線_1 < 方向線_3 && 方向線_3 < 方向線_2 && 空頭排列;
           }
         else
           {
            買進條件1 = false;
            賣出條件1 = false;
           }

//出場模組
   if(inO1==1)
     {
      多單出場條件1 = iClose(Symbol(),時間週期,1)>方向線_1+ (獲利幾倍ATR*ATR_1);
      空單出場條件1 = iClose(Symbol(),時間週期,1)<方向線_1- (獲利幾倍ATR*ATR_1);
     }
   else
      if(inO1==2)
        {
         多單出場條件1 = 方向線_1 < 方向線_2 && 方向線_1 < 方向線_3 && 方向線_3 < 方向線_2 ;
         空單出場條件1 = 方向線_1 > 方向線_2 && 方向線_1 > 方向線_3 && 方向線_3 > 方向線_2 ;

        }
      else
         if(inO1==3)
           {
            if(多單筆數()==0)
              {
               多單獲利根數 = 0;
              }
            if(多單筆數()>0 && Bid>多單進場價())
              {
               多單獲利根數 += 1;
              }

            if(空單筆數()==0)
              {
               空單獲利根數 = 0;
              }
            if(空單筆數()>0 && Ask<空單進場價())
              {
               空單獲利根數 += 1;
              }

            多單出場條件1 = 多單獲利根數>=獲利根數;
            空單出場條件1 = 空單獲利根數>=獲利根數;
           }
         else
            if(inO1==4)
              {
               多單出場條件1 = Bid>多單進場價() && iHighest(Symbol(),時間週期,MODE_HIGH,O4A,0)==0 &&
                         iLow(Symbol(),時間週期,iLowest(Symbol(),時間週期,MODE_LOW,O4B,0))<MA144_1;
               空單出場條件1 = Ask<空單進場價() && iLowest(Symbol(),時間週期,MODE_LOW,O4A,0) == 0 &&
                         iHigh(Symbol(),時間週期,iHighest(Symbol(),時間週期,MODE_HIGH,O4B,0))>MA144_1;
              }
            else
              {
               多單出場條件1 = false;
               空單出場條件1 = false;
              }

//----------------------------------------------------------------------------------
//                                          多單開始
//----------------------------------------------------------------------------------

   if(多單筆數()==0 && B避免同根重複下單的風控變數!=iBars(Symbol(),時間週期))
     {
      if(買進的條件()==true)
        {
         MqlTradeRequest request= {};
         MqlTradeResult  result= {};
         request.order=買單單號;
         request.action=TRADE_ACTION_DEAL;
         request.symbol=Symbol();
         request.type=ORDER_TYPE_BUY;
         request.volume=初始手數;
         request.deviation=100;
         request.price=Ask;
         request.sl=Ask - 停損幾倍ATR*ATR_1;
         request.tp=Ask + 獲利幾倍ATR*ATR_1;
         request.comment="MOM Buy";
         request.magic=MagicNumber;

         if(!OrderSend(request,result))
            PrintFormat("OrderSend error %d",GetLastError());
         else
            B避免同根重複下單的風控變數=iBars(Symbol(),時間週期);

         PrintFormat("retcode=%u  deal=%I64u  order=%I64u",result.retcode,result.deal,result.order);


         空單平倉();
         Sleep(100);
        }
     }
//---------------------------------------------------------多單出場

   if(多單筆數()>0 && 多單出場條件()==true && B避免同根重複下單的風控變數!=iBars(Symbol(),時間週期))
     {
      多單平倉();
      if(多單筆數()==0)
        {
         B避免同根重複下單的風控變數=iBars(Symbol(),時間週期);
        }
     }


//----------------------------------------------------------------------------------
//                                          空單開始
//----------------------------------------------------------------------------------


   if(空單筆數()==0 && S避免同根重複下單的風控變數!=iBars(Symbol(),時間週期))
     {
      if(賣出的條件()==true)
        {

         MqlTradeRequest request= {};
         MqlTradeResult  result= {};
         request.order=賣單單號;
         request.action=TRADE_ACTION_DEAL;
         request.symbol=Symbol();
         request.type=ORDER_TYPE_SELL;
         request.volume=初始手數;
         request.deviation=100;
         request.price=Bid;
         request.sl=Bid + 停損幾倍ATR*ATR_1;
         request.tp=Bid - 獲利幾倍ATR*ATR_1;
         request.comment="MOM Sell";
         request.magic=MagicNumber+77;

         if(!OrderSend(request,result))
            PrintFormat("OrderSend error %d",GetLastError());
         else
            S避免同根重複下單的風控變數=iBars(Symbol(),時間週期);
         PrintFormat("retcode=%u  deal=%I64u  order=%I64u",result.retcode,result.deal,result.order);



         多單平倉();
         Sleep(100);
        }
     }

   if(空單筆數()>0 && 空單出場條件()==true && S避免同根重複下單的風控變數!=iBars(Symbol(),時間週期))
     {
      空單平倉();
      if(空單筆數()==0)
        {
         S避免同根重複下單的風控變數=iBars(Symbol(),時間週期);
        }
     }


  }


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool NewBar(ENUM_TIMEFRAMES tf = PERIOD_CURRENT,string symbol = NULL)
  {
   string sym = symbol==NULL? Symbol():symbol;
   if(bar != iBars(sym,tf))
     {
      bar = iBars(sym,tf);
      return true;
     }
   return false;
  }

//----------------------------------------------------------------------------------
//                                         函數庫
//----------------------------------------------------------------------------------

//---------------------------------------------------------多單筆數

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int 多單筆數()
  {
   int count=0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      if(PositionGetTicket(i)>0)
        {
         if(PositionGetString(POSITION_SYMBOL)==Symbol() && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY && PositionGetInteger(POSITION_MAGIC)==MagicNumber)
            count++;
        }
     }
   return(count);
  }
//---------------------------------------------------------空單筆數

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int 空單筆數()
  {
   int count=0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      if(PositionGetTicket(i)>0)
        {
         if(PositionGetString(POSITION_SYMBOL)==Symbol() && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL && PositionGetInteger(POSITION_MAGIC)==MagicNumber+77)
            count++;
        }
     }
   return(count);
  }
//---------------------------------------------------------買進的條件

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool 買進的條件()
  {
   if(買進條件1)
      return(true);
   else
      return(false);
  }
//---------------------------------------------------------賣出的條件

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool 賣出的條件()
  {
   if(賣出條件1)
      return(true);
   else
      return(false);
  }
//---------------------------------------------------------多單出場條件

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool 多單出場條件()
  {
   if(多單出場條件1)
      return(true);
   else
      return(false);
  }
//---------------------------------------------------------空單出場條件

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool 空單出場條件()
  {

   if(空單出場條件1)
      return(true);
   else
      return(false);
  }

//---------------------------------------------------------多單Close寫法

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void 多單平倉()
  {
   int t=PositionsTotal();
   for(int i=t-1; i>=0; i--)
     {
      if(PositionGetTicket(i)>0)
        {
         if(PositionGetString(POSITION_SYMBOL)==Symbol()
            && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY
            && PositionGetInteger(POSITION_MAGIC)==MagicNumber)
           {
            MqlTradeRequest request= {};
            MqlTradeResult  result= {};
            request.action=TRADE_ACTION_DEAL;
            request.symbol=Symbol();
            request.volume=PositionGetDouble(POSITION_VOLUME);
            request.type=ORDER_TYPE_SELL;
            request.price=SymbolInfoDouble(Symbol(),SYMBOL_BID);
            request.deviation=10;
            request.comment="Long_Exit";
            request.position =PositionGetTicket(i);
            if(!OrderSend(request,result))
               PrintFormat("OrderSend error %d",GetLastError());
           }
        }
     }
  }
//---------------------------------------------------------空單Close寫法

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void 空單平倉()
  {
   int t=PositionsTotal();
   for(int i=t-1; i>=0; i--)
     {
      if(PositionGetTicket(i)>0)
        {
         if(PositionGetString(POSITION_SYMBOL)==Symbol()
            && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL
            && PositionGetInteger(POSITION_MAGIC)==MagicNumber+77)
           {
            MqlTradeRequest request= {};
            MqlTradeResult  result= {};
            request.action=TRADE_ACTION_DEAL;
            request.symbol=Symbol();
            request.volume=PositionGetDouble(POSITION_VOLUME);
            request.type=ORDER_TYPE_BUY;
            request.price=SymbolInfoDouble(Symbol(),SYMBOL_ASK);
            request.deviation=100;
            request.comment="Short_Exit";
            request.position =PositionGetTicket(i);
            if(!OrderSend(request,result))
               PrintFormat("OrderSend error %d",GetLastError());
           }
        }
     }
  }


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double 多單進場價()
  {
   double BFO=0.0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      if(PositionGetTicket(i)>0)
        {
         if(PositionGetString(POSITION_SYMBOL)==Symbol() && PositionGetInteger(POSITION_MAGIC)==MagicNumber)
           {
            BFO=PositionGetDouble(POSITION_PRICE_OPEN);
           }
        }
     }
   return(BFO);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double 空單進場價()
  {
   double SFO=0.0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      if(PositionGetTicket(i)>0)
        {
         if(PositionGetString(POSITION_SYMBOL)==Symbol() && PositionGetInteger(POSITION_MAGIC)==MagicNumber+77)
           {
            SFO=PositionGetDouble(POSITION_PRICE_OPEN);
           }
        }
     }
   return(SFO);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int getMagicNum(string pro)
  {

   string f1=StringSubstr(pro,0,3);
   string f2=StringSubstr(pro,3,3);
   string com="";

   if(f1=="USD")
     {
      com+="10";
     }
   else
      if(f1=="GBP")
        {
         com+="20";
        }
      else
         if(f1=="EUR")
           {
            com+="30";
           }
         else
            if(f1=="AUD")
              {
               com+="40";
              }
            else
               if(f1=="NZD")
                 {
                  com+="50";
                 }
               else
                  if(f1=="JPY")
                    {
                     com+="60";
                    }
                  else
                     if(f1=="CAD")
                       {
                        com+="70";
                       }
                     else
                        if(f1=="CNH")
                          {
                           com+="80";
                          }
                        else
                           if(f1=="CHF")
                             {
                              com+="90";
                             }

   if(f2=="USD")
     {
      com+="10";
     }
   else
      if(f2=="GBP")
        {
         com+="20";
        }
      else
         if(f2=="EUR")
           {
            com+="30";
           }
         else
            if(f2=="AUD")
              {
               com+="40";
              }
            else
               if(f2=="NZD")
                 {
                  com+="50";
                 }
               else
                  if(f2=="JPY")
                    {
                     com+="60";
                    }
                  else
                     if(f2=="CAD")
                       {
                        com+="70";
                       }
                     else
                        if(f2=="CNH")
                          {
                           com+="80";
                          }
                        else
                           if(f2=="CHF")
                             {
                              com+="90";
                             }

   switch(_Period)
     {

      case PERIOD_M1:
         com+="01";
         break;
      case PERIOD_M2:
         com+="02";
         break;
      case PERIOD_M3:
         com+="03";
         break;
      case PERIOD_M4:
         com+="04";
         break;
      case PERIOD_M6:
         com+="05";
         break;
      case PERIOD_M10:
         com+="06";
         break;
      case PERIOD_M12:
         com+="07";
         break;
      case PERIOD_M15:
         com+="08";
         break;
      case PERIOD_M20:
         com+="09";
         break;
      case PERIOD_M30:
         com+="10";
         break;
      case PERIOD_H1:
         com+="11";
         break;
      case PERIOD_H2:
         com+="12";
         break;
      case PERIOD_H3:
         com+="13";
         break;
      case PERIOD_H4:
         com+="14";
         break;
      case PERIOD_H6:
         com+="15";
         break;
      case PERIOD_H8:
         com+="16";
         break;
      case PERIOD_H12:
         com+="17";
         break;
      case PERIOD_D1:
         com+="18";
         break;
      case PERIOD_W1:
         com+="19";
         break;
      case PERIOD_MN1:
         com+="20";
         break;
      default:
         com+="00";
     }

   return (int)StringToDouble(com);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool 可交易時段(string symbol = NULL)
  {
   bool enable = false;
   datetime dt1,dt2;
   MqlDateTime dtstart,dtend;
   string sym = symbol==NULL? Symbol():symbol;

   if(SymbolInfoSessionTrade(Symbol(),(ENUM_DAY_OF_WEEK)Time.day_of_week,0,dt1,dt2))
     {
      TimeToStruct(dt1,dtstart);
      TimeToStruct(dt2,dtend);
      if(dt1<dt2)
        {
         enable = Time.hour>=dtstart.hour && Time.min>=dtstart.min &&
                  Time.hour<=dtend.hour && Time.min<=dtend.min;
        }
      else
        {
         enable = (Time.hour>=dtstart.hour && Time.min>=dtstart.min) ||
                  (Time.hour<=dtend.hour && Time.min<=dtend.min);
        }
      return enable;
     }
   else
      return enable;
  }
//+------------------------------------------------------------------+
