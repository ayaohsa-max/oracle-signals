//+------------------------------------------------------------------+
//|                                            ORACLE_Executor.mq5   |
//|  Robot d'exécution des idées ORACLE pour MetaTrader 5 (OANDA)    |
//|  Lit un fichier de consignes, pose des ordres en attente avec    |
//|  stop et objectifs, gère le break-even et les garde-fous.        |
//|  Version 1.11 – comptes démo et réel                             |
//|  1.11 : SAV-WS : mesure du passage au prix d'entrée (variante    |
//|         « BE » notée pour chaque résultat) et option de le faire |
//|         en réel ; consignes lues sans le cache de 5 min de GitHub|
//|         quand le jeton GitHub est renseigné.                     |
//|  1.10 : gestion des anomalies : alerte Telegram au retour d'une  |
//|         coupure (courtier ou PC/MT5 arrêté) avec sa durée,       |
//|         alerte en cas de refus du courtier, rattrapage de la     |
//|         fermeture du vendredi si le robot était arrêté.          |
//|  1.09 : moteur SAV-WS (filtres SAV-AFS + entrée WinStructure) :  |
//|         ordre limite Fibo 0.618-1 sur confluence (OB, FVG,       |
//|         liquidité, MSS, Premium/Discount, killzone, zone H4),    |
//|         stop derrière la confluence, objectif Fibo -0.5 ; en     |
//|         M15 et H1, mode observation ou trading.                  |
//|  1.08 : signal de vie horaire dans le ticket GitHub n°2, alerte  |
//|         Telegram quand les consignes sont trop anciennes ou      |
//|         illisibles (et à la reprise).                           |
//|  1.07 : perte max totale « suiveuse » comme FTMO (depuis le plus |
//|         haut de l'équité), bilan quotidien dans le journal.       |
//|  1.06 : moteur SAV-AFS intégré (structure LL/HH, Fibonacci,      |
//|         BOS, filtre de tendance) en H1 et H4, dans le sens du    |
//|         biais fondamental publié par ORACLE ; mode observation   |
//|         (statistiques) ou trading.                               |
//|  1.05 : alertes Telegram directes, journal des trades (GitHub),  |
//|         filtre de spread, risque total plafonné, réduction après |
//|         une série de pertes, sortie au choix (break-even / ATR). |
//+------------------------------------------------------------------+
#property copyright "ORACLE"
#property version   "1.11"
#property description "Exécute les idées du plan ORACLE (ordres en attente). Fonctionne sur compte démo et réel."

#include <Trade\Trade.mqh>

//--- Réglages
input string InpSignalURL       = "https://raw.githubusercontent.com/ayaohsa-max/oracle-signals/main/oracle_signals.csv";                   // Adresse web du fichier de consignes (vide = fichier local)
input string InpLocalFile       = "oracle_signals.csv"; // Fichier local (dossier MQL5\Files)
input int    InpPollSeconds     = 60;                   // Lecture des consignes toutes les N secondes
input bool   InpDemoOnly        = false;                // true = refuser de trader sur un compte réel
input double InpRiskOverride    = 0.0;                  // Risque % par trade (0 = valeur ORACLE du fichier)
input double InpMaxRiskPct      = 1.0;                  // Plafond absolu du risque % par trade
input double InpMaxDailyLossPct = 4.0;                  // Perte max du jour en % (coupe tout jusqu'au lendemain)
input double InpMaxTotalLossPct = 8.0;                  // Perte max totale en % (arrêt définitif)
input bool   InpTrailingMaxLoss = true;                 // Perte max totale mesurée depuis le plus haut de l'équité (règle FTMO « trailing »)
input int    InpMaxTrades       = 3;                    // Nombre max d'idées ouvertes ou en attente
input double InpMaxSignalAgeH   = 36;                   // Consignes plus vieilles = on annule les ordres en attente
input bool   InpAlertStale      = true;                 // Alerte Telegram si consignes trop anciennes / illisibles (en semaine)
input bool   InpAutoAdjust      = true;                 // Recaler les niveaux spot sur le prix du courtier
input double InpMaxAdjustPct    = 1.0;                  // Écart spot/courtier max accepté (%)
input bool   InpBreakEven       = true;                 // Stop à l'entrée sur la 2e moitié une fois TP1 touché
input bool   InpFridayClose     = true;                 // Fermer tout le vendredi soir et rester en pause le week-end (règle FTMO)
input int    InpFridayHour      = 21;                   // Heure de fermeture du vendredi (heure de Paris)
input int    InpFridayMinute    = 45;                   // Minute de fermeture du vendredi (heure de Paris)
input bool   InpPush            = true;                 // Notifications sur l'application MT5 mobile
input long   InpMagic           = 77;                   // Identifiant du robot (ne pas changer en cours de route)
input string InpSymGold         = "";                   // Symbole de l'or (vide = détection auto)
input string InpSymBrent        = "";                   // Symbole du Brent (vide = détection auto)
input string InpSymUS500        = "";                   // Symbole du S&P 500 (vide = détection auto)
input string InpSymBTC          = "";                   // Symbole du bitcoin (vide = détection auto)
input string InpTgToken         = "";                   // Telegram : jeton du bot (vide = pas de Telegram)
input string InpTgChat          = "7351544661";         // Telegram : identifiant de la conversation
input string InpGitToken        = "";                   // GitHub : jeton « Issues » pour le journal des trades (vide = journal local seulement)
input string InpGitRepo         = "ayaohsa-max/oracle-signals"; // GitHub : dépôt du journal
input int    InpGitIssue        = 1;                    // GitHub : numéro du ticket « Journal du robot »
input int    InpBeatIssue       = 2;                    // GitHub : numéro du ticket « Signal de vie » (0 = désactivé)
input int    InpBeatMinutes     = 60;                   // Signal de vie toutes les N minutes
input double InpMaxSpreadPct    = 10.0;                 // Spread max, en % de la distance entrée-stop (sinon on attend)
input double InpMaxOpenRiskPct  = 1.5;                  // Risque total max (positions + ordres en attente), en % du capital
input int    InpLossStreak      = 3;                    // Après N idées perdantes d'affilée...
input double InpStreakFactor    = 0.5;                  // ...le risque par trade est multiplié par ce facteur
input double InpTrailATRMult    = 1.0;                  // Sortie « ATR » : stop suiveur à N x ATR(14) journalier sur la 2e moitié
input int    InpSavMode         = -1;                   // SAV-AFS : -1 = selon ORACLE, 0 = arrêt, 1 = observation, 2 = trading
input double InpSavRR           = 2.0;                  // SAV-AFS : ratio gain / risque
input double InpSavAtrMult      = 0.2;                  // SAV-AFS : marge du stop (x ATR 14 de l'unité)
input double InpSavFibMin       = 0.5;                  // SAV-AFS : début de la zone de retracement
input double InpSavFibMax       = 0.786;                // SAV-AFS : fin de la zone de retracement
input int    InpSavMaxBars      = 60;                   // SAV-AFS : durée max d'une étape (bougies)
input int    InpSwMode          = -1;                   // SAV-WS : -1 = selon ORACLE, 0 = arrêt, 1 = observation, 2 = trading
input ENUM_TIMEFRAMES InpSwTF1  = PERIOD_M15;           // SAV-WS : unité 1 (Actuelle = désactivée)
input ENUM_TIMEFRAMES InpSwTF2  = PERIOD_H1;            // SAV-WS : unité 2 (Actuelle = désactivée)
input ENUM_TIMEFRAMES InpSwHTF  = PERIOD_H4;            // SAV-WS : unité supérieure (tendance, Premium/Discount, zones)
input bool   InpSwNotify        = true;                 // SAV-WS : Telegram / mobile pour chaque setup en observation
input int    InpSwPivot         = 5;                    // SAV-WS : longueur des pivots
input bool   InpSwChoch         = true;                 // SAV-WS : setups aussi sur CHoCH
input bool   InpSwHtfTrend      = true;                 // SAV-WS : prix du bon côté de la SMA 200 de l'unité supérieure
input bool   InpSwAlign         = true;                 // SAV-WS : EMA 20 > EMA 50 > SMA 200 (inverse en vente)
input int    InpSwMinConf       = 2;                    // SAV-WS : confluences minimum (BOS/CHoCH non compté)
input bool   InpSwNeedKey       = true;                 // SAV-WS : exiger OB, FVG, sweep ou zone de l'unité supérieure
input bool   InpSwUseMss        = true;                 // SAV-WS : compter le MSS (cassure par bougie de déplacement)
input double InpSwMssAtr        = 1.0;                  // SAV-WS : MSS = corps de la bougie de cassure >= N x ATR
input double InpSwMinRR         = 1.5;                  // SAV-WS : gain / risque minimum vers l'objectif
input double InpSwTarget        = -0.5;                 // SAV-WS : objectif Fibo (0, -0.5 ou -0.618)
input double InpSwSlAtr         = 0.2;                  // SAV-WS : marge du stop derrière la confluence (x ATR 14)
input int    InpSwObLook        = 10;                   // SAV-WS : recherche de l'Order Block (bougies avant l'origine)
input int    InpSwPdLen         = 50;                   // SAV-WS : range Premium/Discount (bougies de l'unité supérieure)
input int    InpSwMaxWait       = 100;                  // SAV-WS : validité d'un setup (bougies)
input string InpSwKzLondon      = "08:00-11:00";        // SAV-WS : killzone Londres (heure de Paris)
input string InpSwKzNY          = "13:00-16:00";        // SAV-WS : killzone New York (heure de Paris)
input string InpSwAsia          = "01:00-06:00";        // SAV-WS : range asiatique (heure de Paris)
input bool   InpSwBE            = false;                // SAV-WS : en réel, stop remonté au prix d'entrée (à activer seulement si le bilan le valide)
input double InpSwBeAtR         = 1.0;                  // SAV-WS : gain (en R) à partir duquel le stop passe au prix d'entrée (réel et mesure)

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
int      g_exitMode = 0;     // 0 = break-even après TP1 ; 1 = break-even + stop suiveur ATR
string   g_tgQueue[];        // messages Telegram en attente d'envoi
string   g_gitQueue[];       // lignes de journal en attente d'envoi
string   g_state     = "démarrage"; // état affiché, repris dans le signal de vie
datetime g_lastBeat  = 0;    // dernier signal de vie envoyé (heure locale)
datetime g_lastOk    = 0;    // dernière lecture réussie des consignes (GMT)
bool     g_staleSent = false; // alerte « consignes » déjà envoyée
string   g_symCache[];       // symboles dont l'ATR est suivi
int      g_atrHandle[];
int      g_savMode  = 1;     // SAV-AFS : 0 = arrêt, 1 = observation, 2 = trading (valeur ORACLE)
int      g_swMode   = 1;     // SAV-WS : 0 = arrêt, 1 = observation, 2 = trading (valeur ORACLE, 7e champ de HEADER)
string   g_biasAsset[];      // biais fondamental publié par ORACLE, par actif
int      g_biasVal[];        // 1 = haussier, -1 = baissier, 0 = neutre
// signaux SAV-AFS suivis en observation (trades virtuels)
string   g_vAsset[];
string   g_vSym[];
int      g_vTf[];            // 1 = H1, 4 = H4
int      g_vBuy[];
datetime g_vTime[];
double   g_vE[];
double   g_vSL[];
double   g_vTP[];

//+------------------------------------------------------------------+
//| Outils                                                           |
//+------------------------------------------------------------------+
void QueuePush(string &q[], string item)
  {
   int n = ArraySize(q);
   if(n >= 200) return;                       // sécurité mémoire
   ArrayResize(q, n + 1);
   q[n] = item;
  }

void QueueDropFirst(string &q[])
  {
   int n = ArraySize(q);
   for(int i = 1; i < n; i++) q[i - 1] = q[i];
   if(n > 0) ArrayResize(q, n - 1);
  }

void Notify(string msg)
  {
   Print("ORACLE : ", msg);
   if(InpPush)
      SendNotification("ORACLE : " + msg);
   if(InpTgToken != "")
      QueuePush(g_tgQueue, "ROBOT ORACLE (" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ") : " + msg);
  }

string UrlEncode(string s)
  {
   uchar b[];
   int n = StringToCharArray(s, b, 0, WHOLE_ARRAY, CP_UTF8);
   string r = "";
   for(int i = 0; i < n - 1; i++)
     {
      uchar c = b[i];
      bool plain = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~';
      if(plain) r += CharToString(c);
      else      r += StringFormat("%%%02X", (int)c);
     }
   return r;
  }

string JsonEscape(string s)
  {
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   StringReplace(r, "\r", "");
   return r;
  }

int HttpPost(string url, string headers, string body)
  {
   char data[], res[];
   string rh;
   int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0) ArrayResize(data, n - 1);
   ResetLastError();
   return WebRequest("POST", url, headers, 8000, data, res, rh);
  }

bool TgSend(string text)
  {
   string url = "https://api.telegram.org/bot" + InpTgToken + "/sendMessage";
   string body = "chat_id=" + UrlEncode(InpTgChat) + "&text=" + UrlEncode(text);
   int code = HttpPost(url, "Content-Type: application/x-www-form-urlencoded\r\n", body);
   if(code != 200)
      Print("ORACLE : Telegram non envoyé (code ", code, ", erreur ", GetLastError(), "). Ajoutez https://api.telegram.org dans les WebRequest autorisés.");
   return code == 200 || code == 400 || code == 401 || code == 403;   // 4xx = message ou jeton invalide : inutile de réessayer
  }

bool GitSend(string line, int issue = 0)
  {
   if(issue <= 0) issue = InpGitIssue;
   string url = "https://api.github.com/repos/" + InpGitRepo + "/issues/" + IntegerToString(issue) + "/comments";
   string hdr = "Authorization: Bearer " + InpGitToken + "\r\nUser-Agent: ORACLE-EA\r\nAccept: application/vnd.github+json\r\nContent-Type: application/json\r\n";
   int code = HttpPost(url, hdr, "{\"body\":\"" + JsonEscape(line) + "\"}");
   if(code != 201)
      Print("ORACLE : journal GitHub non envoyé (code ", code, ", erreur ", GetLastError(), "). Ajoutez https://api.github.com dans les WebRequest autorisés et vérifiez le jeton.");
   return code == 201 || code == 401 || code == 403 || code == 404 || code == 422;
  }

void FlushQueues()
  {
   int sent = 0;
   while(ArraySize(g_tgQueue) > 0 && sent < 10)
     {
      if(!TgSend(g_tgQueue[0])) break;
      QueueDropFirst(g_tgQueue);
      sent++;
     }
   sent = 0;
   while(InpGitToken != "" && ArraySize(g_gitQueue) > 0 && sent < 10)
     {
      if(!GitSend(g_gitQueue[0])) break;
      QueueDropFirst(g_gitQueue);
      sent++;
     }
  }

void JournalLocal(string line)
  {
   int h = FileOpen("oracle_journal.csv", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

double AtrD1(string sym)
  {
   int k = -1;
   for(int i = 0; i < ArraySize(g_symCache); i++)
      if(g_symCache[i] == sym) k = i;
   if(k < 0)
     {
      int h = iATR(sym, PERIOD_D1, 14);
      if(h == INVALID_HANDLE) return 0;
      k = ArraySize(g_symCache);
      ArrayResize(g_symCache, k + 1);
      ArrayResize(g_atrHandle, k + 1);
      g_symCache[k] = sym;
      g_atrHandle[k] = h;
     }
   double buf[];
   if(CopyBuffer(g_atrHandle[k], 0, 1, 1, buf) != 1) return 0;   // ATR de la dernière journée clôturée
   return buf[0];
  }

string GV(string name) { return "ORACLE_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagic) + "_" + name; }

// T08 -> 108, S03 -> 203, autre lettre -> 3xx
int IdToNum(string id)
  {
   if(StringLen(id) < 2) return -1;
   ushort c = StringGetCharacter(id, 0);
   int code = (c == 'T') ? 1 : (c == 'S') ? 2 : 3;   // 3 = V (signaux SAV-AFS du robot)
   int n = (int)StringToInteger(StringSubstr(id, 1));
   if(n < 0 || n > 99) return -1;
   return code * 100 + n;
  }

string NumToId(int num)
  {
   int code = num / 100, n = num % 100;
   string p = (code == 1) ? "T" : (code == 2) ? "S" : (code == 4) ? "W" : "V";
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
   int code = -1;
   // Avec le jeton GitHub : lecture par l'API (pas de cache de 5 minutes), sinon adresse brute
   string pre = "https://raw.githubusercontent.com/";
   if(InpGitToken != "" && StringFind(InpSignalURL, pre) == 0)
     {
      string parts[];
      string rest = StringSubstr(InpSignalURL, StringLen(pre));
      int k = StringSplit(rest, '/', parts);
      if(k >= 4)
        {
         string path = parts[3];
         for(int j = 4; j < k; j++) path += "/" + parts[j];
         string api = "https://api.github.com/repos/" + parts[0] + "/" + parts[1] + "/contents/" + path + "?ref=" + parts[2];
         string h = "Authorization: Bearer " + InpGitToken + "\r\nUser-Agent: ORACLE-EA\r\nAccept: application/vnd.github.raw\r\n";
         code = WebRequest("GET", api, h, 8000, post, res, hdr);
        }
     }
   if(code != 200)
     {
      string url = InpSignalURL;
      url += (StringFind(url, "?") >= 0) ? "&t=" : "?t=";
      url += IntegerToString((long)TimeGMT());
      code = WebRequest("GET", url, "", 8000, post, res, hdr);
     }
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
   ArrayResize(g_biasAsset, 0);
   ArrayResize(g_biasVal, 0);
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
         g_exitMode = (k >= 5 && f[4] == "1") ? 1 : 0;   // 5e champ facultatif : mode de sortie
         g_savMode  = (k >= 6) ? (int)StringToInteger(f[5]) : 1;   // 6e champ facultatif : mode SAV-AFS
         g_swMode   = (k >= 7) ? (int)StringToInteger(f[6]) : 1;   // 7e champ facultatif : mode SAV-WS
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
      else if(f[0] == "BIAS" && k >= 3)
        {
         int v = (int)StringToInteger(f[2]);
         int nb = ArraySize(g_biasAsset);
         ArrayResize(g_biasAsset, nb + 1);
         ArrayResize(g_biasVal, nb + 1);
         g_biasAsset[nb] = f[1];
         g_biasVal[nb]   = (v > 0) ? 1 : (v < 0) ? -1 : 0;
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
      if(GlobalVariableCheck(GV("day")) && GlobalVariableCheck(GV("day_bal")))
        {
         // bilan de la journée écoulée (journal local + GitHub), pas de Telegram
         double prevBal = GlobalVariableGet(GV("day_bal"));
         double pk = GlobalVariableCheck(GV("peak_eq")) ? GlobalVariableGet(GV("peak_eq")) : eq;
         string ln = StringFormat("ORACLE_DAY;%I64d;%.0f;%.2f;%.2f;%.2f;%.2f;%s",
                                  AccountInfoInteger(ACCOUNT_LOGIN), GlobalVariableGet(GV("day")), bal, eq, pk,
                                  bal - prevBal, AccountInfoString(ACCOUNT_CURRENCY));
         JournalLocal(ln);
         if(InpGitToken != "") QueuePush(g_gitQueue, ln);
        }
      GlobalVariableSet(GV("day"), day);
      GlobalVariableSet(GV("day_bal"), bal);
      if(GlobalVariableCheck(GV("halt_day"))) GlobalVariableDel(GV("halt_day"));
     }
   double dayBal   = GlobalVariableGet(GV("day_bal"));
   double startBal = GlobalVariableGet(GV("start_bal"));
   // plus haut de l'équité (pour la perte max « suiveuse »)
   double peak = GlobalVariableCheck(GV("peak_eq")) ? GlobalVariableGet(GV("peak_eq")) : MathMax(startBal, eq);
   if(eq > peak) peak = eq;
   GlobalVariableSet(GV("peak_eq"), peak);
   double refTotal = InpTrailingMaxLoss ? peak : startBal;
   if(eq <= refTotal * (1.0 - InpMaxTotalLossPct / 100.0))
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
//| Envoi d'un ordre en attente, confirmé par le serveur             |
//+------------------------------------------------------------------+
// Alerte Telegram sur un refus du courtier, au plus une fois par heure pour un même symbole et un même code
void RefusalAlert(string ctx, string sym)
  {
   uint rc = g_trade.ResultRetcode();
   string key = GV("ref_" + sym + "_" + IntegerToString((int)rc));
   if(GlobalVariableCheck(key) && TimeGMT() - (datetime)GlobalVariableGet(key) < 3600) return;
   GlobalVariableSet(key, (double)TimeGMT());
   Notify(StringFormat("ALERTE : refus du courtier sur %s (%s) : code %d, %s. Vérifier marge, symbole et heures de cotation.",
                       sym, ctx, (int)rc, g_trade.ResultRetcodeDescription()));
  }

bool SendPending(string sym, ENUM_ORDER_TYPE ot, double lot, double price, double sl, double tp, long magic, string comment)
  {
   g_trade.SetExpertMagicNumber(magic);
   g_trade.SetTypeFillingBySymbol(sym);
   long expMode = SymbolInfoInteger(sym, SYMBOL_EXPIRATION_MODE);
   ENUM_ORDER_TYPE_TIME tt = ((expMode & SYMBOL_EXPIRATION_GTC) != 0) ? ORDER_TIME_GTC : ORDER_TIME_DAY;
   if(!g_trade.OrderOpen(sym, ot, lot, 0, price, sl, tp, tt, 0, comment))
      return false;
   uint rc = g_trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
  }

//+------------------------------------------------------------------+
//| Risque déjà engagé et série de pertes                            |
//+------------------------------------------------------------------+
double LossIfStopped(ENUM_ORDER_TYPE dir, string sym, double vol, double from, double sl)
  {
   if(sl <= 0 || vol <= 0) return 0;
   double pl = 0;
   if(!OrderCalcProfit(dir, sym, vol, from, sl, pl)) return 0;
   return (pl < 0) ? -pl : 0;                 // un stop déjà au-delà de l'entrée ne risque plus rien
  }

double OpenRiskMoney()
  {
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs(PositionGetInteger(POSITION_MAGIC))) continue;
      bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      total += LossIfStopped(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, PositionGetString(POSITION_SYMBOL),
                             PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL));
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !IsOurs(OrderGetInteger(ORDER_MAGIC))) continue;
      long ot = OrderGetInteger(ORDER_TYPE);
      bool buy = (ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP);
      total += LossIfStopped(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, OrderGetString(ORDER_SYMBOL),
                             OrderGetDouble(ORDER_VOLUME_CURRENT), OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL));
     }
   return total;
  }

