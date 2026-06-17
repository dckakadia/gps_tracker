import express from 'express';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';

const router = express.Router();

router.get('/', authorize, requireAdmin, async (req, res) => {
  try {
    const result = await query('SELECT * FROM geofences ORDER BY created_at DESC');
    return res.json({ geofences: result.rows });
  } catch (err) {
    console.error('Fetch geofences error', err);
    return res.status(500).json({ error: 'Unable to fetch geofences' });
  }
});

router.post('/', authorize, requireAdmin, async (req, res) => {
  const { name, latitude, longitude, radius_meters } = req.body;
  if (!name || latitude == null || longitude == null || radius_meters == null) {
    return res.status(400).json({ error: 'name, latitude, longitude, and radius_meters are required' });
  }
  try {
    const result = await query(
      'INSERT INTO geofences (name, latitude, longitude, radius_meters) VALUES ($1, $2, $3, $4) RETURNING *',
      [name, latitude, longitude, radius_meters]
    );
    return res.status(201).json({ geofence: result.rows[0] });
  } catch (err) {
    console.error('Create geofence error', err);
    return res.status(500).json({ error: 'Unable to create geofence' });
  }
});

router.put('/:id', authorize, requireAdmin, async (req, res) => {
  const { id } = req.params;
  const { name, latitude, longitude, radius_meters } = req.body;
  if (!name || latitude == null || longitude == null || radius_meters == null) {
    return res.status(400).json({ error: 'name, latitude, longitude, and radius_meters are required' });
  }
  // Note: the geofences table has no created_by column, so ownership is enforced by
  // the admin-only middleware rather than a per-row owner check.
  try {
    const result = await query(
      'UPDATE geofences SET name = $1, latitude = $2, longitude = $3, radius_meters = $4 WHERE id = $5 RETURNING *',
      [name, latitude, longitude, radius_meters, id]
    );
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'Geofence not found' });
    }
    return res.json({ geofence: result.rows[0] });
  } catch (err) {
    console.error('Update geofence error', err);
    return res.status(500).json({ error: 'Unable to update geofence' });
  }
});

router.delete('/:id', authorize, requireAdmin, async (req, res) => {
  const { id } = req.params;
  try {
    const result = await query('DELETE FROM geofences WHERE id = $1 RETURNING id', [id]);
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'Geofence not found' });
    }
    return res.json({ message: 'Geofence deleted' });
  } catch (err) {
    console.error('Delete geofence error', err);
    return res.status(500).json({ error: 'Unable to delete geofence' });
  }
});

export default router;
