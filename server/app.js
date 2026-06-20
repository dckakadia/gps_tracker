import dotenv from 'dotenv';
import express from 'express';
import { logger } from './logger.js';
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
import appRoutes from './routes/app.js';
import { performBackup } from './services/backup.js';
import { initializeUsername } from './db/init-username.js';
import { initializeUploadAudit } from './db/init-upload-audit.js';
import { initializeLocationsIndex } from './db/init-locations-index.js';
import { initializeAdminUser } from './db/init-admin-user.js';
import pool, { initializeDatabase } from './db/index.js';
import { initializeAttendance } from './db/init-attendance.js';
import { initializeBatteryColumn } from './db/init-battery.js';
import { initializeArchive } from './db/init-archive.js';
import { initializeGeofences } from './db/init-geofences.js';
import { initializeAntiCheat } from './db/init-anticheat.js';
import { initializePostGIS } from './db/init-postgis.js';
import { initializeGpsQuality } from './db/init-gps-quality.js';
import deviceEventRoutes from './routes/device-events.js';
import stopsRoutes from './routes/stops.js';
import { migrateGeofenceEvents } from './db/migrate-geofence-events.js';
import { initializeFcm } from './db/init-fcm.js';
import { initializeRefreshTokenVersion } from './db/init-refresh-token-version.js';
import { initializeBackupRuns } from './db/init-backup-runs.js';

dotenv.config();

const inMemory = process.env.USE_IN_MEMORY_DB === 'true';
const REQUIRED_ENV = inMemory
  ? ['JWT_SECRET', 'PORT']
  : ['DATABASE_URL', 'JWT_SECRET', 'PORT'];
for (const key of REQUIRED_ENV) {
  if (!process.env[key]) {
    console.error(`MISSING ENV: ${key} is required`);
    process.exit(1);
  }
}

const JWT_SECRET = process.env.JWT_SECRET;
const app = express();
const httpServer = http.createServer(app);
const allowedOrigins = process.env.ALLOWED_ORIGINS
  ? process.env.ALLOWED_ORIGINS.split(',')
  : ['*'];

const io = new SocketIOServer(httpServer, {
  cors: {
    origin: allowedOrigins,
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

app.set('trust proxy', 1); // trust nginx X-Forwarded-For so rate-limiter sees real client IP
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
app.use('/api/app', appRoutes);
app.use('/api/device-events', deviceEventRoutes);
app.use('/api/stops', stopsRoutes);
app.use('/api/routes', locationRoutes); // alias for /api/routes/summary

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok' });
  } catch (err) {
    logger.error({ err }, 'Health check failed');
    res.status(500).json({ status: 'error' });
  }
});

app.use((err, req, res, next) => {
  logger.error({ err }, 'Unhandled error');
  res.status(500).json({ error: 'Unexpected server error' });
});

// Socket.IO connection handler
io.on('connection', (socket) => {
  logger.debug({ socketId: socket.id }, 'User connected');
  socket.on('disconnect', () => {
    logger.debug({ socketId: socket.id }, 'User disconnected');
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

// Archive old location data daily at 2:30 AM (staggered 30 min after backup to avoid lock contention)
if (process.env.ENABLE_ARCHIVE !== 'false') {
  cron.schedule('30 2 * * *', async () => {
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
}

const startServer = async () => {
  // Database health check
  try {
    await pool.query('SELECT 1');
    logger.info('Database connection healthy');
  } catch (err) {
    logger.fatal({ err }, 'Database connection failed');
    process.exit(1);
  }

  // Initialize base schema first (in-memory DB only)
  try {
    await initializeDatabase();
  } catch (err) {
    console.error('Failed to initialize database schema:', err.message);
  }

  // Run independent migrations concurrently to cut startup time
  await Promise.allSettled([
    initializeUsername().catch(err => console.error('Failed to initialize username:', err.message)),
    initializeUploadAudit().catch(err => console.error('Failed to initialize upload audit table:', err.message)),
    initializeLocationsIndex().catch(err => console.error('Failed to initialize locations index:', err.message)),
    initializeAttendance().catch(err => console.error('Failed to initialize attendance table:', err.message)),
    initializeBatteryColumn().catch(err => console.error('Failed to initialize battery column:', err.message)),
    initializeArchive().catch(err => console.error('Failed to initialize archive table:', err.message)),
    initializeGeofences().catch(err => console.error('Failed to initialize geofences tables:', err.message)),
    initializeFcm().catch(err => console.error('Failed to initialize FCM column:', err.message)),
    initializeAntiCheat().catch(err => console.error('Failed to initialize anti-cheat schema:', err.message)),
    initializeGpsQuality().catch(err => console.error('Failed to initialize GPS quality columns:', err.message)),
    initializeRefreshTokenVersion().catch(err => console.error('Failed to initialize refresh token version:', err.message)),
    initializeBackupRuns().catch(err => console.error('Failed to initialize backup runs table:', err.message)),
  ]);

  // PostGIS depends on schema existing; geofence events migration depends on geofences table
  try {
    await initializePostGIS();
  } catch (err) {
    console.error('Failed to initialize PostGIS (non-fatal):', err.message);
  }
  try {
    await migrateGeofenceEvents();
  } catch (err) {
    console.error('Failed to migrate geofence_events table:', err.message);
  }

  // Admin user depends on users table being fully migrated
  try {
    await initializeAdminUser();
  } catch (err) {
    console.error('Failed to initialize admin user:', err.message);
  }

  httpServer.listen(port, () => {
    logger.info({ port }, 'GPS Tracker API listening');
  });
};

startServer();
