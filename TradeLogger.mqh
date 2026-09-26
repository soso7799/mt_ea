//+------------------------------------------------------------------+
//|  TradeLogger.mqh                                                 |
//|  成交紀錄寫成 CSV：MQL5\Files\trade_logs\YYYY\MM\                 |
//|  trade_logs 用 symlink 指到歷史資料碟（見 docs/STORAGE_LAYOUT.md） |
//+------------------------------------------------------------------+
#ifndef TRADELOGGER_MQH
#define TRADELOGGER_MQH

#define TL_MAX_PENDING 500

class CTradeLogger
{
private:
   long     m_magic;
   string   m_root;
   bool     m_enabled;
   string   m_pending[];   // 網路碟寫入失敗時暫存，下次成功時補寫

   string FileFor(datetime t)
   {
      MqlDateTime d; TimeToStruct(t, d);
      return StringFormat("%s\\%04d\\%02d\\trades_%I64d_%04d%02d.csv",
                          m_root, d.year, d.mon, AccountInfoInteger(ACCOUNT_LOGIN), d.year, d.mon);
   }

   string DealTypeStr(ENUM_DEAL_TYPE t)
   {
      if(t==DEAL_TYPE_BUY)  return "BUY";
      if(t==DEAL_TYPE_SELL) return "SELL";
      return EnumToString(t);
   }

   string EntryStr(ENUM_DEAL_ENTRY e)
   {
      if(e==DEAL_ENTRY_IN)    return "IN";
      if(e==DEAL_ENTRY_OUT)   return "OUT";
      if(e==DEAL_ENTRY_INOUT) return "INOUT";
      return "OUT_BY";
   }

   string ReasonStr(ENUM_DEAL_REASON r)
   {
      if(r==DEAL_REASON_SL)     return "SL";
      if(r==DEAL_REASON_TP)     return "TP";
      if(r==DEAL_REASON_SO)     return "STOPOUT";
      if(r==DEAL_REASON_EXPERT) return "EXPERT";
      if(r==DEAL_REASON_CLIENT) return "MANUAL";
      return EnumToString(r);
   }

   bool AppendLine(const string file, const string line)
   {
      int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(h == INVALID_HANDLE) return false;

      if(FileSize(h) == 0)
         FileWriteString(h, "time,deal,position,symbol,type,entry,volume,price,sl,tp,"
                            "profit,swap,commission,reason,score,balance,equity,comment\r\n");
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line + "\r\n");
      FileClose(h);
      return true;
   }

   void Write(const string file, const string line)
   {
      // 先補寫之前失敗的，保持時間順序
      int n = ArraySize(m_pending);
      int done = 0;
      while(done < n)
      {
         string parts[];
         StringSplit(m_pending[done], '|', parts);   // "檔名|內容"
         if(ArraySize(parts) < 2 || !AppendLine(parts[0], StringSubstr(m_pending[done], StringLen(parts[0])+1)))
            break;
         done++;
      }
      if(done > 0) ArrayRemove(m_pending, 0, done);

      if(ArraySize(m_pending) == 0 && AppendLine(file, line))
         return;

      if(ArraySize(m_pending) >= TL_MAX_PENDING)
         ArrayRemove(m_pending, 0, 1);
      int k = ArraySize(m_pending);
      ArrayResize(m_pending, k+1);
      m_pending[k] = file + "|" + line;
      PrintFormat("⚠️ TradeLogger: 寫入 %s 失敗(err=%d)，暫存 %d 筆待補寫", file, GetLastError(), k+1);
   }

public:
   CTradeLogger() : m_magic(0), m_root("trade_logs"), m_enabled(true) {}

   void Init(long magic, bool enabled, string root="trade_logs")
   {
      m_magic   = magic;
      m_enabled = enabled;
      m_root    = root;
   }

   // 在 OnTradeTransaction 呼叫；score = 開倉時的信號分數（平倉填 0）
   void OnTransaction(const MqlTradeTransaction &trans, int score)
   {
      if(!m_enabled || trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
      if(!HistoryDealSelect(trans.deal)) return;
      if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != m_magic) return;

      ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) return;

      string   sym    = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
      int      digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      datetime t      = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

      string comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
      StringReplace(comment, ",", " ");
      StringReplace(comment, "|", " ");

      string line = StringFormat("%s,%I64u,%I64d,%s,%s,%s,%.2f,%s,%s,%s,%.2f,%.2f,%.2f,%s,%d,%.2f,%.2f,%s",
         TimeToString(t, TIME_DATE|TIME_SECONDS),
         trans.deal,
         HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID),
         sym,
         DealTypeStr(type),
         EntryStr(entry),
         HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
         DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), digits),
         DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_SL), digits),
         DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_TP), digits),
         HistoryDealGetDouble(trans.deal, DEAL_PROFIT),
         HistoryDealGetDouble(trans.deal, DEAL_SWAP),
         HistoryDealGetDouble(trans.deal, DEAL_COMMISSION),
         ReasonStr((ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON)),
         (entry == DEAL_ENTRY_IN ? score : 0),
         AccountInfoDouble(ACCOUNT_BALANCE),
         AccountInfoDouble(ACCOUNT_EQUITY),
         comment);

      Write(FileFor(t), line);
   }
};

#endif
