//+------------------------------------------------------------------+
//|                                    PriceInTimeEA.mq5            |
//|       Asian range + NTZ breakout + CSV no-trade skip + News     |
//|       session separators + TP ladder + auto London-close flat    |
//+------------------------------------------------------------------+
#property copyright   "2025 Jerome Chauncey / NTZ"
#property link        "https://github.com/Jerome-Chauncey"
#property version     "1.16"
#property strict


#include <Trade\Trade.mqh>

//â€•â€•â€•â€•â€•â€•â€•â€•â€•â€• Inputs â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•
input string  TradeSymbol       = "";       // "" = current chart symbol
input double  LotSize           = 0.10;     // lots per trade
input int     Slippage          = 5;        // slippage in points
input int     MagicNumber       = 10101;    // EA magic number
input int     AsiaThresholdPips = 40;       // skip if Asia > this
input int     TargetCount       = 10;       // TP steps per side
input string  ExcludedDates     = "";       // back-test: "YYYY.MM.DD,..."

//â€•â€•â€•â€•â€•â€• Globals & State â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•
CTrade    trade;
string    Sym;
bool SessionPrinted = false;
string TradeBlockReason = "None";


// pending-stop tickets we placed
ulong     BuyTicket       = 0;
ulong     SellTicket      = 0;

bool      NO_TRADE_TODAY  = false;  // blocked by CSV
bool      DoNotTradeDay   = false;  // Asia-too-big or manual
bool      LondonClosed    = false;  // have we run the 19:00 cleanup?
bool      DailyResetDone  = false;
int       lastResetDate   = 0;      // YYYYMMDD

double    AsiaHigh = -DBL_MAX, AsiaLow = DBL_MAX;
double    NTZHigh  = -DBL_MAX, NTZLow  = DBL_MAX, NTZRange = 0.0;

double    TPLevels[21];
bool      TPTrig[21];

datetime  frankOpen      = 0;
bool      OrdersPlaced   = false;
bool      NTZDefined     = false;
bool      PositionOpened = false;
datetime LastHeartbeat = 0;
double   LastAsiaHigh  = 0;
double   LastNTZHigh   = 0;
int       lastHour       = -1;

// object names
#define PREF_ASIAN     "SessAsian"
#define PREF_FRANK     "SessFrank"
#define PREF_LON       "SessLondon"
#define PREF_NY        "SessNY"
#define OBJ_HIGH       "NTZ_High"
#define OBJ_LOW        "NTZ_Low"
#define OBJ_INFO       "NTZ_Info"
#define OBJ_RANGE      "Asia_NTZ_Range"
#define OBJ_STATUS     "NTZ_Status"
#define OBJ_STATUS_BG  "NTZ_Status_BG"

//+------------------------------------------------------------------+
//| CSV blocker: skip on NFP, FOMC, ECB, Fed, Retail Sales, Holiday  |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Log every CSV event for today into Journal                      |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Clear all daily objects except the bottom-range label           |
//+------------------------------------------------------------------+
void ClearDailyLines()
{
   ObjectDelete(0,OBJ_HIGH);
   ObjectDelete(0,OBJ_LOW);
   ObjectDelete(0,OBJ_INFO);
   ObjectDelete(0, "NTZ_Box");
   for(int i=1;i<=TargetCount;i++)
   {
      ObjectDelete(0,StringFormat("TPB_%d",i));
      ObjectDelete(0,StringFormat("TPS_%d",i));
   }
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string nm=ObjectName(0,i);
      if(StringFind(nm,PREF_ASIAN)==0||
         StringFind(nm,PREF_FRANK)==0||
         StringFind(nm,PREF_LON)==0||
         StringFind(nm,PREF_NY)==0)
         ObjectDelete(0,nm);
   }
}

//+------------------------------------------------------------------+
//| Ensure bottom-center range label exists                         |
//+------------------------------------------------------------------+
void EnsureRangeLabel()
{
   if(ObjectFind(0,OBJ_RANGE)==-1)
   {
      ObjectCreate(0,OBJ_RANGE,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_CORNER,   CORNER_RIGHT_LOWER);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_COLOR,    clrWhite);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_YDISTANCE,20);
   }
}

//+------------------------------------------------------------------+
//| Cancel ANY and ALL pending stop orders on this symbol           |
//+------------------------------------------------------------------+
void CancelPendingOrders()
{
   // delete tickets we tracked
   if(BuyTicket>0)  { trade.OrderDelete(BuyTicket);  BuyTicket=0; }
   if(SellTicket>0) { trade.OrderDelete(SellTicket); SellTicket=0; }

   // sweep _all_ pending stops for our symbol
   int total=OrdersTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong tck=OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL)==Sym)
      {
         ENUM_ORDER_TYPE typ=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(typ==ORDER_TYPE_BUY_STOP||typ==ORDER_TYPE_SELL_STOP)
            trade.OrderDelete(tck);
      }
   }
   OrdersPlaced=false;
   Print("âœ”ï¸ All pending STOP orders cleared");
}

