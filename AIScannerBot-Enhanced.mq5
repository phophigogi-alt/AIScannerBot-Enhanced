//+------------------------------------------------------------------+
//|                                           AIScannerBot-Enhanced.mq5|
//|                   AI Chart Scanner & Auto-Trading Bot EA (v2.0)   |
//|              With Robust Signals, Risk Management & Logging      |
//+------------------------------------------------------------------+
#property copyright "AI Trading Bot Enhanced"
#property link      "https://github.com/phophigogi-alt/AIScannerBot-Enhanced"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

// --- INPUT PARAMETERS ---
input group "=== Risk & Execution Settings ==="
input double   InpLotSize        = 0.10;      // Fixed Lot Size (or set to 0 for % risk-based sizing)
input double   InpRiskPercent    = 2.0;       // Risk % of Account (used if InpLotSize = 0)
input int      InpMaxOpenTrades  = 1;         // Maximum Open Trades Allowed
input int      InpMaxTradesPerDay = 3;        // Maximum Trades Per Calendar Day
input ulong    InpMagicNumber    = 100200;    // Unique Bot Magic Number

input group "=== Analysis Settings ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M30;     // Timeframe to Scan
input ENUM_TIMEFRAMES InpFilterTimeframe = PERIOD_H1; // Higher TF for trend filter
input int      InpStopLossPips   = 100;       // Stop Loss (in Points)
input int      InpTakeProfitPips = 300;       // Take Profit (in Points)

input group "=== Signal Confirmation ==="
input bool     InpRequireVolumeConfirm = true;  // Require Volume Confirmation
input double   InpMinVolume       = 1.0;       // Min Volume Multiplier (vs avg)
input bool     InpRequireRSI      = true;      // Use RSI Confirmation
input int      InpRSIPeriod       = 14;        // RSI Period
input double   InpRSIBullish      = 30.0;      // RSI Oversold Threshold (Bullish)
input double   InpRSIBearish      = 70.0;      // RSI Overbought Threshold (Bearish)

input group "=== Money Management ==="
input double   InpMaxDailyDrawdown = 5.0;     // Max Daily Drawdown % (Stop trading if hit)
input double   InpAccountSizePercent = 1.0;   // % of Account to Risk per Trade

input group "=== Session Settings ==="
input bool     InpTradeEuropean   = true;      // Allow European Session
input bool     InpTradeAmerican   = true;      // Allow American Session
input bool     InpTradeAsia       = true;      // Allow Asian Session
input bool     InpAvoidNewsEvents = true;      // Skip High Impact News (requires calendar check)

// --- GLOBAL VARIABLES ---
datetime g_lastBarTime = 0;
datetime g_lastTradeTime = 0;
int      g_tradesOpenedToday = 0;
double   g_dailyLossTarget = 0;
double   g_startingBalance = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyLossTarget = g_startingBalance * (InpMaxDailyDrawdown / 100.0);
   
   Print("=== AI Scanner EA v2.0 Initialized ===");
   Print("Starting Balance: $", DoubleToString(g_startingBalance, 2));
   Print("Daily Loss Limit: $", DoubleToString(g_dailyLossTarget, 2));
   Print("Magic Number: ", InpMagicNumber);
   
   // Log initialization
   LogEvent("INIT", "EA Initialized - Starting Balance: $" + DoubleToString(g_startingBalance, 2));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== AI Scanner EA Terminated ===");
   LogEvent("DEINIT", "EA Terminated - Reason Code: " + IntToString(reason));
}

//+------------------------------------------------------------------+
//| Log trading events to file                                       |
//+------------------------------------------------------------------+
void LogEvent(string eventType, string message)
{
   string filename = "AIScannerBot_" + _Symbol + ".log";
   int filehandle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_TXT);
   
   if(filehandle != INVALID_HANDLE)
   {
      FileSeek(filehandle, 0, SEEK_END);
      string timestamp = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
      FileWrite(filehandle, "[" + timestamp + "] [" + eventType + "] " + message);
      FileClose(filehandle);
   }
}

