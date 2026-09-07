--
-- PostgreSQL database dump
--

-- Dumped from database version 16.3
-- Dumped by pg_dump version 16.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: shop; Type: SCHEMA; Schema: -; Owner: shop
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: customers; Type: TABLE; Schema: public; Owner: shop
--

CREATE TABLE public.customers (
    id integer NOT NULL,
    name character varying(120) NOT NULL,
    city character varying(80),
    email character varying(255),
    joined date NOT NULL,
    newsletter boolean DEFAULT false NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.customers OWNER TO shop;

--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: shop
--

CREATE SEQUENCE public.customers_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customers_id_seq OWNER TO shop;

--
-- Name: customers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shop
--

ALTER SEQUENCE public.customers_id_seq OWNED BY public.customers.id;


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: shop
--

CREATE TABLE public.order_items (
    order_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity smallint DEFAULT 1 NOT NULL,
    unit_price numeric(10,2) NOT NULL
);


ALTER TABLE public.order_items OWNER TO shop;

--
-- Name: orders; Type: TABLE; Schema: public; Owner: shop
--

CREATE TABLE public.orders (
    id integer NOT NULL,
    customer_id integer NOT NULL,
    placed timestamp with time zone NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    note text,
    tags text[] DEFAULT '{}'::text[],
    meta jsonb,
    CONSTRAINT orders_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'paid'::text, 'shipped'::text, 'cancelled'::text])))
);


ALTER TABLE public.orders OWNER TO shop;

--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: shop
--

CREATE SEQUENCE public.orders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.orders_id_seq OWNER TO shop;

ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: shop
--

CREATE TABLE public.products (
    id integer NOT NULL,
    sku character(8) NOT NULL,
    name character varying(160) NOT NULL,
    category character varying(20) DEFAULT 'paper'::character varying NOT NULL,
    price numeric(10,2) NOT NULL,
    in_stock integer DEFAULT 0 NOT NULL,
    notes text,
    uid uuid DEFAULT public.uuid_generate_v4() NOT NULL
);


ALTER TABLE public.products OWNER TO shop;

COMMENT ON COLUMN public.products.sku IS 'three letters, a dash, four digits';

--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: shop
--

CREATE SEQUENCE public.products_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_id_seq OWNER TO shop;

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: settings; Type: TABLE; Schema: public; Owner: shop
--

CREATE TABLE public.settings (
    key character varying(64) NOT NULL,
    value text
);


ALTER TABLE public.settings OWNER TO shop;

--
-- Name: customers id; Type: DEFAULT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.customers ALTER COLUMN id SET DEFAULT nextval('public.customers_id_seq'::regclass);


--
-- Name: orders id; Type: DEFAULT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Data for Name: customers; Type: TABLE DATA; Schema: public; Owner: shop
--

COPY public.customers (id, name, city, email, joined, newsletter, updated_at) FROM stdin;
1	Aisyah Rahman	Kuala Lumpur	aisyah@example.com	2025-01-14	t	2025-01-14 09:12:00
2	陈美玲	北京	meiling@example.cn	2025-02-03	f	2025-02-03 11:40:21
3	Daniel O'Brien	Dublin	dobrien@example.ie	2025-02-19	t	2025-02-19 16:05:44
4	林志豪	台北	chihao@example.tw	2025-03-01	f	2025-03-01 08:00:00
5	Priya Nair	Penang	\N	2025-03-22	t	2025-03-22 13:27:09
6	Hans "Hansi" Müller	München	hans@example.de	2025-04-10	t	2025-04-10 10:10:10
7	Siti Nurhaliza	Johor Bahru	siti@example.my	2025-04-28	f	2025-04-28 17:45:00
8	Kenji Tanaka	Osaka	kenji@example.jp	2025-05-15	t	2025-05-15 07:30:12
9	王小明	上海	xiaoming@example.cn	2025-06-02	f	2025-06-02 12:00:00
10	Fatima Al-Sayed	Dubai	fatima@example.ae	2025-06-30	t	2025-06-30 19:20:05
11	Léa Dubois	Lyon	lea@example.fr	2025-07-18	t	2025-07-18 14:14:14
12	Muhammad Faiz	Kuching	faiz@example.my	2025-08-09	f	2025-08-09 09:09:09
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: shop
--

