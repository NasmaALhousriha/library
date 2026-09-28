import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service.js';

@Injectable()
export class QueueService {
  constructor(private readonly prisma: PrismaService) {}

  async joinQueue(userId: number, bookId: number) {
    const rows = await this.prisma.$queryRaw<{ join_queue: number }[]>`
      SELECT join_queue(${userId}, ${bookId}) AS join_queue;`;
    return { queueId: rows[0].join_queue };
  }

  async getQueueForBook(bookId: number) {
    const rows = await this.prisma.$queryRaw<{ get_queue_for_book: unknown }[]>`
      SELECT get_queue_for_book(${bookId}) AS get_queue_for_book;`;
    return rows[0].get_queue_for_book;
  }

  async receiveBook(queueId: number, userId: number) {
    const rows = await this.prisma.$queryRaw<{ receive_book: number }[]>`
      SELECT receive_book(${queueId}, ${userId}) AS receive_book;`;
    return { borrowingId: rows[0].receive_book, message: 'Book received successfully' };
  }

  async cancelQueueEntry(queueId: number, userId: number) {
    await this.prisma.$executeRaw`SELECT cancel_queue_entry(${queueId}, ${userId});`;
    return { message: 'Queue entry cancelled successfully' };
  }
}
