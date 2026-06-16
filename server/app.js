import dotenv from 'dotenv';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import http from 'http';
import jwt from 'jsonwebtoken';
import { Server as SocketIOServer } from 'socket.io';
import cron from 'node-cron';
import authRoutes from './routes/auth.js';
import adminRoutes from './routes/admin.js';
import usersRoutes from './routes/users.js';
import locationRoutes from './routes/locations.js';
import backupRoutes from './routes/backup.js';
import geofencesRoutes from './routes/geofences.js';
import { performBackup } from './services/backup.js';
import { initializeUsername } from './db/init-username.js';
import { initializeUploadAudit } from './db/init-upload-audit.js';
import { initializeLocationsIndex } from './db/init-locations-index.js';
import { initializeAdminUser } from './db/init-admin-user.js';
import { initializeDatabase } from './db/index.js';
import { initializeAttendance } from './db/init-attendance.js';
import { initializeBatteryColumn } from './db/init-battery.js';
import { initializeArchive } from './db/init-archive.js';
import { initializeGeofences } from './db/init-geofences.js';
import { initializeFcm } from './db/init-fcm.js';
import pool from './db/index.js';

dotenv.config();

const REQUIRED_ENV = ['DATABASE_URL', 'JWT_SECRET', 'PORT'];
for (const key of REQUIRED_ENV) {
  if (!process.env[key]) {
    console.error(`MISSING ENV: ${key} is required`);
    process.exit(1);
  }
}

const JWT_SECRET = process.env.JWT_SECRET;
const app = express();
const httpServer = http.createServer(app);
const io = new SocketIOServer(httpServer, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

// Socket.IO JWT authentication middleware
io.use((socket, next) => {
  const token = socket.handshake.auth?.token;
  if (!token) {
    return next(new Error('Unauthorized'));
  }
  try {
    const payload = jwt.verify(token, JWT_SECRET);
    if (payload.role !== 'admin') {
      return next(new Error('Unauthorized'));
    }
    socket.user = payload;
    next();
  } catch (err) {
    return next(new Error('Unauthorized'));
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
app.use('/api/users', usersRoutes);
app.use('/api/locations', locationRoutes);
app.use('/api/backup', backupRoutes);
app.use('/api/geofences', geofencesRoutes);

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

// Archive old location data daily at 2 AM
cron.schedule('0 2 * * *', async () => {
  try {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 90);
    const result = await pool.query(
      `WITH moved AS (
        DELETE FROM locations WHERE received_at < $1 RETURNING *
      ) INSERT INTO locations_archive SELECT * FROM moved`,
      [cutoff.toISOString()]
    );
    console.log(`Archived ${result.rowCount} old location rows`);
  } catch (err) {
    console.error('Location archive job failed:', err.message);
  }
});

const startServer = async () => {
  // Database health check
  try {
    await pool.query('SELECT 1');
    console.log('✓ Database connection healthy');
  } catch (err) {
    console.error('✗ Database connection failed:', err.message);
    process.exit(1);
  }

  try {
    await initializeDatabase();
  } catch (err) {
    console.error('Failed to initialize database schema:', err.message);
  }

  try {
    await initializeAdminUser();
  } catch (err) {
    console.error('Failed to initialize admin user:', err.message);
  }

  try {
    await initializeUsername();
  } catch (err) {
    console.error('Failed to initialize username:', err.message);
  }

  try {
    await initializeUploadAudit();
  } catch (err) {
    console.error('Failed to initialize upload audit table:', err.message);
  }

  try {
    await initializeLocationsIndex();
  } catch (err) {
    console.error('Failed to initialize locations index:', err.message);
  }

  try {
    await initializeAttendance();
  } catch (err) {
    console.error('Failed to initialize attendance table:', err.message);
  }

  try {
    await initializeBatteryColumn();
  } catch (err) {
    console.error('Failed to initialize battery column:', err.message);
  }

  try {
    await initializeArchive();
  } catch (err) {
    console.error('Failed to initialize archive table:', err.message);
  }

  try {
    await initializeGeofences();
  } catch (err) {
    console.error('Failed to initialize geofences tables:', err.message);
  }

  try {
    await initializeFcm();
  } catch (err) {
    console.error('Failed to initialize FCM column:', err.message);
  }

  httpServer.listen(port, () => {
    console.log(`GPS Tracker API listening on port ${port}`);
  });
};

startServer();
