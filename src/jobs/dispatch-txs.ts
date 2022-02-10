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
import { publish } from "../lib/pub-sub";
import { get } from "../lib/buckets";
import { broadcastTx } from "../lib/broadcast";
import { ImportTx, DispatchTx } from "../interfaces/messages";
import { toB64url } from "../lib/encoding";
import { Transaction } from "../lib/arweave";

export const handler = createQueueHandler<DispatchTx>(
  getQueueUrl("dispatch-txs"),
  async (message) => {
    console.log(message);
    const { tx, data_size: dataSize, data_format } = message;

    console.log(`data_size: ${dataSize}, tx: ${tx.id}`);

    console.log(`broadcasting: ${tx.id}`);

    const fullTx: Transaction = {
      ...tx,
      data:
        (!data_format || data_format < 2.1) && dataSize > 0
          ? await getEncodedData(tx.id)
          : "",
    };

    await broadcastTx(fullTx);

    console.log(`publishing: ${tx.id}`);

    await publish<ImportTx>(message);
  }
);

const getEncodedData = async (txid: string): Promise<string> => {
  try {
    const data = await get("tx-data", `tx/${txid}`);
    return toB64url(data.Body as Buffer);
  } catch (error) {
    return "";
  }
};

export default handler;
