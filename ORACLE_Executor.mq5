//+------------------------------------------------------------------+
//|                                            ORACLE_Executor.mq5   |
//|  Robot d'exécution des idées ORACLE pour MetaTrader 5 (OANDA)    |
//|  Lit un fichier de consignes, pose des ordres en attente avec    |
//|  stop et objectifs, gère le break-even et les garde-fous.        |
//|  Version 1.02 – comptes démo et réel                             |
//+------------------------------------------------------------------+
#property copyright "ORACLE"
#property version   "1.02"
#property description "Exécute les idées du plan ORACLE (ordres en attente). Fonctionne sur compte démo et réel."

#include <Trade\Trade.mqh>

//--- Réglages
input string InpSignalURL       = "";                   // Adresse web du fichier de consignes (vide = fichier local)
input string InpLocalFile       = "oracle_signals.csv"; // Fichier local (dossier MQL5\Files)
input int    InpPollSeconds     = 60;                   // Lecture des consignes toutes les N secondes
input bool   InpDemoOnly        = false;                // true = refuser de trader sur un compte réel
input double InpRiskOverride    = 0.0;                  // Risque % par trade (0 = valeur ORACLE du fichier)
input double InpMaxRiskPct      = 1.0;                  // Plafond absolu du risque % par trade
input double InpMaxDailyLossPct = 4.0;                  // Perte max du jour en % (coupe tout jusqu'au lendemain)
input double InpMaxTotalLossPct = 8.0;                  // Perte max totale en % (arrêt définitif)
input int    InpMaxTrades       = 3;                    // Nombre max d'idées ouvertes ou en attente
input double InpMaxSignalAgeH   = 36;                   // Consignes plus vieilles = on annule les ordres en attente
input bool   InpAutoAdjust      = true;                 // Recaler les niveaux spot sur le prix du courtier
input double InpMaxAdjustPct    = 1.0;                  // Écart spot/courtier max accepté (%)
input bool   InpBreakEven       = true;                 // Stop à l'entrée sur la 2e moitié une fois TP1 touché
input bool   InpPush            = true;                 // Notifications sur l'application MT5 mobile
input long   InpMagic           = 77;                   // Identifiant du robot (ne pas changer en cours de route)
input string InpSymGold         = "";                   // Symbole de l'or (vide = détection auto)
input string InpSymBrent        = "";                   // Symbole du Brent (vide = détection auto)
input string InpSymUS500        = "";                   // Symbole du S&P 500 (vide = détection auto)
input string InpSymBTC          = "";                   // Symbole du bitcoin (vide = détection auto)

//--- Données
struct OSignal
  {
   string            id;
   string            asset;
   string            side;   // BUY / SELL
   string            type;   // LIMIT / STOP
   double            entry;
   double            stop;
   double            tp1;
   double            tp2;
   double            ref;    // prix spot au moment de la publication (0 = inconnu)
  };

CTrade   g_trade;
OSignal  g_sig[];
int      g_nsig     = 0;
datetime g_updated  = 0;     // heure UTC de publication
bool     g_enabled  = false;
double   g_risk     = 0.25;
datetime g_bstart[];
datetime g_bend[];
int      g_nb       = 0;
string   g_status   = "";

//+------------------------------------------------------------------+
//| Outils                                                           |
//+------------------------------------------------------------------+
void Notify(string msg)
  {
   Print("ORACLE : ", msg);
   if(InpPush)
      SendNotification("ORACLE : " + msg);
  }

