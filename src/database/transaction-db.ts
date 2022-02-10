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

import { upsert } from "./postgres";
import log from "../lib/log";
import { Knex } from "knex";
import {
  TransactionHeader,
  getTagValue,
  Tag,
  utf8DecodeTag,
  DataBundleItem,
} from "../lib/arweave";
import {
  fromB64Url,
  sha256B64Url,
  ISO8601DateTimeString,
} from "../lib/encoding";
import { pick, uniqBy } from "lodash";
import moment from "moment";
import { TagFilter } from "../gateway/routes/graphql-v2/schema/types";
import { sequentialBatch } from "../lib/helpers";
import { DataItem } from "arbundles";

interface DatabaseTag {
  tx_id: string;
  index: number;
  name: string | undefined;
  value: string | undefined;
  // value_numeric: string | undefined;
}

const txFields = [
  "format",
  "id",
  "signature",
  "owner",
  "owner_address",
  "target",
  "reward",
  "last_tx",
  "tags",
  "quantity",
  "quantity",
  "content_type",
  "data_size",
  "data_root",
];

export const getTxIds = async (
  connection: Knex,
  predicates: object
): Promise<string[]> => {
  return await connection.pluck("id").from("transactions").where(predicates);
};

export const getTx = async (
  connection: Knex,
  predicates: object
): Promise<any | undefined> => {
  return connection.select().from("transactions").where(predicates).first();
};

type TxSortOrder = "HEIGHT_ASC" | "HEIGHT_DESC";

const orderByClauses: { [key in TxSortOrder]: string } = {
  HEIGHT_ASC: "transactions.height ASC NULLS LAST, id ASC",
  HEIGHT_DESC: "transactions.height DESC NULLS FIRST, id ASC",
};

interface TxQuery {
  to?: string[];
  from?: string[];
  id?: string;
  ids?: string[];
  tags?: TagFilter[];
  parents?: string[];
  limit?: number;
  offset?: number;
  select?: any;
  blocks?: boolean;
  before?: ISO8601DateTimeString;
  sortOrder?: TxSortOrder;
  status?: "any" | "confirmed" | "pending";
  pendingMinutes?: number;
  minHeight?: number;
  maxHeight?: number;
}

export const query = <T = any[]>(
  connection: Knex,
  {
    to,
    from,
    tags,
    parents,
    limit = 100000,
    offset = 0,
    id,
    ids,
    status,
    select,
    before,
    blocks = false,
    sortOrder = "HEIGHT_DESC",
    pendingMinutes = 60,
    minHeight = -1,
    maxHeight = -1,
  }: TxQuery
): Knex.QueryBuilder<T, T> => {
  const query = connection
    .queryBuilder<T, T>()
    .select<T, T>(
      select || {
        id: "transactions.id",
        height: "transactions.height",
        tags: "transactions.tags",
      }
    )
    .from<T, T>("transactions");

  if (blocks) {
    query.leftJoin("blocks", "transactions.height", "blocks.height");
  }

  if (pendingMinutes >= 0) {
    query.where((query) => {
      // Include recent pending transactions up to pendingMinutes old.
      // After this threshold they will be considered orphaned so not included in results.
      query.whereNotNull("transactions.height");

      query.orWhere(
        "transactions.created_at",
        ">",
        moment().subtract(pendingMinutes, "minutes").toISOString()
      );
    });
  }

  if (status == "confirmed") {
    query.whereNotNull("transactions.height");
  }

  if (before) {
    query.where("transactions.created_at", "<", before);
  }

  if (id) {
    query.where("transactions.id", id);
  }

  if (ids) {
    query.whereIn("transactions.id", ids);
  }

  if (parents) {
    query.whereIn("transactions.parent", parents);
  }

  if (to) {
    query.whereIn("transactions.target", to);
  }

  if (from) {
    query.whereIn("transactions.owner_address", from);
  }

  if (tags) {
    tags.forEach((tag, index) => {
      const tagAlias = `${index}_${index}`;

      query.join(`tags as ${tagAlias}`, (join) => {
        join.on("transactions.id", `${tagAlias}.tx_id`);

        join.andOnIn(`${tagAlias}.name`, [tag.name]);

        if (tag.op == "EQ") {
          join.andOnIn(`${tagAlias}.value`, tag.values);
        }

        if (tag.op == "NEQ") {
          join.andOnNotIn(`${tagAlias}.value`, tag.values);
        }
      });
    });
  }

  if (minHeight >= 0) {
    query.where("transactions.height", ">=", minHeight);
  }

  if (maxHeight >= 0) {
    query.where("transactions.height", "<=", maxHeight);
  }

  query.limit(limit).offset(offset);

  if (Object.keys(orderByClauses).includes(sortOrder)) {
    query.orderByRaw(orderByClauses[sortOrder]);
  }

  log.info("[grqphql/v2/104] RAW", { queryRaw: query.toString() });
  return query;
};

export const hasTx = async (connection: Knex, id: string): Promise<boolean> => {
  const result = await connection
    .first("id")
    .from("transactions")
    .where({ id })
    .whereNotNull("owner");

  return !!(result && result.id);
};

export const hasTxs = async (
  connection: Knex,
  ids: string[]
): Promise<string[]> => {
  return await connection.pluck("id").from("transactions").whereIn("id", ids);
};

