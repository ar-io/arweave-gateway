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

import "./env";
import express from "express";
import helmet from "helmet";
import {
  initConnectionPool,
  releaseConnectionPool,
} from "../database/postgres";
import log from "../lib/log";
import { handler as corsMiddleware } from "./middleware/cors";
import { handler as jsonBodyMiddleware } from "./middleware/json-body";
import {
  configureRequestLogging,
  handler as requestLoggingMiddleware,
} from "./middleware/request-log";
import { handler as sandboxMiddleware } from "./middleware/sandbox";
import { handler as arqlHandler } from "./routes/arql";
import { handler as dataHandler } from "./routes/data";
import { apolloServer } from "./routes/graphql";
import { apolloServer as apolloServerV2 } from "./routes/graphql-v2";
import { handler as healthHandler } from "./routes/health";
import { handler as newTxHandler } from "./routes/new-tx";
import { handler as newChunkHandler } from "./routes/new-chunk";
import { handler as proxyHandler } from "./routes/proxy";
import { handler as webhookHandler } from "./routes/webhooks";

import { logMiddleware } from "./middleware/log.middleware";

require("express-async-errors");

initConnectionPool("read", { min: 1, max: 100 });

const app = express();

const dataPathRegex =
  /^\/?([a-zA-Z0-9-_]{43})\/?$|^\/?([a-zA-Z0-9-_]{43})\/(.*)$/i;

const port = process.env.APP_PORT;

app.set("trust proxy", 1);

// Global middleware

app.use(configureRequestLogging);

// app.use(requestLoggingMiddleware);

app.use(helmet.hidePoweredBy());

app.use(corsMiddleware);

app.use(sandboxMiddleware);
app.use(logMiddleware);

app.get("/favicon.ico", (req, res) => {
  res.status(204).end();
});

app.options("/tx", (req, res) => {
  res.send("OK").end();
});

app.post("/tx", jsonBodyMiddleware, newTxHandler);

app.post("/chunk", jsonBodyMiddleware, newChunkHandler);

app.options("/chunk", (req, res) => {
  res.send("OK").end();
});

app.post("/webhook", jsonBodyMiddleware, webhookHandler);

app.post("/arql", jsonBodyMiddleware, arqlHandler);

app.get("/health", healthHandler);

app.get(dataPathRegex, dataHandler);

const apolloServerInstanceArql = apolloServer();

const apolloServerInstanceGql = apolloServerV2({ introspection: true });

Promise.all([
  apolloServerInstanceArql.start(),
  apolloServerInstanceGql.start(),
]).then(() => {
  apolloServerInstanceArql.applyMiddleware({ app, path: "/arql" });
  apolloServerInstanceGql.applyMiddleware({
    app,
    path: "/graphql",
  });
  log.info(`[app] Started on http://localhost:${port}`);
  const server = app.listen(port, () => {
    try {
      log.info(
        `[${new Date().toLocaleString()}] Using version `,
        require("../../package.json").version
      );
    } catch (e) {
      log.info(`'Unable to retrieve the package version.'`);
    }

    // The apollo middleare *must* be applied after the standard arql handler
    // as arql is the default behaviour. If the graphql handler
    // is invoked first it will emit an error if it received an arql request.
  });

  server.keepAliveTimeout = 120 * 1000;
  server.headersTimeout = 120 * 1000;
  app.get("*", proxyHandler);
});

// console.log([server.headersTimeout]);

process.on("SIGINT", function () {
  log.info("\nGracefully shutting down from SIGINT");
  releaseConnectionPool().then(() => {
    log.info("[app] DB connections closed");
    process.exit(1);
  });
});
