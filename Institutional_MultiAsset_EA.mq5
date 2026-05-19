//+------------------------------------------------------------------+
//| Institutional_MultiAsset_EA.mq5                     |
//+------------------------------------------------------------------+
#property strict
#property version "14.23"

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_MARKET_MODE { MODE_RANGE=0, MODE_TREND=1, MODE_EXPANSION=2 };
enum ENUM_DIRECTION   { DIR_NONE=0, DIR_BUY=1, DIR_SELL=-1 };
enum ENUM_SL_MODE     { SL_FIXED=0, SL_SWING=1, SL_ATR=2 };

input group "--- General ---"
input ENUM_TIMEFRAMES EntryTF = PERIOD_M15;
input ENUM_TIMEFRAMES HTF_TF  = PERIOD_H1;
input ulong MagicNumber = 14021;
input int SlippagePoints = 30;
input bool AllowBuy = true;
input bool AllowSell = true;

input group "--- Spread ---"
input bool UseDynamicSpread = true;
input int MaxSpreadPoints = 250;
input double DynamicSpreadATRPercent = 0.15;

input group "--- Sessions ---"
input bool UseSessionFilter = true;
input bool UseSession1 = true;
input int Session1StartHour = 9;
input int Session1EndHour   = 11;
input bool UseSession2 = true;
input int Session2StartHour = 15;
input int Session2EndHour   = 18;

input group "--- News Protection Manual ---"
input bool UseNewsFilter = false;
input int NewsHour1 = 15;
input int NewsMinute1 = 30;
input int NewsBlockMinutesBefore = 30;
input int NewsBlockMinutesAfter  = 30;

input group "--- Market Mode ---"
input int ADX_Period = 14;
input double ADX_RangeLevel = 18.0;
input double ADX_ExpansionLevel = 32.0;

input group "--- ATR / Volatility ---"
input int ATR_Period = 14;
input double ATRExpansionMultiplier = 1.10;
input double MomentumATRMultiplier = 1.20;

input group "--- Structure / Liquidity ---"
input int StructureLookback = 80;
input int SweepLookback = 20;
input double SweepBufferPoints = 30;
input int MSSLookback = 6;
input bool UsePremiumDiscount = true;

input group "--- SL / Risk ---"
input ENUM_SL_MODE SL_Mode = SL_SWING;
input double FixedSLPoints = 800;
input int SwingLookback = 12;
input ENUM_TIMEFRAMES SwingSL_TF = PERIOD_H1; // higher timeframe for swing SL
input double SL_ATR_Multiplier = 2.5;
input double SL_BufferPoints = 50;
input double SL_AdjustPoints = 0; // + wider SL, - tighter SL
input bool UseDynamicRisk = true;
input double FixedLot = 0.01;
input double RiskRange = 0.30;
input double RiskTrend = 0.50;
input double RiskExpansion = 0.70;

input group "--- Adaptive RR / Basket TP ---"
input double Range_RR = 1.20;
input double Trend_RR = 2.50;
input double Expansion_RR = 4.00;
input double TP_RR_Multiplier = 0.90; // <1 closer TP, >1 farther TP
input double TP_AdjustPoints = 0; // + farther TP, - closer TP
input bool CloseBasketAtCommonTP = true;

input group "--- Basket Trailing Stop ---"
input bool EnableBasketTrailing = true;
input double TrailStartR = 1.20;
input double TrailDistanceR = 0.70;
input double TrailStepPoints = 50;

input group "--- Loss-Based Pyramid Basket Entry ---"
input bool UsePyramidBasket = true;
input int MaxPyramidEntries = 3;
input double PyramidLotScale1 = 0.50; // first position must be smallest
input double PyramidLotScale2 = 1.00;
input double PyramidLotScale3 = 1.50;
input double LossAddStepR1 = 0.35;
input double LossAddStepR2 = 0.70;
input double MaxBasketRiskPercent = 1.0;

input group "--- Basket Protection ---"
input bool MoveBasketSLToBE = false;
input double MoveBEAfterR = 1.0;
input double BEBufferPoints = 20;

input group "--- Visuals ---"
input bool DrawSignals = true;

int adxHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

