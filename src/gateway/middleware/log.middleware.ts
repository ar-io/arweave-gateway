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

import morgan from "morgan";
import id from "shortid";
import { Request, Response, NextFunction } from "express";

export function logConfigurationMiddleware(
  req: Request,
  res: Response,
  next: NextFunction
) {
  const trace = id.generate();
  req.id = trace;
  res.header("X-Trace", trace);
  return next();
}
morgan.token("trace", (req: Request) => {
  return req.id || "UNKNOWN";
});

export const logMiddleware = morgan(
  '[http] :remote-addr - :remote-user [:date] ":method :url HTTP/:http-version" :status :res[content-length] :response-time ms ":referrer" ":user-agent" [trace=:trace]'
);
