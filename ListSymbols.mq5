//+------------------------------------------------------------------+
//|  ListSymbols.mq5 — 列出券商（FTMO）全部商品明細（腳本，只讀）       |
//|  拖到任一圖表執行 → Common\Files\FTMO_Data\symbols_list.csv        |
//|  欄位：商品、分組、說明、券商資料夾、小數位、合約大小、每點價值、   |
//|        最小/最大手數、手數間距、目前點差、隔夜費多/空、交易模式、    |
//|        是否在 HistoryExporter 匯出範圍                               |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.00"

input string InpGroups = "major,cross,exotic,metal,energy,index,agri,crypto"; // HistoryExporter 的分組（標記是否匯出）

//--- 商品分組（內嵌 SymbolGroups.mqh）
//+------------------------------------------------------------------+
//|  SymbolGroups.mqh                                                |
//|  商品分組：主要貨幣 / 交叉貨幣 / 異國貨幣 / 金屬 / 能源 / 指數 /   |
//|            農產品 / 加密貨幣                                      |
//|                                                                  |
//|  先依商品名稱判斷（可處理 .cash / .c / .m 等後綴與短前綴），         |
//|  名稱判斷不出來時再看券商的商品資料夾 (SYMBOL_PATH)                 |
//+------------------------------------------------------------------+

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

//+------------------------------------------------------------------+

string ModeName(const long m)
{
   switch((int)m)
   {
      case SYMBOL_TRADE_MODE_DISABLED:  return "停用";
      case SYMBOL_TRADE_MODE_LONGONLY:  return "只能做多";
      case SYMBOL_TRADE_MODE_SHORTONLY: return "只能做空";
      case SYMBOL_TRADE_MODE_CLOSEONLY: return "只能平倉";
   }
   return "可交易";
}

void OnStart()
{
   FolderCreate("FTMO_Data", FILE_COMMON);
   string file = "FTMO_Data\\symbols_list.csv";
   int h = FileOpen(file, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_UTF8);
   if(h == INVALID_HANDLE) { Print("ListSymbols：無法建立 ", file); return; }
   FileWriteString(h, ShortToString(0xFEFF));   // BOM，Excel 才會正確顯示中文
   FileWrite(h, "symbol", "group", "group_name", "description", "path", "digits", "contract_size",
             "tick_value", "min_lot", "max_lot", "lot_step", "spread_points", "swap_long", "swap_short",
             "trade_mode", "exported");

   string groups = "," + InpGroups + ",";
   StringReplace(groups, " ", "");
   int total = SymbolsTotal(false), exported = 0;
   int cnt[GRP_COUNT];
   ArrayInitialize(cnt, 0);
   for(int i = 0; i < total; i++)
   {
      string s = SymbolName(i, false);
      ENUM_SYM_GROUP g = SymbolGroup(s);
      long mode = SymbolInfoInteger(s, SYMBOL_TRADE_MODE);
      bool exp = (mode != SYMBOL_TRADE_MODE_DISABLED) && StringFind(groups, "," + GroupCode(g) + ",") >= 0;
      if(exp) exported++;
      cnt[(int)g]++;
      string desc = SymbolInfoString(s, SYMBOL_DESCRIPTION);
      StringReplace(desc, ",", " ");
      FileWrite(h, s, GroupCode(g), GroupName(g), desc, SymbolInfoString(s, SYMBOL_PATH),
                SymbolInfoInteger(s, SYMBOL_DIGITS), SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE),
                SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE), SymbolInfoDouble(s, SYMBOL_VOLUME_MIN),
                SymbolInfoDouble(s, SYMBOL_VOLUME_MAX), SymbolInfoDouble(s, SYMBOL_VOLUME_STEP),
                SymbolInfoInteger(s, SYMBOL_SPREAD), SymbolInfoDouble(s, SYMBOL_SWAP_LONG),
                SymbolInfoDouble(s, SYMBOL_SWAP_SHORT), ModeName(mode), exp ? "Y" : "");
   }
   FileClose(h);

   string sum = "";
   for(int k = 0; k < GRP_COUNT; k++)
      if(cnt[k] > 0) sum += StringFormat("%s %d  ", GroupName((ENUM_SYM_GROUP)k), cnt[k]);
   PrintFormat("ListSymbols：%s（%s）共 %d 個商品，HistoryExporter 會匯出 %d 個", AccountInfoString(ACCOUNT_SERVER),
               AccountInfoString(ACCOUNT_COMPANY), total, exported);
   Print("ListSymbols：", sum);
   PrintFormat("ListSymbols：明細已寫入 %%APPDATA%%\\MetaQuotes\\Terminal\\Common\\Files\\%s", file);
}
