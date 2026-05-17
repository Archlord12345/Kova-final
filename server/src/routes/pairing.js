// src/routes/pairing.js — Device pairing (QR code / pairing code)
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const pool = require('../db/pool');
const authMiddleware = require('../middleware/auth');

const router = express.Router();

// Generate a human-readable pairing code like KOVA-XXXX-XXXX
function generatePairingCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I confusion
  let code = 'KOVA-';
  for (let i = 0; i < 4; i++) code += chars[Math.floor(Math.random() * chars.length)];
  code += '-';
  for (let i = 0; i < 4; i++) code += chars[Math.floor(Math.random() * chars.length)];
  return code;
}

// ── POST /api/pairing/generate ──
// Maps to: WhatsappConnectScreen — generates QR data and pairing code
router.post('/generate', authMiddleware, async (req, res) => {
  try {
    const { childId } = req.body;

    if (!childId) {
      return res.status(400).json({ error: 'childId is required' });
    }

    // Verify child belongs to parent
    const { rows: children } = await pool.query(
      'SELECT id FROM children WHERE id = $1 AND parent_id = $2',
      [childId, req.parentId]
    );
    if (children.length === 0) {
      return res.status(404).json({ error: 'Child not found' });
    }

    // Expire any existing pending codes for this child
    await pool.query(
      `UPDATE pairing_codes SET status = 'expired'
       WHERE child_id = $1 AND status = 'pending'`,
      [childId]
    );

    const code = generatePairingCode();
    const { rows: [pairing] } = await pool.query(
      `INSERT INTO pairing_codes (parent_id, child_id, code, status, expires_at)
       VALUES ($1, $2, $3, 'pending', NOW() + INTERVAL '15 minutes')
       RETURNING id, code, status, expires_at`,
      [req.parentId, childId, code]
    );

    // QR data is the code itself — child app scans this
    res.status(201).json({
      code: pairing.code,
      qrData: JSON.stringify({
        type: 'kova-pair',
        code: pairing.code,
        childId,
      }),
      expiresAt: pairing.expires_at,
    });
  } catch (err) {
    console.error('Generate pairing error:', err);
    res.status(500).json({ error: 'Failed to generate pairing code' });
  }
});

