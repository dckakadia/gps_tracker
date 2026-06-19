import { initializeApp, getApps, cert } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';

let messaging = null;

// Lazy init — top-level code runs before dotenv.config() in app.js (ES module hoisting),
// so we defer reading process.env until the first sendNotification() call.
function initFcm() {
  if (messaging) return true;
  const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT;
  if (!serviceAccountJson) return false;
  try {
    const serviceAccount = JSON.parse(serviceAccountJson);
    const existingApps = getApps();
    const app = existingApps.length > 0
      ? existingApps[0]
      : initializeApp({ credential: cert(serviceAccount) });
    messaging = getMessaging(app);
    console.log('✓ Firebase Admin SDK initialized');
    return true;
  } catch (err) {
    console.warn('⚠ Failed to initialize Firebase Admin SDK:', err.message);
    return false;
  }
}

export async function sendNotification(fcmToken, message) {
  if (!messaging && !initFcm()) {
    throw new Error('FCM not configured on server — set FIREBASE_SERVICE_ACCOUNT in .env');
  }
  const response = await messaging.send({
    token: fcmToken,
    notification: {
      title: 'GPS Tracker',
      body: message,
    },
    android: {
      priority: 'high',
      notification: {
        channelId: 'gps_tracker_alerts',
        priority: 'high',
        defaultSound: true,
      },
    },
  });
  console.log('FCM notification sent:', response);
  return response;
}
