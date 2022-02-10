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

import "./env.mjs";
import R from "ramda";
import retry from "async-retry";
import pWaitFor from "p-wait-for";
import pMinDelay from "p-min-delay";
import pWhilst from "p-whilst";
import exitHook from "exit-hook";
import got from "got";
import { createDbClient } from "./postgres.mjs";
import { shuffle } from "./utils.mjs";
import {
  fullBlockToDbBlock,
  getHighestBlock,
  getRecentBlocks,
  saveBlocks,
} from "./block-db.mjs";

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

let latestBlock;
let lastBlock;

export const getNewestBlock = async () => {
  for (const node of nodes.values()) {
    let response;
    try {
      response = await got(node + "/block/current").json();
      // const response = await got(node + "/block/height/705101").json();
    } catch {}
    if (typeof response === "object" && typeof response.height === "number") {
      return response;
    }
  }
};

export const getSpecificBlock = async (hash) => {
  let block;
  for (const node of nodes.values()) {
    try {
      const response = await got(node + "/block/hash/" + hash).json();

      if (typeof response === "object" && response.indep_hash === hash) {
        block = response;
      }
    } catch (error) {
      console.error(error);
    }
    if (block) {
      return block;
    }
  }
  return block;
};

export const getSpecificBlockHeight = async (height) => {
  let block;
  for (const node of nodes.values()) {
    try {
      const response = await got(node + "/block/height/" + height).json();

      if (typeof response === "object") {
        block = response;
      }
    } catch (error) {
      console.error(error);
    }
    if (block) {
      return block;
    }
  }
  return block;
};

(async () => {
  console.log("starting import-blocks...");
  console.log(process.env);
  await refreshNodes();

  const dbRead = await createDbClient({
    user: "read",
  });
  const dbWrite = await createDbClient({
    user: "write",
  });

  lastBlock = await getHighestBlock(dbRead);
  latestBlock = await getNewestBlock();

  pWhilst(
    () => !exitSignaled,
    async () => {
      console.log("Polling for new block...");
      try {
        // await pMinDelay(getNewestBlock(), 5 * 1000);
        await new Promise((resolve) => setTimeout(resolve, 5 * 1000));
        latestBlock = await getNewestBlock();
        // mega-gap scenario
        // dont import more than 100 block in single go
        // due do crazy memory needed to do so.
        if (
          lastBlock &&
          latestBlock &&
          latestBlock.height - lastBlock.height > 100
        ) {
          console.log("far behind: resolving next 100 blocks");
          latestBlock = await getSpecificBlockHeight(lastBlock.height + 100);
        }

        console.log("Comparing", lastBlock.height, latestBlock.height);
        if (lastBlock && latestBlock && latestBlock.height > lastBlock.height) {
          console.log("New block detected: ", latestBlock.height);
          if (
            typeof latestBlock === "object" &&
            (latestBlock.height === 0 ||
              latestBlock.previous_block === lastBlock.id)
          ) {
            console.log("current block matches new block's previous block");
            await saveBlocks(dbWrite, [fullBlockToDbBlock(latestBlock)]);
            console.log("[import-blocks] saveBlock completed!");
            lastBlock = latestBlock;
          } else {
            console.log("gap detected...");
            const gapDiff_ = await resolveGap(
              (await getRecentBlocks(dbRead)).map((block) => block.id),
              [latestBlock],
              {
                maxDepth: 3000,
              }
            );
            const gapDiff = gapDiff_.map(fullBlockToDbBlock);

            console.log(`[import-blocks] resolved fork/gap`, {
              length: gapDiff.length,
            });

            await saveBlocks(dbWrite, gapDiff);
            console.log("[import-blocks] saveBlocks completed!");
            lastBlock = latestBlock;
          }
        }
      } catch (error) {
        console.error(error);
      }
    }
  );
})();

/**
 * Try and find the branch point between the chain in our database and the chain
 * belonging to the new block we've just received. If we find a branch point,
 * We'll return the diff as a sorted array containing all the missing blocks.
 */
export const resolveGap = async (
  mainChainIds,
  fork,
  { currentDepth = 0, maxDepth = 10 }
) => {
  // Grab the last known block from the forked chain (blocks are appended, newest -> oldest).
  const block = fork[fork.length - 1];

  // genesis fix
  if (!block || block.height === 0) return fork;

  console.log(`[import-blocks] resolving fork/gap`, {
    id: block.indep_hash,
    height: block.height,
  });

  // If this block has a previous_block value that intersects with the the main chain ids,
  // then it means we've resolved the fork. The fork array now contains the block
  // diff between the two chains, sorted by height descending.
  if (mainChainIds.includes(block.previous_block)) {
    console.log(`[import-blocks] resolved fork`, {
      id: block.indep_hash,
      height: block.height,
    });

    return fork;
  }

  if (currentDepth >= maxDepth) {
    throw new Error(`Couldn't resolve fork within maxDepth of ${maxDepth}`);
  }

  const previousBlock = await getSpecificBlock(block.previous_block);

  // If we didn't intersect the mainChainIds array then we're still working backwards
  // through the forked chain and haven't found the branch point yet.
  // We'll add this previous block block to the end of the fork and try again.
  return resolveGap(mainChainIds, [...fork, previousBlock], {
    currentDepth: currentDepth + 1,
    maxDepth,
  });
};
