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

import fetch from "node-fetch";
import { RequestHandler } from "express";
import { getLatestBlock } from "../../../database/block-db";
import { getConnectionPool } from "../../../database/postgres";
import log from "../../../lib/log";

const origins = JSON.parse(process.env.ARWEAVE_NODES_GET || "") as string[];

if (!Array.isArray(origins)) {
  throw new Error(
    `error.config: Invalid env var, process.env.ARWEAVE_NODES_GET: ${process.env.ARWEAVE_NODES_GET}`
  );
}

export const handler: RequestHandler = async (req, res) => {
  const healthStatus = {
    region: process.env.AWS_REGION,
    origins: await originHealth(),
    database: await databaseHealth(),
  };
  res.send(healthStatus).end();
};

const originHealth = async () => {
  try {
    return await Promise.all(
      origins.map(async (originUrl) => {
        try {
          const response = await fetch(`${originUrl}/info`);
          return {
            endpoint: originUrl,
            status: response.status,
            info: await response.json(),
          };
        } catch (error) {
          console.error(error);
          return error;
        }
      })
    );
  } catch (error) {
    log.error(`[health-check] database error`, { error });
    return false;
  }
};

const databaseHealth = async () => {
  try {
    const pool = getConnectionPool("read");
    return { block: await getLatestBlock(pool) };
  } catch (error) {
    log.error(`[health-check] database error`, { error });
    return false;
  }
};
