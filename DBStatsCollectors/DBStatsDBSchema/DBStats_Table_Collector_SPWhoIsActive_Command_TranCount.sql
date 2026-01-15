/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:14
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Collector].[SPWhoIsActive_Command_TranCount](
	[database_name] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[dd hh:mm:ss.mss] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[session_id] [smallint] NULL,
	[blocking_session_id] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[tempdb_allocations] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[login_name] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[host_name] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[program_name] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[login_time] [datetime2](7) NULL,
	[start_time] [datetime2](7) NULL,
	[sql_text] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[sql_command] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[wait_info] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[used_memory] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[status] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[open_tran_count] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RowError] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RowState] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Table] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ItemArray] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[HasErrors] [bit] NULL,
	[CollectionTime] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO

