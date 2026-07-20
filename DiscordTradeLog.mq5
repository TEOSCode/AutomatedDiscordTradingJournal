//+------------------------------------------------------------------+
//|                                            LemuzLabs.blogspot.com| 
//|                                           TradeToDiscordForum.mq5|
//|  Envia cada operacion a un canal FORO de Discord:                |
//|   - Al ABRIR: crea un thread nuevo (webhook + thread_name)       |
//|     con una captura del chart e info del trade.                  |
//|   - Al CERRAR: postea en el MISMO thread (bot token) con otra    |
//|     captura e info de cierre (profit, duracion, etc).            |
//|                                                                  |
//|  REQUISITOS ANTES DE CORRERLO:                                   |
//|   1) Herramientas > Opciones > Expert Advisors >                 |
//|      "Permitir WebRequest para las URLs listadas" y agrega:      |
//|         https://discord.com                                      |
//|   2) Crea un Webhook en el canal foro de Discord                 |
//|      (Configuracion del canal > Integraciones > Webhooks)        |
//|   3) Crea un Bot en https://discord.com/developers/applications  |
//|      invitalo al servidor con permiso "Send Messages in          |
//|      Threads" y "Attach Files", y copia su token.                |
//|   4) El EA debe correr en el chart del simbolo que quieres       |
//|      capturar (ChartScreenShot solo captura el chart actual).    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

//--- Inputs de configuracion
input string InpWebhookURL      = "https://discord.com/api/webhooks/ID/TOKEN"; // Webhook del canal foro
input string InpBotToken        = "TU_BOT_TOKEN_AQUI";                          // Token del bot (para actualizar threads)
input string InpMappingFile     = "trade_threads.csv";                          // Archivo local de mapeo ticket->thread
input int    InpShotWidth       = 3840;
input int    InpShotHeight      = 2160;
input int    InpHttpTimeoutMs   = 8000;
input bool   InpDeleteLocalPng  = true;  // borrar el PNG local despues de enviarlo

//+------------------------------------------------------------------+
//| Utilidades de texto / JSON minimo                                 |
//+------------------------------------------------------------------+
string JsonEscape(const string s)
{
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   StringReplace(r, "\r", "");
   return r;
}

string TypeToStr(const ENUM_DEAL_TYPE t)
{
   if(t == DEAL_TYPE_BUY)  return "🟢 Buy";
   if(t == DEAL_TYPE_SELL) return "🔴 Sell";
   return "OTRO";
}

//+------------------------------------------------------------------+
//| Calcula el dinero (en la divisa de la cuenta) entre el precio de  |
//| apertura y un nivel dado (SL o TP) para una direccion/volumen.    |
//| Devuelve false si el nivel es 0 (no definido) o el calculo falla. |
//+------------------------------------------------------------------+
bool MoneyForLevel(const ENUM_DEAL_TYPE dealType,
                    const string symbol,
                    const double volume,
                    const double openPrice,
                    const double level,
                    double &moneyOut)
{
   moneyOut = 0;
   if(level <= 0) return false;

   ENUM_ORDER_TYPE orderType = (dealType == DEAL_TYPE_SELL) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   if(!OrderCalcProfit(orderType, symbol, volume, openPrice, level, moneyOut))
   {
      Print("OrderCalcProfit fallo. Error: ", GetLastError());
      return false;
   }
   return true;
}