ENUM_MARKET_MODE activeMode = MODE_RANGE;
double activeRR = 1.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   adxHandle = iADX(_Symbol, HTF_TF, ADX_Period);
   atrHandle = iATR(_Symbol, EntryTF, ATR_Period);

   if(adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
     {
      Print("Indicator handle error");
      return INIT_FAILED;
     }

   Print("NDS v14.22 Loss Pyramid Basket Common SL/TP Loaded");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(adxHandle != INVALID_HANDLE)
      IndicatorRelease(adxHandle);

   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   activeMode = GetMarketMode();
   activeRR = GetRRByMode(activeMode);

   ManageBasketExit();
   ManageBasketBE();
   ManageBasketTrailing();
   ManagePyramidEntries();

   if(!IsNewBar())
      return;
   if(!IsTradingSession())
      return;
   if(!NewsOK())
      return;
   if(!SpreadOK())
      return;

   if(CountBasketPositions() > 0)
      return;

   bool buySignal = BuySignal();
   bool sellSignal = SellSignal();

   if(buySignal && AllowBuy)
      OpenPyramidBuy(1);

   if(sellSignal && AllowSell)
      OpenPyramidSell(1);
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, EntryTF, 0);

   if(t != lastBarTime)
     {
      lastBarTime = t;
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
double GetATR()
  {
   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(atrHandle, 0, 0, 20, atr) < 20)
      return 0.0;

   return atr[1];
  }

//+------------------------------------------------------------------+
ENUM_MARKET_MODE GetMarketMode()
  {
   double adx[];
   ArraySetAsSeries(adx, true);

   if(CopyBuffer(adxHandle, 0, 0, 3, adx) < 3)
      return MODE_RANGE;

   double value = adx[1];

   if(value >= ADX_ExpansionLevel)
      return MODE_EXPANSION;

   if(value >= ADX_RangeLevel)
      return MODE_TREND;

   return MODE_RANGE;
  }

//+------------------------------------------------------------------+
double GetRRByMode(ENUM_MARKET_MODE mode)
  {
   if(mode == MODE_RANGE)
      return Range_RR;

   if(mode == MODE_EXPANSION)
      return Expansion_RR;

   return Trend_RR;
  }

//+------------------------------------------------------------------+
double GetRiskByMode(ENUM_MARKET_MODE mode)
  {
   if(mode == MODE_RANGE)
      return RiskRange;

   if(mode == MODE_EXPANSION)
      return RiskExpansion;

   return RiskTrend;
  }

//+------------------------------------------------------------------+
bool SpreadOK()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPoints = (ask - bid) / _Point;

   if(!UseDynamicSpread)
      return spreadPoints <= (double)MaxSpreadPoints;

   double atr = GetATR();

   if(atr <= 0.0)
      return spreadPoints <= (double)MaxSpreadPoints;

   double dynamicLimit = (atr / _Point) * DynamicSpreadATRPercent;
   double finalLimit = MathMin((double)MaxSpreadPoints, dynamicLimit);

   return spreadPoints <= finalLimit;
  }

//+------------------------------------------------------------------+
bool IsTradingSession()
  {
   if(!UseSessionFilter)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   int hour = (int)tm.hour;

   bool s1 = false;
   bool s2 = false;

   if(UseSession1)
      s1 = (hour >= Session1StartHour && hour < Session1EndHour);

   if(UseSession2)
      s2 = (hour >= Session2StartHour && hour < Session2EndHour);

   return s1 || s2;
  }

//+------------------------------------------------------------------+
bool NewsOK()
  {
   if(!UseNewsFilter)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   int currentMinutes = (int)tm.hour * 60 + (int)tm.min;
   int newsMinutes = NewsHour1 * 60 + NewsMinute1;

   int from = newsMinutes - NewsBlockMinutesBefore;
   int to = newsMinutes + NewsBlockMinutesAfter;

   return !(currentMinutes >= from && currentMinutes <= to);
  }

