/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:14
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Servers].[Servers](
	[serverID] [int] IDENTITY(1,1) NOT NULL,
	[Servername] [varchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SQL_Build_Version] [sql_variant] NULL,
	[SQL_Server_Edition] [varchar](300) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SQL_Server_Patch_Level] [varchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Core_count] [int] NULL,
	[RAM] [int] NULL,
	[Server_Collation] [varchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Max_Server_Memory_value_in_use] [int] NULL,
	[Max_Server_Percentage] [float] NULL,
	[Optimize_for_Ad_hoc] [tinyint] NULL,
	[Max_DOP] [int] NULL,
	[CostThreshold] [int] NULL,
	[repo_create_date] [datetime2](7) NULL,
	[decomm] [bit] NULL,
	[decomm_date] [datetime2](7) NULL,
	[Trace_Flags] [varchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[is_prod] [bit] NULL,
	[locked_pages_in_memory] [bit] NULL,
	[is_sql] [bit] NULL,
	[push] [bit] NULL,
	[is_ssas] [bit] NULL,
	[is_ssrs] [bit] NULL,
	[is_ssis] [bit] NULL,
	[SQL_Server_Product_Level] [varchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ServerModel] [varchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[is_LogShipped] [bit] NULL,
	[is_admin] [bit] NULL,
	[LogShip_Id] [smallint] NULL,
	[is_dr] [bit] NULL,
	[LPIM] [varchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SQLServerAccount] [varchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SQLServerAgentAccount] [varchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[is_rds] [bit] NULL
) ON [PRIMARY]

GO

