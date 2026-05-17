// src/routes/relay.js — Store-and-forward relay for parent/child devices.
// Designed for Railway/Render-style Node hosting. Data is end-to-end encrypted
// by the mobile clients; the backend only queues opaque payloads per pair token.
const express = require('express');

const alertStore = new Map(); // pairToken -> [encrypted alerts]
const historyStore = new Map(); // pairToken -> [encrypted history entries]
const ackStore = new Map(); // pairToken -> Set(ids)
const childProfiles = new Map(); // pairToken -> profile

const MAX_STORED_ALERTS = Number(process.env.MAX_STORED_ALERTS || 100);
const MAX_STORED_HISTORY = Number(process.env.MAX_STORED_HISTORY || 500);
const MAX_STORED_ACKS = Number(process.env.MAX_STORED_ACKS || 500);
const MAX_TOKEN_STORES = Number(process.env.MAX_TOKEN_STORES || 5000);
const TOKEN_TTL_MS = Number(process.env.RELAY_TOKEN_TTL_MS || 7 * 24 * 60 * 60 * 1000);

const lastSeen = new Map(); // pairToken -> timestamp

function getBearerToken(req) {
  const header = req.headers.authorization || req.headers.Authorization;
  if (!header || !header.startsWith('Bearer ')) return '';
  return header.slice('Bearer '.length).trim();
}

function touch(token) {
  lastSeen.set(token, Date.now());
}

function cleanupStores() {
  const now = Date.now();
  for (const [token, seenAt] of lastSeen.entries()) {
    if (now - seenAt > TOKEN_TTL_MS) {
      lastSeen.delete(token);
      alertStore.delete(token);
      historyStore.delete(token);
      ackStore.delete(token);
      childProfiles.delete(token);
    }
  }

  if (lastSeen.size <= MAX_TOKEN_STORES) return;
  const oldest = [...lastSeen.entries()]
    .sort((a, b) => a[1] - b[1])
    .slice(0, lastSeen.size - MAX_TOKEN_STORES);
  for (const [token] of oldest) {
    lastSeen.delete(token);
    alertStore.delete(token);
    historyStore.delete(token);
    ackStore.delete(token);
    childProfiles.delete(token);
  }
}

function requirePairToken(req, res) {
  const token = getBearerToken(req);
  if (!token) {
    res.status(401).json({ error: 'Missing bearer pair token' });
    return '';
  }
  cleanupStores();
  touch(token);
  return token;
}

function appendBounded(store, token, item, max) {
  if (!store.has(token)) store.set(token, []);
  const queue = store.get(token);
  queue.push(item);
  if (queue.length > max) queue.splice(0, queue.length - max);
  return queue.length;
}

// ── Alert Router ───────────────────────────────────────────────────────────
const alertRouter = express.Router();

