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

import { put } from "../../../lib/buckets";
import { fromB64Url } from "../../../lib/encoding";
import { Transaction, getTagValue } from "../../../lib/arweave";
import { enqueue, getQueueUrl } from "../../../lib/queues";
import { pick } from "lodash";
import {
  ImportTx,
  DispatchTx,
  DataFormatVersion,
} from "../../../interfaces/messages";
import { RequestHandler } from "express";
import { BadRequest } from "http-errors";
import { attemptFallbackNodes } from "../../../lib/broadcast";

import Joi, { Schema } from "@hapi/joi";
import { parseInput } from "../../middleware/validate-body";

export const txSchema: Schema = Joi.object({
  id: Joi.string()
    .required()
    .regex(/^[a-zA-Z0-9_-]{43}$/),
  owner: Joi.string().required(),
  signature: Joi.string().required(),
  reward: Joi.string()
    .regex(/[0-9]*/)
    .required(),
  last_tx: Joi.string().optional().allow("").default(""),
  target: Joi.string().optional().allow("").default(""),
  quantity: Joi.string()
    .regex(/[0-9]*/)
    .optional()
    .allow("")
    .default(""),
  data: Joi.string().optional().allow("").default(""),
  tags: Joi.array()
    .optional()
    .items(
      Joi.object({
        name: Joi.string().required().allow("").default(""),
        value: Joi.string().required().allow("").default(""),
      })
    )
    .default([]),
  format: Joi.number().optional().default(1),
  data_root: Joi.string().optional().allow("").default(""),
  data_size: Joi.string()
    .regex(/[0-9]*/)
    .optional()
    .default(""),
  data_tree: Joi.array().items(Joi.string()).optional().default([]),
});

const dispatchQueueUrl = getQueueUrl("dispatch-txs");
const importQueueUrl = getQueueUrl("import-txs");

export const handler: RequestHandler<{}, {}, Transaction> = async (
  req,
  res
) => {
  const tx = parseInput<Transaction>(txSchema, req.body);
  const { data, ...senzaData } = tx;

  // some clients are sending fractional values in reward, the
  // nodes ALWAYS reject these, so let's make less suffering for the user
  if (
    typeof senzaData === "object" &&
    typeof senzaData["reward"] === "string" &&
    senzaData["reward"].length > 0 &&
    senzaData["reward"].includes(".")
  ) {
    res
      .status(400)
      .send(
        `Bad reward field, expected string-integer but got ${senzaData["reward"]}`
      );
    return;
  }

  req.log.info(`[new-tx] Submit right away`, senzaData);

  try {
    await attemptFallbackNodes(tx);
  } catch (error) {
    req.log.info(
      "[new-tx] something went wrong sending new tx to fallback nodes",
      error
    );
  }

  req.log.info(`[new-tx]`, {
    ...tx,
    data: tx.data && tx.data.substr(0, 100) + "...",
  });

  const dataSize = getDataSize(tx);

  req.log.info(`[new-tx] data_size: ${dataSize}`);

  if (dataSize > 0) {
    const dataBuffer = fromB64Url(tx.data);

    if (dataBuffer.byteLength > 0) {
      await put("tx-data", `tx/${tx.id}`, dataBuffer, {
        contentType: getTagValue(tx.tags, "content-type"),
      });
    }
  }

  req.log.info(`[new-tx] queuing for dispatch to network`, {
    id: tx.id,
    queue: dispatchQueueUrl,
  });

  await enqueue<DispatchTx>(dispatchQueueUrl, {
    data_format: getPayloadFormat(tx),
    data_size: dataSize,
    tx: pick(tx, [
      "format",
      "id",
      "signature",
      "owner",
      "target",
      "reward",
      "last_tx",
      "tags",
      "quantity",
      "data_size",
      "data_tree",
      "data_root",
    ]),
  });

  req.log.info(`[new-tx] queuing for import`, {
    id: tx.id,
    queue: importQueueUrl,
  });

  await enqueue<ImportTx>(importQueueUrl, {
    tx: pick(tx, [
      "format",
      "id",
      "signature",
      "owner",
      "target",
      "reward",
      "last_tx",
      "tags",
      "quantity",
      "data_size",
      "data_tree",
      "data_root",
    ]),
  });

  res.sendStatus(200).end();
};

const getDataSize = (tx: Transaction): number => {
  if (tx.data_size) {
    return parseInt(tx.data_size);
  }
  if (tx.data == "") {
    return 0;
  }

  try {
    return fromB64Url(tx.data).byteLength;
  } catch (error) {
    console.error(error);
    throw new BadRequest();
  }
};

const getPayloadFormat = (tx: Transaction): DataFormatVersion => {
  if (tx.format == 1) {
    return 1;
  }

  if (tx.format == 2) {
    return tx.data && typeof tx.data == "string" && tx.data.length > 0
      ? 2.0
      : 2.1;
  }

  return 1;
};
