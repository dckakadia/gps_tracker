import express from 'express';
import multer from 'multer';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { authorize, requireAdmin } from '../middleware/auth.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const APKS_DIR = path.join(__dirname, '../uploads/apks');
const VERSION_FILE = path.join(APKS_DIR, 'version.json');

const router = express.Router();

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, APKS_DIR),
  filename: (req, file, cb) => {
    const { version } = req.body;
    if (!version || !/^\d+\.\d+\.\d+$/.test(version)) {
      return cb(new Error('version must be in X.Y.Z format'));
    }
    const slug = version.replace(/\./g, '_');
    cb(null, `gpstracker_ver_${slug}.apk`);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 100 * 1024 * 1024 }, // 100 MB
  fileFilter: (req, file, cb) => {
    if (file.mimetype === 'application/vnd.android.package-archive' || file.originalname.endsWith('.apk')) {
      cb(null, true);
    } else {
      cb(new Error('Only .apk files are allowed'));
    }
  },
});

// GET /api/app/version — public, no auth required (checked before login)
router.get('/version', (req, res) => {
  try {
    if (!fs.existsSync(VERSION_FILE)) {
      return res.json({ latestVersion: null, versionCode: 0, fileName: null, releaseNotes: '', updatedAt: null });
    }
    const data = JSON.parse(fs.readFileSync(VERSION_FILE, 'utf8'));
    res.json(data);
  } catch (err) {
    console.error('Version read error', err);
    res.status(500).json({ error: 'Could not read version info' });
  }
});

// GET /api/app/download/:filename — public download of APK
router.get('/download/:filename', (req, res) => {
  const { filename } = req.params;
  if (!/^gpstracker_ver_[\d_]+\.apk$/.test(filename)) {
    return res.status(400).json({ error: 'Invalid filename' });
  }
  const filePath = path.join(APKS_DIR, filename);
  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'APK not found' });
  }
  res.download(filePath, filename);
});

// POST /api/app/upload — admin only, uploads new APK and updates version.json
router.post('/upload', authorize, requireAdmin, (req, res) => {
  upload.single('apk')(req, res, (err) => {
    if (err) {
      return res.status(400).json({ error: err.message });
    }
    if (!req.file) {
      return res.status(400).json({ error: 'No APK file provided' });
    }

    const { version, versionCode, releaseNotes } = req.body;
    if (!version || !versionCode) {
      fs.unlinkSync(req.file.path);
      return res.status(400).json({ error: 'version and versionCode are required' });
    }

    const parsedCode = parseInt(versionCode, 10);
    if (isNaN(parsedCode) || parsedCode <= 0) {
      fs.unlinkSync(req.file.path);
      return res.status(400).json({ error: 'versionCode must be a positive integer' });
    }

    // Remove old APK files (keep only the latest)
    try {
      const files = fs.readdirSync(APKS_DIR).filter(f => f.endsWith('.apk'));
      for (const f of files) {
        if (f !== req.file.filename) {
          fs.unlinkSync(path.join(APKS_DIR, f));
        }
      }
    } catch (cleanupErr) {
      console.warn('Could not clean up old APKs:', cleanupErr.message);
    }

    const versionData = {
      latestVersion: version,
      versionCode: parsedCode,
      fileName: req.file.filename,
      releaseNotes: releaseNotes || '',
      updatedAt: new Date().toISOString(),
    };

    try {
      fs.writeFileSync(VERSION_FILE, JSON.stringify(versionData, null, 2));
    } catch (writeErr) {
      return res.status(500).json({ error: 'Failed to update version file' });
    }

    res.json({ success: true, ...versionData });
  });
});

// GET /api/app/list-apks — admin only, lists uploaded APKs
router.get('/list-apks', authorize, requireAdmin, (req, res) => {
  try {
    const files = fs.existsSync(APKS_DIR)
      ? fs.readdirSync(APKS_DIR).filter(f => f.endsWith('.apk'))
      : [];
    res.json({ apks: files });
  } catch (err) {
    res.status(500).json({ error: 'Could not list APKs' });
  }
});

export default router;
