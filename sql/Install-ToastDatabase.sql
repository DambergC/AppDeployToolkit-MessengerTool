/*
Fresh installation only, SQL Server 2016 or later. Select an existing EMPTY
application database; this script does not create or upgrade databases.
Example (integrated authentication):
  sqlcmd -S SQLSERVER -d ToastNotifications -E -b -f 65001 -i sql/Install-ToastDatabase.sql

Run the entire file as one batch (no GO separators). All DDL, including procedure
definitions, executes inside one transaction after the empty-database guard.
Any failure rolls back the installation; no existing objects are dropped.
Use a dedicated database and add separate database users to ToastClientReader
or ToastMessageAdmin afterwards. Neither role requires db_owner membership.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
        THROW 50000, 'Select an empty application database, not a system database.', 1;

    IF EXISTS (SELECT 1 FROM sys.objects WHERE is_ms_shipped = 0)
        OR EXISTS (SELECT 1 FROM sys.types WHERE is_user_defined = 1)
        OR EXISTS (
            SELECT 1 FROM sys.schemas
            WHERE name NOT IN (
                N'dbo', N'guest', N'INFORMATION_SCHEMA', N'sys',
                N'db_owner', N'db_accessadmin', N'db_securityadmin', N'db_ddladmin',
                N'db_backupoperator', N'db_datareader', N'db_datawriter',
                N'db_denydatareader', N'db_denydatawriter'
            )
        )
        OR DATABASE_PRINCIPAL_ID(N'ToastClientReader') IS NOT NULL
        OR DATABASE_PRINCIPAL_ID(N'ToastMessageAdmin') IS NOT NULL
        THROW 50001, 'Fresh installation requires an empty database with no existing application objects, schemas, types, or Toast roles. Existing installations are not supported.', 1;

    EXEC sys.sp_executesql N'
CREATE TABLE dbo.ToastGroup (
    GroupId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastGroup PRIMARY KEY,
    GroupName nvarchar(128) NOT NULL CONSTRAINT UQ_ToastGroup_GroupName UNIQUE,
    IsActive bit NOT NULL CONSTRAINT DF_ToastGroup_IsActive DEFAULT (1),
    CreatedUtc datetime2(7) NOT NULL CONSTRAINT DF_ToastGroup_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_ToastGroup_Name CHECK (LEN(LTRIM(RTRIM(GroupName))) > 0)
);

CREATE TABLE dbo.ToastClient (
    ClientId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastClient PRIMARY KEY,
    ComputerName nvarchar(256) NOT NULL CONSTRAINT UQ_ToastClient_ComputerName UNIQUE,
    IsActive bit NOT NULL CONSTRAINT DF_ToastClient_IsActive DEFAULT (1),
    CreatedUtc datetime2(7) NOT NULL CONSTRAINT DF_ToastClient_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_ToastClient_Name CHECK (LEN(LTRIM(RTRIM(ComputerName))) > 0)
);

CREATE TABLE dbo.ToastClientGroup (
    ClientId int NOT NULL,
    GroupId int NOT NULL,
    CONSTRAINT PK_ToastClientGroup PRIMARY KEY (ClientId, GroupId),
    CONSTRAINT FK_ToastClientGroup_Client FOREIGN KEY (ClientId) REFERENCES dbo.ToastClient(ClientId),
    CONSTRAINT FK_ToastClientGroup_Group FOREIGN KEY (GroupId) REFERENCES dbo.ToastGroup(GroupId)
);
CREATE INDEX IX_ToastClientGroup_Group ON dbo.ToastClientGroup(GroupId, ClientId);

CREATE TABLE dbo.ToastMessageTemplate (
    TemplateId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastMessageTemplate PRIMARY KEY,
    Name nvarchar(200) NULL,
    Description nvarchar(4000) NULL,
    Title nvarchar(200) NOT NULL,
    Subtitle nvarchar(200) NULL,
    Body nvarchar(4000) NOT NULL,
    AcknowledgeButtonText nvarchar(200) NOT NULL CONSTRAINT DF_ToastMessageTemplate_AcknowledgeButtonText DEFAULT (N''Stäng''),
    CONSTRAINT CK_ToastMessageTemplate_Title CHECK (LEN(LTRIM(RTRIM(Title))) > 0),
    CONSTRAINT CK_ToastMessageTemplate_Body CHECK (LEN(LTRIM(RTRIM(Body))) > 0),
    CONSTRAINT CK_ToastMessageTemplate_AcknowledgeButtonText CHECK (
        LEN(LTRIM(RTRIM(AcknowledgeButtonText))) > 0
        AND LTRIM(RTRIM(AcknowledgeButtonText)) COLLATE Latin1_General_100_CI_AS <> N''Timeout''
    )
);

CREATE TABLE dbo.ToastMessage (
    MessageId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastMessage PRIMARY KEY,
    GroupId int NOT NULL,
    Title nvarchar(200) NOT NULL,
    Subtitle nvarchar(200) NULL,
    Body nvarchar(4000) NOT NULL,
    AcknowledgeButtonText nvarchar(200) NOT NULL CONSTRAINT DF_ToastMessage_AcknowledgeButtonText DEFAULT (N''Stäng''),
    CreatedUtc datetime2(7) NOT NULL CONSTRAINT DF_ToastMessage_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    ExpiresUtc datetime2(7) NOT NULL,
    RepeatIntervalSeconds int NULL,
    RepeatCount int NULL,
    IsCancelled bit NOT NULL CONSTRAINT DF_ToastMessage_IsCancelled DEFAULT (0),
    CONSTRAINT FK_ToastMessage_Group FOREIGN KEY (GroupId) REFERENCES dbo.ToastGroup(GroupId),
    CONSTRAINT CK_ToastMessage_Title CHECK (LEN(LTRIM(RTRIM(Title))) > 0),
    CONSTRAINT CK_ToastMessage_Body CHECK (LEN(LTRIM(RTRIM(Body))) > 0),
    CONSTRAINT CK_ToastMessage_AcknowledgeButtonText CHECK (
        LEN(LTRIM(RTRIM(AcknowledgeButtonText))) > 0
        AND LTRIM(RTRIM(AcknowledgeButtonText)) COLLATE Latin1_General_100_CI_AS <> N''Timeout''
    ),
    CONSTRAINT CK_ToastMessage_Expiration CHECK (ExpiresUtc > CreatedUtc),
    CONSTRAINT CK_ToastMessage_Repeat CHECK (
        (RepeatIntervalSeconds IS NULL AND RepeatCount IS NULL)
        OR (RepeatIntervalSeconds IS NOT NULL AND RepeatCount IS NOT NULL
            AND RepeatIntervalSeconds > 0 AND RepeatCount >= 2)
    )
);
CREATE INDEX IX_ToastMessage_Polling
    ON dbo.ToastMessage(GroupId, ExpiresUtc, MessageId)
    INCLUDE (Title, Subtitle, Body, AcknowledgeButtonText, RepeatIntervalSeconds, RepeatCount)
    WHERE IsCancelled = 0;

CREATE TABLE dbo.ToastMessageAudit (
    AuditId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastMessageAudit PRIMARY KEY,
    EventType varchar(6) NOT NULL CONSTRAINT CK_ToastMessageAudit_EventType CHECK (EventType IN (''INSERT'', ''UPDATE'', ''DELETE'')),
    EventUtc datetime2(7) NOT NULL CONSTRAINT DF_ToastMessageAudit_EventUtc DEFAULT (SYSUTCDATETIME()),
    SqlUser nvarchar(128) NOT NULL,
    DomainUser nvarchar(256) NULL,
    SqlServer nvarchar(128) NOT NULL,
    SenderHost nvarchar(128) NULL,
    MessageId bigint NOT NULL,
    GroupId int NOT NULL,
    GroupName nvarchar(128) NOT NULL,
    Title nvarchar(200) NOT NULL,
    Subtitle nvarchar(200) NULL,
    Body nvarchar(4000) NOT NULL,
    AcknowledgeButtonText nvarchar(200) NOT NULL,
    CreatedUtc datetime2(7) NOT NULL,
    ExpiresUtc datetime2(7) NOT NULL,
    RepeatIntervalSeconds int NULL,
    RepeatCount int NULL,
    IsCancelled bit NOT NULL
);
CREATE INDEX IX_ToastMessageAudit_Message ON dbo.ToastMessageAudit(MessageId, AuditId);
';

    EXEC sys.sp_executesql N'
CREATE TRIGGER dbo.tr_ToastMessage_Audit ON dbo.ToastMessage
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.ToastMessageAudit (
        EventType, SqlUser, DomainUser, SqlServer, SenderHost, MessageId, GroupId, GroupName,
        Title, Subtitle, Body, AcknowledgeButtonText, CreatedUtc, ExpiresUtc,
        RepeatIntervalSeconds, RepeatCount, IsCancelled
    )
    SELECT CASE WHEN d.MessageId IS NULL THEN ''INSERT'' ELSE ''UPDATE'' END,
        ORIGINAL_LOGIN(), CONVERT(nvarchar(256), SESSION_CONTEXT(N''DomainUser'')),
        CONVERT(nvarchar(128), SERVERPROPERTY(''ServerName'')), HOST_NAME(),
        i.MessageId, i.GroupId, g.GroupName, i.Title, i.Subtitle, i.Body,
        i.AcknowledgeButtonText, i.CreatedUtc, i.ExpiresUtc,
        i.RepeatIntervalSeconds, i.RepeatCount, i.IsCancelled
    FROM inserted AS i
    LEFT JOIN deleted AS d ON d.MessageId = i.MessageId
    INNER JOIN dbo.ToastGroup AS g ON g.GroupId = i.GroupId
    UNION ALL
    SELECT ''DELETE'',
        ORIGINAL_LOGIN(), CONVERT(nvarchar(256), SESSION_CONTEXT(N''DomainUser'')),
        CONVERT(nvarchar(128), SERVERPROPERTY(''ServerName'')), HOST_NAME(),
        d.MessageId, d.GroupId, g.GroupName, d.Title, d.Subtitle, d.Body,
        d.AcknowledgeButtonText, d.CreatedUtc, d.ExpiresUtc,
        d.RepeatIntervalSeconds, d.RepeatCount, d.IsCancelled
    FROM deleted AS d
    INNER JOIN dbo.ToastGroup AS g ON g.GroupId = d.GroupId
    WHERE NOT EXISTS (SELECT 1 FROM inserted AS i WHERE i.MessageId = d.MessageId);
END;
';

    EXEC sys.sp_executesql N'
CREATE PROCEDURE dbo.usp_GetPendingToast
    @ComputerName nvarchar(256),
    @MessageId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.MessageId, m.Title, m.Subtitle, m.Body, m.AcknowledgeButtonText,
           m.RepeatIntervalSeconds, m.RepeatCount, m.ExpiresUtc
    FROM dbo.ToastMessage AS m
    INNER JOIN dbo.ToastGroup AS g ON g.GroupId = m.GroupId AND g.IsActive = 1
    INNER JOIN dbo.ToastClientGroup AS cg ON cg.GroupId = m.GroupId
    INNER JOIN dbo.ToastClient AS c ON c.ClientId = cg.ClientId
    WHERE c.ComputerName = @ComputerName AND c.IsActive = 1
      AND m.IsCancelled = 0
      AND m.ExpiresUtc > SYSUTCDATETIME()
      AND (@MessageId IS NULL OR m.MessageId = @MessageId)
    ORDER BY m.MessageId;
END;
';

    EXEC sys.sp_executesql N'
CREATE PROCEDURE dbo.usp_QueueToastMessage
    @GroupName nvarchar(128),
    @Title nvarchar(200),
    @Body nvarchar(4000),
    @Subtitle nvarchar(200) = NULL,
    @AcknowledgeButtonText nvarchar(200) = N''Stäng'',
    @ExpiresUtc datetime2(7) = NULL,
    @ActiveDuration int = NULL,
    @DurationUnit varchar(10) = NULL,
    @RepeatIntervalSeconds int = NULL,
    @RepeatCount int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @GroupName = NULLIF(LTRIM(RTRIM(@GroupName)), N'''');
    IF @GroupName IS NULL OR NULLIF(LTRIM(RTRIM(@Title)), N'''') IS NULL
        OR NULLIF(LTRIM(RTRIM(@Body)), N'''') IS NULL
        THROW 50002, ''GroupName, Title, and Body must not be empty.'', 1;

    SET @Subtitle = NULLIF(LTRIM(RTRIM(@Subtitle)), N'''');
    SET @AcknowledgeButtonText = COALESCE(NULLIF(LTRIM(RTRIM(@AcknowledgeButtonText)), N''''), N''Stäng'');
    IF @AcknowledgeButtonText COLLATE Latin1_General_100_CI_AS = N''Timeout''
        THROW 50012, ''AcknowledgeButtonText must not be Timeout because it is reserved by the prompt.'', 1;

    IF (@ExpiresUtc IS NOT NULL AND (@ActiveDuration IS NOT NULL OR @DurationUnit IS NOT NULL))
        OR (@ExpiresUtc IS NULL AND (@ActiveDuration IS NULL OR @DurationUnit IS NULL))
        THROW 50003, ''Specify exactly one of ExpiresUtc or ActiveDuration together with DurationUnit.'', 1;
    IF @ActiveDuration IS NOT NULL AND @ActiveDuration <= 0
        THROW 50004, ''ActiveDuration must be a positive integer.'', 1;
    IF @DurationUnit IS NOT NULL AND @DurationUnit COLLATE Latin1_General_100_BIN2 NOT IN (''Days'', ''Hours'', ''Minutes'')
        THROW 50005, ''DurationUnit must be Days, Hours, or Minutes.'', 1;

    IF (@RepeatIntervalSeconds IS NULL AND @RepeatCount IS NOT NULL)
        OR (@RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NULL)
        THROW 50006, ''RepeatIntervalSeconds and RepeatCount must both be provided.'', 1;
    IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatIntervalSeconds <= 0
        THROW 50007, ''RepeatIntervalSeconds must be greater than zero.'', 1;
    IF @RepeatCount IS NOT NULL AND @RepeatCount < 2
        THROW 50008, ''RepeatCount must be 2 or greater because it includes the first display.'', 1;

    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName = @GroupName AND IsActive = 1);
    IF @GroupId IS NULL
        THROW 50009, ''Active toast group was not found.'', 1;

    DECLARE @CreatedUtc datetime2(7) = SYSUTCDATETIME();
    IF @ExpiresUtc IS NULL
    BEGIN
        BEGIN TRY
            SET @ExpiresUtc = CASE @DurationUnit
                WHEN ''Minutes'' THEN DATEADD(MINUTE, @ActiveDuration, @CreatedUtc)
                WHEN ''Hours'' THEN DATEADD(HOUR, @ActiveDuration, @CreatedUtc)
                WHEN ''Days'' THEN DATEADD(DAY, @ActiveDuration, @CreatedUtc)
            END;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (517, 8115)
                THROW 50010, ''ActiveDuration exceeds the supported expiration date range.'', 1;
            THROW;
        END CATCH;
    END;
    IF @ExpiresUtc IS NULL OR @ExpiresUtc <= @CreatedUtc
        THROW 50011, ''ExpiresUtc must be a future UTC date.'', 1;

    INSERT dbo.ToastMessage (
        GroupId, Title, Subtitle, Body, AcknowledgeButtonText, CreatedUtc,
        ExpiresUtc, RepeatIntervalSeconds, RepeatCount
    )
    VALUES (
        @GroupId, @Title, @Subtitle, @Body, @AcknowledgeButtonText, @CreatedUtc,
        @ExpiresUtc, @RepeatIntervalSeconds, @RepeatCount
    );
    SELECT CONVERT(bigint, SCOPE_IDENTITY()) AS MessageId;
END;
';

    EXEC sys.sp_executesql N'
CREATE ROLE ToastClientReader AUTHORIZATION dbo;
CREATE ROLE ToastMessageAdmin AUTHORIZATION dbo;
GRANT EXECUTE ON OBJECT::dbo.usp_GetPendingToast TO ToastClientReader;
DENY INSERT, UPDATE, DELETE TO ToastClientReader;
DENY EXECUTE ON OBJECT::dbo.usp_QueueToastMessage TO ToastClientReader;

GRANT EXECUTE ON OBJECT::dbo.usp_QueueToastMessage TO ToastMessageAdmin;
GRANT SELECT, INSERT ON OBJECT::dbo.ToastGroup TO ToastMessageAdmin;
GRANT SELECT, INSERT, DELETE ON OBJECT::dbo.ToastClient TO ToastMessageAdmin;
GRANT SELECT, INSERT, DELETE ON OBJECT::dbo.ToastClientGroup TO ToastMessageAdmin;
GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.ToastMessageTemplate TO ToastMessageAdmin;
GRANT SELECT ON OBJECT::dbo.ToastMessageAudit TO ToastMessageAdmin;
';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
