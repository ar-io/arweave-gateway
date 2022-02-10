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

import { S3 } from "aws-sdk";
import log from "../lib/log";
import { Readable, PassThrough } from "stream";
import { ManagedUpload, Metadata } from "aws-sdk/clients/s3";
import { Tag } from "./arweave";
import fetch from "node-fetch";

export const buckets: { [key in BucketType]: string } = {
  "tx-data": process.env.ARWEAVE_S3_TX_DATA_BUCKET!,
};

type BucketType = "tx-data";

export type BucketObject = S3.GetObjectOutput;

export const s3 = new S3({
  httpOptions: { timeout: 30000, connectTimeout: 5000 },
  logger: console,
});

export const put = async (
  bucketType: BucketType,
  key: string,
  body: Buffer | Readable,
  { contentType, tags }: { contentType?: string; tags?: Tag[] }
) => {
  const bucket = buckets[bucketType];

  log.info(`[s3] uploading to bucket`, {
    bucket,
    key,
    type: contentType,
  });

  await s3
    .upload({
      Key: key,
      Bucket: bucket,
      Body: body,
      ContentType: contentType,
    })
    .promise();
};

export const putStream = async (
  bucketType: BucketType,
  key: string,
  {
    contentType,
    contentLength,
    tags,
  }: { contentType?: string; contentLength?: number; tags?: Tag[] }
): Promise<{ upload: ManagedUpload; stream: PassThrough }> => {
  const bucket = buckets[bucketType];

  log.info(`[s3] uploading to bucket`, {
    bucket,
    key,
    type: contentType,
  });

  const cacheStream = new PassThrough({
    objectMode: false,
    autoDestroy: true,
    highWaterMark: 512 * 1024,
    writableHighWaterMark: 512 * 1024,
  });

  const upload = await s3.upload(
    {
      Key: key,
      Bucket: bucket,
      Body: cacheStream,
      ContentType: contentType,
      ContentLength: contentLength,
    },
    { partSize: 10 * 1024 * 1024, queueSize: 2 },
    () => undefined
  );

  return { stream: cacheStream, upload };
};

export const get = async (
  bucketType: BucketType,
  key: string
): Promise<BucketObject> => {
  const bucket = buckets[bucketType];
  log.info(`[s3] getting data from bucket`, { bucket, key });
  return s3
    .getObject({
      Key: key,
      Bucket: bucket,
    })
    .promise();
};

export const getStream = async (
  bucketType: BucketType,
  key: string
): Promise<
  | {
      contentType?: string;
      contentLength: number;
      stream: Readable;
      tags?: Tag[];
    }
  | undefined
> => {
  log.info(`[s3] getting stream from bucket`, { key });

  const s3Response: any = await s3
    .headObject({
      Key: key,
      Bucket: buckets[bucketType],
    })
    .promise();

  const { ContentType, ContentLength } = s3Response;

  return {
    contentLength: ContentLength || 0,
    contentType: ContentType,
    tags: [],
    stream: s3
      .getObject({
        Key: key,
        Bucket: buckets[bucketType],
      })
      .createReadStream(),
  };
};

export const objectHeader = async (
  bucketType: BucketType,
  key: string
): Promise<{
  contentType?: string;
  contentLength: number;
  tags?: Tag[];
}> => {
  const bucket = buckets[bucketType];

  const { ContentType, ContentLength, Metadata } = await s3
    .headObject({
      Key: key,
      Bucket: bucket,
    })
    .promise();

  return {
    contentLength: ContentLength || 0,
    contentType: ContentType,
    tags: parseMetadataTags(Metadata || {}),
  };
};

const parseMetadataTags = (metadata: Metadata): Tag[] => {
  const rawTags = metadata["x-arweave-tags"];

  if (rawTags) {
    try {
      return JSON.parse(rawTags) as Tag[];
    } catch (error) {
      log.info(`[s3] error parsing tags`, { metadata, rawTags });
    }
  }

  return [];
};