bool HasPendingStops()
{
   int total = OrdersTotal();

   for(int i=0;i<total;i++)
   {
      ulong ticket = OrderGetTicket(i);

      if(OrderGetString(ORDER_SYMBOL) == Sym)
      {
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

         if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
            return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
void InitSessionSeparatorsAndNTZ()
{
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);

   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   // Asia starts 03:00
   if(dt.hour >= 3)  DrawSessionSeparator(todayStart + 3*3600, clrYellow, PREF_ASIAN);
   // Frankfurt starts 10:00
   if(dt.hour >= 10) DrawSessionSeparator(todayStart + 10*3600, clrBlue, PREF_FRANK);

   // London starts 11:00
   if(dt.hour >= 11) DrawSessionSeparator(todayStart + 11*3600, clrGreen, PREF_LON);
   // New York starts 16:00
   if(dt.hour >= 16) DrawSessionSeparator(todayStart + 16*3600, clrRed, PREF_NY);

   // Ã¢Å“â€¦ Backfill NTZ box if past 10:00
   
}

//+------------------------------------------------------------------+
//| DST SAFE SESSION ENGINE                                          |
//+------------------------------------------------------------------+

int BrokerGMTOffset=0;

datetime AsiaStart;
datetime FrankfurtOpen;
datetime LondonOpen;
datetime NewYorkOpen;
datetime LondonClose;

datetime GMTToBroker(int hour,int minute=0)
{
   datetime gmtDay=StringToTime(TimeToString(TimeGMT(),TIME_DATE));
   datetime gmtTime=gmtDay+hour*3600+minute*60;
   return gmtTime+BrokerGMTOffset;
}

void UpdateSessionTimes()
{
   AsiaStart     = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " 02:00"); // Tokyo start
   FrankfurtOpen = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " 09:00"); // Frankfurt DST
   LondonOpen    = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " 10:00"); // London DST
   NewYorkOpen   = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " 15:00"); // New York DST
   LondonClose   = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " 18:00"); // London Close DST
}

int OnInit()
{
   BrokerGMTOffset=(int)(TimeCurrent()-TimeGMT());
   UpdateSessionTimes();
   EventSetTimer(60);
   
   Sym = StringLen(TradeSymbol)>0 ? TradeSymbol : _Symbol;
   trade.SetExpertMagicNumber(MagicNumber);
   
   EnsureRangeLabel();
   
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   lastResetDate = dt.year*10000 + dt.mon*100 + dt.day;
   
   NO_TRADE_TODAY=false;
   DoNotTradeDay =false;
   LondonClosed  =false;
   frankOpen     =0;
   OrdersPlaced  =false;
   NTZDefined    =false;
   PositionOpened=false;
   lastHour      =-1;
   
   AsiaHigh=-DBL_MAX;
   AsiaLow=DBL_MAX;
   NTZHigh=-DBL_MAX;
   NTZLow=DBL_MAX;
   NTZRange=0.0;
   
   CancelPendingOrders();
   ClearDailyLines();
   EnsureRangeLabel();
  
   
   RebuildSessionState();


   // Ã¢Å“â€¦ Immediately calculate Asian range up to now
   

   
   

   // Ã¢Å“â€¦ Check todayÃ¢â‚¬â„¢s news immediately
   FetchNewsFromFF();
   if(NO_TRADE_TODAY) Print("Ã°Å¸â€ºâ€˜ Halted for CSV blocker");

   return(INIT_SUCCEEDED);
}


void InitAsiaRange()
{
   AsiaHigh = -DBL_MAX;
   AsiaLow  = DBL_MAX;

   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);

   datetime asiaStart = StringToTime(StringFormat("%04d.%02d.%02d 03:00", dt.year, dt.mon, dt.day));

   int startBar = iBarShift(Sym, PERIOD_M1, asiaStart, false);
   int endBar   = iBarShift(Sym, PERIOD_M1, now, false);
   
   if(startBar == -1 || endBar == -1) return;
   
   if(startBar < endBar)
   {
      int tmp = startBar;
      startBar = endBar;
      endBar = tmp;
   }
   
   for(int i=startBar; i>=endBar; i--)
   {
      double hi = iHigh(Sym, PERIOD_M1, i);
      double lo = iLow (Sym, PERIOD_M1, i);
      if(hi>AsiaHigh) AsiaHigh=hi;
      if(lo<AsiaLow)  AsiaLow=lo;
   }
}

