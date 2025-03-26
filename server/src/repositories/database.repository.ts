import { Injectable } from '@nestjs/common';
import AsyncLock from 'async-lock';
import { Kysely, sql, Transaction } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import semver from 'semver';
import {
  EXTENSION_NAMES,
  POSTGRES_VERSION_RANGE,
  VECTOR_VERSION_RANGE,
  VECTORCHORD_VERSION_RANGE,
  VECTORS_VERSION_RANGE,
} from 'src/constants';
import { DB } from 'src/db';
import { GenerateSql } from 'src/decorators';
import { DatabaseExtension, DatabaseLock, VectorIndex } from 'src/enum';
import { ConfigRepository } from 'src/repositories/config.repository';
import { LoggingRepository } from 'src/repositories/logging.repository';
import { ExtensionVersion, VectorExtension, VectorUpdateResult } from 'src/types';
import { isValidInteger } from 'src/validation';
import { DataSource } from 'typeorm';

export function createVectorIndex(vectorExtension: VectorExtension, tableName: string, indexName: string): string {
  switch (vectorExtension) {
    case DatabaseExtension.VECTORCHORD:
      return `
        CREATE INDEX IF NOT EXISTS ${indexName} ON ${tableName} USING vchordrq (embedding vector_cosine_ops) WITH (options = $$
        residual_quantization = false
        [build.internal]
        lists = [1000]
        spherical_centroids = true
        $$)`;
    case DatabaseExtension.VECTORS:
      return `
        CREATE INDEX IF NOT EXISTS ${indexName} ON ${tableName} USING vectors (embedding vector_cos_ops) WITH (options = $$
        [indexing.hnsw]
        m = 16
        ef_construction = 300
        $$)`;
    case DatabaseExtension.VECTOR:
      return `
        CREATE INDEX IF NOT EXISTS ${indexName}
        ON ${tableName}
        USING hnsw (embedding vector_cosine_ops)`;
    default:
      throw new Error(`Unsupported vector extension: '${vectorExtension}'`);
  }
}

@Injectable()
export class DatabaseRepository {
  private vectorExtension: VectorExtension;
  private readonly asyncLock = new AsyncLock();

  constructor(
    @InjectKysely() private db: Kysely<DB>,
    private logger: LoggingRepository,
    private configRepository: ConfigRepository,
  ) {
    this.vectorExtension = configRepository.getEnv().database.vectorExtension;
    this.logger.setContext(DatabaseRepository.name);
  }

  async shutdown() {
    await this.db.destroy();
  }

  @GenerateSql({ params: [DatabaseExtension.VECTORS] })
  async getExtensionVersion(extension: DatabaseExtension): Promise<ExtensionVersion> {
    const { rows } = await sql<ExtensionVersion>`
      SELECT default_version as "availableVersion", installed_version as "installedVersion"
      FROM pg_available_extensions
      WHERE name = ${extension}
    `.execute(this.db);
    return rows[0] ?? { availableVersion: null, installedVersion: null };
  }

  getExtensionVersionRange(extension: VectorExtension): string {
    switch (extension) {
      case DatabaseExtension.VECTORCHORD:
        return VECTORCHORD_VERSION_RANGE;
      case DatabaseExtension.VECTORS:
        return VECTORS_VERSION_RANGE;
      case DatabaseExtension.VECTOR:
        return VECTOR_VERSION_RANGE;
      default:
        throw new Error(`Unsupported vector extension: '${extension}'`);
    }
  }

  @GenerateSql()
  async getPostgresVersion(): Promise<string> {
    const { rows } = await sql<{ server_version: string }>`SHOW server_version`.execute(this.db);
    return rows[0].server_version;
  }

  getPostgresVersionRange(): string {
    return POSTGRES_VERSION_RANGE;
  }

  async createExtension(extension: DatabaseExtension): Promise<void> {
    await sql`CREATE EXTENSION IF NOT EXISTS ${sql.raw(extension)} CASCADE`.execute(this.db);
  }

  async updateVectorExtension(extension: VectorExtension, targetVersion?: string): Promise<VectorUpdateResult> {
    const { availableVersion, installedVersion } = await this.getExtensionVersion(extension);
    if (!installedVersion) {
      throw new Error(`${EXTENSION_NAMES[extension]} extension is not installed`);
    }

    if (!availableVersion) {
      throw new Error(`No available version for ${EXTENSION_NAMES[extension]} extension`);
    }
    targetVersion ??= availableVersion;

    const isVectors = extension === DatabaseExtension.VECTORS;
    let restartRequired = false;
    await this.db.transaction().execute(async (tx) => {
      await this.setSearchPath(tx);

      await sql`ALTER EXTENSION ${sql.raw(extension)} UPDATE TO ${sql.lit(targetVersion)}`.execute(tx);

      const diff = semver.diff(installedVersion, targetVersion);
      if (isVectors && diff && ['minor', 'major'].includes(diff)) {
        await sql`SELECT pgvectors_upgrade()`.execute(tx);
        restartRequired = true;
      } else {
        await Promise.all([this.reindex(VectorIndex.CLIP), this.reindex(VectorIndex.FACE)]);
      }
    });

    return { restartRequired };
  }