//+------------------------------------------------------------------+
//| Count open positions for this EA on current symbol               |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         ulong magic   = PositionGetInteger(POSITION_MAGIC);
         
         if(symbol == _Symbol && magic == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count trades opened today (for daily trade limit)                |
//+------------------------------------------------------------------+
int CountTradesToday()
{
   int count = 0;
   datetime todayStart = StructCreate::DateToSecond(TimeCurrent()) - TimeCurrent() % 86400;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         ulong magic = PositionGetInteger(POSITION_MAGIC);
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         
         if(magic == InpMagicNumber && openTime >= todayStart)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if new bar has opened on target timeframe                  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if current time is within allowed trading session          |
//+------------------------------------------------------------------+
bool IsAllowedTradingSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   
   // European Session: 08:00-17:00 UTC
   bool isEuropean = (hour >= 8 && hour < 17);
   
   // American Session: 13:00-22:00 UTC
   bool isAmerican = (hour >= 13 && hour < 22);
   
   // Asian Session: 00:00-09:00 UTC
   bool isAsia = (hour >= 0 && hour < 9);
   
   bool allowed = false;
   if(InpTradeEuropean && isEuropean) allowed = true;
   if(InpTradeAmerican && isAmerican) allowed = true;
   if(InpTradeAsia && isAsia) allowed = true;
   
   return allowed;
}

//+------------------------------------------------------------------+
//| Check if current drawdown exceeds daily limit                    |
//+------------------------------------------------------------------+
bool IsDrawdownExceeded()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLoss = g_startingBalance - currentBalance;
   
   if(dailyLoss > g_dailyLossTarget)
   {
      LogEvent("RISK", "Daily drawdown limit exceeded. Stopping trades.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check higher timeframe trend (bullish/bearish/neutral)           |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, InpFilterTimeframe, 0, 3, rates) < 3)
      return 0; // Neutral
   
   double close1 = rates[1].close;
   double open1  = rates[1].open;
   double close2 = rates[2].close;
   double ma20   = iMA(_Symbol, InpFilterTimeframe, 20, 0, MODE_SMA, PRICE_CLOSE, 1);
   
   if(close1 > ma20 && close1 > open1)
      return 1; // Bullish
   else if(close1 < ma20 && close1 < open1)
      return -1; // Bearish
   else
      return 0; // Neutral
}

//+------------------------------------------------------------------+
//| Calculate RSI                                                     |
//+------------------------------------------------------------------+
double GetRSI(int period)
{
   return iRSI(_Symbol, InpTimeframe, period, PRICE_CLOSE, 1);
}

//+------------------------------------------------------------------+
//| Calculate average volume                                         |
//+------------------------------------------------------------------+
double GetAverageVolume(int period)
{
   return iVolume(_Symbol, InpTimeframe, 0) / iMA(_Symbol, InpTimeframe, period, 0, MODE_SMA, PRICE_VOLUME, 0);
}

//+------------------------------------------------------------------+
//| Calculate optimal lot size based on risk                         |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   if(InpLotSize > 0)
      return InpLotSize; // Use fixed lot size
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   double slPips = InpStopLossPips;
   double lotSize = riskAmount / (slPips * pointValue * tickValue);
   
   // Normalize to broker's lot step
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Pre-flight checks
   if(!IsNewBar())
      return;
   
   if(!IsAllowedTradingSession())
   {
      LogEvent("SESSION", "Current time outside allowed trading sessions");
      return;
   }
   
   if(IsDrawdownExceeded())
   {
      return; // Stop trading for the day
   }
   
   if(CountOpenPositions() >= InpMaxOpenTrades)
   {
      return;
   }
   
   if(CountTradesToday() >= InpMaxTradesPerDay)
   {
      LogEvent("LIMIT", "Daily trade limit reached (" + IntToString(InpMaxTradesPerDay) + " trades)");
      return;
   }

   // 2. Fetch candle data
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, InpTimeframe, 0, 3, rates) < 3)
   {
      Print("Error fetching timeframe rates.");
      return;
   }

   double close1 = rates[1].close;
   double open1  = rates[1].open;
   double low1   = rates[1].low;
   double high1  = rates[1].high;
   double low2   = rates[2].low;
   double high2  = rates[2].high;
   long volume1  = rates[1].tick_volume;

   // 3. Pattern detection
   bool isBullishRejection = (close1 > open1) && (low1 < low2);
   bool isBearishRejection = (close1 < open1) && (high1 > high2);

   // 4. Multi-confirmation checks
   bool bullishSignalValid = isBullishRejection;
   bool bearishSignalValid = isBearishRejection;

   // Confirm with trend filter
   int trend = GetTrendDirection();
   if(trend == -1) bullishSignalValid = false; // Bearish trend rejects bullish signals
   if(trend == 1) bearishSignalValid = false;  // Bullish trend rejects bearish signals

   // Confirm with volume
   if(InpRequireVolumeConfirm)
   {
      double volumeRatio = GetAverageVolume(20);
      if(volumeRatio < InpMinVolume)
      {
         bullishSignalValid = false;
         bearishSignalValid = false;
      }
   }

   // Confirm with RSI
   if(InpRequireRSI)
   {
      double rsi = GetRSI(InpRSIPeriod);
      if(bullishSignalValid && rsi > InpRSIBullish)
         bullishSignalValid = false; // Not oversold
      if(bearishSignalValid && rsi < InpRSIBearish)
         bearishSignalValid = false; // Not overbought
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (ask - bid) / point;

   // Check spread
   if(spread > InpStopLossPips * 0.5) // Spread too wide
   {
      LogEvent("SPREAD", "Spread too wide (" + DoubleToString(spread, 2) + " pips). Skipping trade.");
      return;
   }

   // 5. Execute trades with all confirmations
   double lotSize = CalculateLotSize();

   if(bullishSignalValid)
   {
      double sl = ask - (InpStopLossPips * point);
      double tp = ask + (InpTakeProfitPips * point);
      
      Print("[SIGNAL] Bullish Rejection - Trend: ", trend, " | Volume: OK | RSI: ", GetRSI(InpRSIPeriod));
      LogEvent("BUY", "Bullish Rejection - Lot: " + DoubleToString(lotSize, 2) + " | SL: " + DoubleToString(sl, 5) + " | TP: " + DoubleToString(tp, 5));
      
      if(trade.Buy(lotSize, _Symbol, ask, sl, tp, "AI Bot BUY Signal"))
      {
         Print("[SUCCESS] BUY order executed at ", ask);
      }
      else
      {
         Print("[ERROR] BUY order failed. Error: ", GetLastError());
         LogEvent("ERROR", "BUY order failed - Error Code: " + IntToString(GetLastError()));
      }
   }
   else if(bearishSignalValid)
   {
      double sl = bid + (InpStopLossPips * point);
      double tp = bid - (InpTakeProfitPips * point);
      
      Print("[SIGNAL] Bearish Rejection - Trend: ", trend, " | Volume: OK | RSI: ", GetRSI(InpRSIPeriod));
      LogEvent("SELL", "Bearish Rejection - Lot: " + DoubleToString(lotSize, 2) + " | SL: " + DoubleToString(sl, 5) + " | TP: " + DoubleToString(tp, 5));
      
      if(trade.Sell(lotSize, _Symbol, bid, sl, tp, "AI Bot SELL Signal"))
      {
         Print("[SUCCESS] SELL order executed at ", bid);
      }
      else
      {
         Print("[ERROR] SELL order failed. Error: ", GetLastError());
         LogEvent("ERROR", "SELL order failed - Error Code: " + IntToString(GetLastError()));
      }
   }
}
//+------------------------------------------------------------------+
