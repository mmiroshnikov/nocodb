import type { Knex } from 'knex';

// Stub migration — schema changes were applied by official Docker image (EE).
// This file exists to satisfy knex validateMigrationList for CE fork deploys.
const up = async (_knex: Knex) => {};
const down = async (_knex: Knex) => {};

export { up, down };
