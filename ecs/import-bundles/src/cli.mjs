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

import "dotenv/config";
import R from "ramda";
import https from "https";
import { promisify } from "node:util";
import stream from "node:stream";
import fs from "node:fs";
import fsPromises from "node:fs/promises";
import got from "got";
import { createDbClient } from "./postgres.mjs";
import { shuffle, tmpFile } from "./utils.mjs";
import { processAns102 } from "./ans102.mjs";
import { isTxAns104, processAns104 } from "./ans104.mjs";
import log from "./logger.mjs";

const txId = process.argv.slice(2)[0];

(async () => {
  if (typeof txId !== "string" || txId.length !== 43) {
    log.error(`Invalid txid passed in as cli argument ${txId}`);
    process.exit(1);
  }

  log.info("Starting import-bundles job..");

  log.info("opening new dbWrite connection");
  const dbWrite = await createDbClient({
    user: "write",
  });
  log.info("opening new dbRead connection");
  const dbRead = await createDbClient({
    user: "read",
  });

  let tx = "";

  try {
    tx = await got(`https://arweave.net:443/tx/${txId}`).json();
  } catch (error) {
    log.error(error);
    process.exit(1);
  }

  // do some work with `message`
  const txDataSize = parseInt(tx["data_size"]);

  const filePath = tmpFile();
  const pipeline = promisify(stream.pipeline);

  await pipeline(
    got.stream(`https://arweave.net:443/${txId}`),
    fs.createWriteStream(filePath)
  );

  if (isTxAns104(tx)) {
    await processAns104({
      tx,
      filePath,
      dbRead,
      dbWrite,
      parent: txId,
    });
  } else {
    await processAns102({
      tx,
      filePath,
      dbRead,
      dbWrite,
      parent: txId,
    });
  }

  await fsPromises.unlink(filePath);
})();