string GV(string name) { return "ORACLE_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagic) + "_" + name; }

// T08 -> 108, S03 -> 203, autre lettre -> 3xx
int IdToNum(string id)
  {
   if(StringLen(id) < 2) return -1;
   ushort c = StringGetCharacter(id, 0);
   int code = (c == 'T') ? 1 : (c == 'S') ? 2 : 3;
   int n = (int)StringToInteger(StringSubstr(id, 1));
   if(n < 0 || n > 99) return -1;
   return code * 100 + n;
  }

string NumToId(int num)
  {
   int code = num / 100, n = num % 100;
   string p = (code == 1) ? "T" : (code == 2) ? "S" : "X";
   return p + StringFormat("%02d", n);
  }

long MakeMagic(int idnum, int leg) { return InpMagic * 10000 + idnum * 10 + leg; }
bool IsOurs(long magic)            { return (magic / 10000) == InpMagic; }
int  MagicId(long magic)           { return (int)((magic % 10000) / 10); }
int  MagicLeg(long magic)          { return (int)(magic % 10); }

string Clean(string s)
  {
   string r = s;
   StringToUpper(r);
   StringReplace(r, "/", "");
   StringReplace(r, "_", "");
   StringReplace(r, " ", "");
   StringReplace(r, ".", "");
   StringReplace(r, "-", "");
   return r;
  }

//+------------------------------------------------------------------+
//| Symboles                                                         |
//+------------------------------------------------------------------+
string FindSymbol(string &keys[])
  {
   int total = SymbolsTotal(false);
   // 1) correspondance exacte, 2) commence par
   for(int pass = 0; pass < 2; pass++)
      for(int k = 0; k < ArraySize(keys); k++)
        {
         string key = Clean(keys[k]);
         for(int i = 0; i < total; i++)
           {
            string name = SymbolName(i, false);
            string c = Clean(name);
            bool ok = (pass == 0) ? (c == key) : (StringFind(c, key) == 0);
            if(ok)
              {
               SymbolSelect(name, true);
               return name;
              }
           }
        }
   return "";
  }

string ResolveSymbol(string asset)
  {
   string ov = "";
   if(asset == "GOLD")  ov = InpSymGold;
   if(asset == "BRENT") ov = InpSymBrent;
   if(asset == "US500") ov = InpSymUS500;
   if(asset == "BTC")   ov = InpSymBTC;
   if(ov != "")
     {
      if(SymbolSelect(ov, true)) return ov;
      return "";
     }
   if(asset == "GOLD")  { string k[] = {"XAUUSD", "GOLD"};                               return FindSymbol(k); }
   if(asset == "BRENT") { string k[] = {"BCOUSD", "UKOIL", "BRENT", "XBRUSD", "UKBRENT"}; return FindSymbol(k); }
   if(asset == "US500") { string k[] = {"US500", "SPX500", "USSPX500", "USA500", "SP500"}; return FindSymbol(k); }
   if(asset == "BTC")   { string k[] = {"BTCUSD", "BITCOIN"};                            return FindSymbol(k); }
   string k[1];
   k[0] = asset;
   return FindSymbol(k);
  }

double RoundPrice(string sym, double p)
  {
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(tick > 0) p = MathRound(p / tick) * tick;
   return NormalizeDouble(p, digits);
  }

double NormLot(string sym, double v)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   v = MathFloor(v / step + 1e-9) * step;
   if(v < mn) return 0;
   if(v > mx) v = mx;
   return NormalizeDouble(v, 8);
  }

//+------------------------------------------------------------------+
//| Lecture des consignes                                            |
//+------------------------------------------------------------------+
bool LoadFile(string name, string &txt)
  {
   int h = FileOpen(name, FILE_READ | FILE_BIN);
   if(h == INVALID_HANDLE) return false;
   int n = (int)FileSize(h);
   uchar buf[];
   ArrayResize(buf, n);
   if(n > 0) FileReadArray(h, buf, 0, n);
   FileClose(h);
   txt = CharArrayToString(buf, 0, n, CP_UTF8);
   return n > 0;
  }

void SaveCache(string txt)
  {
   uchar buf[];
   int n = StringToCharArray(txt, buf, 0, WHOLE_ARRAY, CP_UTF8);
   int h = FileOpen("oracle_cache.csv", FILE_WRITE | FILE_BIN);
   if(h == INVALID_HANDLE) return;
   if(n > 1) FileWriteArray(h, buf, 0, n - 1);
   FileClose(h);
  }

bool FetchText(string &txt)
  {
   if(InpSignalURL == "")
      return LoadFile(InpLocalFile, txt);
   char post[], res[];
   string hdr;
   ResetLastError();
   string url = InpSignalURL;
   url += (StringFind(url, "?") >= 0) ? "&t=" : "?t=";
   url += IntegerToString((long)TimeGMT());
   int code = WebRequest("GET", url, "", 8000, post, res, hdr);
   if(code == 200)
     {
      txt = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
      SaveCache(txt);
      return true;
     }
   Print("ORACLE : lecture web impossible (code ", code, ", erreur ", GetLastError(),
         "). Ajoutez l'adresse dans Outils > Options > Expert Advisors > WebRequest. Copie locale utilisée.");
   return LoadFile("oracle_cache.csv", txt);
  }

