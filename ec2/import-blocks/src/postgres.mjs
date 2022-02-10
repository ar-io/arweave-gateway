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

import "./env.mjs";
import AWS from "aws-sdk";
import knex from "knex";

const rds = new AWS.RDS();

const awsSM = new AWS.SecretsManager({
  region: process.env.AWS_REGION,
});

function getSecretValue(secretName) {
  return new Promise((resolve, reject) => {
    awsSM.getSecretValue({ SecretId: secretName }, function (err, data) {
      if (err) {
        if (err.code === "DecryptionFailureException")
          // Secrets Manager can't decrypt the protected secret text using the provided KMS key.
          // Deal with the exception here, and/or rethrow at your discretion.
          reject(err);
        else if (err.code === "InternalServiceErrorException")
          // An error occurred on the server side.
          // Deal with the exception here, and/or rethrow at your discretion.
          reject(err);
        else if (err.code === "InvalidParameterException")
          // You provided an invalid value for a parameter.
          // Deal with the exception here, and/or rethrow at your discretion.
          reject(err);
        else if (err.code === "InvalidRequestException")
          // You provided a parameter value that is not valid for the current state of the resource.
          // Deal with the exception here, and/or rethrow at your discretion.
          reject(err);
        else if (err.code === "ResourceNotFoundException")
          // We can't find the resource that you asked for.
          // Deal with the exception here, and/or rethrow at your discretion.
          reject(err);
        else reject(err);
      } else {
        resolve(data.SecretString);
      }
    });
  });
}

export async function createDbClient({ user }) {
  const rdsReadRoleSecret = {
    username: "",
    password: "",
    url: process.env.ARWEAVE_DB_READ_HOST,
  };
  const rdsWriteRoleSecret = {
    username: "",
    password: "",
    url: process.env.ARWEAVE_DB_WRITE_HOST,
  };

  try {
    const rdsProxySecretRead = JSON.parse(await getSecretValue("read"));
    rdsReadRoleSecret.username = rdsProxySecretRead.username;
    rdsReadRoleSecret.password = rdsProxySecretRead.password;
  } catch (error) {
    console.error(error);
  }

  try {
    const rdsProxySecretWrite = JSON.parse(await getSecretValue("write"));
    rdsWriteRoleSecret.username = rdsProxySecretWrite.username;
    rdsWriteRoleSecret.password = rdsProxySecretWrite.password;
  } catch (error) {
    console.error(error);
  }

  const roleSecret = user === "read" ? rdsReadRoleSecret : rdsWriteRoleSecret;

  return await knex({
    client: "pg",
    pool: {
      min: 1,
      max: 2,
      acquireTimeoutMillis: 20000,
      idleTimeoutMillis: 30000,
      reapIntervalMillis: 40000,
    },
    connection: {
      host: roleSecret.url,
      user: roleSecret.username,
      database: "arweave",
      ssl: false,
      password: roleSecret.password,
      expirationChecker: () => true,
    },
  });
}
