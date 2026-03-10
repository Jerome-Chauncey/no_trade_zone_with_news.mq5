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

//―――――――――― Inputs ――――――――――――――――――――――――――――――――――――――――――――
input string  TradeSymbol       = "";       // "" = current chart symbol
input double  LotSize           = 0.10;     // lots per trade
input int     Slippage          = 5;        // slippage in points
input int     MagicNumber       = 10101;    // EA magic number
input int     AsiaThresholdPips = 40;       // skip if Asia > this
input int     TargetCount       = 10;       // TP steps per side
input string  ExcludedDates     = "";       // back-test: "YYYY.MM.DD,..."

//―――――― Globals & State ――――――――――――――――――――――――――――――――――――――――――
CTrade    trade;
string    Sym;
bool SessionPrinted = false;


// pending-stop tickets we placed
ulong     BuyTicket       = 0;
ulong     SellTicket      = 0;

bool      NO_TRADE_TODAY  = false;  // blocked by CSV
bool      DoNotTradeDay   = false;  // Asia-too-big or manual
bool      LondonClosed    = false;  // have we run the 19:00 cleanup?
int       lastResetDate   = 0;      // YYYYMMDD

double    AsiaHigh = -DBL_MAX, AsiaLow = DBL_MAX;
double    NTZHigh  = -DBL_MAX, NTZLow  = DBL_MAX, NTZRange = 0.0;

double    TPLevels[21];
bool      TPTrig[21];

datetime  frankOpen      = 0;
bool      OrdersPlaced   = false;
bool      NTZDefined     = false;
bool      PositionOpened = false;
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
   Print("✔️ All pending STOP orders cleared");
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
   // Frankfurt starts 09:00
   if(dt.hour >= 9)  DrawSessionSeparator(todayStart + 9*3600, clrBlue, PREF_FRANK);
   // London starts 10:00
   if(dt.hour >= 10) DrawSessionSeparator(todayStart + 10*3600, clrGreen, PREF_LON);
   // New York starts 16:00
   if(dt.hour >= 16) DrawSessionSeparator(todayStart + 16*3600, clrRed, PREF_NY);

   // âœ… Backfill NTZ box if past 10:00
   
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
   AsiaStart     =GMTToBroker(0,0);    // 00:00 GMT
   FrankfurtOpen =GMTToBroker(7,0);    // 07:00 GMT
   LondonOpen    =GMTToBroker(8,0);    // 08:00 GMT
   NewYorkOpen   =GMTToBroker(13,0);   // 13:00 GMT
   LondonClose   =GMTToBroker(16,0);   // 16:00 GMT
}

int OnInit()
{
   BrokerGMTOffset=(int)(TimeCurrent()-TimeGMT());
   UpdateSessionTimes();
   
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


   // âœ… Immediately calculate Asian range up to now
   

   
   

   // âœ… Check todayâ€™s news immediately
   FetchNewsFromFF();
   if(NO_TRADE_TODAY) Print("ðŸ›‘ Halted for CSV blocker");

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
   if(now>=FrankfurtOpen)
   {
      AsiaHigh=-DBL_MAX;
      AsiaLow =DBL_MAX;

      int startBar=iBarShift(Sym,PERIOD_M1,AsiaStart,false);
      int endBar  =iBarShift(Sym,PERIOD_M1,FrankfurtOpen,false);

      for(int i=startBar;i>=endBar;i--)
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
   }

   // rebuild NTZ
   if(now>=LondonOpen)
   {
      NTZHigh=-DBL_MAX;
      NTZLow =DBL_MAX;

      int startBar=iBarShift(Sym,PERIOD_M1,FrankfurtOpen,false);
      int endBar  =iBarShift(Sym,PERIOD_M1,LondonOpen,false);

      for(int i=startBar;i>=endBar;i--)
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
   ClearDailyLines();
   ObjectDelete(0,OBJ_RANGE);
}

//+------------------------------------------------------------------+
//| Fetch news from Forex Factory JSON feed                         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Fetch news from Forex Factory JSON feed (filter by today)        |
//+------------------------------------------------------------------+
void FetchNewsFromFF()
{
   NO_TRADE_TODAY = false;

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

      // ---- ONLY HIGH IMPACT ----
      string impact = StringSubstr(ev, ipos + 10);
      int iend = StringFind(impact, "\"");
      if(iend > 0)
         impact = StringSubstr(impact, 0, iend);

      if(impact != "High")
         continue;

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

      // ---- TITLE EXTRACTION ----
      string title = StringSubstr(ev, tpos + 9);
      int endq = StringFind(title, "\"");
      if(endq > 0)
         title = StringSubstr(title, 0, endq);

      // ---- STRATEGY MATCH ----
      for(int j = 0; j < ArraySize(blockers); j++)
      {
         if(StringFind(title, blockers[j]) >= 0)
         {
            PrintFormat("NEWS BLOCKER TODAY (HIGH): %s | %s",
                        title,
                        TimeToString(evBroker, TIME_DATE|TIME_MINUTES));
            foundAny = true;
            break;
         }
      }
   }

   if(foundAny)
   {
      NO_TRADE_TODAY = true;
      Print("ðŸ›‘ Trading halted due to HIGH impact strategic news");
   }
   else
   {
      Print("No HIGH impact strategic blockers today");
   }
}









