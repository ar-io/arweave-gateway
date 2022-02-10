/**
 * Arweave Gateway
 * Copyright (C) 2022 Permanent Data Solutions, Inc
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import { Knex } from "knex";
import {
  getConnectionPool,
  initConnectionPool,
  releaseConnectionPool,
} from "../database/postgres";
import { getTx, saveTx } from "../database/transaction-db";
import { ImportTx, ImportBundle } from "../interfaces/messages";
import {
  fetchTransactionHeader,
  getTagValue,
  TransactionHeader,
} from "../lib/arweave";
import { isTxAns102, isTxAns104, wait } from "../lib/helpers";
import log from "../lib/log";
import { createQueueHandler, getQueueUrl, enqueue } from "../lib/queues";
import { MIN_BINARY_SIZE } from "arbundles";

export const handler = createQueueHandler<ImportTx>(
  getQueueUrl("import-txs"),
  async ({ id, tx }) => {
    const pool = getConnectionPool("write");

    const header = tx || (await fetchTransactionHeader(id || ""));

    if (tx) {
      log.info(`[import-txs] importing tx header`, { id });
      await save(pool, tx);
    }

    if (id) {
      await save(pool, await fetchTransactionHeader(id));
    }

    await handleBundle(pool, header);
  },
  {
    before: async () => {
      log.info(`[import-txs] handler:before database connection init`);
      initConnectionPool("write");
    },
    after: async () => {
      log.info(`[import-txs] handler:after database connection cleanup`);
      await releaseConnectionPool("write");
      await wait(500);
    },
  }
);

const save = async (connection: Knex<any>, tx: TransactionHeader) => {
  log.info(`[import-txs] saving tx header`, { id: tx.id });

  await saveTx(connection, tx);

  log.info(`[import-txs] successfully saved tx header`, { id: tx.id });
};

const handleBundle = async (connection: Knex<any>, tx: TransactionHeader) => {
  const dataSize = parseInt(tx?.data_size || "0");
  if (
    (dataSize > 0 && isTxAns102(tx)) ||
    (dataSize > MIN_BINARY_SIZE && isTxAns104(tx))
  ) {
    log.info(`[import-txs] detected data bundle tx`, { id: tx.id });

    // A single bundle import will trigger the importing of all the contained txs,
    // This  process will queue all the txs and a consumer will keep polling until the
    // bundle data is available and mined.
    //
    // Ideally we don't want to overdo this as it's quite spammy.
    //
    // For now, we'll only import bundled txs if it's the first time we've seen it,
    // or if it's been seen before but failed to import for whatever reason.
    //
    // When we get tx sync download webhoooks this can be improved.
    log.info(`[import-txs] queuing bundle for import`, { id: tx.id });

    await enqueue<any>(getQueueUrl("import-bundles"), { id: tx.id });

    log.info(`[import-txs] successfully queued bundle for import`, {
      id: tx.id,
    });
  }
};
