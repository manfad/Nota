-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Sep 07, 2026 at 02:10 PM
-- Server version: 8.0.36
-- PHP Version: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";
SET NAMES utf8mb4;
SET CHARACTER SET utf8mb4;


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `shop`
--

-- --------------------------------------------------------

--
-- Table structure for table `customers`
--

CREATE TABLE `customers` (
  `id` int UNSIGNED NOT NULL AUTO_INCREMENT,
  `name` varchar(120) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `city` varchar(80) DEFAULT NULL,
  `email` varchar(255) DEFAULT NULL COMMENT 'lower-cased on save',
  `joined` date NOT NULL,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `email` (`email`),
  KEY `idx_city` (`city`)
) ENGINE=InnoDB AUTO_INCREMENT=13 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='people who bought something';

--
-- Dumping data for table `customers`
--

LOCK TABLES `customers` WRITE;
/*!40000 ALTER TABLE `customers` DISABLE KEYS */;
INSERT INTO `customers` (`id`, `name`, `city`, `email`, `joined`, `updated_at`) VALUES
(1, 'Aisyah Rahman', 'Kuala Lumpur', 'aisyah@example.com', '2025-01-14', '2025-01-14 09:12:00'),
(2, '陈美玲', '北京', 'meiling@example.cn', '2025-02-03', '2025-02-03 11:40:21'),
(3, 'Daniel O\'Brien', 'Dublin', 'dobrien@example.ie', '2025-02-19', '2025-02-19 16:05:44'),
(4, '林志豪', '台北', 'chihao@example.tw', '2025-03-01', '2025-03-01 08:00:00'),
(5, 'Priya Nair', 'Penang', NULL, '2025-03-22', '2025-03-22 13:27:09'),
(6, 'Hans "Hansi" Müller', 'München', 'hans@example.de', '2025-04-10', '2025-04-10 10:10:10'),
(7, 'Siti Nurhaliza', 'Johor Bahru', 'siti@example.my', '2025-04-28', '2025-04-28 17:45:00'),
(8, 'Kenji Tanaka', 'Osaka', 'kenji@example.jp', '2025-05-15', '2025-05-15 07:30:12'),
(9, '王小明', '上海', 'xiaoming@example.cn', '2025-06-02', '2025-06-02 12:00:00'),
(10, 'Fatima Al-Sayed', 'Dubai', 'fatima@example.ae', '2025-06-30', '2025-06-30 19:20:05'),
(11, 'Léa Dubois', 'Lyon', 'lea@example.fr', '2025-07-18', '2025-07-18 14:14:14'),
(12, 'Muhammad Faiz', 'Kuching', 'faiz@example.my', '2025-08-09', '2025-08-09 09:09:09');
/*!40000 ALTER TABLE `customers` ENABLE KEYS */;
UNLOCK TABLES;

-- --------------------------------------------------------

--
-- Table structure for table `products`
--

CREATE TABLE `products` (
  `id` int UNSIGNED NOT NULL AUTO_INCREMENT,
  `sku` char(8) NOT NULL,
  `name` varchar(160) NOT NULL,
  `category` enum('lamp','paper','pen','ink','bag') NOT NULL DEFAULT 'paper',
  `price` decimal(10,2) UNSIGNED NOT NULL,
  `in_stock` smallint UNSIGNED NOT NULL DEFAULT '0',
  `notes` text,
  PRIMARY KEY (`id`),
  UNIQUE KEY `sku` (`sku`),
  KEY `idx_category` (`category`),
  FULLTEXT KEY `ft_name_notes` (`name`,`notes`)
) ENGINE=InnoDB AUTO_INCREMENT=11 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `products`
--