bool Parse(string txt)
  {
   StringReplace(txt, "\r", "");
   string lines[];
   int n = StringSplit(txt, '\n', lines);
   ArrayResize(g_sig, 0);
   g_nsig = 0;
   ArrayResize(g_bstart, 0);
   ArrayResize(g_bend, 0);
   g_nb = 0;
   bool hdr = false;
   for(int i = 0; i < n; i++)
     {
      string l = lines[i];
      StringTrimLeft(l);
      StringTrimRight(l);
      if(l == "" || StringGetCharacter(l, 0) == '#') continue;
      string f[];
      int k = StringSplit(l, ';', f);
      if(k < 1) continue;
      if(f[0] == "HEADER" && k >= 4)
        {
         g_updated = StringToTime(f[1]);
         g_enabled = (f[2] == "1");
         g_risk    = StringToDouble(f[3]);
         hdr = true;
        }
      else if(f[0] == "ORDER" && k >= 10)
        {
         OSignal s;
         s.id    = f[1];
         s.asset = f[2];
         s.side  = f[3];
         s.type  = f[4];
         s.entry = StringToDouble(f[5]);
         s.stop  = StringToDouble(f[6]);
         s.tp1   = StringToDouble(f[7]);
         s.tp2   = StringToDouble(f[8]);
         s.ref   = StringToDouble(f[9]);
         bool buy = (s.side == "BUY");
         bool okType = (s.type == "LIMIT" || s.type == "STOP") && (s.side == "BUY" || s.side == "SELL");
         bool okLv = buy ? (s.stop < s.entry && s.entry < s.tp1) : (s.stop > s.entry && s.entry > s.tp1);
         if(s.tp2 > 0) okLv = okLv && (buy ? s.tp2 > s.tp1 : s.tp2 < s.tp1);
         if(!okType || !okLv || IdToNum(s.id) < 0)
           {
            Print("ORACLE : ligne ignorée (niveaux incohérents) : ", l);
            continue;
           }
         ArrayResize(g_sig, g_nsig + 1);
         g_sig[g_nsig++] = s;
        }
      else if(f[0] == "BLACKOUT" && k >= 3)
        {
         ArrayResize(g_bstart, g_nb + 1);
         ArrayResize(g_bend, g_nb + 1);
         g_bstart[g_nb] = StringToTime(f[1]);
         g_bend[g_nb]   = StringToTime(f[2]);
         g_nb++;
        }
     }
   return hdr;
  }

bool InBlackout()
  {
   datetime now = TimeGMT();
   for(int i = 0; i < g_nb; i++)
      if(now >= g_bstart[i] && now <= g_bend[i]) return true;
   return false;
  }

int FindSignal(int idnum)
  {
   for(int i = 0; i < g_nsig; i++)
      if(IdToNum(g_sig[i].id) == idnum) return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| État des ordres et positions                                     |
//+------------------------------------------------------------------+
bool HasOrderOrPosition(int idnum)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      long m = OrderGetInteger(ORDER_MAGIC);
      if(IsOurs(m) && MagicId(m) == idnum) return true;
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(IsOurs(m) && MagicId(m) == idnum) return true;
     }
   return false;
  }

int CountActiveIds()
  {
   int ids[];
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0) continue;
      long m = OrderGetInteger(ORDER_MAGIC);
      if(!IsOurs(m)) continue;
      int id = MagicId(m);
      bool seen = false;
      for(int j = 0; j < n; j++) if(ids[j] == id) seen = true;
      if(!seen) { ArrayResize(ids, n + 1); ids[n++] = id; }
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurs(m)) continue;
      int id = MagicId(m);
      bool seen = false;
      for(int j = 0; j < n; j++) if(ids[j] == id) seen = true;
      if(!seen) { ArrayResize(ids, n + 1); ids[n++] = id; }
     }
   return n;
  }

bool WasFilled(int idnum) { return GlobalVariableCheck(GV("filled_" + IntegerToString(idnum))); }

void DeletePending(string why, int onlyId = -1)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      long m = OrderGetInteger(ORDER_MAGIC);
      if(!IsOurs(m)) continue;
      if(onlyId >= 0 && MagicId(m) != onlyId) continue;
      if(g_trade.OrderDelete(t))
         Print("ORACLE : ordre ", NumToId(MagicId(m)), " annulé (", why, ")");
     }
  }

void CloseAll(string why)
  {
   DeletePending(why);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsOurs(PositionGetInteger(POSITION_MAGIC))) continue;
      g_trade.PositionClose(t);
     }
   Notify("tout est fermé : " + why);
  }

