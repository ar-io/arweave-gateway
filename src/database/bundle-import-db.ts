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
import { String } from "aws-sdk/clients/acm";

export interface DataBundleStatus {
  id: string;
  status: "pending" | "complete" | "error" | "invalid";
  attempts: number;
  error: string | null;
  bundle_meta?: string;
}

const table = "bundle_status";

const fields = ["id", "status", "attempts", "error"];

export const saveBundleStatus = async (
  connection: Knex,
  rows: Partial<DataBundleStatus>[]
) => {
  return upsert(connection, {
    table,
    conflictKeys: ["id"],
    rows,
  });
};

export const getBundleImport = async (
  connection: Knex,
  id: string
): Promise<Partial<DataBundleStatus>> => {
  const result = await connection
    .select<DataBundleStatus[]>(fields)
    .from("bundle_status")
    .where({ id })
    .first();

  if (result) {
    return {
      id: result.id,
      status: result.status,
      attempts: result.attempts,
      error: result.error,
    };
  }

  return {};
};
