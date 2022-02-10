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

import { SNS } from "aws-sdk";

const topicArn = process.env.ARWEAVE_SNS_EVENTS_ARN!;
const sns = new SNS();

export const publish = async <T>(message: T) => {
  await sns
    .publish({
      TopicArn: topicArn,
      Message: JSON.stringify(message),
    })
    .promise();
};
