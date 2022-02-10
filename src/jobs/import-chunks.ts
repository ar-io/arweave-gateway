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

import { getQueueUrl, createQueueHandler } from "../lib/queues";
import { ImportChunk } from "../interfaces/messages";
import { saveChunk } from "../database/chunk-db";
import {
  getConnectionPool,
  initConnectionPool,
  releaseConnectionPool,
} from "../database/postgres";
import log from "../lib/log";
import { wait } from "../lib/helpers";

export const handler = createQueueHandler<ImportChunk>(
  getQueueUrl("import-chunks"),
  async ({ header, size }) => {
    const pool = getConnectionPool("write");
    log.info(`[import-chunks] importing chunk`, {
      root: header.data_root,
      size: size,
    });
    await saveChunk(pool, {
      ...header,
      chunk_size: size,
    });
  },
  {
    before: async () => {
      log.info(`[import-chunks] handler:before database connection init`);
      initConnectionPool("write");
      await wait(500);
    },
    after: async () => {
      log.info(`[import-chunks] handler:after database connection cleanup`);
      await releaseConnectionPool("write");
      await wait(500);
    },
  }
);

export default handler;
