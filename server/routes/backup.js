import express from 'express';
import { performBackup } from '../services/backup.js';

const router = express.Router();

// In-memory state tracker
let backupState = {
  running: false,
  lastStatus: null,
  lastError: null,
  lastTimestamp: null,
  stage: null,
  overallPct: 0
};

// POST /api/backup - Trigger manual backup
router.post('/', (req, res) => {
  if (backupState.running) {
    return res.json({ success: true, message: 'Backup already in progress.', running: true });
  }

  const io = req.app.get('io');

  // Reset state
  backupState = {
    running: true,
    lastStatus: 'running',
    lastError: null,
    lastTimestamp: null,
    stage: 'Starting...',
    overallPct: 0
  };

  // Respond immediately — avoids 504 Gateway Timeout
  res.json({ success: true, message: 'Backup started.', running: true });

  // Run in background (no await)
  performBackup(io)
    .then((timestamp) => {
      backupState.running = false;
      backupState.lastStatus = 'success';
      backupState.lastTimestamp = timestamp;
      backupState.overallPct = 100;
    })
    .catch((error) => {
      backupState.running = false;
      backupState.lastStatus = 'failed';
      backupState.lastError = error.message;
      backupState.overallPct = 0;
    });
});

// GET /api/backup/status - Get backup status
router.get('/status', (req, res) => {
  res.json({
    success: true,
    running: backupState.running,
    lastStatus: backupState.lastStatus,
    lastError: backupState.lastError,
    lastTimestamp: backupState.lastTimestamp,
    stage: backupState.stage,
    overallPct: backupState.overallPct
  });
});

export default router;
