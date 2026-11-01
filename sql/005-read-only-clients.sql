/* Run LAST after 001-004 (including when upgrading). Retain historical delivery data. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage
    @GroupName nvarchar(128),
    @Title nvarchar(200),
    @Body nvarchar(4000),
    @ExpiresUtc datetime2(0) = NULL,
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

    IF @AcknowledgeButtonText IS NOT NULL AND @ButtonText IS NOT NULL AND UPPER(@AcknowledgeButtonText) = UPPER(@ButtonText)
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

    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName = @GroupName AND IsActive = 1);
    IF @GroupId IS NULL THROW 50001, 'Active toast group was not found.', 1;

    BEGIN TRAN;

    INSERT dbo.ToastMessage(
        GroupId,
        Title,
        Subtitle,
        Body,
        ExpiresUtc,
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

    COMMIT;

    SELECT @MessageId AS MessageId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_GetPendingToast
    @ComputerName nvarchar(256),
    @MessageId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.MessageId, m.Title, m.Subtitle, m.Body, m.Sound, m.IsUrgent,
           m.ButtonText, m.ButtonArguments, m.ButtonActivationType, m.AcknowledgeButtonText,
           m.Scenario, CAST('AppDeployToolkit' AS varchar(20)) AS DisplayMode,
           m.RepeatIntervalSeconds, m.RepeatCount, m.ExpiresUtc
    FROM dbo.ToastMessage m
    INNER JOIN dbo.ToastGroup g ON g.GroupId = m.GroupId AND g.IsActive = 1
    INNER JOIN dbo.ToastClientGroup cg ON cg.GroupId = m.GroupId
    INNER JOIN dbo.ToastClient c ON c.ClientId = cg.ClientId
    WHERE c.ComputerName = @ComputerName AND c.IsActive = 1
      AND m.IsCancelled = 0
      AND (m.ExpiresUtc IS NULL OR m.ExpiresUtc > SYSDATETIME())
      AND (@MessageId IS NULL OR m.MessageId = @MessageId)
    ORDER BY m.IsUrgent DESC, m.MessageId;
END;
GO
-- Old callers must fail explicitly, never continue updating delivery history.
CREATE OR ALTER PROCEDURE dbo.usp_RecordToastDelivery
    @ComputerName nvarchar(256),
    @MessageId bigint,
    @Status varchar(20),
    @ErrorMessage nvarchar(2000) = NULL,
    @LeaseId uniqueidentifier = NULL
AS
BEGIN
    THROW 50040, 'Database delivery reporting is retired. Upgrade the client to local registry read tracking.', 1;
END;
GO
IF DATABASE_PRINCIPAL_ID('ToastClientReader') IS NULL
    CREATE ROLE ToastClientReader AUTHORIZATION dbo;
GRANT EXECUTE ON OBJECT::dbo.usp_GetPendingToast TO ToastClientReader;
DENY INSERT, UPDATE, DELETE TO ToastClientReader;
DENY EXECUTE ON OBJECT::dbo.usp_QueueToastMessage TO ToastClientReader;
DENY EXECUTE ON OBJECT::dbo.usp_RecordToastDelivery TO ToastClientReader;
GO
