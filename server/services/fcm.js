import admin from 'firebase-admin';

let fcmInitialized = false;

const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT;
if (serviceAccountJson) {
  try {
    const serviceAccount = JSON.parse(serviceAccountJson);
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });
    fcmInitialized = true;
    console.log('✓ Firebase Admin SDK initialized');
  } catch (err) {
    console.warn('⚠ Failed to initialize Firebase Admin SDK:', err.message);
  }
} else {
  console.warn('⚠ FIREBASE_SERVICE_ACCOUNT env var not set — FCM push notifications disabled');
}

export async function sendNotification(fcmToken, message) {
  if (!fcmInitialized) {
    console.warn('FCM not initialized — skipping push notification');
    return;
  }
  const payload = {
    token: fcmToken,
    notification: {
      title: 'GPS Tracker',
      body: message,
    },
  };
  const response = await admin.messaging().send(payload);
  console.log('FCM notification sent:', response);
  return response;
}
