import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service.js';

export interface BorrowingRow {
  id: number;
  userId: number;
  bookId: number;
  borrowedAt: Date;
  dueDate: Date;
  returnedAt: Date | null;
  userName: string;
  userEmail: string;
  bookTitle: string;
  bookAuthor: string;
}

@Injectable()
export class BorrowingsService {
  constructor(private readonly prisma: PrismaService) {}

  async borrowBook(userId: number, bookId: number) {
    const rows = await this.prisma.$queryRaw<{ borrow_book: unknown }[]>`
      SELECT borrow_book(${userId}, ${bookId}) AS borrow_book;`;
    return rows[0].borrow_book;
  }

  async returnBook(borrowingId: number) {
    await this.prisma.$executeRaw`SELECT return_book(${borrowingId});`;
    return { message: 'Book returned successfully' };
  }

  async listBorrowings() {
    const rows = await this.prisma.$queryRaw<BorrowingRow[]>`
      SELECT
        b.id,
        b.user_id     AS "userId",
        b.book_id     AS "bookId",
        b.borrowed_at AS "borrowedAt",
        b.due_date    AS "dueDate",
        b.returned_at AS "returnedAt",
        u.name        AS "userName",
        u.email       AS "userEmail",
        bk.title      AS "bookTitle",
        bk.author     AS "bookAuthor"
      FROM borrowings b
      JOIN users u  ON u.id  = b.user_id
      JOIN books bk ON bk.id = b.book_id
      ORDER BY b.id ASC;
    `;

    return rows.map((r) => ({
      id: r.id,
      userId: r.userId,
      bookId: r.bookId,
      borrowedAt: r.borrowedAt,
      dueDate: r.dueDate,
      returnedAt: r.returnedAt,
      user: { id: r.userId, name: r.userName, email: r.userEmail },
      book: { id: r.bookId, title: r.bookTitle, author: r.bookAuthor },
    }));
  }
}
