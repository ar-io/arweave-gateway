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

import morgan, { token as morganToken } from "morgan";
import { RequestHandler, Request } from "express";
import shortId from "shortid";
import log from "../../lib/log";
import { createLogger, transports, format } from "winston";

export const configureRequestLogging: RequestHandler = (req, res, next) => {
  const traceId = shortId.generate();
  req.id = traceId;
  res.header("X-Trace", traceId);
  req.log = log.child({
    trace: traceId,
  });
  next();
};

morganToken("trace", (req) => {
  return getTraceId(req);
});

morganToken("aws_trace", (req) => {
  return getAwsTraceId(req);
});

export const handler = morgan({
  stream: { write: (str: string) => log.log("info", str) },
});

const getTraceId = (req: any): string => {
  return req.id || "";
};

const getAwsTraceId = (req: any): string => {
  return req.headers["x-amzn-trace-id"]
    ? (req.headers["x-amzn-trace-id"] as string)
    : "";
};