// ── POST /api/pairing/connect ──
// Maps to: Child app using the pairing code to connect
router.post('/connect', async (req, res) => {
  try {
    const { code, deviceId } = req.body;

    if (!code || !deviceId) {
      return res.status(400).json({ error: 'Code and deviceId are required' });
    }

    // Find valid pairing code
    const { rows } = await pool.query(
      `SELECT pc.*, c.parent_id
       FROM pairing_codes pc
       JOIN children c ON c.id = pc.child_id
       WHERE pc.code = $1 AND pc.status = 'pending' AND pc.expires_at > NOW()`,
      [code]
    );

    if (rows.length === 0) {
      return res.status(404).json({ error: 'Invalid or expired pairing code' });
    }

    const pairing = rows[0];

    // Update pairing status
    await pool.query(
      `UPDATE pairing_codes SET status = 'connected' WHERE id = $1`,
      [pairing.id]
    );

    // Update child with device ID
    await pool.query(
      `UPDATE children SET device_id = $1, is_online = true, last_seen = NOW()
       WHERE id = $2`,
      [deviceId, pairing.child_id]
    );

    // Mark WhatsApp as connected
    await pool.query(
      `UPDATE monitored_apps SET is_connected = true
       WHERE child_id = $1 AND app_name = 'WhatsApp'`,
      [pairing.child_id]
    );

    res.json({
      success: true,
      childId: pairing.child_id,
      parentId: pairing.parent_id,
    });
  } catch (err) {
    console.error('Pairing connect error:', err);
    res.status(500).json({ error: 'Failed to connect device' });
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// RELAY ENDPOINTS (for Flutter app compatibility)
// These provide temporary storage for pairing codes when LAN is unavailable
// ═══════════════════════════════════════════════════════════════════════════

const relayStore = new Map(); // code -> { parentDeviceId, childDeviceId, pairToken, timestamp, status }
const RELAY_TTL_MS = Number(process.env.PAIRING_CODE_TTL_MS || 15 * 60 * 1000); // 15 minutes
const MAX_PAIRING_CODES = Number(process.env.MAX_PAIRING_CODES || 10000);

function normalizePairingCode(code) {
  return String(code || '').trim().toUpperCase();
}

function cleanupRelayStore() {
  const now = Date.now();
  for (const [key, value] of relayStore.entries()) {
    if (now - value.timestamp > RELAY_TTL_MS) {
      relayStore.delete(key);
    }
  }

  if (relayStore.size <= MAX_PAIRING_CODES) return;
  const oldest = [...relayStore.entries()]
    .sort((a, b) => a[1].timestamp - b[1].timestamp)
    .slice(0, relayStore.size - MAX_PAIRING_CODES);
  for (const [key] of oldest) relayStore.delete(key);
}

// ── POST /api/pair/register ──
// Parent registers a pairing code with the relay
router.post('/register', async (req, res) => {
  try {
    let { code, parentDeviceId } = req.body || {};
    code = normalizePairingCode(code);
    
    if (!code || !parentDeviceId) {
      return res.status(400).json({ error: 'code and parentDeviceId required' });
    }
    
    if (!/^[A-Z0-9-]{4,32}$/.test(code)) {
      return res.status(400).json({ error: 'Invalid pairing code format' });
    }

    cleanupRelayStore();
    const now = Date.now();

    // Store the pairing request
    relayStore.set(code, {
      code,
      parentDeviceId,
      childDeviceId: null,
      pairToken: null,
      timestamp: now,
      status: 'waiting'
    });
    
    console.log(`📡 Pair code registered: ${code}`);
    res.status(201).json({ success: true, code, expiresIn: Math.floor(RELAY_TTL_MS / 1000) });
  } catch (err) {
    console.error('Pair register error:', err);
    res.status(500).json({ error: 'Failed to register code' });
  }
});

// ── POST /api/pair/claim ──
// Child claims a pairing code and gets the pair token
router.post('/claim', async (req, res) => {
  try {
    let { code, childDeviceId } = req.body || {};
    code = normalizePairingCode(code);
    
    if (!code || !childDeviceId) {
      return res.status(400).json({ error: 'code and childDeviceId required' });
    }
    
    cleanupRelayStore();
    const entry = relayStore.get(code);
    
    if (!entry) {
      return res.status(404).json({ error: 'Code not found or expired' });
    }
    
    // Check if expired
    if (Date.now() - entry.timestamp > RELAY_TTL_MS) {
      relayStore.delete(code);
      return res.status(404).json({ error: 'Code expired' });
    }
    
    if (entry.childDeviceId && entry.childDeviceId !== childDeviceId) {
      return res.status(409).json({ error: 'Code already claimed by another device' });
    }

    // Generate pair token if not already done
    if (!entry.pairToken) {
      entry.pairToken = uuidv4();
    }
    entry.childDeviceId = childDeviceId;
    entry.status = 'claimed';
    
    console.log(`🔗 Pair code claimed: ${code} -> token: ${entry.pairToken.substring(0, 8)}...`);
    res.json({ 
      success: true, 
      pairToken: entry.pairToken,
      parentDeviceId: entry.parentDeviceId 
    });
  } catch (err) {
    console.error('Pair claim error:', err);
    res.status(500).json({ error: 'Failed to claim code' });
  }
});

// ── GET /api/pair/status ──
// Check if a code has been claimed
router.get('/status', async (req, res) => {
  try {
    let { code } = req.query;
    code = normalizePairingCode(code);
    
    if (!code) {
      return res.status(400).json({ error: 'code required' });
    }
    
    cleanupRelayStore();
    const entry = relayStore.get(code);
    
    if (!entry) {
      return res.status(404).json({ error: 'Code not found' });
    }
    
    // Check if expired
    if (Date.now() - entry.timestamp > RELAY_TTL_MS) {
      relayStore.delete(code);
      return res.status(404).json({ error: 'Code expired' });
    }
    
    res.json({
      code,
      status: entry.status,
      paired: !!entry.childDeviceId,      // Flutter client checks this field
      claimed: !!entry.childDeviceId,     // Keep for backwards compat
      pairToken: entry.pairToken,
      childDeviceId: entry.childDeviceId,
      expiresIn: Math.max(0, Math.floor((RELAY_TTL_MS - (Date.now() - entry.timestamp)) / 1000))
    });
  } catch (err) {
    console.error('Pair status error:', err);
    res.status(500).json({ error: 'Failed to check status' });
  }
});

// ── GET /api/pair/ping ──
// Keep-alive endpoint for pre-warming
router.get('/ping', (req, res) => {
  res.json({ status: 'ok', service: 'kova-relay' });
});

module.exports = router;
