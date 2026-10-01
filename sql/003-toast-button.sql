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

IF COL_LENGTH('dbo.ToastMessage', 'Subtitle') IS NULL
    ALTER TABLE dbo.ToastMessage ADD Subtitle nvarchar(200) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'AcknowledgeButtonText') IS NULL
    ALTER TABLE dbo.ToastMessage ADD AcknowledgeButtonText nvarchar(200) NULL;

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
