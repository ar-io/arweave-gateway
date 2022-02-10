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

import AWS from "aws-sdk";
import R from "ramda";
import { Consumer } from "sqs-consumer";
import verifyAndIndexStream from "arbundles/stream";
import { Bundle, DataItem } from "arbundles";
import exitHook from "exit-hook";
import got from "got";
import { createDbClient } from "./postgres.mjs";
import { shuffle } from "./utils.mjs";

let exitSignaled = false;

exitHook(() => {
  exitSignaled = true;
});

const nodes = new Set();

async function refreshNodes() {
  let jsonResponse;
  try {
    await retry(
      async () => {
        jsonResponse = await got("https://arweave.net/health").json();
      },
      {
        retries: 5,
      }
    );
  } catch (error) {
    console.error(error);
  }

  if (typeof jsonResponse === "object" && Array.isArray(jsonResponse.origins)) {
    for (const origin of jsonResponse.origins) {
      if (origin.status === 200) {
        nodes.add(origin.endpoint);
      } else {
        nodes.remove(origin.endpoint);
      }
    }
  }
}

const getSpecificTxHeader = async (id) => {
  let tx;
  for (const node of nodes.values()) {
    try {
      const response = await got(node + "/tx/" + id).json();

      if (typeof response === "object" && response.id === id) {
        tx = response;
      }
    } catch (error) {
      console.error(error);
    }
    if (tx) {
      return tx;
    }
  }
  return tx;
};

let dbRead;
let dbWrite;

const app = Consumer.create({
  queueUrl: process.env.ARWEAVE_SQS_IMPORT_BUNDLES_URL,
  handleMessage: async (message) => {
    console.log("MESSAGE", message);
    // do some work with `message`
    const tx = getSpecificTxHeader(message.tx_id);
    const txDataSize = parseInt(tx["data_size"]);

    const maybeStream = await getData(tx.id || "", { log });
  },
  sqs: new AWS.SQS({
    httpOptions: {
      agent: new https.Agent({
        keepAlive: true,
      }),
    },
  }),
});

app.on("error", (err) => {
  console.error("[SQS] ERROR", err.message);
});

app.on("processing_error", (err) => {
  console.error("[SQS] PROCESSING ERROR", err.message);
});

(async () => {
  console.log("Starting import-bundles job..");
  await refreshNodes();

  setInterval(async () => {
    try {
      await refreshNodes();
    } catch (error) {
      console.error("Failed to refresh nodes", error);
    }
  }, 1000 * 60 * 60);

  console.log("opening new dbWrite connection");
  dbWrite = await createDbClient({
    user: "write",
  });
  console.log("opening new dbRead connection");
  dbRead = await createDbClient({
    user: "read",
  });
  console.log("start polling sqs messages...");
  app.start();
})();
