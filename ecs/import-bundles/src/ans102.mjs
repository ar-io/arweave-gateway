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

import {
  getTagValue,
  sha256B64Url,
  fromB64Url,
  txTagsToRows,
} from "./utils.mjs";
import { upsert } from "./postgres.mjs";
import { put } from "./bucket.mjs";
import processBundle from "arbundles/stream/index.js";
import base64url from "base64url";
import fs from "node:fs/promises";
import log from "./logger.mjs";

export const processAns102 = async ({
  tx,
  filePath,
  dbRead,
  dbWrite,
  parent,
}) => {
  const fileRaw = await fs.readFile(filePath);
  const fileJson = JSON.parse(fileRaw);

  // FOR LOGGING ONLY!!
  let index = 0;

  const bundleLength = fileJson.items.length;

  const txBatch = [];
  const tagsBatch = [];

  const alreadyPushed = new Set();

  const processBatches = async (connection) => {
    await connection.transaction(async (knexTransaction) => {
      await upsert(connection, {
        table: "transactions",
        conflictKeys: ["id"],
        rows: txBatch,
        transaction: knexTransaction,
      });

      // empty array
      while (txBatch.length > 0) {
        txBatch.pop();
      }

      await upsert(connection, {
        table: "tags",
        conflictKeys: ["tx_id", "index"],
        rows: tagsBatch,
        transaction: knexTransaction,
      });

      // empty array
      while (tagsBatch.length > 0) {
        tagsBatch.pop();
      }
    });
  };

  for (const dataItem of fileJson.items) {
    log.info(`[data-item] ans102 ${index + 1}/${bundleLength}`);
    index += 1;

    if (dataItem.id && !alreadyPushed.has(dataItem.id)) {
      alreadyPushed.add(dataItem.id);

      if (txBatch.length > 9) {
        await processBatches(dbWrite);
      }

      const contentType = getTagValue(dataItem.tags, "content-type");

      const dataBuffer = fromB64Url(dataItem.data);

      log.info(
        `[data-item] ans102 tx/${dataItem.id} ${
          contentType || "application/octet-stream"
        }`
      );

      await put(
        `tx/${dataItem.id}`,
        dataBuffer,
        contentType || "application/octet-stream"
      );

      const maybeHeight = await dbRead
        .select("height")
        .from("transactions")
        .where({ id: parent });

      const dataItemDb = {
        parent,
        format: 1,
        id: dataItem.id,
        signature: dataItem.signature,
        owner: dataItem.owner,
        owner_address: sha256B64Url(fromB64Url(dataItem.owner)),
        target: dataItem.target || "",
        reward: 0,
        last_tx: dataItem.nonce || dataItem.anchor || "",
        tags: JSON.stringify(dataItem.tags),
        quantity: 0,
        data_size: dataItem.dataSize ?? fromB64Url(dataItem.data).byteLength,
        ...(maybeHeight && maybeHeight.length > 0 ? maybeHeight[0] : undefined),
      };

      txBatch.push(dataItemDb);

      const dbTags = txTagsToRows(dataItem.id, dataItem.tags);

      dbTags.forEach((tag) => tagsBatch.push(tag));
    } else {
      log.info(`[data-item] ans102 duplicate data-item id: ${dataItem.id}`);
    }
  }

  await processBatches(dbWrite);
};
