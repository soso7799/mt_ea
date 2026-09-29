//+------------------------------------------------------------------+
//|  NewsFilter.mqh                                                  |
//|  重大新聞避開（MT5 內建經濟日曆）                                  |
//|                                                                  |
//|  FTMO 帳戶在高影響新聞發布前後 2 分鐘內不可有成交                   |
//|  （含開倉、平倉、SL/TP 觸發）。這裡：                                |
//|   * 每 10 分鐘讀取一次經濟日曆，取未來 24 小時的高影響事件            |
//|   * 商品任一幣別（例如 USDJPY 的 USD、JPY）有事件時，                 |
//|     事件前 BeforeMin 分鐘 ~ 事件後 AfterMin 分鐘為「新聞時段」         |
//|   * EA 在新聞時段不開新倉、不做主動平倉；可選擇事件前先平倉            |
//|  注意：策略測試器沒有經濟日曆資料，回測時本濾網不會作用                |
//|  日曆時間為交易伺服器時間，與 TimeTradeServer() 比較                  |
//+------------------------------------------------------------------+
#ifndef NEWS_FILTER_MQH
#define NEWS_FILTER_MQH

class CNewsFilter
{
private:
   datetime m_time[];
   string   m_cur[];
   string   m_name[];
   datetime m_lastLoad;
   bool     m_warned;

   // CNH 在日曆裡是 CNY
   string CalCurrency(string c)
   {
      if(c == "CNH") return "CNY";
      return c;
   }

public:
   int  BeforeMin;      // 事件前幾分鐘開始
   int  AfterMin;       // 事件後幾分鐘結束
   bool IncludeMedium;  // 也避開中等影響事件

   CNewsFilter() : m_lastLoad(0), m_warned(false), BeforeMin(5), AfterMin(5), IncludeMedium(false) {}

   // 由商品名稱取出兩個幣別，例如 "USDJPY"、"m.GBPJPY"、"USDCNH.x"
   static bool Currencies(string sym, string &base, string &quote)
   {
      string s = sym;
      StringToUpper(s);
      int n = StringLen(s);
      for(int i=0; i+6<=n; i++)
      {
         bool ok = true;
         for(int k=0; k<6; k++)
         {
            ushort ch = StringGetCharacter(s, i+k);
            if(ch < 'A' || ch > 'Z') { ok = false; break; }
         }
         if(ok)
         {
            base  = StringSubstr(s, i, 3);
            quote = StringSubstr(s, i+3, 3);
            return true;
         }
      }
      return false;
   }

   // 每 10 分鐘重新讀取日曆
   void Refresh()
   {
      datetime now = TimeTradeServer();
      if(m_lastLoad != 0 && now - m_lastLoad < 600) return;
      m_lastLoad = now;

      ArrayResize(m_time, 0);
      ArrayResize(m_cur,  0);
      ArrayResize(m_name, 0);

      MqlCalendarValue vals[];
      int n = CalendarValueHistory(vals, now - 3600, now + 86400);
      if(n <= 0)
      {
         if(!m_warned && !MQLInfoInteger(MQL_TESTER))
         {
            PrintFormat("⚠️ 新聞濾網：讀不到經濟日曆 (err=%d)，請確認 MT5 已連線且「工具→選項→伺服器」允許新聞", GetLastError());
            m_warned = true;
         }
         return;
      }

      for(int i=0; i<n; i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev)) continue;

         bool hi  = (ev.importance == CALENDAR_IMPORTANCE_HIGH);
         bool mid = (ev.importance == CALENDAR_IMPORTANCE_MODERATE);
         if(!hi && !(IncludeMedium && mid)) continue;

         MqlCalendarCountry c;
         if(!CalendarCountryById(ev.country_id, c)) continue;

         int k = ArraySize(m_time);
         ArrayResize(m_time, k+1);
         ArrayResize(m_cur,  k+1);
         ArrayResize(m_name, k+1);
         m_time[k] = vals[i].time;
         m_cur[k]  = c.currency;
         m_name[k] = ev.name;
      }
   }

   // 該商品目前是否在新聞時段；是的話 reason 回傳事件
   bool InWindow(string sym, string &reason, int extraBeforeMin = 0)
   {
      reason = "";
      string b, q;
      if(!Currencies(sym, b, q)) return false;
      b = CalCurrency(b);
      q = CalCurrency(q);

      datetime now = TimeTradeServer();
      for(int i=0; i<ArraySize(m_time); i++)
      {
         if(m_cur[i] != b && m_cur[i] != q) continue;
         datetime from = m_time[i] - (BeforeMin + extraBeforeMin) * 60;
         datetime to   = m_time[i] + AfterMin * 60;
         if(now >= from && now <= to)
         {
            reason = StringFormat("%s %s %s", m_cur[i], TimeToString(m_time[i], TIME_MINUTES), m_name[i]);
            return true;
         }
      }
      return false;
   }

   // 面板用：最近一個相關事件
   string NextEvent(string sym)
   {
      string b, q;
      if(!Currencies(sym, b, q)) return "";
      b = CalCurrency(b);
      q = CalCurrency(q);

      datetime now = TimeTradeServer();
      int best = -1;
      for(int i=0; i<ArraySize(m_time); i++)
      {
         if(m_cur[i] != b && m_cur[i] != q) continue;
         if(m_time[i] + AfterMin * 60 < now) continue;
         if(best < 0 || m_time[i] < m_time[best]) best = i;
      }
      if(best < 0) return "";
      return StringFormat("%s %s %s", m_cur[best], TimeToString(m_time[best], TIME_DATE|TIME_MINUTES), m_name[best]);
   }
};

#endif // NEWS_FILTER_MQH
//+------------------------------------------------------------------+
