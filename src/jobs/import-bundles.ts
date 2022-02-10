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

import { Knex } from "knex";
import {
  TransactionHeader,
  fetchTransactionData,
  DataBundleWrapper,
  getTagValue,
  DataBundleItem,
  fetchRequest,
  fetchTransactionHeader,
} from "../lib/arweave";
import { getData, streamCachedChunks } from "../data/transactions";
import log from "../lib/log";
import {
  saveBundleStatus,
  getBundleImport,
} from "../database/bundle-import-db";
import { createQueueHandler, getQueueUrl, enqueue } from "../lib/queues";
import { ImportBundle } from "../interfaces/messages";
import {
  getConnectionPool,
  initConnectionPool,
  releaseConnectionPool,
} from "../database/postgres";
import { streamToJson, fromB64Url, streamToBuffer } from "../lib/encoding";
import { sequentialBatch } from "../lib/helpers";
import { getTx, saveBundleDataItems } from "../database/transaction-db";
import { buckets, put } from "../lib/buckets";
import verifyAndIndexStream from "arbundles/stream";
import { Bundle, DataItem } from "arbundles";
import { base64 } from "rfc4648";
import base64url from "base64url";
import { head } from "lodash";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { s3 } from "../lib/buckets";
import { PassThrough } from "stream";

type PartialBy<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;

const MAX_RETRY = 9;
const RETRY_BACKOFF_SECONDS = 60;
const MAX_BACKOFF_SECONDS = 150;

export const isTxAns104 = (tx: TransactionHeader): boolean => {
  return (
    // getTagValue(tx.tags, "content-type") == "application/json" &&
    getTagValue(tx.tags, "bundle-format") == "binary" &&
    getTagValue(tx.tags, "bundle-version") == "2.0.0"
  );
};

async function calculateBackoffWaitTime(
  retryNum: number,
  numBytes: number,
  reward: number
): Promise<number> {
  log.info("[import-bundles] calculating backoff value");
  let basePrice: number = -1;
  try {
    const response = await fetchRequest(`price/${numBytes}`);
    basePrice =
      response && response.body
        ? parseInt(await streamToJson(response.body))
        : 0;
  } catch (error) {
    throw new Error(
      "[import-bundles] getting basePrice from nodes failed, " + error
    );
  }
  if (basePrice === -1) {
    // most likely redundant, but better safe than sorry
    throw new Error(
      `[import-bundles] something went wrong parsing basePrice from /price/${numBytes}`
    );
  }
  const rewardMultiplier = reward / basePrice;

  const waitMultiplier =
    retryNum * RETRY_BACKOFF_SECONDS * (1 / rewardMultiplier);

  const returnedBackoffTime = Math.max(MAX_BACKOFF_SECONDS, waitMultiplier);
  log.info(
    `[import-bundles] setting retry backoff time to ${returnedBackoffTime}`,
    { rewardMultiplier, waitMultiplier, basePrice, retryNum, reward }
  );
  return returnedBackoffTime;
}

