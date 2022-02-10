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

import { chunk } from "lodash";
import { getTagValue, TransactionHeader } from "../lib/arweave";

/**
 * Split a large array into batches and process each batch sequentially,
 * using an awaited async function.
 * @param items
 * @param batchSize
 * @param func
 */
export const sequentialBatch = async (
  items: any[],
  batchSize = 10,
  func: Function
) => {
  const batches = chunk(items, batchSize);

  for (let batchIndex = 0; batchIndex < batches.length; batchIndex++) {
    const batch = batches[batchIndex];
    await func(batch);
  }
};

export const wait = async (ms: number) => {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
};

export const isTxAns102 = (tx: TransactionHeader): boolean => {
  return (
    // getTagValue(tx.tags, "content-type") == "application/json" &&
    getTagValue(tx.tags, "bundle-format") == "json" &&
    getTagValue(tx.tags, "bundle-version") == "1.0.0"
  );
};

export const isTxAns104 = (tx: TransactionHeader): boolean => {
  return (
    // getTagValue(tx.tags, "content-type") == "application/json" &&
    getTagValue(tx.tags, "bundle-format") == "binary" &&
    getTagValue(tx.tags, "bundle-version") == "2.0.0"
  );
};