//+------------------------------------------------------------------+
ENUM_DIRECTION GetHTFDirection()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(_Symbol, HTF_TF, 0, StructureLookback, rates);

   if(copied < 30)
      return DIR_NONE;

   double recentHigh = rates[1].high;
   double recentLow = rates[1].low;
   double oldHigh = rates[StructureLookback - 1].high;
   double oldLow = rates[StructureLookback - 1].low;

   if(recentHigh > oldHigh && recentLow > oldLow)
      return DIR_BUY;

   if(recentHigh < oldHigh && recentLow < oldLow)
      return DIR_SELL;

   return DIR_NONE;
  }

//+------------------------------------------------------------------+
bool InDiscount()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(_Symbol, HTF_TF, 0, StructureLookback, rates);

   if(copied < 30)
      return false;

   double high = rates[1].high;
   double low = rates[1].low;

   for(int i = 2; i < copied; i++)
     {
      if(rates[i].high > high)
         high = rates[i].high;

      if(rates[i].low < low)
         low = rates[i].low;
     }

   double eq = (high + low) / 2.0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   return price <= eq;
  }

//+------------------------------------------------------------------+
bool InPremium()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(_Symbol, HTF_TF, 0, StructureLookback, rates);

   if(copied < 30)
      return false;

   double high = rates[1].high;
   double low = rates[1].low;

   for(int i = 2; i < copied; i++)
     {
      if(rates[i].high > high)
         high = rates[i].high;

      if(rates[i].low < low)
         low = rates[i].low;
     }

   double eq = (high + low) / 2.0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   return price >= eq;
  }

//+------------------------------------------------------------------+
bool ATRExpansionOK()
  {
   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(atrHandle, 0, 0, 20, atr) < 20)
      return false;

   double atrNow = atr[1];
   double avg = 0.0;

   for(int i = 2; i < 12; i++)
      avg += atr[i];

   avg /= 10.0;

   return atrNow >= avg * ATRExpansionMultiplier;
  }

//+------------------------------------------------------------------+
bool MomentumBurstBuy()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);

   if(CopyRates(_Symbol, EntryTF, 0, 5, r) < 5)
      return false;

   double atr = GetATR();

   if(atr <= 0.0)
      return false;

   double body = MathAbs(r[1].close - r[1].open);

   return r[1].close > r[1].open && body >= atr * MomentumATRMultiplier;
  }

//+------------------------------------------------------------------+
bool MomentumBurstSell()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);

   if(CopyRates(_Symbol, EntryTF, 0, 5, r) < 5)
      return false;

   double atr = GetATR();

   if(atr <= 0.0)
      return false;

   double body = MathAbs(r[1].close - r[1].open);

   return r[1].close < r[1].open && body >= atr * MomentumATRMultiplier;
  }

//+------------------------------------------------------------------+
bool BullishSweepRecovery()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);

   int copied = CopyRates(_Symbol, EntryTF, 0, SweepLookback + 5, r);

   if(copied < SweepLookback + 5)
      return false;

   double lowest = r[2].low;

   for(int i = 3; i <= SweepLookback + 1; i++)
     {
      if(r[i].low < lowest)
         lowest = r[i].low;
     }

   bool sweep = r[1].low < lowest - SweepBufferPoints * _Point;
   bool reclaim = r[1].close > lowest;
   bool bullish = r[1].close > r[1].open;

   return sweep && reclaim && bullish;
  }

//+------------------------------------------------------------------+
bool BearishSweepRecovery()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);

   int copied = CopyRates(_Symbol, EntryTF, 0, SweepLookback + 5, r);

   if(copied < SweepLookback + 5)
      return false;

   double highest = r[2].high;

   for(int i = 3; i <= SweepLookback + 1; i++)
     {
      if(r[i].high > highest)
         highest = r[i].high;
     }

   bool sweep = r[1].high > highest + SweepBufferPoints * _Point;
   bool reclaim = r[1].close < highest;
   bool bearish = r[1].close < r[1].open;

   return sweep && reclaim && bearish;
  }

//+------------------------------------------------------------------+
bool BullishMSS()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);

   int copied = CopyRates(_Symbol, EntryTF, 0, MSSLookback + 5, r);

   if(copied < MSSLookback + 5)
      return false;

   double high = r[2].high;

   for(int i = 3; i <= MSSLookback + 1; i++)
     {
      if(r[i].high > high)
         high = r[i].high;
     }

   return r[1].close > high;
  }

