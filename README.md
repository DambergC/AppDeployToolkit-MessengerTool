# AppDeployToolkit-MessengerTool

Gruppbaserade meddelanden från SQL Server till interaktiva Windows-sessioner. Administratören importerar datorgrupper från AD och köar meddelanden. Klienten läser kön och visar en AppDeployToolkit-dialog med **en kvitteringsknapp** (standardtext `Stäng`). Lässtatus och eventuella repetitioner lagras lokalt **per dator i HKLM**, aldrig som leveranshistorik i SQL.

SQL-frågor för löpande administration finns i [Underhåll av databasen](sql/Database-Maintenance.md).

## Förutsättningar

- 64-bitars Windows och 64-bitars Windows PowerShell 5.1 eller PowerShell 7. Det medföljande PSAppDeployToolkit-manifestet kräver minst Windows PowerShell 5.1.14393.0.
- SQL Server 2016 eller senare, en ny tom databas och DBA-behörighet för installationen.
- TCP-åtkomst till SQL Server (vanligen port 1433), aktiverad SQL-TLS och ett betrott servercertifikat vars namn matchar servernamnet i konfigurationen.
- Synkroniserade systemklockor på SQL-server, administrationsdator och klienter; alla giltighetskontroller använder UTC.
- `sqlcmd` på installationsdatorn. Endast administrationsdatorn behöver RSAT-modulen `ActiveDirectory` och rätt att läsa aktuella AD-objekt.
- Klienten kan köras som `SYSTEM` via en schemalagd aktivitet eller utan elevation i användarens interaktiva session. SYSTEM-läget kräver medföljande PSAppDeployToolkit 4.1.8: SQL och lässtatus hanteras som SYSTEM, medan dialogen förmedlas till en aktiv användarsession. Utan aktiv session lämnas meddelandet okvitterat till ett senare försök.

## 1. Installera filer och skapa konfiguration

Distribuera projektets filer, inklusive den oförändrade, versionslåsta katalogen `Dependencies\PSAppDeployToolkit\4.1.8`, till **`C:\Program Files\AppDeployToolkit-MessengerTool`**. Hämta inte moduler dynamiskt vid inloggning. Skydda kod, beroenden och konfiguration med fil-ACL: endast administratörer får ändra dem; klientanvändare behöver läs-/köråtkomst.

Kör följande kopiering som lokal administratör på respektive dator. Administrationsdatorn kan använda samma installationssökväg:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
# På klienten:
Copy-Item -LiteralPath (Join-Path $root 'config\config.example.psd1') `
  -Destination (Join-Path $root 'config\config.psd1')

# Endast på administrationsdatorn:
Copy-Item -LiteralPath (Join-Path $root 'config\config.example.psd1') `
  -Destination (Join-Path $root 'config\admin.local.psd1')