//+------------------------------------------------------------------+
//| Rebuild session ranges if EA starts mid-day                     |
//+------------------------------------------------------------------+
void RebuildSessionState()
{
   datetime now=TimeCurrent();
   
   // rebuild Asian range
   AsiaHigh=-DBL_MAX;
   AsiaLow =DBL_MAX;
   
   datetime asiaEnd = MathMin(TimeCurrent(), FrankfurtOpen);

      if(!EnsureM1History(AsiaStart))
      {
         Print("ERROR Cannot rebuild Asia range. Missing history.");
         return;
      }
      
      int startBar = iBarShift(Sym, PERIOD_M1, AsiaStart, false);
      int endBar   = iBarShift(Sym, PERIOD_M1, asiaEnd, false);
      
      if(startBar < endBar)
      {
         int tmp = startBar;
         startBar = endBar;
         endBar = tmp;
      }
      
      for(int i=startBar; i>=endBar; i--)
      {
         double hi=iHigh(Sym,PERIOD_M1,i);
         double lo=iLow(Sym,PERIOD_M1,i);

         if(hi>AsiaHigh) AsiaHigh=hi;
         if(lo<AsiaLow)  AsiaLow=lo;
      }

      double aP=(AsiaHigh-AsiaLow)/(_Point*10.0);

      if(aP>AsiaThresholdPips)
      {
         DoNotTradeDay=true;
         PrintFormat("Asia %.1f pips > %d halt",aP,AsiaThresholdPips);
      }
      Print("AsiaStart: ", TimeToString(AsiaStart));
      Print("FrankfurtOpen: ", TimeToString(FrankfurtOpen));
   

   // rebuild NTZ
   if(now>=LondonOpen)
   {
      NTZHigh=-DBL_MAX;
      NTZLow =DBL_MAX;

      if(!EnsureM1History(FrankfurtOpen))
      {
         Print("ERROR Cannot rebuild NTZ. Missing history.");
         return;
      }
      
      int startBar = iBarShift(Sym, PERIOD_M1, FrankfurtOpen, false);
      int endBar   = iBarShift(Sym, PERIOD_M1, LondonOpen, false);
      
      if(startBar < endBar)
      {
         int tmp = startBar;
         startBar = endBar;
         endBar = tmp;
      }
      
      for(int i=startBar; i>=endBar; i--)
      {
         double hi=iHigh(Sym,PERIOD_M1,i);
         double lo=iLow(Sym,PERIOD_M1,i);

         if(hi>NTZHigh) NTZHigh=hi;
         if(lo<NTZLow)  NTZLow=lo;
      }

      NTZRange=NTZHigh-NTZLow;
      double nP = NTZRange / (_Point*10.0);

      if(nP < 10.0 || nP > 30.0)
      {
         DoNotTradeDay = true;
         PrintFormat("NTZ %.1f pips outside [10-30]. No trade today.", nP);
      }
      NTZDefined=true;
      frankOpen=FrankfurtOpen;

      DrawNTZBox();
      PrintSessionSummary();
      
      if(HasPendingStops())
      {
         OrdersPlaced = true;
         Print("Existing pending orders detected. EA synchronized.");
      }
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ClearDailyLines();
   ObjectDelete(0,OBJ_RANGE);
   ObjectDelete(0,OBJ_STATUS);
   ObjectDelete(0,OBJ_STATUS_BG);
}

//+------------------------------------------------------------------+
//| Fetch Forex Factory News                                         |
//+------------------------------------------------------------------+
void FetchNewsFromFF()
{
   NO_TRADE_TODAY   = false;
   TradeBlockReason = "None";

   string url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json";
   uchar post[], result[];
   string headers;

   int res = WebRequest("GET", url, "", "", 10000, post, 0, result, headers);
   if(res == -1)
   {
      PrintFormat("WebRequest failed: %d", GetLastError());
      return;
   }

   string json = CharArrayToString(result);

   datetime nowBroker = TimeCurrent();
   MqlDateTime td;
   TimeToStruct(nowBroker, td);
   int todayKey = td.year*10000 + td.mon*100 + td.day;

   int brokerOffset = (int)(TimeCurrent() - TimeGMT());

   string blockers[] =
   {
      "Non-Farm",
      "Interest Rate",
      "Rate Decision",
      "Monetary Policy",
      "Policy Statement",
      "FOMC",
      "Fed",
      "ECB",
      "Central Bank",
      "Bank Holiday",
      "Holiday"
   };

   bool foundAny = false;

   string events[];
   int n = StringSplit(json, '{', events);

   for(int i = 0; i < n; i++)
   {
      string ev = events[i];

      int dpos = StringFind(ev, "\"date\":\"");
      int tpos = StringFind(ev, "\"title\":\"");
      int ipos = StringFind(ev, "\"impact\":\"");

      if(dpos < 0 || tpos < 0 || ipos < 0)
         continue;

      // ---- IMPACT ----
      string impact = StringSubstr(ev, ipos + 10);
      int iend = StringFind(impact, "\"");
      if(iend > 0)
         impact = StringSubstr(impact, 0, iend);

      // ---- TIME CONVERSION ----
      string fullDate = StringSubstr(ev, dpos + 8, 25);

      string base = StringSubstr(fullDate, 0, 19);
      string tz   = StringSubstr(fullDate, 19);

      datetime localTime = StringToTime(base);

      int sign  = (StringSubstr(tz, 0, 1) == "-" ? -1 : 1);
      int hours = (int)StringToInteger(StringSubstr(tz, 1, 2));
      int mins  = (int)StringToInteger(StringSubstr(tz, 4, 2));
      int tzOffset = sign * (hours*3600 + mins*60);

      datetime evUTC    = localTime - tzOffset;
      datetime evBroker = evUTC + brokerOffset;

      MqlDateTime evd;
      TimeToStruct(evBroker, evd);
      int evKey = evd.year*10000 + evd.mon*100 + evd.day;

      if(evKey != todayKey)
         continue;

      // ---- TITLE ----
      string title = StringSubstr(ev, tpos + 9);
      int endq = StringFind(title, "\"");
      if(endq > 0)
         title = StringSubstr(title, 0, endq);

      // ---- STRATEGY MATCH ----
      for(int j = 0; j < ArraySize(blockers); j++)
      {
         if(StringFind(title, blockers[j]) >= 0)
         {
            // ---- HOLIDAY BLOCK ----
            if(StringFind(title, "Holiday") >= 0 || 
               StringFind(title, "Bank Holiday") >= 0)
            {
               PrintFormat("HOLIDAY BLOCKER: %s | %s",
                           title,
                           TimeToString(evBroker, TIME_DATE|TIME_MINUTES));

               foundAny = true;
               TradeBlockReason = "Bank Holiday";
               break;
            }

            // ---- HIGH IMPACT BLOCK ----
            if(impact == "High")
            {
               PrintFormat("HIGH IMPACT BLOCKER: %s | %s",
                           title,
                           TimeToString(evBroker, TIME_DATE|TIME_MINUTES));

               foundAny = true;
               TradeBlockReason = "High Impact News";
               break;
            }
         }
      }

      if(foundAny)
         break;
   }

   // ---- FINAL DECISION ----
   if(foundAny)
   {
      NO_TRADE_TODAY = true;

      Print("Trading disabled today");
      Print("Reason: ", TradeBlockReason);
   }
   else
   {
      NO_TRADE_TODAY   = false;
      TradeBlockReason = "None";

      Print("No HIGH impact strategic blockers today");
   }
}

//+------------------------------------------------------------------+
//| Ensure M1 History Loaded                                         |
//+------------------------------------------------------------------+
bool EnsureM1History(datetime fromTime)
{
   int bars = iBars(Sym, PERIOD_M1);

   if(bars <= 0)
   {
      Print("WARNING No M1 bars available");
      return false;
   }

   int shift = iBarShift(Sym, PERIOD_M1, fromTime, false);

   if(shift == -1)
   {
      Print("Loading M1 history...");

      datetime now = TimeCurrent();

      MqlRates rates[];
      ArraySetAsSeries(rates,true);

      int copied = CopyRates(Sym, PERIOD_M1, fromTime, now, rates);

      if(copied <= 0)
      {
         Print("ERROR Failed to load M1 history");
         return false;
      }

      Sleep(200);

      shift = iBarShift(Sym, PERIOD_M1, fromTime, false);

      if(shift == -1)
      {
         Print("ERROR History still unavailable");
         return false;
      }

      Print("M1 history loaded successfully");
   }

   return true;
}

//+------------------------------------------------------------------+
//| Session Integrity Check                                          |
//+------------------------------------------------------------------+
void ValidateSessionState()
{
   static datetime lastCheck = 0;

   // Check once every 60 seconds
   if(TimeCurrent() - lastCheck < 60)
      return;

   lastCheck = TimeCurrent();

   bool rebuildNeeded = false;

   // Invalid Asia
   if(AsiaHigh == -DBL_MAX || AsiaLow == DBL_MAX)
      rebuildNeeded = true;

   // Invalid NTZ after London open
   if(TimeCurrent() >= LondonOpen)
   {
      if(NTZHigh == -DBL_MAX || NTZLow == DBL_MAX)
         rebuildNeeded = true;
   }

   // Invalid range
   if(AsiaHigh <= AsiaLow && TimeCurrent() >= FrankfurtOpen)
      rebuildNeeded = true;

   if(rebuildNeeded)
   {
      Print("WARNING Session state invalid. Rebuilding...");
      RebuildSessionState();
   }
}


//+------------------------------------------------------------------+
//| Debug Status Panel                                               |
//+------------------------------------------------------------------+
void UpdateStatusPanel()
{
   int x = 10;
   int y = 20;
   int line = 14;

   double pip = _Point * 10.0;
   double asiaP = (AsiaHigh>AsiaLow)?(AsiaHigh-AsiaLow)/pip:0;
   double ntzP  = (NTZRange>0)?NTZRange/pip:0;

   string eaStatus="ACTIVE";
   string asiaStatus="WAITING";
   string ntzStatus="WAITING";
   string tradeStatus="ENABLED";
   string orderStatus = OrdersPlaced ? "PLACED" : "NOT PLACED";

   datetime now=TimeCurrent();

   if(now>=AsiaStart && now<FrankfurtOpen)
      asiaStatus="BUILDING";
   else if(now>=FrankfurtOpen)
      asiaStatus="COMPLETE";

   if(now>=FrankfurtOpen && now<LondonOpen)
      ntzStatus="BUILDING";
   else if(now>=LondonOpen && NTZDefined)
      ntzStatus="COMPLETE";

   if(NO_TRADE_TODAY || DoNotTradeDay)
      tradeStatus="DISABLED";

   string tradeDay = (NO_TRADE_TODAY || DoNotTradeDay) ? "NO" : "YES";

   string lines[18];

   lines[0]  = "NTZ EA STATUS";
   lines[1]  = "---------------------------";
   lines[2]  = "EA Status      : " + eaStatus;
   lines[3]  = "Asia Session   : " + asiaStatus;
   lines[4]  = "NTZ Session    : " + ntzStatus;
   lines[5]  = "Orders         : " + orderStatus;
   lines[6]  = "Trading        : " + tradeStatus;
   lines[7]  = " ";
   lines[8]  = "Trade Day      : " + tradeDay;
   lines[9]  = "Reason         : " + TradeBlockReason;
   lines[10] = " ";
   lines[11] = "Ranges";
   lines[12] = "Asia Range     : " + DoubleToString(asiaP,1) + " pips";
   lines[13] = "NTZ Range      : " + DoubleToString(ntzP,1) + " pips";
   lines[14] = " ";
   lines[15] = "Session Times";
   lines[16] = "Asia " + TimeToString(AsiaStart,TIME_MINUTES);
   lines[17] = "London " + TimeToString(LondonOpen,TIME_MINUTES);

   int totalLines = ArraySize(lines);
   int panelHeight = (totalLines * line) + 20;

   // Background Panel
   if(ObjectFind(0,"NTZ_BG")==-1)
   {
      ObjectCreate(0,"NTZ_BG",OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_XSIZE,280);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_BGCOLOR,clrBlack);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_BORDER_COLOR,clrAqua);
   }

   // Dynamic height
   ObjectSetInteger(0,"NTZ_BG",OBJPROP_YSIZE,panelHeight);

   for(int i=0;i<totalLines;i++)
   {
      string name="NTZ_LINE_"+IntegerToString(i);

      if(ObjectFind(0,name)==-1)
      {
         ObjectCreate(0,name,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
         ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
         ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      }

      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x+10);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y+5+(i*line));
      ObjectSetString(0,name,OBJPROP_TEXT,lines[i]);
   }
}


