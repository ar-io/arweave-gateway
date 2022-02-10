import AbortController from "abort-controller";
import { NotFound } from "http-errors";
import { shuffle } from "lodash";
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

import got, { GotReturn, Response } from "got/dist/source/index.js";
import { Readable } from "stream";
import log from "../lib/log";
import {
  Base64UrlEncodedString,
  bufferToStream,
  fromB64Url,
  isValidUTF8,
  streamToBuffer,
  streamToJson,
  WinstonString,
} from "./encoding";
import { arweaveNodesGet as origins } from "./hosts";
import { DataItem } from "arbundles";

interface ArFetchOptions {
  stream?: boolean;
  json?: boolean;
  noStatusFilter?: boolean;
}

export type TransactionHeader = Omit<Transaction, "data">;

export type TransactionData = {
  data: Buffer;
  contentType: string | undefined;
};

export interface Transaction {
  format: number;
  id: string;
  signature: string;
  owner: string;
  target: string;
  data: Base64UrlEncodedString;
  reward: WinstonString;
  last_tx: string;
  tags: Tag[];
  quantity: WinstonString;
  data_size: string;
  data_root: string;
  data_tree: string[];
}

export interface DataBundleWrapper {
  items: (DataBundleItem | DataItem)[];
}

export interface DataBundleItem {
  owner: string;
  target: string;
  nonce: string;
  tags: Tag[];
  data: Base64UrlEncodedString;
  signature: string;
  id: string;
  dataOffset: number;
  dataSize: number;
}

export interface Chunk {
  data_root: string;
  data_size: number;
  data_path: string;
  chunk: string;
  offset: number;
}

export type ChunkHeader = Omit<Chunk, "chunk">;

export interface Tag {
  name: Base64UrlEncodedString;
  value: Base64UrlEncodedString;
}

export interface Block {
  nonce: string;
  previous_block: string;
  timestamp: number;
  last_retarget: number;
  diff: string;
  height: number;
  hash: string;
  indep_hash: string;
  txs: string[];
  tx_root: string;
  wallet_list: string;
  reward_addr: string;
  reward_pool: number;
  weave_size: number;
  block_size: number;
  cumulative_diff: string;
  hash_list_merkle: string;
}

export interface DataResponse {
  stream?: Readable;
  contentLength: number;
  contentType?: string;
  tags?: Tag[];
}

export const fetchBlock = async (id: string): Promise<Block> => {
  const endpoints = origins.map((host) => `${host}/block/hash/${id}`);

  const response = await getFirstResponse(endpoints);

  if (response && response.body) {
    const block = await streamToJson(response.body as any);

    //For now we don't care about the poa and it's takes up too much
    // space when logged, so just remove it for now.
    //@ts-ignore
    delete block.poa;

    return block as Block;
  }

  throw new Error(`Failed to fetch block: ${id}`);
};

export const fetchBlockByHeight = async (height: string): Promise<Block> => {
  log.info(`[arweave] fetching block by height`, { height });

  const endpoints = origins.map((host) => `${host}/block/height/${height}`);

  const response = await getFirstResponse(endpoints);

  if (response && response.body) {
    const block = await streamToJson(response.body as any);

    //For now we don't care about the poa and it's takes up too much
    // space when logged, so just remove it for now.
    //@ts-ignore
    delete block.poa;

    return block as Block;
  }

  throw new Error(`Failed to fetch block: ${height}`);
};

export const fetchTransactionHeader = async (
  txid: string
): Promise<TransactionHeader> => {
  log.info(`[arweave] fetching transaction header`, { txid });
  const endpoints = origins.map((host) => `${host}/tx/${txid}`);

  const response = await getFirstResponse(endpoints);

  if (response && response.body) {
    return (await streamToJson(response.body as any)) as TransactionHeader;
  }

  throw new NotFound();
};

const getContentLength = (headers: any): number => {
  return parseInt(headers.get("content-length"));
};

