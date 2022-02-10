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

import Joi, { Schema, ValidationError } from "@hapi/joi";
import { BadRequest } from "http-errors";

export const parseInput = <T = any>(
  schema: Schema,
  payload: any,
  options: { transform?: (validatedPayload: any) => T } = {}
): T => {
  const { transform } = options;
  try {
    const validatedPayload = Joi.attempt(payload, schema, {
      abortEarly: false,
    });
    return transform ? transform(validatedPayload) : validatedPayload;
  } catch (error: any) {
    const report: ValidationError = error as ValidationError;
    throw new BadRequest({
      // We only want to expose the message and path, so ignore the other fields
      validation: report.details.map(({ message, path }) => ({
        message,
        path,
      })),
    } as any);
  }
};
