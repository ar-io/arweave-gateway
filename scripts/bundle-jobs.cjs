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

const fs = require("fs");
const path = require("path");
const browserify = require("browserify");

const jobJs = process.argv[2];

const b = browserify([process.cwd() + "/dist/jobs/" + path.basename(jobJs)], {
  bare: true,
  node: true,
  noBuiltins: true,
  standalone: "global",
});

console.log(process.cwd() + "/dist/jobs/" + path.basename(jobJs));

const stream = fs.createWriteStream(
  path.resolve(process.cwd(), "./dist/jobs/") +
    "/" +
    path.basename(jobJs, ".js") +
    "-min.js"
);

const p = new Promise((r) => {
  stream.on("end", r);
});

b.exclude("pg-native");

b.bundle().pipe(stream);
