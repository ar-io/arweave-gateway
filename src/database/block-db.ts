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

import * as R from "ramda";
import { Knex } from "knex";
import { ImportTx } from "../interfaces/messages";
import { Block } from "../lib/arweave";
import { upsert, DBConnection } from "./postgres";
import moment from "moment";
import { pick, transform } from "lodash";
import { sequentialBatch } from "../lib/helpers";
import log from "../lib/log";
import { ISO8601DateTimeString } from "../lib/encoding";
import { enqueueBatch, getQueueUrl } from "../lib/queues";

export interface DatabaseBlock {
  id: string;
  previous_block: string;
  mined_at: string;
  height: number;
  txs: string[];
  extended: object;
}

export interface DatabaseBlockTxMap {
  block_id: string;
  tx_id: string;
}

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

export const getLatestBlock = async (
  connection: Knex
): Promise<DatabaseBlock> => {
  const block = await connection
    .select<DatabaseBlock>(blockFields)
    .from("blocks")
    .orderBy("height", "desc")
    .first();

  if (block) {
    return block;
  }

  throw new Error("Failed to get latest block from the block database");
};

export const getBlock = async (
  connection: Knex,
  predicate: { height: number } | { id: string }
): Promise<DatabaseBlock | undefined> => {
  return connection.select(blockFields).from("blocks").where(predicate).first();
};

export const getRecentBlocks = async (
  connection: Knex
): Promise<DatabaseBlock[]> => {
  return connection
    .select<DatabaseBlock[]>(blockFields)
    .from("blocks")
    .orderBy("height", "desc")
    .limit(400);
};

type ITxMapping = { txs: TxBlockHeight[]; block: DatabaseBlock };

const enqueueTxImports = async (queueUrl: string, txIds: string[]) => {
  await sequentialBatch(txIds, 10, async (ids: string[]) => {
    log.info(`[import-blocks] queuing block txs`, {
      ids,
    });
    await enqueueBatch<ImportTx>(
      queueUrl,
      ids.map((id) => {
        return {
          id: id,
          message: {
            id,
          },
        };
      })
    );
  });
};

export const saveBlocks = async (
  connection: DBConnection,
  blocks: DatabaseBlock[]
) => {
  const txImportQueueUrl = await getQueueUrl("import-txs");
  const blockTxMappings: ITxMapping[] = blocks.reduce((map, block) => {
    return map.concat({
      block,
      txs: block.txs.map((tx_id: string) => {
        return { height: block.height, id: tx_id };
      }),
    });
  }, [] as ITxMapping[]);

  for (const map of R.reverse(blockTxMappings)) {
    const { block, txs } = map;
    await connection.transaction(async (knexTransaction) => {
      log.info(`[block-db] saving block`, {
        height: block.height,
        id: block.id,
      });

      await upsert(knexTransaction, {
        table: "blocks",
        conflictKeys: ["height"],
        rows: [serialize(block)],
        transaction: knexTransaction,
      });

      await sequentialBatch(txs, 10, async (batch: TxBlockHeight[]) => {
        log.info(`[block-db] setting tx block heights`, {
          txs: batch.map((item) => {
            return { id: item.id, height: item.height };
          }),
        });

        await upsert(knexTransaction, {
          table: "transactions",
          conflictKeys: ["id"],
          rows: batch,
          transaction: knexTransaction,
        });
      });
    });
    // log.info(`[block-db] setting bundle data item heights`);

    // for (const items_ of R.splitEvery(10, txs)) {
    //   await Promise.all(
    //     items_.map((item: TxBlockHeight) =>
    //       connection.raw(
    //         `UPDATE transactions SET height = ? WHERE parent = ? AND height IS NULL`,
    //         [item.height, item.id]
    //       )
    //     )
    //   );
    // }

    log.info(`[block-db] enqueue-ing tx-imports`);

    // requeue *all* transactions involved in blocks that have forked.
    // Some of them may have been imported already and purged, so we
    // reimport everything to make sure there are no gaps.
    await enqueueTxImports(txImportQueueUrl, block.txs);
  }
};

interface TxBlockHeight {
  id: string;
  height: number;
}

export const fullBlocksToDbBlocks = (blocks: Block[]): DatabaseBlock[] => {
  return blocks.map(fullBlockToDbBlock);
};
/**
 * Format a full block into a stripped down version for storage in the postgres DB.
 */
export const fullBlockToDbBlock = (block: Block): DatabaseBlock => {
  return {
    id: block.indep_hash,
    height: block.height,
    previous_block: block.previous_block,
    txs: block.txs,
    mined_at: moment(block.timestamp * 1000).format(),
    extended: pick(block, extendedFields),
  };
};

// The pg driver and knex don't know the destination column types,
// and they don't correctly serialize json fields, so this needs
// to be done manually.
const serialize = (row: DatabaseBlock): object => {
  return transform(row, (result: any, value: any, key: string) => {
    result[key] =
      value && typeof value == "object" ? JSON.stringify(value) : value;
  });
};

type BlockSortOrder = "HEIGHT_ASC" | "HEIGHT_DESC";

const orderByClauses: { [key in BlockSortOrder]: string } = {
  HEIGHT_ASC: "blocks.height ASC NULLS LAST, id ASC",
  HEIGHT_DESC: "blocks.height DESC NULLS FIRST, id ASC",
};
interface BlockQuery {
  id?: string;
  ids?: string[];
  limit?: number;
  offset?: number;
  select?: any;
  before?: ISO8601DateTimeString;
  sortOrder?: BlockSortOrder;
  minHeight?: number;
  maxHeight?: number;
}

export const queryBlocks = (
  connection: Knex,
  {
    limit = 100000,
    select,
    offset = 0,
    before,
    id,
    ids,
    sortOrder = "HEIGHT_DESC",
    minHeight = -1,
    maxHeight = -1,
  }: BlockQuery
): Knex.QueryInterface => {
  const query = connection.queryBuilder().select(select).from("blocks");

  if (id) {
    query.where("blocks.id", id);
  }

  if (ids) {
    query.whereIn("blocks.id", ids);
  }

  if (before) {
    query.where("blocks.created_at", "<", before);
  }

  if (minHeight >= 0) {
    query.where("blocks.height", ">=", minHeight);
  }

  if (maxHeight >= 0) {
    query.where("blocks.height", "<=", maxHeight);
  }

  query.limit(limit).offset(offset);

  if (Object.keys(orderByClauses).includes(sortOrder)) {
    query.orderByRaw(orderByClauses[sortOrder]);
  }

  return query;
};