export const fetchTransactionData = async (
  txid: string
): Promise<DataResponse> => {
  log.info(`[arweave] fetching data and tags`, { txid });

  try {
    const [tagsResponse, dataResponse] = await Promise.all([
      fetchRequest(`tx/${txid}/tags`),
      fetchRequest(`tx/${txid}/data`),
    ]);

    const tags =
      tagsResponse && tagsResponse.body && tagsResponse.statusCode == 200
        ? ((await streamToJson(tagsResponse.body)) as Tag[])
        : [];

    const contentType = getTagValue(tags, "content-type");

    if (dataResponse && dataResponse.body) {
      if (dataResponse.statusCode == 200) {
        const content = fromB64Url(dataResponse.body.toString());

        return {
          tags,
          contentType,
          contentLength: content.byteLength,
          stream: bufferToStream(content),
        };
      }

      if (dataResponse && dataResponse.statusCode == 400) {
        const { error } = await streamToJson<{ error: string }>(
          dataResponse.body
        );

        if (error == "tx_data_too_big") {
          const offsetResponse = await fetchRequest(`tx/${txid}/offset`);

          if (offsetResponse && offsetResponse.body) {
            const { size, offset } = await streamToJson(offsetResponse.body);
            return {
              tags,
              contentType,
              contentLength: parseInt(size),
              stream: await streamChunks({
                size: parseInt(size),
                offset: parseInt(offset),
              }),
            };
          }
        }
      }
    }

    log.info(`[arweave] failed to find tx`, { txid });
  } catch (error: any) {
    log.error(`[arweave] error finding tx`, { txid, error: error.message });
  }

  return { contentLength: 0 };
};

export const streamChunks = function ({
  offset,
  size,
}: {
  offset: number;
  size: number;
}): Readable {
  let bytesReceived = 0;
  let initialOffset = offset - size + 1;

  const stream = new Readable({
    autoDestroy: true,
    read: async function () {
      let next = initialOffset + bytesReceived;

      try {
        if (bytesReceived >= size) {
          this.push(null);
          return;
        }

        const response = await fetchRequest(`chunk/${next}`);

        if (response && response.body) {
          const data = fromB64Url((await streamToJson(response.body)).chunk);

          if (stream.destroyed) {
            return;
          }

          this.push(data);

          bytesReceived += data.byteLength;
        }
      } catch (error: any) {
        console.error("stream error", error);
        stream.emit("error", error);
      }
    },
  });

  return stream;
};

export const fetchRequest = async (endpoint: string): Promise<any> => {
  const endpoints = origins.map((host) => `${host}/${endpoint}`);

  return await getFirstResponse(endpoints);
};

export const streamRequest = async (
  endpoint: string,
  filter?: FilterFunction
): Promise<GotReturn | undefined> => {
  const endpoints = origins.map(
    // Replace any starting slashes
    (host) => `${host}/${endpoint.replace(/^\//, "")}`
  );

  for (const url of shuffle(endpoints)) {
    let response;
    try {
      response = await got.stream(url);
    } catch (error: any) {
      log.warn(`[arweave] request error`, {
        message: error.message,
        url,
      });
    }
    return response;
  }
};

export const getTagValue = (tags: Tag[], name: string): string | undefined => {
  const contentTypeTag = tags.find((tag) => {
    try {
      return (
        fromB64Url(tag.name).toString().toLowerCase() == name.toLowerCase()
      );
    } catch (error: any) {
      return undefined;
    }
  });
  try {
    return contentTypeTag
      ? fromB64Url(contentTypeTag.value).toString()
      : undefined;
  } catch (error) {
    return undefined;
  }
};

export const utf8DecodeTag = (tag: Tag): { name: string; value: string } => {
  let name = "";
  let value = "";
  try {
    const nameBuffer = fromB64Url(tag.name) || "";
    if (isValidUTF8(nameBuffer)) {
      name = nameBuffer.toString("utf8");
    }
    const valueBuffer = fromB64Url(tag.value) || "";
    if (isValidUTF8(valueBuffer)) {
      value = valueBuffer.toString("utf8");
    }
  } catch (error) {}
  return {
    name,
    value,
  };
};

type FilterFunction = (status: number) => boolean;

const defaultFilter: FilterFunction = (status) =>
  [200, 201, 202, 208].includes(status);

const getFirstResponse = async <T = any>(
  urls: string[]
): Promise<Response | undefined> => {
  for (const url of shuffle(urls)) {
    let response;
    try {
      response = await got.get(url, {
        timeout: {
          request: 5000,
        },
      });
    } catch (error: any) {
      log.warn(`[arweave] request error`, {
        message: error.message,
        url,
      });
    }
    if (response && defaultFilter(response.statusCode)) {
      return response;
    }
  }
};
