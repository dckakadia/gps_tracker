import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { logger } from '../logger.js';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);


const BACKUPS_DIR = path.join(__dirname, '..', 'backups');
const RCLONE_CONFIG = process.env.RCLONE_CONFIG || '/home/dckakadia/.config/rclone/rclone.conf';

// Ensure local backups directory exists
if (!fs.existsSync(BACKUPS_DIR)) {
  fs.mkdirSync(BACKUPS_DIR, { recursive: true });
}

// ── Parse a single rclone stats line ─────────────────────────────────────────
function parseRcloneStats(line) {
  const result = {};

  const transferMatch = line.match(
    /Transferred:\s+([\d.]+)\s*(\w+)\s*\/\s*([\d.]+)\s*(\w+),\s*(\d+)%/
  );
  if (transferMatch) {
    result.uploadedBytes = toBytes(parseFloat(transferMatch[1]), transferMatch[2]);
    result.totalBytes    = toBytes(parseFloat(transferMatch[3]), transferMatch[4]);
    result.percentage    = parseInt(transferMatch[5], 10);
  }

  const speedMatch = line.match(/([\d.]+)\s*(\w+)\/s/);
  if (speedMatch) {
    result.speedBytes = toBytes(parseFloat(speedMatch[1]), speedMatch[2]);
  }

  const etaMatch = line.match(/ETA\s+(\S+)/);
  if (etaMatch) {
    result.etaSeconds = parseEta(etaMatch[1]);
  }

  const fileMatch = line.match(/Transferred:\s+(\d+)\s*\/\s*(\d+),/);
  if (fileMatch) {
    result.processedFiles = parseInt(fileMatch[1], 10);
    result.totalFiles     = parseInt(fileMatch[2], 10);
  }

  return result;
}

function toBytes(value, unit) {
  const u = unit.toUpperCase();
  if (u === 'B'   || u === 'BYTES') return value;
  if (u === 'KIB' || u === 'KB')    return value * 1024;
  if (u === 'MIB' || u === 'MB')    return value * 1024 * 1024;
  if (u === 'GIB' || u === 'GB')    return value * 1024 * 1024 * 1024;
  if (u === 'TIB' || u === 'TB')    return value * 1024 * 1024 * 1024 * 1024;
  return value;
}

function parseEta(etaStr) {
  if (!etaStr || etaStr === '-' || etaStr === 'N/A') return null;
  let seconds = 0;
  const h = etaStr.match(/(\d+)h/);
  const m = etaStr.match(/(\d+)m/);
  const s = etaStr.match(/(\d+)s/);
  if (h) seconds += parseInt(h[1], 10) * 3600;
  if (m) seconds += parseInt(m[1], 10) * 60;
  if (s) seconds += parseInt(s[1], 10);
  return seconds;
}

function formatBytes(bytes) {
  if (!bytes || bytes < 1)           return '0 B';
  if (bytes < 1024)                  return `${bytes} B`;
  if (bytes < 1024 * 1024)           return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024)   return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

