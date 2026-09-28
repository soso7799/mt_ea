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