// Nombre d'idées perdantes consécutives (les deux moitiés d'une idée comptent pour une)
int LossStreakNow()
  {
   if(!HistorySelect(TimeCurrent() - 60 * 86400, TimeCurrent() + 86400)) return 0;
   int streak = 0, lastId = -1;
   double ideaPnl = 0;
   bool any = false;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long m = HistoryDealGetInteger(d, DEAL_MAGIC);
      if(!IsOurs(m) || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      int id = MagicId(m);
      double p = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(any && id != lastId)
        {
         if(ideaPnl < 0) streak++;
         else return streak;
         ideaPnl = 0;
        }
      lastId = id;
      ideaPnl += p;
      any = true;
     }
   if(any && ideaPnl < 0) streak++;
   return streak;
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

   // filtre de spread : un spread trop large par rapport au stop dégrade le trade, on attend
   double spread = ask - bid;
   double stopDist = MathAbs(e - sl);
   if(stopDist <= 0) return;
   if(InpMaxSpreadPct > 0 && spread > stopDist * InpMaxSpreadPct / 100.0)
     {
      string k = GV("spr_" + IntegerToString(idnum));
      if(!GlobalVariableCheck(k) || TimeCurrent() - (datetime)GlobalVariableGet(k) > 3600)
        {
         Print("ORACLE : ", s.id, " spread trop large (", DoubleToString(spread / stopDist * 100.0, 1), " % du stop), ordre reporté.");
         GlobalVariableSet(k, (double)TimeCurrent());
        }
      return;
     }

   double riskPct = (InpRiskOverride > 0) ? InpRiskOverride : g_risk;
   riskPct = MathMin(riskPct, InpMaxRiskPct);
   int streak = LossStreakNow();
   if(InpLossStreak > 0 && streak >= InpLossStreak)
      riskPct *= InpStreakFactor;               // série de pertes : on réduit jusqu'au prochain gain
   if(riskPct <= 0) return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;
   // plafond du risque total engagé (positions + ordres en attente)
   if(InpMaxOpenRiskPct > 0 && OpenRiskMoney() + riskMoney > equity * InpMaxOpenRiskPct / 100.0)
     {
      string k = GV("heat_" + IntegerToString(idnum));
      if(!GlobalVariableCheck(k))
        {
         Notify(s.id + " : ordre non posé, le risque total engagé dépasserait " + DoubleToString(InpMaxOpenRiskPct, 1) + " % du capital.");
         GlobalVariableSet(k, 1);
        }
      return;
     }
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

   bool ok = SendPending(sym, ot, lotA, e, sl, t1, MakeMagic(idnum, 1), "ORACLE " + s.id + " A");
   if(ok && lotB > 0)
      ok = SendPending(sym, ot, lotB, e, sl, t2, MakeMagic(idnum, 2), "ORACLE " + s.id + " B");
   if(!ok)
     {
      Print("ORACLE : ", s.id, " refus du courtier : ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      RefusalAlert("idée " + s.id, sym);
      DeletePending("échec de pose", idnum);
      return;
     }
   GlobalVariableSet(GV("tp1_" + IntegerToString(idnum)), t1);
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   Notify(StringFormat("%s %s %s %s posé : entrée %s, stop %s, TP1 %s%s, lots %s+%s, risque %.2f %%%s",
                       s.id, sym, s.side == "BUY" ? "achat" : "vente", s.type == "LIMIT" ? "limite" : "stop",
                       DoubleToString(e, d), DoubleToString(sl, d), DoubleToString(t1, d),
                       t2 > 0 ? ", TP2 " + DoubleToString(t2, d) : "",
                       DoubleToString(lotA, 2), DoubleToString(lotB, 2), riskPct,
                       (InpLossStreak > 0 && streak >= InpLossStreak) ? " (réduit après " + IntegerToString(streak) + " pertes d'affilée)" : ""));
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
      else if(idnum >= 400 && idnum < 500) continue;     // ordres SAV-WS : tenus par SwProcess
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
         continue;
        }
      // Sortie « ATR » : une fois à break-even, le stop suit le prix à N x ATR(14) journalier, sans jamais reculer
      if(g_exitMode == 1 && already && InpTrailATRMult > 0)
        {
         double atr = AtrD1(sym);
         if(atr <= 0) continue;
         double cand = RoundPrice(sym, buy ? px - InpTrailATRMult * atr : px + InpTrailATRMult * atr);
         double minGap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
         double step = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
         bool better = buy ? (cand > sl + step && cand < px - minGap) : (cand < sl - step && cand > px + minGap);
         if(better)
           {
            g_trade.SetExpertMagicNumber(m);
            if(g_trade.PositionModify(t, cand, tp))
               Print("ORACLE : ", NumToId(MagicId(m)), " stop suiveur ATR déplacé à ", DoubleToString(cand, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| SAV-AFS : moteur intégré (traduction du script TradingView v5)   |
//| Achat : biais haussier -> LL -> impulsion -> retracement Fibo -> |
//|         HL -> BOS (clôture au-dessus du sommet de l'impulsion)   |
//| Vente : miroir exact.                                            |
//| H4 : pivots 3 + prix / SMA 200 ; H1 : pivots 5 + EMA20>EMA50>SMA200|
//| Entrée au BOS confirmé (clôture), stop sous le HL - 0,2 ATR,     |
//| objectif 2R. Calcul refait à chaque nouvelle bougie clôturée sur |
//| tout l'historique récent : aucun état perdu au redémarrage.      |
//+------------------------------------------------------------------+
struct SavHit
  {
   bool              found;
   bool              buy;
   double            entry;
   double            sl;
   double            tp;
   datetime          t;      // heure d'ouverture de la bougie du signal
  };

int SavModeNow() { return (InpSavMode >= 0) ? InpSavMode : g_savMode; }

int BiasOf(string asset)
  {
   for(int i = 0; i < ArraySize(g_biasAsset); i++)
      if(g_biasAsset[i] == asset) return g_biasVal[i];
   return 0;
  }

bool IsPivotHigh(MqlRates &r[], int c, int L)
  {
   for(int j = c - L; j <= c + L; j++)
     {
      if(j == c) continue;
      if(j < c && r[j].high >= r[c].high) return false;
      if(j > c && r[j].high >  r[c].high) return false;
     }
   return true;
  }

bool IsPivotLow(MqlRates &r[], int c, int L)
  {
   for(int j = c - L; j <= c + L; j++)
     {
      if(j == c) continue;
      if(j < c && r[j].low <= r[c].low) return false;
      if(j > c && r[j].low <  r[c].low) return false;
     }
   return true;
  }

// Rejoue la structure sur ~700 bougies et dit si la dernière bougie clôturée donne un signal.
bool SavScan(string sym, ENUM_TIMEFRAMES tf, int L, bool aligned, SavHit &hit)
  {
   hit.found = false;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(sym, tf, 0, 700, r);
   if(n < 260) return false;
   int last = n - 2;                              // dernière bougie clôturée (n - 1 = bougie en cours)

   double atr[], e20[], e50[], s200[];
   ArrayResize(atr, n); ArrayResize(e20, n); ArrayResize(e50, n); ArrayResize(s200, n);
   double sumTR = 0, sum200 = 0;
   double a20 = 2.0 / 21.0, a50 = 2.0 / 51.0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[i].high - r[i].low :
                  MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < 14) { sumTR += tr; atr[i] = sumTR / (i + 1); }
      else atr[i] = (atr[i - 1] * 13.0 + tr) / 14.0;        // ATR de Wilder, comme ta.atr
      e20[i] = (i == 0) ? r[i].close : a20 * r[i].close + (1 - a20) * e20[i - 1];
      e50[i] = (i == 0) ? r[i].close : a50 * r[i].close + (1 - a50) * e50[i - 1];
      sum200 += r[i].close;
      if(i >= 200) sum200 -= r[i - 200].close;
      s200[i] = (i >= 199) ? sum200 / 200.0 : 0;
     }

   double fMin = InpSavFibMin, fMax = InpSavFibMax;
   int mb = InpSavMaxBars;
   double prevPH = 0, prevPL = 0;
   bool havePH = false, havePL = false;
   // achat
   int bState = 0, bLLBar = -1, bHBar = -1, bHLBar = -1;
   double bLL = 0, bH = 0, bHL = 0;
   // vente
   int sState = 0, sHHBar = -1, sLBar = -1, sLHBar = -1;
   double sHH = 0, sL = 0, sLH = 0;

   for(int t = 2 * L; t <= last; t++)
     {
      int pb = t - L;
      bool newPH = IsPivotHigh(r, pb, L);
      bool newPL = IsPivotLow(r, pb, L);
      double ph = r[pb].high, pl = r[pb].low;
      bool isHH = newPH && havePH && ph > prevPH;
      bool isLL = newPL && havePL && pl < prevPL;
      bool trendOk = (t >= 199);
      bool trendLong  = trendOk && (aligned ? (e20[t] > e50[t] && e50[t] > s200[t]) : r[t].close > s200[t]);
      bool trendShort = trendOk && (aligned ? (e20[t] < e50[t] && e50[t] < s200[t]) : r[t].close < s200[t]);

      //--- ACHAT : a) annulations
      if(bState > 0 && r[t].low < bLL) bState = 0;
      if(bState == 1 && t - bLLBar > mb) bState = 0;
      if(bState == 2 && (r[t].low < bH - (bH - bLL) * fMax || t - bHBar > mb)) bState = 0;
      if(bState == 3 && (r[t].close < bHL || t - bHLBar > mb)) bState = 0;
      // b) nouveau LL
      if(isLL && bState <= 1) { bState = 1; bLL = pl; bLLBar = pb; }
      // c) impulsion
      if(newPH && bLLBar >= 0 && pb > bLLBar && (bState == 1 || (bState == 2 && ph > bH))) { bH = ph; bHBar = pb; bState = 2; }
      // d) HL dans la zone Fibonacci
      if(bState == 2 && newPL && pb > bHBar)
        {
         double rg = bH - bLL;
         if(rg > 0)
           {
            double retr = (bH - pl) / rg;
            if(retr >= fMin && retr <= fMax) { bHL = pl; bHLBar = pb; bState = 3; }
            else if(retr > fMax) bState = 0;
           }
        }
      // e) BOS
      if(bState == 3 && r[t].close > bH)
        {
         if(trendLong && t == last)
           {
            hit.found = true; hit.buy = true; hit.entry = r[t].close;
            hit.sl = bHL - atr[t] * InpSavAtrMult;
            hit.tp = hit.entry + (hit.entry - hit.sl) * InpSavRR;
            hit.t = r[t].time;
           }
         bState = 0;
        }

      //--- VENTE : miroir
      if(sState > 0 && r[t].high > sHH) sState = 0;
      if(sState == 1 && t - sHHBar > mb) sState = 0;
      if(sState == 2 && (r[t].high > sL + (sHH - sL) * fMax || t - sLBar > mb)) sState = 0;
      if(sState == 3 && (r[t].close > sLH || t - sLHBar > mb)) sState = 0;
      if(isHH && sState <= 1) { sState = 1; sHH = ph; sHHBar = pb; }
      if(newPL && sHHBar >= 0 && pb > sHHBar && (sState == 1 || (sState == 2 && pl < sL))) { sL = pl; sLBar = pb; sState = 2; }
      if(sState == 2 && newPH && pb > sLBar)
        {
         double rg = sHH - sL;
         if(rg > 0)
           {
            double retr = (ph - sL) / rg;
            if(retr >= fMin && retr <= fMax) { sLH = ph; sLHBar = pb; sState = 3; }
            else if(retr > fMax) sState = 0;
           }
        }
      if(sState == 3 && r[t].close < sL)
        {
         if(trendShort && t == last && !hit.found)
           {
            hit.found = true; hit.buy = false; hit.entry = r[t].close;
            hit.sl = sLH + atr[t] * InpSavAtrMult;
            hit.tp = hit.entry - (hit.sl - hit.entry) * InpSavRR;
            hit.t = r[t].time;
           }
         sState = 0;
        }

      if(newPH) { prevPH = ph; havePH = true; }
      if(newPL) { prevPL = pl; havePL = true; }
     }
   return true;
  }

//--- trades virtuels (mode observation), sauvegardés dans MQL5\Files
void SaveVirtual()
  {
   int h = FileOpen("oracle_sav_virtual.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   for(int i = 0; i < ArraySize(g_vSym); i++)
      FileWriteString(h, StringFormat("%s;%s;%d;%d;%I64d;%.10g;%.10g;%.10g\r\n", g_vAsset[i], g_vSym[i], g_vTf[i], g_vBuy[i],
                                      (long)g_vTime[i], g_vE[i], g_vSL[i], g_vTP[i]));
   FileClose(h);
  }

void AddVirtual(string asset, string sym, int tfh, bool buy, datetime t, double e, double sl, double tp)
  {
   int n = ArraySize(g_vSym);
   if(n >= 100) return;
   ArrayResize(g_vAsset, n + 1); ArrayResize(g_vSym, n + 1); ArrayResize(g_vTf, n + 1); ArrayResize(g_vBuy, n + 1);
   ArrayResize(g_vTime, n + 1); ArrayResize(g_vE, n + 1); ArrayResize(g_vSL, n + 1); ArrayResize(g_vTP, n + 1);
   g_vAsset[n] = asset; g_vSym[n] = sym; g_vTf[n] = tfh; g_vBuy[n] = buy ? 1 : 0;
   g_vTime[n] = t; g_vE[n] = e; g_vSL[n] = sl; g_vTP[n] = tp;
  }

void RemoveVirtual(int k)
  {
   int n = ArraySize(g_vSym);
   for(int i = k; i < n - 1; i++)
     {
      g_vAsset[i] = g_vAsset[i + 1]; g_vSym[i] = g_vSym[i + 1]; g_vTf[i] = g_vTf[i + 1]; g_vBuy[i] = g_vBuy[i + 1];
      g_vTime[i] = g_vTime[i + 1]; g_vE[i] = g_vE[i + 1]; g_vSL[i] = g_vSL[i + 1]; g_vTP[i] = g_vTP[i + 1];
     }
   ArrayResize(g_vAsset, n - 1); ArrayResize(g_vSym, n - 1); ArrayResize(g_vTf, n - 1); ArrayResize(g_vBuy, n - 1);
   ArrayResize(g_vTime, n - 1); ArrayResize(g_vE, n - 1); ArrayResize(g_vSL, n - 1); ArrayResize(g_vTP, n - 1);
  }

void LoadVirtual()
  {
   string txt;
   if(!LoadFile("oracle_sav_virtual.csv", txt)) return;
   StringReplace(txt, "\r", "");
   string lines[];
   int n = StringSplit(txt, '\n', lines);
   for(int i = 0; i < n; i++)
     {
      string f[];
      if(StringSplit(lines[i], ';', f) < 8) continue;
      AddVirtual(f[0], f[1], (int)StringToInteger(f[2]), f[3] == "1", (datetime)StringToInteger(f[4]),
                 StringToDouble(f[5]), StringToDouble(f[6]), StringToDouble(f[7]));
     }
  }

void SavJournal(string line)
  {
   JournalLocal(line);
   if(InpGitToken != "") QueuePush(g_gitQueue, line);
  }

// Suivi des trades virtuels : stop ou objectif touché sur les bougies suivantes (stop prioritaire si les deux)
void UpdateVirtual()
  {
   bool changed = false;
   for(int i = ArraySize(g_vSym) - 1; i >= 0; i--)
     {
      ENUM_TIMEFRAMES tf = (g_vTf[i] == 4) ? PERIOD_H4 : PERIOD_H1;
      MqlRates r[];
      ArraySetAsSeries(r, false);
      int n = CopyRates(g_vSym[i], tf, g_vTime[i] + PeriodSeconds(tf), TimeCurrent(), r);
      if(n <= 0) continue;
      bool buy = (g_vBuy[i] == 1);
      double risk = MathAbs(g_vE[i] - g_vSL[i]);
      double R = 0;
      bool done = false;
      string why = "";
      for(int j = 0; j < n && !done; j++)
        {
         bool hitSL = buy ? (r[j].low <= g_vSL[i]) : (r[j].high >= g_vSL[i]);
         bool hitTP = buy ? (r[j].high >= g_vTP[i]) : (r[j].low <= g_vTP[i]);
         if(hitSL) { R = -1.0; done = true; why = "stop"; }
         else if(hitTP) { R = InpSavRR; done = true; why = "objectif"; }
        }
      if(!done && TimeCurrent() - g_vTime[i] > 20 * 86400 && risk > 0)
        {
         double last = r[n - 1].close;
         R = (buy ? last - g_vE[i] : g_vE[i] - last) / risk;
         done = true; why = "expire";
        }
      if(done)
        {
         SavJournal(StringFormat("SAV_RESULT;%I64d;%s;%s;H%d;%s;%s;%s;%.2f;OBS",
                                 AccountInfoInteger(ACCOUNT_LOGIN), g_vAsset[i], g_vSym[i], g_vTf[i], buy ? "BUY" : "SELL",
                                 TimeToString(g_vTime[i], TIME_DATE | TIME_MINUTES), why, R));
         RemoveVirtual(i);
         changed = true;
        }
     }
   if(changed) SaveVirtual();
  }

// Ordre au marché pour un signal SAV-AFS (mode trading), mêmes garde-fous de risque que les idées du plan
bool PlaceSavMarket(string asset, string sym, int tfh, SavHit &h)
  {
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) return false;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID), ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return false;
   double px = h.buy ? ask : bid;
   double sl = RoundPrice(sym, h.sl);
   double gap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
   if(h.buy ? (sl >= bid - gap) : (sl <= ask + gap)) { Print("ORACLE : SAV ", sym, " le prix est déjà au stop, signal ignoré."); return false; }
   double dist = MathAbs(px - sl);
   double tp = RoundPrice(sym, h.buy ? px + dist * InpSavRR : px - dist * InpSavRR);
   if(InpMaxSpreadPct > 0 && (ask - bid) > dist * InpMaxSpreadPct / 100.0) { Print("ORACLE : SAV ", sym, " spread trop large, signal ignoré."); return false; }

   double riskPct = MathMin((InpRiskOverride > 0) ? InpRiskOverride : g_risk, InpMaxRiskPct);
   int streak = LossStreakNow();
   if(InpLossStreak > 0 && streak >= InpLossStreak) riskPct *= InpStreakFactor;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;
   if(InpMaxOpenRiskPct > 0 && OpenRiskMoney() + riskMoney > equity * InpMaxOpenRiskPct / 100.0)
     {
      Print("ORACLE : SAV ", sym, " non pris, risque total engagé au plafond.");
      return false;
     }
   double pl1 = 0;
   if(!OrderCalcProfit(h.buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, 1.0, px, sl, pl1) || pl1 == 0) return false;
   double lot = NormLot(sym, riskMoney / MathAbs(pl1));
   if(lot <= 0) { Print("ORACLE : SAV ", sym, " capital trop petit pour ce stop."); return false; }

   int seq = GlobalVariableCheck(GV("sav_seq")) ? (int)GlobalVariableGet(GV("sav_seq")) : 0;
   int idnum = -1;
   for(int k = 0; k < 99; k++)
     {
      seq = seq % 99 + 1;
      if(!HasOrderOrPosition(300 + seq)) { idnum = 300 + seq; break; }
     }
   if(idnum < 0) return false;
   GlobalVariableSet(GV("sav_seq"), seq);
   string id = NumToId(idnum);
   g_trade.SetExpertMagicNumber(MakeMagic(idnum, 1));
   g_trade.SetTypeFillingBySymbol(sym);
   string cmt = "ORACLE " + id + " SAV H" + IntegerToString(tfh);
   bool ok = h.buy ? g_trade.Buy(lot, sym, 0, sl, tp, cmt) : g_trade.Sell(lot, sym, 0, sl, tp, cmt);
   if(!ok || (g_trade.ResultRetcode() != TRADE_RETCODE_DONE && g_trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      Print("ORACLE : SAV ", sym, " refus du courtier : ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      RefusalAlert("SAV-AFS", sym);
      return false;
     }
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   Notify(StringFormat("%s SAV-AFS H%d %s %s au marché : stop %s, objectif %s (%.1fR), lot %s, risque %.2f %%",
                       id, tfh, sym, h.buy ? "achat" : "vente", DoubleToString(sl, d), DoubleToString(tp, d), InpSavRR,
                       DoubleToString(lot, 2), riskPct));
   return true;
  }

// Appelé à chaque cycle : une analyse par actif et par unité, à chaque nouvelle bougie clôturée
void SavProcess(bool allowed)
  {
   int mode = SavModeNow();
   if(mode <= 0) return;
   UpdateVirtual();
   for(int i = 0; i < ArraySize(g_biasAsset); i++)
     {
      int bias = g_biasVal[i];
      if(bias == 0) continue;                     // biais neutre : aucun signal (comme le script TradingView)
      string asset = g_biasAsset[i];
      string sym = ResolveSymbol(asset);
      if(sym == "") continue;
      for(int u = 0; u < 2; u++)
        {
         ENUM_TIMEFRAMES tf = (u == 0) ? PERIOD_H4 : PERIOD_H1;
         int tfh = (u == 0) ? 4 : 1;
         int L = (u == 0) ? 3 : 5;
         bool aligned = (u == 1);
         datetime barT = iTime(sym, tf, 1);
         if(barT == 0) continue;
         string key = GV("sv" + IntegerToString(tfh) + "_" + sym);
         if(GlobalVariableCheck(key) && (datetime)GlobalVariableGet(key) == barT) continue;
         SavHit h;
         if(!SavScan(sym, tf, L, aligned, h)) continue;   // historique pas encore chargé : on réessaiera
         GlobalVariableSet(key, (double)barT);
         if(!h.found) continue;
         if(h.buy != (bias > 0)) continue;          // seulement dans le sens du biais fondamental
         if(TimeCurrent() - (h.t + PeriodSeconds(tf)) > 15 * 60) continue;   // signal trop ancien (robot redémarré)
         int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         string taken = "OBS";
         if(mode == 2)
           {
            taken = "NON_PRIS";
            if(allowed && CountActiveIds() < InpMaxTrades && PlaceSavMarket(asset, sym, tfh, h)) taken = "PRIS";
           }
         else
           {
            AddVirtual(asset, sym, tfh, h.buy, h.t, h.entry, h.sl, h.tp);
            SaveVirtual();
           }
         SavJournal(StringFormat("SAV_SIGNAL;%I64d;%s;%s;H%d;%s;%s;%s;%s;%s;%s",
                                 AccountInfoInteger(ACCOUNT_LOGIN), asset, sym, tfh, h.buy ? "BUY" : "SELL",
                                 TimeToString(h.t + PeriodSeconds(tf), TIME_DATE | TIME_MINUTES),
                                 DoubleToString(h.entry, d), DoubleToString(h.sl, d), DoubleToString(h.tp, d), taken));
        }
     }
  }

//+------------------------------------------------------------------+
//| Boucle principale                                                |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Heure de Paris (heure d'été européenne gérée)                    |
//+------------------------------------------------------------------+
datetime LastSundayUTC(int year, int month)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = (month == 12) ? year + 1 : year;
   t.mon  = (month == 12) ? 1 : month + 1;
   t.day  = 1;
   datetime last = StructToTime(t) - 86400;          // dernier jour du mois, 00:00
   MqlDateTime l;
   TimeToStruct(last, l);
   return last - l.day_of_week * 86400;              // dernier dimanche, 00:00 UTC
  }

datetime ParisNow()
  {
   datetime u = TimeGMT();
   MqlDateTime d;
   TimeToStruct(u, d);
   datetime summerStart = LastSundayUTC(d.year, 3) + 3600;   // dernier dimanche de mars, 01:00 UTC
   datetime summerEnd   = LastSundayUTC(d.year, 10) + 3600;  // dernier dimanche d'octobre, 01:00 UTC
   return u + ((u >= summerStart && u < summerEnd) ? 7200 : 3600);
  }

// 0 = semaine normale ; 1 = vendredi après l'heure de fermeture ; 2 = samedi ou dimanche avant 23h
int WeekendState()
  {
   if(!InpFridayClose) return 0;
   MqlDateTime p;
   TimeToStruct(ParisNow(), p);
   int mins = p.hour * 60 + p.min, cut = InpFridayHour * 60 + InpFridayMinute;
   if(p.day_of_week == 5 && mins >= cut) return 1;
   if(p.day_of_week == 6) return 2;
   if(p.day_of_week == 0 && p.hour < 23) return 2;
   return 0;
  }

void FridayClose()
  {
   int open = 0, closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs(PositionGetInteger(POSITION_MAGIC))) continue;
      open++;
      if(g_trade.PositionClose(t)) closed++;
     }
   MqlDateTime p;
   TimeToStruct(ParisNow(), p);
   string key = GV("fri_" + StringFormat("%04d%02d%02d", p.year, p.mon, p.day));
   if(open > 0 && !GlobalVariableCheck(key))
     {
      GlobalVariableSet(key, 1);
      if(closed == open)
         Notify("fermeture du vendredi : " + IntegerToString(open) + " position(s) fermée(s), pause jusqu'à dimanche 23h.");
      else
         Notify(StringFormat("ALERTE fermeture du vendredi : %d position(s) sur %d pas encore fermée(s) (marché fermé ou refus). Le robot réessaie, puis les fermera à la réouverture.",
                             open - closed, open));
     }
  }

//+------------------------------------------------------------------+
//| SAV-WS : filtres SAV-AFS + entrée WinStructure (version 1.09)    |
//| Traduction du script TradingView « SAV-WS v3 ».                  |
//| Déclencheur : BOS ou CHoCH (clôture au-delà du dernier pivot),   |
//| dans le sens du biais ORACLE, tendance H4 (prix / SMA 200) et    |
//| alignement EMA 20 / EMA 50 / SMA 200 sur l'unité du signal.      |
//| Entrée : ordre limite sur le premier niveau Fibo (0.618, 0.705,  |
//| 0.786, 0.893, 1) qui touche la confluence OB / FVG.              |
//| Stop : derrière la confluence + 0,2 ATR. Objectif : Fibo -0.5.   |
//| Confluences comptées : OB, FVG, liquidité (sweep de pivot, PDH / |
//| PDL ou range asiatique, 1 point), MSS, Premium / Discount,       |
//| killzone, zone OB / FVG de l'unité supérieure.                   |
//| Le calcul est rejoué sur l'historique récent à chaque bougie     |
//| clôturée : aucun état perdu au redémarrage.                      |
//+------------------------------------------------------------------+
struct SwRes
  {
   int               state;    // dernière bougie clôturée : 0 rien, 1 ordre limite valide, 2 en position
   bool              buy;
   double            entry;
   double            sl;
   double            tp;
   double            rr;
   double            lvl;      // niveau Fibo de l'entrée
   string            conf;
  };

int SwModeNow() { return (InpSwMode >= 0) ? InpSwMode : g_swMode; }

void QueuePushLocal(string &q[], string item)
  {
   int n = ArraySize(q);
   ArrayResize(q, n + 1);
   q[n] = item;
  }

void QueuePushInt(int &q[], int v)
  {
   int n = ArraySize(q);
   ArrayResize(q, n + 1);
   q[n] = v;
  }

void SwReset(SwRes &x)
  {
   x.state = 0; x.buy = true; x.entry = 0; x.sl = 0; x.tp = 0; x.rr = 0; x.lvl = 0; x.conf = "";
  }

// mémoire du dernier calcul, par actif et par unité
string   g_swKey[];
datetime g_swBar[];
int      g_swState[];
bool     g_swBuy[];
double   g_swE[];
double   g_swSL[];
double   g_swTP[];
double   g_swRR[];
double   g_swLvl[];
string   g_swConf[];

int SwSlot(string key)
  {
   int n = ArraySize(g_swKey);
   for(int i = 0; i < n; i++) if(g_swKey[i] == key) return i;
   ArrayResize(g_swKey, n + 1); ArrayResize(g_swBar, n + 1); ArrayResize(g_swState, n + 1); ArrayResize(g_swBuy, n + 1);
   ArrayResize(g_swE, n + 1); ArrayResize(g_swSL, n + 1); ArrayResize(g_swTP, n + 1); ArrayResize(g_swRR, n + 1);
   ArrayResize(g_swLvl, n + 1); ArrayResize(g_swConf, n + 1);
   g_swKey[n] = key; g_swBar[n] = 0; g_swState[n] = 0; g_swBuy[n] = true;
   g_swE[n] = 0; g_swSL[n] = 0; g_swTP[n] = 0; g_swRR[n] = 0; g_swLvl[n] = 0; g_swConf[n] = "";
   return n;
  }

string SwTfName(ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
  }

double SwFib(double orig, double ext, double lvl) { return ext + lvl * (orig - ext); }

int SwHM(string s)
  {
   string p[];
   if(StringSplit(s, ':', p) < 2) return -1;
   return (int)StringToInteger(p[0]) * 60 + (int)StringToInteger(p[1]);
  }

// "08:00-11:00" : vrai si les minutes (heure de Paris) sont dans la plage
bool SwInSess(int mins, string sess)
  {
   string p[];
   if(StringSplit(sess, '-', p) < 2) return false;
   int a = SwHM(p[0]), b = SwHM(p[1]);
   if(a < 0 || b < 0) return false;
   if(a <= b) return (mins >= a && mins < b);
   return (mins >= a || mins < b);
  }

int ParisOffsetAt(datetime utc)
  {
   MqlDateTime d;
   TimeToStruct(utc, d);
   datetime s = LastSundayUTC(d.year, 3) + 3600;
   datetime e = LastSundayUTC(d.year, 10) + 3600;
   return (utc >= s && utc < e) ? 7200 : 3600;
  }

// minutes de la journée, heure de Paris, pour une heure du serveur du courtier
int SwParisMinutes(datetime srvTime, int srvOff)
  {
   datetime u = srvTime - srvOff;
   MqlDateTime d;
   TimeToStruct(u + ParisOffsetAt(u), d);
   return d.hour * 60 + d.min;
  }

// ATR de Wilder, EMA 20, EMA 50 et SMA 200 (identiques à ta.atr, ta.ema, ta.sma)
void SwBase(MqlRates &r[], int n, double &atr[], double &e20[], double &e50[], double &s200[])
  {
   ArrayResize(atr, n); ArrayResize(e20, n); ArrayResize(e50, n); ArrayResize(s200, n);
   double sumTR = 0, sum200 = 0;
   double a20 = 2.0 / 21.0, a50 = 2.0 / 51.0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[i].high - r[i].low :
                  MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < 14) { sumTR += tr; atr[i] = sumTR / (i + 1); }
      else atr[i] = (atr[i - 1] * 13.0 + tr) / 14.0;
      e20[i] = (i == 0) ? r[i].close : a20 * r[i].close + (1 - a20) * e20[i - 1];
      e50[i] = (i == 0) ? r[i].close : a50 * r[i].close + (1 - a50) * e50[i - 1];
      sum200 += r[i].close;
      if(i >= 200) sum200 -= r[i - 200].close;
      s200[i] = (i >= 199) ? sum200 / 200.0 : 0;
     }
  }

