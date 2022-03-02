 -- Arweave Gateway
 -- Copyright (C) 2022 Permanent Data Solutions, Inc

 -- This program is free software: you can redistribute it and/or modify
 -- it under the terms of the GNU General Public License as published by
 -- the Free Software Foundation, either version 3 of the License, or
 -- (at your option) any later version.

 -- This program is distributed in the hope that it will be useful,
 -- but WITHOUT ANY WARRANTY; without even the implied warranty of
 -- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 -- GNU General Public License for more details.

 -- You should have received a copy of the GNU General Public License
 -- along with this program.  If not, see <https://www.gnu.org/licenses/>.


--
-- Name: blocks; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.blocks (
    id character(64) NOT NULL,
    height integer NOT NULL,
    mined_at timestamp without time zone NOT NULL,
    mined_at_utc bigint NOT NULL,
    txs jsonb NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    extended jsonb,
    previous_block character varying NOT NULL
);


ALTER TABLE public.blocks OWNER TO root;

--
-- Name: blocks_tx_map; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.blocks_tx_map (
    tx_id character(43) NOT NULL,
    block_id character(64)
);


ALTER TABLE public.blocks_tx_map OWNER TO root;

--
-- Name: bundle_status; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.bundle_status (
    id character(43) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone,
    attempts smallint DEFAULT 0 NOT NULL,
    status character varying,
    error character varying,
    bundle_meta text
);


ALTER TABLE public.bundle_status OWNER TO root;

--
-- Name: chunks; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.chunks (
    data_root character varying NOT NULL,
    data_size bigint NOT NULL,
    "offset" bigint NOT NULL,
    data_path character varying NOT NULL,
    chunk_size integer NOT NULL,
    exported_started_at timestamp without time zone,
    exported_completed_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.chunks OWNER TO root;

--
-- Name: hash_list; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.hash_list (
    indep_hash character varying
);


ALTER TABLE public.hash_list OWNER TO root;

--
-- Name: tags; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.tags (
    tx_id character(43) NOT NULL,
    index integer NOT NULL,
    name character varying NOT NULL,
    value character varying NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.tags OWNER TO root;

--
-- Name: tags_grouped; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.tags_grouped (
    tx_id character(43) NOT NULL,
    tags jsonb
);


ALTER TABLE public.tags_grouped OWNER TO root;

--
-- Name: transactions; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.transactions (
    id character(43) NOT NULL,
    owner character varying,
    tags jsonb,
    target character(43),
    quantity character varying,
    reward character varying,
    signature character varying,
    last_tx character varying,
    data_size bigint,
    content_type character varying,
    format smallint,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    deleted_at timestamp without time zone,
    height integer,
    owner_address character(43),
    data_root character(43),
    parent character(43)
);


ALTER TABLE public.transactions OWNER TO root;

--
-- Name: blocks blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT blocks_pkey PRIMARY KEY (id);


--
-- Name: blocks_tx_map blocks_tx_map_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.blocks_tx_map
    ADD CONSTRAINT blocks_tx_map_pkey PRIMARY KEY (tx_id);


--
-- Name: bundle_status bundle_status_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.bundle_status
    ADD CONSTRAINT bundle_status_pkey PRIMARY KEY (id);


--
-- Name: chunks chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT chunks_pkey PRIMARY KEY (data_root, data_size, "offset");


--
-- Name: tags_grouped tags_grouped_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.tags_grouped
    ADD CONSTRAINT tags_grouped_pkey PRIMARY KEY (tx_id);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (tx_id, index);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);


--
-- Name: blocks_created_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX blocks_created_at ON public.blocks USING btree (created_at);


--
-- Name: blocks_height; Type: INDEX; Schema: public; Owner: root
--

CREATE UNIQUE INDEX blocks_height ON public.blocks USING btree (height);


--
-- Name: blocks_height_sorted; Type: INDEX; Schema: public; Owner: root
--

CREATE UNIQUE INDEX blocks_height_sorted ON public.blocks USING btree (height DESC);


--
-- Name: blocks_id_hash; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX blocks_id_hash ON public.blocks USING hash (id);


--
-- Name: blocks_tx_block_id_hash; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX blocks_tx_block_id_hash ON public.blocks_tx_map USING hash (block_id);


--
-- Name: chunks_created_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX chunks_created_at ON public.chunks USING btree (created_at);


--
-- Name: chunks_data_root; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX chunks_data_root ON public.chunks USING hash (data_root);


--
-- Name: chunks_data_root_data_size; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX chunks_data_root_data_size ON public.chunks USING btree (data_root, data_size);


--
-- Name: chunks_exported_completed_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX chunks_exported_completed_at ON public.chunks USING btree (exported_completed_at);


--
-- Name: chunks_exported_started_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX chunks_exported_started_at ON public.chunks USING btree (exported_started_at);


--
-- Name: index_created_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX index_created_at ON public.bundle_status USING btree (created_at);


--
-- Name: index_updated_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX index_updated_at ON public.bundle_status USING btree (updated_at);


--
-- Name: tags_name; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX tags_name ON public.tags USING hash (name);


--
-- Name: tags_name_txid; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX tags_name_txid ON public.tags USING btree (name, tx_id);


--
-- Name: tags_name_value; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX tags_name_value ON public.tags USING btree (name, value);

--
-- NEW index
--

CREATE INDEX tags_name_value_txid ON public.tags USING btree (name, value, tx_id);

--
-- Name: tags_tx_id; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX tags_tx_id ON public.tags USING hash (tx_id);


--
-- Name: tags_value; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX tags_value ON public.tags USING hash (value);


--
-- Name: transactions_created_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_created_at ON public.transactions USING btree (created_at DESC);


--
-- Name: transactions_height; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_height ON public.transactions USING btree (height);


--
-- Name: transactions_height_id_sorted; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_height_id_sorted ON public.transactions USING btree (height DESC, id);


--
-- Name: transactions_height_sorted; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_height_sorted ON public.transactions USING btree (height DESC);


--
-- Name: transactions_owner_address_hash; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_owner_address_hash ON public.transactions USING hash (owner_address);


--
-- Name: transactions_owner_hash; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_owner_hash ON public.transactions USING hash (id);


--
-- Name: transactions_parent; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_parent ON public.transactions USING hash (parent);


--
-- Name: transactions_target; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX transactions_target ON public.transactions USING hash (target);


--
-- Name: tx_id_hash; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX tx_id_hash ON public.blocks_tx_map USING hash (tx_id);

--
-- Name: tags tags_tx_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_tx_id_fkey FOREIGN KEY (tx_id) REFERENCES public.transactions(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: transactions transactions_height_fkey; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_height_fkey FOREIGN KEY (height) REFERENCES public.blocks(height) ON UPDATE SET NULL ON DELETE SET NULL DEFERRABLE;


--
-- Name: blocks_tx_map transactions_map_block_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.blocks_tx_map
    ADD CONSTRAINT transactions_map_block_id_fkey FOREIGN KEY (block_id) REFERENCES public.blocks(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: transactions transactions_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_parent_fkey FOREIGN KEY (parent) REFERENCES public.transactions(id);


--
-- Name: transactions transactions_parent_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_parent_fkey1 FOREIGN KEY (parent) REFERENCES public.transactions(id);