//+------------------------------------------------------------------+
//| Garde-fous de perte                                              |
//+------------------------------------------------------------------+
bool GuardsBlock()
  {
   if(GlobalVariableCheck(GV("halt_total")))
     {
      g_status = "ARRÊT DÉFINITIF : perte totale max atteinte. Supprimez la variable globale " + GV("halt_total") + " pour relancer.";
      return true;
     }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!GlobalVariableCheck(GV("start_bal"))) GlobalVariableSet(GV("start_bal"), bal);
   MqlDateTime dt;
   TimeCurrent(dt);
   double day = dt.year * 10000 + dt.mon * 100 + dt.day;
   if(!GlobalVariableCheck(GV("day")) || GlobalVariableGet(GV("day")) != day)
     {
      GlobalVariableSet(GV("day"), day);
      GlobalVariableSet(GV("day_bal"), bal);
      if(GlobalVariableCheck(GV("halt_day"))) GlobalVariableDel(GV("halt_day"));
     }
   double dayBal   = GlobalVariableGet(GV("day_bal"));
   double startBal = GlobalVariableGet(GV("start_bal"));
   if(eq <= startBal * (1.0 - InpMaxTotalLossPct / 100.0))
     {
      GlobalVariableSet(GV("halt_total"), 1);
      CloseAll(StringFormat("perte totale de %.1f %% atteinte", InpMaxTotalLossPct));
      return true;
     }
   if(GlobalVariableCheck(GV("halt_day")))
     {
      g_status = "Arrêt jusqu'à demain : perte du jour max atteinte.";
      return true;
     }
   if(eq <= dayBal * (1.0 - InpMaxDailyLossPct / 100.0))
     {
      GlobalVariableSet(GV("halt_day"), 1);
      CloseAll(StringFormat("perte du jour de %.1f %% atteinte, reprise demain", InpMaxDailyLossPct));
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Calcul des niveaux recalés                                       |
//+------------------------------------------------------------------+
bool Levels(OSignal &s, string sym, double &e, double &sl, double &t1, double &t2)
  {
   int idnum = IdToNum(s.id);
   string key = GV("off_" + IntegerToString(idnum));
   double off = 0;
   if(InpAutoAdjust && s.ref > 0)
     {
      if(GlobalVariableCheck(key))
         off = GlobalVariableGet(key);
      else if(TimeGMT() - g_updated < 20 * 60)   // consignes fraîches : on mesure l'écart spot/courtier
        {
         double mid = (SymbolInfoDouble(sym, SYMBOL_BID) + SymbolInfoDouble(sym, SYMBOL_ASK)) / 2.0;
         if(mid > 0)
           {
            off = mid - s.ref;
            if(MathAbs(off) / s.ref * 100.0 > InpMaxAdjustPct)
              {
               Print("ORACLE : ", s.id, " écart spot/courtier trop grand (", DoubleToString(off, 2), "), pas de recalage.");
               off = 0;
              }
            GlobalVariableSet(key, off);
           }
        }
     }
   e  = RoundPrice(sym, s.entry + off);
   sl = RoundPrice(sym, s.stop + off);
   t1 = RoundPrice(sym, s.tp1 + off);
   t2 = (s.tp2 > 0) ? RoundPrice(sym, s.tp2 + off) : 0;
   return true;
  }

ENUM_ORDER_TYPE OrderTypeOf(OSignal &s)
  {
   if(s.side == "BUY") return (s.type == "LIMIT") ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP;
   return (s.type == "LIMIT") ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP;
  }

//+------------------------------------------------------------------+
//| Pose d'une idée                                                  |
//+------------------------------------------------------------------+
void PlaceSignal(OSignal &s)
  {
   int idnum = IdToNum(s.id);
   string sym = ResolveSymbol(s.asset);
   if(sym == "")
     {
      Print("ORACLE : ", s.id, " symbole introuvable pour ", s.asset, " (renseignez-le dans les réglages).");
      return;
     }
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) return;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID), ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   double e, sl, t1, t2;
   Levels(s, sym, e, sl, t1, t2);
   ENUM_ORDER_TYPE ot = OrderTypeOf(s);

   // l'ordre doit être du bon côté du marché, sinon il partirait au marché
   double gap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
   bool valid = true;
   if(ot == ORDER_TYPE_BUY_LIMIT  && ask <= e + gap) valid = false;
   if(ot == ORDER_TYPE_BUY_STOP   && ask >= e - gap) valid = false;
   if(ot == ORDER_TYPE_SELL_LIMIT && bid >= e - gap) valid = false;
   if(ot == ORDER_TYPE_SELL_STOP  && bid <= e + gap) valid = false;
   if(!valid)
     {
      string k = GV("skip_" + IntegerToString(idnum));
      if(!GlobalVariableCheck(k))
        {
         Notify(s.id + " " + sym + " : le prix a déjà dépassé l'entrée " + DoubleToString(e, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) + ", ordre non posé (pas d'entrée au marché).");
         GlobalVariableSet(k, 1);
        }
      return;
     }

   double riskPct = (InpRiskOverride > 0) ? InpRiskOverride : g_risk;
   riskPct = MathMin(riskPct, InpMaxRiskPct);
   if(riskPct <= 0) return;
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
   ENUM_ORDER_TYPE dir = (s.side == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double pl1 = 0;
   if(!OrderCalcProfit(dir, sym, 1.0, e, sl, pl1) || pl1 == 0)
     {
      Print("ORACLE : ", s.id, " calcul du risque impossible.");
      return;
     }
   double total = riskMoney / MathAbs(pl1);
   double mn = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double lotA = 0, lotB = 0;
   if(t2 > 0 && NormLot(sym, total / 2.0) >= mn)
     {
      lotA = NormLot(sym, total / 2.0);
      lotB = NormLot(sym, total - lotA);
     }
   else
      lotA = NormLot(sym, total);
   if(lotA <= 0)
     {
      string k = GV("small_" + IntegerToString(idnum));
      if(!GlobalVariableCheck(k))
        {
         Notify(s.id + " : capital trop petit pour risquer " + DoubleToString(riskPct, 2) + " % avec ce stop (lot minimum " + DoubleToString(mn, 2) + "). Ordre non posé.");
         GlobalVariableSet(k, 1);
        }
      return;
     }

   bool ok = true;
   g_trade.SetExpertMagicNumber(MakeMagic(idnum, 1));
   ok = g_trade.OrderOpen(sym, ot, lotA, 0, e, sl, t1, ORDER_TIME_GTC, 0, "ORACLE " + s.id + " A");
   if(ok && lotB > 0)
     {
      g_trade.SetExpertMagicNumber(MakeMagic(idnum, 2));
      ok = g_trade.OrderOpen(sym, ot, lotB, 0, e, sl, t2, ORDER_TIME_GTC, 0, "ORACLE " + s.id + " B");
     }
   if(!ok)
     {
      Print("ORACLE : ", s.id, " refus du courtier : ", g_trade.ResultRetcodeDescription());
      DeletePending("échec de pose", idnum);
      return;
     }
   GlobalVariableSet(GV("tp1_" + IntegerToString(idnum)), t1);
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   Notify(StringFormat("%s %s %s %s posé : entrée %s, stop %s, TP1 %s%s, lots %s+%s, risque %.2f %%",
                       s.id, sym, s.side == "BUY" ? "achat" : "vente", s.type == "LIMIT" ? "limite" : "stop",
                       DoubleToString(e, d), DoubleToString(sl, d), DoubleToString(t1, d),
                       t2 > 0 ? ", TP2 " + DoubleToString(t2, d) : "",
                       DoubleToString(lotA, 2), DoubleToString(lotB, 2), riskPct));
  }

