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

import { TransactionHeader, Block, ChunkHeader } from "../lib/arweave";

export type DataFormatVersion = 1.0 | 2.0 | 2.1;
export interface DispatchTx {
  tx: TransactionHeader;
  data_size: number;
  data_format: DataFormatVersion;
}

export interface ImportChunk {
  header: ChunkHeader;
  size: number;
}

export interface ExportChunk {
  header: ChunkHeader;
  size: number;
}

export interface ImportTx {
  id?: string;
  tx?: TransactionHeader;
}

export interface ImportBlock {
  source: string;
  block: Block;
}

export interface ImportBundle {
  id?: string;
  header?: TransactionHeader;
}
