import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service.js';

@Injectable()
export class BooksService {
  constructor(private readonly prisma: PrismaService) {}

  async createBook(title: string, author: string, totalCopies: number) {
    return this.prisma.book.create({
      data: { title, author, totalCopies, availableCopies: totalCopies },
    });
  }

  async listBooks() {
    return this.prisma.book.findMany({ orderBy: { id: 'asc' } });
  }

  async getBookById(id: number) {
    const book = await this.prisma.book.findUnique({ where: { id } });
    if (!book) {
      throw new NotFoundException('Book not found');
    }
    return book;
  }
}