//+------------------------------------------------------------------+
//| Expert tick handler                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now=TimeCurrent(); MqlDateTime dt; TimeToStruct(now,dt);

   // 1) New-day reset
   int today=dt.year*10000+dt.mon*100+dt.day;
   if(today!=lastResetDate)
   {
      lastResetDate=today;
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

      CancelPendingOrders();
      ClearDailyLines();
      EnsureRangeLabel();

      
      FetchNewsFromFF();
      if(NO_TRADE_TODAY) Print("🛑 Halted for CSV blocker");

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
               PrintFormat("ℹ️ Halted for excluded %s",arr[i]);
               break;
            }
         }
      }
   }

   // 2) London-close flat @19:00
   if(!LondonClosed && now>=LondonClose)
   {
      CancelPendingOrders();
      if(PositionSelect(Sym))
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
      ClearDailyLines();
      LondonClosed=true;
      Print("✅ London-close flat & cleanup");
   }
   if(LondonClosed) return;  // stop until tomorrow

   // 3) update bottom-center range label
   {
      uint w=(uint)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_XDISTANCE,(int)w/2);
      double pip = SymbolInfoDouble(Sym,SYMBOL_POINT) * 10;
      double aP=(AsiaHigh>AsiaLow? (AsiaHigh-AsiaLow)/pip :0.0);
      double nP=(NTZRange>0 ? NTZRange/pip :0.0);
      string txt = StringFormat("📊 Asian Range: %.1f pips\n📊 NTZ Range: %.1f pips",aP,nP);
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

   // 6) build Asia 03–09
   if(now>=AsiaStart && now<FrankfurtOpen)
   {
      AsiaHigh=MathMax(AsiaHigh,iHigh(Sym,PERIOD_M1,0));
      AsiaLow=MathMin(AsiaLow,iLow(Sym,PERIOD_M1,0));
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
   

   // 8) build NTZ 09–10
   if(now>=FrankfurtOpen && now<LondonOpen)
   {
      NTZHigh=MathMax(NTZHigh,iHigh(Sym,PERIOD_M1,0));
      NTZLow=MathMin(NTZLow,iLow(Sym,PERIOD_M1,0));
   }
   

   // 9) place stops 09:57–10:00
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
   
         // 👉 Call NTZ box here
         DrawNTZBox();
   
         OrdersPlaced=true; 
         NTZDefined=true;
         PrintSessionSummary();
         PrintFormat("✅ Orders placed — Asia:%.1f, NTZ:%.1f",
                     (AsiaHigh-AsiaLow)/(_Point*10.0),nP);
      }
      else
         PrintFormat("🛑 NTZ %.1f pips outside [10–30] → halt",nP);
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

      PrintFormat("✅ Orders placed | BuyStop: %.5f vs Ask: %.5f | SellStop: %.5f vs Bid: %.5f",
                  buyStopPrice, ask, sellStopPrice, bid);
   }
   else
   {
      PrintFormat("🛑 Invalid stop levels — BuyStop: %.5f vs Ask: %.5f | SellStop: %.5f vs Bid: %.5f",
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
            PrintFormat("🔒 TP%d hit → SL=%.5f",i,newSL);
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