export const handler = createQueueHandler<ImportBundle>(
  getQueueUrl("import-bundles"),
  async ({ header, id }) => {
    log.info("[import-bundles] importing tx bundle", {
      bundle: {
        id,
        tx: header?.id,
      },
    });

    const pool = getConnectionPool("write");

    const tx = header ? header : await fetchTransactionHeader(id || "");

    const txDataSize = parseInt(tx["data_size"]);

    const { attempts = 0 } = await getBundleImport(pool, tx.id);

    log.info("[import-bundles] importing tx bundle status", {
      bundle: {
        id: tx.id,
        attempts,
      },
    });

    const incrementedAttempts = attempts + 1;

    let stream;

    try {
      if (tx && typeof tx.id === "string" && tx.id.length > 0) {
        const maybeStream = await getData(tx.id || "", { log });
        stream = maybeStream ? maybeStream.stream : undefined;
      }
    } catch (error) {
      log.error("[import-bundles] error getting stream via getData", error);
    }

    const Bucket = buckets["tx-data"];

    if (stream) {
      const is104 = isTxAns104(tx);
      const headTxObj = await s3
        .headObject({
          Key: `tx/${tx.id}`,
          Bucket,
        })
        .promise()
        .then((r) => r.ContentLength === txDataSize)
        .catch((_) => false);

      if (!headTxObj) {
        let isSuccessful = false;
        try {
          await s3
            .upload({
              Key: `tx/${tx.id}`,
              Bucket,
              Body: stream,
            })
            .promise();
          isSuccessful = true;
        } catch (error) {
          log.error(
            "[import-bundles] error streaming from nodes direct to s3 bucket",
            error
          );
        }
        if (!isSuccessful) {
          log.error(
            "Data not available, neither in cache nor nodes, requeuing"
          );
          await retry(pool, tx, {
            attempts: incrementedAttempts,
            error: "Data not yet available",
          });

          throw new Error("Data not yet available, neither in cache nor nodes");
        }

        stream = s3
          .getObject({ Key: `tx/${tx.id}`, Bucket })
          .createReadStream();
      }

      log.info(`[import-bundles] is ANS-104: ${is104}`);
      log.info("[import-bundles] streaming to buffer/json...");

      const bundleImport = await getBundleImport(pool, tx.id);

      let data: { items: DataBundleItem[] } | undefined;

      if (
        bundleImport.bundle_meta &&
        typeof bundleImport.bundle_meta === "string" &&
        bundleImport.bundle_meta.length > 0
      ) {
        data = JSON.parse(bundleImport.bundle_meta);
      } else {
        try {
          if (is104) {
            data = { items: (await verifyAndIndexStream(stream)) as any };
          }
        } catch (error) {
          log.error(
            `[import-bundles] validation call error in ${tx.id}\n\t`,
            error
          );
          await invalid(pool, tx.id, {
            attempts: incrementedAttempts,
            error: (error as any).message,
          });
          return;
        }

        try {
          if (!is104) {
            data = (await streamToJson<DataBundleWrapper>(stream)) as any;
          }

          data = typeof data !== "undefined" ? data : undefined;

          log.info("[import-bundles] finished streaming to buffer/json");

          if (!is104) validateAns102(data as any);

          if (data) {
            await updateBundle(pool, tx.id, data.items);
          } else {
            throw new Error("Data is null");
          }
        } catch (error: any) {
          log.error("error", { id: tx.id, error });
          await invalid(pool, tx.id, {
            attempts: incrementedAttempts,
            error: error.message,
          });
        }
      }

      log.info(
        `[import-bundles] bundle: ${tx.id} is valid, moving on to indexing...`
      );

      // @ts-ignore
      if (!data) throw new Error("Data is null");

      // If data is ANS-104
      if (is104) {
        data.items.forEach(
          (i) =>
            (i.tags = i.tags.map((tag) => ({
              name: base64url(tag.name),
              value: base64url(tag.value),
            })))
        );
      }

      try {
        await Promise.all([
          sequentialBatch(
            data.items,
            200,
            async (items: PartialBy<DataBundleItem, "data">[]) => {
              await Promise.all(
                items.map(async (item) => {
                  const contentType = getTagValue(item.tags, "content-type");
                  console.log(
                    `bytes=${item.dataOffset}-${
                      item.dataOffset + item.dataSize - 1
                    }`
                  );
                  const bundleData = !is104
                    ? item && fromB64Url(item.data || "")
                    : // TODO: Get data by offset (item.offset)
                      s3
                        .getObject({
                          Key: `tx/${tx.id}`,
                          Bucket,
                          Range: `bytes=${item.dataOffset}-${
                            item.dataOffset + item.dataSize - 1
                          }`,
                        })
                        .createReadStream();

                  log.info(`[import-bundles] putting data item: ${item.id}`);

                  await put("tx-data", `tx/${item.id}`, bundleData, {
                    contentType: contentType || "application/octet-stream",
                  });
                })
              );
            }
          ),
          sequentialBatch(data.items, 100, async (items: DataBundleItem[]) => {
            await saveBundleDataItems(pool, tx.id, items);
          }),
        ]);
        await complete(pool, tx.id, { attempts: incrementedAttempts });
      } catch (error: any) {
        log.error("error", error);
        await retry(pool, tx, {
          attempts: incrementedAttempts,
          error: error.message + error.stack || "",
        });
      }
    } else {
      log.error("Data not available, requeuing");
      await retry(pool, tx, {
        attempts: incrementedAttempts,
        error: "Data not yet available",
      });
    }
  },
  {
    before: async () => {
      log.info(`[import-bundles] handler:before database connection init`);
      initConnectionPool("read");
      initConnectionPool("write");
    },
    after: async () => {
      log.info(`[import-bundles] handler:after database connection cleanup`);
      await releaseConnectionPool("read");
      await releaseConnectionPool("write");
    },
  }
);