//+------------------------------------------------------------------+
//| EA Watchdog                                                      |
//+------------------------------------------------------------------+
void WatchdogMonitor()
{
   static datetime lastCheck = 0;

   if(TimeCurrent() - lastCheck < 60)
      return;

   lastCheck = TimeCurrent();

   bool rebuild = false;

   // Asia stuck detection
   if(TimeCurrent() > AsiaStart && TimeCurrent() < FrankfurtOpen)
   {
      if(AsiaHigh == LastAsiaHigh)
      {
         Print("WATCHDOG: Asia range not updating. Rebuilding...");
         rebuild = true;
      }

      LastAsiaHigh = AsiaHigh;
   }

   // NTZ stuck detection
   if(TimeCurrent() > FrankfurtOpen && TimeCurrent() < LondonOpen)
   {
      if(NTZHigh == LastNTZHigh)
      {
         Print("WATCHDOG: NTZ range not updating. Rebuilding...");
         rebuild = true;
      }

      LastNTZHigh = NTZHigh;
   }

   // Invalid range detection
   if(AsiaHigh <= AsiaLow && TimeCurrent() > FrankfurtOpen)
   {
      Print("WATCHDOG: Invalid Asia range detected");
      rebuild = true;
   }

   if(rebuild)
   {
      Print("WATCHDOG: Rebuilding session state...");
      RebuildSessionState();
   }

   LastHeartbeat = TimeCurrent();
}