string MoneyText(const bool has, const double money)
{
   if(!has) return "No definido";
   string sign = (money >= 0) ? "+" : "-";
   return sign + "$" + DoubleToString(MathAbs(money), 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
}

string DealReasonToText(const long reason)
{
   switch((ENUM_DEAL_REASON)reason)
   {
      case DEAL_REASON_CLIENT:  return "Manual (terminal escritorio)";
      case DEAL_REASON_MOBILE:  return "Manual (app movil)";
      case DEAL_REASON_WEB:     return "Manual (navegador)";
      case DEAL_REASON_EXPERT:  return "Cerrado por EA/script";
      case DEAL_REASON_SL:      return "Stop Loss";
      case DEAL_REASON_TP:      return "Take Profit";
      case DEAL_REASON_SO:      return "Stop Out (margen insuficiente)";
      case DEAL_REASON_ROLLOVER:return "Rollover";
      case DEAL_REASON_VMARGIN: return "Variacion de margen";
      case DEAL_REASON_SPLIT:   return "Split";
      default:                  return "Desconocido";
   }
}
//+------------------------------------------------------------------+
//| Formatea una fecha/hora local en espanol, ej:                     |
//| "Lunes 20 Jul 2026 09:30 AM"                                       |
//+------------------------------------------------------------------+
string FormatLocalDate(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
 
   string dayNames[7]   = {"Dom","Lun","Mar","Mie","Jue","Vie","Sab"};
   string monthNames[13] = {"", "Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"};
 
   int hour12 = dt.hour % 12;
   if(hour12 == 0) hour12 = 12;
   string ampm = (dt.hour < 12) ? " AM" : " PM";
 
   return dayNames[dt.day_of_week] + " " +
          StringFormat("%02d", dt.day) + " " +
          monthNames[dt.mon] + " " +
          (string)dt.year + " " +
          StringFormat("%02d", hour12) + ":" +
          StringFormat("%02d", dt.min) + ampm;
}

//+------------------------------------------------------------------+
//| Extrae un valor string simple de un JSON plano: "clave":"valor"   |
//| o "clave":numero  (busqueda ingenua, suficiente para respuestas   |
//| de Discord que no tienen anidamiento profundo en los campos que   |
//| necesitamos).                                                     |
//+------------------------------------------------------------------+
string JsonExtract(const string json, const string key)
{
   string needle = "\"" + key + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0) return "";
   int start = pos + StringLen(needle);

   // saltar espacios
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ')
      start++;

   bool quoted = (StringGetCharacter(json, start) == '"');
   if(quoted) start++;

   int i = start;
   while(i < StringLen(json))
   {
      ushort c = StringGetCharacter(json, i);
      if(quoted && c == '"') break;
      if(!quoted && (c == ',' || c == '}')) break;
      i++;
   }
   return StringSubstr(json, start, i - start);
}

