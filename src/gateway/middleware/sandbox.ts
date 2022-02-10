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

import { fromB64Url, toB32 } from "../../lib/encoding";
import { RequestHandler, Request } from "express";
import querystring from "querystring";

const getTxIdFromPath = (path: string): string | undefined => {
  const matches = path.match(/^\/?([a-z0-9-_]{43})/i) || [];
  return matches[1];
};

export const handler: RequestHandler = (req, res, next) => {
  const txid = getTxIdFromPath(req.path);

  if (txid && !req.headers["x-amz-cf-id"]) {
    const currentSandbox = getRequestSandbox(req);
    const expectedSandbox = expectedTxSandbox(txid);
    let queryString = "";

    if (
      req &&
      typeof req === "object" &&
      req.path &&
      typeof req.query === "object" &&
      Object.keys(req.query).length > 0
    ) {
      try {
        queryString = (
          ((req.path || "").endsWith("/") ? "?" : "/?") +
          querystring.stringify(req.query as any)
        ).replace(/\/\//i, "/"); // fix double slash
      } catch (error) {
        req.log.info("[sandbox] error making queryString", error as any);
        queryString = "";
      }
    }

    if (currentSandbox !== expectedSandbox) {
      return res.redirect(
        302,
        `${process.env.SANDBOX_PROTOCOL}://${expectedSandbox}.` +
          `${process.env.SANDBOX_HOST}${req.path}${queryString || ""}`.replace(
            /\/\//i,
            "/"
          )
      );
    }
  }

  next();
};

const expectedTxSandbox = (id: string): string => {
  return toB32(fromB64Url(id));
};

const getRequestSandbox = (req: Request) => {
  return req.headers.host!.split(".")[0].toLowerCase();
};