void SwPushPivot(double &pp[], int &pi[], double price, int idx)
  {
   int n = ArraySize(pp);
   if(n >= 50)
     {
      for(int i = 0; i < n - 1; i++) { pp[i] = pp[i + 1]; pi[i] = pi[i + 1]; }
      pp[n - 1] = price; pi[n - 1] = idx;
      return;
     }
   ArrayResize(pp, n + 1); ArrayResize(pi, n + 1);
   pp[n] = price; pi[n] = idx;
  }

//--- Évaluation d'un setup (dir = 1 achat, -1 vente) : confluences de la zone, entrée, stop, objectif
void SwEval(MqlRates &r[], int t, int dir, int oIdx, double orig, double ext, double atrV, bool mss,
            double &pp[], int &pi[],
            int &cnt, string &txt, bool &keyOk, bool &swOk,
            double &entry, double &eL, double &sl, double &tp, double &rr, double &zLo, double &zHi)
  {
   bool buy = (dir > 0);
   double rng = MathAbs(ext - orig);
   double z618 = SwFib(orig, ext, 0.618);
   zLo = buy ? orig : z618;
   zHi = buy ? z618 : orig;
   int oOff = MathMin(t - oIdx, 900);
   // Order Block : dernière bougie opposée à l'origine de l'impulsion ou juste avant
   bool obOk = false;
   double obT = 0, obB = 0;
   int iMax = MathMin(oOff + InpSwObLook, t);
   for(int i = oOff; i <= iMax; i++)
     {
      int k = t - i;
      bool opp = buy ? (r[k].close < r[k].open) : (r[k].close > r[k].open);
      if(opp)
        {
         if(r[k].low <= zHi && r[k].high >= zLo) { obOk = true; obT = r[k].high; obB = r[k].low; }
         break;
        }
     }
   // FVG de l'impulsion qui chevauche la zone 0.618 - 1
   bool fvOk = false;
   double fvT = 0, fvB = 0;
   for(int i = 0; i <= oOff - 2; i++)
     {
      int k = t - i;
      double gT = buy ? r[k].low : r[k - 2].low;
      double gB = buy ? r[k - 2].high : r[k].high;
      if(gT > gB && gB <= zHi && gT >= zLo)
        {
         bool better = !fvOk || (buy ? gT > fvT : gB < fvB);
         if(better) { fvOk = true; fvT = gT; fvB = gB; }
        }
     }
   // Sweep : l'origine a pris le dernier pivot opposé
   swOk = false;
   for(int j = ArraySize(pp) - 1; j >= 0; j--)
      if(pi[j] < oIdx) { swOk = buy ? (orig < pp[j]) : (orig > pp[j]); break; }
   bool mssOk = mss;
   keyOk = obOk || fvOk || swOk;
   cnt = (obOk ? 1 : 0) + (fvOk ? 1 : 0) + (swOk ? 1 : 0) + (mssOk ? 1 : 0);
   string parts = "";
   if(obOk)  parts += "OB";
   if(fvOk)  parts += (parts == "" ? "" : "+") + "FVG";
   if(swOk)  parts += (parts == "" ? "" : "+") + "Sweep";
   if(mssOk) parts += (parts == "" ? "" : "+") + "MSS";
   txt = parts;
   bool hasC = obOk || fvOk;
   double cTop = (obOk && fvOk) ? MathMax(obT, fvT) : obOk ? obT : fvT;
   double cBot = (obOk && fvOk) ? MathMin(obB, fvB) : obOk ? obB : fvB;
   // entrée : premier niveau Fibo qui touche la confluence (sinon 0.705)
   eL = 0.705;
   if(hasC)
     {
      double lv[5] = {0.618, 0.705, 0.786, 0.893, 1.0};
      for(int i = 0; i < 5; i++)
        {
         double p = SwFib(orig, ext, lv[i]);
         if(buy ? (p <= cTop) : (p >= cBot)) { eL = lv[i]; break; }
        }
     }
   entry = SwFib(orig, ext, eL);
   // stop derrière la confluence
   double buf = InpSwSlAtr * atrV;
   if(buf <= 0) buf = atrV * 0.01;
   if(buy)
     {
      sl = hasC ? cBot - buf : orig - buf;
      if(sl >= entry - 0.05 * rng) sl = MathMin(sl, orig - buf);
     }
   else
     {
      sl = hasC ? cTop + buf : orig + buf;
      if(sl <= entry + 0.05 * rng) sl = MathMax(sl, orig + buf);
     }
   tp = SwFib(orig, ext, InpSwTarget);
   double risk = MathAbs(entry - sl);
   rr = (risk > 0) ? (buy ? tp - entry : entry - tp) / risk : 0;
  }

