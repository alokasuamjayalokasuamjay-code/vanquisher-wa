# Vanquisher WA Backend

Backend WhatsApp untuk Vanquisher Panel.

## Environment Variables
- `API_KEY` — API key untuk auth (opsional, default: vanquisher-secret-key-2025)
- `PORT` — Port server (Railway auto-set)

## Endpoints
- `GET /` — Info server
- `GET /api/sender/list` — List semua sender
- `POST /api/sender/add` — Tambah sender baru (body: phone)
- `GET /api/sender/:id/pairing-code` — Get pairing code
- `POST /api/sender/:id/toggle` — On/off sender
- `DELETE /api/sender/:id` — Hapus sender
- `POST /api/send` — Kirim pesan (body: senderId, to, message)
- `POST /api/blast` — Blast pesan (body: senderId, targets[], message, delayMs)

Semua endpoint butuh header `x-api-key`.
