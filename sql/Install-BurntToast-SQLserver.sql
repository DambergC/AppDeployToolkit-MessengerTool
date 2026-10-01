/* =========================================================
   BurntToast-SQLserver — Consolidated install/upgrade script
   Safe for both new installations and upgrades.
   Creates missing base tables/indexes and then applies the
   repeat, button/display-mode, and local-time reporting updates.
   ========================================================= */

SET NOCOUNT ON;
SET XACT_ABORT ON;

-------------------------------------------------------------
-- 1. Base schema (create when missing)
-------------------------------------------------------------

IF OBJECT_ID('dbo.ToastGroup', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ToastGroup (
        GroupId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastGroup PRIMARY KEY,
        GroupName   nvarchar(128) NOT NULL CONSTRAINT UQ_ToastGroup_GroupName UNIQUE,
        IsActive    bit NOT NULL CONSTRAINT DF_ToastGroup_IsActive DEFAULT (1),
        CreatedUtc  datetime2(0) NOT NULL CONSTRAINT DF_ToastGroup_CreatedUtc DEFAULT (SYSDATETIME())
    );
END;

IF OBJECT_ID('dbo.ToastClient', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ToastClient (
        ClientId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastClient PRIMARY KEY,
        ComputerName  nvarchar(256) NOT NULL CONSTRAINT UQ_ToastClient_ComputerName UNIQUE,
        IsActive      bit NOT NULL CONSTRAINT DF_ToastClient_IsActive DEFAULT (1),
        LastSeenUtc   datetime2(0) NULL,
        CreatedUtc    datetime2(0) NOT NULL CONSTRAINT DF_ToastClient_CreatedUtc DEFAULT (SYSDATETIME())
    );
END;

IF OBJECT_ID('dbo.ToastClientGroup', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ToastClientGroup (
        ClientId int NOT NULL,
        GroupId  int NOT NULL,
        CONSTRAINT PK_ToastClientGroup PRIMARY KEY (ClientId, GroupId),
        CONSTRAINT FK_ToastClientGroup_Client FOREIGN KEY (ClientId) REFERENCES dbo.ToastClient(ClientId),
        CONSTRAINT FK_ToastClientGroup_Group  FOREIGN KEY (GroupId)  REFERENCES dbo.ToastGroup(GroupId)
    );
END;

IF OBJECT_ID('dbo.ToastMessage', 'U') IS NULL
BEGIN
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
END;

IF COL_LENGTH('dbo.ToastMessage', 'Subtitle') IS NULL
    ALTER TABLE dbo.ToastMessage ADD Subtitle nvarchar(200) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'AcknowledgeButtonText') IS NULL
    ALTER TABLE dbo.ToastMessage ADD AcknowledgeButtonText nvarchar(200) NULL;

IF OBJECT_ID('dbo.ToastDelivery', 'U') IS NULL
BEGIN
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
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastDelivery') AND name = 'IX_ToastDelivery_Client_Status')
    CREATE INDEX IX_ToastDelivery_Client_Status
        ON dbo.ToastDelivery(ClientId, Status, NextShowUtc, LeaseExpiresUtc, MessageId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastMessage') AND name = 'IX_ToastMessage_Polling')
    CREATE INDEX IX_ToastMessage_Polling
        ON dbo.ToastMessage(MessageId)
        INCLUDE (
            IsCancelled, ExpiresUtc, Title, Body,
            AppLogoPath, HeroImagePath, AppLogoBytes, AppLogoContentType, HeroImageBytes, HeroImageContentType,
            Sound, IsUrgent, RepeatIntervalSeconds, RepeatCount,
            ButtonText, ButtonArguments, ButtonActivationType, Scenario, DisplayMode
        );
GO

-------------------------------------------------------------
-- 2. Upgrade/install components from legacy scripts
-------------------------------------------------------------

/* ===== sql/002-toast-design-repeat.sql ===== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ServerLocalTimeZone sysname = NULL;

BEGIN TRY
    EXEC sp_executesql
        N'SELECT @ResolvedTimeZone = CONVERT(sysname, CURRENT_TIMEZONE())',
        N'@ResolvedTimeZone sysname OUTPUT',
        @ResolvedTimeZone = @ServerLocalTimeZone OUTPUT;
END TRY
BEGIN CATCH
    SET @ServerLocalTimeZone = NULL;
END CATCH;

-- CURRENT_TIMEZONE() can return a local display name, for example:
-- "(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna".
-- AT TIME ZONE requires a valid SQL Server time zone name instead.
IF @ServerLocalTimeZone IS NOT NULL
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.time_zone_info
        WHERE name = @ServerLocalTimeZone
    )
    BEGIN
        SET @ServerLocalTimeZone = NULL;
    END;
END;

-- Fallback: match a valid zone by current UTC offset and DST status.
IF @ServerLocalTimeZone IS NULL
BEGIN
    SELECT TOP (1)
        @ServerLocalTimeZone = name
    FROM sys.time_zone_info
    WHERE current_utc_offset = DATENAME(TZOFFSET, SYSDATETIMEOFFSET())
    ORDER BY
        CASE WHEN is_currently_dst = 1 THEN 0 ELSE 1 END,
        name;
END;

-- Final fallback when no time zone can be resolved.
IF @ServerLocalTimeZone IS NULL
BEGIN
    SET @ServerLocalTimeZone = N'UTC';
END;

IF COL_LENGTH('dbo.ToastMessage', 'AppLogoPath') IS NULL
    ALTER TABLE dbo.ToastMessage ADD AppLogoPath nvarchar(1024) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'HeroImagePath') IS NULL
    ALTER TABLE dbo.ToastMessage ADD HeroImagePath nvarchar(1024) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'AppLogoBytes') IS NULL
    ALTER TABLE dbo.ToastMessage ADD AppLogoBytes varbinary(max) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'AppLogoContentType') IS NULL
    ALTER TABLE dbo.ToastMessage ADD AppLogoContentType varchar(100) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'HeroImageBytes') IS NULL
    ALTER TABLE dbo.ToastMessage ADD HeroImageBytes varbinary(max) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'HeroImageContentType') IS NULL
    ALTER TABLE dbo.ToastMessage ADD HeroImageContentType varchar(100) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'Sound') IS NULL
    ALTER TABLE dbo.ToastMessage ADD Sound varchar(20) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'IsUrgent') IS NULL
    ALTER TABLE dbo.ToastMessage ADD IsUrgent bit NOT NULL CONSTRAINT DF_ToastMessage_IsUrgent DEFAULT (0) WITH VALUES;

IF COL_LENGTH('dbo.ToastMessage', 'RepeatIntervalSeconds') IS NULL
    ALTER TABLE dbo.ToastMessage ADD RepeatIntervalSeconds int NULL;

IF COL_LENGTH('dbo.ToastMessage', 'RepeatCount') IS NULL
    ALTER TABLE dbo.ToastMessage ADD RepeatCount int NULL;

IF COL_LENGTH('dbo.ToastDelivery', 'NextShowUtc') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD NextShowUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastDelivery_NextShowUtc DEFAULT (SYSDATETIME()) WITH VALUES;
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRAN;

        DECLARE @NextShowUtcDefaultConstraintName sysname;
        DECLARE @NextShowUtcDefaultDefinition nvarchar(max);

        SELECT
            @NextShowUtcDefaultConstraintName = dc.name,
            @NextShowUtcDefaultDefinition = dc.definition
        FROM sys.default_constraints dc
        INNER JOIN sys.columns c
            ON c.default_object_id = dc.object_id
        WHERE dc.parent_object_id = OBJECT_ID('dbo.ToastDelivery')
          AND c.name = 'NextShowUtc';

        IF @NextShowUtcDefaultDefinition LIKE '%SYSUTCDATETIME%'
        BEGIN
            IF @ServerLocalTimeZone IS NULL
                THROW 50013, 'Unable to resolve SQL Server local Windows time zone name for UTC-to-local timestamp migration.', 1;

            UPDATE dbo.ToastDelivery
            SET
                NextShowUtc = CAST(((NextShowUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0)),
                LeaseExpiresUtc = CASE
                    WHEN LeaseExpiresUtc IS NULL THEN NULL
                    ELSE CAST(((LeaseExpiresUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END
            WHERE NextShowUtc IS NOT NULL
               OR LeaseExpiresUtc IS NOT NULL;

            UPDATE dbo.ToastDelivery
            SET
                LastAttemptUtc = CASE
                    WHEN LastAttemptUtc IS NULL THEN NULL
                    ELSE CAST(((LastAttemptUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END,
                DeliveredUtc = CASE
                    WHEN DeliveredUtc IS NULL THEN NULL
                    ELSE CAST(((DeliveredUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END
            WHERE LastAttemptUtc IS NOT NULL
               OR DeliveredUtc IS NOT NULL;

            UPDATE dbo.ToastClient
            SET LastSeenUtc = CAST(((LastSeenUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
            WHERE LastSeenUtc IS NOT NULL;

            UPDATE dbo.ToastMessage
            SET
                CreatedUtc = CAST(((CreatedUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0)),
                ExpiresUtc = CASE
                    WHEN ExpiresUtc IS NULL THEN NULL
                    ELSE CAST(((ExpiresUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END
            WHERE CreatedUtc IS NOT NULL
               OR ExpiresUtc IS NOT NULL;
        END;

        IF @NextShowUtcDefaultConstraintName IS NOT NULL
        BEGIN
            DECLARE @DropNextShowUtcDefaultConstraintSql nvarchar(max);
            SET @DropNextShowUtcDefaultConstraintSql =
                N'ALTER TABLE dbo.ToastDelivery DROP CONSTRAINT '
                + QUOTENAME(@NextShowUtcDefaultConstraintName)
                + N';';

            EXEC sp_executesql @DropNextShowUtcDefaultConstraintSql;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM sys.default_constraints dc
            INNER JOIN sys.columns c
                ON c.default_object_id = dc.object_id
            WHERE dc.parent_object_id = OBJECT_ID('dbo.ToastDelivery')
              AND c.name = 'NextShowUtc'
        )
            ALTER TABLE dbo.ToastDelivery
                ADD CONSTRAINT DF_ToastDelivery_NextShowUtc DEFAULT (SYSDATETIME()) FOR NextShowUtc;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;

        THROW;
    END CATCH
END;

IF COL_LENGTH('dbo.ToastDelivery', 'ShowCount') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD ShowCount int NOT NULL CONSTRAINT DF_ToastDelivery_ShowCount DEFAULT (0) WITH VALUES;

IF COL_LENGTH('dbo.ToastDelivery', 'LeaseId') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD LeaseId uniqueidentifier NULL;

IF COL_LENGTH('dbo.ToastDelivery', 'LeaseExpiresUtc') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD LeaseExpiresUtc datetime2(0) NULL;

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ToastDelivery_Status' AND parent_object_id = OBJECT_ID('dbo.ToastDelivery'))
    ALTER TABLE dbo.ToastDelivery DROP CONSTRAINT CK_ToastDelivery_Status;

ALTER TABLE dbo.ToastDelivery
    ADD CONSTRAINT CK_ToastDelivery_Status CHECK (Status IN ('Pending','InProgress','Delivered','Failed','Cancelled'));

IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastDelivery') AND name = 'IX_ToastDelivery_Client_Status')
    DROP INDEX IX_ToastDelivery_Client_Status ON dbo.ToastDelivery;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastDelivery') AND name = 'IX_ToastDelivery_Client_Status')
    CREATE INDEX IX_ToastDelivery_Client_Status ON dbo.ToastDelivery(ClientId, Status, NextShowUtc, LeaseExpiresUtc, MessageId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastMessage') AND name = 'IX_ToastMessage_Polling')
    CREATE INDEX IX_ToastMessage_Polling
        ON dbo.ToastMessage(MessageId)
        INCLUDE (IsCancelled, ExpiresUtc, Title, Body, AppLogoPath, HeroImagePath, Sound, IsUrgent, RepeatIntervalSeconds, RepeatCount);

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

/* ===== sql/003-toast-button.sql ===== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF COL_LENGTH('dbo.ToastMessage', 'ButtonText') IS NULL
    ALTER TABLE dbo.ToastMessage ADD ButtonText nvarchar(200) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'ButtonArguments') IS NULL
    ALTER TABLE dbo.ToastMessage ADD ButtonArguments nvarchar(2048) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'ButtonActivationType') IS NULL
    ALTER TABLE dbo.ToastMessage ADD ButtonActivationType varchar(20) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'AppLogoBytes') IS NULL
    ALTER TABLE dbo.ToastMessage ADD AppLogoBytes varbinary(max) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'AppLogoContentType') IS NULL
    ALTER TABLE dbo.ToastMessage ADD AppLogoContentType varchar(100) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'HeroImageBytes') IS NULL
    ALTER TABLE dbo.ToastMessage ADD HeroImageBytes varbinary(max) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'HeroImageContentType') IS NULL
    ALTER TABLE dbo.ToastMessage ADD HeroImageContentType varchar(100) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'Scenario') IS NULL
    ALTER TABLE dbo.ToastMessage ADD Scenario varchar(20) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'DisplayMode') IS NULL
    ALTER TABLE dbo.ToastMessage ADD DisplayMode varchar(20) NULL;

GO

WHILE 1 = 1
BEGIN
    ;WITH MessagesWithDeliveryHistory AS (
        SELECT DISTINCT d.MessageId
        FROM dbo.ToastDelivery d
    )
    UPDATE TOP (1000) m
    SET DisplayMode = 'AppDeployToolkit'
    FROM dbo.ToastMessage m
    LEFT JOIN MessagesWithDeliveryHistory h
        ON h.MessageId = m.MessageId
    WHERE m.DisplayMode IS NULL
       OR (
            m.DisplayMode <> 'AppDeployToolkit'
            AND h.MessageId IS NULL
       );

    IF @@ROWCOUNT = 0
        BREAK;
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.default_constraints dc
    INNER JOIN sys.columns c
        ON c.object_id = dc.parent_object_id
       AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = OBJECT_ID('dbo.ToastMessage')
      AND c.name = 'DisplayMode'
)
    ALTER TABLE dbo.ToastMessage
        ADD CONSTRAINT DF_ToastMessage_DisplayMode DEFAULT ('AppDeployToolkit') FOR DisplayMode;

IF EXISTS (
    SELECT 1
    FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ToastMessage')
      AND name = 'DisplayMode'
      AND is_nullable = 1
)
    ALTER TABLE dbo.ToastMessage
        ALTER COLUMN DisplayMode varchar(20) NOT NULL;

GO
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
    SET @Subtitle = NULLIF(LTRIM(RTRIM(@Subtitle)), '');
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
        GroupId,
        Title,
        Subtitle,
        Body,
        ExpiresUtc,
        AppLogoPath,
        HeroImagePath,
        AppLogoBytes,
        AppLogoContentType,
        HeroImageBytes,
        HeroImageContentType,
        Sound,
        IsUrgent,
        RepeatIntervalSeconds,
        RepeatCount,
        ButtonText,
        ButtonArguments,
        ButtonActivationType,
        Scenario,
        DisplayMode,
        AcknowledgeButtonText
    )
    VALUES(
        @GroupId,
        @Title,
        @Subtitle,
        @Body,
        @ExpiresUtc,
        NULLIF(@AppLogoPath, ''),
        NULLIF(@HeroImagePath, ''),
        @AppLogoBytes,
        @AppLogoContentType,
        @HeroImageBytes,
        @HeroImageContentType,
        NULLIF(@Sound, ''),
        ISNULL(@IsUrgent, 0),
        @RepeatIntervalSeconds,
        @RepeatCount,
        @ButtonText,
        @ButtonArguments,
        @ButtonActivationType,
        @Scenario,
        @DisplayMode,
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


/* ===== sql/004-local-time-reporting.sql ===== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

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
    SET @DefaultLocalTimeZone = N'UTC';
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
