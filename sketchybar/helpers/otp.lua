-- Holt den Einmalcode aus einer SMS (items/sms_code.lua).
--
-- Gesucht wird nur in Nachrichten mit einem Schlüsselwort. Ohne diese Bedingung
-- würde jede SMS mit einer Zahl darin zum "Code", vom Paketdienst bis zur
-- Rechnung. Zwei Wege:
--
-- 1. Direkt hinter dem Schlüsselwort: "Code: 4711", "Ihr Code lautet 4711",
--    "PASSCODE: abcdef". Hinter einem Doppelpunkt darf der Code auch aus reinen
--    Buchstaben bestehen; manche Absender verschicken genau solche Codes. Ohne
--    Doppelpunkt braucht er mindestens eine Ziffer, sonst wäre in "Code expires
--    soon" das Wort "expires" der Code.
-- 2. Sonst die erste freistehende Zahl mit 4 bis 8 Stellen im Text, etwa
--    "123456 ist dein Code" oder "G-123456". Jahre, Beträge, Datumsteile und
--    Telefonnummern fallen dabei heraus.
--
-- Zurück kommt nur, was auf ^[%w-]+$ passt: der Code landet in einem
-- Shell-Aufruf, und der Inhalt einer SMS ist fremde Eingabe.

local M = {}

-- prefix = true: das Wort darf Teil eines zusammengesetzten Worts sein
-- ("Bestätigungscode", "mTAN", "Einmalpasswort").
local KEYWORDS = {
  { word = "code", prefix = true },
  { word = "passwort", prefix = true },
  { word = "tan", prefix = true },
  { word = "pin", prefix = false },
  { word = "otp", prefix = false },
}

local MIN_LEN, MAX_LEN = 4, 10

local function valid(token)
  return token and #token >= MIN_LEN and #token <= MAX_LEN
    and token:match("^[%w%-]+$") ~= nil
end

-- Positionen hinter jedem Vorkommen eines Schlüsselworts. Lua-Muster arbeiten
-- auf Bytes: string.lower lässt UTF-8-Umlaute unverändert, die Positionen in
-- lower und text bleiben also gleich.
local function keyword_ends(lower)
  local ends = {}
  for _, kw in ipairs(KEYWORDS) do
    local init = 1
    while true do
      local s, e = lower:find(kw.word, init, true)
      if not s then break end
      local before = lower:sub(s - 1, s - 1)
      local after = lower:sub(e + 1, e + 1)
      if not after:match("%a") and (kw.prefix or not before:match("%a")) then
        ends[#ends + 1] = e
      end
      init = e + 1
    end
  end
  table.sort(ends)
  return ends
end

local function after_keyword(text, e)
  local rest = text:sub(e + 1, e + 60)
  local colon = rest:match("^%s*:%s*([%w%-]+)")
  if colon then
    -- Reine Buchstaben nur in einer Schreibweise: "abcdef" oder "ABCDEF".
    -- "Bitte" (normales Wort) ist kein Code.
    local letters_ok = colon == colon:lower() or colon == colon:upper()
    if valid(colon) and (colon:match("%d") or letters_ok) then return colon end
  end
  local n = 0
  for raw, e2 in rest:gmatch("(%S+)()") do
    n = n + 1
    if n > 3 then break end
    local word = raw:gsub("^[%p]+", ""):gsub("[%.,;:!%?%)]+$", "")
    -- "0800 123456": eine Nummer in Blöcken, kein Code
    local block = rest:sub(e2, e2 + 1):match("^ %d")
    if valid(word) and word:match("%d") and not block then return word end
  end
end

local function is_year(num)
  return #num == 4 and (num:match("^19") or num:match("^20")) ~= nil
end

local function standalone_number(text)
  for s, num, e in text:gmatch("()(%d+)()") do
    local before = text:sub(s - 1, s - 1)
    local before2 = text:sub(s - 2, s - 2)
    local after = text:sub(e, e)
    local after2 = text:sub(e + 1, e + 1)
    local ok = #num >= 4 and #num <= 8 and not is_year(num)
      -- Teil eines Worts, einer Telefonnummer (+49…), eines Pfads oder einer
      -- maskierten Kartennummer (123456******7890)
      and not before:match("[%a%+/%*]")
      -- Bindestrich nur als "G-123456", nicht als "030-123456"
      and (before ~= "-" or before2:match("%u") ~= nil)
      and not after:match("[%a%*]")
      -- Dezimalzahl, Betrag oder Datum: 49,99 / 12.10.2026
      and not (before:match("[,%.]") and before2:match("%d"))
      and not (after:match("[,%.]") and after2:match("%d"))
      -- Telefonnummer in Blöcken: "0800 123456"
      and not (before == " " and before2:match("%d"))
      and not (after == " " and after2:match("%d"))
      and not text:sub(e, e + 4):match("^%s?€") and not text:sub(e, e + 4):match("^%s?EUR")
    if ok then return num end
  end
end

function M.extract(text)
  if type(text) ~= "string" or text == "" then return nil end
  local ends = keyword_ends(text:lower())
  if #ends == 0 then return nil end
  for _, e in ipairs(ends) do
    local code = after_keyword(text, e)
    if code then return code end
  end
  local num = standalone_number(text)
  if valid(num) then return num end
end

return M
