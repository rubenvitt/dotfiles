-- Selbsttest für helpers/otp.lua:  lua ~/.config/sketchybar/helpers/otp_test.lua
-- Alle Beispiele sind ausgedacht; echte Absender und Codes gehören nicht ins Repo.

package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;" .. package.path
local extract = require("otp").extract

local cases = {
  -- Schlüsselwort mit Doppelpunkt, auch reine Buchstaben
  { "PASSCODE: qamoxe\nBEISPIEL GMBH", "qamoxe" },
  { "Code: 4711", "4711" },
  { "Ihr Bestätigungscode: 839201. Nicht weitergeben.", "839201" },
  { "Sicherheitscode: AB12CD", "AB12CD" },
  -- Schlüsselwort mit Füllwort
  { "Ihr Code lautet 552190", "552190" },
  { "Your verification code is 482913.", "482913" },
  { "Ihre mTAN für die Überweisung: 66120044", "66120044" },
  { "Deine PIN ist 9087", "9087" },
  -- Zahl vor dem Schlüsselwort
  { "123456 ist dein Code für Beispiel.", "123456" },
  { "G-771203 ist dein Google-Bestätigungscode.", "771203" },
  { "Code expires in 10 minutes. 302918 is your code", "302918" },
  { "Ihre mTAN für den Einkauf über 9.99 EUR vom 01.02.2026, 10:15 mit Karte 512345******6789 lautet: 448812", "448812" },
  -- kein Code
  { "Dein Paket kommt am 12.10.2026 zwischen 10 und 12 Uhr", nil },
  { "Code: Bitte nicht weitergeben", nil },
  { "Ihre Rechnung über 49,99 € ist da. Code folgt per Post.", nil },
  { "Ihr Code folgt im Jahr 2026", nil },
  { "Code anfordern unter +49 172 1234567", nil },
  { "Code anfordern unter 0800 123456", nil },
  { "Standortfreigabe 4711 aktiv", nil },
  { "", nil },
}

local failed = 0
for _, c in ipairs(cases) do
  local got = extract(c[1])
  if got ~= c[2] then
    failed = failed + 1
    print(string.format("FAIL %q -> %s (erwartet %s)", c[1], tostring(got), tostring(c[2])))
  end
end
print(string.format("%d/%d ok", #cases - failed, #cases))
os.exit(failed == 0)