//+------------------------------------------------------------------+
bool BearishMSS()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);

   int copied = CopyRates(_Symbol, EntryTF, 0, MSSLookback + 5, r);

   if(copied < MSSLookback + 5)
      return false;

   double low = r[2].low;

   for(int i = 3; i <= MSSLookback + 1; i++)
     {
      if(r[i].low < low)
         low = r[i].low;
     }

   return r[1].close < low;
  }

//+------------------------------------------------------------------+
bool BuySignal()
  {
   ENUM_DIRECTION dir = GetHTFDirection();

   if(dir != DIR_BUY)
      return false;

   if(UsePremiumDiscount && activeMode != MODE_EXPANSION && !InDiscount())
      return false;

   if(activeMode == MODE_RANGE)
      return BullishSweepRecovery() && BullishMSS();

   if(activeMode == MODE_TREND)
      return BullishSweepRecovery() && BullishMSS() && ATRExpansionOK();

   if(activeMode == MODE_EXPANSION)
      return MomentumBurstBuy() && ATRExpansionOK();

   return false;
  }

//+------------------------------------------------------------------+
bool SellSignal()
  {
   ENUM_DIRECTION dir = GetHTFDirection();

   if(dir != DIR_SELL)
      return false;

   if(UsePremiumDiscount && activeMode != MODE_EXPANSION && !InPremium())
      return false;

   if(activeMode == MODE_RANGE)
      return BearishSweepRecovery() && BearishMSS();

   if(activeMode == MODE_TREND)
      return BearishSweepRecovery() && BearishMSS() && ATRExpansionOK();

   if(activeMode == MODE_EXPANSION)
      return MomentumBurstSell() && ATRExpansionOK();

   return false;
  }

//+------------------------------------------------------------------+
double CalculateSL(bool isBuy, double entry)
  {
   double sl = 0.0;
   double atr = GetATR();

   if(SL_Mode == SL_FIXED)
     {
      if(isBuy)
         sl = entry - FixedSLPoints * _Point;
      else
         sl = entry + FixedSLPoints * _Point;
     }
   else
      if(SL_Mode == SL_ATR)
        {
         if(atr <= 0.0)
           {
            if(isBuy)
               sl = entry - FixedSLPoints * _Point;
            else
               sl = entry + FixedSLPoints * _Point;
           }
         else
           {
            if(isBuy)
               sl = entry - atr * SL_ATR_Multiplier;
            else
               sl = entry + atr * SL_ATR_Multiplier;
           }
        }
      else
        {
         MqlRates r[];
         ArraySetAsSeries(r, true);

         if(CopyRates(_Symbol, SwingSL_TF, 0, SwingLookback + 5, r) < SwingLookback + 5)
           {
            if(isBuy)
               sl = entry - FixedSLPoints * _Point;
            else
               sl = entry + FixedSLPoints * _Point;
           }
         else
           {
            if(isBuy)
              {
               double low = r[1].low;

               for(int i = 2; i <= SwingLookback; i++)
                 {
                  if(r[i].low < low)
                     low = r[i].low;
                 }

               sl = low - SL_BufferPoints * _Point;
              }
            else
              {
               double high = r[1].high;

               for(int i = 2; i <= SwingLookback; i++)
                 {
                  if(r[i].high > high)
                     high = r[i].high;
                 }

               sl = high + SL_BufferPoints * _Point;
              }
           }
        }

   if(SL_AdjustPoints != 0.0)
     {
      if(isBuy)
         sl -= SL_AdjustPoints * _Point;
      else
         sl += SL_AdjustPoints * _Point;
     }

   return NormalizeDouble(sl, _Digits);
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot < minLot)
      lot = minLot;

   if(lot > maxLot)
      lot = maxLot;

   if(step > 0.0)
      lot = MathFloor(lot / step) * step;

   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
double CalculateBaseLot(double slPrice, bool isBuy)
  {
   if(!UseDynamicRisk)
      return NormalizeLot(FixedLot);

   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distance = MathAbs(entry - slPrice);

   if(distance <= 0.0)
      return NormalizeLot(FixedLot);

   double riskPercent = GetRiskByMode(activeMode);
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0)
      return NormalizeLot(FixedLot);

   double moneyPerLot = distance / tickSize * tickValue;

   if(moneyPerLot <= 0.0)
      return NormalizeLot(FixedLot);

   return NormalizeLot(riskMoney / moneyPerLot);
  }

