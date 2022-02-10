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

import { ApolloServer, ApolloServerExpressConfig } from "apollo-server-express";
import { ApolloServerPluginLandingPageDisabled } from "apollo-server-core";
import { getConnectionPool } from "../../../database/postgres";
import { resolvers } from "./resolvers";
import { typeDefs } from "./schema";

const apolloServer = (opts: ApolloServerExpressConfig = {}) => {
  return new ApolloServer({
    typeDefs,
    resolvers,
    debug: false,
    plugins: [ApolloServerPluginLandingPageDisabled()],
    context: () => {
      console.log("context...");
      return {
        connection: getConnectionPool("read"),
      };
    },
    ...opts,
  });
};

export { apolloServer };
