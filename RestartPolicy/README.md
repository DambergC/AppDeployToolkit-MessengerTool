# RestartPolicy för Windows 11

Fristående påminnelser om omstart, baserade på datorns senaste Windows-start. Enda gemensamma beroendet med MessengerTool är **PSAppDeployToolkit 4.1.8**. Ingen SQL, AD, MessengerTool-konfiguration eller MessengerTool-modul används. Inga befintliga klienter eller aktiviteter ändras.

**Standardkonfigurationen kan starta om datorn automatiskt.** Vid sista varningen visas toolkitets omstartsdialog med nedräkning. Sätt `UseToolkitRestartPrompt` till `false` för enbart kvitteringsdialoger utan automatisk omstart.

## Standardbeteende

| Tid sedan Windows-start | Meddelande |
| --- | --- |
| 66 timmar | Högst 6 timmar kvar till omstartsgränsen |
| 69 timmar | Högst 3 timmar kvar |
| 71 timmar 30 minuter | Omstartsdialog med 30 minuters nedräkning |
| 72 timmar eller mer | Samma omstartsdialog om den inte redan visats |

Tiden räknas från `Win32_OperatingSystem.LastBootUpTime`, inklusive vila och viloläge, inte från inloggningen eller skriptstarten. Windows Snabbstart kan bevara starttiden vid avstängning/påslagning; välj **Starta om** för att återställa tiden.

Varje skriptkörning gör en kontroll och avslutas därefter; den schemalagda aktiviteten startar en ny kontroll som standard varje minut. En varning visas vid nästa kontroll efter tröskeln, inte garanterat exakt på sekunden. Om datorn vaknar eller användaren loggar in sent visas **endast det mest aktuella steget**, inte en kö av gamla varningar. Utan aktiv användarsession avslutas kontrollen och nästa schemalagda körning försöker igen.

Vanliga dialoger kvitteras högst en gång per steg **per dator och Windows-start**, i `HKLM:\SOFTWARE\RestartPolicy`. Kvitteringar gäller därmed även vid användarbyte och omstart av skriptet. En riktig omstart återställer policyn automatiskt. Kvittering av en varning skjuter inte upp nästa steg eller omstartsgränsen. Om omstartsdialogen är avstängd visas inga fler meddelanden efter kvitterad slutuppmaning förrän nästa Windows-start.

En vanlig dialog stängs efter `DialogTimeoutSeconds` om den inte kvitteras. Timeout räknas **inte** som kvittering: nästa schemalagda körning försöker igen, eller visar nästa steg om dess tröskel har passerats. En körning väntar medan toolkitets dialog är öppen; särskilt omstartsdialogen kan vara öppen tills datorn startas om. Inga parallella körningar startas under tiden.

## Krav och installation

- Windows 11, 64-bitars Windows PowerShell 5.1, samt lokal administratör vid installation.
- Hela denna mapp inklusive XSD-filen och en lokalt paketerad, oförändrad PSAppDeployToolkit **4.1.8**. Ingen hämtning sker vid körning.
- Den schemalagda aktiviteten körs som **SYSTEM**. Manuell körning av `Start-RestartPolicy.ps1` kan även göras från en förhöjd administratörssession för test. En vanlig icke-eleverad användare nekas eftersom kvittenser delas i HKLM. Toolkitets `Get-ADTLoggedOnUser`, `Initialize-ADTModule`, `Get-ADTEnvironmentTable`, `Show-ADTInstallationPrompt` och `Show-ADTInstallationRestartPrompt` hanterar dialogerna. Ingen egen toast-/UI-motor eller användarprocessstart implementeras.

Exempel på placering (toolkitets övriga filer och underkataloger måste också finnas):

```text
C:\Program Files\AppDeployToolkit-MessengerTool\
  RestartPolicy\
    Start-RestartPolicy.ps1
    Register-RestartPolicyTask.ps1
    RestartPolicy.psm1
    RestartPolicy.xml
    RestartPolicy.xsd
  Dependencies\
    PSAppDeployToolkit\
      4.1.8\
        PSAppDeployToolkit.psd1
        ...
```

Mappen kan också distribueras helt separat från MessengerTool; ange då den lokala toolkit-sökvägen i XML. Skydda **kod, XML, XSD och hela toolkit-katalogen** med fil-ACL: endast SYSTEM och administratörer får ändra dem, vanliga användare endast läsa/köra. Använd inte en användarskrivbar sökväg för något som SYSTEM laddar. Standard-ACL under Program Files är en lämplig utgångspunkt. Lämna HKLM-nyckeln skrivskyddad för vanliga användare.