const retry = async (
  connection: Knex<any>,
  header: TransactionHeader,
  { attempts, error }: { attempts: number; error?: any }
) => {
  if (attempts && attempts >= MAX_RETRY + 1) {
    return saveBundleStatus(connection, [
      {
        id: header.id,
        status: "error",
        attempts,
        error,
      },
    ]);
  }

  let numBytes: number = -1;
  let reward: number = -1;

  try {
    numBytes =
      typeof header.data_size === "number"
        ? header.data_size
        : parseInt(header.data_size);
  } catch (error) {
    log.error(
      `[import-bundles] unable to get data_size out of ${header.data_size}`,
      error
    );
  }

  try {
    reward =
      typeof header.reward === "number"
        ? header.reward
        : parseInt(header.reward);
  } catch (error) {
    log.error(
      `[import-bundles] unable to get reward out of ${header.reward}`,
      error
    );
  }

  if (numBytes === -1 || reward === -1) {
    throw new Error(
      `[import-bundles] something went wrong parsing the tx-headers (there should be an error message above)`
    );
  }

  return calculateBackoffWaitTime(attempts, numBytes, reward).then((delay) => {
    return Promise.all([
      saveBundleStatus(connection, [
        {
          id: header.id,
          status: "pending",
          attempts,
          error: error || null,
        },
      ]),
      enqueue<ImportBundle>(
        getQueueUrl("import-bundles"),
        { header },
        { delaySeconds: delay }
      ),
    ]);
  });
};

const complete = async (
  connection: Knex<any>,
  id: string,
  { attempts }: { attempts: number }
) => {
  // TODO: Add column
  await saveBundleStatus(connection, [
    {
      id,
      status: "complete",
      attempts,
      error: null,
    },
  ]);
};

const invalid = async (
  connection: Knex<any>,
  id: string,
  { attempts, error }: { attempts: number; error?: string }
) => {
  await saveBundleStatus(connection, [
    {
      id,
      status: "invalid",
      attempts,
      error: error || null,
    },
  ]);
};

const updateBundle = async (
  connection: Knex<any>,
  id: string,
  items: any[]
) => {
  await saveBundleStatus(connection, [
    {
      id,
      status: "invalid",
      bundle_meta: JSON.stringify(items),
    },
  ]);
};

const validateAns102 = (bundle: { items: DataBundleItem[] }) => {
  bundle.items.forEach((item) => {
    const fields = Object.keys(item);
    const requiredFields = ["id", "owner", "signature", "data"];
    requiredFields.forEach((requiredField) => {
      if (!fields.includes(requiredField)) {
        throw new Error(
          `Invalid bundle detected, missing required field: ${requiredField}`
        );
      }
    });
  });
};

const validateAns104 = async (bundle: Bundle) => {
  if (!(await bundle.verify())) {
    throw new Error("Invalid ANS-104 bundle detected");
  }
};

async function collectAsyncGenerator<T>(g: AsyncGenerator<T>): Promise<T[]> {
  const arr: any[] = [];
  for await (const item of g) {
    arr.push(item);
  }
  return arr;
}

export default handler;
