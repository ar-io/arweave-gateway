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

import R from "ramda";
import pLimit from "p-limit";
import moment from "moment";
import { enqueue } from "./sqs.mjs";

// The pg driver and knex don't know the destination column types,
// and they don't correctly serialize json fields, so this needs
// to be done manually.
const serialize = (row) => {
  return R.reduce((result, key) => {
    const value = row[key];
    result[key] =
      value && typeof value == "object" ? JSON.stringify(value) : value;
    return result;
  }, {})(Object.keys(row));
};

const upsert = async (
  connection,
  { table, conflictKeys, rows, transaction }
) => {
  const updateFields = Object.keys(rows[0])
    .filter((field) => !conflictKeys.includes(field))
    .map((field) => `${field} = excluded.${field}`)
    .join(",");

  const query = connection.insert(rows).into(table);

  if (transaction) {
    query.transacting(transaction);
  }

  const { sql, bindings } = query.toSQL();

  const upsertSql = sql.concat(
    ` ON CONFLICT (${conflictKeys
      .map((key) => `"${key}"`)
      .join(",")}) DO UPDATE SET ${updateFields};`
  );

  return await connection.raw(upsertSql, bindings);
};

const txImportQueueUrl = process.env.ARWEAVE_SQS_IMPORT_TXS_URL;

const enqueueTxImports = async (queueUrl, txIds) => {
  const parallelize = pLimit(10);
  console.log(`[import-blocks] queuing block txs`);
  await Promise.all(
    txIds.map((txid) => {
      return parallelize(() => {
        return enqueue(queueUrl, { id: txid, message: { id: txid } });
      });
    })
  );
};

export const saveBlocks = async (connection, blocks) => {
  const blockTxMappings = blocks.reduce((map, block) => {
    return map.concat({
      block,
      txs: block.txs.map((tx_id) => {
        return { height: block.height, id: tx_id };
      }),
    });
  }, []);

  console.log(`[block-db] inserting block headers into blocks table`);

  for (const map of R.reverse(blockTxMappings)) {
    const { block, txs } = map;
    await connection.transaction(async (knexTransaction) => {
      console.log(`[block-db] saving block`, {
        height: block.height,
        id: block.id,
      });

      await upsert(knexTransaction, {
        table: "blocks",
        conflictKeys: ["height"],
        rows: [serialize(block)],
        transaction: knexTransaction,
      });

      const parallelize = pLimit(10);
      console.log(`[block-db] setting tx block heights`);
      await Promise.all(
        txs.map((item) => {
          return parallelize(() => {
            return upsert(knexTransaction, {
              table: "transactions",
              conflictKeys: ["id"],
              rows: [item],
              transaction: knexTransaction,
            });
          });
        })
      );
    });

    console.log(`[block-db] enqueue-ing tx-imports`);

    // requeue *all* transactions involved in blocks that have forked.
    // Some of them may have been imported already and purged, so we
    // reimport everything to make sure there are no gaps.
    await enqueueTxImports(txImportQueueUrl, block.txs);
  }
};

const blockFields = [
  "id",
  "height",
  "mined_at",
  "previous_block",
  "txs",
  "extended",
];

const extendedFields = [
  "diff",
  "hash",
  "reward_addr",
  "last_retarget",
  "tx_root",
  "tx_tree",
  "reward_pool",
  "weave_size",
  "block_size",
  "cumulative_diff",
  "hash_list_merkle",
  "tags",
];

export const getHighestBlock = async (connection) => {
  const block = await connection
    .select(blockFields)
    .from("blocks")
    .orderBy("height", "desc")
    .first();

  if (block) {
    return block;
  } else {
    console.error(
      "Failed to get latest block from the block database, assuming 0"
    );
    return {
      id: "7wIU7KolICAjClMlcZ38LZzshhI7xGkm2tDCJR7Wvhe3ESUo2-Z4-y0x1uaglRJE",
      height: 0,
    };
  }
};

export const getRecentBlocks = async (connection) => {
  return connection
    .select(blockFields)
    .from("blocks")
    .orderBy("height", "desc")
    .limit(400);
};

/**
 * Format a full block into a stripped down version for storage in the postgres DB.
 */
export const fullBlockToDbBlock = (block) => {
  return {
    id: block.indep_hash,
    height: block.height,
    previous_block: block.previous_block,
    txs: block.txs,
    mined_at: moment(block.timestamp * 1000).format(),
    extended: R.pick(extendedFields)(block),
  };
};