  async reindex(index: VectorIndex): Promise<void> {
    this.logger.log(`Reindexing ${index}`);
    const table = await this.getIndexTable(index);
    if (!table) {
      this.logger.warn(`Could not find table for index ${index}`);
      return;
    }
    const dimSize = await this.getDimSize(table);
    await this.db.transaction().execute(async (tx) => {
      await sql`DROP INDEX IF EXISTS ${sql.raw(index)}`.execute(this.db);
      await sql`ALTER TABLE ${sql.raw(table)} ALTER COLUMN embedding SET DATA TYPE real[]`.execute(tx);
      const schema = this.vectorExtension === DatabaseExtension.VECTORS ? 'vectors.' : '';
      await sql`
        ALTER TABLE ${sql.raw(table)}
        ALTER COLUMN embedding
        SET DATA TYPE ${sql.raw(schema)}vector(${sql.raw(String(dimSize))})`.execute(tx);
      await sql.raw(createVectorIndex(this.vectorExtension, table, index)).execute(tx);
    });
  }

  @GenerateSql({ params: [VectorIndex.CLIP] })
  async shouldReindex(names: VectorIndex[]): Promise<boolean[]> {
    const { rows } = await sql<{
      indexdef: string;
      indexname: string;
    }>`SELECT indexdef, indexname FROM pg_indexes WHERE indexname = ANY(ARRAY[${names}])`.execute(this.db);

    let keyword: string;
    switch (this.vectorExtension) {
      case DatabaseExtension.VECTOR:
        keyword = 'using hnsw';
        break;
      case DatabaseExtension.VECTORCHORD:
        keyword = 'using vchordrq';
        break;
      case DatabaseExtension.VECTORS:
        keyword = 'using vectors';
        break;
      default:
        throw new Error(`Unsupported vector extension: '${this.vectorExtension}'`);
    }

    return names.map(
      (name) =>
        !rows
          .find((index) => index.indexname === name)
          ?.indexdef.toLowerCase()
          .includes(keyword),
    );
  }

  private async setSearchPath(tx: Transaction<DB>): Promise<void> {
    await sql`SET search_path TO "$user", public, vectors`.execute(tx);
  }

  private async getIndexTable(index: VectorIndex): Promise<string | null> {
    const { rows } = await sql<{
      relname: string | null;
    }>`SELECT relname FROM pg_stat_all_indexes WHERE indexrelname = ${index}`.execute(this.db);
    return rows[0]?.relname;
  }

  private async getDimSize(table: string, column = 'embedding'): Promise<number> {
    const { rows } = await sql<{ dimsize: number }>`
      SELECT atttypmod as dimsize
      FROM pg_attribute f
        JOIN pg_class c ON c.oid = f.attrelid
      WHERE c.relkind = 'r'::char
        AND f.attnum > 0
        AND c.relname = ${table}::text
        AND f.attname = ${column}::text
    `.execute(this.db);

    const dimSize = rows[0]?.dimsize;
    if (!isValidInteger(dimSize, { min: 1, max: 2 ** 16 })) {
      throw new Error(`Could not retrieve dimension size`);
    }
    return dimSize;
  }

  async runMigrations(options?: { transaction?: 'all' | 'none' | 'each' }): Promise<void> {
    const { database } = this.configRepository.getEnv();
    const dataSource = new DataSource(database.config.typeorm);

    this.logger.log('Running migrations, this may take a while');

    await dataSource.initialize();
    await dataSource.runMigrations(options);
    await dataSource.destroy();
  }

  async withLock<R>(lock: DatabaseLock, callback: () => Promise<R>): Promise<R> {
    let res;
    await this.asyncLock.acquire(DatabaseLock[lock], async () => {
      await this.db.connection().execute(async (connection) => {
        try {
          await this.acquireLock(lock, connection);
          res = await callback();
        } finally {
          await this.releaseLock(lock, connection);
        }
      });
    });

    return res as R;
  }

  tryLock(lock: DatabaseLock): Promise<boolean> {
    return this.db.connection().execute(async (connection) => this.acquireTryLock(lock, connection));
  }

  isBusy(lock: DatabaseLock): boolean {
    return this.asyncLock.isBusy(DatabaseLock[lock]);
  }

  async wait(lock: DatabaseLock): Promise<void> {
    await this.asyncLock.acquire(DatabaseLock[lock], () => {});
  }

  private async acquireLock(lock: DatabaseLock, connection: Kysely<DB>): Promise<void> {
    await sql`SELECT pg_advisory_lock(${lock})`.execute(connection);
  }

  private async acquireTryLock(lock: DatabaseLock, connection: Kysely<DB>): Promise<boolean> {
    const { rows } = await sql<{
      pg_try_advisory_lock: boolean;
    }>`SELECT pg_try_advisory_lock(${lock})`.execute(connection);
    return rows[0].pg_try_advisory_lock;
  }

  private async releaseLock(lock: DatabaseLock, connection: Kysely<DB>): Promise<void> {
    await sql`SELECT pg_advisory_unlock(${lock})`.execute(connection);
  }
}
