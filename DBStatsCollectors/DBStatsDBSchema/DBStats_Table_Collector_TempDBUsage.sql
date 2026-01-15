/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:14
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Collector].[TempDBUsage](
	[ComputerName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[InstanceName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SqlInstance] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Spid] [smallint] NULL,
	[StatementCommand] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[QueryText] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProcedureName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[StartTime] [datetime2](7) NULL,
	[CurrentUserAllocatedKB] [bigint] NULL,
	[TotalUserAllocatedKB] [bigint] NULL,
	[UserDeallocatedKB] [bigint] NULL,
	[TotalUserDeallocatedKB] [bigint] NULL,
	[InternalAllocatedKB] [bigint] NULL,
	[TotalInternalAllocatedKB] [bigint] NULL,
	[InternalDeallocatedKB] [bigint] NULL,
	[TotalInternalDeallocatedKB] [bigint] NULL,
	[RequestedReads] [bigint] NULL,
	[RequestedWrites] [bigint] NULL,
	[RequestedLogicalReads] [bigint] NULL,
	[RequestedCPUTime] [int] NULL,
	[IsUserProcess] [bit] NULL,
	[Status] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Database] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoginName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OriginalLoginName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[NTDomain] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[NTUserName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[HostName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProgramName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoginTime] [datetime2](7) NULL,
	[LastRequestedStartTime] [datetime2](7) NULL,
	[LastRequestedEndTime] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RowError] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RowState] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Table] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ItemArray] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[HasErrors] [bit] NULL,
	[CollectionTime] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO

