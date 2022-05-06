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

import R from "ramda";
import crypto, { createHash } from "crypto";
import os from "os";
import path from "path";

const shuffler = R.curry(function (random, list) {
  var idx = -1;
  var len = list.length;
  var position;
  var result = [];
  while (++idx < len) {
    position = Math.floor((idx + 1) * random());
    result[idx] = result[position];
    result[position] = list[idx];
  }
  return result;
});

export const shuffle = shuffler(Math.random);

export function fromB64Url(input) {
  const paddingLength = input.length % 4 == 0 ? 0 : 4 - (input.length % 4);

  const base64 = input
    .replace(/\-/g, "+")
    .replace(/\_/g, "/")
    .concat("=".repeat(paddingLength));

  return Buffer.from(base64, "base64");
}

export function toB64url(buffer) {
  return buffer
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/\=/g, "");
}

export const getTagValue = (tags, name) => {
  const contentTypeTag = tags.find((tag) => {
    try {
      return (
        fromB64Url(tag.name).toString().toLowerCase() == name.toLowerCase()
      );
    } catch (error) {
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

export function sha256B64Url(input /* Buffer */) {
  return toB64url(createHash("sha256").update(input).digest());
}

export const isValidUTF8 = function (buffer) {
  return Buffer.compare(Buffer.from(buffer.toString(), "utf8"), buffer) === 0;
};

export const utf8DecodeTag = (tag) => {
  let name = undefined;
  let value = undefined;
  try {
    const nameBuffer = fromB64Url(tag.name);
    if (isValidUTF8(nameBuffer)) {
      name = nameBuffer.toString("utf8");
    }
    const valueBuffer = fromB64Url(tag.value);
    if (isValidUTF8(valueBuffer)) {
      value = valueBuffer.toString("utf8");
    }
  } catch (error) {}
  return {
    name,
    value,
  };
};

export const txTagsToRows = (tx_id, tags) => {
  return (
    tags
      .map((tag, index) => {
        const { name, value } = utf8DecodeTag(tag);

        return {
          tx_id,
          index,
          name,
          value,
        };
      })
      // The name and values columns are indexed, so ignore any values that are too large.
      // Postgres will throw an error otherwise: index row size 5088 exceeds maximum 2712 for index "tags_name_value"
      .filter(
        ({ name, value }) => (name.length || 0) + (value.length || 0) < 2712
      )
  );
};

export function tmpFile(prefix, suffix, tmpdir) {
  prefix = typeof prefix !== "undefined" ? prefix : "tmp.";
  suffix = typeof suffix !== "undefined" ? suffix : "";
  tmpdir = tmpdir ? tmpdir : os.tmpdir();
  return path.join(
    tmpdir,
    prefix + crypto.randomBytes(16).toString("hex") + suffix
  );
}
