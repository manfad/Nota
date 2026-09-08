USE [master]
GO
/****** Object:  Database [shop]    Script Date: 07/09/2026 14:12:03 ******/
CREATE DATABASE [shop]
GO
USE [shop]
GO
/****** Object:  Table [dbo].[customers]    Script Date: 07/09/2026 14:12:03 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[customers](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](120) NOT NULL,
	[city] [nvarchar](80) NULL,
	[email] [nvarchar](255) NULL,
	[joined] [date] NOT NULL,
	[newsletter] [bit] NOT NULL,
	[updated_at] [datetime2](7) NOT NULL,
 CONSTRAINT [PK_customers] PRIMARY KEY CLUSTERED
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY],
 CONSTRAINT [UQ_customers_email] UNIQUE NONCLUSTERED
(
	[email] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[products]    Script Date: 07/09/2026 14:12:03 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[products](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[sku] [char](8) NOT NULL,
	[name] [nvarchar](160) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[category] [nvarchar](16) NOT NULL,
	[price] [decimal](10, 2) NOT NULL,
	[in_stock] [smallint] NOT NULL,
	[notes] [nvarchar](max) NULL,
	[thumbnail] [varbinary](max) NULL,
	[rowguid] [uniqueidentifier] ROWGUIDCOL  NOT NULL,
 CONSTRAINT [PK_products] PRIMARY KEY CLUSTERED
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[orders]    Script Date: 07/09/2026 14:12:03 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[orders](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[customer_id] [int] NOT NULL,
	[placed] [datetime] NOT NULL,
	[status] [nvarchar](16) NOT NULL,
	[note] [nvarchar](255) NULL,
 CONSTRAINT [PK_orders] PRIMARY KEY CLUSTERED
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[order_items]    Script Date: 07/09/2026 14:12:03 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[order_items](
	[order_id] [int] NOT NULL,
	[product_id] [int] NOT NULL,
	[quantity] [smallint] NOT NULL,
	[unit_price] [decimal](10, 2) NOT NULL,
 CONSTRAINT [PK_order_items] PRIMARY KEY CLUSTERED
(
	[order_id] ASC,
	[product_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[settings]    Script Date: 07/09/2026 14:12:03 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[settings](
	[key] [nvarchar](64) NOT NULL,
	[value] [nvarchar](max) NULL,
 CONSTRAINT [PK_settings] PRIMARY KEY CLUSTERED
(
	[key] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
SET IDENTITY_INSERT [dbo].[customers] ON

INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (1, N'Aisyah Rahman', N'Kuala Lumpur', N'aisyah@example.com', CAST(N'2025-01-14' AS Date), 1, CAST(N'2025-01-14T09:12:00.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (2, N'陈美玲', N'北京', N'meiling@example.cn', CAST(N'2025-02-03' AS Date), 0, CAST(N'2025-02-03T11:40:21.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (3, N'Daniel O''Brien', N'Dublin', N'dobrien@example.ie', CAST(N'2025-02-19' AS Date), 1, CAST(N'2025-02-19T16:05:44.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (4, N'林志豪', N'台北', N'chihao@example.tw', CAST(N'2025-03-01' AS Date), 0, CAST(N'2025-03-01T08:00:00.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (5, N'Priya Nair', N'Penang', NULL, CAST(N'2025-03-22' AS Date), 1, CAST(N'2025-03-22T13:27:09.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (6, N'Hans "Hansi" Müller', N'München', N'hans@example.de', CAST(N'2025-04-10' AS Date), 1, CAST(N'2025-04-10T10:10:10.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (7, N'Siti Nurhaliza', N'Johor Bahru', N'siti@example.my', CAST(N'2025-04-28' AS Date), 0, CAST(N'2025-04-28T17:45:00.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (8, N'Kenji Tanaka', N'Osaka', N'kenji@example.jp', CAST(N'2025-05-15' AS Date), 1, CAST(N'2025-05-15T07:30:12.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (9, N'王小明', N'上海', N'xiaoming@example.cn', CAST(N'2025-06-02' AS Date), 0, CAST(N'2025-06-02T12:00:00.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (10, N'Fatima Al-Sayed', N'Dubai', N'fatima@example.ae', CAST(N'2025-06-30' AS Date), 1, CAST(N'2025-06-30T19:20:05.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (11, N'Léa Dubois', N'Lyon', N'lea@example.fr', CAST(N'2025-07-18' AS Date), 1, CAST(N'2025-07-18T14:14:14.000' AS DateTime2))
INSERT [dbo].[customers] ([id], [name], [city], [email], [joined], [newsletter], [updated_at]) VALUES (12, N'Muhammad Faiz', N'Kuching', N'faiz@example.my', CAST(N'2025-08-09' AS Date), 0, CAST(N'2025-08-09T09:09:09.000' AS DateTime2))
GO
SET IDENTITY_INSERT [dbo].[customers] OFF
GO
SET IDENTITY_INSERT [dbo].[products] ON

INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (1, N'LMP-0001', N'燈籠 paper lantern, red', N'lamp', CAST(18.50 AS Decimal(10, 2)), 42, N'Folds flat.
Ships in a tube.', 0x89504E470D0A1A0A, N'3f2504e0-4f89-11d3-9a0c-0305e82c3301')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (2, N'LMP-0002', N'Brass desk lamp', N'lamp', CAST(129.00 AS Decimal(10, 2)), 5, NULL, NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3302')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (3, N'PPR-0001', N'A5 dot-grid notebook', N'paper', CAST(9.90 AS Decimal(10, 2)), 300, N'The customer''s favourite.', NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3303')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (4, N'PPR-0002', N'Washi tape, 3 rolls', N'paper', CAST(7.20 AS Decimal(10, 2)), 118, N'Patterns: 桜, 波, 雲', NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3304')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (5, N'PEN-0001', N'Fountain pen, fine nib', N'pen', CAST(64.00 AS Decimal(10, 2)), 17, N'Comes with a converter', NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3305')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (6, N'PEN-0002', N'Gel pen set (12)', N'pen', CAST(14.40 AS Decimal(10, 2)), 260, NULL, NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3306')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (7, N'INK-0001', N'Iron-gall ink, 50 ml', N'ink', CAST(21.00 AS Decimal(10, 2)), 33, N'Say "blue-black" — it dries darker.', NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3307')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (8, N'INK-0002', N'Ink cartridges (6)', N'ink', CAST(5.50 AS Decimal(10, 2)), 500, NULL, NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3308')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (9, N'BAG-0001', N'Canvas tote', N'bag', CAST(24.00 AS Decimal(10, 2)), 80, N'C:\shop\art\tote.svg', NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c3309')
INSERT [dbo].[products] ([id], [sku], [name], [category], [price], [in_stock], [notes], [thumbnail], [rowguid]) VALUES (10, N'BAG-0002', N'Pen roll, leather', N'bag', CAST(39.00 AS Decimal(10, 2)), 12, N'Holds 8 pens', NULL, N'3f2504e0-4f89-11d3-9a0c-0305e82c330a')
GO
SET IDENTITY_INSERT [dbo].[products] OFF
GO
SET IDENTITY_INSERT [dbo].[orders] ON

INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (1, 1, CAST(N'2025-03-02T10:15:00.000' AS DateTime), N'shipped', NULL)
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (2, 2, CAST(N'2025-03-05T14:02:11.000' AS DateTime), N'shipped', N'请轻拿轻放')
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (3, 3, CAST(N'2025-03-09T09:30:00.000' AS DateTime), N'paid', N'Leave with the neighbour if I''m out')
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (4, 4, CAST(N'2025-03-15T18:45:30.000' AS DateTime), N'cancelled', N'改天再買')
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (5, 5, CAST(N'2025-04-01T08:00:00.000' AS DateTime), N'shipped', NULL)
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (6, 6, CAST(N'2025-04-12T12:12:12.000' AS DateTime), N'shipped', N'Gift wrap, please')
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (7, 7, CAST(N'2025-05-03T16:20:00.000' AS DateTime), N'paid', NULL)
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (8, 8, CAST(N'2025-05-20T07:55:41.000' AS DateTime), N'shipped', NULL)
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (9, 9, CAST(N'2025-06-06T11:11:11.000' AS DateTime), N'pending', N'发票抬头：王小明')
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (10, 10, CAST(N'2025-07-01T20:00:00.000' AS DateTime), N'shipped', NULL)
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (11, 11, CAST(N'2025-07-22T13:37:00.000' AS DateTime), N'paid', N'Livraison le matin')
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (12, 1, CAST(N'2025-08-10T09:00:00.000' AS DateTime), N'pending', N'Repeat order')
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (13, 12, CAST(N'2025-08-15T15:15:15.000' AS DateTime), N'shipped', NULL)
INSERT [dbo].[orders] ([id], [customer_id], [placed], [status], [note]) VALUES (14, 2, CAST(N'2025-09-01T10:30:00.000' AS DateTime), N'pending', NULL)
GO
SET IDENTITY_INSERT [dbo].[orders] OFF
GO
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (1, 3, 2, CAST(9.90 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (1, 6, 1, CAST(14.40 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (2, 1, 4, CAST(18.50 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (3, 5, 1, CAST(64.00 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (3, 7, 2, CAST(21.00 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (4, 2, 1, CAST(129.00 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (5, 4, 3, CAST(7.20 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (6, 5, 1, CAST(64.00 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (6, 10, 1, CAST(39.00 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (7, 8, 6, CAST(5.50 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (8, 9, 2, CAST(24.00 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (9, 1, 10, CAST(18.50 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (10, 3, 5, CAST(9.90 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (11, 7, 1, CAST(21.00 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (12, 3, 2, CAST(9.90 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (13, 6, 3, CAST(14.40 AS Decimal(10, 2)))
INSERT [dbo].[order_items] ([order_id], [product_id], [quantity], [unit_price]) VALUES (14, 4, 1, CAST(7.20 AS Decimal(10, 2)))
GO
INSERT [dbo].[settings] ([key], [value]) VALUES (N'currency', N'MYR')
INSERT [dbo].[settings] ([key], [value]) VALUES (N'free_shipping_over', N'150.00')
INSERT [dbo].[settings] ([key], [value]) VALUES (N'shop_name', N'燈籠 Stationery')
GO
/****** Object:  Index [idx_orders_customer]    Script Date: 07/09/2026 14:12:03 ******/
CREATE NONCLUSTERED INDEX [idx_orders_customer] ON [dbo].[orders]
(
	[customer_id] ASC
)
INCLUDE([placed]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [idx_products_category]    Script Date: 07/09/2026 14:12:03 ******/
CREATE NONCLUSTERED INDEX [idx_products_category] ON [dbo].[products]
(
	[category] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
ALTER TABLE [dbo].[products] ADD  CONSTRAINT [DF_products_in_stock]  DEFAULT ((0)) FOR [in_stock]
GO
ALTER TABLE [dbo].[orders]  WITH CHECK ADD  CONSTRAINT [FK_orders_customer] FOREIGN KEY([customer_id])
REFERENCES [dbo].[customers] ([id])
ON DELETE CASCADE
GO
ALTER TABLE [dbo].[orders] CHECK CONSTRAINT [FK_orders_customer]
GO
ALTER TABLE [dbo].[order_items]  WITH CHECK ADD  CONSTRAINT [FK_items_order] FOREIGN KEY([order_id])
REFERENCES [dbo].[orders] ([id])
GO
ALTER TABLE [dbo].[order_items] CHECK CONSTRAINT [FK_items_order]
GO
ALTER TABLE [dbo].[order_items]  WITH CHECK ADD  CONSTRAINT [FK_items_product] FOREIGN KEY([product_id])
REFERENCES [dbo].[products] ([id])
GO
ALTER TABLE [dbo].[order_items] CHECK CONSTRAINT [FK_items_product]
GO
EXEC sys.sp_addextendedproperty @name=N'MS_Description', @value=N'people who bought something' , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'TABLE',@level1name=N'customers'
GO
EXEC sys.sp_addextendedproperty @name=N'MS_Description', @value=N'lower-cased on save' , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'TABLE',@level1name=N'customers', @level2type=N'COLUMN',@level2name=N'email'
GO
USE [master]
GO
ALTER DATABASE [shop] SET  READ_WRITE
GO
