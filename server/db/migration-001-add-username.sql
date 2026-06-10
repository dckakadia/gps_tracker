-- Migration: Add username column to users table if it doesn't exist
-- Run this on the live database to fix the schema mismatch

-- Add username column if it doesn't exist
ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT UNIQUE;

-- Verify the migration
\d users
