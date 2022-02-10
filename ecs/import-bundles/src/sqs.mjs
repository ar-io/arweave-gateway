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

import AWS from "aws-sdk";

const sqs = new AWS.SQS({
  maxRetries: 3,
  httpOptions: { timeout: 5000, connectTimeout: 5000 },
});

function* chunk(arr, n) {
  for (let i = 0; i < arr.length; i += n) {
    yield arr.slice(i, i + n);
  }
}

export const enqueue = async (queueUrl, message, options) => {
  if (!queueUrl) {
    throw new Error(`Queue URL undefined`);
  }

  await sqs
    .sendMessage({
      QueueUrl: queueUrl,
      MessageBody: JSON.stringify(message),
      MessageGroupId: options && options.messagegroup,
      MessageDeduplicationId: options && options.deduplicationId,
      DelaySeconds: options && options.delaySeconds,
    })
    .promise();
};

export const enqueueBatch = async (queueUrl, messages) => {
  for (const messageChnk of chunk(messages, 10)) {
    await sqs
      .sendMessageBatch({
        QueueUrl: queueUrl,
        Entries: messageChnk.map((message) => {
          return {
            Id: message.id,
            MessageBody: JSON.stringify(message),
            MessageGroupId: message.messagegroup,
            MessageDeduplicationId: message.deduplicationId,
          };
        }),
      })
      .promise();
  }
};
