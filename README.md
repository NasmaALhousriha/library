# Library Queue System

نظام طابور انتظار على كتب المكتبة:

- إذا كل نسخ الكتاب مستعارة، المستخدم بينحط بطابور.
- أول ما ترجع نسخة، بتنحجز تلقائياً لأول واحد بالطابور لمدة **24 ساعة**.
- إذا ما استلمها خلال المدة، الحجز بينتهي والنسخة بتروح للي بعدو.

---

## المعمارية

كل الـ business logic مكتوب كـ **PostgreSQL functions**. الـ NestJS بيستدعيها عبر Prisma بس:

```ts
const rows = await this.prisma.$queryRaw`SELECT borrow_book(${userId}, ${bookId}) AS borrow_book`;
```

| الطبقة | المسؤولية |
|---|---|
| **PostgreSQL** (`sql/functions.sql`) | كل المنطق: الاستعارة، الطابور، الحجز، الانتهاء، الإرجاع، الإلغاء |
| **NestJS services** | استدعاء الـ function وإرجاع النتيجة، بلا أي منطق |
| **PrismaExceptionFilter** | ترجمة أخطاء الـ functions لـ HTTP status |
| **SchedulerService** | معالجة الحجوزات المنتهية كل دقيقة |

- `$queryRaw` للـ functions يلي بترجع قيمة.
- `$executeRaw` للـ functions يلي بترجع `VOID`.

---

## المتطلبات

- Node.js 20+
- PostgreSQL 15+ (مع `psql` و `pgbench`)

---

## التشغيل

### 1. الإعداد

```bash
npm install
```

ملف `.env` بجذر المشروع:

```env
DATABASE_URL="postgresql://postgres:PASSWORD@localhost:5432/library_db"
PORT=3000
```

### 2. قاعدة البيانات

```bash
createdb -U postgres library_db
psql -U postgres -d library_db -f sql/schema.sql
psql -U postgres -d library_db -f sql/functions.sql
npx prisma generate
```

> ⚠️ `sql/schema.sql` هو المصدر الأساسي للـ schema. فيه CHECK constraints و partial unique indexes ما بتدعمهم Prisma.
> **لا تستخدم** `prisma db push` أو `prisma migrate dev` لأنهم ممكن يحذفوهم.

### 3. تشغيل الـ API

```bash
npm run start:dev
```

---

## الـ API

| Method | Endpoint | Body | الوظيفة |
|---|---|---|---|
| POST | `/users` | `{ name, email }` | إنشاء مستخدم |
| GET | `/users` / `/users/:id` | | عرض المستخدمين |
| POST | `/books` | `{ title, author, totalCopies }` | إنشاء كتاب |
| GET | `/books` / `/books/:id` | | عرض الكتب |
| POST | `/borrowings` | `{ userId, bookId }` | استعارة. إذا ما في نسخة، بيدخل الطابور تلقائياً |
| POST | `/borrowings/:id/return` | | إرجاع. النسخة بتنحجز لأول واحد بالطابور |
| GET | `/borrowings` | | كل الاستعارات |
| POST | `/queue` | `{ userId, bookId }` | دخول الطابور (فقط إذا ما في نسخ متاحة) |
| POST | `/queue/receive` | `{ queueId, userId }` | استلام الكتاب المحجوز (صاحب الحجز فقط) |
| POST | `/queue/:id/cancel` | `{ userId }` | إلغاء الدور |
| GET | `/queue/book/:bookId` | | حالة الطابور لكتاب |

### أكواد الأخطاء

| الكود | الرسالة | HTTP |
|---|---|---|
| `P0010` | Book not found | 404 |
| `P0012` | Copies available, borrow directly | 409 |
| `P0013` | Already in the queue | 409 |
| `P0014` | Borrowing not found or already returned | 404 |
| `P0015` | Already borrowed this book | 409 |
| `P0016` | Reservation not found or expired | 404 |
| `P0017` | Queue entry not found | 404 |
| `P0018` | Queue entry can no longer be cancelled | 409 |
| `23505` | Duplicate entry | 409 |
| `23503` | Related record does not exist | 400 |

أي خطأ غير متوقع بيرجع `500 Internal server error`، والتفاصيل بتنكتب بالـ log بس.

---

## حالات الطابور

