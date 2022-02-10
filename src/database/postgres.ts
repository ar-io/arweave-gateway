import AWS from "aws-sdk";
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

import knex, { Knex } from "knex";
import log from "../lib/log";
import { wait } from "../lib/helpers";

export type ConnectionMode = "read" | "write";

export type DBConnection = Knex | Knex.Transaction;

let poolCache: {
  read: null | Knex;
  write: null | Knex;
} = {
  read: null,
  write: null,
};

export const initConnectionPool = (
  mode: ConnectionMode,
  config?: PoolConfig
) => {
  if (!poolCache[mode]) {
    log.info(`[postgres] creating connection: ${mode}`);
    poolCache[mode] = createConnectionPool(mode, config);
  }
};

export const getConnectionPool = (mode: ConnectionMode): Knex => {
  log.info(`[postgres] reusing connection: ${mode}`);
  return poolCache[mode]!;
};

export const releaseConnectionPool = async (
  mode?: ConnectionMode
): Promise<void> => {
  if (mode) {
    if (poolCache[mode]) {
      log.info(`[postgres] destroying connection: ${mode}`);
      await poolCache[mode]!.destroy();
      poolCache[mode] = null;
    }
  } else {
    await Promise.all([
      releaseConnectionPool("read"),
      releaseConnectionPool("write"),
    ]);
    await wait(200);
  }
};

interface PoolConfig {
  min: number;
  max: number;
}

export const createConnectionPool = (
  mode: ConnectionMode = "write",
  { min, max }: PoolConfig = { min: 1, max: 10 }
): Knex => {
  // newline
  const host = {
    read: process.env.ARWEAVE_DB_READ_HOST,
    write: process.env.ARWEAVE_DB_WRITE_HOST,
  }[mode];

  const password = {
    read: process.env.PSQL_READ_PASSWORD,
    write: process.env.PSQL_WRITE_PASSWORD,
  }[mode];

  const hostDisplayName = `${process.env.AWS_REGION} ${mode}@${host}:${5432}`;

  log.info(`[postgres] connecting to db: ${hostDisplayName}`);

  const client = knex({
    acquireConnectionTimeout: 120000,
    client: "pg",
    pool: {
      min,
      max,
      acquireTimeoutMillis: 120000,
      idleTimeoutMillis: 30000,
      reapIntervalMillis: 40000,
    },
    connection: {
      host,
      user: mode,
      database: "arweave",
      ssl: {
        rejectUnauthorized: false,
      },
      password,
      expirationChecker: () => true,
      connectTimeout: 90000,
    },
  });

  return client;
};

interface UpsertOptions<T = object[]> {
  table: string;
  conflictKeys: string[];
  rows: T;
  transaction?: Knex.Transaction;
}

/**
 * Generate a postgres upsert statement. This manually appends a raw section to the query.
 *
 * INSERT (col, col, col) VALUES (val, val, val) ON CONFLICT (id,index) SO UPDATE SET x = excluded.x...
 */
export const upsert = (
  connection: DBConnection,
  { table, conflictKeys, rows, transaction }: UpsertOptions
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

  return connection.raw(upsertSql, bindings);
};
