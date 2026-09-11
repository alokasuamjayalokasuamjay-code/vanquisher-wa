/* ============================================================
   VANQUISHER WA BACKEND v1.0
   Multi-sender WhatsApp + Pairing Code + Blast + Auto-reply
   ============================================================ */

const express = require('express');
const cors = require('cors');
const { default: makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, Browsers } = require('@whiskeysockets/baileys');
const pino = require('pino');
const fs = require('fs');
const path = require('path');

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));

const PORT = process.env.PORT || 3000;
const API_KEY = process.env.API_KEY || 'vanquisher-secret-key-2025';

// Folder untuk simpan session WA
const SESSIONS_DIR = path.join(__dirname, 'sessions');
if (!fs.existsSync(SESSIONS_DIR)) fs.mkdirSync(SESSIONS_DIR);

// Store semua sender
const senders = {}; // { senderId: { sock, status, phone, pairingCode, reconnectTimer } }

function log(...args) { console.log('[VQ-WA]', ...args); }

/* ============ AUTH MIDDLEWARE ============ */
function auth(req, res, next) {
  const key = req.headers['x-api-key'] || req.query.api_key;
  if (key !== API_KEY) return res.status(401).json({ ok: false, error: 'Unauthorized' });
  next();
}

/* ============ HELPER: Delay ============ */
function delay(ms) { return new Promise(r => setTimeout(r, ms)); }

/* ============ HELPER: Buat Session Baru ============ */
async function createSession(senderId, phone) {
  const sessionPath = path.join(SESSIONS_DIR, senderId);
  const { state, saveCreds } = await useMultiFileAuthState(sessionPath);
  const { version } = await fetchLatestBaileysVersion();

  log(`Creating session for ${senderId} | phone: ${phone}`);

  const sock = makeWASocket({
    version,
    auth: state,
    printQRInTerminal: false, // Kita pakai pairing code
    logger: pino({ level: 'silent' }),
    browser: Browsers.ubuntu('Chrome'),
    generateHighQualityLinkPreview: false,
    getMessage: async () => ({ conversation: 'Vanquisher Bot' })
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect } = update;
    if (connection === 'open') {
      log(`✅ ${senderId} connected`);
      senders[senderId].status = 'connected';
      senders[senderId].pairingCode = null;
    } else if (connection === 'close') {
      const code = lastDisconnect?.error?.output?.statusCode;
      const shouldReconnect = code !== DisconnectReason.loggedOut;
      log(`❌ ${senderId} closed | code: ${code} | reconnect: ${shouldReconnect}`);
      senders[senderId].status = 'disconnected';
      if (shouldReconnect) {
        setTimeout(() => {
          if (senders[senderId]) createSession(senderId, phone);
        }, 5000);
      } else {
        // Logged out — hapus session
        try { fs.rmSync(sessionPath, { recursive: true, force: true }); } catch(e) {}
        delete senders[senderId];
      }
    }
  });

  // Request pairing code (kalau belum register)
  if (!sock.authState.creds.registered) {
    try {
      // Beri waktu socket siap
      await delay(1500);
      const code = await sock.requestPairingCode(phone);
      senders[senderId].pairingCode = code;
      log(`🔑 Pairing code ${senderId}: ${code}`);
    } catch (e) {
      log(`❌ Gagal request pairing code: ${e.message}`);
      senders[senderId].pairingCode = 'ERROR';
    }
  }

  senders[senderId].sock = sock;
  return sock;
}

/* ============ ENDPOINT: ROOT ============ */
app.get('/', (req, res) => {
  res.json({
    ok: true,
    name: 'Vanquisher WA Backend',
    version: '1.0.0',
    senders: Object.keys(senders).length,
    time: new Date().toISOString()
  });
});

/* ============ ENDPOINT: LIST SENDER ============ */
app.get('/api/sender/list', auth, (req, res) => {
  const list = Object.keys(senders).map(id => ({
    id,
    phone: senders[id].phone,
    status: senders[id].status,
    pairingCode: senders[id].pairingCode,
    connected: senders[id].status === 'connected'
  }));
  res.json({ ok: true, senders: list });
});