alertRouter.post('/push', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const { encryptedData, iv, id } = req.body || {};
  if (!encryptedData || !iv) {
    return res.status(400).json({ error: 'encryptedData and iv are required' });
  }

  const alert = {
    id: id || `alert_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    encryptedData,
    iv,
    receivedAt: new Date().toISOString(),
  };
  const queueSize = appendBounded(alertStore, token, alert, MAX_STORED_ALERTS);

  console.log(`🚨 Alert queued (token: ${token.substring(0, 8)}..., size: ${queueSize})`);
  res.status(201).json({ success: true, alertId: alert.id, queueSize });
});

alertRouter.get('/poll', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const alerts = alertStore.get(token) || [];
  alertStore.set(token, []);
  if (alerts.length > 0) {
    console.log(`📬 Delivered ${alerts.length} alert(s) (token: ${token.substring(0, 8)}...)`);
  }
  res.json({ alerts, count: alerts.length, polledAt: new Date().toISOString() });
});

alertRouter.post('/test', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const { app, severity, alertType, childName } = req.body || {};
  const testAlert = {
    app: app || 'WhatsApp',
    severity: severity || 'high',
    alertType: alertType || 'suspicious_content',
    childName: childName || 'Test Child',
    timestamp: new Date().toISOString(),
    id: `test_${Date.now()}`,
    isTestAlert: true,
  };
  const queueSize = appendBounded(alertStore, token, testAlert, MAX_STORED_ALERTS);
  res.status(201).json({ success: true, alert: testAlert, queueSize });
});

alertRouter.get('/debug/status', (_req, res) => {
  cleanupStores();
  res.json({
    totalTokens: lastSeen.size,
    alertTokens: alertStore.size,
    historyTokens: historyStore.size,
    ackTokens: ackStore.size,
    profiles: childProfiles.size,
    limits: {
      maxStoredAlerts: MAX_STORED_ALERTS,
      maxStoredHistory: MAX_STORED_HISTORY,
      maxStoredAcks: MAX_STORED_ACKS,
      maxTokenStores: MAX_TOKEN_STORES,
    },
  });
});

// ── History Router ────────────────────────────────────────────────────────
const historyRouter = express.Router();

historyRouter.post('/push', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const { encryptedData, iv, id } = req.body || {};
  if (!encryptedData || !iv) {
    return res.status(400).json({ error: 'encryptedData and iv are required' });
  }

  const entry = {
    id: id || `history_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    encryptedData,
    iv,
    receivedAt: new Date().toISOString(),
  };
  const queueSize = appendBounded(historyStore, token, entry, MAX_STORED_HISTORY);
  res.status(201).json({ success: true, recordId: entry.id, queueSize });
});

historyRouter.get('/poll', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const history = historyStore.get(token) || [];
  historyStore.set(token, []);
  res.json({ history, count: history.length, polledAt: new Date().toISOString() });
});

// ── Ack Router ─────────────────────────────────────────────────────────────
const ackRouter = express.Router();

ackRouter.post('/push', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const ids = Array.isArray(req.body?.ids) ? req.body.ids : req.body?.alertId ? [req.body.alertId] : [];
  if (ids.length === 0) return res.status(400).json({ error: 'ids array is required' });

  if (!ackStore.has(token)) ackStore.set(token, new Set());
  const set = ackStore.get(token);
  ids.forEach((id) => set.add(String(id)));
  while (set.size > MAX_STORED_ACKS) set.delete(set.values().next().value);

  res.status(201).json({ success: true, count: ids.length, queueSize: set.size });
});

ackRouter.get('/poll', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const acks = ackStore.has(token) ? [...ackStore.get(token)] : [];
  ackStore.delete(token);
  res.json({ acks, count: acks.length });
});

// ── Child Profile Router ──────────────────────────────────────────────────
const childRouter = express.Router();

childRouter.post('/register', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const { childId, name, age, avatarUrl, settings, encryptedData, iv } = req.body || {};
  if (!childId || !name) {
    return res.status(400).json({ error: 'childId and name are required' });
  }

  const profile = {
    childId,
    name,
    age: age || 10,
    avatarUrl: avatarUrl || null,
    settings: settings || {},
    encryptedData: encryptedData || null,
    iv: iv || null,
    updatedAt: Date.now(),
  };
  childProfiles.set(token, profile);

  console.log(`👶 Child profile registered: ${name}`);
  res.status(200).json({ success: true, childId, timestamp: profile.updatedAt });
});

childRouter.get('/profile', (req, res) => {
  const token = requirePairToken(req, res);
  if (!token) return;

  const profile = childProfiles.get(token);
  if (!profile) return res.status(404).json({ error: 'Profile not found' });
  res.json({ success: true, profile });
});

const healthRouter = express.Router();
healthRouter.get('/health', (_req, res) => {
  cleanupStores();
  res.json({
    status: 'ok',
    service: 'relay',
    alerts: alertStore.size,
    history: historyStore.size,
    acks: ackStore.size,
    profiles: childProfiles.size,
  });
});

module.exports = {
  alertRouter,
  historyRouter,
  ackRouter,
  childRouter,
  healthRouter,
};
