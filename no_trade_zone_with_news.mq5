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

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Sym = StringLen(TradeSymbol)>0 ? TradeSymbol : _Symbol;
   trade.SetExpertMagicNumber(MagicNumber);
   EnsureRangeLabel();
   return(INIT_SUCCEEDED);
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
void FetchNewsFromFF()
{
   string url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json";
   uchar post[];          // empty request body
   uchar result[];        // response body
   string result_headers; // response headers

   int res = WebRequest("GET", url, "", "", 5000, post, 0, result, result_headers);

   if(res == -1)
   {
      PrintFormat("❌ WebRequest failed (%d)", GetLastError());
      return;
   }

   string json = CharArrayToString(result);

   string blockers[] = {"Payroll","FOMC","ECB","Fed","Retail Sales","Holiday"};

   for(int i=0; i<ArraySize(blockers); i++)
   {
      if(StringFind(json, blockers[i]) >= 0)
      {
         NO_TRADE_TODAY = true;
         PrintFormat("🚫 Blocker today: %s", blockers[i]);
         break;
      }
   }

   Print("📢 FF JSON snippet (first 200 chars):");
   Print(StringSubstr(json,0,200));
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
   if(!LondonClosed && dt.hour>=19)
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
      double aP=(AsiaHigh>AsiaLow? (AsiaHigh-AsiaLow)/(_Point*10.0):0.0);
      double nP=(NTZRange>0 ? NTZRange/(_Point*10.0) :0.0);
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
   if(dt.hour!=lastHour && dt.min==0)
   {
      lastHour=dt.hour;
      switch(dt.hour)
      {
         case 3:  DrawSessionSeparator(now,clrYellow,PREF_ASIAN); break;
         case 9:  DrawSessionSeparator(now,clrBlue,  PREF_FRANK); break;
         case 10: DrawSessionSeparator(now,clrGreen, PREF_LON);   break;
         case 16: DrawSessionSeparator(now,clrRed,   PREF_NY);    break;
      }
   }

   // 5) bail if blocked
   if(NO_TRADE_TODAY||DoNotTradeDay) return;

   // 6) build Asia 03–09
   if(dt.hour>=3 && dt.hour<9)
   {
      AsiaHigh=MathMax(AsiaHigh,iHigh(Sym,PERIOD_M1,0));
      AsiaLow =MathMin(AsiaLow, iLow (Sym,PERIOD_M1,0));
   }

   // 7) 09:00 NTZ start & threshold
   if(dt.hour==9 && dt.min==0 && frankOpen==0)
   {
      double aP=(AsiaHigh-AsiaLow)/(_Point*10.0);
      if(aP>AsiaThresholdPips)
      {
         DoNotTradeDay=true;
         PrintFormat("🛑 Asia %.1f pips > %d → halt",aP,AsiaThresholdPips);
      }
      frankOpen=now;
   }

   // 8) build NTZ 09–10
   if(frankOpen>0 && now<frankOpen+3600)
   {
      NTZHigh=MathMax(NTZHigh,iHigh(Sym,PERIOD_M1,0));
      NTZLow =MathMin(NTZLow, iLow (Sym,PERIOD_M1,0));
   }

   // 9) place stops 09:57–10:00
   if(frankOpen>0 && !OrdersPlaced
      && now>=frankOpen+57*60 && now<frankOpen+60*60)
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
         PrintFormat("✅ Orders placed — Asia:%.1f, NTZ:%.1f",
                     (AsiaHigh-AsiaLow)/(_Point*10.0),nP);
      }
      else
         PrintFormat("🛑 NTZ %.1f pips outside [10–30] → halt",nP);
   }


   // 10) cancel unfilled stops by 3h after frankOpen
   if(!PositionOpened        // **only if no fill yet**
      && OrdersPlaced        // stops are live
      && frankOpen>0
      && TimeCurrent()>=frankOpen+3*3600)
   {
      Print("⌛ 3h passed without fill → canceling stops");
      CancelPendingOrders();
   }

   // 11) TP ladder & detect fills
   if(NTZDefined) ManageTakeProfits();
   if(!PositionOpened && PositionSelect(Sym))
      PositionOpened=true;
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
   BuyTicket  = trade.BuyStop (LotSize,NTZHigh+_Point,Sym,NTZLow-_Point,0,0,Slippage);
   SellTicket = trade.SellStop(LotSize,NTZLow-_Point, Sym,NTZHigh+_Point,0,0,Slippage);
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