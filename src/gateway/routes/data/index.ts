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
import { fetchTransactionData, getTagValue, Tag } from "../../../lib/arweave";
import {
  resolveManifestPath,
  PathManifest,
} from "../../../lib/arweave-path-manifest";
import { getStream, putStream, put, get } from "../../../lib/buckets";
import { RequestHandler, Request, Response } from "express";
import { streamToJson, jsonToBuffer, fromB64Url } from "../../../lib/encoding";
import { Readable } from "stream";
import { NotFound } from "http-errors";
import { query } from "../../../database/transaction-db";
import { StreamTap } from "../../../lib/stream-tap";
import pump from "pump";
import { getData } from "../../../data/transactions";
import { concat } from "lodash";
import { arweaveNodesGet } from "../../../lib/hosts";

const DEFAULT_TYPE = "text/html";

interface Bundle {
  items: { id: string; data: string; tags: Tag[] }[];
}

export const handler: RequestHandler = async (req, res) => {
  const index: number = Math.floor(Math.random() * arweaveNodesGet.length);
  const host: string = arweaveNodesGet[index];
  const txid = getTxIdFromPath(req.path);

  if (txid) {
    const { stream, contentType, contentLength, tags, cached, status } =
      await getData(txid, req);

    req.log.info("tx stream", {
      stream: stream && stream?.readable,
      contentType,
      contentLength,
      cached,
      tags,
    });

    if (status) {
      res.status(status);
    }

    if (contentLength == 0) {
      setDataHeaders({ contentType, etag: txid, res });

      res.end();
    }

    const blacklistHosts = arweaveNodesGet;

    let blhost;
    if (blacklistHosts && blacklistHosts.length > 0) {
      try {
        blhost =
          blacklistHosts[Math.floor(Math.random() * blacklistHosts.length)];
      } catch (error) {
        req.log.info(`[is_tx_blacklisted] ERROR getting the list of nodes`, {
          error,
        });
      }
    } else {
      req.log.info("[is_tx_blacklisted] No hosts available, skipping.");
    }

    let response;
    if (blhost) {
      try {
        req.log.info(`[is_tx_blacklisted] checking if ${txid} is blacklisted`, {
          host: blhost,
          txid,
          link: `${blhost}/is_tx_blacklisted/${txid}`,
        });
        response = await fetch(`${blhost}/is_tx_blacklisted/${txid}`);
      } catch (error) {
        req.log.info(
          `[is_tx_blacklisted] no/failed response host ${blhost} for ${txid} `,
          { error }
        );
      }

      if (response) {
        if (response.status !== 200) {
          req.log.info(
            `[is_tx_blacklisted] failed on host ${blhost} for ${txid}`
          );
        }

        if ((await response.text()) === "true") {
          res.status(451).send("Transaction blacklisted.");
          return;
        }
      }
    }

    if (stream && contentLength) {
      if (contentType == "application/x.arweave-manifest+json") {
        req.log.info("[get-data] manifest content-type detected", { txid });

        const manifest = await streamToJson<PathManifest>(stream);

        let cacheRequest: any = null;

        if (!cached) {
          cacheRequest = put("tx-data", `tx/${txid}`, jsonToBuffer(manifest), {
            contentType,
            tags,
          });
        }

        return await Promise.all([
          cacheRequest,
          handleManifest(req, res, manifest, txid),
        ]);
      }

      setDataHeaders({ contentType, contentLength, etag: txid, res });

      if (cached) {
        stream.pipe(res);
      } else {
        await sendAndCache({
          txid,
          req,
          res,
          stream,
          contentType,
          contentLength,
          tags,
        });
      }
    }
  }
};

const getTxIdFromPath = (path: string): string | undefined => {
  const matches = path.match(/^\/?([a-z0-9-_]{43})/i) || [];
  return matches[1];
};

const setDataHeaders = ({
  res,
  etag,
  contentType,
  contentLength,
}: {
  res: Response;
  etag: string;
  contentType?: string;
  contentLength?: number;
}) => {
  res.header("Etag", etag);
  if (contentType) {
    res.type(contentType || DEFAULT_TYPE);
  }
  if (contentLength) {
    res.header("Content-Length", contentLength.toString());
  }
};

const sendAndCache = async ({
  txid,
  contentType,
  contentLength,
  tags,
  stream,
  res,
  req,
}: {
  txid: string;
  contentType?: string;
  contentLength: number;
  tags?: Tag[];
  stream: Readable;
  req: Request;
  res: Response;
}) => {
  await new Promise(async (resolve, reject) => {
    req.log.info("[get-data] streaming chunks from s3 cache", {
      txid,
    });

    const { upload, stream: cacheStream } = await putStream(
      "tx-data",
      `tx/${txid}`,
      {
        contentType,
        contentLength,
        tags,
      }
    );

    const copyToResponse = new StreamTap(res);

    cacheStream.on("end", (error: any) => {
      req.log.info("[get-data] cach stream ended", { txid, error });

      if (copyToResponse.getBytesProcessed() != contentLength) {
        req.log.warn(
          `[get-data] cached content doesn't match expected data_size`,
          { contentLength, processedBytes: copyToResponse.getBytesProcessed }
        );
      }

      upload.send((err, data) => {
        req.log.info("[get-data] s3 upload done", { data });
        if (err) {
          upload.abort();
          reject(err);
        }
        resolve(data);
      });
    });

    res.flushHeaders();

    pump(stream, copyToResponse, cacheStream, async (err) => {
      if (err) {
        req.log.error("pump error", { err });
        upload.abort();
        res.end();
        cacheStream.end();
        stream.destroy();
        console.log("rejecting...");
        reject(err);
      }
      res.end();
    });
  });
  req.log.info("[get-data] streaming handler complete");
};

const handleManifest = async (
  req: Request,
  res: Response,
  manifest: PathManifest,
  txid: string
) => {
  let safePath = req.path.replace(/\/\?.*/i, "");

  // not risking "/" (index) paths
  if (safePath.length > 1) {
    safePath = safePath.replace(/\/$/i, "");
  }

  let subpath = unescape(getManifestSubpath(safePath) || "");

  // not risking "/" (index) paths
  if (subpath.length > 1) {
    subpath = subpath.replace(/\/$/i, "");
  }

  if (req.path == `/${txid}`) {
    return res.redirect(301, `${req.path}/`);
  }

  const resolvedTx = resolveManifestPath(manifest, subpath);

  req.log.info("[get-data] resolved manifest path content", {
    subpath,
    resolvedTx,
  });

  if (resolvedTx) {
    const { stream, contentType, contentLength, cached } = await getData(
      resolvedTx,
      req
    );

    setDataHeaders({ contentType, contentLength, etag: txid, res });

    if (stream && contentLength && contentLength > 0) {
      if (cached) {
        return stream.pipe(res);
      } else {
        return sendAndCache({
          txid: resolvedTx,
          req,
          res,
          stream,
          contentType,
          contentLength,
        });
      }
    } else {
      req.log.info(
        "[get-data] NotFound contentType, contentLength or stream went missing",
        {
          resolvedTx,
          stream: typeof stream,
          contentType,
          contentLength,
        }
      );
    }
  }

  throw new NotFound();
};

//@deprecated
const getManifestSubpath = (requestPath: string): string | undefined => {
  return getTransactionSubpath(requestPath);
};

const getTransactionSubpath = (requestPath: string): string | undefined => {
  const subpath = requestPath.match(/^\/?[a-zA-Z0-9-_]{43}\/(.*)$/i);
  return (subpath && subpath[1]) || undefined;
};