//+------------------------------------------------------------------+
//| Mapeo local ticket(posicion) -> thread_id (CSV simple)            |
//+------------------------------------------------------------------+
bool SaveMapping(const long positionId, const string threadId)
{
   int handle = FileOpen(InpMappingFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
      handle = FileOpen(InpMappingFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return false;

   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, (string)positionId, threadId);
   FileClose(handle);
   return true;
}

string LoadMapping(const long positionId)
{
   string result = "";
   if(!FileIsExist(InpMappingFile)) return result;

   int handle = FileOpen(InpMappingFile, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return result;

   string target = (string)positionId;
   while(!FileIsEnding(handle))
   {
      string idStr    = FileReadString(handle);
      if(idStr == "") break;
      string threadId = FileReadString(handle);
      if(idStr == target)
      {
         result = threadId;
         // seguimos leyendo hasta el final por si hay actualizaciones mas nuevas
      }
   }
   FileClose(handle);
   return result;
}

//+------------------------------------------------------------------+
//| Cache en memoria de ultimo SL/TP conocido por posicion, para      |
//| detectar cambios reales y no reenviar cuando no cambio nada.      |
//+------------------------------------------------------------------+
ulong  g_cacheTicket[];
double g_cacheSL[];
double g_cacheTP[];

bool CacheGet(const ulong ticket, double &sl, double &tp)
{
   for(int i = 0; i < ArraySize(g_cacheTicket); i++)
   {
      if(g_cacheTicket[i] == ticket)
      {
         sl = g_cacheSL[i];
         tp = g_cacheTP[i];
         return true;
      }
   }
   return false;
}

void CacheSet(const ulong ticket, const double sl, const double tp)
{
   for(int i = 0; i < ArraySize(g_cacheTicket); i++)
   {
      if(g_cacheTicket[i] == ticket)
      {
         g_cacheSL[i] = sl;
         g_cacheTP[i] = tp;
         return;
      }
   }
   int n = ArraySize(g_cacheTicket);
   ArrayResize(g_cacheTicket, n + 1);
   ArrayResize(g_cacheSL, n + 1);
   ArrayResize(g_cacheTP, n + 1);
   g_cacheTicket[n] = ticket;
   g_cacheSL[n]     = sl;
   g_cacheTP[n]     = tp;
}

//+------------------------------------------------------------------+
//| Envia un mensaje de solo texto (embed, sin imagen) a un thread    |
//| existente usando el bot token.                                    |
//+------------------------------------------------------------------+
bool SendPlainEmbedToThread(const string threadId, const string json, string &responseOut, int &httpCodeOut)
{
   string url     = "https://discord.com/api/v10/channels/" + threadId + "/messages";
   string headers = "Authorization: Bot " + InpBotToken + "\r\n" +
                     "Content-Type: application/json\r\n";

   uchar data[];
   StringToCharArray(json, data, 0, StringLen(json), CP_UTF8);

   uchar result[];
   string resultHeaders;

   ResetLastError();
   int code = WebRequest("POST", url, headers, InpHttpTimeoutMs, data, result, resultHeaders);

   if(code == -1)
   {
      Print("WebRequest (SL/TP update) fallo. Error: ", GetLastError());
      httpCodeOut = -1;
      return false;
   }

   httpCodeOut = code;
   responseOut = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return (code >= 200 && code < 300);
}

//+------------------------------------------------------------------+
//| Captura de pantalla del chart actual -> devuelve bytes en array   |
//+------------------------------------------------------------------+
bool CaptureChart(const string fileNamePng, uchar &outBytes[])
{
   if(!ChartScreenShot(0, fileNamePng, InpShotWidth, InpShotHeight, ALIGN_RIGHT))
   {
      Print("ChartScreenShot fallo. Error: ", GetLastError());
      return false;
   }

   int handle = FileOpen(fileNamePng, FILE_READ|FILE_BIN);
   if(handle == INVALID_HANDLE)
   {
      Print("No se pudo abrir el PNG capturado. Error: ", GetLastError());
      return false;
   }

   int size = (int)FileSize(handle);
   ArrayResize(outBytes, size);
   FileReadArray(handle, outBytes, 0, size);
   FileClose(handle);

   if(InpDeleteLocalPng)
      FileDelete(fileNamePng);

   return true;
}

//+------------------------------------------------------------------+
//| Construye el cuerpo multipart/form-data                           |
//| parte 1: campo "payload_json" con el JSON del embed/thread_name   |
//| parte 2: archivo "files[0]" con los bytes de la imagen            |
//+------------------------------------------------------------------+
void BuildMultipartBody(const string boundary,
                         const string jsonPayload,
                         const string fileName,
                         const uchar &fileBytes[],
                         uchar &outBody[])
{
   string head1 = "--" + boundary + "\r\n" +
                  "Content-Disposition: form-data; name=\"payload_json\"\r\n" +
                  "Content-Type: application/json\r\n\r\n" +
                  jsonPayload + "\r\n" +
                  "--" + boundary + "\r\n" +
                  "Content-Disposition: form-data; name=\"files[0]\"; filename=\"" + fileName + "\"\r\n" +
                  "Content-Type: image/png\r\n\r\n";

   string tail = "\r\n--" + boundary + "--\r\n";

   uchar head1Bytes[], tailBytes[];
   StringToCharArray(head1, head1Bytes, 0, StringLen(head1), CP_UTF8);
   StringToCharArray(tail,  tailBytes,  0, StringLen(tail),  CP_UTF8);

   int totalSize = ArraySize(head1Bytes) + ArraySize(fileBytes) + ArraySize(tailBytes);
   ArrayResize(outBody, totalSize);

   int offset = 0;
   ArrayCopy(outBody, head1Bytes, offset, 0, ArraySize(head1Bytes));
   offset += ArraySize(head1Bytes);
   ArrayCopy(outBody, fileBytes, offset, 0, ArraySize(fileBytes));
   offset += ArraySize(fileBytes);
   ArrayCopy(outBody, tailBytes, offset, 0, ArraySize(tailBytes));
}

//+------------------------------------------------------------------+
//| Envia el multipart via WebRequest. extraHeaders debe terminar     |
//| en \r\n si no esta vacio.                                         |
//+------------------------------------------------------------------+
bool SendMultipart(const string url,
                    const string extraHeaders,
                    const uchar &body[],
                    string &responseOut,
                    int &httpCodeOut)
{
   string boundary = "----MT5Boundary" + (string)GetTickCount();
   string headers  = extraHeaders +
                      "Content-Type: multipart/form-data; boundary=" + boundary + "\r\n";

   uchar result[];
   string resultHeaders;

   ResetLastError();
   int code = WebRequest("POST", url, headers, InpHttpTimeoutMs, body, result, resultHeaders);

   if(code == -1)
   {
      int err = GetLastError();
      Print("WebRequest fallo. Error: ", err,
            " (revisa que la URL este en la lista permitida en Opciones > Expert Advisors)");
      httpCodeOut = -1;
      return false;
   }

   httpCodeOut = code;
   responseOut = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return (code >= 200 && code < 300);
}

//+------------------------------------------------------------------+
//| Construye el body multipart ya con boundary calculado y lo manda  |
//| (helper que junta BuildMultipartBody + SendMultipart usando el    |
//| MISMO boundary en ambos pasos)                                    |
//+------------------------------------------------------------------+
bool SendImageWithPayload(const string url,
                           const string extraHeaders,
                           const string jsonPayload,
                           const string fileName,
                           const uchar &fileBytes[],
                           string &responseOut,
                           int &httpCodeOut)
{
   string boundary = "----MT5Boundary" + (string)GetTickCount() + (string)MathRand();
   uchar body[];
   BuildMultipartBody(boundary, jsonPayload, fileName, fileBytes, body);

   string headers = extraHeaders +
                     "Content-Type: multipart/form-data; boundary=" + boundary + "\r\n";

   uchar result[];
   string resultHeaders;

   ResetLastError();
   int code = WebRequest("POST", url, headers, InpHttpTimeoutMs, body, result, resultHeaders);

   if(code == -1)
   {
      int err = GetLastError();
      Print("WebRequest fallo. Error: ", err,
            " (revisa la lista de URLs permitidas en Opciones > Expert Advisors)");
      httpCodeOut = -1;
      return false;
   }

   httpCodeOut = code;
   responseOut = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return (code >= 200 && code < 300);
}

//+------------------------------------------------------------------+
//| Info de un deal para armar el mensaje                             |
//+------------------------------------------------------------------+
struct DealInfo
{
   ulong          positionId;
   string         symbol;
   ENUM_DEAL_TYPE type;
   double         volume;
   double         price;
   double         sl;
   double         tp;
   double         profit;
   datetime       time;
};

void FillDealInfo(const ulong dealTicket, DealInfo &info)
{
   info.positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   info.symbol     = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   info.type       = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   info.volume     = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   info.price      = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   info.profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   info.time       = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);

   // SL/TP no vienen en el deal directamente; si la posicion sigue abierta
   // los tomamos de ella, si no, quedan en 0.
   if(PositionSelectByTicket(info.positionId))
   {
      info.sl = PositionGetDouble(POSITION_SL);
      info.tp = PositionGetDouble(POSITION_TP);
   }
   else
   {
      info.sl = 0;
      info.tp = 0;
   }
}

//+------------------------------------------------------------------+
//| Maneja la APERTURA: crea el thread con imagen                     |
//+------------------------------------------------------------------+
void HandleOpen(const ulong dealTicket)
{
   DealInfo info;
   FillDealInfo(dealTicket, info);

   string fileName = "open_" + (string)info.positionId + ".png";
   uchar imgBytes[];
   if(!CaptureChart(fileName, imgBytes))
      return;

   string threadName = FormatLocalDate(TimeLocal()) + " " + TypeToStr(info.type) + " " + info.symbol ;
   
   // Discord limita thread_name a 100 caracteres
   if(StringLen(threadName) > 100)
      threadName = StringSubstr(threadName, 0, 100);

   double riskMoney = 0, rewardMoney = 0;
   bool hasSL = MoneyForLevel(info.type, info.symbol, info.volume, info.price, info.sl, riskMoney);
   bool hasTP = MoneyForLevel(info.type, info.symbol, info.volume, info.price, info.tp, rewardMoney);

  string desc =  "## Trade abierto \\n" +
                 "**Entry:** " + DoubleToString(info.price, _Digits) + "\\n" +
                 "**SL:** " + DoubleToString(info.sl, _Digits) + " • " + MoneyText(hasSL, riskMoney) + "\\n" +
                 "**TP:** " + DoubleToString(info.tp, _Digits) + " • " + MoneyText(hasTP, rewardMoney) + "\\n" +
                 "\\n" +
                 "**Tipo:** " + TypeToStr(info.type) + "\\n" +
                 "**Volumen:** " + DoubleToString(info.volume, 2) + "\\n" +
                 "**Simbolo:** " + info.symbol + "\\n" +  
                 "**Hora MX:** " + FormatLocalDate(TimeLocal()) + "\\n" +
                 "**Ticket:** " + (string)info.positionId;
 
   string json = "{" +
                 "\"thread_name\":\"" + JsonEscape(threadName) + "\"," +
                 "\"content\":\"" + desc + "\"" +
                 "}";

   string webhookUrl = InpWebhookURL;
   webhookUrl += (StringFind(webhookUrl, "?") >= 0) ? "&wait=true" : "?wait=true";

   string response; int httpCode;
   bool ok = SendImageWithPayload(webhookUrl, "", json, fileName, imgBytes, response, httpCode);

   if(!ok)
   {
      Print("Fallo al crear thread de apertura. HTTP=", httpCode, " Respuesta=", response);
      return;
   }

   string threadId = JsonExtract(response, "channel_id");
   if(threadId == "")
      threadId = JsonExtract(response, "id"); // fallback

   if(threadId != "")
   {
      SaveMapping((long)info.positionId, threadId);
      CacheSet(info.positionId, info.sl, info.tp);
      Print("Thread creado para posicion ", info.positionId, " -> thread_id=", threadId);
   }
   else
   {
      Print("No se pudo extraer thread_id de la respuesta (revisa que el webhook tenga wait=true): ", response);
   }
}

//+------------------------------------------------------------------+
//| Maneja el CIERRE: postea en el thread existente                   |
//+------------------------------------------------------------------+
void HandleClose(const ulong dealTicket)
{
   DealInfo info;
   FillDealInfo(dealTicket, info);

   string threadId = LoadMapping((long)info.positionId);
   if(threadId == "")
   {
      Print("No se encontro thread_id para la posicion ", info.positionId,
            " (se perdio el mapeo o nunca se creo el thread de apertura)");
      return;
   }

   string fileName = "close_" + (string)info.positionId + ".png";
   uchar imgBytes[];
   if(!CaptureChart(fileName, imgBytes))
      return;

   string embedColor = (info.profit >= 0) ? "3066993" : "15158332"; // verde / rojo
   long   reasonRaw   = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   string reasonText  = DealReasonToText(reasonRaw);

   string desc = "## Profit: $ " + DoubleToString(info.profit, 2) + "\\n" +
                 "**Motivo de cierre:** " + reasonText + "\\n" +
                 "**Precio cierre:** " + DoubleToString(info.price, _Digits) + "\\n" +
                 "**Volumen:** " + DoubleToString(info.volume, 2) + "\\n" +
                 "**Simbolo:** " + info.symbol + "\\n" +
                 "**Hora MX:** " + FormatLocalDate(TimeLocal()) + "\\n" + //"**Hora cierre:** " + TimeToString(info.time, TIME_DATE|TIME_MINUTES) + "\\n" +
                 "**Ticket:** " + (string)info.positionId;

   string json = "{" +
                 "\"embeds\":[{" +
                    "\"title\":\"Trade cerrado\"," +
                    "\"description\":\"" + desc + "\"," +
                    "\"color\":" + embedColor + "," +
                    "\"image\":{\"url\":\"attachment://" + fileName + "\"}" +
                 "}]" +
                 "}";

   string url = "https://discord.com/api/v10/channels/" + threadId + "/messages";
   string authHeader = "Authorization: Bot " + InpBotToken + "\r\n";

   string response; int httpCode;
   bool ok = SendImageWithPayload(url, authHeader, json, fileName, imgBytes, response, httpCode);

   if(!ok)
      Print("Fallo al actualizar thread de cierre. HTTP=", httpCode, " Respuesta=", response);
   else
      Print("Thread actualizado con el cierre de la posicion ", info.positionId);
}

//+------------------------------------------------------------------+
//| Maneja un cambio de SL/TP en una posicion abierta: si el SL o TP  |
//| realmente cambio respecto al ultimo valor conocido, postea al     |
//| thread el nuevo riesgo/beneficio en dinero.                       |
//+------------------------------------------------------------------+
void HandleSLTPChange(const ulong positionTicket)
{
   if(!PositionSelectByTicket(positionTicket))
      return;

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);

   double cachedSL = 0, cachedTP = 0;
   bool found = CacheGet(positionTicket, cachedSL, cachedTP);

   // si no lo conociamos aun, solo lo registramos (evita falso positivo
   // justo despues de la apertura, antes de que HandleOpen lo cachee)
   if(!found)
   {
      CacheSet(positionTicket, curSL, curTP);
      return;
   }

   if(cachedSL == curSL && cachedTP == curTP)
      return; // no hubo cambio real

   CacheSet(positionTicket, curSL, curTP);

   string threadId = LoadMapping((long)positionTicket);
   if(threadId == "")
      return; // no hay thread asociado (o se perdio el mapeo)

   string symbol   = PositionGetString(POSITION_SYMBOL);
   double volume   = PositionGetDouble(POSITION_VOLUME);
   double openPr   = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_DEAL_TYPE dtype = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) ? DEAL_TYPE_SELL : DEAL_TYPE_BUY;

   double riskMoney = 0, rewardMoney = 0;
   bool hasSL = MoneyForLevel(dtype, symbol, volume, openPr, curSL, riskMoney);
   bool hasTP = MoneyForLevel(dtype, symbol, volume, openPr, curTP, rewardMoney);

   string desc = "**SL: ** " + DoubleToString(curSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) +
                 "  •  " + MoneyText(hasSL, riskMoney) + "\\n" +
                 "**TP: ** " + DoubleToString(curTP, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) +
                 "  •  " + MoneyText(hasTP, rewardMoney) + "";

   string json = "{" +
                 "\"embeds\":[{" +
                    "\"title\":\"SL/TP actualizado\"," +
                    "\"description\":\"" + desc + "\"," +
                    "\"color\":3447003" +
                 "}]" +
                 "}";

   string response; int httpCode;
   bool ok = SendPlainEmbedToThread(threadId, json, response, httpCode);

   if(!ok)
      Print("Fallo al notificar cambio de SL/TP. HTTP=", httpCode, " Respuesta=", response);
   else
      Print("SL/TP actualizado notificado para posicion ", positionTicket);
}

//+------------------------------------------------------------------+
//| Evento principal: detecta apertura/cierre via deals, y cambios    |
//| de SL/TP via TRADE_TRANSACTION_POSITION                           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_POSITION)
   {
      HandleSLTPChange(trans.position);
      return;
   }

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket))
      return;

   long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

   // ignorar depositos/retiros/balance, solo BUY/SELL
   if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL)
      return;

   if(entry == DEAL_ENTRY_IN)
   {
      HandleOpen(dealTicket);
   }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      HandleClose(dealTicket);
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpWebhookURL == "" || StringFind(InpWebhookURL, "discord.com") < 0)
      Print("ADVERTENCIA: configura InpWebhookURL con tu webhook real de Discord.");
   if(InpBotToken == "" || InpBotToken == "TU_BOT_TOKEN_AQUI")
      Print("ADVERTENCIA: configura InpBotToken para poder actualizar threads al cerrar.");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {}
void OnTick() {}
//+------------------------------------------------------------------+