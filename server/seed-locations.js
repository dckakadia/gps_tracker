#!/usr/bin/env node

/**
 * Seed sample location data for testing
 * Creates test users and inserts location data for the Live Map
 */

import 'dotenv/config.js';
import pool from './db/index.js';
import bcrypt from 'bcrypt';

const TEST_USERS = [
  {
    email: 'john.smith@tracker.local',
    name: 'John Smith',
    username: 'john.smith',
    password: 'TestPass123!',
    locations: [
      { latitude: 40.7128, longitude: -74.0060 }, // NYC
      { latitude: 40.7150, longitude: -74.0070 }, // NYC nearby
      { latitude: 40.7100, longitude: -74.0050 }, // NYC nearby
    ]
  },
  {
    email: 'sarah.johnson@tracker.local',
    name: 'Sarah Johnson',
    username: 'sarah.johnson',
    password: 'TestPass123!',
    locations: [
      { latitude: 34.0522, longitude: -118.2437 }, // Los Angeles
      { latitude: 34.0530, longitude: -118.2450 },
    ]
  },
  {
    email: 'mike.davis@tracker.local',
    name: 'Mike Davis',
    username: 'mike.davis',
    password: 'TestPass123!',
    locations: [
      { latitude: 41.8781, longitude: -87.6298 }, // Chicago
    ]
  },
];

async function seedLocations() {
  try {
    console.log('🌱 Seeding test location data...\n');

    for (const user of TEST_USERS) {
      console.log(`Creating user: ${user.name} (${user.email})`);

      // Check if user already exists
      const existingUser = await pool.query(
        'SELECT id FROM users WHERE email = $1',
        [user.email]
      );

      let userId;
      if (existingUser.rows.length > 0) {
        userId = existingUser.rows[0].id;
        console.log(`  ✓ User already exists (ID: ${userId})`);
      } else {
        // Create new user
        const hashedPassword = await bcrypt.hash(user.password, 12);
        const result = await pool.query(
          `INSERT INTO users (name, email, username, password_hash, role, created_at, updated_at)
           VALUES ($1, $2, $3, $4, 'salesperson', NOW(), NOW()) RETURNING id`,
          [user.name, user.email, user.username, hashedPassword]
        );
        userId = result.rows[0].id;
        console.log(`  ✓ User created (ID: ${userId})`);
      }

      // Insert location data
      console.log(`  Adding ${user.locations.length} location point(s)...`);
      
      for (let i = 0; i < user.locations.length; i++) {
        const loc = user.locations[i];
        const recordedAt = new Date(Date.now() - (i * 5 * 60 * 1000)); // Spread over 5-minute intervals
        
        await pool.query(
          `INSERT INTO locations (user_id, latitude, longitude, recorded_at, received_at)
           VALUES ($1, $2, $3, $4, $5)`,
          [userId, loc.latitude, loc.longitude, recordedAt, new Date()]
        );
      }
      console.log(`  ✓ Location data inserted\n`);
    }

    console.log('✅ Seed completed successfully!');
    console.log('\nYou should now see users on the Live Map:');
    console.log('  - John Smith (NYC)');
    console.log('  - Sarah Johnson (Los Angeles)');
    console.log('  - Mike Davis (Chicago)');
    console.log('\nReload the admin dashboard to view them.');

  } catch (err) {
    console.error('❌ Seed failed:', err.message);
    process.exit(1);
  }
}

seedLocations();
