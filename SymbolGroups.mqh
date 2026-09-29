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
