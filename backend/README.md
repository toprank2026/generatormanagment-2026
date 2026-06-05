# Moldati Accounts Backend

Accounts-only backend for the **Moldati Owner** Flutter app. It owns
**authentication, subscription/plans, device binding, and cloud DB backups**.
All generator business data (boards, circuits, subscribers, prices, receipts,
expenses, local staff) stays on the device in SQLite and is **never** sent here.

- Stack: Node.js + Express + Mongoose (MongoDB).
- The authoritative endpoint spec is [`API_CONTRACT.md`](./API_CONTRACT.md).
- The architecture map is in [`../STRUCTURE.md`](../STRUCTURE.md).

## Requirements

- Node.js >= 18
- No MongoDB install needed for local dev — with `USE_MEMORY_DB=true` an
  in-process [`mongodb-memory-server`](https://github.com/nodkz/mongodb-memory-server)
  is started automatically. For persistence, set `USE_MEMORY_DB=false` and point
  `MONGO_URI` at a real MongoDB.

## Quick start

```bash
cd backend
cp .env.example .env        # then edit secrets (Windows: copy .env.example .env)
npm install
npm run dev                 # nodemon, auto-restart on change
# or: npm start             # plain node
```

The server listens on `http://localhost:4000` by default (`PORT` in `.env`).

- API base: `http://localhost:4000/api`
- Health check: `GET http://localhost:4000/api/health`
- Admin panel: `http://localhost:4000/admin`

On first boot the server **seeds** default plans (`trial`, `monthly`, `yearly`)
and a bootstrap admin from `ADMIN_USERNAME` / `ADMIN_PASSWORD` (default
`admin` / `admin123`). Re-seeding is idempotent.

## Pointing the Flutter app at this backend

The app reads its base URL from a `--dart-define`:

```bash
# Android emulator (host machine is 10.0.2.2):
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000

# Physical device on the same LAN (use your machine's IP):
flutter run --dart-define=API_BASE_URL=http://192.168.1.99:4000
```

Default in `lib/core/api_config.dart` is `http://192.168.1.99:4000`.

## Scripts

| Script         | Purpose                                                        |
| -------------- | ------------------------------------------------------------- |
| `npm start`    | Run the server (`node src/server.js`).                         |
| `npm run dev`  | Run with nodemon (auto-restart).                               |
| `npm run seed` | Manually run the seeder (plans + admin). See note below.       |

> `npm run seed` against `USE_MEMORY_DB=true` seeds an ephemeral DB that is
> discarded when the process exits (sanity check only). The server seeds on
> every boot anyway, so this is mainly useful with a real `MONGO_URI`.

## Environment (`.env`)

| Var              | Default                              | Notes                                   |
| ---------------- | ------------------------------------ | --------------------------------------- |
| `PORT`           | `4000`                               | HTTP port.                              |
| `USE_MEMORY_DB`  | `true`                               | In-process Mongo for dev.               |
| `MONGO_URI`      | `mongodb://127.0.0.1:27017/moldati`  | Used when `USE_MEMORY_DB=false`.        |
| `JWT_SECRET`     | `change-me-...`                      | **Change in production.**               |
| `JWT_EXPIRES`    | `30d`                                | Token lifetime.                         |
| `ADMIN_USERNAME` | `admin`                              | Bootstrap admin login.                  |
| `ADMIN_PASSWORD` | `admin123`                           | Bootstrap admin password.               |
| `BACKUP_DIR`     | `./backups`                          | Per-account SQLite snapshot storage.    |
| `MAX_BACKUPS`    | `10`                                 | Newest-N retained per account.          |

## Project layout

```
backend/
├── src/
│   ├── server.js              Express app: routes, static admin SPA, errors
│   ├── config/{env,db}.js     env vars + Mongo (memory or real) connection
│   ├── bootstrap/seed.js      ensures default plans + bootstrap admin
│   ├── scripts/seedPlans.js   manual `npm run seed`
│   ├── models/                User, Plan, Backup (Mongoose schemas)
│   ├── middleware/            auth (JWT/admin), validate, error
│   ├── utils/                 token, asyncHandler, serialize, devices
│   ├── controllers/           auth, subscription, device, backup, admin
│   └── routes/                auth, subscription, device, backup, admin
├── public/admin/index.html    Admin SPA (written separately)
├── API_CONTRACT.md            endpoint source of truth
├── .env.example
└── package.json
```

## Notes

- Passwords are hashed with bcrypt; auth is stateless JWT (`Authorization:
  Bearer <token>`).
- Device binding is keyed off `installId` + `deviceId`; binding a **new** device
  beyond the active plan's `maxDevices` returns `403 { code: "DEVICE_LIMIT" }`.
- Every error response uses the contract shape: `{ "message": "...", "code"?: "..." }`.
```
