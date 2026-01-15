/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:14
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Servers].[MongoDB](
	[ServerID] [int] IDENTITY(1,1) NOT NULL,
	[HostName] [varchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[IP] [varchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[is_prod] [bit] NULL,
	[is_stage] [bit] NULL,
	[is_arbitor] [bit] NULL,
	[decomm] [bit] NULL,
	[decomm_date] [datetime] NULL,
	[is_linux] [bit] NULL,
	[is_windows] [bit] NULL
) ON [PRIMARY]

GO