Anpassa XML-filen och kör sedan i **förhöjd, 64-bitars Windows PowerShell**:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool\RestartPolicy'
& "$root\Register-RestartPolicyTask.ps1" -ConfigPath "$root\RestartPolicy.xml"
```

Registreringen skapar/ersätter endast aktiviteten `RestartPolicy` och startar den direkt. Den körs som SYSTEM vid datorstart, inloggning och därefter enligt ett dagligt upprepat schema, även på batteri, utan tidsgräns. Schemalagda parallella instanser ignoreras. Aktivitetsschemaläggaren försöker starta om processen tre gånger med en minuts mellanrum vid fel. Kvarstående fel måste åtgärdas av administratör; ingen annan omstartsmekanism tar över. Registrera aktiviteten på nytt efter uppgradering eller ändring av `PollSeconds`, så att schemat uppdateras.

Förhandsgranska registreringen med `-WhatIf`. Befintlig aktivitet med samma namn ersätts vid vanlig registrering; välj `-TaskName` om ett annat namn behövs. Flera parallella policyinstanser på samma dator stöds inte.

## XML-inställningar

`RestartPolicy.xml` läses och valideras mot `RestartPolicy.xsd` **vid processstart**. Ogiltig XML eller ogiltiga värden stoppar start med fel. DTD och externa entiteter tillåts inte. Behåll elementens ordning enligt exempelfilen.

| Inställning | Betydelse |
| --- | --- |
| `ToolkitModulePath` | Sökväg till toolkitets manifest. Relativ sökväg räknas från XML-filens katalog, inte aktuell arbetskatalog. |
| `RestartAfterHours` | Positivt heltal, 1–8760 timmar från Windows-start; standard 72. |
| `PollSeconds` | Schemalagt kontrollintervall, hela minuter mellan 60 och 3600 sekunder; standard 60. Äldre konfigurationer med exempelvis 30 måste ändras före uppgradering. |
| `DialogTimeoutSeconds` | Dialogens timeout, heltal 10–300 sekunder; standard 120. Får inte överstiga toolkitets `UI.DefaultTimeout`. |
| `UseToolkitRestartPrompt` | `true` aktiverar toolkitets omstartsdialog för sista varningen och efter tidsgränsen (standard i exempelfilen). `false` eller utelämnat använder vanliga kvitteringsdialoger. |
| `Title` | Dialogrubrik. |
| `AcknowledgeButtonText` | Kvitteringsknapp, 1–200 tecken. `Timeout` är reserverat av toolkit. |
| `OverdueMessage` | Text när omstartsgränsen har nåtts. |
| `Reminders/Reminder` | En eller flera varningar. Texten är meddelandet; attributet `MinutesBefore` är antalet minuter **före** gränsen. |

`MinutesBefore` ska vara unika positiva heltal, högst 1440 (sista dygnet) och mindre än `RestartAfterHours × 60`. XML-ordningen på varningarna saknar betydelse. Standardvärdena är **360, 180 och 30**. Ange inte 66/69/71,5 här: dessa är förfluten tid i timmar, inte återstående minuter.

Med `UseToolkitRestartPrompt` satt till `true` används `Show-ADTInstallationRestartPrompt` från den varning som har lägst `MinutesBefore`, även om gränsen redan passerats innan dialogen kan visas. **Datorn kan startas om automatiskt när nedräkningen löper ut**, så användaren måste spara sitt arbete. Nedräkningen är hela detta antal minuter från dialogens start (30 minuter med standardvärdena), inte återstående tid till gränsen; vid sen inloggning eller vila kan omstarten därför ske efter gränsen. De sista 30 sekunderna kan dialogen inte döljas. Toolkitets egna lokaliserade texter används, inte `Reminder`, `OverdueMessage`, `AcknowledgeButtonText` eller `DialogTimeoutSeconds`.

Skriptet avslutas om ingen aktiv session finns vid kontrollen. Toolkitet kan dock starta om utan dialog om sessionen försvinner mellan kontrollen och toolkitets egen sessionskontroll. Omstartsdialogen returnerar ingen kvittens till skriptet; den markeras därför inte som kvitterad, och om den återvänder utan att datorn startats om försöker nästa schemalagda körning igen.

Texterna i vanliga dialoger kan innehålla `{DeadlineLocal}`, som ersätts med den verkliga tidsgränsen i lokal tid (`yyyy-MM-dd HH:mm`). Ingen PowerShell-kod utvärderas från XML och meddelandenas toolkit-markup neutraliseras. XML-specialtecken måste skrivas som till exempel `&amp;` och `&lt;`. Spara XML som UTF-8 så att svenska tecken bevaras även i Windows PowerShell 5.1.

Efter XML-ändring:

```powershell
Stop-ScheduledTask -TaskName 'RestartPolicy'
& "$root\Register-RestartPolicyTask.ps1" -ConfigPath "$root\RestartPolicy.xml"
```

Kvitteringar sparas över processomstarter. Ändringar av policy/tider återvisar inte redan kvitterade eller mindre brådskande steg under samma Windows-start. Vid avsiktlig återställning för ett pilottest: stoppa aktiviteten, ta bort **endast** `HKLM:\SOFTWARE\RestartPolicy` som administratör och starta aktiviteten igen.

## Loggar, kontroll och test

Dialogresultat och körfel loggas via `Write-ADTLogEntry` med källan `RestartPolicy` i filen `RestartPolicy.log` under toolkitets `Toolkit.LogPath` (standard `C:\Windows\Logs\Software`). Loggfil och loggformat anges uttryckligen eftersom ingen installationssession öppnas. Fel före logginitiering skrivs som terminerande PowerShell-fel och ger misslyckad aktivitet. Skriptet stoppar vid körfel i stället för att markera varningen som kvitterad.

För extra diagnostik, ange `-Log` vid manuell körning av `Start-RestartPolicy.ps1` eller vid registrering av aktiviteten:

```powershell
& "$root\Register-RestartPolicyTask.ps1" -ConfigPath "$root\RestartPolicy.xml" -Log
```

Detta lägger till tidsstämplade rader i `RestartPolicy-diagnostic.log` i samma katalog som skriptet. Varje kontroll visar senaste start, omstartsgränsen och om en påminnelse är aktuell; annars anges tiden för nästa möjliga påminnelse eller att slutpåminnelsen redan kvitterats. Resultat som saknad aktiv session och timeout loggas också. Tider anges i lokal tid med UTC-offset. Loggen växer vid varje kontroll och måste vid behov rensas enligt er rutin. SYSTEM eller administratören som kör skriptet behöver skrivrättighet i katalogen; behåll skyddet mot skrivning för vanliga användare. Loggfel stoppar körningen. Fel före diagnostikloggens initiering visas som terminerande PowerShell-fel. Utan `-Log` skapas ingen diagnostiklogg och den ordinarie toolkit-loggen påverkas inte.

```powershell
Get-ScheduledTask -TaskName 'RestartPolicy'
Get-ScheduledTaskInfo -TaskName 'RestartPolicy'
Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\RestartPolicy' -ErrorAction SilentlyContinue
```

För en manuell kontroll kan `Start-RestartPolicy.ps1 -ConfigPath <sökväg>` användas i en separat SYSTEM-process eller i en förhöjd administratörssession. Stoppa den ordinarie aktiviteten först. Kör sedan exempelvis följande från förhöjd, 64-bitars PowerShell:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool\RestartPolicy'
Stop-ScheduledTask -TaskName 'RestartPolicy' -ErrorAction SilentlyContinue
& (Join-Path $root 'Start-RestartPolicy.ps1') `
  -ConfigPath (Join-Path $root 'RestartPolicy.xml')
