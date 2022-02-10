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
import { get } from "../lib/buckets";
import { broadcastChunk } from "../lib/broadcast";
import { ExportChunk } from "../interfaces/messages";
import { toB64url } from "../lib/encoding";
import { completedExport } from "../database/chunk-db";
import {
  getConnectionPool,
  releaseConnectionPool,
  initConnectionPool,
} from "../database/postgres";
import { wait } from "../lib/helpers";
import log from "../lib/log";

export const handler = createQueueHandler<ExportChunk>(
  getQueueUrl("export-chunks"),
  async (message) => {
    const { header } = message;

    log.info(`[export-chunks] exporting chunk`, {
      data_root: header.data_root,
      offset: header.offset,
    });

    const fullChunk = {
      ...header,
      chunk: toB64url(
        (await get("tx-data", `chunks/${header.data_root}/${header.offset}`))
          .Body as Buffer
      ),
    };

    await broadcastChunk(fullChunk);

    const pool = getConnectionPool("write");

    await completedExport(pool, {
      data_size: header.data_size,
      data_root: header.data_root,
      offset: header.offset,
    });
  },
  {
    before: async () => {
      log.info(`[export-chunks] handler:before database connection init`);
      initConnectionPool("write");
      await wait(100);
    },
    after: async () => {
      log.info(`[export-chunks] handler:after database connection cleanup`);
      await releaseConnectionPool("write");
      await wait(100);
    },
  }
);

export default handler;
