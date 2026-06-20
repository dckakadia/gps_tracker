import express from 'express';
import { performBackup } from '../services/backup.js';
import { authorize, requireAdmin } from '../middleware/auth.js';
import { query } from '../db/index.js';

const router = express.Router();

router.use(authorize, requireAdmin);

async function getLatestRun() {
  const res = await query(
    `SELECT id, started_at, finished_at, status, error_message
     FROM backup_runs ORDER BY id DESC LIMIT 1`
  );
  return res.rows[0] ?? null;
}

// POST /api/backup — Trigger manual backup
router.post('/', async (req, res) => {
  const latest = await getLatestRun();
  if (latest?.status === 'running') {
    return res.json({ success: true, message: 'Backup already in progress.', running: true });
  }

  const io = req.app.get('io');

  const runRes = await query(
    `INSERT INTO backup_runs (status) VALUES ('running') RETURNING id`
  );
  const runId = runRes.rows[0].id;

  // Respond immediately to avoid 504 Gateway Timeout
  res.json({ success: true, message: 'Backup started.', running: true });

  performBackup(io)
    .then(async (timestamp) => {
      await query(
        `UPDATE backup_runs SET status='success', finished_at=NOW() WHERE id=$1`,
        [runId]
      );
    })
    .catch(async (error) => {
      await query(
        `UPDATE backup_runs SET status='failed', finished_at=NOW(), error_message=$1 WHERE id=$2`,
        [error.message, runId]
      );
    });
});

// GET /api/backup/status — Get backup status from DB
router.get('/status', async (req, res) => {
  try {
    const run = await getLatestRun();
    if (!run) {
      return res.json({ success: true, running: false, lastStatus: null, lastError: null, lastTimestamp: null });
    }
    res.json({
      success: true,
      running: run.status === 'running',
      lastStatus: run.status,
      lastError: run.error_message ?? null,
      lastTimestamp: run.finished_at ?? null,
    });
  } catch (err) {
    console.error('Backup status error', err);
    res.status(500).json({ error: 'Unable to fetch backup status' });
  }
});

export default router;