void Heartbeat()
{
   static datetime last = 0;

   if(TimeCurrent() - last >= 300)
   {
      Print("EA Heartbeat OK - ", TimeToString(TimeCurrent()));
      last = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Restart Recovery                                                 |
//+------------------------------------------------------------------+
void RestartRecovery()
{
   static bool recovered = false;

   if(recovered)
      return;

   // Check existing position
   if(PositionSelect(Sym))
   {
      PositionOpened = true;
      Print("Recovery: Existing position detected");
   }

   // Check pending orders
   if(HasPendingStops())
   {
      OrdersPlaced = true;
      Print("Recovery: Pending orders detected");
   }

   // Rebuild TP ladder if NTZ exists
   if(NTZHigh != -DBL_MAX && NTZLow != DBL_MAX)
   {
      NTZRange = NTZHigh - NTZLow;

      if(NTZRange > 0)
      {
         SetupTPLevels();
         DrawTPLevels();

         Print("Recovery: TP ladder rebuilt");
      }
   }

   recovered = true;
}

//+------------------------------------------------------------------+
//| Expert tick handler                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now=TimeCurrent(); MqlDateTime dt; TimeToStruct(now,dt);
   ValidateSessionState();
   WatchdogMonitor();
   Heartbeat();
   RestartRecovery();
   UpdateStatusPanel();
   if(LondonClosed && now >= AsiaStart && now < FrankfurtOpen)
   {
      LondonClosed = false;
      Print("New trading day started. EA reactivated.");
   }
   
   if(LondonClosed && now < AsiaStart)
   return;

   // 1) New-day reset
   int today=dt.year*10000+dt.mon*100+dt.day;
   if(today!=lastResetDate)
   {
      UpdateSessionTimes();
      lastResetDate=today;
      
      DailyResetDone = false;
      NO_TRADE_TODAY=false;
      DoNotTradeDay =false;
      LondonClosed  =false;
      frankOpen     =0;
      OrdersPlaced  =false;
      NTZDefined    =false;
      PositionOpened=false;
      SessionPrinted = false;
      lastHour      =-1;
      AsiaHigh=-DBL_MAX; AsiaLow=DBL_MAX;
      NTZHigh=-DBL_MAX; NTZLow=DBL_MAX; NTZRange=0.0;
      ArrayFill(TPTrig, 0, ArraySize(TPTrig), false);

      CancelPendingOrders();
      ClearDailyLines();
      EnsureRangeLabel();

      
      FetchNewsFromFF();
      if(NO_TRADE_TODAY) Print("ðŸ›‘ Halted for CSV blocker");

      if(!NO_TRADE_TODAY && StringLen(ExcludedDates)>0)
      {
         string arr[]; int cnt=StringSplit(ExcludedDates,',',arr);
         for(int i=0;i<cnt;i++)
         {
            datetime ex=StringToTime(arr[i]+" 00:00");
            MqlDateTime ed; TimeToStruct(ex,ed);
            if(ed.year==dt.year&&ed.mon==dt.mon&&ed.day==dt.day)
            {
               DoNotTradeDay=true;
               PrintFormat("â„¹ï¸ Halted for excluded %s",arr[i]);
               break;
            }
         }
      }
   }

   
   // 2) London-close flat @19:00 (Run once only)
   if(!DailyResetDone && now>=LondonClose)
   {
      CancelPendingOrders();
   
      if(PositionSelect(Sym))
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
   
      ClearDailyLines();
   
      // FULL RESET
      NO_TRADE_TODAY  = false;
      DoNotTradeDay   = false;
   
      frankOpen       = 0;
      OrdersPlaced    = false;
      NTZDefined      = false;
      PositionOpened  = false;
      SessionPrinted  = false;
      lastHour        = -1;
   
      AsiaHigh = -DBL_MAX;
      AsiaLow  = DBL_MAX;
   
      NTZHigh  = -DBL_MAX;
      NTZLow   = DBL_MAX;
      NTZRange = 0.0;
   
      ArrayFill(TPTrig, 0, ArraySize(TPTrig), false);
   
      UpdateSessionTimes();
   
      LondonClosed   = true;
      DailyResetDone = true;
   
      Print("London close cleanup + FULL RESET complete");
   }
   
   
   

   // 3) update bottom-center range label
   {
      uint w=(uint)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_XDISTANCE,(int)w/2);
      double pip = SymbolInfoDouble(Sym,SYMBOL_POINT) * 10;
      double aP=(AsiaHigh>AsiaLow? (AsiaHigh-AsiaLow)/pip :0.0);
      double nP=(NTZRange>0 ? NTZRange/pip :0.0);
      string txt = StringFormat("ðŸ“Š Asian Range: %.1f pips\nðŸ“Š NTZ Range: %.1f pips",aP,nP);
      ObjectSetString(0,OBJ_RANGE,OBJPROP_TEXT,txt);
      
      color c = clrWhite;
      if(aP > AsiaThresholdPips) c = clrRed;
      else if(nP >= 10 && nP <= 30) c = clrLime;
      else if(nP > 0) c = clrOrange;
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_COLOR,c);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_FONTSIZE,14);
   }

   // 4) session separators
   if(now>=AsiaStart && lastHour<1)
   {
      DrawSessionSeparator(AsiaStart,clrYellow,PREF_ASIAN);
      lastHour=1;
   }
   
   if(now>=FrankfurtOpen && lastHour<2)
   {
      DrawSessionSeparator(FrankfurtOpen,clrBlue,PREF_FRANK);
      lastHour=2;
   }
   
   if(now>=LondonOpen && lastHour<3)
   {
      DrawSessionSeparator(LondonOpen,clrGreen,PREF_LON);
      lastHour=3;
   }
   
   if(now>=NewYorkOpen && lastHour<4)
   {
      DrawSessionSeparator(NewYorkOpen,clrRed,PREF_NY);
      lastHour=4;
   }

   // 5) bail if blocked
   if(NO_TRADE_TODAY||DoNotTradeDay) return;

   // 6) build Asia 03â€“09
   if(now >= AsiaStart && now < FrankfurtOpen)
   {
      double hi = iHigh(Sym, PERIOD_M1, 1);
      double lo = iLow(Sym, PERIOD_M1, 1);
   
      if(hi > AsiaHigh) AsiaHigh = hi;
      if(lo < AsiaLow)  AsiaLow  = lo;
   }
   

   // 7) 09:00 NTZ start & threshold
   if(now>=FrankfurtOpen && frankOpen==0)
   {
      double aP=(AsiaHigh-AsiaLow)/(_Point*10.0);
   
      if(aP>AsiaThresholdPips)
      {
         DoNotTradeDay=true;
         PrintFormat("Asia %.1f pips > %d halt",aP,AsiaThresholdPips);
      }
   
      frankOpen=FrankfurtOpen;
   }
   

   // 8) build NTZ 09â€“10 (use closed candles for stability)
   if(now>=FrankfurtOpen && now<LondonOpen)
   {
      NTZHigh=MathMax(NTZHigh,iHigh(Sym,PERIOD_M1,1));
      NTZLow=MathMin(NTZLow,iLow(Sym,PERIOD_M1,1));
      
      static double lastLoggedNTZ = 0;

      double currentNTZ = (NTZHigh - NTZLow) / (_Point * 10.0);
      
      if(MathAbs(currentNTZ - lastLoggedNTZ) > 0.5)
      {
         PrintFormat("DEBUG NTZ Update | High: %.5f | Low: %.5f | Range: %.1f pips",
                     NTZHigh, NTZLow, currentNTZ);
      
         lastLoggedNTZ = currentNTZ;
      }
   }
   

   // 9) place stops 09:57â€“10:00
   if(frankOpen>0 && !OrdersPlaced && !HasPendingStops()
      && now>=LondonOpen-180 && now<LondonOpen)
   {
      NTZRange=NTZHigh-NTZLow;
      double nP=NTZRange/(_Point*10.0);
      if(ObjectFind(0,OBJ_HIGH)==-1) ObjectCreate(0,OBJ_HIGH,OBJ_HLINE,0,0,NTZHigh);
      if(ObjectFind(0,OBJ_LOW )==-1) ObjectCreate(0,OBJ_LOW, OBJ_HLINE,0,0,NTZLow);
      ObjectSetDouble(0,OBJ_HIGH,OBJPROP_PRICE,NTZHigh);
      ObjectSetDouble(0,OBJ_LOW, OBJPROP_PRICE,NTZLow);
   
      if(nP>=10.0 && nP<=30.0)
      {
         SetupTPLevels(); 
         PlacePendingOrders(); 
         DrawTPLevels();
   
         // ðŸ‘‰ Call NTZ box here
         DrawNTZBox();
   
         OrdersPlaced=true; 
         NTZDefined=true;
         PrintSessionSummary();
         PrintFormat("âœ… Orders placed â€” Asia:%.1f, NTZ:%.1f",
                     (AsiaHigh-AsiaLow)/(_Point*10.0),nP);
      }
      else
         PrintFormat("ðŸ›‘ NTZ %.1f pips outside [10â€“30] â†’ halt",nP);
   }


   // 10) cancel unfilled stops by 3h after frankOpen
   if(!PositionOpened
      && HasPendingStops()
      && frankOpen>0
      && TimeCurrent()>=frankOpen+3*3600)
   {
      Print("3 hours passed without fill. Canceling stops.");
      CancelPendingOrders();
   }

   // 11) TP ladder & detect fills
   if(NTZDefined) ManageTakeProfits();
   if(!PositionOpened && PositionSelect(Sym))
      PositionOpened=true;
}

