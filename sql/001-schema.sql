/* =========================================================
   BurntToast-SQLserver — Full install script
   Creates all tables, indexes, constraints, procedures,
   functions and views in their final (current) shape.
   Run this against an empty/new database.
   ========================================================= */

SET NOCOUNT ON;
SET XACT_ABORT ON;

-------------------------------------------------------------
-- 1. Tables
-------------------------------------------------------------

CREATE TABLE dbo.ToastGroup (
    GroupId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastGroup PRIMARY KEY,
    GroupName   nvarchar(128) NOT NULL CONSTRAINT UQ_ToastGroup_GroupName UNIQUE,
    IsActive    bit NOT NULL CONSTRAINT DF_ToastGroup_IsActive DEFAULT (1),
    CreatedUtc  datetime2(0) NOT NULL CONSTRAINT DF_ToastGroup_CreatedUtc DEFAULT (SYSDATETIME())
);

CREATE TABLE dbo.ToastClient (
    ClientId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastClient PRIMARY KEY,
    ComputerName  nvarchar(256) NOT NULL CONSTRAINT UQ_ToastClient_ComputerName UNIQUE,
    IsActive      bit NOT NULL CONSTRAINT DF_ToastClient_IsActive DEFAULT (1),
    LastSeenUtc   datetime2(0) NULL,
    CreatedUtc    datetime2(0) NOT NULL CONSTRAINT DF_ToastClient_CreatedUtc DEFAULT (SYSDATETIME())
);

CREATE TABLE dbo.ToastClientGroup (
    ClientId int NOT NULL,
    GroupId  int NOT NULL,
    CONSTRAINT PK_ToastClientGroup PRIMARY KEY (ClientId, GroupId),
    CONSTRAINT FK_ToastClientGroup_Client FOREIGN KEY (ClientId) REFERENCES dbo.ToastClient(ClientId),
    CONSTRAINT FK_ToastClientGroup_Group  FOREIGN KEY (GroupId)  REFERENCES dbo.ToastGroup(GroupId)
);

CREATE TABLE dbo.ToastMessage (
    MessageId               bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastMessage PRIMARY KEY,
    GroupId                 int NOT NULL,
    Title                   nvarchar(200) NOT NULL,
    Subtitle                nvarchar(200) NULL,
    Body                    nvarchar(4000) NOT NULL,
    CreatedUtc              datetime2(0) NOT NULL CONSTRAINT DF_ToastMessage_CreatedUtc DEFAULT (SYSDATETIME()),
    ExpiresUtc              datetime2(0) NULL,
    IsCancelled             bit NOT NULL CONSTRAINT DF_ToastMessage_IsCancelled DEFAULT (0),
    AppLogoPath             nvarchar(1024) NULL,
    HeroImagePath           nvarchar(1024) NULL,
    AppLogoBytes            varbinary(max) NULL,
    AppLogoContentType      varchar(100) NULL,
    HeroImageBytes          varbinary(max) NULL,
    HeroImageContentType    varchar(100) NULL,
    Sound                   varchar(20) NULL,
    IsUrgent                bit NOT NULL CONSTRAINT DF_ToastMessage_IsUrgent DEFAULT (0),
    RepeatIntervalSeconds   int NULL,
    RepeatCount             int NULL,
    ButtonText              nvarchar(200) NULL,
    ButtonArguments         nvarchar(2048) NULL,
    ButtonActivationType    varchar(20) NULL,
    AcknowledgeButtonText   nvarchar(200) NULL,
    Scenario                varchar(20) NULL,
    DisplayMode             varchar(20) NOT NULL CONSTRAINT DF_ToastMessage_DisplayMode DEFAULT ('AppDeployToolkit'),
    CONSTRAINT FK_ToastMessage_Group FOREIGN KEY (GroupId) REFERENCES dbo.ToastGroup(GroupId)
);

