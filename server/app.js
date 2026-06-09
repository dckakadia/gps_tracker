import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import dotenv from 'dotenv';
import http from 'http';
import { Server as SocketIOServer } from 'socket.io';
import cron from 'node-cron';
import authRoutes from './routes/auth.js';
import adminRoutes from './routes/admin.js';
import locationRoutes from './routes/locations.js';
import backupRoutes from './routes/backup.js';
import { performBackup } from './services/backup.js';
import { initializeUsername } from './db/init-username.js';
import pool from './db/index.js';

dotenv.config();
const app = express();
const httpServer = http.createServer(app);
const io = new SocketIOServer(httpServer, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

const port = process.env.PORT || 4000;

// Attach io to app for routes to access
app.set('io', io);

app.use(helmet());
app.use(cors());
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false }));

app.use('/api/auth', authRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/locations', locationRoutes);
app.use('/api/backup', backupRoutes);

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('Health check failed', err);
    res.status(500).json({ status: 'error' });
  }
});

app.use((err, req, res, next) => {
  console.error('Unhandled error', err);
  res.status(500).json({ error: 'Unexpected server error' });
});

// Socket.IO connection handler
io.on('connection', (socket) => {
  console.log(`User connected: ${socket.id}`);
  socket.on('disconnect', () => {
    console.log(`User disconnected: ${socket.id}`);
  });
});

// Schedule auto backup daily at 2 AM
if (process.env.ENABLE_AUTO_BACKUP === 'true') {
  cron.schedule('0 2 * * *', async () => {
    console.log('Running scheduled auto-backup...');
    try {
      await performBackup(io);
    } catch (error) {
      console.error('Auto-backup failed:', error.message);
    }
  });
  console.log('Auto-backup scheduled for 2:00 AM daily');
}

httpServer.listen(port, async () => {
  console.log(`GPS Tracker API listening on port ${port}`);
  // Initialize username field for existing users
  try {
    await initializeUsername();
  } catch (err) {
    console.error('Failed to initialize username:', err.message);
  }
});
