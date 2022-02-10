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

import { Transform } from "stream";

export class Base64DUrlecode extends Transform {
  protected extra: string;
  protected bytesProcessed: number;

  constructor() {
    super({ decodeStrings: false, objectMode: false });
    this.extra = "";
    this.bytesProcessed = 0;
  }

  _transform(chunk: Buffer, encoding: any, cb: Function) {
    let conbinedChunk =
      this.extra +
      chunk
        .toString("base64")
        .replace(/\-/g, "+")
        .replace(/\_/g, "/")
        .replace(/(\r\n|\n|\r)/gm, "");

    this.bytesProcessed += chunk.byteLength;

    const remaining = chunk.length % 4;

    this.extra = conbinedChunk.slice(chunk.length - remaining);

    const buf = Buffer.from(
      conbinedChunk.slice(0, chunk.length - remaining),
      "base64"
    );
    this.push(buf);
    cb();
  }

  _flush(cb: Function) {
    if (this.extra.length) {
      this.push(Buffer.from(this.extra, "base64"));
    }

    cb();
  }
}
