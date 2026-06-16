import fs from 'fs';
import path from 'path';
import pool from './index.js';

function sanitizeSql(sql) {
  const lines = sql.split(/\r?\n/);
  const cleaned = lines.filter((line) => {
    const trimmed = line.trim();
    if (!trimmed) return true;
    if (trimmed.startsWith('\\')) return false;
    if (/^CREATE EXTENSION IF NOT EXISTS postgis;?$/i.test(trimmed)) return false;
    return true;
  });
  return cleaned.join('\n');
}

async function runSqlFile(filePath) {
  let sql = fs.readFileSync(filePath, 'utf8');
  if (!sql.trim()) return;
  sql = sanitizeSql(sql);
  console.log(`Running SQL file: ${path.basename(filePath)}`);
  try {
    await pool.query(sql);
  } catch (err) {
    const message = err && err.message ? err.message.toString() : '';
    if (filePath.endsWith('migration-001-add-username.sql') && message.includes('created_at')) {
      console.warn('Skipping index migration because locations.created_at does not exist');
      return;
    }
    throw err;
  }
}

async function main() {
  try {
    const root = path.join(path.dirname(new URL(import.meta.url).pathname), '..');
    const dbPath = path.join(root, 'db');
    // Run main schema
    await runSqlFile(path.join(dbPath, 'schema.sql'));

    // Run any explicit migrations
    const migrations = [
      path.join(dbPath, 'migration-001-add-username.sql'),
    ];
    for (const m of migrations) {
      if (fs.existsSync(m)) {
        await runSqlFile(m);
      }
    }

    try {
      await pool.query(`CREATE INDEX IF NOT EXISTS idx_locations_user_recorded_at ON locations(user_id, recorded_at DESC);`);
    } catch (err) {
      const message = err && err.message ? err.message.toString() : '';
      if (message.includes('recorded_at')) {
        console.warn('Skipping index creation because locations.recorded_at does not exist');
      } else {
        throw err;
      }
    }

    console.log('✓ Migrations completed');
    process.exit(0);
  } catch (err) {
    console.error('Migration failed', err);
    process.exit(1);
  }
}

main();