void OnTimer()
{
   OnTick();
}

void PrintSessionSummary()
{
   if(SessionPrinted) return;

   if(AsiaHigh <= AsiaLow) return;
   if(NTZRange <= 0) return;   // wait until NTZ is defined

   double asiaPips = (AsiaHigh - AsiaLow) / (_Point * 10.0);
   double ntzPips  = NTZRange / (_Point * 10.0);

   PrintFormat("SESSION SUMMARY");
   PrintFormat("Asia High: %.5f | Asia Low: %.5f | Asia Range: %.1f pips",
               AsiaHigh, AsiaLow, asiaPips);

   PrintFormat("NTZ High: %.5f | NTZ Low: %.5f | NTZ Range: %.1f pips",
               NTZHigh, NTZLow, ntzPips);

   SessionPrinted = true;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void SetupTPLevels()
{
   ArrayFill(TPTrig,0,ArraySize(TPTrig),false);
   for(int i=1;i<=TargetCount;i++)
   {
      TPLevels[i]            = NTZHigh + i*NTZRange;
      TPLevels[i+TargetCount]= NTZLow  - i*NTZRange;
   }
}
void PlacePendingOrders()
{
   double ask = SymbolInfoDouble(Sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(Sym, SYMBOL_BID);

   double pip = _Point * 10.0;

   double buyStopPrice  = NTZHigh + pip;
   double sellStopPrice = NTZLow  - pip;

   // Validation check
   if(buyStopPrice > ask && sellStopPrice < bid)
   {
      BuyTicket  = trade.BuyStop(LotSize, buyStopPrice, Sym, sellStopPrice, 0, 0, Slippage);
      SellTicket = trade.SellStop(LotSize, sellStopPrice, Sym, buyStopPrice, 0, 0, Slippage);

      PrintFormat("âœ… Orders placed | BuyStop: %.5f vs Ask: %.5f | SellStop: %.5f vs Bid: %.5f",
                  buyStopPrice, ask, sellStopPrice, bid);
   }
   else
   {
      PrintFormat("ðŸ›‘ Invalid stop levels â€” BuyStop: %.5f vs Ask: %.5f | SellStop: %.5f vs Bid: %.5f",
                  buyStopPrice, ask, sellStopPrice, bid);
   }
}

void DrawTPLevels()
{
   for(int i=1;i<=TargetCount;i++)
   {
      string b=StringFormat("TPB_%d",i),
             s=StringFormat("TPS_%d",i);
      if(ObjectFind(0,b)==-1) {
         ObjectCreate(0,b,OBJ_HLINE,0,0,TPLevels[i]);
         ObjectSetString(0,b,OBJPROP_TEXT,StringFormat("TP Buy %d",i));
      }
      if(ObjectFind(0,s)==-1) {
         ObjectCreate(0,s,OBJ_HLINE,0,0,TPLevels[i+TargetCount]);
         ObjectSetString(0,s,OBJPROP_TEXT,StringFormat("TP Sell %d",i));
      }
   }
}


//+------------------------------------------------------------------+
//| Draw NTZ shaded rectangle                                        |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Draw NTZ shaded rectangle                                        |
//+------------------------------------------------------------------+
void DrawNTZBox()
{
   // Create rectangle if it doesn't exist
   if(ObjectFind(0,"NTZ_Box")==-1)
   {
      ObjectCreate(0,"NTZ_Box",OBJ_RECTANGLE,0,
                   frankOpen,NTZHigh,
                   frankOpen+3600,NTZLow);
   }
   else
   {
      // Update coordinates
      ObjectMove(0,"NTZ_Box",0,frankOpen,NTZHigh);
      ObjectMove(0,"NTZ_Box",1,frankOpen+3600,NTZLow);
   }

   // Style
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_COLOR,clrAqua);
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_WIDTH,1);
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_BACK,true);
}