//+------------------------------------------------------------------+
double GetPyramidScale(int stage)
  {
   if(stage == 1)
      return PyramidLotScale1;
   if(stage == 2)
      return PyramidLotScale2;
   if(stage == 3)
      return PyramidLotScale3;

   return 1.0;
  }

//+------------------------------------------------------------------+
string BasketTPKey()
  {
   return "NDS14_BASKET_TP_" + _Symbol + "_" + (string)MagicNumber;
  }

//+------------------------------------------------------------------+
string BasketSLKey()
  {
   return "NDS14_BASKET_SL_" + _Symbol + "_" + (string)MagicNumber;
  }

//+------------------------------------------------------------------+
double BasketRiskMoneyIfSLHit()
  {
   double totalRisk = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double volume = PositionGetDouble(POSITION_VOLUME);

      double distance = MathAbs(openPrice - sl);

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0.0 || tickSize <= 0.0 || distance <= 0.0)
         continue;

      totalRisk += distance / tickSize * tickValue * volume;
     }

   return totalRisk;
  }

//+------------------------------------------------------------------+
double LimitLotByBasketRisk(double desiredLot, double entryPrice, double slPrice)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxRiskMoney = equity * MaxBasketRiskPercent / 100.0;

   double currentRisk = BasketRiskMoneyIfSLHit();
   double remainingRisk = maxRiskMoney - currentRisk;

   if(remainingRisk <= 0.0)
      return 0.0;

   double distance = MathAbs(entryPrice - slPrice);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0 || distance <= 0.0)
      return 0.0;

   double riskPerLot = distance / tickSize * tickValue;

   if(riskPerLot <= 0.0)
      return 0.0;

   double maxAllowedLot = remainingRisk / riskPerLot;
   double finalLot = MathMin(desiredLot, maxAllowedLot);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(finalLot < minLot)
      return 0.0;

   return NormalizeLot(finalLot);
  }

//+------------------------------------------------------------------+
void OpenPyramidBuy(int stage)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   string tpKey = BasketTPKey();
   string slKey = BasketSLKey();

   double sl = 0.0;
   double basketTP = 0.0;

   if(stage == 1 || !GlobalVariableCheck(slKey) || !GlobalVariableCheck(tpKey))
     {
      sl = CalculateSL(true, ask);
      double risk = ask - sl;

      if(risk <= 0.0)
         return;

      basketTP = NormalizeDouble(ask + risk * activeRR * TP_RR_Multiplier + TP_AdjustPoints * _Point, _Digits);
      GlobalVariableSet(slKey, sl);
      GlobalVariableSet(tpKey, basketTP);
     }
   else
     {
      sl = NormalizeDouble(GlobalVariableGet(slKey), _Digits);
      basketTP = NormalizeDouble(GlobalVariableGet(tpKey), _Digits);
     }

   double riskForLot = MathAbs(ask - sl);

   if(riskForLot <= 0.0)
      return;

   double baseLot = CalculateBaseLot(sl, true);
   double desiredLot = NormalizeLot(baseLot * GetPyramidScale(stage));
   double lot = LimitLotByBasketRisk(desiredLot, ask, sl);

   if(lot <= 0.0)
     {
      Print("BUY Stage ", stage, " blocked: Basket risk limit reached.");
      return;
     }

// همه پوزیشن‌های بسکت دقیقاً یک SL و یک TP مشترک دارند
   if(trade.Buy(lot, _Symbol, ask, sl, basketTP, "NDS14 SAME SLTP BUY " + (string)stage))
     {
      DrawArrow("BUY_" + IntegerToString(stage) + "_" + TimeToString(TimeCurrent()), TimeCurrent(), ask, clrLime, 233);
      Print("BUY Stage=", stage, " Lot=", lot, " SharedSL=", sl, " SharedTP=", basketTP, " BasketRisk=", BasketRiskMoneyIfSLHit());
     }
  }