// ── Run rclone with spawn and stream progress ─────────────────────────────────
function runRcloneWithProgress(args, progressCallback) {
  return new Promise((resolve, reject) => {
    const proc = spawn('rclone', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = '';
    let lastStats = {};
    let buffer = '';

    const processChunk = (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split('\n');
      buffer = lines.pop();

      for (const line of lines) {
        const clean = line.replace(/\x1b\[[0-9;]*m/g, '').trim();
        if (!clean) continue;
        stderr += clean + '\n';

        const stats = parseRcloneStats(clean);
        if (Object.keys(stats).length > 0) {
          lastStats = { ...lastStats, ...stats };
          if (progressCallback) progressCallback({ ...lastStats });
        }
      }
    };

    proc.stdout.on('data', processChunk);
    proc.stderr.on('data', processChunk);

    proc.on('close', (code) => {
      if (code === 0) {
        resolve(lastStats);
      } else {
        const msg = stderr || `rclone exited with code ${code}`;
        if (msg.includes('invalid_grant') || msg.includes('Invalid JWT Signature')) {
          reject(new Error('Google Drive credentials are invalid or revoked. Please re-authenticate.'));
        } else {
          reject(new Error(`Rclone failed: ${msg.slice(0, 500)}`));
        }
      }
    });

    proc.on('error', (err) => {
      reject(new Error(`Failed to start rclone: ${err.message}`));
    });
  });
}

// ── Backup service ──────────────────────────────────────────────────────────
async function performBackup(io) {
  const emit = (stage, extra = {}) => {
    if (!io) return;
    io.emit('backup_progress', { stage, ...extra, ts: Date.now() });
  };

  const uploadsPath = path.join(__dirname, '..', 'uploads');
  const rcloneArgs = [
    '--config', RCLONE_CONFIG,
    '--stats', '2s',
    '--stats-one-line'
  ];

  const timestamp = new Date().toISOString();

  let dbDumpFile = null;
  try {
    // Create local JSON backup
    emit('Creating local backup...', { overallPct: 1, stageLabel: 'Stage 1 / 3' });
    const dateStr = new Date().toISOString().slice(0, 10);
    const backupFile = path.join(BACKUPS_DIR, `Backup_${dateStr}_${Date.now()}.json`);
    const backupData = { timestamp, type: 'database_backup' };
    fs.writeFileSync(backupFile, JSON.stringify(backupData, null, 2));

    // Stage 1: Dump PostgreSQL database
    emit('Dumping PostgreSQL database...', { overallPct: 2, stageLabel: 'Stage 1 / 3' });
    dbDumpFile = path.join(BACKUPS_DIR, `db_dump_${dateStr}_${Date.now()}.sql`);
    const databaseUrl = process.env.DATABASE_URL;

    if (!databaseUrl) {
      throw new Error('DATABASE_URL not set');
    }

    await new Promise((resolve, reject) => {
      const proc = spawn('pg_dump', ['--file', dbDumpFile, databaseUrl], { stdio: ['ignore', 'ignore', 'pipe'] });
      let stderr = '';

      const timeout = setTimeout(() => {
        proc.kill('SIGTERM');
        reject(new Error('pg_dump timed out after 10 minutes'));
      }, 10 * 60 * 1000);

      proc.stderr.on('data', (d) => { stderr += d.toString(); });
      proc.on('close', (code) => {
        clearTimeout(timeout);
        if (code === 0) resolve();
        else reject(new Error(`pg_dump failed (code ${code}): ${stderr.slice(0, 500)}`));
      });
      proc.on('error', (e) => { clearTimeout(timeout); reject(new Error(`Failed to start pg_dump: ${e.message}`)); });
    });
    emit('Database dumped', { overallPct: 5, stageLabel: 'Stage 1 / 3' });

    // Stage 2: Upload database dump to Google Drive
    emit('Uploading database dump...', { overallPct: 6, stageLabel: 'Stage 2 / 3' });
    await runRcloneWithProgress(
      [...rcloneArgs, 'copy', dbDumpFile, 'gdrive:backups/db'],
      (stats) => {
        emit('Uploading database dump...', {
          overallPct: 6 + Math.round((stats.percentage || 0) * 0.4),
          stageLabel: 'Stage 2 / 3'
        });
      }
    );
    emit('Database dump uploaded', { overallPct: 46, stageLabel: 'Stage 2 / 3' });

    // Stage 3: Uploads folder (47-93%)
    let uploadExists = fs.existsSync(uploadsPath);
    if (uploadExists) {
      emit('Scanning uploads...', { overallPct: 47, stageLabel: 'Stage 3 / 3' });
      await runRcloneWithProgress(
        [...rcloneArgs, 'copy', uploadsPath, 'gdrive:backups/uploads'],
        (stats) => {
          const overallPct = 47 + Math.round((stats.percentage || 0) * 0.46);
          emit('Uploading files...', {
            overallPct,
            stageLabel: 'Stage 3 / 3',
            processedFiles:    stats.processedFiles,
            totalFiles:        stats.totalFiles,
            uploadedBytesLabel: formatBytes(stats.uploadedBytes),
            totalBytesLabel:    formatBytes(stats.totalBytes),
            speedLabel:         formatBytes(stats.speedBytes) + '/s',
            etaSeconds:         stats.etaSeconds,
            rclonePct:          stats.percentage
          });
        }
      );
      emit('Files uploaded', { overallPct: 94, stageLabel: 'Stage 3 / 3' });
    } else {
      emit('No uploads folder found (skipping)', { overallPct: 94, stageLabel: 'Stage 3 / 3' });
    }

    // Final: JSON backups (94-99%)
    emit('Uploading backups metadata...', { overallPct: 95, stageLabel: 'Final' });
    await runRcloneWithProgress(
      [...rcloneArgs, 'copy', BACKUPS_DIR, 'gdrive:backups/json'],
      () => {
        emit('Uploading backups metadata...', { overallPct: 97, stageLabel: 'Final' });
      }
    );

    // Cleanup old backups (keep last 30 days)
    const files = fs.readdirSync(BACKUPS_DIR);
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    for (const file of files) {
      const filePath = path.join(BACKUPS_DIR, file);
      const stat = fs.statSync(filePath);
      if (stat.mtime < thirtyDaysAgo) {
        fs.unlinkSync(filePath);
        logger.info({ file }, 'Deleted old backup');
      }
    }

    emit('Backup complete!', {
      overallPct: 100,
      stageLabel: 'Complete',
      status: 'success',
      timestamp
    });

    logger.info({ timestamp }, 'Backup completed successfully');
    return timestamp;
  } catch (error) {
    logger.error({ err: error }, 'Backup error');
    emit('Backup failed', {
      status: 'failed',
      error: error.message,
      overallPct: 0
    });
    throw error;
  } finally {
    // Always clean up the dump file, whether upload succeeded or failed (LEAK-3)
    if (dbDumpFile) {
      try { fs.unlinkSync(dbDumpFile); } catch { /* ignore cleanup error */ }
    }
  }
}

export { performBackup };