void ManageTakeProfits()
{
   if(!PositionSelect(Sym)) return;
   ulong tk=PositionGetInteger(POSITION_TICKET);
   long  ty=PositionGetInteger(POSITION_TYPE);
   double pr=(ty==POSITION_TYPE_BUY
              ? SymbolInfoDouble(Sym,SYMBOL_BID)
              : SymbolInfoDouble(Sym,SYMBOL_ASK));
   for(int i=1;i<=TargetCount;i++)
   {
      if(!TPTrig[i])
      {
         bool hit=(ty==POSITION_TYPE_BUY&&pr>=TPLevels[i])
                 ||(ty==POSITION_TYPE_SELL&&pr<=TPLevels[i+TargetCount]);
         if(hit)
         {
            double newSL=(i==1
                          ? PositionGetDouble(POSITION_PRICE_OPEN)
                          : (ty==POSITION_TYPE_BUY? TPLevels[i-1]
                                                  : TPLevels[(i-1)+TargetCount]));
            trade.PositionModify(tk,newSL,PositionGetDouble(POSITION_TP));
            TPTrig[i]=true;
            PrintFormat("ðŸ”’ TP%d hit â†’ SL=%.5f",i,newSL);
            break;
         }
      }
   }
}
void DrawSessionSeparator(datetime t,color c,string p)
{
   string nm=p+TimeToString(t,TIME_DATE|TIME_MINUTES);
   if(ObjectFind(0,nm)==-1)
   {
      ObjectCreate(0,nm,OBJ_VLINE,0,t,0);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
      ObjectSetInteger(0,nm,OBJPROP_WIDTH,2);
   }
}
//+------------------------------------------------------------------+