export const saveTx = async (connection: Knex, tx: TransactionHeader) => {
  return await connection.transaction(async (knexTransaction) => {
    await upsert(knexTransaction, {
      table: "transactions",
      conflictKeys: ["id"],
      rows: [
        txToRow({
          tx,
        }),
      ],
    });

    if (tx.tags.length > 0) {
      await upsert(knexTransaction, {
        table: "tags",
        conflictKeys: ["tx_id", "index"],
        rows: txTagsToRows(tx.id, tx.tags),
      });
    }
  });
};

export const saveBundleDataItem = async (
  connection: Knex,
  tx: DataBundleItem,
  { parent }: { parent: string }
) => {
  const maybeHeight = await connection
    .select("height")
    .from("transactions")
    .where({ id: parent });

  return await connection.transaction(async (knexTransaction: any) => {
    await upsert(knexTransaction, {
      table: "transactions",
      conflictKeys: ["id"],
      rows: [
        {
          parent,
          format: 1,
          id: tx.id,
          signature: tx.signature,
          owner: tx.owner,
          owner_address: sha256B64Url(fromB64Url(tx.owner)),
          target: tx.target,
          reward: 0,
          last_tx: tx.nonce,
          tags: JSON.stringify(tx.tags),
          quantity: 0,
          data_size: tx.dataSize || fromB64Url((tx as any).data).byteLength,
          ...(maybeHeight && maybeHeight.length > 0
            ? maybeHeight[0]
            : undefined),
        },
      ],
    });

    if (tx.tags.length > 0) {
      await upsert(knexTransaction, {
        table: "tags",
        conflictKeys: ["tx_id", "index"],
        rows: txTagsToRows(tx.id, tx.tags),
      });
    }
  });
};

export const saveBundleDataItems = async (
  connection: Knex,
  bundleId: string,
  items: DataBundleItem[]
) => {
  const maybeHeight = await connection
    .select("height")
    .from("transactions")
    .where({ id: bundleId });

  return await connection.transaction(async (knexTransaction: any) => {
    log.info(`[import-bundles] importing tx bundle items to gql db`, {
      bundle: bundleId,
      batchSize: items.length,
    });

    const tags: DatabaseTag[] = [];

    const rows = uniqBy(items, "id").map((item) => {
      console.error({ item });
      if (item.tags.length > 0) {
        tags.push(...txTagsToRows(item.id, item.tags));
      }

      log.info(`[import-bundles] importing tx bundle item to gql db`, {
        parent: bundleId,
        format: 1,
        id: item.id,
        signature: item.signature,
        owner: item.owner,
        owner_address: sha256B64Url(fromB64Url(item.owner)),
        target: item.target || "",
        reward: 0,
        // @ts-ignore
        last_tx: item.nonce || item.anchor || "",
        tags: JSON.stringify(item.tags || []),
        quantity: 0,
        data_size: item.dataSize ?? fromB64Url((item as any).data).byteLength,
        ...(maybeHeight && maybeHeight.length > 0 ? maybeHeight[0] : undefined),
      });

      return {
        parent: bundleId,
        format: 1,
        id: item.id,
        signature: item.signature,
        owner: item.owner,
        owner_address: sha256B64Url(fromB64Url(item.owner)),
        target: item.target || "",
        reward: 0,
        // @ts-ignore
        last_tx: item.nonce || item.anchor || "",
        tags: JSON.stringify(item.tags || []),
        quantity: 0,
        data_size: item.dataSize ?? fromB64Url((item as any).data).byteLength,
        ...(maybeHeight && maybeHeight.length > 0 ? maybeHeight[0] : undefined),
      };
    });

    await upsert(knexTransaction, {
      table: "transactions",
      conflictKeys: ["id"],
      rows: rows,
    });

    if (tags.length > 0) {
      await sequentialBatch(tags, 500, async (items: DatabaseTag[]) => {
        log.info(`[import-bundles] importing tx bundle tags to gql db`, {
          bundle: bundleId,
          batchSize: items.length,
        });

        log.info(
          `[import-bundles] importing tx bundle item tags to gql db`,
          tags
        );

        await upsert(knexTransaction, {
          table: "tags",
          conflictKeys: ["tx_id", "index"],
          rows: tags,
        });
      });
    }
  });
};

const txToRow = ({ tx }: { tx: TransactionHeader | DataBundleItem }) => {
  return pick(
    {
      ...tx,
      content_type: getTagValue(tx.tags, "content-type"),
      format: (tx as any).format || 0,
      data_size:
        (tx as any).data_size ||
        ((tx as any).data
          ? fromB64Url((tx as any).data).byteLength
          : undefined),
      tags: JSON.stringify(tx.tags),
      owner_address: sha256B64Url(fromB64Url(tx.owner)),
    },
    txFields
  );
};

const txTagsToRows = (tx_id: string, tags: Tag[]): DatabaseTag[] => {
  return (
    tags
      .map((tag, index) => {
        const { name, value } = utf8DecodeTag(tag);

        return {
          tx_id,
          index,
          name,
          value,
        };
      })
      // The name and values columns are indexed, so ignore any values that are too large.
      // Postgres will throw an error otherwise: index row size 5088 exceeds maximum 2712 for index "tags_name_value"
      .filter(
        ({ name, value }) => (name?.length || 0) + (value?.length || 0) < 2712
      )
  );
};
