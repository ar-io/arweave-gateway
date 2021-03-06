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

import { base32 } from "rfc4648";
import { createHash } from "crypto";
import { Readable, PassThrough } from "stream";
import { Base64DUrlecode } from "./base64url-stream";
import Ar from "arweave/node/ar";

const ar = new Ar();

export type Base64EncodedString = string;
export type Base64UrlEncodedString = string;
export type WinstonString = string;
export type ArString = string;
export type ISO8601DateTimeString = string;

export const sha256 = (buffer: Buffer): Buffer => {
  return createHash("sha256").update(buffer).digest();
};

export function toB64url(buffer: Buffer): Base64UrlEncodedString {
  return buffer
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/\=/g, "");
}

export function fromB64Url(input: Base64UrlEncodedString): Buffer {
  const paddingLength = input.length % 4 == 0 ? 0 : 4 - (input.length % 4);

  const base64 = input
    .replace(/\-/g, "+")
    .replace(/\_/g, "/")
    .concat("=".repeat(paddingLength));

  return Buffer.from(base64, "base64");
}

export function fromB32(input: string): Buffer {
  return Buffer.from(
    base32.parse(input, {
      loose: true,
    })
  );
}

export function toB32(input: Buffer): string {
  return base32.stringify(input, { pad: false }).toLowerCase();
}

export function sha256B64Url(input: Buffer): string {
  return toB64url(createHash("sha256").update(input).digest());
}

export const streamToBuffer = async (stream: Readable): Promise<Buffer> => {
  let buffer = Buffer.alloc(0);
  return new Promise((resolve, reject) => {
    stream.on("data", (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
    });

    stream.on("end", () => {
      resolve(buffer);
    });
  });
};

export const streamToString = async (stream: Readable): Promise<string> => {
  return (await streamToBuffer(stream)).toString("utf-8");
};

export const bufferToJson = <T = any | undefined>(input: Buffer): T => {
  return JSON.parse(input.toString("utf8"));
};

export const jsonToBuffer = (input: object): Buffer => {
  return Buffer.from(JSON.stringify(input));
};

export const streamToJson = async <T = any | undefined>(
  input: Readable | string
): Promise<T> => {
  return typeof input === "string"
    ? JSON.parse(input)
    : bufferToJson<T>(await streamToBuffer(input));
};

export const isValidUTF8 = function (buffer: Buffer) {
  return Buffer.compare(Buffer.from(buffer.toString(), "utf8"), buffer) === 0;
};

export const streamDecoderb64url = (readable: Readable): Readable => {
  const outputStream = new PassThrough({ objectMode: false });

  const decoder = new Base64DUrlecode();

  readable.pipe(decoder).pipe(outputStream);

  return outputStream;
};
export const bufferToStream = (buffer: Buffer) => {
  return new Readable({
    objectMode: false,
    read() {
      this.push(buffer);
      this.push(null);
    },
  });
};

export const winstonToAr = (amount: string) => {
  return ar.winstonToAr(amount);
};

export const arToWinston = (amount: string) => {
  return ar.arToWinston(amount);
};