//+------------------------------------------------------------------+
//| Entretien des ordres en attente                                  |
//+------------------------------------------------------------------+
void ManagePending(bool allowed, string why)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      long m = OrderGetInteger(ORDER_MAGIC);
      if(!IsOurs(m)) continue;
      int idnum = MagicId(m);
      string reason = "";
      if(!allowed) reason = why;
      else
        {
         int k = FindSignal(idnum);
         if(k < 0) reason = "idée retirée du plan";
         else
           {
            string sym = OrderGetString(ORDER_SYMBOL);
            double e, sl, t1, t2;
            Levels(g_sig[k], sym, e, sl, t1, t2);
            double pt = SymbolInfoDouble(sym, SYMBOL_POINT) * 2;
            if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - e) > pt || MathAbs(OrderGetDouble(ORDER_SL) - sl) > pt)
               reason = "niveaux modifiés dans le plan";
           }
        }
      if(reason != "" && g_trade.OrderDelete(t))
        {
         Print("ORACLE : ordre ", NumToId(idnum), " annulé (", reason, ")");
         if(reason == "idée retirée du plan" || reason == "niveaux modifiés dans le plan")
            Notify(NumToId(idnum) + " : ordre en attente annulé (" + reason + ")");
        }
     }
  }

void ManageBreakEven()
  {
   if(!InpBreakEven) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurs(m) || MagicLeg(m) != 2) continue;
      string key = GV("tp1_" + IntegerToString(MagicId(m)));
      if(!GlobalVariableCheck(key)) continue;
      double tp1 = GlobalVariableGet(key);
      string sym = PositionGetString(POSITION_SYMBOL);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double px = buy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      bool reached = buy ? (px >= tp1) : (px <= tp1);
      bool already = buy ? (sl >= open) : (sl > 0 && sl <= open);
      if(reached && !already)
        {
         g_trade.SetExpertMagicNumber(m);
         if(g_trade.PositionModify(t, open, tp))
            Notify(NumToId(MagicId(m)) + " : TP1 atteint, stop remonté à l'entrée sur la 2e moitié.");
        }
     }
  }

