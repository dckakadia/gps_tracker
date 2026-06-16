import pkg from 'pg';
import dotenv from 'dotenv';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.join(__dirname, '..', '.env') });

const { Pool } = pkg;
const useInMemoryDb = process.env.USE_IN_MEMORY_DB === 'true' || !process.env.DATABASE_URL;
let pool;
let isInMemoryDb = false;

function sanitizeSql(sql) {
  const lines = sql.split(/\r?\n/);
  return lines
    .filter((line) => {
      const trimmed = line.trim();
      if (!trimmed) return true;
      if (trimmed.startsWith('\\')) return false;
      if (/^CREATE EXTENSION IF NOT EXISTS postgis;?$/i.test(trimmed)) return false;
      return true;
    })
    .join('\n');
}

if (useInMemoryDb) {
  console.log('Using in-memory pg-mem database');
  const { newDb } = await import('pg-mem');
  const db = newDb();
  const pg = db.adapters.createPg();
  pool = new pg.Pool();
  isInMemoryDb = true;
} else {
  console.log('Using PostgreSQL database');
  pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,
    min: 2,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000,
  });
  pool.on('error', (err) => {
    console.error('PostgreSQL client error', err);
  });
}

export async function initializeDatabase() {
  if (!isInMemoryDb) return;

  const schemaPath = path.join(__dirname, '..', 'db', 'schema.sql');
  if (!fs.existsSync(schemaPath)) {
    console.warn('Schema file not found, skipping in-memory DB schema load');
    return;
  }

  let sql = fs.readFileSync(schemaPath, 'utf8');
  sql = sanitizeSql(sql);
  if (!sql.trim()) return;

  try {
    await pool.query(sql);
    console.log('✓ In-memory database schema loaded');
  } catch (err) {
    console.error('Failed to load in-memory schema:', err.message);
    throw err;
  }
}

export async function query(text, params) {
  const client = await pool.connect();
  try {
    const res = await client.query(text, params);
    return res;
  } finally {
    client.release();
  }
}

export default pool;
