import { query } from './index.js';

export async function initializeArchive() {
  await query(`CREATE TABLE IF NOT EXISTS locations_archive (LIKE locations INCLUDING ALL)`);
  console.log('✓ locations_archive table ready');
}