LOCK TABLES `products` WRITE;
INSERT INTO `products` (`id`, `sku`, `name`, `category`, `price`, `in_stock`, `notes`) VALUES
(1, 'LMP-0001', '燈籠 paper lantern, red', 'lamp', 18.50, 42, 'Folds flat.\nShips in a tube.'),
(2, 'LMP-0002', 'Brass desk lamp', 'lamp', 129.00, 5, NULL),
(3, 'PPR-0001', 'A5 dot-grid notebook', 'paper', 9.90, 300, 'The customer\'s favourite.'),
(4, 'PPR-0002', 'Washi tape, 3 rolls', 'paper', 7.20, 118, 'Patterns: 桜, 波, 雲'),
(5, 'PEN-0001', 'Fountain pen, fine nib', 'pen', 64.00, 17, 'Comes with a converter'),
(6, 'PEN-0002', 'Gel pen set (12)', 'pen', 14.40, 260, NULL),
(7, 'INK-0001', 'Iron-gall ink, 50 ml', 'ink', 21.00, 33, 'Say \"blue-black\" — it dries darker.'),
(8, 'INK-0002', 'Ink cartridges (6)', 'ink', 5.50, 500, NULL),
(9, 'BAG-0001', 'Canvas tote', 'bag', 24.00, 80, 'C:\\shop\\art\\tote.svg'),
(10, 'BAG-0002', 'Pen roll, leather', 'bag', 39.00, 12, 'Holds 8 pens');
UNLOCK TABLES;

-- --------------------------------------------------------

--
-- Table structure for table `orders`
--

CREATE TABLE `orders` (
  `id` int UNSIGNED NOT NULL AUTO_INCREMENT,
  `customer_id` int UNSIGNED NOT NULL,
  `placed` datetime NOT NULL,
  `status` enum('pending','paid','shipped','cancelled') NOT NULL DEFAULT 'pending',
  `note` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_orders_customer` (`customer_id`),
  CONSTRAINT `fk_orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=15 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `orders`
--

INSERT INTO `orders` (`id`, `customer_id`, `placed`, `status`, `note`) VALUES
(1, 1, '2025-03-02 10:15:00', 'shipped', NULL),
(2, 2, '2025-03-05 14:02:11', 'shipped', '请轻拿轻放'),
(3, 3, '2025-03-09 09:30:00', 'paid', 'Leave with the neighbour if I\'m out'),
(4, 4, '2025-03-15 18:45:30', 'cancelled', '改天再買'),
(5, 5, '2025-04-01 08:00:00', 'shipped', NULL),
(6, 6, '2025-04-12 12:12:12', 'shipped', 'Gift wrap, please'),
(7, 7, '2025-05-03 16:20:00', 'paid', NULL),
(8, 8, '2025-05-20 07:55:41', 'shipped', NULL),
(9, 9, '2025-06-06 11:11:11', 'pending', '发票抬头：王小明'),
(10, 10, '2025-07-01 20:00:00', 'shipped', NULL),
(11, 11, '2025-07-22 13:37:00', 'paid', 'Livraison le matin'),
(12, 1, '2025-08-10 09:00:00', 'pending', 'Repeat order'),
(13, 12, '2025-08-15 15:15:15', 'shipped', NULL),
(14, 2, '2025-09-01 10:30:00', 'pending', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `order_items`
--

CREATE TABLE `order_items` (
  `order_id` int UNSIGNED NOT NULL,
  `product_id` int UNSIGNED NOT NULL,
  `quantity` smallint UNSIGNED NOT NULL DEFAULT '1',
  `unit_price` decimal(10,2) NOT NULL,
  PRIMARY KEY (`order_id`,`product_id`),
  KEY `fk_items_product` (`product_id`),
  CONSTRAINT `fk_items_order` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`),
  CONSTRAINT `fk_items_product` FOREIGN KEY (`product_id`) REFERENCES `products` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `order_items`
--

INSERT INTO `order_items` (`order_id`, `product_id`, `quantity`, `unit_price`) VALUES
(1, 3, 2, 9.90),
(1, 6, 1, 14.40),
(2, 1, 4, 18.50),
(3, 5, 1, 64.00),
(3, 7, 2, 21.00),
(4, 2, 1, 129.00),
(5, 4, 3, 7.20),
(6, 10, 1, 39.00),
(6, 5, 1, 64.00),
(7, 8, 6, 5.50),
(8, 9, 2, 24.00),
(9, 1, 10, 18.50),
(10, 3, 5, 9.90),
(11, 7, 1, 21.00),
(12, 3, 2, 9.90),
(13, 6, 3, 14.40),
(14, 4, 1, 7.20);

-- --------------------------------------------------------

--
-- Table structure for table `settings`
--

CREATE TABLE `settings` (
  `key` varchar(64) NOT NULL,
  `value` text,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `settings` (`key`, `value`) VALUES
('currency', 'MYR'),
('shop_name', '燈籠 Stationery'),
('free_shipping_over', '150.00');

COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