//+------------------------------------------------------------------+
void OpenPyramidSell(int stage)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string tpKey = BasketTPKey();
   string slKey = BasketSLKey();

   double sl = 0.0;
   double basketTP = 0.0;

   if(stage == 1 || !GlobalVariableCheck(slKey) || !GlobalVariableCheck(tpKey))
     {
      sl = CalculateSL(false, bid);
      double risk = sl - bid;

      if(risk <= 0.0)
         return;

      basketTP = NormalizeDouble(bid - risk * activeRR * TP_RR_Multiplier - TP_AdjustPoints * _Point, _Digits);
      GlobalVariableSet(slKey, sl);
      GlobalVariableSet(tpKey, basketTP);
     }
   else
     {
      sl = NormalizeDouble(GlobalVariableGet(slKey), _Digits);
      basketTP = NormalizeDouble(GlobalVariableGet(tpKey), _Digits);
     }

   double riskForLot = MathAbs(sl - bid);

   if(riskForLot <= 0.0)
      return;

   double baseLot = CalculateBaseLot(sl, false);
   double desiredLot = NormalizeLot(baseLot * GetPyramidScale(stage));
   double lot = LimitLotByBasketRisk(desiredLot, bid, sl);

   if(lot <= 0.0)
     {
      Print("SELL Stage ", stage, " blocked: Basket risk limit reached.");
      return;
     }

// همه پوزیشن‌های بسکت دقیقاً یک SL و یک TP مشترک دارند
   if(trade.Sell(lot, _Symbol, bid, sl, basketTP, "NDS14 SAME SLTP SELL " + (string)stage))
     {
      DrawArrow("SELL_" + IntegerToString(stage) + "_" + TimeToString(TimeCurrent()), TimeCurrent(), bid, clrRed, 234);
      Print("SELL Stage=", stage, " Lot=", lot, " SharedSL=", sl, " SharedTP=", basketTP, " BasketRisk=", BasketRiskMoneyIfSLHit());
     }
  }

//+------------------------------------------------------------------+
int CountBasketPositions()
  {
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);

      if((ulong)magic == MagicNumber)
         count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetBasketType()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);

      if((ulong)magic == MagicNumber)
         return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
     }

   return POSITION_TYPE_BUY;
  }

//+------------------------------------------------------------------+
double GetBasketAveragePrice()
  {
   double totalVolume = 0.0;
   double weighted = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);

      if((ulong)magic != MagicNumber)
         continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);

      weighted += vol * price;
      totalVolume += vol;
     }

   if(totalVolume <= 0.0)
      return 0.0;

   return weighted / totalVolume;
  }

//+------------------------------------------------------------------+
double GetBasketSL()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);

      if((ulong)magic == MagicNumber)
         return PositionGetDouble(POSITION_SL);
     }

   return 0.0;
  }

//+------------------------------------------------------------------+
void CloseBasket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);

      if((ulong)magic != MagicNumber)
         continue;

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
void ManageBasketExit()
  {
   if(!CloseBasketAtCommonTP)
      return;

   int count = CountBasketPositions();

   if(count <= 0)
      return;

   string key = BasketTPKey();

   if(!GlobalVariableCheck(key))
      return;

   double tp = GlobalVariableGet(key);
   ENUM_POSITION_TYPE type = GetBasketType();

   if(type == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(bid >= tp)
        {
         Print("COMMON Basket TP BUY hit: ", tp);
         CloseBasket();
         GlobalVariableDel(key);
         GlobalVariableDel(BasketSLKey());
        }
     }
   else
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(ask <= tp)
        {
         Print("COMMON Basket TP SELL hit: ", tp);
         CloseBasket();
         GlobalVariableDel(key);
         GlobalVariableDel(BasketSLKey());
        }
     }
  }