//--- Rejoue SAV-WS sur l'historique. ev[] reçoit les événements de la dernière bougie clôturée.
bool SwScan(string sym, ENUM_TIMEFRAMES tf, int bias, int srvOff, SwRes &res, string &ev[])
  {
   SwReset(res);
   ArrayResize(ev, 0);
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(sym, tf, 0, 1000, r);
   if(n < 300) return false;
   int last = n - 2;
   int L = InpSwPivot;
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double spr = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   if(spr < 0) spr = 0;

   double atr[];
   double e20[];
   double e50[];
   double s200[];
   SwBase(r, n, atr, e20, e50, s200);

   //--- unité supérieure : tendance, Premium / Discount, zones OB / FVG (bougies clôturées seulement)
   bool htfOn = PeriodSeconds(InpSwHTF) > PeriodSeconds(tf);
   MqlRates h[];
   ArraySetAsSeries(h, false);
   int m = 0;
   double hSma[];
   double hHi[];
   double hLo[];
   double zbT[];
   double zbB[];
   double zsT[];
   double zsB[];
   double obT_[];
   double obB_[];
   double osT[];
   double osB[];
   if(htfOn)
     {
      m = CopyRates(sym, InpSwHTF, 0, 500, h);
      if(m < 210) return false;
      ArrayResize(hSma, m); ArrayResize(hHi, m); ArrayResize(hLo, m);
      ArrayResize(zbT, m); ArrayResize(zbB, m); ArrayResize(zsT, m); ArrayResize(zsB, m);
      ArrayResize(obT_, m); ArrayResize(obB_, m); ArrayResize(osT, m); ArrayResize(osB, m);
      double s = 0, bfT = 0, bfB = 0, sfT = 0, sfB = 0, boT = 0, boB = 0, soT = 0, soB = 0;
      for(int k = 0; k < m; k++)
        {
         s += h[k].close;
         if(k >= 200) s -= h[k - 200].close;
         hSma[k] = (k >= 199) ? s / 200.0 : 0;
         double hi = h[k].high, lo = h[k].low;
         for(int j = MathMax(0, k - InpSwPdLen + 1); j <= k; j++) { hi = MathMax(hi, h[j].high); lo = MathMin(lo, h[j].low); }
         hHi[k] = (k >= InpSwPdLen - 1) ? hi : 0;
         hLo[k] = (k >= InpSwPdLen - 1) ? lo : 0;
         if(k >= 2)
           {
            if(h[k].low > h[k - 2].high) { bfT = h[k].low; bfB = h[k - 2].high; }
            if(h[k].high < h[k - 2].low) { sfT = h[k - 2].low; sfB = h[k].high; }
            if(h[k].close > h[k - 1].high && h[k - 1].close < h[k - 1].open) { boT = h[k - 1].high; boB = h[k - 1].low; }
            if(h[k].close < h[k - 1].low && h[k - 1].close > h[k - 1].open) { soT = h[k - 1].high; soB = h[k - 1].low; }
            if(bfB > 0 && h[k].close < bfB) { bfT = 0; bfB = 0; }
            if(sfT > 0 && h[k].close > sfT) { sfT = 0; sfB = 0; }
            if(boB > 0 && h[k].close < boB) { boT = 0; boB = 0; }
            if(soT > 0 && h[k].close > soT) { soT = 0; soB = 0; }
           }
         zbT[k] = bfT; zbB[k] = bfB; zsT[k] = sfT; zsB[k] = sfB;
         obT_[k] = boT; obB_[k] = boB; osT[k] = soT; osB[k] = soB;
        }
     }
   //--- veille : plus haut / plus bas
   MqlRates dd[];
   ArraySetAsSeries(dd, false);
   int nd = CopyRates(sym, PERIOD_D1, 0, 120, dd);

   //--- état de la structure
   double lastHigh = 0, lastLow = 0;
   int lastHighIdx = -1, lastLowIdx = -1, trend = 0;
   bool highBroken = true, lowBroken = true;
   double phP[];
   double plP[];
   int    phI[];
   int    plI[];
   double aH = 0, aL = 0, cAH = 0, cAL = 0;
   bool prevAsia = false;
   int kp = 0, dp = 0;
   // achat
   int bState = 0, bOIdx = -1, bStart = -1, bFill = -1;
   double bO = 0, bExt = 0, bEntry = 0, bEL = 0, bSL = 0, bTP = 0, bRR = 0;
   string bConf = "", bLiq = "";
   bool bValid = false, bChoch = false, bMss = false, bKz = false;
   bool bBeOn = false, bBeOut = false;
   int  bBeBar = -1;
   // vente
   int sState = 0, sOIdx = -1, sStart = -1, sFill = -1;
   double sO = 0, sExt = 0, sEntry = 0, sEL = 0, sSL = 0, sTP = 0, sRR = 0;
   string sConf = "", sLiq = "";
   bool sValid = false, sChoch = false, sMss = false, sKz = false;
   bool sBeOn = false, sBeOut = false;
   int  sBeBar = -1;

   for(int t = 1; t <= last; t++)
     {
      //--- sessions (heure de Paris)
      int pm = SwParisMinutes(r[t].time, srvOff);
      bool inAsia = SwInSess(pm, InpSwAsia);
      if(inAsia && !prevAsia) { cAH = r[t].high; cAL = r[t].low; }
      else if(inAsia) { cAH = MathMax(cAH, r[t].high); cAL = MathMin(cAL, r[t].low); }
      if(!inAsia && prevAsia) { aH = cAH; aL = cAL; }
      prevAsia = inAsia;
      bool inKZ = SwInSess(pm, InpSwKzLondon) || SwInSess(pm, InpSwKzNY);

      //--- unité supérieure : dernière bougie clôturée
      int k1 = -1;
      if(htfOn)
        {
         while(kp + 1 < m && h[kp + 1].time <= r[t].time) kp++;
         if(h[kp].time <= r[t].time) k1 = kp - 1;
        }
      bool htfBull = !InpSwHtfTrend || !htfOn || (k1 >= 199 && h[k1].close > hSma[k1]);
      bool htfBear = !InpSwHtfTrend || !htfOn || (k1 >= 199 && h[k1].close < hSma[k1]);
      double pdMid = 0;
      if(htfOn) { if(k1 >= 0 && hHi[k1] > 0) pdMid = (hHi[k1] + hLo[k1]) / 2.0; }
      else if(t > InpSwPdLen)
        {
         double hi = r[t - 1].high, lo = r[t - 1].low;
         for(int j = t - InpSwPdLen; j <= t - 1; j++) { hi = MathMax(hi, r[j].high); lo = MathMin(lo, r[j].low); }
         pdMid = (hi + lo) / 2.0;
        }
      //--- veille
      double pdh = 0, pdl = 0;
      if(nd > 1)
        {
         while(dp + 1 < nd && dd[dp + 1].time <= r[t].time) dp++;
         if(dd[dp].time <= r[t].time && dp >= 1) { pdh = dd[dp - 1].high; pdl = dd[dp - 1].low; }
        }

      //--- pivots confirmés
      if(t >= 2 * L)
        {
         int pb = t - L;
         if(IsPivotHigh(r, pb, L))
           {
            lastHigh = r[pb].high; lastHighIdx = pb; highBroken = false;
            SwPushPivot(phP, phI, r[pb].high, pb);
           }
         if(IsPivotLow(r, pb, L))
           {
            lastLow = r[pb].low; lastLowIdx = pb; lowBroken = false;
            SwPushPivot(plP, plI, r[pb].low, pb);
           }
        }

      //--- cassures (clôture)
      bool bullBreak = !highBroken && lastHighIdx >= 0 && r[t].close > lastHigh;
      bool bearBreak = !lowBroken && lastLowIdx >= 0 && r[t].close < lastLow;
      bool bullChoch = bullBreak && trend == -1;
      bool bearChoch = bearBreak && trend == 1;
      bool maOk = (t >= 199);
      bool alBull = !InpSwAlign || (maOk && e20[t] > e50[t] && e50[t] > s200[t]);
      bool alBear = !InpSwAlign || (maOk && e20[t] < e50[t] && e50[t] < s200[t]);
      bool canBull = bullBreak && (InpSwChoch || !bullChoch) && bias > 0 && htfBull && alBull;
      bool canBear = bearBreak && (InpSwChoch || !bearChoch) && bias < 0 && htfBear && alBear;
      bool bullMss = bullBreak && (r[t].close - r[t].open) >= InpSwMssAtr * atr[t];
      bool bearMss = bearBreak && (r[t].open - r[t].close) >= InpSwMssAtr * atr[t];
      int brkHighIdx = lastHighIdx, brkLowIdx = lastLowIdx;
      if(bullBreak) { highBroken = true; trend = 1; }
      if(bearBreak) { lowBroken = true; trend = -1; }

      //================= ACHAT =================
      if(bState == 1 && sState == 2) bState = 0;          // une seule position à la fois
      bool bEval = false;
      if(canBull && bState != 2 && sState != 2)
        {
         int span = MathMin(t - brkHighIdx, 500);
         double oLow = r[t].low;
         int oOff = 0;
         for(int i = 0; i <= span; i++) if(r[t - i].low < oLow) { oLow = r[t - i].low; oOff = i; }
         double ext = r[t].high;
         for(int i = 0; i <= oOff; i++) ext = MathMax(ext, r[t - i].high);
         bState = 1; bOIdx = t - oOff; bO = oLow; bExt = ext; bStart = t; bValid = false;
         bChoch = bullChoch; bMss = bullMss; bKz = inKZ;
         bLiq = (pdl > 0 && oLow < pdl) ? "PDL" : (aL > 0 && oLow < aL) ? "Asie" : "";
         bEval = true;
        }
      else if(bState == 1)
        {
         if(bValid && r[t].low <= bEntry)
           {
            bState = 2; bFill = t; bBeOn = false; bBeOut = false; bBeBar = -1;
            if(t == last) Print("ORACLE : SAV-WS ", sym, " ", SwTfName(tf), " achat déclenché à ", DoubleToString(bEntry, dg));
           }
         else if(r[t].high > bExt) { bExt = r[t].high; bEval = true; }
         else if(t - bStart > InpSwMaxWait || r[t].low < bO || bearBreak) bState = 0;
        }
      if(bEval)
        {
         int cnt = 0;
         string txt = "";
         bool keyOk = false, swOk = false;
         double e = 0, eL = 0, sl = 0, tp = 0, rr = 0, zLo = 0, zHi = 0;
         SwEval(r, t, 1, bOIdx, bO, bExt, atr[t], InpSwUseMss && bMss, plP, plI, cnt, txt, keyOk, swOk, e, eL, sl, tp, rr, zLo, zHi);
         bool was = bValid;
         bool pdOk = pdMid > 0 && e < pdMid;
         bool lqOk = (bLiq != "");
         bool hzOk = htfOn && k1 >= 0 &&
                     ((zbT[k1] > 0 && zbT[k1] >= zLo && zbB[k1] <= zHi) || (obT_[k1] > 0 && obT_[k1] >= zLo && obB_[k1] <= zHi));
         int x = (pdOk ? 1 : 0) + (bKz ? 1 : 0) + (lqOk && !swOk ? 1 : 0) + (hzOk ? 1 : 0);
         string xs = "";
         if(pdOk) xs += "Discount";
         if(bKz)  xs += (xs == "" ? "" : "+") + "KZ";
         if(lqOk) xs += (xs == "" ? "" : "+") + bLiq;
         if(hzOk) xs += (xs == "" ? "" : "+") + "ZoneHTF";
         bEntry = e; bEL = eL; bSL = sl; bTP = tp; bRR = rr;
         string all = txt + ((txt != "" && xs != "") ? "+" : "") + xs;
         bConf = (bChoch ? "CHoCH" : "BOS") + (all != "" ? " | " + all : "");
         bValid = (cnt + x >= InpSwMinConf) && rr >= InpSwMinRR && (keyOk || lqOk || hzOk || !InpSwNeedKey);
         if(t == last && bValid && !was)
            QueuePushLocal(ev, StringFormat("SETUP;BUY;%s;%s;%s;%s;%.2f;%.3f;%s", TimeToString(r[t].time + PeriodSeconds(tf), TIME_DATE | TIME_MINUTES),
                                            DoubleToString(e, dg), DoubleToString(sl, dg), DoubleToString(tp, dg), rr, eL, bConf));
        }
      if(bState == 2)
        {
         double bRisk = MathAbs(bEntry - bSL);
         // variante « passage à l'entrée » : stop à l'entrée à partir de la bougie qui suit les +InpSwBeAtR R
         if(bBeOn && !bBeOut && t > bBeBar && r[t].low <= bEntry) bBeOut = true;
         if(!bBeOn && t > bFill && bRisk > 0 && r[t].high >= bEntry + InpSwBeAtR * bRisk) { bBeOn = true; bBeBar = t; }
         bool hitSL = r[t].low <= bSL;
         bool hitTP = t > bFill && r[t].high >= bTP;
         if(hitSL || hitTP)
           {
            if(t == last)
              {
               double cost = (bRisk > 0) ? spr / bRisk : 0;
               double R = (hitSL ? -1.0 : bRR) - cost;
               double Rbe = bBeOut ? -cost : R;
               QueuePushLocal(ev, StringFormat("RESULT;BUY;%s;%s;%.2f;%.2f", TimeToString(r[bStart].time + PeriodSeconds(tf), TIME_DATE | TIME_MINUTES),
                                               hitSL ? "stop" : "objectif", R, Rbe));
              }
            bState = 0;
           }
        }

      //================= VENTE =================
      if(sState == 1 && bState == 2) sState = 0;
      bool sEval = false;
      if(canBear && sState != 2 && bState != 2)
        {
         int span = MathMin(t - brkLowIdx, 500);
         double oHigh = r[t].high;
         int oOff = 0;
         for(int i = 0; i <= span; i++) if(r[t - i].high > oHigh) { oHigh = r[t - i].high; oOff = i; }
         double ext = r[t].low;
         for(int i = 0; i <= oOff; i++) ext = MathMin(ext, r[t - i].low);
         sState = 1; sOIdx = t - oOff; sO = oHigh; sExt = ext; sStart = t; sValid = false;
         sChoch = bearChoch; sMss = bearMss; sKz = inKZ;
         sLiq = (pdh > 0 && oHigh > pdh) ? "PDH" : (aH > 0 && oHigh > aH) ? "Asie" : "";
         sEval = true;
        }
      else if(sState == 1)
        {
         if(sValid && r[t].high >= sEntry)
           {
            sState = 2; sFill = t; sBeOn = false; sBeOut = false; sBeBar = -1;
            if(t == last) Print("ORACLE : SAV-WS ", sym, " ", SwTfName(tf), " vente déclenchée à ", DoubleToString(sEntry, dg));
           }
         else if(r[t].low < sExt) { sExt = r[t].low; sEval = true; }
         else if(t - sStart > InpSwMaxWait || r[t].high > sO || bullBreak) sState = 0;
        }
      if(sEval)
        {
         int cnt = 0;
         string txt = "";
         bool keyOk = false, swOk = false;
         double e = 0, eL = 0, sl = 0, tp = 0, rr = 0, zLo = 0, zHi = 0;
         SwEval(r, t, -1, sOIdx, sO, sExt, atr[t], InpSwUseMss && sMss, phP, phI, cnt, txt, keyOk, swOk, e, eL, sl, tp, rr, zLo, zHi);
         bool was = sValid;
         bool pdOk = pdMid > 0 && e > pdMid;
         bool lqOk = (sLiq != "");
         bool hzOk = htfOn && k1 >= 0 &&
                     ((zsT[k1] > 0 && zsT[k1] >= zLo && zsB[k1] <= zHi) || (osT[k1] > 0 && osT[k1] >= zLo && osB[k1] <= zHi));
         int x = (pdOk ? 1 : 0) + (sKz ? 1 : 0) + (lqOk && !swOk ? 1 : 0) + (hzOk ? 1 : 0);
         string xs = "";
         if(pdOk) xs += "Premium";
         if(sKz)  xs += (xs == "" ? "" : "+") + "KZ";
         if(lqOk) xs += (xs == "" ? "" : "+") + sLiq;
         if(hzOk) xs += (xs == "" ? "" : "+") + "ZoneHTF";
         sEntry = e; sEL = eL; sSL = sl; sTP = tp; sRR = rr;
         string all = txt + ((txt != "" && xs != "") ? "+" : "") + xs;
         sConf = (sChoch ? "CHoCH" : "BOS") + (all != "" ? " | " + all : "");
         sValid = (cnt + x >= InpSwMinConf) && rr >= InpSwMinRR && (keyOk || lqOk || hzOk || !InpSwNeedKey);
         if(t == last && sValid && !was)
            QueuePushLocal(ev, StringFormat("SETUP;SELL;%s;%s;%s;%s;%.2f;%.3f;%s", TimeToString(r[t].time + PeriodSeconds(tf), TIME_DATE | TIME_MINUTES),
                                            DoubleToString(e, dg), DoubleToString(sl, dg), DoubleToString(tp, dg), rr, eL, sConf));
        }
      if(sState == 2)
        {
         double sRisk = MathAbs(sSL - sEntry);
         if(sBeOn && !sBeOut && t > sBeBar && r[t].high >= sEntry) sBeOut = true;
         if(!sBeOn && t > sFill && sRisk > 0 && r[t].low <= sEntry - InpSwBeAtR * sRisk) { sBeOn = true; sBeBar = t; }
         bool hitSL = r[t].high >= sSL;
         bool hitTP = t > sFill && r[t].low <= sTP;
         if(hitSL || hitTP)
           {
            if(t == last)
              {
               double cost = (sRisk > 0) ? spr / sRisk : 0;
               double R = (hitSL ? -1.0 : sRR) - cost;
               double Rbe = sBeOut ? -cost : R;
               QueuePushLocal(ev, StringFormat("RESULT;SELL;%s;%s;%.2f;%.2f", TimeToString(r[sStart].time + PeriodSeconds(tf), TIME_DATE | TIME_MINUTES),
                                               hitSL ? "stop" : "objectif", R, Rbe));
              }
            sState = 0;
           }
        }
     }

   //--- état final : ordre limite à tenir (le setup le plus récent si les deux sens sont en attente)
   if(bState == 2 || sState == 2) { res.state = 2; res.buy = (bState == 2); return true; }
   bool bOk = (bState == 1 && bValid), sOk = (sState == 1 && sValid);
   if(bOk && (!sOk || bStart >= sStart))
     { res.state = 1; res.buy = true;  res.entry = bEntry; res.sl = bSL; res.tp = bTP; res.rr = bRR; res.lvl = bEL; res.conf = bConf; }
   else if(sOk)
     { res.state = 1; res.buy = false; res.entry = sEntry; res.sl = sSL; res.tp = sTP; res.rr = sRR; res.lvl = sEL; res.conf = sConf; }
   return true;
  }

