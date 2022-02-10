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

import { fetchRequest } from "../../../lib/arweave";
import { RequestHandler } from "express";
import { BadGateway, NotFound, HttpError } from "http-errors";
import { streamToString } from "../../../lib/encoding";
import { Logger } from "winston";

interface CachedResponse {
  status: number;
  contentType?: string;
  contentLength?: number;
  body?: string;
}

export const handler: RequestHandler = async (req, res) => {
  const { log, method, path } = req;

  req.log.info(`[proxy] request`, { method, path });

  const { status, contentType, contentLength, body } = await proxyAndCache(
    method,
    // Remove slash prefix for node.net/info rather than node.net//info
    path.replace(/^\//, ""),
    log
  );

  if (contentType) {
    res.type(contentType);
  }

  res.status(status);

  return res.send(body).end();
};

const proxyAndCache = async (
  method: string,
  path: string,
  log: Logger
): Promise<CachedResponse> => {
  let nodeStatuses: number[] = [];

  const response = await fetchRequest(path);

  if (response && response.body) {
    const { statusCode: status, headers, body } = response;
    const streamedBody = body;
    const contentType =
      (headers as any)["content-type"] ||
      (headers as any)["Content-Type"] ||
      undefined;
    const contentLength = Buffer.byteLength(streamedBody, "utf8");

    return {
      body: streamedBody,
      status,
      contentType,
      contentLength,
    };
  } else {
    throw new NotFound();
  }
};

const exposeError = (error: HttpError): HttpError => {
  error.expose = true;
  return error;
};