CREATE TABLE dbo.ToastDelivery (
    MessageId        bigint NOT NULL,
    ClientId         int NOT NULL,
    Status           varchar(20) NOT NULL CONSTRAINT DF_ToastDelivery_Status DEFAULT ('Pending'),
    Attempts         int NOT NULL CONSTRAINT DF_ToastDelivery_Attempts DEFAULT (0),
    LastAttemptUtc   datetime2(0) NULL,
    DeliveredUtc     datetime2(0) NULL,
    ErrorMessage     nvarchar(2000) NULL,
    NextShowUtc      datetime2(0) NOT NULL CONSTRAINT DF_ToastDelivery_NextShowUtc DEFAULT (SYSDATETIME()),
    ShowCount        int NOT NULL CONSTRAINT DF_ToastDelivery_ShowCount DEFAULT (0),
    LeaseId          uniqueidentifier NULL,
    LeaseExpiresUtc  datetime2(0) NULL,
    CONSTRAINT PK_ToastDelivery PRIMARY KEY (MessageId, ClientId),
    CONSTRAINT FK_ToastDelivery_Message FOREIGN KEY (MessageId) REFERENCES dbo.ToastMessage(MessageId),
    CONSTRAINT FK_ToastDelivery_Client  FOREIGN KEY (ClientId)  REFERENCES dbo.ToastClient(ClientId),
    CONSTRAINT CK_ToastDelivery_Status CHECK (Status IN ('Pending','InProgress','Delivered','Failed','Cancelled'))
);

-------------------------------------------------------------
-- 2. Indexes
-------------------------------------------------------------

CREATE INDEX IX_ToastDelivery_Client_Status
    ON dbo.ToastDelivery(ClientId, Status, NextShowUtc, LeaseExpiresUtc, MessageId);

CREATE INDEX IX_ToastMessage_Polling
    ON dbo.ToastMessage(MessageId)
    INCLUDE (IsCancelled, ExpiresUtc, Title, Body, AppLogoPath, HeroImagePath, Sound, IsUrgent, RepeatIntervalSeconds, RepeatCount);
GO

-------------------------------------------------------------
-- 3. Stored procedures
-------------------------------------------------------------

CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage
    @GroupName nvarchar(128),
    @Title nvarchar(200),
    @Body nvarchar(4000),
    @ExpiresUtc datetime2(0) = NULL,
    @AppLogoPath nvarchar(1024) = NULL,
    @HeroImagePath nvarchar(1024) = NULL,
    @AppLogoBytes varbinary(max) = NULL,
    @AppLogoContentType varchar(100) = NULL,
    @HeroImageBytes varbinary(max) = NULL,
    @HeroImageContentType varchar(100) = NULL,
    @Sound varchar(20) = NULL,
    @IsUrgent bit = 0,
    @RepeatIntervalSeconds int = NULL,
    @RepeatCount int = NULL,
    @ButtonText nvarchar(200) = NULL,
    @ButtonArguments nvarchar(2048) = NULL,
    @ButtonActivationType varchar(20) = NULL,
    @Scenario varchar(20) = 'Default',
    @DisplayMode varchar(20) = 'AppDeployToolkit',
    @ResolvedScenario varchar(20) = NULL OUTPUT,
    @Subtitle nvarchar(200) = NULL,
    @AcknowledgeButtonText nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF (@RepeatIntervalSeconds IS NULL AND @RepeatCount IS NOT NULL) OR (@RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NULL)
        THROW 50002, 'RepeatIntervalSeconds and RepeatCount must both be provided for repeating messages.', 1;

    IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatIntervalSeconds < 1
        THROW 50003, 'RepeatIntervalSeconds must be greater than zero.', 1;

    IF @RepeatCount IS NOT NULL AND @RepeatCount < 2
        THROW 50004, 'RepeatCount must be 2 or greater because it includes the first display.', 1;

    SET @ButtonText = NULLIF(LTRIM(RTRIM(@ButtonText)), '');
    SET @ButtonArguments = NULLIF(LTRIM(RTRIM(@ButtonArguments)), '');
    SET @ButtonActivationType = NULLIF(LTRIM(RTRIM(@ButtonActivationType)), '');
    SET @AppLogoContentType = LOWER(NULLIF(LTRIM(RTRIM(@AppLogoContentType)), ''));
    SET @HeroImageContentType = LOWER(NULLIF(LTRIM(RTRIM(@HeroImageContentType)), ''));
    SET @Scenario = NULLIF(LTRIM(RTRIM(@Scenario)), '');
    SET @DisplayMode = NULLIF(LTRIM(RTRIM(@DisplayMode)), '');
    SET @AcknowledgeButtonText = NULLIF(LTRIM(RTRIM(@AcknowledgeButtonText)), '');

    IF @Scenario IS NULL
        SET @Scenario = 'Default';

    IF @Scenario NOT IN ('Default','Reminder','Alarm','IncomingCall')
        THROW 50030, 'Scenario must be Default, Reminder, Alarm, or IncomingCall.', 1;

    IF @DisplayMode IS NULL
        SET @DisplayMode = 'AppDeployToolkit';

    IF @DisplayMode <> 'AppDeployToolkit'
        THROW 50031, 'DisplayMode must be AppDeployToolkit.', 1;

    SET @ResolvedScenario = @Scenario;

    IF @ButtonText IS NULL AND @ButtonArguments IS NOT NULL
        THROW 50008, 'ButtonText must be provided when ButtonArguments is supplied.', 1;

    IF @ButtonText IS NULL AND @ButtonActivationType IS NOT NULL
        THROW 50009, 'ButtonText must be provided when ButtonActivationType is supplied.', 1;

    IF @ButtonText IS NOT NULL AND @ButtonActivationType IS NULL
        SET @ButtonActivationType = 'Protocol';

    IF @AcknowledgeButtonText IS NOT NULL AND @ButtonText IS NOT NULL AND @AcknowledgeButtonText = @ButtonText
        THROW 50032, 'AcknowledgeButtonText must differ from ButtonText.', 1;

    IF @ButtonActivationType IS NOT NULL AND @ButtonActivationType NOT IN ('Protocol','Dismiss')
        THROW 50010, 'ButtonActivationType must be Protocol or Dismiss.', 1;

    IF @ButtonText IS NOT NULL AND @ButtonActivationType = 'Protocol' AND @ButtonArguments IS NULL
        THROW 50011, 'ButtonArguments is required when ButtonActivationType is Protocol.', 1;

    DECLARE @ButtonUriSchemeSeparator int = CHARINDEX(':', @ButtonArguments);
    DECLARE @ButtonUriScheme varchar(20) = LOWER(LEFT(@ButtonArguments, @ButtonUriSchemeSeparator - 1));
    IF @ButtonText IS NOT NULL AND @ButtonActivationType = 'Protocol' AND (
        @ButtonUriSchemeSeparator <= 1
        OR SUBSTRING(@ButtonArguments, 1, 1) NOT LIKE '[A-Za-z]'
        OR PATINDEX('%[^A-Za-z0-9+.-]%', LEFT(@ButtonArguments, @ButtonUriSchemeSeparator - 1)) > 0
        OR (@ButtonUriScheme IN ('http','https','ftp','file','ws','wss') AND @ButtonArguments NOT LIKE @ButtonUriScheme + '://%')
        OR (@ButtonUriScheme IN ('http','https','ftp','ws','wss') AND (
                LEN(@ButtonArguments) <= @ButtonUriSchemeSeparator + 3
                OR SUBSTRING(@ButtonArguments, @ButtonUriSchemeSeparator + 3, 1) IN ('/','?','#')
            ))
    )
        THROW 50012, 'ButtonArguments must look like a valid absolute URI when ButtonActivationType is Protocol.', 1;

    IF (@AppLogoBytes IS NULL AND @AppLogoContentType IS NOT NULL) OR (@AppLogoBytes IS NOT NULL AND @AppLogoContentType IS NULL)
        THROW 50014, 'AppLogoBytes and AppLogoContentType must both be provided for binary app-logo images.', 1;

    IF (@HeroImageBytes IS NULL AND @HeroImageContentType IS NOT NULL) OR (@HeroImageBytes IS NOT NULL AND @HeroImageContentType IS NULL)
        THROW 50015, 'HeroImageBytes and HeroImageContentType must both be provided for binary hero images.', 1;

    IF @AppLogoContentType = 'image/jpg'
        SET @AppLogoContentType = 'image/jpeg';

    IF @HeroImageContentType = 'image/jpg'
        SET @HeroImageContentType = 'image/jpeg';

    IF @AppLogoContentType IS NOT NULL AND @AppLogoContentType NOT IN ('image/png','image/jpeg','image/gif','image/bmp')
        THROW 50016, 'AppLogoContentType must be image/png, image/jpeg, image/gif, or image/bmp.', 1;

    IF @HeroImageContentType IS NOT NULL AND @HeroImageContentType NOT IN ('image/png','image/jpeg','image/gif','image/bmp')
        THROW 50017, 'HeroImageContentType must be image/png, image/jpeg, image/gif, or image/bmp.', 1;

    IF @AppLogoBytes IS NOT NULL AND DATALENGTH(@AppLogoBytes) > 5242880
        THROW 50018, 'AppLogoBytes exceeds the maximum supported image size of 5242880 bytes.', 1;

    IF @AppLogoBytes IS NOT NULL AND DATALENGTH(@AppLogoBytes) = 0
        THROW 50020, 'AppLogoBytes must not be empty.', 1;

    IF @HeroImageBytes IS NOT NULL AND DATALENGTH(@HeroImageBytes) > 5242880
        THROW 50019, 'HeroImageBytes exceeds the maximum supported image size of 5242880 bytes.', 1;

    IF @HeroImageBytes IS NOT NULL AND DATALENGTH(@HeroImageBytes) = 0
        THROW 50021, 'HeroImageBytes must not be empty.', 1;

    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName = @GroupName AND IsActive = 1);
    IF @GroupId IS NULL THROW 50001, 'Active toast group was not found.', 1;

    BEGIN TRAN;

    INSERT dbo.ToastMessage(
        GroupId, Title, Subtitle, Body, ExpiresUtc, AppLogoPath, HeroImagePath,
        AppLogoBytes, AppLogoContentType, HeroImageBytes, HeroImageContentType,
        Sound, IsUrgent, RepeatIntervalSeconds, RepeatCount,
        ButtonText, ButtonArguments, ButtonActivationType, Scenario, DisplayMode,
        AcknowledgeButtonText
    )
    VALUES(
        @GroupId, @Title, NULLIF(LTRIM(RTRIM(@Subtitle)), ''), @Body, @ExpiresUtc, NULLIF(@AppLogoPath, ''), NULLIF(@HeroImagePath, ''),
        @AppLogoBytes, @AppLogoContentType, @HeroImageBytes, @HeroImageContentType,
        NULLIF(@Sound, ''), ISNULL(@IsUrgent, 0), @RepeatIntervalSeconds, @RepeatCount,
        @ButtonText, @ButtonArguments, @ButtonActivationType, @Scenario, @DisplayMode,
        @AcknowledgeButtonText
    );

    DECLARE @MessageId bigint = SCOPE_IDENTITY();

    INSERT dbo.ToastDelivery(MessageId, ClientId)
        SELECT @MessageId, ClientId
        FROM dbo.ToastClientGroup
        WHERE GroupId = @GroupId;

    COMMIT;

    SELECT @MessageId AS MessageId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPendingToast
    @ComputerName nvarchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName AND IsActive = 1);
    IF @ClientId IS NULL RETURN;

    DECLARE @Now datetime2(0) = SYSDATETIME();
    DECLARE @LeaseSeconds int = 120;

    UPDATE dbo.ToastClient
    SET LastSeenUtc = @Now
    WHERE ClientId = @ClientId;

    ;WITH DueMessages AS (
        SELECT TOP (20) d.ClientId, d.MessageId
        FROM dbo.ToastDelivery d WITH (UPDLOCK, READPAST, ROWLOCK)
        INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
        WHERE d.ClientId = @ClientId
          AND m.IsCancelled = 0
          AND (m.ExpiresUtc IS NULL OR m.ExpiresUtc > @Now)
          AND d.NextShowUtc <= @Now
          AND (
                d.Status = 'Pending'
                OR (d.Status = 'InProgress' AND d.LeaseExpiresUtc IS NOT NULL AND d.LeaseExpiresUtc <= @Now)
              )
        ORDER BY d.MessageId
    )
    UPDATE d
    SET Status = 'InProgress',
        LeaseId = NEWID(),
        LeaseExpiresUtc = DATEADD(second, @LeaseSeconds, @Now),
        ErrorMessage = NULL
    OUTPUT inserted.MessageId,
           inserted.LeaseId,
           m.Title,
           m.Subtitle,
           m.Body,
           m.AppLogoPath,
           m.HeroImagePath,
           m.AppLogoBytes,
           m.AppLogoContentType,
           m.HeroImageBytes,
           m.HeroImageContentType,
           m.Sound,
           m.IsUrgent,
           m.ButtonText,
           m.ButtonArguments,
           m.ButtonActivationType,
           m.AcknowledgeButtonText,
           m.Scenario,
           CAST('AppDeployToolkit' AS varchar(20)) AS DisplayMode,
           m.RepeatIntervalSeconds,
           m.RepeatCount,
           m.ExpiresUtc,
           inserted.ShowCount
    FROM dbo.ToastDelivery d
    INNER JOIN DueMessages x ON x.ClientId = d.ClientId AND x.MessageId = d.MessageId
    INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
    WHERE d.ClientId = @ClientId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RecordToastDelivery
    @ComputerName nvarchar(256),
    @MessageId bigint,
    @Status varchar(20),
    @ErrorMessage nvarchar(2000) = NULL,
    @LeaseId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName);
    IF @ClientId IS NULL RETURN;
    IF @LeaseId IS NULL THROW 50005, 'LeaseId is required when recording a toast delivery.', 1;
    IF @Status NOT IN ('Delivered','Failed','Cancelled') THROW 50007, 'Status must be Delivered, Failed, or Cancelled.', 1;

    DECLARE @Now datetime2(0) = SYSDATETIME();
    DECLARE @RepeatIntervalSeconds int;
    DECLARE @RepeatCount int;
    DECLARE @ExpiresUtc datetime2(0);
    DECLARE @ShowCount int;
    DECLARE @FailureShowCount int;
    DECLARE @FailureNextShowUtc datetime2(0);
    DECLARE @FailureStatus varchar(20);

    SELECT
        @RepeatIntervalSeconds = m.RepeatIntervalSeconds,
        @RepeatCount = m.RepeatCount,
        @ExpiresUtc = m.ExpiresUtc,
        @ShowCount = d.ShowCount
    FROM dbo.ToastDelivery d
    INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
    WHERE d.MessageId = @MessageId
      AND d.ClientId = @ClientId
      AND d.LeaseId = @LeaseId;

    IF @ShowCount IS NULL THROW 50006, 'Toast delivery lease was not found or is no longer active for this client.', 1;

    IF @Status = 'Delivered'
    BEGIN
        DECLARE @NewShowCount int = @ShowCount + 1;
        DECLARE @NextShowUtc datetime2(0) = NULL;

        IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NOT NULL AND @NewShowCount < @RepeatCount
        BEGIN
            SET @NextShowUtc = DATEADD(second, @RepeatIntervalSeconds, @Now);

            IF @ExpiresUtc IS NOT NULL AND @NextShowUtc >= @ExpiresUtc
                SET @NextShowUtc = NULL;
        END;

        UPDATE dbo.ToastDelivery
        SET Status = CASE WHEN @NextShowUtc IS NULL THEN 'Delivered' ELSE 'Pending' END,
            Attempts = Attempts + 1,
            ShowCount = @NewShowCount,
            LastAttemptUtc = @Now,
            DeliveredUtc = CASE WHEN @NextShowUtc IS NULL THEN @Now ELSE NULL END,
            NextShowUtc = CASE WHEN @NextShowUtc IS NULL THEN @Now ELSE @NextShowUtc END,
            ErrorMessage = NULL,
            LeaseId = NULL,
            LeaseExpiresUtc = NULL
        WHERE MessageId = @MessageId
          AND ClientId = @ClientId
          AND LeaseId = @LeaseId;

        IF @@ROWCOUNT = 0 THROW 50006, 'Toast delivery lease was not found or is no longer active for this client.', 1;

        RETURN;
    END;

    SET @FailureStatus = @Status;
    SET @FailureNextShowUtc = @Now;
    SET @FailureShowCount = @ShowCount;

    IF @Status = 'Failed'
    BEGIN
        SET @FailureShowCount = @ShowCount + 1;

        IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NOT NULL AND @FailureShowCount < @RepeatCount
        BEGIN
            SET @FailureNextShowUtc = DATEADD(second, @RepeatIntervalSeconds, @Now);

            IF @ExpiresUtc IS NULL OR @FailureNextShowUtc < @ExpiresUtc
                SET @FailureStatus = 'Pending';
            ELSE
                SET @FailureNextShowUtc = @Now;
        END;
    END;

    UPDATE dbo.ToastDelivery
    SET Status = @FailureStatus,
        Attempts = Attempts + 1,
        ShowCount = @FailureShowCount,
        LastAttemptUtc = @Now,
        DeliveredUtc = NULL,
        NextShowUtc = @FailureNextShowUtc,
        ErrorMessage = @ErrorMessage,
        LeaseId = NULL,
        LeaseExpiresUtc = NULL
    WHERE MessageId = @MessageId
      AND ClientId = @ClientId
      AND LeaseId = @LeaseId;

    IF @@ROWCOUNT = 0 THROW 50006, 'Toast delivery lease was not found or is no longer active for this client.', 1;