//+------------------------------------------------------------------+
//| Boucle principale                                                |
//+------------------------------------------------------------------+
void Cycle()
  {
   if(InpDemoOnly && TerminalInfoInteger(TERMINAL_CONNECTED) && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
     {
      Comment("ORACLE : compte RÉEL détecté, robot à l'arrêt (réglage « Démo uniquement »).");
      return;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Comment("ORACLE : activez le bouton « Algo Trading » et l'option « Autoriser le trading algorithmique ».");
      return;
     }
   g_status = "";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoInteger(ACCOUNT_LOGIN) == 0 ||
      AccountInfoDouble(ACCOUNT_BALANCE) <= 0 || AccountInfoDouble(ACCOUNT_EQUITY) <= 0)
     {
      Comment("ORACLE : pas connecté au serveur du courtier (ou compte vide). Vérifiez le compte et le serveur dans Fichier > Connexion à un compte de trading. Aucune action.");
      return;
     }
   if(GuardsBlock())
     {
      Comment("ORACLE : " + g_status);
      return;
     }

   string txt;
   bool ok = FetchText(txt) && Parse(txt);
   bool stale = !ok || (TimeGMT() - g_updated > (long)(InpMaxSignalAgeH * 3600));
   bool black = InBlackout();
   string why = !ok ? "consignes illisibles" : stale ? "consignes trop anciennes" : !g_enabled ? "robot coupé par ORACLE (interrupteur)" : black ? "annonce économique" : "";
   bool allowed = (why == "");

   ManagePending(allowed, why);
   ManageBreakEven();

   if(allowed)
      for(int i = 0; i < g_nsig; i++)
        {
         int idnum = IdToNum(g_sig[i].id);
         if(HasOrderOrPosition(idnum) || WasFilled(idnum)) continue;
         if(CountActiveIds() >= InpMaxTrades) break;
         PlaceSignal(g_sig[i]);
        }

   Comment(StringFormat("ORACLE Executor v1.02 | %s | consignes du %s UTC | %d idée(s) | risque %.2f %% | %s",
                        AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DÉMO" : "RÉEL",
                        TimeToString(g_updated, TIME_DATE | TIME_MINUTES), g_nsig,
                        MathMin(InpRiskOverride > 0 ? InpRiskOverride : g_risk, InpMaxRiskPct),
                        allowed ? "actif" : "en pause : " + why));
  }

int OnInit()
  {
   g_trade.SetDeviationInPoints(30);
   EventSetTimer(MathMax(10, InpPollSeconds));
   Notify("robot démarré sur le compte " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) +
          (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? " (démo)" : " (réel)"));
   Cycle();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTimer() { Cycle(); }

//+------------------------------------------------------------------+
//| Notifications d'exécution                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   long m = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(!IsOurs(m)) return;
   int idnum = MagicId(m);
   string id = NumToId(idnum);
   string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      GlobalVariableSet(GV("filled_" + IntegerToString(idnum)), 1);
      Notify(StringFormat("%s %s exécuté à %s (moitié %s)", id, sym, DoubleToString(price, d), MagicLeg(m) == 1 ? "A" : "B"));
     }
   else if(entry == DEAL_ENTRY_OUT)
     {
      double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      long r = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string why = (r == DEAL_REASON_SL) ? "stop" : (r == DEAL_REASON_TP) ? "objectif" : "clôture";
      Notify(StringFormat("%s %s fermé (%s) à %s, résultat %.2f %s", id, sym, why, DoubleToString(price, d), pnl, AccountInfoString(ACCOUNT_CURRENCY)));
     }
  }
//+------------------------------------------------------------------+
