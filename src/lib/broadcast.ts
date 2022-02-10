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

import fetch from "node-fetch";
import { shuffle } from "lodash";
import log from "./log";
import { Chunk, Transaction } from "./arweave";
import { arweaveNodesPut as arweaveNodes, arweaveFallbackNodes } from "./hosts";

let ARWEAVE_DISPATCH_TX_CONFIRMATION_REQUIREMENT: number;

try {
  ARWEAVE_DISPATCH_TX_CONFIRMATION_REQUIREMENT = parseInt(
    process.env.ARWEAVE_DISPATCH_TX_CONFIRMATION_REQUIREMENT as string
  );
} catch (error) {
  log.info(
    "ERROR: ARWEAVE_DISPATCH_TX_CONFIRMATION_REQUIREMENT was not defined or was not a number!"
  );
  ARWEAVE_DISPATCH_TX_CONFIRMATION_REQUIREMENT = 2;
}

export async function attemptFallbackNodes(tx: Transaction) {
  log.info(`[broadcast-tx] broadcasting new tx to fallback nodes`, {
    id: tx.id,
    arweaveNodes,
  });
  for (const fallbackNode of arweaveFallbackNodes) {
    try {
      await fetch(`${fallbackNode}/tx`, {
        method: "POST",
        body: JSON.stringify(tx),
        headers: { "Content-Type": "application/json" },
      });
    } catch (error: any) {
      log.error(
        `[broadcast-tx] attempting a fallback node "${fallbackNode}" failed`,
        error
      );
    }
  }
}

export async function broadcastTx(tx: Transaction) {
  log.info(`[broadcast-tx] broadcasting new tx`, { id: tx.id, arweaveNodes });

  let submitted = 0;

  let retry = -1;
  const retries = arweaveNodes.length * 2;
  const shuffledArweaveNodes = shuffle(arweaveNodes);

  while (
    submitted < ARWEAVE_DISPATCH_TX_CONFIRMATION_REQUIREMENT &&
    retries > retry
  ) {
    retry += 1;
    await wait(100);

    const index = retry % arweaveNodes.length;
    let host: string = shuffledArweaveNodes[index];

    log.info(`[broadcast-tx] sending`, { host, id: tx.id });
    try {
      const { status: existingStatus, ok: isReceived } = await fetch(
        `${host}/tx/${tx.id}/id`
      );

      if (isReceived) {
        log.info(`[broadcast-tx] already received`, {
          host,
          id: tx.id,
          existingStatus,
        });
        submitted++;
        break;
      }

      const {
        status: postStatus,
        ok: postOk,
        text: bodyText,
      } = await fetch(`${host}/tx`, {
        method: "POST",
        body: JSON.stringify(tx),
        headers: { "Content-Type": "application/json" },
      });

      log.info(`[broadcast-tx] sent`, {
        host,
        id: tx.id,
        postStatus,
      });

      if ([400, 410].includes(postStatus)) {
        log.error(`[broadcast-tx] failed`, {
          id: tx.id,
          host,
          error: postStatus,
          body: await bodyText(),
        });
      } else {
        submitted++;
      }
    } catch (e: any) {
      log.error(`[broadcast-tx] failed`, {
        id: tx.id,
        host,
        error: e.message,
      });
      return false;
    }
  }

  return submitted >= ARWEAVE_DISPATCH_TX_CONFIRMATION_REQUIREMENT;
}

export async function broadcastChunk(chunk: Chunk) {
  log.info(`[broadcast-chunk] broadcasting new chunk`, {
    chunk: chunk.data_root,
  });

  let submitted = 0;

  for (const host of arweaveNodes) {
    await wait(50);

    log.info(`[broadcast-chunk] sending`, { host, chunk: chunk.data_root });
    try {
      const response = await fetch(`${host}/chunk`, {
        method: "POST",
        body: JSON.stringify({
          ...chunk,
          data_size: chunk.data_size.toString(),
          offset: chunk.offset.toString(),
        }),
        headers: {
          "Content-Type": "application/json",
          "arweave-data-root": chunk.data_root,
          "arweave-data-size": chunk.data_size.toString(),
        },
      });

      log.info(`[broadcast-chunk] sent`, {
        host,
        status: response.status,
      });

      if (!response.ok) {
        log.warn(`[broadcast-chunk] response`, {
          host,
          chunk: chunk.data_root,
          status: response.status,
          body: await response.text(),
        });
      }

      if ([400, 410].includes(response.status)) {
        log.error(`[broadcast-chunk] failed or waiting for tx`, {
          host,
          error: response.status,
          chunk: chunk.data_root,
        });
      } else {
        submitted++;
      }
    } catch (error: any) {
      log.warn(`[broadcast-chunk] failed to broadcast: ${host}`, {
        error: error.message,
        chunk: chunk.data_root,
      });
    }
  }

  if (submitted < 2) {
    throw new Error(`Failed to successfully broadcast to 2 nodes`);
    return false;
  } else {
    log.log(`[broadcast-chunk] complete`, {
      submitted,
    });
    return true;
  }
}

const wait = async (timeout: number) =>
  new Promise((resolve) => setTimeout(resolve, timeout));
