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

import { getTagValue } from "./utils.mjs";

export const isTxAns104 = (tx) => {
  return (
    getTagValue(tx.tags, "bundle-format") == "binary" &&
    getTagValue(tx.tags, "bundle-version") == "2.0.0"
  );
};

export const processAns102 = (tx) => {};

export const processAns104 = (tx) => {
  const iterable = (await processBundle(stream)) as any;
  const items = [];
  for await (const item of iterable) {
    items.push(item);
  }
  data = { items };
};