//--- Numéro d'idée W00 à W99 (400 à 499) attribué une fois pour toutes à chaque actif et unité
int SwIdFor(string sym, ENUM_TIMEFRAMES tf)
  {
   string key = GV("swid_" + sym + "_" + SwTfName(tf));
   if(GlobalVariableCheck(key)) return (int)GlobalVariableGet(key);
   string pre = GV("swid_");
   int used[100];
   ArrayInitialize(used, 0);
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string nm = GlobalVariableName(i);
      if(StringFind(nm, pre) != 0) continue;
      int v = (int)GlobalVariableGet(nm) - 400;
      if(v >= 0 && v < 100) used[v] = 1;
     }
   for(int v = 0; v < 100; v++)
      if(used[v] == 0) { GlobalVariableSet(key, 400 + v); return 400 + v; }
   return -1;
  }

bool SwIsSw(int idnum) { return idnum >= 400 && idnum < 500; }

// une position ou un ordre ORACLE en sens inverse existe déjà sur ce symbole
bool SwOpposite(string sym, bool buy, int idnum)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurs(mg) || MagicId(mg) == idnum || PositionGetString(POSITION_SYMBOL) != sym) continue;
      bool pb = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if(pb != buy) return true;
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0) continue;
      long mg = OrderGetInteger(ORDER_MAGIC);
      if(!IsOurs(mg) || MagicId(mg) == idnum || OrderGetString(ORDER_SYMBOL) != sym) continue;
      long ot = OrderGetInteger(ORDER_TYPE);
      bool ob = (ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP);
      if(ob != buy) return true;
     }
   return false;
  }