```

Använd endast `config.example.psd1` som mall. De lokala konfigurationerna är git-ignorerade; distribuera inte administratörskonfiguration eller administratörsuppgifter till klienterna. Ett filnamn ger inga SQL-rättigheter.

Redigera respektive lokal fil med statiska värden (`Import-PowerShellDataFile` utvärderar inte godtycklig kod):

```powershell
@{
    SqlServer = 'sql01.example.test'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = $true
    SqlCredential = $null
    ClientName = $null
    AppDeployToolkitModulePath = 'C:\Program Files\AppDeployToolkit-MessengerTool\Dependencies\PSAppDeployToolkit\4.1.8\PSAppDeployToolkit.psd1'
    Encrypt = $true
    TrustServerCertificate = $false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
```

Ange samma SQL-server, port och databas i båda konfigurationerna. `ClientName = $null` använder lokalt datornamn, vilket ska matcha importerad AD-dators **Name**, inte DNSHostName. Behåll `Encrypt = $true` och `TrustServerCertificate = $false`; åtgärda certifikatkedja/namn i stället för att kringgå valideringen.

## 2. Skapa en tom databas och installera SQL

**Endast för förstagångsinstallation.** Installationsskriptet skapar inte databasen och vägrar installera över befintliga applikationsobjekt. Det är ingen destruktiv uppgradering eller kompatibilitetslösning för äldre databaser. Befintliga installationer kräver separat uppgraderingsplan, verifierad backup och testad återställning.

Kör som DBA i PowerShell; ersätt server/databas med era värden. `-E` använder aktuell Windows-identitet, `-N` begär kryptering, `-b` ger felkod vid SQL-fel och `-f 65001` läser skriptet som UTF-8 så att exempelvis `Stäng` bevaras:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
sqlcmd -S 'tcp:sql01.example.test,1433' -E -N -b -f 65001 -d master `
  -Q 'CREATE DATABASE [ToastNotifications];'
if ($LASTEXITCODE -ne 0) { throw 'Databasen kunde inte skapas; fortsätt inte.' }

sqlcmd -S 'tcp:sql01.example.test,1433' -E -N -b -f 65001 -d ToastNotifications `
  -i (Join-Path $root 'sql\Install-ToastDatabase.sql')
if ($LASTEXITCODE -ne 0) { throw 'SQL-installationen misslyckades; kontrollera felutskriften.' }
```

Kör **enbart** detta installationsskript i den uttryckligen valda, tomma databasen. Det installerar tabellerna `dbo.ToastGroup`, `dbo.ToastClient`, `dbo.ToastClientGroup`, `dbo.ToastMessage`, `dbo.ToastMessageTemplate`, `dbo.ToastMessageAudit`, kö-/läsprocedurer och roller. Meddelandemallar innehåller `Title`, valfri `Subtitle`, `Body`, `AcknowledgeButtonText` samt valfria `Name` och `Description`; SQL för att uppdatera en befintlig malltabell samt lista, spara och ta bort mallar finns i [Underhåll av databasen](sql/Database-Maintenance.md#meddelandemallar). Serverhistorik lagras i audittabellen; inga delivery- eller lease-tabeller används. För att lägga till audit i en befintlig databas med aktuellt meddelandeschema, se [Serverlogg i databasen](sql/Database-Maintenance.md#serverlogg-i-databasen).

### Separera SQL-identiteter

DBA skapar separata Windows-grupplogins och databasanvändare. Ersätt `EXAMPLE` och gruppnamnen med befintliga AD-grupper. För SYSTEM-läget ska klientgruppen innehålla **datorkonton**. Använd helst en avgränsad grupp för berörda datorer; `Domain Computers` fungerar om alla domändatorer ska få läsbehörigheten. För användarläget används i stället en separat användargrupp.

```sql
USE [master];
CREATE LOGIN [EXAMPLE\ToastMessageAdmins] FROM WINDOWS;
CREATE LOGIN [EXAMPLE\ToastClientComputers] FROM WINDOWS;
GO
USE [ToastNotifications];
CREATE USER [EXAMPLE\ToastMessageAdmins] FOR LOGIN [EXAMPLE\ToastMessageAdmins];
CREATE USER [EXAMPLE\ToastClientComputers] FOR LOGIN [EXAMPLE\ToastClientComputers];
ALTER ROLE [ToastMessageAdmin] ADD MEMBER [EXAMPLE\ToastMessageAdmins];
ALTER ROLE [ToastClientReader] ADD MEMBER [EXAMPLE\ToastClientComputers];
GO
```

- `ToastClientReader`: `EXECUTE` på den SELECT-baserade `dbo.usp_GetPendingToast`; `INSERT`, `UPDATE` och `DELETE` nekas. Ingen klientregistrering eller skrivning till SQL.
- `ToastMessageAdmin`: `EXECUTE` på `dbo.usp_QueueToastMessage`, `SELECT`/`INSERT` på de tre måltabellerna `ToastGroup`, `ToastClient`, `ToastClientGroup` samt `DELETE` på `ToastClient` och `ToastClientGroup` för AD-gruppsynkningen. Rollen har även `SELECT`/`INSERT`/`UPDATE`/`DELETE` på `dbo.ToastMessageTemplate` för mallhantering.

För en redan installerad databas behöver DBA ge rollen borttagningsrättigheter i den valda applikationsdatabasen (kör inte om installationsskriptet):

```sql
USE [ToastNotifications];
GRANT DELETE ON OBJECT::dbo.ToastClient TO ToastMessageAdmin;
GRANT DELETE ON OBJECT::dbo.ToastClientGroup TO ToastMessageAdmin;
```

Kör import/köning med administratörens Windows-identitet. Med `UseIntegratedSecurity = $true` autentiserar SYSTEM på en domänansluten klient mot en fjärransluten SQL Server som `EXAMPLE\DATORNAMN$`, inte som den inloggade användaren. Användarläget använder däremot användarens Windows-identitet. SQL-servern måste kunna autentisera den valda domänidentiteten. Ge klientidentiteten rollen `ToastClientReader`: enbart SELECT-rättigheter ersätter inte EXECUTE på läsproceduren. För `Domain Computers`, ersätt `ToastClientComputers` med det faktiska gruppnamnet på alla tre ställena i exemplet.

Ge inte klientgruppen `db_owner`, `db_datawriter`, breda EXECUTE-rättigheter eller medlemskap i administratörsgruppen. Kontrollera även rättigheter via andra grupper och `public`. Klienterna behöver inga skrivrättigheter i databasen.

**Datornamn är ett urval, inte en autentiseringsgräns:** en behörig klientidentitet kan begära en annan registrerad dators meddelanden. Använd inte denna målstyrning för hemligt innehåll.

## 3. Importera mål från AD

Kör på administrationsdatorn med administratörens SQL-behörighet. `Tag` är notifieringsgruppens namn i SQL, inte ett AD-attribut. Förhandsgranska först:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
$adminConfig = Join-Path $root 'config\admin.local.psd1'
$importScript = Join-Path $root 'src\Server\Import-ToastADComputers.ps1'

& $importScript -ConfigPath $adminConfig -Tag 'IT-TEST' `
  -SearchBase 'OU=Workstations,DC=example,DC=test' `
  -Filter 'Enabled -eq $true' -WhatIf

# Efter kontroll: samma kommando utan -WhatIf.
& $importScript -ConfigPath $adminConfig -Tag 'IT-TEST' `
  -SearchBase 'OU=Workstations,DC=example,DC=test' `
  -Filter 'Enabled -eq $true'
```

Alternativt anger du en AD-grupps DN som `SearchBase`; då används rekursiva datormedlemskap och inget eget `Filter`:

```powershell
& $importScript -ConfigPath $adminConfig -Tag 'IT-TEST' `
  -SearchBase 'CN=ToastPilot,OU=Groups,DC=example,DC=test' -WhatIf
```

Ta bort `-WhatIf` efter kontroll för att importera gruppurvalet. Importen ändrar inte AD. Saknade grupper, datorer och medlemskap läggs till utan dubbletter. Vid AD-gruppurval synkroniseras tagget: datorer som inte längre ingår i gruppen tas bort från tagget och raderas även från `ToastClient` om de saknar andra taggar. Andra taggar bevaras. En tom AD-grupp tömmer tagget och samma rensning gäller då. Använd därför ett eget tagg per AD-grupp; även manuellt tillagda medlemskap i tagget tas bort om datorn saknas i gruppen. OU-/filterimport lägger fortfarande bara till medlemskap. Detta gäller både skriptet och funktionen i `ToastAdmin.psm1`. Inaktiva objekt återaktiveras inte. Klienterna registrerar aldrig sig själva.

## 4. Köa ett meddelande med obligatorisk giltighetstid

`Title` och `Body` krävs. `Subtitle` är en valfri, självständig underrubrik; utelämnad eller blank underrubrik visas som det neutrala `Meddelande`, aldrig som en kopia av titeln eller brödtexten. Innehållet behandlas som vanlig text, utan markup eller klickbara länkar. En URL får stå som text men öppnas inte.

Dialogen har exakt en kvitteringsknapp; `AcknowledgeButtonText` ändrar dess text (standard `Stäng`). Texten `Timeout` är reserverad för ADT:s timeoutresultat och nekas oavsett skiftläge. Det finns inga exponerade parametrar för URL-start, bilder, ljud, scenario, brådskande läge eller visningsläge.

Knapptexten får vara högst 200 tecken; tom text använder standardvärdet.

Välj **exakt ett** av följande:

- `ExpiresUtc`: en explicit framtida tidpunkt som `DateTimeOffset`, tidszonsbestämd `DateTime` eller ISO 8601-text med `Z`/tidszonsförskjutning. Tidszon krävs; exemplet nedan konverterar till UTC.
- `ActiveDuration`: positivt heltal tillsammans med `DurationUnit`, exakt `Days`, `Hours` eller `Minutes`.

SQL beräknar varaktigheten relativt `CreatedUtc = SYSUTCDATETIME()` vid insättning, inte relativt klientstart. Sluttiden måste vara senare än aktuell UTC-tid. Giltighetstiden är varken repetitionsintervall eller dialogens timeout.

Exempel med uttrycklig tidszon och egen knapptext (byt datum till en framtida tidpunkt vid körning):

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
$adminConfig = Join-Path $root 'config\admin.local.psd1'
$sendScript = Join-Path $root 'src\Server\Send-ToastMessage.ps1'
$expiry = ([datetimeoffset]'2027-01-15T17:00:00+01:00').UtcDateTime

& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Planerat underhåll' -Subtitle 'Information från IT' `
  -Body 'Spara arbetet. Mer information: https://status.example.test/' `
  -AcknowledgeButtonText 'Jag har läst' -ExpiresUtc $expiry
```

Exempel för samtliga varaktighetsenheter:

```powershell
& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Veckoinformation' -Body 'Information giltig i två dygn.' `
  -ActiveDuration 2 -DurationUnit Days

& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Driftinformation' -Body 'Information giltig i tre timmar.' `
  -ActiveDuration 3 -DurationUnit Hours

& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Testmeddelande' -Body 'Kvittera med Stäng.' `
  -ActiveDuration 15 -DurationUnit Minutes
```

Utelämna repetitionsparametrar för engångsvisning. Vid behov kan **antingen** `RepeatIntervalSeconds` **eller** `RepeatIntervalMinutes` kombineras med `RepeatCount` (minst 2, inklusive första kvitteringen). Nästa visning räknas från föregående lyckade kvittering. Repetitioner förlänger aldrig giltighetstiden.

`Send-ToastMessage.ps1` kontrollerar som standard TCP-åtkomst till SQL-porten före köning. Ange `-CheckSqlPort:$false` för att hoppa över förkontrollen eller `-CheckSqlPort:$true` för att uttryckligen aktivera den. Detta är inte ICMP-ping. SQL-anslutning, autentisering, TLS-validering och ordinarie felhantering krävs även när förkontrollen är avstängd. Klienten och AD-importen ansluter redan direkt till SQL utan denna förkontroll.

### Funktioner för SAPIEN PowerShell Studio

De fristående skripten finns kvar och fungerar som tidigare. Den valfria modulen `src\Module\ToastAdmin.psm1` exponerar `Import-ToastADComputers` och `Send-ToastMessage` för egna GUI:n. Funktionerna återanvänder skripten, inklusive validering, parametriserad SQL och serverloggning. Distribuera därför hela `src\Module` och `src\Server` tillsammans med GUI:t; modulen är inte en fristående paketerad EXE.

Importera modulen i projektets startkod eller formulärets Load-händelse, inte vid varje knapptryckning. Använd en uttrycklig installationssökväg även i paketerade projekt:

```powershell
$script:toastRoot = 'C:\Program Files\AppDeployToolkit-MessengerTool'
$script:adminConfig = Join-Path $script:toastRoot 'config\admin.local.psd1'
Import-Module (Join-Path $script:toastRoot 'src\Module\ToastAdmin.psm1') -ErrorAction Stop

Get-Help Import-ToastADComputers -Full
Get-Help Send-ToastMessage -Examples
```

Enbart modulimporten kontaktar varken AD eller SQL och startar ingen klient. Samma Windows-/SQL-behörigheter och RSAT-krav som för skripten gäller när funktionerna körs. Funktionerna avslutar inte GUI-processen; fel kastas till anroparen.

Exempel på Click-händelser i PowerShell Studio. Anpassa kontrollnamnen till formuläret: textrutorna `textboxTag`, `textboxSearchBase`, `textboxGroupName`, `textboxTitle`, `textboxBody`, `textboxStatus` och `datagridviewComputers`. SearchBase-exemplet kräver en AD-grupps eller OU:s DN. Ange motsvarande knapphändelser i designern:

```powershell
$buttonImport_Click = {
    try {
        $rows = @(Import-ToastADComputers -ConfigPath $script:adminConfig `
            -Tag $textboxTag.Text -SearchBase $textboxSearchBase.Text -ErrorAction Stop)
        $datagridviewComputers.DataSource = [System.Collections.ArrayList]$rows
        $textboxStatus.Text = "Processed $($rows.Count) computers."
    }
    catch {
        # Tidigare datorer kan redan vara importerade; importen kan köras igen.
        $textboxStatus.Text = "Import failed (may be partial): $($_.Exception.Message)"
    }
}

$buttonSend_Click = {
    try {
        $message = Send-ToastMessage -ConfigPath $script:adminConfig `
            -GroupName $textboxGroupName.Text -Title $textboxTitle.Text `
            -Body $textboxBody.Text -ActiveDuration 2 -DurationUnit Hours `
            -Confirm:$false -ErrorAction Stop
        $textboxStatus.Text = "Queued message $($message.MessageId)."
    }
    catch {
        $textboxStatus.Text = "Queue failed: $($_.Exception.Message)"
    }
}
```

Importfunktionen ger ett objekt med `ComputerName` och `Tag` per behandlad dator, även för befintliga medlemskap. Send-funktionen ger ett objekt med `MessageId` (`Int64`) och `GroupName`, inte konsoltext. Det betyder köat, inte levererat eller kvitterat. Det fristående `Send-ToastMessage.ps1` behåller sin textutskrift; använd dess nya `-PassThru` om objekt önskas även där.

Båda funktionerna stöder `-WhatIf`/`-Confirm`. Importens `-WhatIf` läser fortfarande AD/konfiguration och skriver logg, men ändrar inte SQL. Send-funktionens `-WhatIf` hoppar över hela sändningen och returnerar inget objekt; det verifierar därför inte inställningar eller anslutning. Använd inte interaktiva konsolfrågor för bekräftelse i ett paketerat GUI: visa egen bekräftelsedialog och anropa därefter med `-Confirm:$false`.

Exemplen kör synkront och kan blockera formuläret under AD-/SQL-anrop. För produktion kan PowerShell Studios bakgrundsjobb/runspace-mönster användas: importera modulen även där, skicka in vanliga parametervärden och återför resultat/fel till UI-tråden. Uppdatera inte WinForms-kontroller direkt från en bakgrundstråd. Om en NumericUpDown används för `ActiveDuration`, konvertera dess decimalvärde till `[int]` före anropet; heltalsvalideringen är avsiktligt strikt.

## 5. Starta och verifiera klienten

Provisionera först lässtatus på varje klientdator i **64-bitars PowerShell som administratör**, efter att klientkonfigurationen har färdigställts:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
& (Join-Path $root 'deploy\Initialize-ToastReadState.ps1') `
  -ConfigPath (Join-Path $root 'config\config.psd1')
```

Skriptet skapar `HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\<hash>` för konfigurationens SQL-server, port, databas och datornamn och skriver ut sökvägen. Kör det igen vid ändrat scope; befintliga statusvärden bevaras. Skapa inte nycklar eller ACL:er manuellt. Endast den exakta hashnyckelns ACL ändras: `SYSTEM` och lokala administratörer får full kontroll; interaktiva användare (`S-1-5-4`) får endast `ReadKey` och `SetValue`, inte skapa undernycklar, ändra ACL eller ta över ägarskap. Ingen skrivbehörighet ges på `HKLM:\Software`, applikationsnyckeln eller `ReadState`-roten.

För SYSTEM-läget registrerar och startar du aktiviteten enligt nästa avsnitt. För ett manuellt test av användarläget, kör i avsedd SQL-behörig användares **icke-eleverade, interaktiva 64-bitars PowerShell**:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
$clientScript = Join-Path $root 'src\Client\Start-ToastClient.ps1'
$clientConfig = Join-Path $root 'config\config.psd1'
& $clientScript -ConfigPath $clientConfig -Once
```

Smoketest med ett nytt meddelande utan repetitioner:

1. Importera testdatorn och köa ett meddelande med tillräcklig giltighetstid.
2. Starta SYSTEM-aktiviteten med en användare inloggad, eller kör `-Once` i användarläget, och klicka på kvitteringsknappen.
3. Vänta till nästa pollning eller kör `-Once` igen: meddelandet ska **inte** visas på samma dator.
4. Byt inloggad användare på samma dator: meddelandet ska **inte** visas igen eftersom lässtatus delas av alla användare i samma scope. Endast användarläget kräver SQL-behörighet för den nya användaren.
5. Köa ett separat meddelande med kort giltighetstid och vänta tills det gått ut innan klientstart: det ska hoppas över. Timeout, okänt dialogresultat eller visningsfel ska lämna meddelandet oläst; ett nytt försök sker medan det fortfarande är giltigt.
6. I SYSTEM-läget: köa ett nytt meddelande utan någon aktiv användarsession. Ingen dialog eller kvittens ska skapas. Logga sedan in innan giltighetstiden går ut: dialogen ska visas. Prova även utloggning och användarbyte medan aktiviteten fortsätter köra.

Klienten lagrar `Read`, `ShowCount` och `NextShowUtc` som JSON i strängvärden namngivna efter `MessageId` under `HKEY_LOCAL_MACHINE\Software\AppDeployToolkit-MessengerTool\ReadState\<hash>` i 64-bitarsregistret. Hashen avgränsas fortfarande av SQL-server/port, databas och datornamn, inte användar-SID. Alla användare på datorn delar kvittenser och repetitionsräknare i samma scope. En maskinomfattande mutex med begränsad åtkomst för interaktiva användare hindrar konkurrerande visningar över sessioner; en upptagen `-Once` kan avslutas utan visning. Klienten skapar inte nycklar och avbryter med instruktion om provisionering när scope saknas.

### Lokal loggning

Loggfilerna skapas automatiskt **direkt i `C:\Windows\Temp`**, utan underkataloger (`%SystemRoot%\Temp` om Windows ligger på annan plats):

- Server: `AppDeployToolkit-MessengerTool-Server.log`
- SYSTEM-klient: `AppDeployToolkit-MessengerTool-Client-SYSTEM.log`
- Användarklient: `AppDeployToolkit-MessengerTool-Client-<SID>.log`

Inga katalog- eller filrättigheter ändras och inget extra filskydd läggs till. Befintliga Windows-rättigheter och processens identitet avgör åtkomsten; separata filnamn är inte en säkerhetsgräns. Ingen loggprovisionering behövs. Det uppdaterade `deploy\Initialize-ToastLogging.ps1` kontrollerar endast att Temp-katalogen finns och skriver ut sökvägen; den tidigare parametern `ClientUserSid` accepteras med en varning men ändrar ingenting.

Loggarna är CMTrace-kompatibla, roteras vid 10 MB och behåller fem arkiv. Låsfiler (`.log.lock`) och arkiv (`.log.1` till `.log.5`) ligger också direkt i Temp. Vid uppgradering: distribuera även det uppdaterade installationsskriptet och starta om klient-/serverprocesserna. Äldre loggar och rättigheter migreras eller återställs inte automatiskt. Windows eller städverktyg kan rensa temporära loggar; nya loggfiler skapas vid nästa skrivning.

Loggrader innehåller datum, klockslag med tidszon, nivå, komponent, process-ID, körnings-ID och vid behov MessageId. Klienten loggar datornamn, titel, undertitel och hela meddelandetexten som JSON i `Details=` när dialogen ska visas och när användaren kvitterar. Kvittensraden skrivs vid knappsvaret; en separat rad bekräftar att lokal lässtatus sparats. Timeout, okänt resultat och visningsfel loggas inte som kvittens. Att dialogen visas bevisar inte att användaren har läst texten. Anslutningsuppgifter loggas inte. Upprepade identiska fel sammanfattas högst var femte minut och återhämtning loggas direkt. Loggfel visas som varning och hindrar inte polling eller ändrar kvittensresultat. `-DebugLogging` aktiverar ytterligare klientdiagnostik; tomma pollningar loggas inte.

**Loggarna innehåller nu meddelandeinnehåll.** Ta hänsyn till befintliga Temp-rättigheter, backup och gallring innan känsliga meddelanden skickas. Serverns databaslogg innehåller grupp, meddelandedetaljer, UTC-datum/klockslag, SQL-inloggning, SQL-server och sändande dator för köning, uppdatering och borttagning; se [Serverlogg i databasen](sql/Database-Maintenance.md#serverlogg-i-databasen). Klientkvittens skickas fortfarande inte till SQL.

Medlemskap, avbrott och giltighet kontrolleras igen innan nästa väntande meddelande visas. **En redan öppen dialog stängs inte automatiskt när giltighetstiden går ut.** Ingen lässtatus skickas tillbaka till SQL. Lokal status är inte ett manipulationsskyddat revisionsregister: alla interaktiva användare kan ändra den delade statusen, även för andra användare, eller orsaka stopp med ogiltiga värden. Borttagen maskinstatus kan göra att aktiva meddelanden visas igen; borttagen användarprofil återställer inte status. Äldre HKCU-status migreras inte och används inte längre, så aktiva meddelanden kan visas igen vid uppgradering. Återanvändning av meddelande-ID efter databasåterställning kräver separat hantering av lokal status.

### Schemalagd aktivitet som SYSTEM

Kör följande i **64-bitars PowerShell som administratör** efter provisionering och SQL-behörighet för datorkontot:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
& (Join-Path $root 'deploy\Register-ToastClientTask.ps1') `
  -ScriptPath (Join-Path $root 'src\Client\Start-ToastClient.ps1') `
  -ConfigPath (Join-Path $root 'config\config.psd1') `
  -RunAsSystem

Start-ScheduledTask -TaskName 'AppDeployToolkit Toast SQL Client (SYSTEM)'
```

Aktiviteten kör som `S-1-5-18` (SYSTEM), utan sparat lösenord, vid datorstart och vid inloggning. Den fortsätter polla var 30:e sekund även utan inloggad användare men visar då ingen dialog. Den har ingen maximal körtid, tillåts på batteri, ignorerar nya starter när den redan kör och försöker starta om tre gånger med en minuts mellanrum vid fel. `Start-ScheduledTask` startar den direkt efter registrering; annars startar den vid nästa datorstart eller inloggning.

PSAppDeployToolkit 4.1.8 väljer den senast inloggade aktiva användarsessionen. Klienten uppdaterar toolkitets sessionsval inför varje dialog och kontrollerar att vald session fortfarande är aktiv. Dialogen visas i **en** session, inte i alla samtidiga RDP-/konsolsessioner, och kvittensen gäller hela datorn. Dialoganropet väntar på knappsvaret; ingen kvittens skapas bara för att dialogen startas. Den äldre `Show-InstallationPrompt` används aldrig i SYSTEM-läget.

SYSTEM-processen kör fortfarande i Session 0; ett inloggningsvillkor flyttar inte processen. Det är toolkitets sessionsbrygga som visar dialogen hos användaren. Skydda därför skript, konfiguration och hela toolkitkatalogen mot ändringar av vanliga användare, och använd betrodda lokala, absoluta sökvägar. Använd inte en användarskrivbar sökväg för SYSTEM-aktiviteten.

Stoppa och ta bort tidigare användaraktiviteter vid övergång till SYSTEM, så att de inte fortsätter ansluta till SQL med användaridentiteter. Aktivitetsnamnen skiljer sig avsiktligt; registrering av SYSTEM-aktiviteten tar inte bort befintliga aktiviteter.

### Automatisk start per användare (alternativ)

Efter godkänt smoketest registrerar varje avsedd användare sin egen inloggningsaktivitet:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
& (Join-Path $root 'deploy\Register-ToastClientTask.ps1') `
  -ScriptPath (Join-Path $root 'src\Client\Start-ToastClient.ps1') `
  -ConfigPath (Join-Path $root 'config\config.psd1')
```

Utan `-RunAsSystem` bevaras användarläget: aktiviteten använder interaktiv inloggning, begränsade rättigheter och PowerShell med `-STA`; den startar vid nästa inloggning. Båda lägena använder Windows PowerShell från `System32`. Använd beständiga, absoluta sökvägar och behåll filskyddet från steg 1. Stoppa manuellt startad polling innan aktiviteten testas. För manuell kontinuerlig körning:

```powershell
& (Join-Path $root 'src\Client\Start-ToastClient.ps1') `
  -ConfigPath (Join-Path $root 'config\config.psd1') -PollSeconds 30
```

## Felsökning och tester

| Symptom | Kontroll |
| --- | --- |
| SQL-inloggning/EXECUTE nekas | SYSTEM mot fjärr-SQL: datorkontot `DOMÄN\DATORNAMN$` och dess AD-grupp ska ha `ToastClientReader`. Användarläget: kontrollera användarens behörighet. Ge inte administratörsrättigheter som klientlösning. |
| SQL-anslutning eller TLS misslyckas | Servernamn, TCP-port, brandvägg och betrodd certifikatkedja/namn; behåll certifikatvalidering. |
| Inga meddelanden | Matchning mellan AD `Name` och `ClientName`, aktiv dator/grupp, medlemskap, UTC-giltighet, eventuell avbrytning och datorns delade kvittens/repetitionsstatus. Kontrollera andra aktiva klientsessioner. |
| Dialogen kan inte visas | Aktiv användarsession, 64-bitars PowerShell, lokal ADT-sökväg samt läs-/köråtkomst till den medföljande modulen. SYSTEM kräver sessionsbryggan i PSAppDeployToolkit 4.1.8; en frånkopplad RDP-session räcker inte. |
| Lässtatus saknas eller åtkomst nekas | Kör `deploy\Initialize-ToastReadState.ps1 -ConfigPath <klientkonfiguration>` som administratör i 64-bitars PowerShell på klientdatorn. Kontrollera den utskrivna HKLM-sökvägen; ge inte användare skrivåtkomst på överordnade nycklar. |
| Logg saknas eller åtkomst nekas | Kontrollera processens befintliga skrivrättigheter till `%SystemRoot%\Temp` och aktuell loggfil samt eventuella fillås. Skripten ändrar inga rättigheter. Loggfilen skapas automatiskt direkt i Temp; `deploy\Initialize-ToastLogging.ps1` kontrollerar endast katalogens existens. |
| `SetValue`: `Cannot write to the registry key` trots provisionering | Uppdatera `src\Module\ToastSql.psm1`: skrivhandtaget måste öppnas med `RegistryKeyPermissionCheck.ReadWriteSubTree` och endast `RegistryRights.SetValue`. `Default` ger ett skrivskyddat .NET-handtag även när ACL tillåter skrivning. Utöka inte ACL och kör inte klienten som administratör. |
| Meddelandet visas igen efter kvittering | Kontrollera fel vid skrivning till HKLM, ändrat SQL-/datorscope, borttagen maskinstatus eller aktiverade repetitioner. |

Repositoryts befintliga Pester-svit körs på en dator med Pester installerat:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
Invoke-Pester -Path (Join-Path $root 'tests')
```

Testet med taggen `WindowsRegistry` skriver och uppdaterar status i en unik tillfällig HKLM-hashnyckel och tar sedan bort den. Det körs endast i eleverad 64-bitars PowerShell på Windows; övriga miljöer hoppar över det.

Mockade tester ersätter inte integrationstest mot verklig SQL Server, AD, TLS och en interaktiv Windows-session. Verifiera installation, SQL-roller och smoketest i målmiljön före utrullning.