COPY public.products (id, sku, name, category, price, in_stock, notes, uid) FROM stdin;
1	LMP-0001	燈籠 paper lantern, red	lamp	18.50	42	Folds flat.\nShips in a tube.	7c9e6679-7425-40de-944b-e07fc1f90ae7
2	LMP-0002	Brass desk lamp	lamp	129.00	5	\N	5a8f3b1e-2d4c-4e7a-9b6d-1f2e3d4c5b6a
3	PPR-0001	A5 dot-grid notebook	paper	9.90	300	The customer's favourite.	0f1e2d3c-4b5a-4697-8877-665544332211
4	PPR-0002	Washi tape, 3 rolls	paper	7.20	118	Patterns: 桜, 波, 雲	11223344-5566-4777-8899-aabbccddeeff
5	PEN-0001	Fountain pen, fine nib	pen	64.00	17	Comes with a converter	a1b2c3d4-e5f6-4789-8abc-def012345678
6	PEN-0002	Gel pen set (12)	pen	14.40	260	\N	12345678-90ab-4cde-8f01-234567890abc
7	INK-0001	Iron-gall ink, 50 ml	ink	21.00	33	Say "blue-black" — it dries darker.	deadbeef-dead-4eef-8ead-beefdeadbeef
8	INK-0002	Ink cartridges (6)	ink	5.50	500	\N	cafebabe-cafe-4abe-8afe-babecafebabe
9	BAG-0001	Canvas tote	bag	24.00	80	C:\\shop\\art\\tote.svg	01234567-89ab-4cde-8f01-23456789abcd
10	BAG-0002	Pen roll, leather	bag	39.00	12	Holds 8 pens\ttab-separated note	fedcba98-7654-4321-8fed-cba987654321
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: shop
--

COPY public.orders (id, customer_id, placed, status, note, tags, meta) FROM stdin;
1	1	2025-03-02 10:15:00+08	shipped	\N	{gift}	{"courier": "poslaju"}
2	2	2025-03-05 14:02:11+08	shipped	请轻拿轻放	{fragile,gift}	\N
3	3	2025-03-09 09:30:00+00	paid	Leave with the neighbour if I'm out	{}	\N
4	4	2025-03-15 18:45:30+08	cancelled	改天再買	{}	{"reason": "changed mind"}
5	5	2025-04-01 08:00:00+08	shipped	\N	{}	\N
6	6	2025-04-12 12:12:12+02	shipped	Gift wrap, please	{gift}	\N
7	7	2025-05-03 16:20:00+08	paid	\N	{}	\N
8	8	2025-05-20 07:55:41+09	shipped	\N	{}	{"courier": "yamato"}
9	9	2025-06-06 11:11:11+08	pending	发票抬头：王小明	{invoice}	\N
10	10	2025-07-01 20:00:00+04	shipped	\N	{}	\N
11	11	2025-07-22 13:37:00+02	paid	Livraison le matin	{}	\N
12	1	2025-08-10 09:00:00+08	pending	Repeat order	{}	\N
13	12	2025-08-15 15:15:15+08	shipped	\N	{}	\N
14	2	2025-09-01 10:30:00+08	pending	\N	{}	\N
\.


--
-- Data for Name: order_items; Type: TABLE DATA; Schema: public; Owner: shop
--

COPY public.order_items (order_id, product_id, quantity, unit_price) FROM stdin;
1	3	2	9.90
1	6	1	14.40
2	1	4	18.50
3	5	1	64.00
3	7	2	21.00
4	2	1	129.00
5	4	3	7.20
6	10	1	39.00
6	5	1	64.00
7	8	6	5.50
8	9	2	24.00
9	1	10	18.50
10	3	5	9.90
11	7	1	21.00
12	3	2	9.90
13	6	3	14.40
14	4	1	7.20
\.


--
-- Data for Name: settings; Type: TABLE DATA; Schema: public; Owner: shop
--

COPY public.settings (key, value) FROM stdin;
currency	MYR
shop_name	燈籠 Stationery
free_shipping_over	150.00
\.


--
-- Name: customers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: shop
--

SELECT pg_catalog.setval('public.customers_id_seq', 12, true);


--
-- Name: orders_id_seq; Type: SEQUENCE SET; Schema: public; Owner: shop
--

SELECT pg_catalog.setval('public.orders_id_seq', 14, true);


--
-- Name: products_id_seq; Type: SEQUENCE SET; Schema: public; Owner: shop
--

SELECT pg_catalog.setval('public.products_id_seq', 10, true);


--
-- Name: customers customers_email_key; Type: CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_email_key UNIQUE (email);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (order_id, product_id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: products products_sku_key; Type: CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (key);


--
-- Name: idx_customers_city; Type: INDEX; Schema: public; Owner: shop
--

CREATE INDEX idx_customers_city ON public.customers USING btree (city);


--
-- Name: idx_orders_customer; Type: INDEX; Schema: public; Owner: shop
--

CREATE INDEX idx_orders_customer ON public.orders USING btree (customer_id);


--
-- Name: order_items order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: order_items order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: orders orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shop
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: shop
--

GRANT SELECT ON TABLE public.customers TO readonly;


--
-- PostgreSQL database dump complete
--