//--- Tient l'ordre limite SAV-WS d'un actif / unité aligné sur le dernier calcul (mode trading)
void SwSync(string sym, ENUM_TIMEFRAMES tf, int idnum, int slot, bool allowed, int &keep[])
  {
   ulong pt = 0;
   double pE = 0, pSL = 0;
   long pType = -1;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      long mg = OrderGetInteger(ORDER_MAGIC);
      if(IsOurs(mg) && MagicId(mg) == idnum)
        { pt = tk; pE = OrderGetDouble(ORDER_PRICE_OPEN); pSL = OrderGetDouble(ORDER_SL); pType = OrderGetInteger(ORDER_TYPE); break; }
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(IsOurs(mg) && MagicId(mg) == idnum) return;     // en position : stop et objectif chez le courtier
     }
   if(!allowed || g_swState[slot] != 1) return;          // l'ordre éventuel sera retiré par le balayage final

   bool buy = g_swBuy[slot];
   double e  = RoundPrice(sym, g_swE[slot]);
   double sl = RoundPrice(sym, g_swSL[slot]);
   double tp = RoundPrice(sym, g_swTP[slot]);
   ENUM_ORDER_TYPE ot = buy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   double tol = SymbolInfoDouble(sym, SYMBOL_POINT) * 2;
   if(pt > 0)
     {
      if(pType == ot && MathAbs(pE - e) <= tol && MathAbs(pSL - sl) <= tol)
        {
         QueuePushInt(keep, idnum);
         return;
        }
      if(!g_trade.OrderDelete(pt)) { QueuePushInt(keep, idnum); return; }
      Print("ORACLE : ", NumToId(idnum), " SAV-WS ", sym, " niveaux mis à jour, ordre remplacé.");
     }
   if(CountActiveIds() >= InpMaxTrades) return;
   if(SwOpposite(sym, buy, idnum)) return;
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) return;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID), ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;
   double gap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
   if(buy ? (ask <= e + gap) : (bid >= e - gap)) return; // le prix est déjà sur l'entrée : pas d'ordre limite possible
   double dist = MathAbs(e - sl);
   if(dist <= 0) return;
   if(InpMaxSpreadPct > 0 && (ask - bid) > dist * InpMaxSpreadPct / 100.0) return;

   double riskPct = MathMin((InpRiskOverride > 0) ? InpRiskOverride : g_risk, InpMaxRiskPct);
   int streak = LossStreakNow();
   if(InpLossStreak > 0 && streak >= InpLossStreak) riskPct *= InpStreakFactor;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;
   if(InpMaxOpenRiskPct > 0 && OpenRiskMoney() + riskMoney > equity * InpMaxOpenRiskPct / 100.0) return;
   double pl1 = 0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, 1.0, e, sl, pl1) || pl1 == 0) return;
   double lot = NormLot(sym, riskMoney / MathAbs(pl1));
   if(lot <= 0) { Print("ORACLE : SAV-WS ", sym, " capital trop petit pour ce stop."); return; }
   string id = NumToId(idnum);
   string cmt = "ORACLE " + id + " SAVWS " + SwTfName(tf);
   if(!SendPending(sym, ot, lot, e, sl, tp, MakeMagic(idnum, 1), cmt))
     {
      Print("ORACLE : SAV-WS ", sym, " refus du courtier : ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      RefusalAlert("SAV-WS " + SwTfName(tf), sym);
      return;
     }
   QueuePushInt(keep, idnum);
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   Notify(StringFormat("%s SAV-WS %s %s %s : ordre limite %s (Fibo %.3f), stop %s, objectif %s (%.1fR), lot %s, risque %.2f %% | %s",
                       id, SwTfName(tf), sym, buy ? "achat" : "vente", DoubleToString(e, d), g_swLvl[slot],
                       DoubleToString(sl, d), DoubleToString(tp, d), g_swRR[slot], DoubleToString(lot, 2), riskPct, g_swConf[slot]));
  }

//--- En réel (option InpSwBE) : stop d'une position SAV-WS remonté au prix d'entrée à +InpSwBeAtR R
void SwManageBE()
  {
   if(!InpSwBE || InpSwBeAtR <= 0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurs(m) || !SwIsSw(MagicId(m))) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      string rk = GV("swr_" + IntegerToString((long)t));
      if(!GlobalVariableCheck(rk))
        {
         if(sl <= 0) continue;
         GlobalVariableSet(rk, MathAbs(open - sl));        // risque initial, mémorisé à la première lecture
        }
      double risk = GlobalVariableGet(rk);
      if(risk <= 0) continue;
      bool already = buy ? (sl >= open) : (sl > 0 && sl <= open);
      if(already) continue;
      double px = buy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      double minGap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
      bool reached = buy ? (px >= open + InpSwBeAtR * risk && px - open > minGap) : (px <= open - InpSwBeAtR * risk && open - px > minGap);
      if(!reached) continue;
      g_trade.SetExpertMagicNumber(m);
      if(g_trade.PositionModify(t, RoundPrice(sym, open), tp))
         Notify(StringFormat("%s SAV-WS %s : +%.1fR atteint, stop remonté au prix d'entrée.", NumToId(MagicId(m)), sym, InpSwBeAtR));
     }
  }

//--- Appelé à chaque cycle
void SwProcess(bool allowed)
  {
   int keep[];
   ArrayResize(keep, 0);
   if(SwModeNow() > 0)
     {
      int srvOff = (int)(MathRound((double)(TimeTradeServer() - TimeGMT()) / 1800.0) * 1800);
      for(int i = 0; i < ArraySize(g_biasAsset); i++)
        {
         int bias = g_biasVal[i];
         if(bias == 0) continue;                          // biais neutre : aucun setup
         string asset = g_biasAsset[i];
         string sym = ResolveSymbol(asset);
         if(sym == "") continue;
         for(int u = 0; u < 2; u++)
           {
            ENUM_TIMEFRAMES tf = (u == 0) ? InpSwTF1 : InpSwTF2;
            if(tf == PERIOD_CURRENT) continue;
            int ps = PeriodSeconds(tf);
            if(ps < 300 || ps > 86400) continue;
            datetime barT = iTime(sym, tf, 1);
            if(barT == 0) continue;
            int idnum = SwIdFor(sym, tf);
            if(idnum < 0) continue;
            int slot = SwSlot(sym + "_" + SwTfName(tf));
            if(g_swBar[slot] != barT)
              {
               SwRes res;
               string ev[];
               if(SwScan(sym, tf, bias, srvOff, res, ev))
                 {
                  g_swBar[slot] = barT;
                  g_swState[slot] = res.state; g_swBuy[slot] = res.buy; g_swE[slot] = res.entry; g_swSL[slot] = res.sl;
                  g_swTP[slot] = res.tp; g_swRR[slot] = res.rr; g_swLvl[slot] = res.lvl; g_swConf[slot] = res.conf;
                  string jk = GV("swj_" + sym + "_" + SwTfName(tf));
                  if(!GlobalVariableCheck(jk) || (datetime)GlobalVariableGet(jk) != barT)
                    {
                     GlobalVariableSet(jk, (double)barT);
                     string modeTxt = (SwModeNow() == 2) ? "TRADING" : "OBS";
                     for(int k = 0; k < ArraySize(ev); k++)
                       {
                        string f[];
                        int nf = StringSplit(ev[k], ';', f);
                        if(nf < 5) continue;
                        if(f[0] == "SETUP" && nf >= 9)
                          {
                           SavJournal(StringFormat("SAVWS_SETUP;%I64d;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s", AccountInfoInteger(ACCOUNT_LOGIN),
                                                   asset, sym, SwTfName(tf), f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], modeTxt));
                           if(SwModeNow() == 1 && InpSwNotify)
                              Notify(StringFormat("SAV-WS %s %s %s (observation) : limite %s, stop %s, objectif %s, %sR | %s",
                                                  SwTfName(tf), sym, f[1] == "BUY" ? "achat" : "vente", f[3], f[4], f[5], f[6], f[8]));
                          }
                        else if(f[0] == "RESULT")
                          {
                           SavJournal(StringFormat("SAVWS_RESULT;%I64d;%s;%s;%s;%s;%s;%s;%s;%s;%s", AccountInfoInteger(ACCOUNT_LOGIN),
                                                   asset, sym, SwTfName(tf), f[1], f[2], f[3], f[4], SwModeNow() == 2 ? "SIM" : "OBS",
                                                   nf >= 6 ? f[5] : f[4]));
                           if(SwModeNow() == 1 && InpSwNotify)
                              Notify(StringFormat("SAV-WS %s %s %s (observation) : %s, %sR", SwTfName(tf), sym,
                                                  f[1] == "BUY" ? "achat" : "vente", f[3], f[4]));
                          }
                       }
                    }
                 }
              }
            if(SwModeNow() == 2) SwSync(sym, tf, idnum, slot, allowed, keep);
           }
        }
     }
   //--- balayage : retire les ordres SAV-WS qui ne correspondent plus à un setup valide
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      long mg = OrderGetInteger(ORDER_MAGIC);
      if(!IsOurs(mg)) continue;
      int id = MagicId(mg);
      if(!SwIsSw(id)) continue;
      bool kept = false;
      for(int j = 0; j < ArraySize(keep); j++) if(keep[j] == id) kept = true;
      if(!kept && g_trade.OrderDelete(tk))
         Print("ORACLE : ordre ", NumToId(id), " SAV-WS annulé (setup terminé, invalidé ou robot en pause).");
     }
  }

int SwCountSlots(int state)
  {
   int c = 0;
   for(int i = 0; i < ArraySize(g_swState); i++) if(g_swState[i] == state) c++;
   return c;
  }

//+------------------------------------------------------------------+
//| Gestion des anomalies (v1.10)                                    |
//+------------------------------------------------------------------+
string DiscName()  { return "ORACLE_DISC_"  + IntegerToString(InpMagic); }   // début d'une coupure courtier (GMT)
string AliveName() { return "ORACLE_ALIVE_" + IntegerToString(InpMagic); }   // dernier signe de vie (GMT), survit à l'arrêt du PC

string ParisHM(datetime utc)
  {
   MqlDateTime d;
   TimeToStruct(utc + ParisOffsetAt(utc), d);
   return StringFormat("%02d/%02d %02d:%02d", d.day, d.mon, d.hour, d.min);
  }

string Duree(long mins)
  {
   if(mins < 120) return IntegerToString(mins) + " min";
   if(mins < 2880) return IntegerToString(mins / 60) + " h " + StringFormat("%02d", (int)(mins % 60));
   return IntegerToString(mins / 1440) + " j " + IntegerToString((mins % 1440) / 60) + " h";
  }

// Retour de la connexion au courtier après une coupure d'au moins 5 minutes
void ConnectionCheck()
  {
   if(!GlobalVariableCheck(DiscName())) return;
   datetime from = (datetime)GlobalVariableGet(DiscName());
   GlobalVariableDel(DiscName());
   long mins = (long)(TimeGMT() - from) / 60;
   if(mins >= 5)
      Notify(StringFormat("connexion au courtier rétablie : coupure du %s au %s (%s). Stops et objectifs sont restés chez le courtier ; le robot reprend normalement.",
                          ParisHM(from), ParisHM(TimeGMT()), Duree(mins)));
  }

// Heure UTC de la dernière fermeture du vendredi (InpFridayHour:InpFridayMinute, heure de Paris)
datetime LastFridayCutUTC()
  {
   datetime p = ParisNow();
   long off = (long)(p - TimeGMT());
   MqlDateTime d;
   TimeToStruct(p, d);
   int back = (d.day_of_week - 5 + 7) % 7;
   d.hour = InpFridayHour; d.min = InpFridayMinute; d.sec = 0;
   datetime cut = StructToTime(d) - back * 86400;
   if(cut > p) cut -= 7 * 86400;
   return (datetime)(cut - off);
  }

// Rattrapage : une position ouverte avant la dernière fermeture du vendredi (robot arrêté à ce moment-là) est fermée à la réouverture
void WeekendCatchUp()
  {
   if(!InpFridayClose) return;
   datetime cutUtc = LastFridayCutUTC();
   int srvOff = (int)(MathRound((double)(TimeTradeServer() - TimeGMT()) / 1800.0) * 1800);
   int n = 0, ok = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs(PositionGetInteger(POSITION_MAGIC))) continue;
      datetime openUtc = (datetime)PositionGetInteger(POSITION_TIME) - srvOff;
      if(openUtc >= cutUtc) continue;
      n++;
      if(g_trade.PositionClose(t)) ok++;
     }
   if(n == 0 || ok == 0) return;
   string key = GV("wkc_" + IntegerToString((long)cutUtc));
   if(GlobalVariableCheck(key)) return;
   GlobalVariableSet(key, 1);
   Notify(StringFormat("rattrapage de la fermeture du vendredi : %d position(s) restée(s) ouverte(s) pendant le week-end (robot arrêté vendredi soir) fermée(s) à la réouverture.", ok));
  }

