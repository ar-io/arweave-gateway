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
import AWS from "aws-sdk";
import R from "ramda";
import https from "https";
import retry from "async-retry";
import { Consumer } from "sqs-consumer";
import exitHook from "exit-hook";
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

let exitSignaled = false;

exitHook(() => {
  exitSignaled = true;
});

const nodes = new Set();

let dbRead;
let dbWrite;

const messageHandler = async (message) => {
  console.log({ message });

  let txId = undefined;

  try {
    txId = JSON.parse(message.Body)["id"];
  } catch (error) {
    log.error(error);
  }

  if (!txId) {
    throw new Error("Couldn't retrieve txid from message");
  }
  let tx;

  try {
    tx = await dbRead.select().from("transactions").where({ id: txId }).first();
  } catch (error) {
    log.error(`querying for txID ${txId} from database failed`, error);
  }

  if (!tx) {
    try {
      tx = await got.get(`https://arweave.net:443/tx/${txId}`).json();
    } catch (error) {
      log.error(error);
    }
  }

  if (!tx) {
    throw new Error("Couldn't download tx header for: " + txId);
  }

  // do some work with `message`
  const txDataSize = parseInt(tx["data_size"]);

  const filePath = tmpFile();
  const pipeline = promisify(stream.pipeline);

  await pipeline(
    got.stream(`https://arweave.net:443/${tx.id}`),
    fs.createWriteStream(filePath)
  );

  if (isTxAns104(tx)) {
    await processAns104({
      tx,
      filePath,
      dbRead,
      dbWrite,
      parent: tx.id,
    });
  } else {
    await processAns102({
      tx,
      filePath,
      dbRead,
      dbWrite,
      parent: tx.id,
    });
  }

  await fsPromises.unlink(filePath);
};

const app = Consumer.create({
  queueUrl: process.env.ARWEAVE_SQS_IMPORT_BUNDLES_URL,
  pollingWaitTimeMs: 10000,
  batchSize: 1,
  handleMessage: messageHandler,
  sqs: new AWS.SQS({
    httpOptions: {
      agent: new https.Agent({
        keepAlive: true,
      }),
    },
  }),
});

app.on("error", (err) => {
  log.error("[SQS] ERROR " + err.message);
});

app.on("processing_error", (err) => {
  log.error("[SQS] PROCESSING ERROR" + err.message);
  process.exit(1);
});

(async () => {
  log.info("Starting import-bundles job..");

  log.info("opening new dbWrite connection");
  dbWrite = await createDbClient({
    user: "write",
  });
  log.info("opening new dbRead connection");
  dbRead = await createDbClient({
    user: "read",
  });
  log.info("start polling sqs messages...");
  app.start();
})();
