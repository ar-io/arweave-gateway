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

import { TransactionHeader, utf8DecodeTag, Tag } from "../../../lib/arweave";
import { query } from "../../../database/transaction-db";

type Resolvers = any;

type ResolverFn = (parent: any, args: any, ctx: any) => Promise<any>;
interface ResolverMap {
  [field: string]: ResolverFn;
}

export const defaultMaxResults = 5000;

export const resolvers: Resolvers = {
  Query: {
    transaction: async (
      parent: any,
      { id }: Record<any, any>,
      context: any
    ) => {
      return query(context.connection, {
        id,
      });
    },
    transactions: async (
      parent: any,
      { to, from, tags }: Record<any, any>,
      context: any
    ) => {
      const sqlQuery = query(context.connection, {
        limit: defaultMaxResults,
        to,
        from,
        tags: (tags || []).map((tag: Tag) => {
          return {
            name: tag.name,
            values: [tag.value],
          };
        }),
      });

      // console.log(sqlQuery.toSQL());

      const results = (await sqlQuery) as TransactionHeader[];

      return results.map(({ id, tags = [] }: Partial<TransactionHeader>) => {
        return {
          id,
          tags: tags.map(utf8DecodeTag),
        };
      });
    },
  },
  Transaction: {
    linkedFromTransactions: async (
      parent: any,
      { byForeignTag, to, from, tags }: Record<any, any>,
      context: any
    ) => {
      const sqlQuery = query(context.connection, {
        limit: defaultMaxResults,
        to,
        from,
        tags: ((tags as any[]) || []).concat({
          name: byForeignTag,
          values: [parent.id],
        }),
      });

      // console.log(sqlQuery.toSQL());

      const results = (await sqlQuery) as TransactionHeader[];

      return results.map(({ id, tags = [] }: Partial<TransactionHeader>) => {
        return {
          id,
          tags: tags.map(utf8DecodeTag),
        };
      });
    },
    countLinkedFromTransactions: async (
      parent: any,
      { byForeignTag, to, from, tags }: Record<any, any>,
      context: any
    ) => {
      const sqlQuery = query(context.connection, {
        limit: defaultMaxResults,
        to,
        from,
        tags: ((tags as any[]) || []).concat({
          name: byForeignTag,
          values: [parent.id],
        }),
        select: [],
      }).count();

      // console.log(sqlQuery.toSQL());

      return (await sqlQuery.first()).count;
    },
  },
};