//+------------------------------------------------------------------+
void ManageBasketBE()
  {
   if(!MoveBasketSLToBE)
      return;

   int count = CountBasketPositions();

   if(count <= 0)
      return;

   double avg = GetBasketAveragePrice();
   double sl = GetBasketSL();

   if(avg <= 0.0 || sl <= 0.0)
      return;

   double risk = MathAbs(avg - sl);

   if(risk <= 0.0)
      return;

   ENUM_POSITION_TYPE type = GetBasketType();

   if(type == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(bid - avg < risk * MoveBEAfterR)
         return;

      double newSL = NormalizeDouble(avg + BEBufferPoints * _Point, _Digits);
      GlobalVariableSet(BasketSLKey(), newSL);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionGetSymbol(i) != _Symbol)
            continue;

         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;

         ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         double tp = PositionGetDouble(POSITION_TP);
         double oldSL = PositionGetDouble(POSITION_SL);

         if(oldSL < newSL)
            trade.PositionModify(ticket, newSL, tp);
        }
     }
   else
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(avg - ask < risk * MoveBEAfterR)
         return;

      double newSL = NormalizeDouble(avg - BEBufferPoints * _Point, _Digits);
      GlobalVariableSet(BasketSLKey(), newSL);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionGetSymbol(i) != _Symbol)
            continue;

         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;

         ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         double tp = PositionGetDouble(POSITION_TP);
         double oldSL = PositionGetDouble(POSITION_SL);

         if(oldSL == 0.0 || oldSL > newSL)
            trade.PositionModify(ticket, newSL, tp);
        }
     }
  }


//+------------------------------------------------------------------+
void UpdateCommonBasketSL(double newSL)
  {
   newSL = NormalizeDouble(newSL, _Digits);

   string slKey = BasketSLKey();
   GlobalVariableSet(slKey, newSL);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      double tp = PositionGetDouble(POSITION_TP);
      if(!trade.PositionModify(ticket, newSL, tp))
         Print("Shared SL modify failed. Ticket=", ticket, " SL=", newSL, " Error=", GetLastError());
     }
  }

//+------------------------------------------------------------------+
void ManageBasketTrailing()
  {
   if(!EnableBasketTrailing)
      return;

   int count = CountBasketPositions();

   if(count <= 0)
      return;

   double avg = GetBasketAveragePrice();
   double sl = GetBasketSL();

   if(avg <= 0.0 || sl <= 0.0)
      return;

   double initialRisk = MathAbs(avg - sl);

   if(initialRisk <= 0.0)
      return;

   ENUM_POSITION_TYPE type = GetBasketType();

   if(type == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(bid - avg < initialRisk * TrailStartR)
         return;

      double newSL = NormalizeDouble(bid - initialRisk * TrailDistanceR, _Digits);

      if(newSL > sl + TrailStepPoints * _Point && newSL < bid)
        {
         UpdateCommonBasketSL(newSL);
         Print("Basket trailing BUY shared SL moved to ", newSL);
        }
     }
   else
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(avg - ask < initialRisk * TrailStartR)
         return;

      double newSL = NormalizeDouble(ask + initialRisk * TrailDistanceR, _Digits);

      if((sl == 0.0 || newSL < sl - TrailStepPoints * _Point) && newSL > ask)
        {
         UpdateCommonBasketSL(newSL);
         Print("Basket trailing SELL shared SL moved to ", newSL);
        }
     }
  }

//+------------------------------------------------------------------+
void ManagePyramidEntries()
  {
   if(!UsePyramidBasket)
      return;

   int count = CountBasketPositions();

   if(count <= 0 || count >= MaxPyramidEntries)
      return;

   ENUM_POSITION_TYPE type = GetBasketType();

   double avg = GetBasketAveragePrice();
   double sl = GetBasketSL();

   if(avg <= 0.0 || sl <= 0.0)
      return;

   double risk = MathAbs(avg - sl);

   if(risk <= 0.0)
      return;

   if(type == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lossDistance = avg - bid;

      if(count == 1 && lossDistance >= risk * LossAddStepR1)
         OpenPyramidBuy(2);

      if(count == 2 && lossDistance >= risk * LossAddStepR2)
         OpenPyramidBuy(3);
     }
   else
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lossDistance = ask - avg;

      if(count == 1 && lossDistance >= risk * LossAddStepR1)
         OpenPyramidSell(2);

      if(count == 2 && lossDistance >= risk * LossAddStepR2)
         OpenPyramidSell(3);
     }
  }

//+------------------------------------------------------------------+
void DrawArrow(string name, datetime time, double price, color clr, int code)
  {
   if(!DrawSignals)
      return;

   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
  }
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
