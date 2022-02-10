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

import { TransactionHeader, Block } from "../../../lib/arweave";
import { enqueue, getQueueUrl } from "../../../lib/queues";
import { pick } from "lodash";
import { ImportTx, ImportBlock } from "../../../interfaces/messages";
import { RequestHandler } from "express";
import { NotFound, BadRequest } from "http-errors";

export const handler: RequestHandler = async (req, res, next) => {
  if (
    process.env.WEBHOOK_TOKEN &&
    process.env.WEBHOOK_TOKEN != req.query.token
  ) {
    req.log.info(`[webhook] invalid webhook token provided ${req.query.token}`);
    throw new NotFound();
  }

  const {
    transaction,
    block,
  }: { transaction: TransactionHeader; block: Block } = req.body;

  if (!transaction && !block) {
    throw new BadRequest();
  }

  if (transaction) {
    req.log.info(`[webhook] importing transaction header`, {
      id: transaction.id,
    });
    await importTx(transaction);
    return res.sendStatus(200).end();
  }

  if (block) {
    req.log.info(`[webhook] importing block`, { id: block.indep_hash });
    await importBlock({
      block,
      source: req.headers["x-forwarded-for"]
        ? req.headers["x-forwarded-for"][0]
        : "0.0.0.0",
    });
    return res.sendStatus(200).end();
  }
  req.log.info(`[webhook] no valid payload provided`);
  throw new BadRequest();
};

const importTx = async (tx: TransactionHeader): Promise<void> => {
  let dataSize = parseInt(tx.data_size || "0");
  return enqueue<ImportTx>(getQueueUrl("import-txs"), {
    tx: pick(
      {
        ...(tx as any),
        data_size: dataSize,
        data_tree: tx.data_tree || [],
        data_root: tx.data_root || "",
        format: tx.format || 1,
      },
      [
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
      ]
    ),
  });
};

const importBlock = async ({ source, block }: ImportBlock): Promise<void> => {
  await enqueue<ImportBlock>(
    getQueueUrl("import-blocks"),
    {
      source: source,
      block: pick(block, [
        "nonce",
        "previous_block",
        "timestamp",
        "last_retarget",
        "diff",
        "height",
        "hash",
        "indep_hash",
        "txs",
        "tx_root",
        "wallet_list",
        "reward_addr",
        "reward_pool",
        "weave_size",
        "block_size",
        "cumulative_diff",
        "hash_list_merkle",
      ]),
    },
    {
      messagegroup: `source:${source}`,
      deduplicationId: `source:${source}/${Date.now()}`,
    }
  );
};
