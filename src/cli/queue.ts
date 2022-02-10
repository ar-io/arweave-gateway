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

import { SQS } from "aws-sdk";
import { readFileSync } from "fs";
import { sequentialBatch } from "../lib/helpers";
import { enqueueBatch } from "../lib/queues";
import { ImportTx } from "../interfaces/messages";

handler();

export async function handler(): Promise<void> {
  const args = process.argv.slice(2);
  const csvPath = args[0];
  const queueUrl = args[1];

  const rows = readFileSync(csvPath, "utf8").split("\n");

  let count = 0;
  let total = rows.length;

  console.log(`queueUrl: ${queueUrl}\ninputData: ${total} rows`);

  await sequentialBatch(rows, 50, async (batch: string[]) => {
    await Promise.all([
      enqueueBatch<ImportTx>(
        queueUrl,
        batch.slice(0, 10).map((id) => {
          return {
            id,
            message: { id },
          };
        })
      ),
      enqueueBatch<ImportTx>(
        queueUrl,
        batch.slice(10, 20).map((id) => {
          return {
            id,
            message: { id },
          };
        })
      ),
      enqueueBatch<ImportTx>(
        queueUrl,
        batch.slice(20, 30).map((id) => {
          return {
            id,
            message: { id },
          };
        })
      ),
      enqueueBatch<ImportTx>(
        queueUrl,
        batch.slice(30, 40).map((id) => {
          return {
            id,
            message: { id },
          };
        })
      ),
      enqueueBatch<ImportTx>(
        queueUrl,
        batch.slice(40, 50).map((id) => {
          return {
            id,
            message: { id },
          };
        })
      ),
    ]);

    // console.log(
    //   batch.map((id) => {
    //     return {
    //       id,
    //       message: { id },
    //     };
    //   })
    // );

    count = count + batch.length;
    console.log(`${count}/${total}`);
  });
}
