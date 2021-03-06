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

import { SQS } from "aws-sdk";
import { SQSEvent, SQSHandler, SQSRecord } from "aws-lambda";
import log from "../lib/log";

type QueueType =
  | "dispatch-txs"
  | "import-txs"
  | "import-blocks"
  | "import-bundles"
  | "import-chunks"
  | "export-chunks";
type SQSQueueUrl = string;
type MessageGroup = string;
type MessageDeduplicationId = string;
type DelaySeconds = number;
interface HandlerContext {
  sqsMessage?: SQSRecord;
}

const queues: { [key in QueueType]: SQSQueueUrl } = {
  "dispatch-txs": process.env.ARWEAVE_SQS_DISPATCH_TXS_URL!,
  "import-chunks": process.env.ARWEAVE_SQS_IMPORT_CHUNKS_URL!,
  "export-chunks": process.env.ARWEAVE_SQS_EXPORT_CHUNKS_URL!,
  "import-txs": process.env.ARWEAVE_SQS_IMPORT_TXS_URL!,
  "import-blocks": process.env.ARWEAVE_SQS_IMPORT_BLOCKS_URL!,
  "import-bundles": process.env.ARWEAVE_SQS_IMPORT_BUNDLES_URL!,
};

const sqs = new SQS({
  maxRetries: 3,
  httpOptions: { timeout: 5000, connectTimeout: 5000 },
});

export const getQueueUrl = (type: QueueType): SQSQueueUrl => {
  return queues[type];
};

function* chunks(arr: any[], n: number) {
  for (let i = 0; i < arr.length; i += n) {
    yield arr.slice(i, i + n);
  }
}

export const enqueue = async <MessageType extends object>(
  queueUrl: SQSQueueUrl,
  message: MessageType,
  options?:
    | {
        messagegroup?: MessageGroup;
        deduplicationId?: MessageDeduplicationId;
        delaySeconds?: DelaySeconds;
      }
    | undefined
) => {
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

export const enqueueBatch = async <MessageType extends object>(
  queueUrl: SQSQueueUrl,
  messages: {
    id: string;
    message: MessageType;
    messagegroup?: MessageGroup;
    deduplicationId?: MessageDeduplicationId;
  }[]
) => {
  for (const messageChnk of chunks(messages, 10)) {
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

const deleteMessages = async (
  queueUrl: SQSQueueUrl,
  receipts: { Id: string; ReceiptHandle: string }[]
) => {
  if (!receipts.length) {
    return;
  }
  for (const receiptChnk of chunks(receipts, 10)) {
    await sqs
      .deleteMessageBatch({
        QueueUrl: queueUrl,
        Entries: receiptChnk,
      })
      .promise();
  }
};

export const createQueueHandler = <MessageType>(
  queueUrl: SQSQueueUrl,
  handler: (message: MessageType, sqsMessage: SQSRecord) => Promise<void>,
  hooks?: {
    before?: () => Promise<void>;
    after?: () => Promise<void>;
  }
): SQSHandler => {
  return async (event: SQSEvent) => {
    if (hooks && hooks.before) {
      await hooks.before();
    }
    try {
      if (!event) {
        log.info(`[sqs-handler] invalid SQS messages received`, { event });
        throw new Error("Queue handler: invalid SQS messages received");
      }

      log.info(`[sqs-handler] received messages`, {
        count: event.Records.length,
        source: event.Records[0].eventSourceARN,
      });

      const receipts: { Id: string; ReceiptHandle: string }[] = [];

      const errors: Error[] = [];

      await Promise.all(
        event.Records.map(async (sqsMessage) => {
          log.info(`[sqs-handler] processing message`, { sqsMessage });
          try {
            await handler(
              JSON.parse(sqsMessage.body) as MessageType,
              sqsMessage
            );
            receipts.push({
              Id: sqsMessage.messageId,
              ReceiptHandle: sqsMessage.receiptHandle,
            });
          } catch (error: any) {
            log.error(`[sqs-handler] error processing message`, {
              event,
              error,
            });
            errors.push(error);
          }
        })
      );

      log.info(`[sqs-handler] queue handler complete`, {
        successful: receipts.length,
        failed: event.Records.length - receipts.length,
      });

      await deleteMessages(queueUrl, receipts);

      if (receipts.length !== event.Records.length) {
        log.warn(
          `Failed to process ${event.Records.length - receipts.length} messages`
        );

        // If all the errors are the same then fail the whole queue with a more specific error mesage
        if (errors.every((error) => error.message == errors[0].message)) {
          throw new Error(
            `Failed to process SQS messages: ${errors[0].message}`
          );
        }

        throw new Error(`Failed to process SQS messages`);
      }
    } finally {
      if (hooks && hooks.after) {
        await hooks.after();
      }
    }
  };
};