END;
GO

-------------------------------------------------------------
-- 4. Local-time reporting functions & views
-------------------------------------------------------------

DECLARE @DefaultLocalTimeZone sysname = NULL;
BEGIN TRY
    EXEC sp_executesql
        N'SELECT @ResolvedTimeZone = CONVERT(sysname, CURRENT_TIMEZONE())',
        N'@ResolvedTimeZone sysname OUTPUT',
        @ResolvedTimeZone = @DefaultLocalTimeZone OUTPUT;
END TRY
BEGIN CATCH
    SET @DefaultLocalTimeZone = NULL;
END CATCH;

IF @DefaultLocalTimeZone IS NULL
BEGIN
    SELECT TOP (1) @DefaultLocalTimeZone = name
    FROM sys.time_zone_info
    WHERE current_utc_offset = DATENAME(TZOFFSET, SYSDATETIMEOFFSET())
    ORDER BY name;
END;

IF @DefaultLocalTimeZone IS NULL
    THROW 50014, 'Unable to resolve SQL Server local Windows time zone name before local-time reporting setup.', 1;

DECLARE @EscapedDefaultLocalTimeZone nvarchar(256) = REPLACE(@DefaultLocalTimeZone, '''', '''''');

DECLARE @Sql1 nvarchar(max) = N'
CREATE OR ALTER FUNCTION dbo.ufn_ToastMessageLocal
(
    @TimeZoneName sysname = N''' + @EscapedDefaultLocalTimeZone + N''',
    @ServerTimeZoneName sysname = N''' + @EscapedDefaultLocalTimeZone + N'''
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        m.MessageId,
        m.GroupId,
        m.Title,
        m.Body,
        m.CreatedUtc,
        m.ExpiresUtc,
        m.CreatedUtc AS CreatedServerLocalTime,
        m.ExpiresUtc AS ExpiresServerLocalTime,
        (m.CreatedUtc AT TIME ZONE @ServerTimeZoneName) AT TIME ZONE @TimeZoneName AS CreatedLocalTime,
        (m.ExpiresUtc AT TIME ZONE @ServerTimeZoneName) AT TIME ZONE @TimeZoneName AS ExpiresLocalTime
    FROM dbo.ToastMessage m
);';

DECLARE @Sql2 nvarchar(max) = N'
CREATE OR ALTER FUNCTION dbo.ufn_ToastDeliveryLocal
(
    @TimeZoneName sysname = N''' + @EscapedDefaultLocalTimeZone + N''',
    @ServerTimeZoneName sysname = N''' + @EscapedDefaultLocalTimeZone + N'''
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        d.MessageId,
        d.ClientId,
        d.Status,
        d.Attempts,
        d.LastAttemptUtc,
        d.DeliveredUtc,
        c.LastSeenUtc,
        d.LastAttemptUtc AS LastAttemptServerLocalTime,
        d.DeliveredUtc AS DeliveredServerLocalTime,
        c.LastSeenUtc AS LastSeenServerLocalTime,
        (d.LastAttemptUtc AT TIME ZONE @ServerTimeZoneName) AT TIME ZONE @TimeZoneName AS LastAttemptLocalTime,
        (d.DeliveredUtc AT TIME ZONE @ServerTimeZoneName) AT TIME ZONE @TimeZoneName AS DeliveredLocalTime,
        (c.LastSeenUtc AT TIME ZONE @ServerTimeZoneName) AT TIME ZONE @TimeZoneName AS LastSeenLocalTime
    FROM dbo.ToastDelivery d
    INNER JOIN dbo.ToastClient c ON c.ClientId = d.ClientId
);';

DECLARE @Sql3 nvarchar(max) = N'
CREATE OR ALTER VIEW dbo.vw_ToastMessageLocal
AS
SELECT
    m.MessageId,
    m.GroupId,
    m.Title,
    m.Body,
    m.CreatedUtc,
    m.ExpiresUtc,
    m.CreatedUtc AS CreatedServerLocalTime,
    m.ExpiresUtc AS ExpiresServerLocalTime,
    m.CreatedUtc AT TIME ZONE N''' + @EscapedDefaultLocalTimeZone + N''' AS CreatedLocalTime,
    m.ExpiresUtc AT TIME ZONE N''' + @EscapedDefaultLocalTimeZone + N''' AS ExpiresLocalTime
FROM dbo.ToastMessage m;';

DECLARE @Sql4 nvarchar(max) = N'
CREATE OR ALTER VIEW dbo.vw_ToastDeliveryLocal
AS
SELECT
    d.MessageId,
    d.ClientId,
    d.Status,
    d.Attempts,
    d.LastAttemptUtc,
    d.DeliveredUtc,
    c.LastSeenUtc,
    d.LastAttemptUtc AS LastAttemptServerLocalTime,
    d.DeliveredUtc AS DeliveredServerLocalTime,
    c.LastSeenUtc AS LastSeenServerLocalTime,
    d.LastAttemptUtc AT TIME ZONE N''' + @EscapedDefaultLocalTimeZone + N''' AS LastAttemptLocalTime,
    d.DeliveredUtc AT TIME ZONE N''' + @EscapedDefaultLocalTimeZone + N''' AS DeliveredLocalTime,
    c.LastSeenUtc AT TIME ZONE N''' + @EscapedDefaultLocalTimeZone + N''' AS LastSeenLocalTime
FROM dbo.ToastDelivery d
INNER JOIN dbo.ToastClient c ON c.ClientId = d.ClientId;';

EXEC sp_executesql @Sql1;
EXEC sp_executesql @Sql2;
EXEC sp_executesql @Sql3;
EXEC sp_executesql @Sql4;
GO
