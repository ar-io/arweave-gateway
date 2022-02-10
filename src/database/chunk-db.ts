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
import { Knex } from "knex";
import moment from "moment";
export interface DatabaseChunk {
  data_root: string;
  data_size: number;
  data_path: string;
  offset: number;
  chunk_size: number;
}

const chunkFields = [
  "data_root",
  "data_size",
  "data_path",
  "offset",
  "chunk_size",
];

export const saveChunk = async (connection: Knex, chunk: DatabaseChunk) => {
  await upsert(connection, {
    table: "chunks",
    conflictKeys: ["data_root", "data_size", "offset"],
    rows: [chunk],
  });
};

interface ChunkQuery {
  limit?: number;
  offset?: number;
  root?: string;
  select?: (keyof DatabaseChunk)[];
  order?: "asc" | "desc";
}

export const query = (
  connection: Knex,
  { select, order = "asc", root }: ChunkQuery
): Knex.QueryBuilder<any, Partial<DatabaseChunk>[]> => {
  const query = connection
    .queryBuilder()
    .select(select || "*")
    .from("chunks");

  query.orderBy("offset", order);

  return query;
};

export const getPendingExports = async (
  connection: Knex,
  { limit = 100 }: { limit: number }
): Promise<DatabaseChunk[]> => {
  // select * from chunks where data_root in
  // (select data_root from chunks group by data_root, data_size having sum(chunk_size) = data_size)
  // and exported_started_at is null order by created_at asc
  const query = connection
    .select(chunkFields)
    .from("chunks")
    .whereIn("data_root", (query) => {
      query
        .select("data_root")
        .from("chunks")
        .groupBy(["data_root", "data_size"])
        .havingRaw("sum(chunk_size) = data_size");
    })
    .whereNull("exported_started_at")
    .orderBy("created_at", "asc");

  if (limit) {
    query.limit(limit);
  }

  return query;
};

export const startedExport = async (
  connection: Knex,
  chunk: {
    data_root: string;
    data_size: number;
    offset: number;
  }
) => {
  const query = connection
    .update({
      exported_started_at: moment().format(),
    })
    .from("chunks")
    .where(chunk);

  await query;
};

export const completedExport = async (
  connection: Knex,
  chunk: {
    data_root: string;
    data_size: number;
    offset: number;
  }
) => {
  await connection
    .update({
      exported_completed_at: moment().format(),
    })
    .from("chunks")
    .where(chunk);
};

export const queryRecentChunks = async (
  connection: Knex,
  {
    root,
    size,
  }: {
    root: string;
    size: number;
  }
) => {
  return connection
    .select(["data_root", "data_size", "offset"])
    .from("chunks")
    .where({
      data_root: root,
      data_size: size,
    })
    .orderBy("offset", "asc");
};