/* ============ ENDPOINT: ADD SENDER ============ */
app.post('/api/sender/add', auth, async (req, res) => {
  const { phone, id } = req.body;
  if (!phone) return res.status(400).json({ ok: false, error: 'phone wajib diisi' });

  // Format nomor: harus 62xxx tanpa +
  let cleanPhone = phone.replace(/[^0-9]/g, '');
  if (cleanPhone.startsWith('0')) cleanPhone = '62' + cleanPhone.slice(1);
  if (!cleanPhone.startsWith('62')) cleanPhone = '62' + cleanPhone;

  const senderId = id || ('sender_' + Date.now());

  if (senders[senderId]) {
    return res.status(400).json({ ok: false, error: 'Sender ID sudah ada' });
  }

  senders[senderId] = {
    phone: cleanPhone,
    status: 'connecting',
    pairingCode: null,
    sock: null
  };

  try {
    await createSession(senderId, cleanPhone);
    res.json({ ok: true, senderId, phone: cleanPhone });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

/* ============ ENDPOINT: GET PAIRING CODE ============ */
app.get('/api/sender/:id/pairing-code', auth, (req, res) => {
  const sender = senders[req.params.id];
  if (!sender) return res.status(404).json({ ok: false, error: 'Sender tidak ditemukan' });
  res.json({ ok: true, pairingCode: sender.pairingCode, status: sender.status });
});

/* ============ ENDPOINT: TOGGLE SENDER (on/off) ============ */
app.post('/api/sender/:id/toggle', auth, async (req, res) => {
  const sender = senders[req.params.id];
  if (!sender) return res.status(404).json({ ok: false, error: 'Sender tidak ditemukan' });

  if (sender.status === 'connected') {
    // Logout / disconnect
    try {
      if (sender.sock) await sender.sock.logout();
    } catch(e) {}
    try {
      if (sender.sock) sender.sock.end();
    } catch(e) {}
    sender.status = 'disconnected';
    return res.json({ ok: true, status: 'disconnected' });
  } else {
    // Reconnect
    sender.status = 'connecting';
    try {
      await createSession(req.params.id, sender.phone);
      res.json({ ok: true, status: 'connecting' });
    } catch (e) {
      res.status(500).json({ ok: false, error: e.message });
    }
  }
});

/* ============ ENDPOINT: DELETE SENDER ============ */
app.delete('/api/sender/:id', auth, async (req, res) => {
  const sender = senders[req.params.id];
  if (!sender) return res.status(404).json({ ok: false, error: 'Sender tidak ditemukan' });

  try {
    if (sender.sock) {
      try { await sender.sock.logout(); } catch(e) {}
      try { sender.sock.end(); } catch(e) {}
    }
  } catch(e) {}

  const sessionPath = path.join(SESSIONS_DIR, req.params.id);
  try { fs.rmSync(sessionPath, { recursive: true, force: true }); } catch(e) {}

  delete senders[req.params.id];
  res.json({ ok: true });
});

/* ============ ENDPOINT: SEND MESSAGE (SINGLE) ============ */
app.post('/api/send', auth, async (req, res) => {
  const { senderId, to, message } = req.body;
  if (!senderId || !to || !message) {
    return res.status(400).json({ ok: false, error: 'senderId, to, message wajib diisi' });
  }

  const sender = senders[senderId];
  if (!sender) return res.status(404).json({ ok: false, error: 'Sender tidak ditemukan' });
  if (sender.status !== 'connected') return res.status(400).json({ ok: false, error: 'Sender belum terhubung' });

  let cleanTo = to.replace(/[^0-9]/g, '');
  if (cleanTo.startsWith('0')) cleanTo = '62' + cleanTo.slice(1);
  if (!cleanTo.startsWith('62')) cleanTo = '62' + cleanTo;
  const jid = cleanTo + '@s.whatsapp.net';

  try {
    await sender.sock.sendMessage(jid, { text: message });
    res.json({ ok: true, to: cleanTo });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

/* ============ ENDPOINT: BLAST (KIRIM BANYAK) ============ */
app.post('/api/blast', auth, async (req, res) => {
  const { senderId, targets, message, delayMs } = req.body;
  if (!senderId || !targets || !Array.isArray(targets) || !message) {
    return res.status(400).json({ ok: false, error: 'senderId, targets[], message wajib diisi' });
  }

  const sender = senders[senderId];
  if (!sender) return res.status(404).json({ ok: false, error: 'Sender tidak ditemukan' });
  if (sender.status !== 'connected') return res.status(400).json({ ok: false, error: 'Sender belum terhubung' });

  const delayTime = delayMs || 3000; // default 3 detik
  const results = [];

  for (const to of targets) {
    let cleanTo = String(to).replace(/[^0-9]/g, '');
    if (cleanTo.startsWith('0')) cleanTo = '62' + cleanTo.slice(1);
    if (!cleanTo.startsWith('62')) cleanTo = '62' + cleanTo;
    const jid = cleanTo + '@s.whatsapp.net';

    try {
      await sender.sock.sendMessage(jid, { text: message });
      results.push({ to: cleanTo, ok: true });
    } catch (e) {
      results.push({ to: cleanTo, ok: false, error: e.message });
    }
    await delay(delayTime);
  }

  res.json({ ok: true, results });
});

/* ============ INIT: AUTO-RECONNECT SEMUA SENDER ============ */
function autoReconnectAll() {
  try {
    const dirs = fs.readdirSync(SESSIONS_DIR);
    for (const d of dirs) {
      const fullPath = path.join(SESSIONS_DIR, d);
      if (!fs.statSync(fullPath).isDirectory()) continue;
      const credsPath = path.join(fullPath, 'creds.json');
      if (!fs.existsSync(credsPath)) continue;

      try {
        const creds = JSON.parse(fs.readFileSync(credsPath, 'utf-8'));
        const phone = creds?.me?.id?.split(':')[0]?.split('@')[0];
        if (!phone) continue;

        log(`🔄 Auto-reconnect: ${d} (${phone})`);
        senders[d] = { phone, status: 'connecting', pairingCode: null, sock: null };
        createSession(d, phone).catch(e => log(`Reconnect gagal ${d}: ${e.message}`));
      } catch (e) {}
    }
  } catch (e) {}
}

app.listen(PORT, () => {
  log(`🚀 Server running on port ${PORT}`);
  log(`🔑 API Key: ${API_KEY}`);
  setTimeout(autoReconnectAll, 3000);
});