```

Administratörsläget använder samma HKLM-status och samma toolkit-sessionbrygga som SYSTEM-läget; en aktiv användarsession krävs fortfarande för att visa dialogen. Körningen visar bara en påminnelse om aktuell starttid passerat en konfigurerad tröskel.

Kör de isolerade Pester 5-testerna manuellt från repots rot:

```powershell
Invoke-Pester -Path .\RestartPolicy\RestartPolicy.Tests.ps1 -CI
Invoke-ScriptAnalyzer -Path .\RestartPolicy -Recurse -Severity Error
```

Testerna simulerar klocka, register och toolkit för att täcka exakta tidsgränser, XML-fel, sena inloggningar, kvitteringar och sessionsbryggan. De ändrar inte datorns starttid eller dess riktiga HKLM-status och körs även i repots CI. Verifiera dessutom på en Windows 11-pilot: interaktiv dialog från SYSTEM, ingen inloggad användare, användarbyte, vila, processomstart och riktig Windows-omstart. Detta kan inte ersättas av mockade tester.

## Avinstallation

```powershell
Stop-ScheduledTask -TaskName 'RestartPolicy'
Unregister-ScheduledTask -TaskName 'RestartPolicy' -Confirm:$false
# Valfritt: ta bort endast policyns kvitteringar.
Remove-Item -LiteralPath 'HKLM:\SOFTWARE\RestartPolicy' -Recurse -Force
```

Ta därefter bort den separat distribuerade `RestartPolicy`-mappen enligt er distributionsrutin. Ta **inte** bort den delade toolkit-katalogen om MessengerTool fortfarande använder den.