string LockName() { return "ORACLE_LOCK_" + IntegerToString(InpMagic); }
string BeatName() { return "ORACLE_BEAT_" + IntegerToString(InpMagic); }
double ChartKey() { return (double)(ChartID() % 1000000007); }  // tient sans perte dans un double

// Alerte (une seule fois) quand les consignes sont trop anciennes ou illisibles, puis à la reprise.
// En semaine seulement, après 8h GMT : évite l'alerte du lundi matin avant la première publication.
void StaleAlert(bool ok, bool stale, int wk)
  {
   if(!InpAlertStale) return;
   MqlDateTime g;
   TimeToStruct(TimeGMT(), g);
   bool office = (wk == 0 && g.day_of_week >= 1 && g.day_of_week <= 5 && g.hour >= 8);
   bool bad = ok ? stale : (g_lastOk == 0 || TimeGMT() - g_lastOk > 3600);   // illisible depuis plus d'1 h
   if(bad && office && !g_staleSent)
     {
      g_staleSent = true;
      Notify(ok ? "ALERTE : consignes trop anciennes (publiées le " + TimeToString(g_updated, TIME_DATE | TIME_MINUTES) +
                  " UTC). Robot en pause, ordres en attente annulés. Vérifier les tâches ORACLE."
                : "ALERTE : consignes illisibles depuis plus d'1 h (réseau, GitHub ou WebRequest). Robot en pause.");
     }
   else if(!bad && !stale && g_staleSent)
     {
      g_staleSent = false;
      Notify("consignes de nouveau à jour (" + TimeToString(g_updated, TIME_DATE | TIME_MINUTES) + " UTC), robot réactivé.");
     }
  }

// Signal de vie : un commentaire dans le ticket GitHub InpBeatIssue toutes les InpBeatMinutes minutes.
// HEARTBEAT;compte;DÉMO|RÉEL;serveur;version;heure UTC;état;consignes du;idées;équité;devise
void Heartbeat()
  {
   if(InpGitToken == "" || InpBeatIssue <= 0) return;
   if(g_lastBeat != 0 && TimeLocal() - g_lastBeat < MathMax(15, InpBeatMinutes) * 60) return;
   g_lastBeat = TimeLocal();
   string line = StringFormat("HEARTBEAT;%I64d;%s;%s;1.11;%s;%s;%s;%d;%.2f;%s",
                              AccountInfoInteger(ACCOUNT_LOGIN),
                              AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DÉMO" : "RÉEL",
                              AccountInfoString(ACCOUNT_SERVER),
                              TimeToString(TimeGMT(), TIME_DATE | TIME_MINUTES), g_state,
                              g_updated > 0 ? TimeToString(g_updated, TIME_DATE | TIME_MINUTES) : "jamais",
                              CountActiveIds(), AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoString(ACCOUNT_CURRENCY));
   if(!GitSend(line, InpBeatIssue)) g_lastBeat = TimeLocal() - MathMax(15, InpBeatMinutes) * 60 + 300;   // échec : réessai dans 5 min
  }

void Cycle()
  {
   GlobalVariableSet(LockName(), ChartKey());
   GlobalVariableSet(BeatName(), (double)TimeLocal());
   GlobalVariableSet(AliveName(), (double)TimeGMT());
   static datetime lastFlush = 0;
   if(TimeLocal() - lastFlush >= 600) { GlobalVariablesFlush(); lastFlush = TimeLocal(); }   // survit à une coupure de courant
   if(InpDemoOnly && TerminalInfoInteger(TERMINAL_CONNECTED) && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
     {
      Comment("ORACLE : compte RÉEL détecté, robot à l'arrêt (réglage « Démo uniquement »).");
      g_state = "arrêt : compte réel refusé (Démo uniquement)";
      return;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Comment("ORACLE : activez le bouton « Algo Trading » et l'option « Autoriser le trading algorithmique ».");
      g_state = "arrêt : Algo Trading désactivé";
      return;
     }
   g_status = "";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoInteger(ACCOUNT_LOGIN) == 0 ||
      AccountInfoDouble(ACCOUNT_BALANCE) <= 0 || AccountInfoDouble(ACCOUNT_EQUITY) <= 0)
     {
      Comment("ORACLE : pas connecté au serveur du courtier (ou compte vide). Vérifiez le compte et le serveur dans Fichier > Connexion à un compte de trading. Aucune action.");
      g_state = "arrêt : pas connecté au courtier";
      if(!GlobalVariableCheck(DiscName())) GlobalVariableSet(DiscName(), (double)TimeGMT());
      return;
     }
   ConnectionCheck();
   if(GuardsBlock())
     {
      Comment("ORACLE : " + g_status);
      g_state = "arrêt : " + g_status;
      return;
     }

   string txt;
   bool ok = FetchText(txt) && Parse(txt);
   if(ok) g_lastOk = TimeGMT();
   bool stale = !ok || (TimeGMT() - g_updated > (long)(InpMaxSignalAgeH * 3600));
   bool black = InBlackout();
   int wk = WeekendState();
   if(wk == 1) FridayClose();
   else if(wk == 0) WeekendCatchUp();
   string why = (wk > 0) ? "week-end (fermeture du vendredi " + IntegerToString(InpFridayHour) + "h" + StringFormat("%02d", InpFridayMinute) + ")" :
                !ok ? "consignes illisibles" : stale ? "consignes trop anciennes" : !g_enabled ? "robot coupé par ORACLE (interrupteur)" : black ? "annonce économique" : "";
   bool allowed = (why == "");
   g_state = allowed ? "actif" : "en pause : " + why;
   StaleAlert(ok, stale, wk);

   ManagePending(allowed, why);
   ManageBreakEven();
   SwManageBE();

   if(allowed)
      for(int i = 0; i < g_nsig; i++)
        {
         int idnum = IdToNum(g_sig[i].id);
         if(HasOrderOrPosition(idnum) || WasFilled(idnum)) continue;
         if(CountActiveIds() >= InpMaxTrades) break;
         PlaceSignal(g_sig[i]);
        }

   SavProcess(allowed);
   SwProcess(allowed);
   int sm = SavModeNow();
   int nbias = 0;
   for(int i = 0; i < ArraySize(g_biasVal); i++) if(g_biasVal[i] != 0) nbias++;

   Comment(StringFormat("ORACLE Executor v1.11 | %s | consignes du %s UTC | %d idée(s) | risque %.2f %% | sortie %s | SAV-AFS %s (%d actif(s) orienté(s), %d suivi(s)) | SAV-WS %s (%d setup(s) en attente) | Telegram %s | journal %s | %s",
                        AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DÉMO" : "RÉEL",
                        TimeToString(g_updated, TIME_DATE | TIME_MINUTES), g_nsig,
                        MathMin(InpRiskOverride > 0 ? InpRiskOverride : g_risk, InpMaxRiskPct),
                        g_exitMode == 1 ? "ATR" : "BE",
                        sm == 2 ? "trading" : sm == 1 ? "observation" : "arrêt", nbias, ArraySize(g_vSym),
                        SwModeNow() == 2 ? "trading" : SwModeNow() == 1 ? "observation" : "arrêt", SwCountSlots(1),
                        InpTgToken != "" ? "oui" : "non", InpGitToken != "" ? "GitHub" : "local",
                        allowed ? "actif" : "en pause : " + why));
  }

int OnInit()
  {
   // Un seul robot ORACLE par MetaTrader : refuse de démarrer si un autre graphique l'exécute déjà.
   if(GlobalVariableCheck(LockName()) && GlobalVariableGet(LockName()) != ChartKey() &&
      GlobalVariableCheck(BeatName()) && TimeLocal() - (datetime)GlobalVariableGet(BeatName()) < 3 * MathMax(10, InpPollSeconds))
     {
      string msg = "ORACLE : un autre graphique exécute déjà le robot dans ce MetaTrader. Retirez l'un des deux (sinon ordres en double).";
      Print(msg);
      Alert(msg);
      return INIT_FAILED;
     }
   g_trade.SetDeviationInPoints(30);
   EventSetTimer(MathMax(10, InpPollSeconds));
   LoadVirtual();
   long down = GlobalVariableCheck(AliveName()) ? (long)(TimeGMT() - (datetime)GlobalVariableGet(AliveName())) / 60 : 0;
   if(down >= 15)
      Notify(StringFormat("robot relancé (compte %I64d) après un arrêt de %s (dernier signe de vie le %s, heure de Paris : PC éteint, MT5 fermé ou coupure). Stops et objectifs sont restés chez le courtier ; les setups SAV-WS sont recalculés.",
                          AccountInfoInteger(ACCOUNT_LOGIN), Duree(down), ParisHM((datetime)GlobalVariableGet(AliveName()))));
   else
      Notify("robot démarré (compte " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ")");
   GlobalVariableSet(AliveName(), (double)TimeGMT());
   Cycle();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(GlobalVariableCheck(LockName()) && GlobalVariableGet(LockName()) == ChartKey())
     {
      GlobalVariableDel(LockName());
      GlobalVariableDel(BeatName());
     }
   Comment("");
  }

void OnTimer()
  {
   Cycle();
   FlushQueues();
   Heartbeat();
  }

//+------------------------------------------------------------------+
//| Journal d'un trade clôturé (une ligne par moitié)                |
//| ORACLE_TRADE;compte;idée;moitié;symbole;sens;ouverture;entrée;   |
//| stop initial;fermeture;sortie;motif;volume;résultat;devise;R;    |
//| MFE en R;MAE en R                                                |
//+------------------------------------------------------------------+
void JournalTrade(ulong outDeal)
  {
   long posId = HistoryDealGetInteger(outDeal, DEAL_POSITION_ID);
   long m = HistoryDealGetInteger(outDeal, DEAL_MAGIC);
   string sym = HistoryDealGetString(outDeal, DEAL_SYMBOL);
   double exitPx = HistoryDealGetDouble(outDeal, DEAL_PRICE);
   datetime tOut = (datetime)HistoryDealGetInteger(outDeal, DEAL_TIME);
   double vol = HistoryDealGetDouble(outDeal, DEAL_VOLUME);
   double pnl = HistoryDealGetDouble(outDeal, DEAL_PROFIT) + HistoryDealGetDouble(outDeal, DEAL_SWAP) + HistoryDealGetDouble(outDeal, DEAL_COMMISSION);
   long r = HistoryDealGetInteger(outDeal, DEAL_REASON);
   string why = (r == DEAL_REASON_SL) ? "stop" : (r == DEAL_REASON_TP) ? "objectif" : "cloture";

   double entry = 0, sl0 = 0;
   datetime tIn = 0;
   bool buy = true;
   if(HistorySelectByPosition(posId))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0 || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         entry = HistoryDealGetDouble(d, DEAL_PRICE);
         tIn = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         buy = HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY;
         ulong ord = (ulong)HistoryDealGetInteger(d, DEAL_ORDER);
         if(ord > 0 && HistoryOrderSelect(ord)) sl0 = HistoryOrderGetDouble(ord, ORDER_SL);
         break;
        }
     }
   double risk = (sl0 > 0 && entry > 0) ? MathAbs(entry - sl0) : 0;
   double dir = buy ? 1.0 : -1.0;
   double rMult = (risk > 0) ? dir * (exitPx - entry) / risk : 0;
   double mfeR = 0, maeR = 0;
   if(risk > 0 && tIn > 0)
     {
      MqlRates rt[];
      int n = CopyRates(sym, PERIOD_M1, tIn, tOut, rt);
      if(n > 0)
        {
         double hi = rt[0].high, lo = rt[0].low;
         for(int i = 1; i < n; i++) { hi = MathMax(hi, rt[i].high); lo = MathMin(lo, rt[i].low); }
         mfeR = buy ? (hi - entry) / risk : (entry - lo) / risk;
         maeR = buy ? (lo - entry) / risk : (entry - hi) / risk;
        }
     }
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string line = StringFormat("ORACLE_TRADE;%I64d;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%.2f;%.2f;%s;%.2f;%.2f;%.2f",
                              AccountInfoInteger(ACCOUNT_LOGIN), NumToId(MagicId(m)), MagicLeg(m) == 1 ? "A" : "B", sym, buy ? "BUY" : "SELL",
                              TimeToString(tIn, TIME_DATE | TIME_MINUTES), DoubleToString(entry, dg), DoubleToString(sl0, dg),
                              TimeToString(tOut, TIME_DATE | TIME_MINUTES), DoubleToString(exitPx, dg), why,
                              vol, pnl, AccountInfoString(ACCOUNT_CURRENCY), rMult, mfeR, maeR);
   JournalLocal(line);
   if(InpGitToken != "") QueuePush(g_gitQueue, line);
  }

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
      JournalTrade(trans.deal);
     }
  }
//+------------------------------------------------------------------+