```
WAITING ──(رجعت نسخة)──► RESERVED ──(استلم)──► FULFILLED
   │                        │
   │                        ├──(مرّت 24 ساعة)──► EXPIRED   (النسخة للي بعدو)
   │                        └──(لغى)───────────► CANCELLED (النسخة للي بعدو)
   └──(لغى)──► CANCELLED
```

---

## التزامن (Concurrency)

**القاعدة:** كل function بتلمس طابور كتاب بتقفل صف الكتاب **أولاً**، وبعدين صفوف الطابور:

```sql
PERFORM 1 FROM books WHERE id = p_book_id FOR NO KEY UPDATE;
```

- **صف الكتاب = mutex:** كل العمليات على نفس الكتاب بتتنفّذ ورا بعض، فالترتيب (FIFO) مضمون وما في race conditions.
- **ترتيب قفل ثابت** (`books` ← `queues`) بكل الـ functions، فما في deadlocks.
- **`FOR NO KEY UPDATE` مو `FOR UPDATE`:** أي `INSERT` على `borrowings` أو `queues` بياخد قفل `KEY SHARE` على الكتاب (بسبب الـ foreign key). و`FOR UPDATE` بيتعارض معو فبيسبب deadlock، أما `FOR NO KEY UPDATE` فلا.
- **FIFO بـ `position`** مو `created_at`، لأنو `NOW()` بـ PostgreSQL هو وقت **بداية** الـ transaction مو وقت الإدخال.

### الحماية على مستوى الـ Schema (Defense in depth)

| Constraint | بيمنع |
|---|---|
| `CHECK (available_copies <= total_copies)` | نسخ أكتر من الموجود |
| `UNIQUE (user_id, book_id) WHERE status IN ('WAITING','RESERVED')` | نفس المستخدم مرتين بالطابور |
| `UNIQUE (user_id, book_id) WHERE returned_at IS NULL` | استعارتين نشطتين لنفس الكتاب |

---

## الاختبارات

### 1. اختبار المنطق (18 فحص)

```bash
psql -U postgres -d library_db -f sql/verify.sql
```

كل فحص بيطبع `PASS`، وأول فشل بيوقف الملف بـ `FAIL`.
⚠️ بيمسح كل الداتا.

### 2. اختبار التزامن

20 client × 200 عملية عشوائية (borrow / return / receive / cancel / expire) على نفس الكتاب:

```bash
psql -U postgres -d library_db -f sql/pgbench_helper.sql
psql -U postgres -d library_db -c "SELECT stress_reset(2, 10);"
pgbench -n -c 20 -j 4 -t 200 -f sql/concurrency_test.sql -U postgres library_db
psql -U postgres -d library_db -f sql/check_invariants.sql
```

**المتوقع:** `number of failed transactions: 0` و 3 PASS:

| Invariant | المعنى |
|---|---|
| I1 | `available + borrowed + reserved = total`: ما في نسخة ضاعت أو انخلقت |
| I2 | ما في نسخة متاحة وحدا عم يستنى |
| I3 | ما في حدا WAITING أقدم من حدا انحجزلو (FIFO) |

### 3. اختبار الـ API

`requests.http`: 21 طلب مع النتيجة المتوقعة فوق كل واحد (بيحتاج extension **REST Client** بـ VS Code).

```bash
psql -U postgres -d library_db -c "TRUNCATE queues, borrowings, books, users RESTART IDENTITY CASCADE;"
npm run start:dev
```

---

## بنية المشروع

```
├── sql/
│   ├── schema.sql              الجداول + الـ constraints
│   ├── functions.sql           كل الـ business logic
│   ├── verify.sql              اختبار المنطق
│   ├── pgbench_helper.sql      دوال مساعدة لاختبار التزامن
│   ├── concurrency_test.sql    سكربت pgbench
│   └── check_invariants.sql    فحص الحالة بعد pgbench
├── prisma/schema.prisma
├── src/
│   ├── common/filters/prisma-exception.filter.ts
│   ├── prisma/                 PrismaService
│   ├── users/  books/          CRUD عادي بـ Prisma
│   ├── borrowings/  queue/     استدعاء الـ SQL functions
│   └── scheduler/              معالجة الحجوزات المنتهية كل دقيقة
└── requests.http
```
